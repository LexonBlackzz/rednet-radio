local config = require("rednet_radio.config")
local directory = require("rednet_radio.directory")
local playlist = require("rednet_radio.playlist")
local station_module = require("rednet_radio.station")
local rednet_api = require("rednet_radio.rednet_api")
local util = require("rednet_radio.util")
local monitor = require("rednet_radio.monitor")
local launchArgs = { ... }

local function log(message)
  print(("[%s] %s"):format(textutils.formatTime(os.time(), true), message))
end

local function main(args)
  local stationId = args[1]

  if not stationId or stationId == "" then
    print("Usage: radio_host <station_id>")
    return
  end

  local function loadStationDefinition()
    local stations, source, err = directory.loadStations(config.directory_url)
    if not stations then
      return nil, ("Could not load stations from %s: %s"):format(
        config.directory_url,
        err or source or "unknown error"
      )
    end

    for _, station in ipairs(stations) do
      if station.station_id == stationId then
        return station, source
      end
    end

    return nil, ("Station '%s' was not found in stations.json at %s"):format(
      stationId,
      config.directory_url
    )
  end

  local function loadPlaylist(stationDefinition)
    local playlistDoc, source, err = playlist.loadPlaylist(
      stationDefinition.station_id,
      stationDefinition.playlist_url,
      stationDefinition.name
    )
    if not playlistDoc then
      return nil, ("Could not load playlist for station '%s' from %s: %s"):format(
        stationDefinition.station_id,
        stationDefinition.playlist_url,
        err or source or "unknown error"
      )
    end

    return playlistDoc, source
  end

  if rednet_api.openModems() == 0 then
    error("No modem was found. Attach a modem before starting a station host.")
  end

  local stationDefinition, definitionSourceOrErr = loadStationDefinition()
  if not stationDefinition then
    error(definitionSourceOrErr or "Unknown station directory error")
  end

  local playlistDoc, playlistSourceOrErr = loadPlaylist(stationDefinition)
  if not playlistDoc then
    error(playlistSourceOrErr or "Unknown playlist error")
  end

  local stationRuntime = station_module.new(stationDefinition, playlistDoc)
  rednet_api.hostStation(stationDefinition)

  log(("Hosting station '%s' using %s directory data and %s playlist data."):format(
    stationDefinition.name,
    definitionSourceOrErr,
    playlistSourceOrErr
  ))
  monitor.renderHost(stationDefinition, stationRuntime:getSnapshot(), playlistSourceOrErr)

  rednet_api.broadcastAnnounce(stationDefinition, stationRuntime:getSnapshot())
  rednet_api.broadcastNowPlaying(stationDefinition, stationRuntime:getSnapshot())

  local timers = {}

  local function schedule(name, seconds)
    timers[os.startTimer(seconds)] = name
  end

  schedule("tick", 1)
  schedule("sync", config.sync_interval_seconds)
  schedule("announce", config.announce_interval_seconds)
  if (config.directory_refresh_seconds or 0) > 0 then
    schedule("refresh_directory", config.directory_refresh_seconds)
  end
  if (config.playlist_refresh_seconds or 0) > 0 then
    schedule("refresh_playlist", config.playlist_refresh_seconds)
  end

  while true do
    local event, p1, p2, p3 = os.pullEvent()

    if event == "timer" then
      local timerName = timers[p1]
      timers[p1] = nil

      if timerName == "tick" then
        local changed = stationRuntime:update(util.nowMilliseconds())
        if changed then
          local snapshot = stationRuntime:getSnapshot()
          local track = snapshot.track
          if track then
            log(("Advanced to track %d: %s - %s"):format(
              snapshot.track_index or 0,
              track.artist or "Unknown Artist",
              track.title or "Unknown Track"
            ))
          end
          rednet_api.broadcastNowPlaying(stationDefinition, stationRuntime:getSnapshot())
        end
        monitor.renderHost(stationDefinition, stationRuntime:getSnapshot(), playlistSourceOrErr)
        schedule("tick", 1)
      elseif timerName == "sync" then
        rednet_api.broadcastSync(stationDefinition, stationRuntime:getSnapshot())
        schedule("sync", config.sync_interval_seconds)
      elseif timerName == "announce" then
        rednet_api.broadcastAnnounce(stationDefinition, stationRuntime:getSnapshot())
        schedule("announce", config.announce_interval_seconds)
      elseif timerName == "refresh_directory" then
        local freshDefinition, source, err = loadStationDefinition()
        if freshDefinition then
          stationDefinition = util.mergeTables(stationDefinition, freshDefinition)
          rednet_api.hostStation(stationDefinition)
          log(("Reloaded station definition from %s."):format(source))
        else
          log(("Directory refresh failed: %s"):format(err or "unknown error"))
        end
        if (config.directory_refresh_seconds or 0) > 0 then
          schedule("refresh_directory", config.directory_refresh_seconds)
        end
      elseif timerName == "refresh_playlist" then
        local freshPlaylist, source, err = loadPlaylist(stationDefinition)
        if freshPlaylist then
          local changed = stationRuntime:setPlaylist(freshPlaylist)
          log(("Reloaded playlist from %s."):format(source))
          if changed then
            rednet_api.broadcastNowPlaying(stationDefinition, stationRuntime:getSnapshot())
          end
          playlistSourceOrErr = source
          monitor.renderHost(stationDefinition, stationRuntime:getSnapshot(), playlistSourceOrErr)
        else
          log(("Playlist refresh failed: %s"):format(err or "unknown error"))
        end
        if (config.playlist_refresh_seconds or 0) > 0 then
          schedule("refresh_playlist", config.playlist_refresh_seconds)
        end
      end
    elseif event == "rednet_message" then
      local senderId = p1
      local message = p2
      local protocol = p3

      if rednet_api.acceptsProtocol(stationDefinition, protocol) and rednet_api.isRadioMessage(message) then
        if message.message_type == config.message_types.ping then
          rednet_api.sendStationInfo(senderId, stationDefinition, stationRuntime:getSnapshot())
        elseif message.message_type == config.message_types.tune_request then
          rednet_api.sendStationInfo(senderId, stationDefinition, stationRuntime:getSnapshot())
          rednet_api.sendNowPlaying(senderId, stationDefinition, stationRuntime:getSnapshot())
        end
      end
    end
  end
end

local ok, err = xpcall(function()
  main(launchArgs)
end, function(message)
  return debug and debug.traceback and debug.traceback(message, 2) or tostring(message)
end)

if not ok then
  print("radio_host failed:")
  print(err)
  print("")
  print("Press any key to exit.")
  os.pullEvent("key")
end
