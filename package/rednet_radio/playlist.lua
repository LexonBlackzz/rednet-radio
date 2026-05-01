local config = require("rednet_radio.config")
local util = require("rednet_radio.util")

local playlist = {}

local function getCachePath(stationId)
  util.ensureDir(config.cache_dir)
  local playlistDir = fs.combine(config.cache_dir, "playlists")
  util.ensureDir(playlistDir)
  return fs.combine(playlistDir, ("%s.json"):format(util.sanitizeId(stationId)))
end

local function normalizeTrack(track)
  if type(track) ~= "table" then
    return nil, "Track entry is not an object"
  end

  if not util.isNonEmptyString(track.id) then
    return nil, "Track is missing id"
  end

  if not util.isNonEmptyString(track.title) then
    return nil, ("Track '%s' is missing title"):format(track.id)
  end

  if not util.isNonEmptyString(track.artist) then
    return nil, ("Track '%s' is missing artist"):format(track.id)
  end

  if not util.isPositiveNumber(track.duration) then
    return nil, ("Track '%s' has invalid duration"):format(track.id)
  end

  if track.source_url ~= nil and type(track.source_url) ~= "string" then
    return nil, ("Track '%s' has invalid source_url"):format(track.id)
  end

  if track.art_url ~= nil and type(track.art_url) ~= "string" then
    return nil, ("Track '%s' has invalid art_url"):format(track.id)
  end

  if track.playback_url ~= nil and type(track.playback_url) ~= "string" then
    return nil, ("Track '%s' has invalid playback_url"):format(track.id)
  end

  return {
    id = track.id,
    title = track.title,
    artist = track.artist,
    source_url = track.source_url or "",
    art_url = track.art_url,
    duration = track.duration,
    playback_url = track.playback_url,
  }
end

function playlist.loadPlaylist(stationId, url, fallbackName)
  local decoded, source, err = util.fetchJson(url, getCachePath(stationId))
  if not decoded then
    return nil, source, err
  end

  local trackItems = decoded
  local playlistName = fallbackName or stationId
  local version = tostring(util.nowMilliseconds())

  if decoded.playlist and type(decoded.playlist) == "table" then
    decoded = decoded.playlist
  end

  if decoded.tracks then
    trackItems = decoded.tracks
    playlistName = decoded.name or playlistName
    version = tostring(decoded.version or version)
  end

  if type(trackItems) ~= "table" then
    return nil, nil, "Playlist must be an array or object with a tracks array"
  end

  local tracks = {}
  for _, item in ipairs(trackItems) do
    local normalized = normalizeTrack(item)
    if normalized then
      table.insert(tracks, normalized)
    end
  end

  if #tracks == 0 then
    return nil, nil, ("Playlist '%s' contains no valid tracks"):format(playlistName)
  end

  return {
    name = playlistName,
    version = version,
    tracks = tracks,
  }, source
end

return playlist
