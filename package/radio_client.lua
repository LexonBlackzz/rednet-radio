local config = require("rednet_radio.config")
local directory = require("rednet_radio.directory")
local rednet_api = require("rednet_radio.rednet_api")
local util = require("rednet_radio.util")
local audio = require("rednet_radio.audio")
local monitor = require("rednet_radio.monitor")

local stations = {}
local currentStation
local currentSnapshot
local lastUpdateMs

local function clear()
  term.clear()
  term.setCursorPos(1, 1)
end

local function loadStations()
  local loadedStations, source, err = directory.loadStations(config.directory_url)
  if not loadedStations then
    return nil, source, ("Could not load stations from %s: %s"):format(
      config.directory_url,
      err or source or "unknown error"
    )
  end

  stations = loadedStations
  return loadedStations, source
end

local function printStationList(source)
  clear()
  print("Rednet Radio")
  print(("Directory: %s"):format(source or "unknown"))
  print("")

  if #stations == 0 then
    print("No stations were found.")
  else
    for index, station in ipairs(stations) do
      print(("%d. %s [%s]"):format(index, station.name, station.station_id))
      if station.description and station.description ~= "" then
        print(("   %s"):format(station.description))
      end
    end
  end

  print("")
  print("Type a station number or station_id, then press Enter.")
  print("Commands: r = reload directory, q = quit")
end

local function chooseStation()
  while true do
    local loadedStations, source, err = loadStations()
    if not loadedStations then
      clear()
      print(("Could not load stations: %s"):format(err or "unknown error"))
      print("Press Enter to retry, or type q to quit.")
      local answer = read()
      if answer == "q" then
        return nil
      end
    else
      printStationList(source)
      write("> ")
      local answer = read()

      if answer == "q" then
        return nil
      elseif answer == "r" then
        -- Loop and reload.
      else
        local station = directory.findStation(stations, answer)
        if station then
          return station
        end

        clear()
        print(("No station matched '%s'."):format(answer))
        print("Press Enter to try again.")
        read()
      end
    end
  end
end

local function renderTunedScreen()
  clear()
  print(("Tuned to: %s"):format(currentStation.name))
  print(("Station ID: %s"):format(currentStation.station_id))
  print(("Protocol: %s"):format(rednet_api.getStationProtocol(currentStation)))
  print("")

  if currentSnapshot and currentSnapshot.track then
    local elapsedSeconds = math.floor(util.trackElapsedMilliseconds(currentSnapshot) / 1000)
    print(("Now Playing: %s - %s"):format(
      currentSnapshot.track.artist,
      currentSnapshot.track.title
    ))
    print(("Elapsed: %ss / %ss"):format(
      elapsedSeconds,
      currentSnapshot.duration
    ))
    print(("Source URL: %s"):format(currentSnapshot.track.source_url))

    if currentSnapshot.track.playback_url then
      print(("Playback URL: %s"):format(currentSnapshot.track.playback_url))
    end
  else
    print("Waiting for station data...")
  end

  print("")
  print(("Playback: %s"):format(audio.getStatusSummary()))
  print(("Last sync: %s"):format(lastUpdateMs and util.formatAge(lastUpdateMs) or "never"))
  print("Keys: q = back to station list, p = ping station, r = reload directory")

  monitor.renderClient(currentStation, currentSnapshot, audio.getStatusSummary())
end

local function tuneStation(station)
  currentStation = station
  currentSnapshot = nil
  lastUpdateMs = nil
  audio.stopTrack()

  rednet_api.listenToStation(station)
  rednet_api.requestTune(station)
  rednet_api.sendPing(station)

  local timers = {}

  local function schedule(name, seconds)
    timers[os.startTimer(seconds)] = name
  end

  schedule("render", 1)
  schedule("ping", config.client_ping_interval_seconds)

  while true do
    renderTunedScreen()

    local event, p1, p2, p3 = os.pullEvent()

    if event == "timer" then
      local timerName = timers[p1]
      timers[p1] = nil

      if timerName == "render" then
        schedule("render", 1)
      elseif timerName == "ping" then
        rednet_api.sendPing(station)
        schedule("ping", config.client_ping_interval_seconds)
      end
    elseif event == "rednet_message" then
      local message = p2
      local protocol = p3

      if rednet_api.matchesStationProtocol(station, protocol) and rednet_api.isRadioMessage(message) then
        if message.station_id == station.station_id then
          if message.message_type == config.message_types.station_info then
            currentStation = util.mergeTables(currentStation, message.station)
            currentSnapshot = message.snapshot or currentSnapshot
            lastUpdateMs = util.nowMilliseconds()
            audio.syncToSnapshot(currentSnapshot)
          elseif message.message_type == config.message_types.now_playing
            or message.message_type == config.message_types.sync
            or message.message_type == config.message_types.announce then
            currentSnapshot = message.snapshot or currentSnapshot
            lastUpdateMs = util.nowMilliseconds()
            audio.syncToSnapshot(currentSnapshot)
          end
        end
      end
    elseif event == "speaker_audio_empty" then
      audio.handleEvent(event)
    elseif event == "char" then
      local key = p1
      if key == "q" then
        audio.stopTrack()
        return
      elseif key == "p" then
        rednet_api.sendPing(station)
      elseif key == "r" then
        local loadedStations = directory.loadStations(config.directory_url)
        if loadedStations then
          local refreshed = directory.findStation(loadedStations, station.station_id)
          if refreshed then
            currentStation = refreshed
            rednet_api.listenToStation(currentStation)
          end
        end
      end
    elseif event == "key" and p1 == keys.backspace then
      audio.stopTrack()
      return
    end
  end
end

local function main()
  if rednet_api.openModems() == 0 then
    error("No modem was found. Attach a modem before running the radio client.")
  end

  while true do
    local station = chooseStation()
    if not station then
      clear()
      print("Goodbye.")
      return
    end

    tuneStation(station)
  end
end

local ok, err = xpcall(main, function(message)
  return debug and debug.traceback and debug.traceback(message, 2) or tostring(message)
end)

if not ok then
  print("radio_client failed:")
  print(err)
  print("")
  print("Press any key to exit.")
  os.pullEvent("key")
end
