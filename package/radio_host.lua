local config = require("rednet_radio.config")
local directory = require("rednet_radio.directory")
local playlist = require("rednet_radio.playlist")
local station_module = require("rednet_radio.station")
local rednet_api = require("rednet_radio.rednet_api")
local util = require("rednet_radio.util")
local monitor = require("rednet_radio.monitor")
local updater = require("rednet_radio.updater")
local settings = require("rednet_radio.settings")
local launchArgs = { ... }

local function log(message)
  print(("[%s] %s"):format(textutils.formatTime(os.time(), true), message))
end

local function main(...)
  local args = { ... }
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
  settings.load()
  monitor.setPalette(settings.getPalette())
  rednet_api.hostStation(stationDefinition)

  log(("Hosting station '%s' using %s directory data and %s playlist data."):format(
    stationDefinition.name,
    definitionSourceOrErr,
    playlistSourceOrErr
  ))
  log(("Updates: %s"):format(updater.getStatusSummary()))
  monitor.renderHost(stationDefinition, stationRuntime:getSnapshot(), playlistSourceOrErr)
  local screenMode = "main"

  rednet_api.broadcastAnnounce(stationDefinition, stationRuntime:getSnapshot())
  rednet_api.broadcastNowPlaying(stationDefinition, stationRuntime:getSnapshot())

  local timers = {}

  local function schedule(name, seconds)
    timers[os.startTimer(seconds)] = name
  end
  
  -- EAS tracking variables
  local easActive = false
  local easPlaying = false
  local easStartTime = nil
  local updateStatus = "Checking for updates..."

  local function startAnnouncement()
    if easPlaying then return end
    log("Announcement Triggered, sending alerts")
    easStartTime = util.nowMilliseconds()
    
    rednet_api.broadcastMessage(stationDefinition, {
      message_type = config.message_types.eas_start,
      alarm_seconds = 5,
      volume = 3
    })
    
    easPlaying = true
    
    -- Wait exactly 5 seconds to match the client's generated siren duration
    local waitTime = 5 
    schedule("eas_finish", waitTime)
  end

  local function installAvailableUpdate()
    local result, err = updater.applyLocalUpdate()
    if not result then
      updateStatus = ("local update failed (%s)"):format(err or "unknown error")
      return
    end

    updateStatus = result.message
    if result.updated then
        -- Hot reload
        log("Update installed. Hot-reloading...")
        for k, v in pairs(package.loaded) do
          if k:match("^rednet_radio%.") then
            package.loaded[k] = nil
          end
        end
        shell.run(shell.getRunningProgram(), table.unpack(args))
        error("RESTART", 0)
    end
  end

  local function refreshUpdateState()
    updater.check()
    updateStatus = updater.getStatusSummary()
  end

  local function getHostSnapshot()
    local snapshot = stationRuntime:getSnapshot()
    snapshot.allow_remote_skip = settings.getAllowRemoteSkip()
    snapshot.allow_remote_shuffle = settings.getAllowRemoteShuffle()
    snapshot.eas_active = easPlaying
    return snapshot
  end

  local function stopAnnouncement()
    log("announcement signal removed. sending expiration...")
    rednet_api.broadcastMessage(stationDefinition, {
      message_type = config.message_types.eas_end
    })
    rednet_api.broadcastNowPlaying(stationDefinition, getHostSnapshot())
  end

  schedule("tick", 1)
  schedule("sync", config.sync_interval_seconds)
  schedule("announce", config.announce_interval_seconds)
  schedule("check_updates", 1)
  if (config.directory_refresh_seconds or 0) > 0 then
    schedule("refresh_directory", config.directory_refresh_seconds)
  end

  -- Initial Redstone Check
  if settings.getEnableRedstoneAnnouncement() then
    local side = settings.getAnnouncementRedstoneSide()
    if rs.getInput(side) then
      easActive = true
      startAnnouncement()
    end
  end
  if (config.playlist_refresh_seconds or 0) > 0 then
    schedule("refresh_playlist", config.playlist_refresh_seconds)
  end

  local function uiThread()
    while true do
      local event, p1, p2, p3 = os.pullEvent()

      if event == "timer" then
        local timerName = timers[p1]
        if timerName then
          if timerName == "tick" then
            timers[p1] = nil
            local changed = false
            if not easPlaying then
              changed = stationRuntime:update(util.nowMilliseconds())
            end
            if changed then
              local snapshot = getHostSnapshot()
              local track = snapshot.track
              if track then
                log(("Advanced to track %d: %s - %s"):format(snapshot.track_index or 0, track.artist or "Unknown Artist", track.title or "Unknown Track"))
              end
              rednet_api.broadcastNowPlaying(stationDefinition, getHostSnapshot())
            elseif easPlaying then
              rednet_api.broadcastNowPlaying(stationDefinition, getHostSnapshot())
            end
            
            if screenMode == "main" then
              monitor.renderHost(stationDefinition, getHostSnapshot(), playlistSourceOrErr, updateStatus)
            else
              monitor.renderHostSettings(stationDefinition.name, settings.getAllowRemoteSkip(), settings.getAllowRemoteShuffle(), settings.getEnableRedstoneAnnouncement(), settings.getAnnouncementRedstoneSide())
            end
            schedule("tick", 1)
          elseif timerName == "eas_finish" then
            timers[p1] = nil
            log("EAS alarm finished. Resuming music.")
            if easStartTime then
              local duration = util.nowMilliseconds() - easStartTime
              stationRuntime:offsetStartTime(duration)
            end
            easPlaying = false
            rednet_api.broadcastNowPlaying(stationDefinition, getHostSnapshot())
          end
        end
      elseif event == "monitor_touch" then
        local x, y = p2, p3
        local action = monitor.getHostTouchAction(x, y, screenMode, settings.getAllowRemoteSkip(), settings.getAllowRemoteShuffle())
        if action == "open_settings" then
          screenMode = "settings"
        elseif action == "settings_back" then
          screenMode = "main"
        elseif action == "toggle_remote_skip" then
          settings.toggleAllowRemoteSkip()
        elseif action == "toggle_remote_shuffle" then
          settings.toggleAllowRemoteShuffle()
        elseif action == "toggle_eas" then
          settings.toggleEnableRedstoneAnnouncement()
        elseif action == "cycle_eas_side" then
          settings.cycleAnnouncementRedstoneSide()
          log("Redstone side changed to: " .. settings.getAnnouncementRedstoneSide())
        elseif action == "check_updates" then
          updateStatus = "Checking for updates..."
          monitor.renderHost(stationDefinition, getHostSnapshot(), playlistSourceOrErr, updateStatus)
          local result = updater.check()
          if result and result.update_available then
            updateStatus = "Update available! Installing..."
            monitor.renderHost(stationDefinition, getHostSnapshot(), playlistSourceOrErr, updateStatus)
            installAvailableUpdate()
          else
            updateStatus = updater.getStatusSummary()
          end
        end
        if screenMode == "main" then
          monitor.renderHost(stationDefinition, getHostSnapshot(), playlistSourceOrErr, updateStatus)
        else
          monitor.renderHostSettings(stationDefinition.name, settings.getAllowRemoteSkip(), settings.getAllowRemoteShuffle(), settings.getEnableRedstoneAnnouncement(), settings.getAnnouncementRedstoneSide())
        end
      elseif event == "redstone" then
        local currentSide = settings.getAnnouncementRedstoneSide()
        if settings.getEnableRedstoneAnnouncement() then
          local signal = rs.getInput(currentSide)
          if signal and not easActive then
            log("Announcement triggered via " .. currentSide)
            easActive = true
            startAnnouncement()
          elseif not signal and easActive then
            log("Announcement signal LOST on " .. currentSide)
            easActive = false
            stopAnnouncement()
          end
        end
      elseif event == "rednet_message" then
        local senderId, message, protocol = p1, p2, p3
        if rednet_api.acceptsProtocol(stationDefinition, protocol) and rednet_api.isRadioMessage(message) then
          if message.palette then
            settings.setPalette(message.palette)
            monitor.setPalette(message.palette)
          end
          if message.message_type == config.message_types.ping then
            rednet_api.sendStationInfo(senderId, stationDefinition, stationRuntime:getSnapshot())
          elseif message.message_type == config.message_types.tune_request then
            rednet_api.sendStationInfo(senderId, stationDefinition, stationRuntime:getSnapshot())
            rednet_api.sendNowPlaying(senderId, stationDefinition, stationRuntime:getSnapshot())
          elseif message.message_type == config.message_types.skip_request then
            if settings.getAllowRemoteSkip() then
              stationRuntime:advanceTrack(util.nowMilliseconds())
              rednet_api.broadcastNowPlaying(stationDefinition, getHostSnapshot())
              if screenMode == "main" then monitor.renderHost(stationDefinition, getHostSnapshot(), playlistSourceOrErr) end
            end
          elseif message.message_type == config.message_types.shuffle_request then
            if settings.getAllowRemoteShuffle() then
              stationRuntime:toggleShuffle()
              rednet_api.broadcastNowPlaying(stationDefinition, getHostSnapshot())
              if screenMode == "main" then monitor.renderHost(stationDefinition, getHostSnapshot(), playlistSourceOrErr) end
            end
          end
        end
      end
    end
  end

  local function networkThread()
    while true do
      local event, p1 = os.pullEvent("timer")
      local timerName = timers[p1]
      if timerName then
        timers[p1] = nil
        if timerName == "sync" then
          timers[p1] = nil
          rednet_api.broadcastSync(stationDefinition, getHostSnapshot())
          schedule("sync", config.sync_interval_seconds)
        elseif timerName == "announce" then
          timers[p1] = nil
          rednet_api.broadcastAnnounce(stationDefinition, getHostSnapshot())
          schedule("announce", config.announce_interval_seconds)
        elseif timerName == "check_updates" then
          timers[p1] = nil
          refreshUpdateState()
          schedule("check_updates", 120)
        elseif timerName == "refresh_directory" then
          timers[p1] = nil
          local freshDefinition, source, err = loadStationDefinition()
          if freshDefinition then
            stationDefinition = util.mergeTables(stationDefinition, freshDefinition)
            rednet_api.hostStation(stationDefinition)
          end
          schedule("refresh_directory", config.directory_refresh_seconds or 300)
        elseif timerName == "refresh_playlist" then
          timers[p1] = nil
          local freshPlaylist, source, err = loadPlaylist(stationDefinition)
          if freshPlaylist then
            if stationRuntime:setPlaylist(freshPlaylist) then
              rednet_api.broadcastNowPlaying(stationDefinition, stationRuntime:getSnapshot())
            end
            playlistSourceOrErr = source
          end
          schedule("refresh_playlist", config.playlist_refresh_seconds or 300)
        end
      end
    end
  end

  parallel.waitForAny(uiThread, networkThread)
end


local ok, err = xpcall(main, function(message)
  return debug and debug.traceback and debug.traceback(message, 2) or tostring(message)
end, ...)

if not ok then
  print("radio_host failed:")
  print(err)
  print("")
  print("Press any key to exit.")
  os.pullEvent("key")
end