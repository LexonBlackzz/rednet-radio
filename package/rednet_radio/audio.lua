local util = require("rednet_radio.util")

local audio = {}

local SAMPLE_RATE = 48000
local BYTES_PER_SECOND = SAMPLE_RATE / 8
local CHUNK_BYTES = 8 * 1024
local MAX_BUFFER_SAMPLES = 128 * 1024
local PRE_ROLL_SECONDS = 1
local RESYNC_THRESHOLD_SECONDS = 5
local MIN_VOLUME_PERCENT = 0
local MAX_VOLUME_PERCENT = 200
local DEFAULT_VOLUME_PERCENT = 100
local VOLUME_STEP_PERCENT = 5
local MIN_VISUALIZER_RANGE_PERCENT = 0
local MAX_VISUALIZER_RANGE_PERCENT = 300
local DEFAULT_VISUALIZER_RANGE_PERCENT = 100
local VISUALIZER_RANGE_STEP_PERCENT = 25
local MAX_TRACKED_CHUNKS = 16

-- ── State ─────────────────────────────────────────────────────────────────────
local state = {
  -- Primary (left / mono) speaker
  speaker = nil,
  speaker_name = nil,
  speaker_ready = true,
  -- Secondary (right) speaker — only used in stereo mode
  speaker_r       = nil,
  speaker_r_name  = nil,   -- peripheral name, used to filter speaker_audio_empty events
  speaker_r_ready = true,

  dfpwm    = nil,
  decoder   = nil,
  decoder_r = nil,   -- right-channel DFPWM decoder
  stream    = nil,
  stream_r  = nil,   -- right-channel HTTP stream (nil = duplicate left on right)

  current_track_id       = nil,
  current_playback_url   = nil,

  pending_buffer   = nil,
  pending_buffer_r = nil,  -- right-channel pending (nil = use left data)
  pending_amplitude = 0,

  amplitude_queue  = {},
  chunk_queue      = {},
  buffered_samples = 0,
  skip_samples     = 0,
  skip_samples_r   = 0,

  sync_offset_seconds = 0,
  sync_clock_ms       = 0,
  bytes_started_at    = 0,

  volume_percent           = DEFAULT_VOLUME_PERCENT,
  visualizer_range_percent = DEFAULT_VISUALIZER_RANGE_PERCENT,

  status     = "metadata mode only",
  last_error = nil,

  -- Stereo flags (set by audio.setStereoEnabled / restartPlayback)
  stereo_enabled = false,  -- user-facing toggle
  stereo_active  = false,  -- true while a track is actually playing on 2 speakers
}
-- ─────────────────────────────────────────────────────────────────────────────

local function clampVolumePercent(volumePercent)
  volumePercent = tonumber(volumePercent) or DEFAULT_VOLUME_PERCENT
  volumePercent = math.floor(volumePercent + 0.5)
  if volumePercent < MIN_VOLUME_PERCENT then return MIN_VOLUME_PERCENT end
  if volumePercent > MAX_VOLUME_PERCENT then return MAX_VOLUME_PERCENT end
  return volumePercent
end

local function clampVisualizerRangePercent(rangePercent)
  rangePercent = tonumber(rangePercent) or DEFAULT_VISUALIZER_RANGE_PERCENT
  rangePercent = math.floor(rangePercent + 0.5)
  if rangePercent < MIN_VISUALIZER_RANGE_PERCENT then return MIN_VISUALIZER_RANGE_PERCENT end
  if rangePercent > MAX_VISUALIZER_RANGE_PERCENT then return MAX_VISUALIZER_RANGE_PERCENT end
  return rangePercent
end

local function getSpeakerVolume() return state.visualizer_range_percent / 100 end

local function applyVolumeBoost(buffer)
  if not buffer or state.volume_percent <= 100 then
    return buffer
  end
  local boosted = {}
  local gain = state.volume_percent / 100
  for i = 1, #buffer do
    local sample = buffer[i] * gain
    if sample > 127 then sample = 127
    elseif sample < -128 then sample = -128 end
    boosted[i] = sample
  end
  return boosted
end

-- ── Speaker helpers ───────────────────────────────────────────────────────────

-- Returns all attached speakers sorted by name for consistent L/R assignment.
local function findAllSpeakers()
  local found = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "speaker" then
      table.insert(found, { name = name, handle = peripheral.wrap(name) })
    end
  end
  table.sort(found, function(a, b) return a.name < b.name end)
  return found
end

-- Primary speaker — returns cached handle or re-detects once.
local function getSpeaker()
  if not state.speaker then
    state.speaker = peripheral.find("speaker")
  end
  return state.speaker
end

-- ── Stream helpers ────────────────────────────────────────────────────────────

local function closeStream()
  if state.stream and state.stream.close then
    pcall(function() state.stream.close() end)
  end
  state.stream = nil
end

local function closeStreamR()
  if state.stream_r and state.stream_r.close then
    pcall(function() state.stream_r.close() end)
  end
  state.stream_r  = nil
  state.decoder_r = nil
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

-- ── Playback core ─────────────────────────────────────────────────────────────

-- Attempts to push pending buffer(s) to the speaker(s).
-- In stereo mode the right speaker is fed the right-channel buffer when available,
-- or the same left-channel data when no separate right stream exists (mono dup).
-- The right speaker call is best-effort (pcall) to avoid crashing on disconnect.
-- Returns true if the left buffer was accepted (we can proceed reading).
local function playPendingBuffer()
  local speaker = getSpeaker()
  if not speaker or not state.pending_buffer then return false end

  if state.stereo_active then
    if not state.speaker_ready or not state.speaker_r_ready then
      state.status = "buffering speaker"
      return false
    end
  elseif not state.speaker_ready then
    state.status = "buffering speaker"
    return false
  end

  local outputBuffer = applyVolumeBoost(state.pending_buffer)
  local vol = getSpeakerVolume()

  if not speaker.playAudio(outputBuffer, vol) then
    state.speaker_ready = false
    state.status = "buffering speaker"
    return false
  end
  state.speaker_ready = false

  -- ── Stereo right channel ──────────────────────────────────────────────────
  if state.stereo_active and state.speaker_r then
    local outputBufferR = state.pending_buffer_r
      and applyVolumeBoost(state.pending_buffer_r)
      or outputBuffer        -- fall back: play same mono data on right

    local okRight, acceptedRight = pcall(state.speaker_r.playAudio, outputBufferR, vol)
    if okRight and acceptedRight then
      state.speaker_r_ready = false
    elseif okRight then
      -- Keep both channels aligned: if the right speaker rejects this chunk,
      -- roll back the left side and retry once the right speaker empties.
      if speaker.stop then
        pcall(function() speaker.stop() end)
      end
      state.speaker_ready = true
      state.speaker_r_ready = false
      state.status = "buffering speaker"
      return false
    else
      closeStreamR()
      state.speaker_r = nil
      state.speaker_r_name = nil
      state.speaker_r_ready = true
      state.stereo_active = false
    end
  end

  table.insert(state.amplitude_queue, state.pending_amplitude)
  table.insert(state.chunk_queue, #outputBuffer)
  state.buffered_samples = state.buffered_samples + #outputBuffer

  state.pending_buffer   = nil
  state.pending_buffer_r = nil
  state.pending_amplitude = 0

  if state.stereo_active then
    state.status = state.stream_r and "playing (stereo L+R)" or "playing (stereo dup)"
  else
    state.status = "playing"
  end
  return true
end

local function skipBytes(response, bytesToSkip)
  local cycles = 0
  while bytesToSkip > 0 do
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

    -- Safety: stream may have been closed by stopTrack() while we were yielded
    if not state.stream then return end

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

    -- ── Stereo: read matching right-channel chunk ──────────────────────────
    local buffer_r = nil
    if state.stereo_active and state.stream_r then
      local ok_r, chunk_r = pcall(state.stream_r.read, CHUNK_BYTES)
      if ok_r and chunk_r and #chunk_r > 0 then
        buffer_r = state.decoder_r(chunk_r)
        if state.skip_samples_r > 0 then
          buffer_r, state.skip_samples_r = trimBuffer(buffer_r, state.skip_samples_r)
        end
      else
        -- Right stream ended or errored — fall back to mono-dup silently
        closeStreamR()
      end
    end

    if #buffer > 0 then
      local peak = 0
      for i = 1, #buffer, 16 do
        local val = math.abs(buffer[i])
        if val > peak then peak = val end
      end
      state.pending_amplitude = peak / 128
      state.pending_buffer    = buffer
      state.pending_buffer_r  = buffer_r  -- nil is fine → playPendingBuffer falls back to left
    end
  end
end

local function restartPlayback(track, targetOffsetSeconds)
  audio.stopTrack()

  local dfpwm = getDecoderFactory()
  if not dfpwm then
    state.status = "playback unavailable (cc.audio.dfpwm missing)"
    return nil, state.status
  end

  if not track or not track.playback_url or track.playback_url == "" then
    state.status = "metadata mode only (no playback_url)"
    return nil, state.status
  end

  -- ── Speaker assignment ────────────────────────────────────────────────────
  local allSpeakers = findAllSpeakers()
  if #allSpeakers == 0 then
    state.status = "metadata mode only (no speaker attached)"
    return nil, state.status
  end

  state.speaker       = allSpeakers[1].handle
  state.speaker_name  = allSpeakers[1].name
  state.speaker_ready = true
  state.speaker_r     = nil
  state.speaker_r_name = nil
  state.speaker_r_ready = true
  state.stereo_active = false

  if state.stereo_enabled and #allSpeakers >= 2 then
    state.speaker_r      = allSpeakers[2].handle
    state.speaker_r_name = allSpeakers[2].name
    state.speaker_r_ready = true
    state.stereo_active  = true
  end

  -- ── Open left / mono stream ───────────────────────────────────────────────
  local preRollBytes  = math.floor(PRE_ROLL_SECONDS * BYTES_PER_SECOND)
  local targetBytes   = math.max(0, math.floor(targetOffsetSeconds * BYTES_PER_SECOND))
  local startByte     = math.max(0, targetBytes - preRollBytes)
  local skipSamples   = (targetBytes - startByte) * 8

  local stream, err = openStream(track.playback_url, startByte)
  if not stream then
    state.status    = "playback error"
    state.last_error = err
    return nil, err
  end

  state.stream              = stream
  state.decoder             = dfpwm.make_decoder()
  state.current_track_id    = track.id
  state.current_playback_url = track.playback_url
  state.pending_buffer      = nil
  state.pending_buffer_r    = nil
  state.pending_amplitude   = 0
  state.amplitude_queue     = {}
  state.chunk_queue         = {}
  state.buffered_samples    = 0
  state.skip_samples        = skipSamples
  state.skip_samples_r      = skipSamples
  state.sync_offset_seconds = targetOffsetSeconds
  state.sync_clock_ms       = util.nowMilliseconds()
  state.bytes_started_at    = startByte
  state.last_error          = nil

  -- ── Open right-channel stream (stereo only) ───────────────────────────────
  state.stream_r  = nil
  state.decoder_r = nil

  if state.stereo_active then
    if track.playback_url_r and track.playback_url_r ~= "" then
      local stream_r, err_r = openStream(track.playback_url_r, startByte)
      if stream_r then
        state.stream_r  = stream_r
        state.decoder_r = dfpwm.make_decoder()
        state.status    = "buffering audio (stereo L+R)"
      else
        -- Right URL failed — degrade gracefully to mono-dup on both speakers
        state.status = "buffering audio (stereo dup)"
      end
    else
      -- No right-channel URL for this track — play mono on both speakers
      state.status = "buffering audio (stereo dup)"
    end
  else
    state.status = "buffering audio"
  end

  queueNextChunk()
  return true
end

-- ── Public API ────────────────────────────────────────────────────────────────

function audio.playLocalBuffer(data, volume)
  audio.stopTrack()
  local speaker = getSpeaker()
  if not speaker then return end
  local dfpwm = getDecoderFactory()
  if not dfpwm then return end

  volume = volume or 1
  local decoder = dfpwm.make_decoder()
  for i = 1, #data, CHUNK_BYTES do
    local chunk   = data:sub(i, i + CHUNK_BYTES - 1)
    local samples = decoder(chunk)

    if volume ~= 1 then
      for j = 1, #samples do
        local s = samples[j] * volume
        if s > 127 then s = 127 elseif s < -128 then s = -128 end
        samples[j] = s
      end
    end

    while not speaker.playAudio(samples, getSpeakerVolume()) do
      os.pullEvent("speaker_audio_empty")
    end
  end
end

function audio.hasSpeaker()             return getSpeaker() ~= nil end
function audio.isPlaybackImplemented()  return true end

function audio.getStatusSummary()
  if state.last_error then return ("%s (%s)"):format(state.status, state.last_error) end
  return state.status
end

function audio.getVolumePercent()              return state.volume_percent end
function audio.getMaxVolumePercent()           return MAX_VOLUME_PERCENT end
function audio.getVolumeStepPercent()          return VOLUME_STEP_PERCENT end
function audio.getVisualizerRangePercent()     return state.visualizer_range_percent end
function audio.getMaxVisualizerRangePercent()  return MAX_VISUALIZER_RANGE_PERCENT end
function audio.getVisualizerRangeStepPercent() return VISUALIZER_RANGE_STEP_PERCENT end

function audio.setVolumePercent(volumePercent)
  state.volume_percent = clampVolumePercent(volumePercent)
  return state.volume_percent
end

function audio.adjustVolumePercent(deltaPercent)
  return audio.setVolumePercent(state.volume_percent + (deltaPercent or 0))
end

function audio.setVisualizerRangePercent(rangePercent)
  state.visualizer_range_percent = clampVisualizerRangePercent(rangePercent)
  return state.visualizer_range_percent
end

function audio.adjustVisualizerRangePercent(deltaPercent)
  return audio.setVisualizerRangePercent(state.visualizer_range_percent + (deltaPercent or 0))
end

-- ── Stereo control ────────────────────────────────────────────────────────────

-- Enable or disable stereo mode.  Takes effect on the next track start / resync.
function audio.setStereoEnabled(enabled)
  enabled = enabled == true
  if state.stereo_enabled ~= enabled then
    state.current_track_id = nil
    state.current_playback_url = nil
  end
  state.stereo_enabled = enabled
end

function audio.getStereoEnabled()
  return state.stereo_enabled
end

-- True if the CURRENT track is actually playing on two speakers.
function audio.getStereoActive()
  return state.stereo_active
end

-- True if at least two speakers are currently attached.
function audio.isStereoAvailable()
  local count = 0
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "speaker" then
      count = count + 1
      if count >= 2 then return true end
    end
  end
  return false
end

-- ─────────────────────────────────────────────────────────────────────────────

function audio.syncToSnapshot(snapshot)
  if not snapshot or not snapshot.track then
    audio.stopTrack()
    state.status = "waiting for station data"
    return nil
  end

  local track          = snapshot.track
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
  local sameTrack = state.current_track_id == track.id
    and state.current_playback_url == track.playback_url

  if sameTrack then
    local drift = math.abs(targetOffsetSeconds - estimateCurrentOffsetSeconds())
    state.sync_offset_seconds = targetOffsetSeconds
    state.sync_clock_ms       = util.nowMilliseconds()

    if drift <= RESYNC_THRESHOLD_SECONDS then return true end
  end

  return restartPlayback(track, targetOffsetSeconds)
end

-- Called from the audio thread on speaker events.
-- In stereo mode we wait for BOTH speakers to report ready before queuing the
-- next chunk, which keeps the left/right streams from drifting apart.
function audio.handleEvent(event, speakerName)
  if event == "speaker_audio_empty" then
    if state.stereo_active then
      if speakerName == state.speaker_name then
        state.speaker_ready = true

        if #state.chunk_queue > 0 then
          local playedSamples = table.remove(state.chunk_queue, 1)
          state.buffered_samples = math.max(0, state.buffered_samples - playedSamples)
        end
        if #state.amplitude_queue > 0 then table.remove(state.amplitude_queue, 1) end
      elseif speakerName == state.speaker_r_name then
        state.speaker_r_ready = true
      else
        return
      end

      if not (state.speaker_ready and state.speaker_r_ready) then
        return
      end
    else
      state.speaker_ready = true
      if #state.chunk_queue > 0 then
        local playedSamples = table.remove(state.chunk_queue, 1)
        state.buffered_samples = math.max(0, state.buffered_samples - playedSamples)
      end
      if #state.amplitude_queue > 0 then table.remove(state.amplitude_queue, 1) end
    end
    queueNextChunk()
  end
end

function audio.startTrack(track, offsetSeconds)
  return restartPlayback(track, offsetSeconds or 0)
end

function audio.stopTrack()
  -- Stop primary speaker
  local speaker = getSpeaker()
  if speaker and speaker.stop then pcall(function() speaker.stop() end) end

  -- Stop right speaker
  if state.speaker_r and state.speaker_r.stop then
    pcall(function() state.speaker_r.stop() end)
  end

  closeStreamR()
  closeStream()

  state.decoder             = nil
  state.current_track_id    = nil
  state.current_playback_url = nil
  state.pending_buffer      = nil
  state.pending_buffer_r    = nil
  state.pending_amplitude   = 0
  state.amplitude_queue     = {}
  state.chunk_queue         = {}
  state.buffered_samples    = 0
  state.skip_samples        = 0
  state.skip_samples_r      = 0
  state.sync_offset_seconds = 0
  state.sync_clock_ms       = 0
  state.bytes_started_at    = 0
  state.last_error          = nil
  state.speaker             = nil
  state.speaker_name        = nil
  state.speaker_ready       = true
  state.speaker_r           = nil
  state.speaker_r_name      = nil
  state.speaker_r_ready     = true
  state.stereo_active       = false

  local hasSpeaker = peripheral.find("speaker") ~= nil
  if hasSpeaker then
    state.status = "idle"
  else
    state.status = "metadata mode only (no speaker attached)"
  end
  return true
end

function audio.getAmplitude()
  if state.status == "playing"
      or state.status == "buffering speaker"
      or state.status == "playing (stereo L+R)"
      or state.status == "playing (stereo dup)" then
    return state.amplitude_queue[1] or 0
  end
  return 0
end

function audio.getBufferRatio()
  if state.status == "playing"
      or state.status == "buffering speaker"
      or state.status == "playing (stereo L+R)"
      or state.status == "playing (stereo dup)" then
    if #state.chunk_queue > MAX_TRACKED_CHUNKS then
      state.chunk_queue      = {}
      state.amplitude_queue  = {}
      state.buffered_samples = 0
    end
    if state.pending_buffer ~= nil then return 1.0 end
    local samples_per_chunk    = CHUNK_BYTES * 8
    local max_chunks_allowed   = math.min(8, math.floor(131072 / samples_per_chunk))
    if max_chunks_allowed < 1 then max_chunks_allowed = 1 end
    return math.max(0, math.min(1, #state.chunk_queue / max_chunks_allowed))
  end
  return 0
end

return audio
