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

function monitor.hasMonitor()
  return getMonitor() ~= nil
end

function monitor.renderClient(station, snapshot, playbackStatus)
  local device = getMonitor()
  if not device then
    return
  end

  local width, height = drawFrame(device, "Current Broadcast")
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
    if snapshot.in_gap then
      writeAt(device, 3, 15, "INTERMISSION", colors.yellow, palette.panel)
    end
  else
    writeAt(device, 3, 10, "Waiting for station...", colors.white, palette.panel)
  end

  writeAt(device, 3, height - 2, fit(playbackStatus or "idle", width - 6), colors.white, palette.panel)
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
    if snapshot.in_gap then
      writeAt(device, 3, 15, "Holding before next track", colors.yellow, palette.panel)
    end
  else
    writeAt(device, 3, 11, "No track loaded", colors.white, palette.panel)
  end

  if playlistSource then
    writeAt(device, 3, height - 2, fit("Playlist: " .. tostring(playlistSource), width - 6), colors.white, palette.panel)
  end
end

return monitor
