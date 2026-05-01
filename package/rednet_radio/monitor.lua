local util = require("rednet_radio.util")

local monitor = {}

local state = {
  device = nil,
  scale = 0.5,
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

local function writeLines(target, lines)
  if not target then
    return
  end

  target.setBackgroundColor(colors.black)
  target.setTextColor(colors.white)
  target.clear()
  target.setCursorPos(1, 1)

  for index, line in ipairs(lines) do
    local width = select(1, target.getSize())
    local text = tostring(line or "")
    if #text > width then
      text = text:sub(1, width)
    end

    target.setCursorPos(1, index)
    target.write(text)
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

  local lines = {
    "Rednet Radio",
    "",
  }

  if station then
    lines[#lines + 1] = station.name
    lines[#lines + 1] = station.station_id
  else
    lines[#lines + 1] = "No station selected"
  end

  lines[#lines + 1] = ""

  if snapshot and snapshot.track then
    local elapsed = math.floor(util.trackElapsedMilliseconds(snapshot) / 1000)
    lines[#lines + 1] = snapshot.track.artist or "Unknown Artist"
    lines[#lines + 1] = snapshot.track.title or "Unknown Track"
    lines[#lines + 1] = ("%ss / %ss"):format(elapsed, snapshot.duration or 0)
  else
    lines[#lines + 1] = "Waiting for station..."
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = playbackStatus or "idle"

  writeLines(device, lines)
end

function monitor.renderHost(station, snapshot, playlistSource)
  local device = getMonitor()
  if not device then
    return
  end

  local lines = {
    "Rednet Radio Host",
    "",
    station and station.name or "Unknown station",
    station and station.station_id or "",
    "",
  }

  if snapshot and snapshot.track then
    local elapsed = math.floor(util.trackElapsedMilliseconds(snapshot) / 1000)
    lines[#lines + 1] = snapshot.track.artist or "Unknown Artist"
    lines[#lines + 1] = snapshot.track.title or "Unknown Track"
    lines[#lines + 1] = ("%ss / %ss"):format(elapsed, snapshot.duration or 0)
    lines[#lines + 1] = "Track " .. tostring(snapshot.track_index or 0)
  else
    lines[#lines + 1] = "No track loaded"
  end

  if playlistSource then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Playlist: " .. tostring(playlistSource)
  end

  writeLines(device, lines)
end

return monitor
