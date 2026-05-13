local config = require("rednet_radio.config")
local directory = require("rednet_radio.directory")
local rednet_api = require("rednet_radio.rednet_api")
local util = require("rednet_radio.util")
local audio = require("rednet_radio.audio")
local monitor = require("rednet_radio.monitor")
local settings = require("rednet_radio.settings")
local updater = require("rednet_radio.updater")
local version = require("rednet_radio.version")
 
local function generateSine(freq, duration, volume)
  local samples = {}
  local numSamples = math.floor(48000 * duration)
  local step = (2 * math.pi * freq) / 48000
  for i = 1, numSamples do
    samples[i] = math.floor(math.sin(i * step) * 126 * volume + 0.5)
  end
  return samples
end

local stations = {}
local currentStation
local currentSnapshot
local lastUpdateMs
local updateStatus = "update check pending"
local updateInfo = nil
local screenMode = "main"

local hostUpdateInProgress = false
local hostUpdateWaitTimer = nil
local isCheckingUpdates = false

local updatePrompt = {
  visible = false,
  latest_version = nil,
  show_never_option = false,
}

local PALETTE_ROLES = { "bg", "panel", "header", "accent", "text", "dim", "good", "warn" }
local paletteState = { selectedRole = 1 }

local refreshUpdateState
local installAvailableUpdate

local function clear()
  term.clear()
  term.setCursorPos(1, 1)
end

local function adjustVolume(deltaPercent) audio.adjustVolumePercent(deltaPercent) end
local function adjustRemindLaterMinutes(deltaMinutes) settings.adjustRemindLaterMinutes(deltaMinutes) end

refreshUpdateState = function(statusOverride)
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
    if settings.getAutoUpdate() then installAvailableUpdate(true); return end
    updateStatus = ("update available: %s -> %s"):format(result.current_version, result.latest_version)
    updatePrompt.visible = settings.shouldPromptForVersion(result.latest_version)
    updatePrompt.latest_version = result.latest_version
    updatePrompt.show_never_option = settings.shouldShowNeverOption()
  else
    updateStatus = ("up to date (%s)"):format(result.current_version)
    updatePrompt.visible = false
    updatePrompt.latest_version = nil
    updatePrompt.show_never_option = settings.shouldShowNeverOption()
  end
end

local function remindAboutUpdateLater()
  settings.remindLater(); updatePrompt.visible = false
  if updateInfo and updateInfo.latest_version then updateStatus = ("update available: %s (remind later)"):format(updateInfo.latest_version) end
end

local function neverShowThisUpdate()
  if updateInfo and updateInfo.latest_version and settings.shouldShowNeverOption() then
    settings.ignoreVersion(updateInfo.latest_version); updatePrompt.visible = false
    updateStatus = ("ignored update %s"):format(updateInfo.latest_version)
  end
end

installAvailableUpdate = function(isAuto)
  local result, err = updater.applyLocalUpdate()
  if not result then
    updateStatus = ("local update failed (%s)"):format(err or "unknown error")
    updatePrompt.visible = false
    return
  end

  settings.clearReminder(); settings.clearIgnoredVersion()
  updatePrompt.visible = false; updateStatus = result.message
  if result.updated then
    updateInfo = nil; updatePrompt.latest_version = nil
    if isAuto or settings.getAutoUpdate() then
      print("Update installed. Hot-reloading...")
      for k, v in pairs(package.loaded) do
        if k:match("^rednet_radio%.") then package.loaded[k] = nil end
      end
      shell.run(shell.getRunningProgram())
      error("RESTART", 0)
    end
    return
  end
  refreshUpdateState(result.message)
end

local function loadStations()
  local loadedStations, source, err = directory.loadStations(config.directory_url)
  if not loadedStations then return nil, source, err or "unknown error" end
  stations = loadedStations
  return loadedStations, source
end

local function printStationList(source)
  clear()
  print("Rednet Radio\nVersion: " .. version.version)
  print("Directory: " .. (source or "unknown"))
  print("Updates: " .. updateStatus .. "\n")
  if #stations == 0 then print("No stations were found.") else
    for index, station in ipairs(stations) do print(("%d. %s [%s]"):format(index, station.name, station.station_id)) end
  end
  print("\nType a station number or station_id, then press Enter.\nCommands: r = reload directory, q = quit")
end

local function chooseStation()
  while true do
    local loadedStations, source, err = loadStations()
    if not loadedStations then
      clear(); print("Could not load stations: " .. (err or "unknown error"))
      print("Press Enter to retry, or type q to quit."); if read() == "q" then return nil end
    else
      printStationList(source); write("> "); local answer = read()
      if answer == "q" then return nil
      elseif answer ~= "r" then
        local station = directory.findStation(stations, answer)
        if station then return station end
        clear(); print("No station matched."); print("Press Enter to try again."); read()
      end
    end
  end
end

local function renderTunedScreen()
  if hostUpdateInProgress then
    clear()
    print("HOST STATION UPDATE IN PROGRESS")
    print("Please stand by...")
    local device = peripheral.find("monitor")
    if device then
      local w, h = device.getSize()
      device.setBackgroundColor(colors.black)
      device.clear()
      local msg1, msg2 = "HOST STATION UPDATE IN PROGRESS", "Please stand by..."
      device.setCursorPos(math.floor((w - #msg1) / 2) + 1, math.floor(h / 2))
      device.setTextColor(colors.yellow)
      device.write(msg1)
      device.setCursorPos(math.floor((w - #msg2) / 2) + 1, math.floor(h / 2) + 2)
      device.setTextColor(colors.white)
      device.write(msg2)
    end
    return
  end

  clear()
  if screenMode == "settings" then
    local currentSettings = settings.get()
    print("Client Settings\n")
    print(("Installed version: %s"):format(version.version))
    print(("Never button in update prompt: %s"):format(currentSettings.show_never_option and "ON" or "OFF"))
    print(("Remind me later delay: %d minutes"):format(settings.getRemindLaterMinutes()))
    print(("Updates: %s"):format(updateStatus))
    print("Keys: b = back, t = toggle NEVER, v = vis, a = auto-update, - / = = delay, u = update, q = quit")
    monitor.renderClientSettings(audio.getStatusSummary(), currentSettings)
    return
  elseif screenMode == "palette" then
    print("Palette Editor\n")
    print("Editing colours on the monitor.")
    print("Use the monitor to select roles, cycle colours,")
    print("apply presets, and press [BACK] when done.")
    local selectedRoleName = PALETTE_ROLES[paletteState.selectedRole] or "bg"
    monitor.renderPaletteEditor(settings.getPalette(), selectedRoleName)
    return
  end

  print(("Tuned to: %s"):format(currentStation.name))
  print(("Station ID: %s"):format(currentStation.station_id))
  print(("Protocol: %s\n"):format(rednet_api.getStationProtocol(currentStation)))

  if currentSnapshot and currentSnapshot.track then
    local elapsedSeconds = math.floor(util.trackElapsedMilliseconds(currentSnapshot) / 1000)
    local shownElapsed = math.max(0, math.min(elapsedSeconds, currentSnapshot.duration))
    print(("Now Playing: %s - %s"):format(currentSnapshot.track.artist, currentSnapshot.track.title))
    print(("Elapsed: %ss / %ss"):format(shownElapsed, currentSnapshot.duration))
    print(("Track: %d / %d%s"):format(
      currentSnapshot.track_index or 0,
      currentSnapshot.track_count or 0,
      currentSnapshot.shuffle_mode and "  [Shuffle ON]" or ""
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

  print("\nPlayback: " .. audio.getStatusSummary())
  print(("Volume: %d%% / %d%%"):format(audio.getVolumePercent(), audio.getMaxVolumePercent()))
  print(("Updates: %s"):format(updateStatus))
  print(("Last sync: %s"):format(lastUpdateMs and util.formatAge(lastUpdateMs) or "never"))
  print("Keys: q = back, p = ping, r = reload, s = settings, [ / ] = volume")
  print("      n = skip track, x = toggle shuffle")
  print("Debug: d = test host update, e = test EAS alarm")

  if updatePrompt.visible then
    local promptLine = "Update prompt: o = OK, l = remind me later"
    if updatePrompt.show_never_option then
      promptLine = promptLine .. ", n = never"
    end
    print(promptLine)
  end

  monitor.renderClient(
    currentStation, currentSnapshot, audio.getStatusSummary(),
    audio.getVolumePercent(), audio.getMaxVolumePercent(),
    updateStatus, updatePrompt,
    settings.getEnableVisualizer() and audio.getAmplitude() or nil,
    settings.getEnableVisualizer() and audio.getBufferRatio() or nil
  )
end

local function tuneStation(station)
  currentStation = station
  currentSnapshot = nil
  lastUpdateMs = nil
  screenMode = "main"
  audio.stopTrack()

  rednet_api.listenToStation(station)
  rednet_api.requestTune(station, { palette = settings.getPalette() })
  rednet_api.sendPing(station, { palette = settings.getPalette() })
  settings.setLastStationId(station.station_id)

  local function backgroundThread()
    while true do
      local e, p1 = os.pullEvent("run_bg_task")
      if p1 == "check_updates" then
        refreshUpdateState()
        os.queueEvent("bg_task_done")
      end
    end
  end

  local function eventThread()
    local pingTimer        = os.startTimer(config.client_ping_interval_seconds)
    local checkUpdateTimer = os.startTimer(120)
    local clockTimer       = os.startTimer(1)
    local visTimer         = os.startTimer(1.35)
    local visualUpdateTimer = nil
    local debugEasTimer    = nil
    
    renderTunedScreen()

    while true do
      local event, p1, p2, p3 = os.pullEvent()

      if event == "timer" then
        if p1 == pingTimer then
          rednet_api.sendPing(station, { palette = settings.getPalette() })
          pingTimer = os.startTimer(config.client_ping_interval_seconds)
        elseif p1 == checkUpdateTimer then
          if not isCheckingUpdates then
            isCheckingUpdates = true; os.queueEvent("run_bg_task", "check_updates")
          end
          checkUpdateTimer = os.startTimer(60)
        elseif p1 == clockTimer then
          renderTunedScreen(); clockTimer = os.startTimer(1)
        elseif p1 == visTimer then
          if screenMode == "main" and settings.getEnableVisualizer() then
            monitor.updateVisualizerOnly(audio.getAmplitude(), audio.getBufferRatio())
          end
          visTimer = os.startTimer(1.35)
        elseif p1 == visualUpdateTimer then
          os.queueEvent("run_bg_task", "check_updates")
        elseif p1 == debugEasTimer then
          if currentSnapshot then currentSnapshot.eas_active = false; os.queueEvent("audio_sync", currentSnapshot) end
          renderTunedScreen()
        elseif p1 == hostUpdateWaitTimer then
          refreshUpdateState()
          if updateInfo and updateInfo.update_available then installAvailableUpdate(true)
          else
            hostUpdateInProgress = false; renderTunedScreen()
            rednet_api.requestTune(station, { palette = settings.getPalette() })
          end
        end

      elseif event == "bg_task_done" then
        isCheckingUpdates = false
        renderTunedScreen()

      elseif event == "rednet_message" then
        local message, protocol = p2, p3
        if rednet_api.matchesStationProtocol(station, protocol) and rednet_api.isRadioMessage(message) then
          if message.station_id == station.station_id then
            local wasWaiting = (currentSnapshot == nil)

            if message.message_type == "host_updating" then
              hostUpdateInProgress = true; audio.stopTrack(); renderTunedScreen()
              hostUpdateWaitTimer = os.startTimer(10)

            elseif message.message_type == config.message_types.station_info then
              currentStation = util.mergeTables(currentStation, message.station)
              currentSnapshot = message.snapshot or currentSnapshot
              lastUpdateMs = util.nowMilliseconds()
              if not currentSnapshot or not currentSnapshot.eas_active then os.queueEvent("audio_sync", currentSnapshot) end
              if wasWaiting and currentSnapshot then renderTunedScreen() end

            elseif message.message_type == config.message_types.now_playing or message.message_type == config.message_types.sync or message.message_type == config.message_types.announce then
              currentSnapshot = message.snapshot or currentSnapshot
              lastUpdateMs = util.nowMilliseconds()
              os.queueEvent("audio_sync", currentSnapshot)
              if wasWaiting and currentSnapshot then renderTunedScreen() end

            elseif message.message_type == config.message_types.eas_start then
              if currentSnapshot then currentSnapshot.eas_active = true end
              os.queueEvent("audio_eas_start", message); renderTunedScreen() 

            elseif message.message_type == config.message_types.eas_end then
              if currentSnapshot then currentSnapshot.eas_active = false; os.queueEvent("audio_sync", currentSnapshot) end
              renderTunedScreen()
            end
          end
        end

      elseif event == "char" then
        local key = p1
        if key == "q" then return "QUIT"
        elseif screenMode == "settings" then
          if key == "b" then screenMode = "main"
          elseif key == "t" then settings.toggleShowNeverOption(); os.queueEvent("run_bg_task", "check_updates")
          elseif key == "v" then settings.toggleEnableVisualizer()
          elseif key == "a" then settings.toggleAutoUpdate()
          elseif key == "u" then rednet_api.sendPing(station, { palette = settings.getPalette(), is_update_signal = true }); installAvailableUpdate()
          end
          renderTunedScreen()
        elseif updatePrompt.visible then
          if key == "o" then rednet_api.sendPing(station, { palette = settings.getPalette(), is_update_signal = true }); installAvailableUpdate()
          elseif key == "l" then remindAboutUpdateLater()
          elseif key == "s" then screenMode = "settings"
          end
          renderTunedScreen()
        else
          if key == "p" then rednet_api.sendPing(station, { palette = settings.getPalette() })
          elseif key == "n" then rednet_api.requestSkip(currentStation)
          elseif key == "x" then rednet_api.requestShuffleToggle(currentStation)
          elseif key == "s" then screenMode = "settings"; paletteState.selectedRole = 1
          elseif key == "[" then adjustVolume(-audio.getVolumeStepPercent())
          elseif key == "]" then adjustVolume(audio.getVolumeStepPercent())
          elseif key == "d" then 
            hostUpdateInProgress = true; audio.stopTrack(); renderTunedScreen()
            hostUpdateWaitTimer = os.startTimer(10)
          elseif key == "e" then
            if currentSnapshot then currentSnapshot.eas_active = true end
            os.queueEvent("audio_eas_start", { volume = 3 }); renderTunedScreen()
            debugEasTimer = os.startTimer(5)
          end
          renderTunedScreen()
        end

      elseif event == "monitor_touch" then
        local action = monitor.getClientTouchAction(p1, p2, p3, screenMode, updatePrompt, util.mergeTables(settings.get(), { palette = settings.getPalette() }))
        if action == "volume_down" then adjustVolume(-audio.getVolumeStepPercent())
        elseif action == "volume_up" then adjustVolume(audio.getVolumeStepPercent())
        elseif action == "open_settings" then screenMode = "settings"
        elseif action == "settings_back" then screenMode = "main"
        elseif action == "toggle_never_option" then settings.toggleShowNeverOption(); os.queueEvent("run_bg_task", "check_updates")
        elseif action == "toggle_visualizer" then settings.toggleEnableVisualizer()
        elseif action == "toggle_auto_update" then settings.toggleAutoUpdate()
        
        elseif action == "check_updates" then 
          if not isCheckingUpdates then
            isCheckingUpdates = true; updateStatus = "Checking for updates..."; renderTunedScreen()
            visualUpdateTimer = os.startTimer(1)
          end
        elseif action == "update_now" or action == "update_ok" then 
          rednet_api.sendPing(currentStation, { palette = settings.getPalette(), is_update_signal = true }); installAvailableUpdate()
        elseif action == "update_auto" then 
          settings.setAutoUpdate(true); rednet_api.sendPing(currentStation, { palette = settings.getPalette(), is_update_signal = true }); installAvailableUpdate(true)
        elseif action == "update_later" then remindAboutUpdateLater()
        elseif action == "skip_track" then rednet_api.requestSkip(currentStation)
        elseif action == "toggle_shuffle" then rednet_api.requestShuffleToggle(currentStation)
        elseif action == "open_palette" then screenMode = "palette"; paletteState.selectedRole = 1
        elseif action == "update_never" then neverShowThisUpdate()
        else
          local selRole = action and action:match("^palette_select_(.+)$")
          if selRole then for i, r in ipairs(PALETTE_ROLES) do if r == selRole then paletteState.selectedRole = i; break end end end
        end
        renderTunedScreen()
      elseif event == "key" then if p1 == keys.backspace then return "QUIT" end end
    end
  end

  local function audioThread()
    local easTimer = nil
    local easChunksPlayed = 0
    local combinedChunk = nil
    local isEasPlaying = false
    
    while true do
      local event, p1, p2, p3 = os.pullEvent()
      if event == "speaker_audio_empty" then audio.handleEvent(event, p1, p2, p3)
      elseif event == "timer" and p1 == easTimer then
        if isEasPlaying then
          local speaker = peripheral.find("speaker")
          if speaker then
            speaker.playAudio(combinedChunk)
            easChunksPlayed = easChunksPlayed + 1
            if easChunksPlayed < 10 then easTimer = os.startTimer(0.45)
            else
              isEasPlaying = false; easTimer = nil
              if currentSnapshot then os.queueEvent("audio_sync", currentSnapshot) end
            end
          else
            isEasPlaying = false; easTimer = nil
          end
        end
      elseif event == "audio_sync" then
        local snapshot = p1
        if not (snapshot and snapshot.eas_active) then
           if isEasPlaying then
             isEasPlaying = false; if easTimer then os.cancelTimer(easTimer) end
             local speaker = peripheral.find("speaker")
             if speaker and speaker.stop then speaker.stop() end
           end
           audio.syncToSnapshot(snapshot)
        end
      elseif event == "audio_eas_start" then
        local message = p1
        audio.stopTrack(); local speaker = peripheral.find("speaker")
        if speaker then
          if speaker.stop then speaker.stop() end 
          local vol = math.min(1, (message.volume or 3) / 3)
          local volScaled = 126 * vol
          combinedChunk = {}
          local step1, step2 = (2 * math.pi * 880) / 48000, (2 * math.pi * 440) / 48000
          for i = 1, 12000 do combinedChunk[i] = math.floor(math.sin(i * step1) * volScaled + 0.5) end
          for i = 1, 12000 do combinedChunk[i + 12000] = math.floor(math.sin(i * step2) * volScaled + 0.5) end
          
          isEasPlaying = true; easChunksPlayed = 1
          speaker.playAudio(combinedChunk)
          easTimer = os.startTimer(0.45)
        end
      end
    end
  end

  parallel.waitForAny(eventThread, backgroundThread, audioThread)
end

local function main()
  if rednet_api.openModems() == 0 then error("No modem found.") end
  settings.load()
  monitor.setPalette(settings.getPalette())
  refreshUpdateState()

  local lastStationId = settings.getLastStationId()
  if lastStationId then
    local loadedStations = loadStations()
    if loadedStations then
      local station = directory.findStation(loadedStations, lastStationId)
      if station then tuneStation(station) end
    end
  end

  while true do
    local station = chooseStation()
    if not station then clear(); print("Goodbye."); return end
    tuneStation(station)
  end
end

local ok, err = xpcall(main, function(message)
  if message == "RESTART" then return "RESTART" end
  return debug and debug.traceback and debug.traceback(message, 2) or tostring(message)
end)

audio.stopTrack()
if not ok and err ~= "RESTART" then print("radio_client failed:\n" .. err); os.pullEvent("key") end