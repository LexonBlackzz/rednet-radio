local baseUrl = "https://rednetradio.rf.gd"

return {
  base_url = baseUrl,
  directory_url = baseUrl .. "/stations.json",
  package_url = baseUrl .. "/install",
  cache_dir = "/rednet_radio_cache",
  protocol = "rednet_radio_v1",
  announce_interval_seconds = 30,
  sync_interval_seconds = 5,
  playlist_refresh_seconds = 60,
  directory_refresh_seconds = 120,
  client_ping_interval_seconds = 8,
  message_types = {
    announce = "announce",
    station_info = "station_info",
    now_playing = "now_playing",
    sync = "sync",
    ping = "ping",
    tune_request = "tune_request",
  },
}
