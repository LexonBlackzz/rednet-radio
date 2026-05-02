local util = require("rednet_radio.util")

local monitor = {}

local state = {
  device = nil,
  scale = 0.5,
}

local palette = {
  bg = colors.blue,
  panel = colors.lightBlue,
  header = colors.orange,
  accent = colors.red,
  text = colors.white,
  dim = colors.lightGray,
  good = colors.lime,
  warn = colors.yellow,
}

local function getMonitor()
  state.device = peripheral.find("monitor")
  if state.device and state.device.setTextScale then
    pcall(function()
      state.device.setTextScale(state.scale)
    end)
  end
  return state.device
end

local function fill(target, x, y, width, height, bg, text)
  target.setBackgroundColor(bg)
  target.setTextColor(text or palette.text)
  local blank = string.rep(" ", math.max(0, width))
  for row = 0, height - 1 do
    target.setCursorPos(x, y + row)
    target.write(blank)
  end
end

local function writeAt(target, x, y, text, fg, bg)
  if bg then
    target.setBackgroundColor(bg)
  end
  target.setTextColor(fg or palette.text)
  target.setCursorPos(x, y)
  target.write(text)
end

local function fit(text, width)
  text = tostring(text or "")
  if #text <= width then
    return text
  end
  if width <= 3 then
    return text:sub(1, width)
  end
  return text:sub(1, width - 3) .. "..."
end

local function drawFrame(target, title)
  local width, height = target.getSize()
  fill(target, 1, 1, width, height, palette.bg, palette.text)
  fill(target, 2, 2, width - 2, height - 2, palette.panel, palette.text)
  fill(target, 2, 2, width - 2, 3, palette.header, colors.black)
  fill(target, width - 2, 2, 1, 1, palette.accent, palette.accent)
  writeAt(target, 4, 3, fit(title, width - 8), colors.yellow, palette.header)
  return width, height
end

local function drawProgressBar(target, x, y, width, ratio, fg, bg)
  ratio = math.max(0, math.min(1, ratio or 0))
  local filled = math.floor(width * ratio + 0.5)
  if width <= 0 then
    return
  end
  fill(target, x, y, width, 1, bg or colors.gray)
  if filled > 0 then
    fill(target, x, y, filled, 1, fg or palette.good)
  end
end

local function getClientVolumeButtonLayout(width, height)
  local row = math.max(9, height - 3)
  local minusLabel = "[-]"
  local plusLabel = "[+]"
  local plusX = math.max(3, width - #plusLabel - 2)
  local minusX = math.max(3, plusX - #minusLabel - 1)
  return {
    row = row,
    minusX = minusX,
    minusWidth = #minusLabel,
    plusX = plusX,
    plusWidth = #plusLabel,
    minusLabel = minusLabel,
    plusLabel = plusLabel,
  }
end

local function getClientSettingsButtonLayout(width, height)
  local label = "[SET]"
  return {
    row = height - 2,
    x = math.max(3, width - #label - 2),
    width = #label,
    label = label,
  }
end

local function getSettingsScreenLayout(width, height, showNeverOption, remindLaterMinutes)
  local toggleLabel = showNeverOption and "[ON]" or "[OFF]"
  local reminderDownLabel = "[-]"
  local reminderUpLabel = "[+]"
  local reminderValueLabel = ("%dm"):format(remindLaterMinutes or 60)
  local toggleRow = 10
  local reminderRow = 14
  local backLabel = "[BACK]"
  return {
    toggleRow = toggleRow,
    toggleX = math.max(3, width - #toggleLabel - 3),
    toggleWidth = #toggleLabel,
    toggleLabel = toggleLabel,
    reminderRow = reminderRow,
    reminderDownX = math.max(3, width - (#reminderUpLabel + #reminderValueLabel + #reminderDownLabel + 6)),
    reminderDownLabel = reminderDownLabel,
    reminderValueX = math.max(8, width - (#reminderUpLabel + #reminderValueLabel + 5)),
    reminderValueLabel = reminderValueLabel,
    reminderUpX = math.max(12, width - #reminderUpLabel - 3),
    reminderUpLabel = reminderUpLabel,
    backRow = math.max(reminderRow + 3, height - 2),
    backX = math.max(3, width - #backLabel - 2),
    backWidth = #backLabel,
    backLabel = backLabel,
  }
end

local function getUpdatePromptLayout(width, height, showNeverOption)
  local boxWidth = math.max(24, math.min(width - 6, 30))
  local boxHeight = showNeverOption and 10 or 8
  local x = math.max(3, math.floor((width - boxWidth) / 2) + 1)
  local y = math.max(5, math.floor((height - boxHeight) / 2) + 1)
  return {
    x = x,
    y = y,
    width = boxWidth,
    height = boxHeight,
    ok = {
      x = x + 2,
      y = y + boxHeight - 2,
      label = "[OK]",
    },
    later = {
      x = x + 8,
      y = y + boxHeight - 2,
      label = "[LATER]",
    },
    never = showNeverOption and {
      x = x + 2,
      y = y + boxHeight - 3,
      label = "[NEVER]",
    } or nil,
  }
end

local function hitButton(x, y, button)
  return button
    and y == button.y
    and x >= button.x
    and x < (button.x + #button.label)
end

local function drawUpdatePrompt(target, width, height, prompt)
  if not prompt or not prompt.visible then
    return
  end

  local layout = getUpdatePromptLayout(width, height, prompt.show_never_option)
  fill(target, layout.x, layout.y, layout.width, layout.height, colors.gray, colors.white)
  fill(target, layout.x + 1, layout.y + 1, layout.width - 2, layout.height - 2, colors.white, colors.black)
  writeAt(target, layout.x + 2, layout.y + 1, fit("Update ready", layout.width - 4), colors.black, colors.white)
  writeAt(
    target,
    layout.x + 2,
    layout.y + 3,
    fit(("Version %s is available."):format(prompt.latest_version or "?"), layout.width - 4),
    colors.black,
    colors.white
  )
  writeAt(
    target,
    layout.x + 2,
    layout.y + 4,
    fit("OK installs locally.", layout.width - 4),
    colors.black,
    colors.white
  )
  writeAt(target, layout.ok.x, layout.ok.y, layout.ok.label, colors.black, colors.lightGray)
  writeAt(target, layout.later.x, layout.later.y, layout.later.label, colors.black, colors.lightGray)
  if layout.never then
    writeAt(target, layout.never.x, layout.never.y, layout.never.label, colors.black, colors.lightGray)
  end
end

function monitor.hasMonitor()
  return getMonitor() ~= nil
end

function monitor.renderClient(station, snapshot, playbackStatus, volumePercent, maxVolumePercent, updateStatus, prompt)
  local device = getMonitor()
  if not device then
    return
  end

  local width, height = drawFrame(device, "Current Broadcast")
  local volumeRow = math.max(9, height - 3)
  local controls = getClientVolumeButtonLayout(width, height)
  local settingsButton = getClientSettingsButtonLayout(width, height)
  writeAt(device, 3, 6, fit(station and station.name or "No station selected", width - 6), colors.white, palette.panel)
  writeAt(device, 3, 7, fit(station and station.station_id or "", width - 6), colors.yellow, palette.panel)

  if snapshot and snapshot.track then
    local elapsed = math.floor(util.trackElapsedMilliseconds(snapshot) / 1000)
    local shownElapsed = math.min(elapsed, snapshot.duration or 0)
    local barWidth = math.max(8, width - 8)
    local ratio = (snapshot.duration or 0) > 0 and (shownElapsed / snapshot.duration) or 0
    writeAt(device, 3, 9, fit(snapshot.track.artist or "Unknown Artist", width - 6), colors.white, palette.panel)
    writeAt(device, 3, 10, fit(snapshot.track.title or "Unknown Track", width - 6), colors.cyan, palette.panel)
    drawProgressBar(device, 3, 12, barWidth, ratio, snapshot.in_gap and palette.warn or palette.good, colors.gray)
    writeAt(device, 3, 13, ("%02ds / %02ds"):format(shownElapsed, snapshot.duration or 0), colors.white, palette.panel)
    writeAt(device, 3, 14, ("Track %d / %d"):format(
      snapshot.track_index or 0,
      snapshot.track_count or 0
    ), colors.yellow, palette.panel)
    if snapshot.in_gap then
      writeAt(device, 3, 16, "INTERMISSION", colors.yellow, palette.panel)
    end
  else
    writeAt(device, 3, 10, "Waiting for station...", colors.white, palette.panel)
  end

  writeAt(
    device,
    3,
    volumeRow,
    fit(
      ("Volume: %d%% / %d%%"):format(volumePercent or 100, maxVolumePercent or 300),
      width - 6
    ),
    colors.white,
    palette.panel
  )
  writeAt(device, controls.minusX, controls.row, controls.minusLabel, colors.black, colors.lightGray)
  writeAt(device, controls.plusX, controls.row, controls.plusLabel, colors.black, colors.lightGray)
  writeAt(device, 3, height - 2, fit(updateStatus or playbackStatus or "idle", settingsButton.x - 5), colors.white, palette.panel)
  writeAt(device, settingsButton.x, settingsButton.row, settingsButton.label, colors.black, colors.lightGray)
  drawUpdatePrompt(device, width, height, prompt)
end

function monitor.renderClientSettings(playbackStatus, settingsState)
  local device = getMonitor()
  if not device then
    return
  end

  local width, height = drawFrame(device, "Client Settings")
  local layout = getSettingsScreenLayout(
    width,
    height,
    settingsState and settingsState.show_never_option,
    settingsState and settingsState.remind_later_minutes
  )
  writeAt(device, 3, 6, fit("Update prompt style", width - 6), colors.white, palette.panel)
  writeAt(device, 3, 8, fit("Show optional NEVER button", width - 6), colors.white, palette.panel)
  writeAt(device, layout.toggleX, layout.toggleRow, layout.toggleLabel, colors.black, colors.lightGray)
  writeAt(device, 3, 12, fit("OFF keeps the prompt to OK and LATER only.", width - 6), colors.black, palette.panel)
  writeAt(device, 3, layout.reminderRow, fit("Remind me later delay", width - 6), colors.white, palette.panel)
  writeAt(device, layout.reminderDownX, layout.reminderRow, layout.reminderDownLabel, colors.black, colors.lightGray)
  writeAt(device, layout.reminderValueX, layout.reminderRow, layout.reminderValueLabel, colors.black, palette.panel)
  writeAt(device, layout.reminderUpX, layout.reminderRow, layout.reminderUpLabel, colors.black, colors.lightGray)
  writeAt(device, layout.backX, layout.backRow, layout.backLabel, colors.black, colors.lightGray)
  writeAt(device, 3, height - 2, fit(playbackStatus or "idle", width - 6), colors.white, palette.panel)
end

function monitor.getClientTouchAction(side, x, y, screenMode, prompt, settingsState)
  local device = getMonitor()
  if not device or peripheral.getName(device) ~= side then
    return nil
  end

  local width, height = device.getSize()
  if prompt and prompt.visible and screenMode ~= "settings" then
    local layout = getUpdatePromptLayout(width, height, prompt.show_never_option)
    if hitButton(x, y, layout.ok) then
      return "update_ok"
    end
    if hitButton(x, y, layout.later) then
      return "update_later"
    end
    if hitButton(x, y, layout.never) then
      return "update_never"
    end
    return nil
  end

  if screenMode == "settings" then
    local layout = getSettingsScreenLayout(
      width,
      height,
      settingsState and settingsState.show_never_option,
      settingsState and settingsState.remind_later_minutes
    )
    if hitButton(x, y, {
      x = layout.toggleX,
      y = layout.toggleRow,
      label = layout.toggleLabel,
    }) then
      return "toggle_never_option"
    end
    if hitButton(x, y, {
      x = layout.reminderDownX,
      y = layout.reminderRow,
      label = layout.reminderDownLabel,
    }) then
      return "remind_delay_down"
    end
    if hitButton(x, y, {
      x = layout.reminderUpX,
      y = layout.reminderRow,
      label = layout.reminderUpLabel,
    }) then
      return "remind_delay_up"
    end
    if hitButton(x, y, {
      x = layout.backX,
      y = layout.backRow,
      label = layout.backLabel,
    }) then
      return "settings_back"
    end
    return nil
  end

  local controls = getClientVolumeButtonLayout(width, height)
  if y ~= controls.row then
    local settingsButton = getClientSettingsButtonLayout(width, height)
    if hitButton(x, y, {
      x = settingsButton.x,
      y = settingsButton.row,
      label = settingsButton.label,
    }) then
      return "open_settings"
    end
    return nil
  end

  if x >= controls.minusX and x < (controls.minusX + controls.minusWidth) then
    return "volume_down"
  end

  if x >= controls.plusX and x < (controls.plusX + controls.plusWidth) then
    return "volume_up"
  end

  return nil
end

function monitor.renderHost(station, snapshot, playlistSource)
  local device = getMonitor()
  if not device then
    return
  end

  local width, height = drawFrame(device, "Station Uplink")
  writeAt(device, 3, 6, fit(station and station.name or "Unknown station", width - 6), colors.white, palette.panel)
  writeAt(device, 3, 7, fit(station and station.station_id or "", width - 6), colors.yellow, palette.panel)

  if snapshot and snapshot.track then
    local elapsed = math.floor(util.trackElapsedMilliseconds(snapshot) / 1000)
    local shownElapsed = math.min(elapsed, snapshot.duration or 0)
    local ratio = (snapshot.duration or 0) > 0 and (shownElapsed / snapshot.duration) or 0
    drawProgressBar(device, 3, 10, math.max(8, width - 8), ratio, snapshot.in_gap and palette.warn or palette.good, colors.gray)
    writeAt(device, 3, 12, fit(snapshot.track.artist or "Unknown Artist", width - 6), colors.white, palette.panel)
    writeAt(device, 3, 13, fit(snapshot.track.title or "Unknown Track", width - 6), colors.cyan, palette.panel)
    writeAt(device, 3, 14, ("Track %d  %02ds / %02ds"):format(
      snapshot.track_index or 0,
      shownElapsed,
      snapshot.duration or 0
    ), colors.white, palette.panel)
    writeAt(device, 3, 15, ("Queue %d / %d"):format(
      snapshot.track_index or 0,
      snapshot.track_count or 0
    ), colors.yellow, palette.panel)
    if snapshot.in_gap then
      writeAt(device, 3, 16, "Holding before next track", colors.yellow, palette.panel)
    end
  else
    writeAt(device, 3, 11, "No track loaded", colors.white, palette.panel)
  end

  if playlistSource then
    writeAt(device, 3, height - 2, fit("Playlist: " .. tostring(playlistSource), width - 6), colors.white, palette.panel)
  end
end

return monitor
