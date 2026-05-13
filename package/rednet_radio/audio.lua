local util = require("rednet_radio.util")

local audio = {}

local SAMPLE_RATE = 48000
local BYTES_PER_SECOND = SAMPLE_RATE / 8
local CHUNK_BYTES = 8 * 1024
local MAX_BUFFER_SAMPLES = 128 * 1024
local PRE_ROLL_SECONDS = 1
local RESYNC_THRESHOLD_SECONDS = 5 
local MIN_VOLUME_PERCENT = 0
local MAX_VOLUME_PERCENT = 300
local DEFAULT_VOLUME_PERCENT = 100
local VOLUME_STEP_PERCENT = 5
local MAX_TRACKED_CHUNKS = 16

local state = {
  speaker = nil,
  dfpwm = nil,
  decoder = nil,
  stream = nil,
  current_track_id = nil,
  current_playback_url = nil,
  pending_buffer = nil,
  pending_amplitude = 0,
  amplitude_queue = {},
  chunk_queue = {},
  buffered_samples = 0,
  skip_samples = 0,
  sync_offset_seconds = 0,
  sync_clock_ms = 0,
  bytes_started_at = 0,
  volume_percent = DEFAULT_VOLUME_PERCENT,
  status = "metadata mode only",
  last_error = nil,
}

local function clampVolumePercent(volumePercent)
  volumePercent = tonumber(volumePercent) or DEFAULT_VOLUME_PERCENT
  volumePercent = math.floor(volumePercent + 0.5)
  if volumePercent < MIN_VOLUME_PERCENT then return MIN_VOLUME_PERCENT end
  if volumePercent > MAX_VOLUME_PERCENT then return MAX_VOLUME_PERCENT end
  return volumePercent
end

local function getSpeakerVolume() return state.volume_percent / 100 end

local function closeStream()
  if state.stream and state.stream.close then
    pcall(function() state.stream.close() end)
  end
  state.stream = nil
end

local function getSpeaker()
  state.speaker = peripheral.find("speaker")
  return state.speaker
end

local function getDecoderFactory()
  if state.dfpwm ~= nil then return state.dfpwm end
  local ok, lib = pcall(require, "cc.audio.dfpwm")
  if ok then state.dfpwm = lib else state.dfpwm = false end
  return state.dfpwm
end

local function trimBuffer(buffer, samplesToSkip)
  if samplesToSkip <= 0 then return buffer, 0 end
  if samplesToSkip >= #buffer then return {}, samplesToSkip - #buffer end
  local trimmed = {}
  local c = 1
  for index = samplesToSkip + 1, #buffer do 
    trimmed[c] = buffer[index] 
    c = c + 1
  end
  return trimmed, 0
end

local function estimateCurrentOffsetSeconds()
  if not state.current_track_id then return 0 end
  return state.sync_offset_seconds + ((util.nowMilliseconds() - state.sync_clock_ms) / 1000)
end

local function playPendingBuffer()
  local speaker = getSpeaker()
  if not speaker or not state.pending_buffer then return false end

  if speaker.playAudio(state.pending_buffer, getSpeakerVolume()) then
    table.insert(state.amplitude_queue, state.pending_amplitude)
    table.insert(state.chunk_queue, #state.pending_buffer)
    state.buffered_samples = state.buffered_samples + #state.pending_buffer
    
    state.pending_buffer = nil
    state.pending_amplitude = 0
    state.status = "playing"
    return true
  end

  state.status = "buffering speaker"
  return false
end

local function skipBytes(response, bytesToSkip)
  local cycles = 0
  while bytesToSkip > 0 do
    -- PROTECTED CALL: Safely catches "attempt to use closed file" if connection drops
    local ok, chunk = pcall(response.read, math.min(CHUNK_BYTES, bytesToSkip))
    if not ok or not chunk or #chunk == 0 then return false end
    bytesToSkip = bytesToSkip - #chunk
    
    cycles = cycles + 1
    if cycles % 10 == 0 then os.sleep(0) end 
  end
  return true
end

local function openStream(playbackUrl, startByte)
  local headers
  if startByte > 0 then headers = { Range = ("bytes=%d-"):format(startByte) } end

  local response, err = http.get(playbackUrl, headers, true)
  if not response then return nil, err or ("HTTP request failed for %s"):format(playbackUrl) end

  local responseCode = response.getResponseCode and response.getResponseCode() or 200
  if startByte > 0 and responseCode ~= 206 then
    response.close()
    response, err = http.get(playbackUrl, nil, true)
    if not response then return nil, err or ("HTTP request failed for %s"):format(playbackUrl) end
    if not skipBytes(response, startByte) then
      response.close()
      return nil, ("Could not seek to byte %d for %s"):format(startByte, playbackUrl)
    end
  end
  return response
end

local function queueNextChunk()
  if not state.stream then return end

  while true do
    if state.pending_buffer then
      if not playPendingBuffer() then return end
    end

    -- Safety check in case stream was closed while we were yielded
    if not state.stream then return end 

    -- PROTECTED CALL: If eventThread calls audio.stopTrack() while we are downloading, safely abort!
    local ok, chunk = pcall(state.stream.read, CHUNK_BYTES)
    if not ok or not chunk or #chunk == 0 then
      closeStream()
      if not state.pending_buffer then state.status = "track ended" end
      return
    end

    local buffer = state.decoder(chunk)
    if state.skip_samples > 0 then
      buffer, state.skip_samples = trimBuffer(buffer, state.skip_samples)
    end

    if #buffer > 0 then
      local peak = 0
      for i = 1, #buffer, 16 do
        local val = math.abs(buffer[i])
        if val > peak then peak = val end
      end
      state.pending_amplitude = peak / 128
      state.pending_buffer = buffer
    end
  end
end

local function restartPlayback(track, targetOffsetSeconds)
  audio.stopTrack()

  local speaker = getSpeaker()
  if not speaker then
    state.status = "metadata mode only (no speaker attached)"
    return nil, state.status
  end

  local dfpwm = getDecoderFactory()
  if not dfpwm then
    state.status = "playback unavailable (cc.audio.dfpwm missing)"
    return nil, state.status
  end

  if not track or not track.playback_url or track.playback_url == "" then
    state.status = "metadata mode only (no playback_url)"
    return nil, state.status
  end

  local preRollBytes = math.floor(PRE_ROLL_SECONDS * BYTES_PER_SECOND)
  local targetBytes = math.max(0, math.floor(targetOffsetSeconds * BYTES_PER_SECOND))
  local startByte = math.max(0, targetBytes - preRollBytes)
  local skipSamples = (targetBytes - startByte) * 8

  local stream, err = openStream(track.playback_url, startByte)
  if not stream then
    state.status = "playback error"
    state.last_error = err
    return nil, err
  end

  state.stream = stream
  state.decoder = dfpwm.make_decoder()
  state.current_track_id = track.id
  state.current_playback_url = track.playback_url
  state.pending_buffer = nil
  state.pending_amplitude = 0
  state.amplitude_queue = {}
  state.chunk_queue = {}
  state.buffered_samples = 0
  state.skip_samples = skipSamples
  state.sync_offset_seconds = targetOffsetSeconds
  state.sync_clock_ms = util.nowMilliseconds()
  state.bytes_started_at = startByte
  state.last_error = nil
  state.status = "buffering audio"

  queueNextChunk()
  return true
end

function audio.playLocalBuffer(data, volume)
  audio.stopTrack()
  local speaker = getSpeaker()
  if not speaker then return end
  local dfpwm = getDecoderFactory()
  if not dfpwm then return end
  
  volume = volume or 1
  local decoder = dfpwm.make_decoder()
  for i = 1, #data, CHUNK_BYTES do
    local chunk = data:sub(i, i + CHUNK_BYTES - 1)
    local samples = decoder(chunk)
    
    if volume ~= 1 then
        for j=1, #samples do
            local s = samples[j] * volume
            if s > 127 then s = 127 elseif s < -128 then s = -128 end
            samples[j] = s
        end
    end

    while not speaker.playAudio(samples) do
      os.pullEvent("speaker_audio_empty")
    end
  end
end

function audio.hasSpeaker() return getSpeaker() ~= nil end
function audio.isPlaybackImplemented() return true end

function audio.getStatusSummary()
  if state.last_error then return ("%s (%s)"):format(state.status, state.last_error) end
  return state.status
end

function audio.getVolumePercent() return state.volume_percent end
function audio.getMaxVolumePercent() return MAX_VOLUME_PERCENT end
function audio.getVolumeStepPercent() return VOLUME_STEP_PERCENT end

function audio.setVolumePercent(volumePercent)
  state.volume_percent = clampVolumePercent(volumePercent)
  return state.volume_percent
end

function audio.adjustVolumePercent(deltaPercent)
  return audio.setVolumePercent(state.volume_percent + (deltaPercent or 0))
end

function audio.syncToSnapshot(snapshot)
  if not snapshot or not snapshot.track then
    audio.stopTrack()
    state.status = "waiting for station data"
    return nil
  end

  local track = snapshot.track
  local elapsedSeconds = util.trackElapsedMilliseconds(snapshot) / 1000
  if snapshot.in_gap or elapsedSeconds >= (snapshot.duration or 0) then
    audio.stopTrack()
    state.status = "intermission"
    return nil
  end

  if not track.playback_url or track.playback_url == "" then
    audio.stopTrack()
    state.status = "metadata mode only (no playback_url)"
    return nil
  end

  local targetOffsetSeconds = math.max(0, elapsedSeconds)
  local sameTrack = state.current_track_id == track.id and state.current_playback_url == track.playback_url

  if sameTrack then
    local drift = math.abs(targetOffsetSeconds - estimateCurrentOffsetSeconds())
    state.sync_offset_seconds = targetOffsetSeconds
    state.sync_clock_ms = util.nowMilliseconds()

    if drift <= RESYNC_THRESHOLD_SECONDS then return true end
  end

  return restartPlayback(track, targetOffsetSeconds)
end

function audio.handleEvent(event)
  if event == "speaker_audio_empty" then
    if #state.chunk_queue > 0 then
      local playedSamples = table.remove(state.chunk_queue, 1)
      state.buffered_samples = math.max(0, state.buffered_samples - playedSamples)
    end
    if #state.amplitude_queue > 0 then table.remove(state.amplitude_queue, 1) end
    queueNextChunk()
  end
end

function audio.startTrack(track, offsetSeconds)
  return restartPlayback(track, offsetSeconds or 0)
end

function audio.stopTrack()
  local speaker = getSpeaker()
  if speaker and speaker.stop then pcall(function() speaker.stop() end) end

  closeStream()
  state.decoder = nil
  state.current_track_id = nil
  state.current_playback_url = nil
  state.pending_buffer = nil
  state.pending_amplitude = 0
  state.amplitude_queue = {}
  state.chunk_queue = {}
  state.buffered_samples = 0
  state.skip_samples = 0
  state.sync_offset_seconds = 0
  state.sync_clock_ms = 0
  state.bytes_started_at = 0
  state.last_error = nil

  if speaker then state.status = "idle" else state.status = "metadata mode only (no speaker attached)" end
  return true
end

function audio.getAmplitude()
  if state.status == "playing" or state.status == "buffering speaker" then
    return state.amplitude_queue[1] or 0
  end
  return 0
end

function audio.getBufferRatio()
  if state.status == "playing" or state.status == "buffering speaker" then
    if #state.chunk_queue > MAX_TRACKED_CHUNKS then
      state.chunk_queue = {}
      state.amplitude_queue = {}
      state.buffered_samples = 0
    end
    if state.pending_buffer ~= nil then return 1.0 end
    local samples_per_chunk = CHUNK_BYTES * 8
    local max_chunks_allowed = math.min(8, math.floor(131072 / samples_per_chunk))
    if max_chunks_allowed < 1 then max_chunks_allowed = 1 end
    return math.max(0, math.min(1, #state.chunk_queue / max_chunks_allowed))
  end
  return 0
end

return audio
