local util = require("rednet_radio.util")

local audio = {}

local SAMPLE_RATE = 48000
local BYTES_PER_SECOND = SAMPLE_RATE / 8
local CHUNK_BYTES = 16 * 1024
local PRE_ROLL_SECONDS = 1
local RESYNC_THRESHOLD_SECONDS = 2

local state = {
  speaker = nil,
  dfpwm = nil,
  decoder = nil,
  stream = nil,
  current_track_id = nil,
  current_playback_url = nil,
  pending_buffer = nil,
  skip_samples = 0,
  sync_offset_seconds = 0,
  sync_clock_ms = 0,
  bytes_started_at = 0,
  status = "metadata mode only",
  last_error = nil,
}

local function closeStream()
  if state.stream and state.stream.close then
    pcall(function()
      state.stream.close()
    end)
  end

  state.stream = nil
end

local function getSpeaker()
  state.speaker = peripheral.find("speaker")
  return state.speaker
end

local function getDecoderFactory()
  if state.dfpwm ~= nil then
    return state.dfpwm
  end

  local ok, lib = pcall(require, "cc.audio.dfpwm")
  if ok then
    state.dfpwm = lib
  else
    state.dfpwm = false
  end

  return state.dfpwm
end

local function trimBuffer(buffer, samplesToSkip)
  if samplesToSkip <= 0 then
    return buffer, 0
  end

  if samplesToSkip >= #buffer then
    return {}, samplesToSkip - #buffer
  end

  local trimmed = {}
  for index = samplesToSkip + 1, #buffer do
    trimmed[#trimmed + 1] = buffer[index]
  end

  return trimmed, 0
end

local function estimateCurrentOffsetSeconds()
  if not state.current_track_id then
    return 0
  end

  return state.sync_offset_seconds + ((util.nowMilliseconds() - state.sync_clock_ms) / 1000)
end

local function playPendingBuffer()
  local speaker = getSpeaker()
  if not speaker or not state.pending_buffer then
    return false
  end

  if speaker.playAudio(state.pending_buffer) then
    state.pending_buffer = nil
    state.status = "playing"
    return true
  end

  state.status = "buffering speaker"
  return false
end

local function skipBytes(response, bytesToSkip)
  while bytesToSkip > 0 do
    local chunk = response.read(math.min(CHUNK_BYTES, bytesToSkip))
    if not chunk or #chunk == 0 then
      return false
    end
    bytesToSkip = bytesToSkip - #chunk
  end

  return true
end

local function openStream(playbackUrl, startByte)
  local headers
  if startByte > 0 then
    headers = { Range = ("bytes=%d-"):format(startByte) }
  end

  local response, err = http.get(playbackUrl, headers, true)
  if not response then
    return nil, err or ("HTTP request failed for %s"):format(playbackUrl)
  end

  local responseCode = response.getResponseCode and response.getResponseCode() or 200
  if startByte > 0 and responseCode ~= 206 then
    response.close()
    response, err = http.get(playbackUrl, nil, true)
    if not response then
      return nil, err or ("HTTP request failed for %s"):format(playbackUrl)
    end

    if not skipBytes(response, startByte) then
      response.close()
      return nil, ("Could not seek to byte %d for %s"):format(startByte, playbackUrl)
    end
  end

  return response
end

local function queueNextChunk()
  if not state.stream or state.pending_buffer then
    return
  end

  while true do
    local chunk = state.stream.read(CHUNK_BYTES)
    if not chunk or #chunk == 0 then
      closeStream()
      if not state.pending_buffer then
        state.status = "track ended"
      end
      return
    end

    local buffer = state.decoder(chunk)
    if state.skip_samples > 0 then
      buffer, state.skip_samples = trimBuffer(buffer, state.skip_samples)
    end

    if #buffer > 0 then
      state.pending_buffer = buffer
      playPendingBuffer()
      return
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
  state.skip_samples = skipSamples
  state.sync_offset_seconds = targetOffsetSeconds
  state.sync_clock_ms = util.nowMilliseconds()
  state.bytes_started_at = startByte
  state.last_error = nil
  state.status = "buffering audio"

  queueNextChunk()
  return true
end

function audio.hasSpeaker()
  return getSpeaker() ~= nil
end

function audio.isPlaybackImplemented()
  return true
end

function audio.getStatusSummary()
  if state.last_error then
    return ("%s (%s)"):format(state.status, state.last_error)
  end

  return state.status
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

  local targetOffsetSeconds = elapsedSeconds
  local sameTrack = state.current_track_id == track.id and state.current_playback_url == track.playback_url

  if sameTrack then
    local drift = math.abs(targetOffsetSeconds - estimateCurrentOffsetSeconds())
    state.sync_offset_seconds = targetOffsetSeconds
    state.sync_clock_ms = util.nowMilliseconds()

    if drift <= RESYNC_THRESHOLD_SECONDS then
      return true
    end
  end

  return restartPlayback(track, targetOffsetSeconds)
end

function audio.handleEvent(event)
  if event == "speaker_audio_empty" then
    if state.pending_buffer then
      playPendingBuffer()
    end

    if not state.pending_buffer then
      queueNextChunk()
    end
  end
end

function audio.startTrack(track, offsetSeconds)
  return restartPlayback(track, offsetSeconds or 0)
end

function audio.stopTrack()
  local speaker = getSpeaker()
  if speaker and speaker.stop then
    pcall(function()
      speaker.stop()
    end)
  end

  closeStream()
  state.decoder = nil
  state.current_track_id = nil
  state.current_playback_url = nil
  state.pending_buffer = nil
  state.skip_samples = 0
  state.sync_offset_seconds = 0
  state.sync_clock_ms = 0
  state.bytes_started_at = 0
  state.last_error = nil

  if speaker then
    state.status = "idle"
  else
    state.status = "metadata mode only (no speaker attached)"
  end

  return true
end

return audio
