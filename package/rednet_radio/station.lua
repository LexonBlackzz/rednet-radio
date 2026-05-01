local config = require("rednet_radio.config")
local util = require("rednet_radio.util")

local Station = {}
Station.__index = Station

local function clampTrackIndex(index, trackCount)
  if trackCount <= 0 then
    return 0
  end

  if index < 1 then
    return 1
  end

  if index > trackCount then
    return 1
  end

  return index
end

function Station.new(stationDefinition, playlistDoc)
  local self = setmetatable({}, Station)
  self.definition = stationDefinition
  self.tracks = {}
  self.current_index = 0
  self:setPlaylist(playlistDoc, true)
  return self
end

function Station:setPlaylist(playlistDoc, isFirstLoad)
  local previousTrack = self:getCurrentTrack()
  self.playlist = playlistDoc
  self.tracks = playlistDoc.tracks or {}
  self.playlist_version = playlistDoc.version

  if #self.tracks == 0 then
    self.current_index = 0
    self.started_at_ms = util.nowMilliseconds()
    return true
  end

  local preservedIndex = 1
  if previousTrack then
    for index, track in ipairs(self.tracks) do
      if track.id == previousTrack.id then
        preservedIndex = index
        break
      end
    end
  end

  self.current_index = clampTrackIndex(self.current_index or preservedIndex, #self.tracks)
  self.started_at_ms = self.started_at_ms or util.nowMilliseconds()

  if isFirstLoad then
    self.current_index = 1
    self.started_at_ms = util.nowMilliseconds()
  end

  return true
end

function Station:getCurrentTrack()
  if not self.tracks or not self.current_index or self.current_index < 1 then
    return nil
  end

  return self.tracks[self.current_index]
end

function Station:advanceTrack(nowMs)
  if #self.tracks == 0 then
    return false
  end

  self.current_index = self.current_index + 1
  if self.current_index > #self.tracks then
    self.current_index = 1
  end
  self.started_at_ms = nowMs or util.nowMilliseconds()
  return true
end

function Station:update(nowMs)
  local track = self:getCurrentTrack()
  if not track then
    return false
  end

  local changed = false
  local trackWindowMs = (track.duration + (config.track_gap_seconds or 0)) * 1000
  while nowMs >= self.started_at_ms + trackWindowMs do
    self:advanceTrack(self.started_at_ms + trackWindowMs)
    track = self:getCurrentTrack()
    changed = true
    if not track then
      break
    end
    trackWindowMs = (track.duration + (config.track_gap_seconds or 0)) * 1000
  end

  return changed
end

function Station:getSnapshot()
  local track = self:getCurrentTrack()
  local elapsed_ms = track and math.max(0, util.nowMilliseconds() - (self.started_at_ms or util.nowMilliseconds())) or 0
  local duration_ms = track and (track.duration * 1000) or 0
  local gap_ms = (config.track_gap_seconds or 0) * 1000
  local in_gap = track and elapsed_ms >= duration_ms and elapsed_ms < (duration_ms + gap_ms) or false
  return {
    playlist_version = self.playlist_version,
    started_at_ms = self.started_at_ms,
    track_index = self.current_index,
    duration = track and track.duration or 0,
    gap_seconds = config.track_gap_seconds or 0,
    in_gap = in_gap,
    track = track,
  }
end

return Station
