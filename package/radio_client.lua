local config = require("rednet_radio.config")
local directory = require("rednet_radio.directory")
local rednet_api = require("rednet_radio.rednet_api")
local util = require("rednet_radio.util")
local audio = require("rednet_radio.audio")
local monitor = require("rednet_radio.monitor")
local settings = require("rednet_radio.settings")
local updater = require("rednet_radio.updater")

local stations = {}
local currentStation
local currentSnapshot
local lastUpdateMs
local updateStatus = "update check pending"
local updateInfo = nil
local screenMode = "main"
local updatePrompt = {
  visible = false,
  latest_version = nil,
  show_never_option = false,
}

local function clear()
  term.clear()
  term.setCursorPos(1, 1)
end

local function adjustVolume(deltaPercent)
  audio.adjustVolumePercent(deltaPercent)
end

local function refreshUpdateState(statusOverride)
  updateInfo = nil

  local result, err = updater.check()
  if not result then
    updateStatus = statusOverride or ("update check failed (%s)"):format(err or "unknown error")
    updatePrompt.visible = false
    updatePrompt.latest_version = nil
    updatePrompt.show_never_option = settings.shouldShowNeverOption()
    return
  end

  updateInfo = result
  if result.update_available then
    updateStatus = statusOverride or ("update available: %s -> %s"):format(
      result.current_version,
      result.latest_version
    )
    updatePrompt.visible = settings.shouldPromptForVersion(result.latest_version)
    updatePrompt.latest_version = result.latest_version
    updatePrompt.show_never_option = settings.shouldShowNeverOption()
  else
    updateStatus = statusOverride or ("up to date (%s)"):format(result.current_version)
    updatePrompt.visible = false
    updatePrompt.latest_version = nil
    updatePrompt.show_never_option = settings.shouldShowNeverOption()
  end
end

local function remindAboutUpdateLater()
  settings.remindLater()
  updatePrompt.visible = false
  if updateInfo and updateInfo.latest_version then
    updateStatus = ("update available: %s (remind later)"):format(updateInfo.latest_version)
  end
end

local function neverShowThisUpdate()
  if updateInfo and updateInfo.latest_version and settings.shouldShowNeverOption() then
    settings.ignoreVersion(updateInfo.latest_version)
    updatePrompt.visible = false
    updateStatus = ("ignored update %s"):format(updateInfo.latest_version)
  end
end

local function installAvailableUpdate()
  local result, err = updater.applyLocalUpdate()
  if not result then
    updateStatus = ("local update failed (%s)"):format(err or "unknown error")
    updatePrompt.visible = false
    return
  end

  settings.clearReminder()
  settings.clearIgnoredVersion()
  updatePrompt.visible = false
  updateStatus = result.message
  if result.updated then
    updateInfo = nil
    updatePrompt.latest_version = nil
    return
  end

  refreshUpdateState(result.message)
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
  print(("Updates: %s"):format(updateStatus))
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
  if screenMode == "settings" then
    local currentSettings = settings.get()
    print("Client Settings")
    print("")
    print(("Never button in update prompt: %s"):format(
      currentSettings.show_never_option and "ON" or "OFF"
    ))
    print(("Updates: %s"):format(updateStatus))
    print("")
    print("Keys: b = back, t = toggle NEVER option, q = back to station list")

    monitor.renderClientSettings(audio.getStatusSummary(), currentSettings)
    return
  end

  print(("Tuned to: %s"):format(currentStation.name))
  print(("Station ID: %s"):format(currentStation.station_id))
  print(("Protocol: %s"):format(rednet_api.getStationProtocol(currentStation)))
  print("")

  if currentSnapshot and currentSnapshot.track then
    local elapsedSeconds = math.floor(util.trackElapsedMilliseconds(currentSnapshot) / 1000)
    local shownElapsed = math.min(elapsedSeconds, currentSnapshot.duration)
    print(("Now Playing: %s - %s"):format(
      currentSnapshot.track.artist,
      currentSnapshot.track.title
    ))
    print(("Elapsed: %ss / %ss"):format(
      shownElapsed,
      currentSnapshot.duration
    ))
    print(("Track: %d / %d"):format(
      currentSnapshot.track_index or 0,
      currentSnapshot.track_count or 0
    ))
    print(("Source URL: %s"):format(currentSnapshot.track.source_url))

    if currentSnapshot.track.playback_url then
      print(("Playback URL: %s"):format(currentSnapshot.track.playback_url))
    end
    if currentSnapshot.in_gap then
      print(("Intermission: %ss"):format(currentSnapshot.gap_seconds or 0))
    end
  else
    print("Waiting for station data...")
  end

  print("")
  print(("Playback: %s"):format(audio.getStatusSummary()))
  print(("Volume: %d%% / %d%%"):format(
    audio.getVolumePercent(),
    audio.getMaxVolumePercent()
  ))
  print(("Updates: %s"):format(updateStatus))
  print(("Last sync: %s"):format(lastUpdateMs and util.formatAge(lastUpdateMs) or "never"))
  print("Keys: q = back, p = ping, r = reload, s = settings, [ / ] = volume")

  if updatePrompt.visible then
    local promptLine = "Update prompt: o = OK, l = remind me later"
    if updatePrompt.show_never_option then
      promptLine = promptLine .. ", n = never"
    end
    print(promptLine)
  end

  monitor.renderClient(
    currentStation,
    currentSnapshot,
    audio.getStatusSummary(),
    audio.getVolumePercent(),
    audio.getMaxVolumePercent(),
    updateStatus,
    updatePrompt
  )
end

local function tuneStation(station)
  currentStation = station
  currentSnapshot = nil
  lastUpdateMs = nil
  screenMode = "main"
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
      elseif screenMode == "settings" then
        if key == "b" then
          screenMode = "main"
        elseif key == "t" then
          settings.toggleShowNeverOption()
          refreshUpdateState()
        end
      elseif updatePrompt.visible then
        if key == "o" then
          installAvailableUpdate()
        elseif key == "l" then
          remindAboutUpdateLater()
        elseif key == "n" then
          neverShowThisUpdate()
        elseif key == "s" then
          screenMode = "settings"
        elseif key == "[" then
          adjustVolume(-audio.getVolumeStepPercent())
        elseif key == "]" then
          adjustVolume(audio.getVolumeStepPercent())
        end
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
      elseif key == "s" then
        screenMode = "settings"
      elseif key == "[" then
        adjustVolume(-audio.getVolumeStepPercent())
      elseif key == "]" then
        adjustVolume(audio.getVolumeStepPercent())
      end
    elseif event == "monitor_touch" then
      local action = monitor.getClientTouchAction(
        p1,
        p2,
        p3,
        screenMode,
        updatePrompt,
        settings.get()
      )
      if action == "volume_down" then
        adjustVolume(-audio.getVolumeStepPercent())
      elseif action == "volume_up" then
        adjustVolume(audio.getVolumeStepPercent())
      elseif action == "open_settings" then
        screenMode = "settings"
      elseif action == "settings_back" then
        screenMode = "main"
      elseif action == "toggle_never_option" then
        settings.toggleShowNeverOption()
        refreshUpdateState()
      elseif action == "update_ok" then
        installAvailableUpdate()
      elseif action == "update_later" then
        remindAboutUpdateLater()
      elseif action == "update_never" then
        neverShowThisUpdate()
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

  settings.load()
  refreshUpdateState()

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
