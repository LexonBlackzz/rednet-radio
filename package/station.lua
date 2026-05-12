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
  self.shuffle_mode = false
  self.shuffle_bag = {} -- Initialize the empty shuffle bag
  self:setPlaylist(playlistDoc, true)
  return self
end

function Station:setPlaylist(playlistDoc, isFirstLoad)
  local previousTrack = self:getCurrentTrack()
  self.playlist = playlistDoc
  self.tracks = playlistDoc.tracks or {}
  self.playlist_version = playlistDoc.version
  
  -- Reset the shuffle bag when the playlist updates
  self.shuffle_bag = {}

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

-- Helper method to refill the bag with unplayed tracks
function Station:_refillShuffleBag()
  self.shuffle_bag = {}
  for i = 1, #self.tracks do
    table.insert(self.shuffle_bag, i)
  end

  -- If we have more than 1 track, remove the currently playing track from the new bag
  -- so it doesn't immediately repeat as the first song of the next rotation.
  if #self.tracks > 1 and self.current_index > 0 then
    for i, idx in ipairs(self.shuffle_bag) do
      if idx == self.current_index then
        table.remove(self.shuffle_bag, i)
        break
      end
    end
  end
end

function Station:advanceTrack(nowMs)
  if #self.tracks == 0 then
    return false
  end

  if self.shuffle_mode then
    -- If the bag is empty (or hasn't been created yet), refill it
    if not self.shuffle_bag or #self.shuffle_bag == 0 then
      self:_refillShuffleBag()
    end
    
    -- Pick a random position inside the bag
    local bagPos = math.random(1, #self.shuffle_bag)
    
    -- Set current track to the pulled index, then remove it from the bag
    self.current_index = self.shuffle_bag[bagPos]
    table.remove(self.shuffle_bag, bagPos)
  else
    self.current_index = self.current_index + 1
    if self.current_index > #self.tracks then
      self.current_index = 1
    end
  end
  
  local startBufferMs = (config.track_start_buffer_seconds or 0) * 1000
  self.started_at_ms = (nowMs or util.nowMilliseconds()) + startBufferMs
  return true
end

function Station:toggleShuffle()
  self.shuffle_mode = not self.shuffle_mode
  if self.shuffle_mode then
    -- Clear the bag when shuffle is turned on so it builds a fresh list
    self.shuffle_bag = {} 
  end
  return self.shuffle_mode
end

function Station:update(nowMs)
  local track = self:getCurrentTrack()
  if not track then
    return false
  end

  local changed = false
  local trackWindowMs = (track.duration + (config.track_gap_seconds or 0)) * 1000
  
  -- prevent infinite loop if track duration is missing or 0
  if trackWindowMs <= 0 then trackWindowMs = 1000 end 
  
  while nowMs >= self.started_at_ms + trackWindowMs do
    self:advanceTrack(self.started_at_ms + trackWindowMs)
    track = self:getCurrentTrack()
    changed = true
    if not track then
      break
    end
    trackWindowMs = (track.duration + (config.track_gap_seconds or 0)) * 1000
	if trackWindowMs <= 0 then trackWindowMs = 1000 end
  end

  return changed
end

function Station:offsetStartTime(offsetMs)
  self.started_at_ms = (self.started_at_ms or util.nowMilliseconds()) + offsetMs
end

function Station:getSnapshot()
  local track = self:getCurrentTrack()
  local elapsed_ms = track and (util.nowMilliseconds() - (self.started_at_ms or util.nowMilliseconds())) or 0
  local duration_ms = track and (track.duration * 1000) or 0
  local gap_ms = (config.track_gap_seconds or 0) * 1000
  local in_gap = track and elapsed_ms >= duration_ms or false
  return {
    playlist_version = self.playlist_version,
    started_at_ms = self.started_at_ms,
    track_index = self.current_index,
    track_count = #self.tracks,
    duration = track and track.duration or 0,
    gap_seconds = config.track_gap_seconds or 0,
    in_gap = in_gap,
    shuffle_mode = self.shuffle_mode,
    track = track,
  }
end

return Station