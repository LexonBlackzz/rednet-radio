local config = require("rednet_radio.config")
local util = require("rednet_radio.util")

local directory = {}

local function cachePath()
  util.ensureDir(config.cache_dir)
  return fs.combine(config.cache_dir, "stations.json")
end

local function validateStation(station)
  if type(station) ~= "table" then
    return nil, "Station entry is not an object"
  end

  if not util.isNonEmptyString(station.station_id) then
    return nil, "Station is missing station_id"
  end

  if not util.isNonEmptyString(station.name) then
    return nil, ("Station '%s' is missing name"):format(station.station_id)
  end

  if not util.isNonEmptyString(station.playlist_url) then
    return nil, ("Station '%s' is missing playlist_url"):format(station.station_id)
  end

  return {
    station_id = station.station_id,
    name = station.name,
    description = station.description or "",
    playlist_url = station.playlist_url,
    rednet_channel = station.rednet_channel,
    host_label = station.host_label,
  }
end

function directory.loadStations(url)
  local decoded, source, err = util.fetchJson(url, cachePath())
  if not decoded then
    return nil, source, err
  end

  local items = decoded
  if decoded.stations then
    items = decoded.stations
  end

  if type(items) ~= "table" then
    return nil, nil, "stations.json must be an array or object with a stations array"
  end

  local valid = {}
  for _, item in ipairs(items) do
    local station = validateStation(item)
    if station then
      table.insert(valid, station)
    end
  end

  return valid, source
end

function directory.findStation(stations, query)
  local index = tonumber(query)
  if index and stations[index] then
    return stations[index]
  end

  for _, station in ipairs(stations or {}) do
    if station.station_id == query or station.name == query then
      return station
    end
  end

  return nil
end

return directory
