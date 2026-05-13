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

  if not stationId or stationId == "" then print("Usage: radio_host <station_id>"); return end

  local function loadStationDefinition()
    local stations, source, err = directory.loadStations(config.directory_url)
    if not stations then return nil, err or "unknown error" end
    for _, station in ipairs(stations) do
      if station.station_id == stationId then return station, source end
    end
    return nil, ("Station '%s' not found"):format(stationId)
  end

  local function loadPlaylist(stationDefinition)
    local playlistDoc, source, err = playlist.loadPlaylist(
      stationDefinition.station_id, stationDefinition.playlist_url, stationDefinition.name
    )
    if not playlistDoc then return nil, err or "unknown error" end
    return playlistDoc, source
  end

  if rednet_api.openModems() == 0 then error("No modem found.") end

  local stationDefinition, defErr = loadStationDefinition()
  if not stationDefinition then error(defErr) end

  local playlistDoc, playErr = loadPlaylist(stationDefinition)
  if not playlistDoc then error(playErr) end

  local stationRuntime = station_module.new(stationDefinition, playlistDoc)
  settings.load()
  monitor.setPalette(settings.getPalette())
  rednet_api.hostStation(stationDefinition)

  log(("Hosting station '%s'"):format(stationDefinition.name))
  local screenMode = "main"
  local playlistSourceOrErr = playErr

  local timers = {}
  local function schedule(name, seconds)
    timers[os.startTimer(seconds)] = name
  end
  
  rednet_api.broadcastAnnounce(stationDefinition, stationRuntime:getSnapshot())
  rednet_api.broadcastNowPlaying(stationDefinition, stationRuntime:getSnapshot())

  local easActive, easPlaying, easStartTime = false, false, nil
  local updateStatus = "Checking for updates..."
  local hostVisualUpdateTimer = nil

  local function getHostSnapshot()
    local snapshot = stationRuntime:getSnapshot()
    snapshot.allow_remote_skip = settings.getAllowRemoteSkip()
    snapshot.allow_remote_shuffle = settings.getAllowRemoteShuffle()
    snapshot.eas_active = easPlaying
    return snapshot
  end

  local function renderScreen()
    if screenMode == "main" then
      monitor.renderHost(stationDefinition, getHostSnapshot(), playlistSourceOrErr, updateStatus)
    else
      monitor.renderHostSettings(stationDefinition.name, settings.getAllowRemoteSkip(), settings.getAllowRemoteShuffle(), settings.getEnableRedstoneAnnouncement(), settings.getAnnouncementRedstoneSide())
    end
  end

  local function startAnnouncement()
    if easPlaying then return end
    log("Announcement Triggered")
    easStartTime = util.nowMilliseconds()
    rednet_api.broadcastMessage(stationDefinition, { message_type = config.message_types.eas_start, alarm_seconds = 5, volume = 3 })
    easPlaying = true; schedule("eas_finish", 5)
  end

  local function stopAnnouncement()
    log("Announcement ended")
    rednet_api.broadcastMessage(stationDefinition, { message_type = config.message_types.eas_end })
    rednet_api.broadcastNowPlaying(stationDefinition, getHostSnapshot())
  end

  local function installAvailableUpdate()
    log("Update initiated. Broadcasting host_updating to clients...")
    rednet_api.broadcastMessage(stationDefinition, { message_type = "host_updating" })
    os.sleep(1)

    local result, err = updater.applyLocalUpdate()
    if not result then
      updateStatus = ("local update failed (%s)"):format(err or "unknown error")
      return
    end

    updateStatus = result.message
    if result.updated then
        log("Update installed. Hot-reloading...")
        for k, v in pairs(package.loaded) do
          if k:match("^rednet_radio%.") then package.loaded[k] = nil end
        end
        error("RESTART", 0)
    end
  end

  -- BACKGROUND WORKER: Runs http.get safely!
  local function backgroundThread()
    while true do
      local e, task, reason = os.pullEvent("run_bg_task")
      if task == "updates" then
        local result, err = updater.check()
        os.queueEvent("bg_task_done", "updates", reason, result, err)
      elseif task == "directory" then
        local def, src = loadStationDefinition()
        os.queueEvent("bg_task_done", "directory", def, src)
      elseif task == "playlist" then
        local play, src = loadPlaylist(stationDefinition)
        os.queueEvent("bg_task_done", "playlist", play, src)
      end
    end
  end

  -- MAIN EVENT LOOP
  local function mainEventLoop()
    schedule("tick", 1); schedule("sync", config.sync_interval_seconds); schedule("announce", config.announce_interval_seconds)
    schedule("check_updates", 1)
    if (config.directory_refresh_seconds or 0) > 0 then schedule("refresh_directory", config.directory_refresh_seconds) end
    if (config.playlist_refresh_seconds or 0) > 0 then schedule("refresh_playlist", config.playlist_refresh_seconds) end

    while true do
      local event, p1, p2, p3, p4, p5 = os.pullEvent()

      if event == "timer" then
        local timerName = timers[p1]
        if timerName then
          timers[p1] = nil 
          if timerName == "tick" then
            if not easPlaying then
              local changed = stationRuntime:update(util.nowMilliseconds())
              if changed then log("Track advanced"); rednet_api.broadcastNowPlaying(stationDefinition, getHostSnapshot()) end
            else
              rednet_api.broadcastNowPlaying(stationDefinition, getHostSnapshot())
            end
            renderScreen(); schedule("tick", 1)
          elseif timerName == "sync" then
            rednet_api.broadcastSync(stationDefinition, getHostSnapshot()); schedule("sync", config.sync_interval_seconds)
          elseif timerName == "announce" then
            rednet_api.broadcastAnnounce(stationDefinition, getHostSnapshot()); schedule("announce", config.announce_interval_seconds)
          elseif timerName == "eas_finish" then
            log("EAS alarm finished. Resuming music.")
            if easStartTime then stationRuntime:offsetStartTime(util.nowMilliseconds() - easStartTime) end
            easPlaying = false
            stopAnnouncement()
          elseif timerName == "check_updates" then
            os.queueEvent("run_bg_task", "updates", "auto")
            schedule("check_updates", 120)
          elseif timerName == "refresh_directory" then
            os.queueEvent("run_bg_task", "directory")
            schedule("refresh_directory", config.directory_refresh_seconds or 300)
          elseif timerName == "refresh_playlist" then
            os.queueEvent("run_bg_task", "playlist")
            schedule("refresh_playlist", config.playlist_refresh_seconds or 300)
          end
        elseif p1 == hostVisualUpdateTimer then
          os.queueEvent("run_bg_task", "updates", "manual")
        end

      elseif event == "bg_task_done" then
        local task, arg1, arg2, arg3 = p1, p2, p3, p4
        if task == "updates" then
          local reason, result, err = arg1, arg2, arg3
          if result then
            if result.update_available then
              updateStatus = ("update available: %s -> %s"):format(result.current_version, result.latest_version)
            else
              updateStatus = ("up to date (%s)"):format(result.current_version)
            end
          else
            updateStatus = ("update check failed (%s)"):format(err or "unknown error")
          end
          renderScreen()
          if reason == "manual" and result and result.update_available then
            updateStatus = "Update available! Installing..."
            renderScreen()
            installAvailableUpdate()
          end
        elseif task == "directory" then
          if arg1 then stationDefinition = util.mergeTables(stationDefinition, arg1); rednet_api.hostStation(stationDefinition) end
        elseif task == "playlist" then
          if arg1 then
            if stationRuntime:setPlaylist(arg1) then rednet_api.broadcastNowPlaying(stationDefinition, getHostSnapshot()) end
            playlistSourceOrErr = arg2
          end
        end

      elseif event == "redstone" then
        local currentSide = settings.getAnnouncementRedstoneSide()
        if settings.getEnableRedstoneAnnouncement() then
          local signal = rs.getInput(currentSide)
          if signal and not easActive then easActive = true; startAnnouncement()
          elseif not signal and easActive then easActive = false; stopAnnouncement() end
        end

      elseif event == "rednet_message" then
        local senderId, message, protocol = p1, p2, p3
        if rednet_api.acceptsProtocol(stationDefinition, protocol) and rednet_api.isRadioMessage(message) then
          if message.palette then settings.setPalette(message.palette); monitor.setPalette(message.palette) end
          
          if message.message_type == config.message_types.ping or message.message_type == config.message_types.tune_request then
            if message.is_update_signal then os.queueEvent("run_bg_task", "updates", "manual") end
            rednet_api.sendStationInfo(senderId, stationDefinition, getHostSnapshot())
            if message.message_type == config.message_types.tune_request then
              rednet_api.sendNowPlaying(senderId, stationDefinition, getHostSnapshot())
            end
          elseif message.message_type == config.message_types.skip_request and settings.getAllowRemoteSkip() then
            stationRuntime:advanceTrack(util.nowMilliseconds()); rednet_api.broadcastNowPlaying(stationDefinition, getHostSnapshot()); renderScreen()
          elseif message.message_type == config.message_types.shuffle_request and settings.getAllowRemoteShuffle() then
            stationRuntime:toggleShuffle(); rednet_api.broadcastNowPlaying(stationDefinition, getHostSnapshot()); renderScreen()
          end
        end

      elseif event == "monitor_touch" then
        local action = monitor.getHostTouchAction(
          p2, p3, screenMode,
          settings.getAllowRemoteSkip(), settings.getAllowRemoteShuffle(),
          settings.getEnableRedstoneAnnouncement(), settings.getAnnouncementRedstoneSide()
        )
        if action == "open_settings" then screenMode = "settings"
        elseif action == "settings_back" then screenMode = "main"
        elseif action == "toggle_remote_skip" then settings.toggleAllowRemoteSkip()
        elseif action == "toggle_remote_shuffle" then settings.toggleAllowRemoteShuffle()
        elseif action == "toggle_eas" then settings.toggleEnableRedstoneAnnouncement()
        elseif action == "cycle_eas_side" then settings.cycleAnnouncementRedstoneSide()
        elseif action == "check_updates" then 
          updateStatus = "Checking for updates..."
          renderScreen()
          hostVisualUpdateTimer = os.startTimer(1) 
        end
        renderScreen()
      end
    end
  end

  parallel.waitForAny(mainEventLoop, backgroundThread)
end

local function relaunchCurrentProgram(args)
  for key in pairs(package.loaded) do
    if key:match("^rednet_radio%.") then
      package.loaded[key] = nil
    end
  end

  if shell and shell.getRunningProgram then
    local program = shell.getRunningProgram()
    if program and program ~= "" then
      return os.run(_ENV, program, table.unpack(args or {}))
    end
  end

  os.reboot()
end

local launchArgs = { ... }
while true do
  local ok, err = xpcall(function() main(table.unpack(launchArgs)) end, function(message)
    if message == "RESTART" then return "RESTART" end
    return debug and debug.traceback and debug.traceback(message, 2) or tostring(message)
  end)

  if not ok and err == "RESTART" then
    print("\n--- Reloading ---")
    os.sleep(0.5)
    return relaunchCurrentProgram(launchArgs)
  elseif not ok then
    print("radio_host failed:\n" .. tostring(err))
    break
  else
    break
  end
end
