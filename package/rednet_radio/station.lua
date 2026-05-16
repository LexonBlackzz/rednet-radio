local config = require("rednet_radio.config")
local util = require("rednet_radio.util")

-- ensures true randomness on every reboot
math.randomseed(os.epoch("utc"))

local Station = {}
Station.__index = Station

local function clampTrackIndex(index, trackCount)
  if trackCount <= 0 then return 0 end
  if index < 1 then return 1 end
  if index > trackCount then return 1 end
  return index
end

local function trackIdForIndex(tracks, index)
  local track = tracks and tracks[index]
  return track and track.id or nil
end

local function indexForTrackId(tracks, trackId)
  if not tracks or not trackId then return nil end
  for index, track in ipairs(tracks) do
    if track.id == trackId then return index end
  end
  return nil
end

function Station.new(stationDefinition, playlistDoc)
  local self = setmetatable({}, Station)
  self.definition = stationDefinition
  self.tracks = {}
  self.current_index = 0
  self.shuffle_mode = false
  self.shuffle_bag = {}
  self.started_at_ms = util.nowMilliseconds()
  self:setPlaylist(playlistDoc, true)
  return self
end

function Station:setPlaylist(playlistDoc, isFirstLoad)
  local previousTrack = self:getCurrentTrack()
  
  -- check if the playlist ACTUALLY changed
  local isNewVersion = (self.playlist_version ~= playlistDoc.version)
  
  self.playlist = playlistDoc
  self.tracks = playlistDoc.tracks or {}
  self.playlist_version = playlistDoc.version
  
  -- ONLY wipe the bag if the playlist version actually changed
  -- This prevents the background 5-minute refresh from ruining the shuffle memory.
  if isNewVersion or isFirstLoad then
    self.shuffle_bag = {}
  end

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
  if isFirstLoad then
    self.current_index = 1
    self.started_at_ms = util.nowMilliseconds() + ((config.track_start_buffer_seconds or 0) * 1000)
  end

  return true
end

function Station:getCurrentTrack()
  if not self.tracks or not self.current_index or self.current_index < 1 then
    return nil
  end
  return self.tracks[self.current_index]
end

function Station:_refillShuffleBag()
  self.shuffle_bag = {}
  
  -- add all tracks to the bag
  for i = 1, #self.tracks do
    table.insert(self.shuffle_bag, i)
  end

  -- scramble the bag
  for i = #self.shuffle_bag, 2, -1 do
    local j = math.random(1, i)
    self.shuffle_bag[i], self.shuffle_bag[j] = self.shuffle_bag[j], self.shuffle_bag[i]
  end

  -- Prevent back-to-back repeats: 
  -- If the top card in our new deck is the song that just finished, swap it with the bottom card!
  if #self.tracks > 1 and self.current_index > 0 then
    if self.shuffle_bag[1] == self.current_index then
      local last = #self.shuffle_bag
      self.shuffle_bag[1], self.shuffle_bag[last] = self.shuffle_bag[last], self.shuffle_bag[1]
    end
  end
end

local function removeIndexFromBag(bag, indexToRemove)
  if not bag or not indexToRemove then return end
  for i = #bag, 1, -1 do
    if bag[i] == indexToRemove then
      table.remove(bag, i)
    end
  end
end

function Station:advanceTrack(nowMs)
  if #self.tracks == 0 then
    return false
  end

  if self.shuffle_mode then
    -- if the deck is empty, shuffle a new one
    if not self.shuffle_bag or #self.shuffle_bag == 0 then
      self:_refillShuffleBag()
    end
    
    self.current_index = table.remove(self.shuffle_bag, 1)
  else
    self.current_index = self.current_index + 1
    if self.current_index > #self.tracks then
      self.current_index = 1
    end
  end
  
  self.started_at_ms = nowMs or util.nowMilliseconds()
  return true
end

function Station:selectTrack(index, nowMs)
  index = tonumber(index)
  if not index or #self.tracks == 0 then
    return false
  end

  index = math.floor(index)
  if index < 1 or index > #self.tracks then
    return false
  end

  self.current_index = index
  if self.shuffle_mode then
    removeIndexFromBag(self.shuffle_bag, index)
  end
  self.started_at_ms = nowMs or util.nowMilliseconds()
  return true
end

function Station:toggleShuffle()
  self.shuffle_mode = not self.shuffle_mode
  if self.shuffle_mode then
    self.shuffle_bag = {} 
  end
  return self.shuffle_mode
end

function Station:getPersistentState()
  local shuffleBagTrackIds = {}
  for _, index in ipairs(self.shuffle_bag or {}) do
    local trackId = trackIdForIndex(self.tracks, index)
    if trackId then
      shuffleBagTrackIds[#shuffleBagTrackIds + 1] = trackId
    end
  end

  return {
    playlist_version = self.playlist_version,
    current_track_id = trackIdForIndex(self.tracks, self.current_index),
    current_index = self.current_index,
    shuffle_mode = self.shuffle_mode == true,
    shuffle_bag_track_ids = shuffleBagTrackIds,
    started_at_ms = self.started_at_ms,
    saved_at_ms = util.nowMilliseconds(),
  }
end

function Station:restorePersistentState(runtimeState)
  if type(runtimeState) ~= "table" or #self.tracks == 0 then
    return false
  end

  self.current_index = indexForTrackId(self.tracks, runtimeState.current_track_id)
    or clampTrackIndex(tonumber(runtimeState.current_index) or 1, #self.tracks)

  self.shuffle_mode = runtimeState.shuffle_mode == true

  local restoredShuffleBag = {}
  for _, trackId in ipairs(runtimeState.shuffle_bag_track_ids or {}) do
    local index = indexForTrackId(self.tracks, trackId)
    if index and index ~= self.current_index then
      restoredShuffleBag[#restoredShuffleBag + 1] = index
    end
  end
  self.shuffle_bag = restoredShuffleBag

  local startedAtMs = tonumber(runtimeState.started_at_ms)
  if startedAtMs and startedAtMs > 0 then
    self.started_at_ms = startedAtMs
  end

  return true
end

function Station:update(nowMs)
  local track = self:getCurrentTrack()
  if not track then return false end

  local changed = false
  local trackWindowMs = (track.duration + (config.track_gap_seconds or 0)) * 1000
  if trackWindowMs <= 0 then trackWindowMs = 1000 end 
  
  while nowMs >= self.started_at_ms + trackWindowMs do
    self:advanceTrack(self.started_at_ms + trackWindowMs)
    track = self:getCurrentTrack()
    changed = true
    if not track then break end
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
  local in_gap = track and elapsed_ms >= duration_ms and elapsed_ms < (duration_ms + gap_ms) or false
  return {
    playlist_version = self.playlist_version,
    started_at_ms = self.started_at_ms,
    track_index = self.current_index,
    track_count = #self.tracks,
    duration = track and track.duration or 0,
    track_list = self.tracks,
    gap_seconds = config.track_gap_seconds or 0,
    in_gap = in_gap,
    shuffle_mode = self.shuffle_mode,
    track = track,
  }
end

return Station
