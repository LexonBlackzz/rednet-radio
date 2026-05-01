local config = require("rednet_radio.config")

local api = {}

local globalProtocol = config.protocol
local hostedProtocols = {}

local function stationProtocolFor(station)
  if station.rednet_channel and station.rednet_channel ~= "" then
    return station.rednet_channel
  end

  return ("%s:station:%s"):format(config.protocol, station.station_id)
end

function api.openModems()
  local opened = 0
  for _, side in ipairs(rs.getSides()) do
    if peripheral.getType(side) == "modem" then
      if not rednet.isOpen(side) then
        rednet.open(side)
      end
      opened = opened + 1
    end
  end
  return opened
end

function api.getStationProtocol(station)
  return stationProtocolFor(station)
end

function api.hostStation(station)
  local stationProtocol = stationProtocolFor(station)

  for protocol in pairs(hostedProtocols) do
    if protocol ~= globalProtocol and protocol ~= stationProtocol then
      rednet.unhost(protocol, station.station_id)
      hostedProtocols[protocol] = nil
    end
  end

  rednet.host(globalProtocol, station.station_id)
  rednet.host(stationProtocol, station.station_id)
  hostedProtocols[globalProtocol] = true
  hostedProtocols[stationProtocol] = true
end

function api.listenToStation(station)
  return stationProtocolFor(station)
end

function api.isRadioMessage(message)
  return type(message) == "table" and type(message.message_type) == "string"
end

function api.acceptsProtocol(station, protocol)
  return protocol == globalProtocol or protocol == stationProtocolFor(station)
end

function api.matchesStationProtocol(station, protocol)
  return protocol == globalProtocol or protocol == stationProtocolFor(station)
end

function api.makeMessage(messageType, station, snapshot, extra)
  local message = {
    protocol_version = 1,
    message_type = messageType,
    station_id = station.station_id,
    station = {
      station_id = station.station_id,
      name = station.name,
      description = station.description,
      playlist_url = station.playlist_url,
      rednet_channel = station.rednet_channel,
      host_label = station.host_label,
    },
    snapshot = snapshot,
    sent_at_ms = os.epoch("utc"),
  }

  if extra then
    for key, value in pairs(extra) do
      message[key] = value
    end
  end

  return message
end

function api.broadcastAnnounce(station, snapshot)
  rednet.broadcast(api.makeMessage(config.message_types.announce, station, snapshot), globalProtocol)
end

function api.broadcastNowPlaying(station, snapshot)
  rednet.broadcast(api.makeMessage(config.message_types.now_playing, station, snapshot), stationProtocolFor(station))
end

function api.broadcastSync(station, snapshot)
  rednet.broadcast(api.makeMessage(config.message_types.sync, station, snapshot), stationProtocolFor(station))
end

function api.sendStationInfo(targetId, station, snapshot)
  rednet.send(targetId, api.makeMessage(config.message_types.station_info, station, snapshot), stationProtocolFor(station))
end

function api.sendNowPlaying(targetId, station, snapshot)
  rednet.send(targetId, api.makeMessage(config.message_types.now_playing, station, snapshot), stationProtocolFor(station))
end

function api.sendPing(station)
  rednet.broadcast(api.makeMessage(config.message_types.ping, station, nil), stationProtocolFor(station))
end

function api.requestTune(station)
  rednet.broadcast(api.makeMessage(config.message_types.tune_request, station, nil), stationProtocolFor(station))
end

return api
