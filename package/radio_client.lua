local config = require("rednet_radio.config")
local directory = require("rednet_radio.directory")
local rednet_api = require("rednet_radio.rednet_api")
local util = require("rednet_radio.util")
local audio = require("rednet_radio.audio")
local monitor = require("rednet_radio.monitor")
local settings = require("rednet_radio.settings")
local updater = require("rednet_radio.updater")
local version = require("rednet_radio.version")

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

-- list of palletes to show in the editor
local PALETTE_ROLES = { "bg", "panel", "header", "accent", "text", "dim", "good", "warn" }
local ROLE_LABELS   = {
  bg     = "Background",
  panel  = "Panel",
  header = "Header",
  accent = "Accent",
  text   = "Text",
  dim    = "Dim Text",
  good   = "Good/Active",
  warn   = "Warning",
}
-- colors in order (i think)
local COLOR_LIST = {
  { name = "white",     value = 1     },
  { name = "orange",    value = 2     },
  { name = "magenta",   value = 4     },
  { name = "lightBlue", value = 8     },
  { name = "yellow",    value = 16    },
  { name = "lime",      value = 32    },
  { name = "pink",      value = 64    },
  { name = "gray",      value = 128   },
  { name = "lightGray", value = 256   },
  { name = "cyan",      value = 512   },
  { name = "purple",    value = 1024  },
  { name = "blue",      value = 2048  },
  { name = "brown",     value = 4096  },
  { name = "green",     value = 8192  },
  { name = "red",       value = 16384 },
  { name = "black",     value = 32768 },
}
local paletteState = { selectedRole = 1 }

local refreshUpdateState
local installAvailableUpdate

local function clear()
  term.clear()
  term.setCursorPos(1, 1)
end

local function adjustVolume(deltaPercent)
  audio.adjustVolumePercent(deltaPercent)
end

local function adjustRemindLaterMinutes(deltaMinutes)
  settings.adjustRemindLaterMinutes(deltaMinutes)
end

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
    if settings.getAutoUpdate() then
      installAvailableUpdate(true)
      return
    end
    updateStatus = ("update available: %s -> %s"):format(
      result.current_version,
      result.latest_version
    )
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

installAvailableUpdate = function(isAuto)
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
    if isAuto or settings.getAutoUpdate() then
      -- Hot reload
      print("Update installed. Hot-reloading...")
      for k, v in pairs(package.loaded) do
        if k:match("^rednet_radio%.") then
          package.loaded[k] = nil
        end
      end
      shell.run(shell.getRunningProgram())
      error("RESTART", 0) -- terminate current execution
    end
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
  print(("Version: %s"):format(version.version))
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
-- pallete editor
local function renderTunedScreen()
  clear()
  if screenMode == "settings" then
    local currentSettings = settings.get()
    print("Client Settings")
    print("")
    print(("Installed version: %s"):format(version.version))
    print(("Never button in update prompt: %s"):format(
      currentSettings.show_never_option and "ON" or "OFF"
    ))
    print(("Remind me later delay: %d minutes"):format(settings.getRemindLaterMinutes()))
    print(("Updates: %s"):format(updateStatus))
    print("Keys: b = back, t = toggle NEVER, - / = = delay, u = update, q = quit")

    monitor.renderClientSettings(audio.getStatusSummary(), currentSettings)
    return
  end

  if screenMode == "palette" then
    print("Palette Editor")
    print("")
    print("Editing colours on the monitor.")
    print("Use the monitor to select roles, cycle colours,")
    print("apply presets, and press [BACK] when done.")
    local selectedRoleName = PALETTE_ROLES[paletteState.selectedRole] or "bg"
    monitor.renderPaletteEditor(settings.getPalette(), selectedRoleName)
    return
  end

  print(("Tuned to: %s"):format(currentStation.name))
  print(("Station ID: %s"):format(currentStation.station_id))
  print(("Protocol: %s"):format(rednet_api.getStationProtocol(currentStation)))
  print("")

  if currentSnapshot and currentSnapshot.track then
    local elapsedSeconds = math.floor(util.trackElapsedMilliseconds(currentSnapshot) / 1000)
    local shownElapsed = math.max(0, math.min(elapsedSeconds, currentSnapshot.duration))
    print(("Now Playing: %s - %s"):format(
      currentSnapshot.track.artist,
      currentSnapshot.track.title
    ))
    print(("Elapsed: %ss / %ss"):format(
      shownElapsed,
      currentSnapshot.duration
    ))
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

  print("")
  print(("Playback: %s"):format(audio.getStatusSummary()))
  print(("Volume: %d%% / %d%%"):format(
    audio.getVolumePercent(),
    audio.getMaxVolumePercent()
  ))
  print(("Updates: %s"):format(updateStatus))
  print(("Last sync: %s"):format(lastUpdateMs and util.formatAge(lastUpdateMs) or "never"))
  print("Keys: q = back, p = ping, r = reload, s = settings, [ / ] = volume")
  print("      n = skip track, x = toggle shuffle")

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
    updatePrompt,
    settings.getEnableVisualizer() and audio.getAmplitude() or nil
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
  settings.setLastStationId(station.station_id)

  -- Renders on a 1-second heartbeat using os.sleep, which yields via its
  -- own internal timer and is completely unaffected by speaker_audio_empty
  -- event spam from DFPWM playback.
  local function renderThread()
    renderTunedScreen()
    while true do
      os.sleep(1)
      renderTunedScreen()
    end
  end

  -- Handles all user input and network messages. Calls renderTunedScreen()
  -- immediately after any state change so the display feels responsive.
  -- Also owns the ping and update-check timers.
  local function eventThread()
    local pingTimer        = os.startTimer(config.client_ping_interval_seconds)
    local checkUpdateTimer = os.startTimer(120)

    while true do
      local event, p1, p2, p3 = os.pullEvent()

      if event == "timer" then
        if p1 == pingTimer then
          rednet_api.sendPing(station)
          pingTimer = os.startTimer(config.client_ping_interval_seconds)
        elseif p1 == checkUpdateTimer then
          refreshUpdateState()
          checkUpdateTimer = os.startTimer(60)
          renderTunedScreen()
        end

      elseif event == "rednet_message" then
        local message  = p2
        local protocol = p3

        if rednet_api.matchesStationProtocol(station, protocol) and rednet_api.isRadioMessage(message) then
          if message.station_id == station.station_id then
            if message.message_type == config.message_types.station_info then
              currentStation = util.mergeTables(currentStation, message.station)
              currentSnapshot = message.snapshot or currentSnapshot
              lastUpdateMs = util.nowMilliseconds()
              os.queueEvent("audio_sync", currentSnapshot)
              renderTunedScreen()
            elseif message.message_type == config.message_types.now_playing
              or message.message_type == config.message_types.sync
              or message.message_type == config.message_types.announce then
              currentSnapshot = message.snapshot or currentSnapshot
              lastUpdateMs = util.nowMilliseconds()
              os.queueEvent("audio_sync", currentSnapshot)
              renderTunedScreen()
            elseif message.message_type == config.message_types.eas_start then
              currentSnapshot.message_prompt = {
                visible = true,
                title = "IMPORTANT ANNOUNCEMENT",
                message = "PLEASE STAND BY..",
                hide_ok = true
              }
              os.queueEvent("audio_eas_start", message)
              renderTunedScreen()
            elseif message.message_type == config.message_types.eas_end then
              currentSnapshot.message_prompt = {
                visible = true,
                title = "NOTICE",
                message = "IMPORTANT ANNOUNCEMENT EXPIRED"
              }
              renderTunedScreen()
            end
          end
        end

      elseif event == "char" then
        local key = p1
        if key == "q" then
          return "QUIT"
        elseif screenMode == "settings" then
          if key == "b" then
            screenMode = "main"
          elseif key == "t" then
            settings.toggleShowNeverOption()
            refreshUpdateState()
          elseif key == "v" then
            settings.toggleEnableVisualizer()
          elseif key == "a" then
            settings.toggleAutoUpdate()
          elseif key == "-" then
            adjustRemindLaterMinutes(-settings.getRemindLaterStepMinutes())
          elseif key == "=" then
            adjustRemindLaterMinutes(settings.getRemindLaterStepMinutes())
          elseif key == "u" then
            installAvailableUpdate()
          end
          renderTunedScreen()
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
          renderTunedScreen()
        else
          if key == "p" then
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
          elseif key == "n" then
            rednet_api.requestSkip(currentStation)
          elseif key == "x" then
            rednet_api.requestShuffleToggle(currentStation)
          elseif key == "s" then
            screenMode = "settings"
            paletteState.selectedRole = 1
          elseif key == "[" then
            adjustVolume(-audio.getVolumeStepPercent())
          elseif key == "]" then
            adjustVolume(audio.getVolumeStepPercent())
          end
          renderTunedScreen()
        end

      elseif event == "monitor_touch" then
        local action = monitor.getClientTouchAction(
          p1,
          p2,
          p3,
          screenMode,
          updatePrompt,
          util.mergeTables(settings.get(), { palette = settings.getPalette() })
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
        elseif action == "toggle_visualizer" then
          settings.toggleEnableVisualizer()
        elseif action == "toggle_auto_update" then
          settings.toggleAutoUpdate()
        elseif action == "remind_delay_down" then
          adjustRemindLaterMinutes(-settings.getRemindLaterStepMinutes())
        elseif action == "remind_delay_up" then
          adjustRemindLaterMinutes(settings.getRemindLaterStepMinutes())
        elseif action == "update_now" then
          installAvailableUpdate()
        elseif action == "check_updates" then
          updateStatus = "Checking for updates..."
          refreshUpdateState()
        elseif action == "update_ok" then
          installAvailableUpdate()
        elseif action == "update_auto" then
          settings.setAutoUpdate(true)
          installAvailableUpdate(true)
        elseif action == "update_later" then
          remindAboutUpdateLater()
        elseif action == "skip_track" then
          if currentSnapshot and currentSnapshot.allow_remote_skip == false then
            currentSnapshot.message_prompt = {
              visible = true,
              title = "Skip not allowed",
              message = "Contact host to enable skipping."
            }
          else
            rednet_api.requestSkip(currentStation)
          end
        elseif action == "toggle_shuffle" then
          if currentSnapshot and currentSnapshot.allow_remote_shuffle == false then
            currentSnapshot.message_prompt = {
              visible = true,
              title = "Shuffle not allowed",
              message = "Contact host to enable shuffling."
            }
          else
            rednet_api.requestShuffleToggle(currentStation)
          end
        elseif action == "message_ok" then
          if currentSnapshot and currentSnapshot.message_prompt then
            currentSnapshot.message_prompt.visible = false
          end
        elseif action == "open_palette" then
          screenMode = "palette"
          paletteState.selectedRole = 1
        elseif action == "update_never" then
          neverShowThisUpdate()
        else
          -- Palette cycling / presets / back...
          local role = action and action:match("^palette_cycle_(.+)$")
          if role then
            local cp  = settings.getPalette()
            local cv  = cp[role] or 1
            local COLOR_LIST_MON = {1,2,4,8,16,32,64,128,256,512,1024,2048,4096,8192,16384,32768}
            local idx = 1
            for ci, v in ipairs(COLOR_LIST_MON) do if v == cv then idx = ci; break end end
            idx = idx + 1; if idx > #COLOR_LIST_MON then idx = 1 end
            settings.setPaletteColor(role, COLOR_LIST_MON[idx])
            monitor.setPalette(settings.getPalette())
          end
          local selRole = action and action:match("^palette_select_(.+)$")
          if selRole then
            for i, r in ipairs(PALETTE_ROLES) do if r == selRole then paletteState.selectedRole = i; break end end
          end
          if action == "palette_prev" or action == "palette_next" then
            local role = PALETTE_ROLES[paletteState.selectedRole] or "bg"
            local cp   = settings.getPalette()
            local cv   = cp[role] or 1
            local vals = {1,2,4,8,16,32,64,128,256,512,1024,2048,4096,8192,16384,32768}
            local idx  = 1
            for ci, v in ipairs(vals) do if v == cv then idx = ci; break end end
            if action == "palette_prev" then idx = idx - 1; if idx < 1 then idx = #vals end else idx = idx + 1; if idx > #vals then idx = 1 end end
            settings.setPaletteColor(role, vals[idx])
            monitor.setPalette(settings.getPalette())
          end
          if action == "preset_default" then settings.applyPreset("default"); monitor.setPalette(settings.getPalette())
          elseif action == "preset_light" then settings.applyPreset("light"); monitor.setPalette(settings.getPalette())
          elseif action == "preset_dark" then settings.applyPreset("dark"); monitor.setPalette(settings.getPalette())
          elseif action == "palette_back" then screenMode = "settings" end
        end
        renderTunedScreen()

      elseif event == "key" then
        if p1 == keys.backspace then
          return "QUIT"
        end
      end
    end
  end

  local function audioThread()
    while true do
      local event, p1, p2, p3 = os.pullEvent()
      if event == "speaker_audio_empty" then
        audio.handleEvent(event)
      elseif event == "audio_sync" then
        audio.syncToSnapshot(p1)
      elseif event == "audio_eas_start" then
        local message = p1
        audio.stopTrack()

        local speaker = peripheral.find("speaker")
        if speaker then
          for i=1, 25 do -- ~5 seconds
            speaker.playSound("minecraft:block.bell.use", 3, 0.5)
            os.sleep(0.1)
            speaker.playSound("minecraft:block.bell.use", 3, 0.8)
            os.sleep(0.1)
          end
        end

        local h = http.get(message.url)
        if h then
          local data = h.readAll()
          h.close()
          audio.playLocalBuffer(data, message.volume or 3)
        end
      end
    end
  end

  parallel.waitForAny(renderThread, eventThread, audioThread)
  audio.stopTrack()
end

local function main()
  if rednet_api.openModems() == 0 then
    error("No modem was found. Attach a modem before running the radio client.")
  end

  settings.load()
  monitor.setPalette(settings.getPalette())
  refreshUpdateState()

  local lastStationId = settings.getLastStationId()
  if lastStationId then
    local loadedStations = loadStations()
    if loadedStations then
      local station = directory.findStation(loadedStations, lastStationId)
      if station then
        tuneStation(station)
      end
    end
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
  if message == "RESTART" then return "RESTART" end
  return debug and debug.traceback and debug.traceback(message, 2) or tostring(message)
end)

audio.stopTrack()

if not ok and err ~= "RESTART" then
  print("radio_client failed:")
  print(err)
  print("")
  print("Press any key to exit.")
  os.pullEvent("key")
end