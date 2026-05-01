local audio = {}

function audio.hasSpeaker()
  return peripheral.find("speaker") ~= nil
end

function audio.isPlaybackImplemented()
  return false
end

function audio.getStatusSummary()
  if not audio.hasSpeaker() then
    return "metadata mode only (no speaker attached)"
  end

  return "metadata mode only (playback adapter not implemented yet)"
end

function audio.startTrack(_track, _offsetSeconds)
  return nil, "Playback is not implemented in v1"
end

function audio.stopTrack()
  return true
end

return audio
