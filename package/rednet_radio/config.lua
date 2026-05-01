local baseUrl = "https://raw.githubusercontent.com/LexonBlackzz/rednet-radio/main"

return {
  base_url = baseUrl,
  directory_url = baseUrl .. "/stations.json",
  package_url = baseUrl .. "/package",
  cache_dir = "/rednet_radio_cache",
  protocol = "rednet_radio_v1",
  announce_interval_seconds = 30,
  sync_interval_seconds = 5,
  playlist_refresh_seconds = 0,
  directory_refresh_seconds = 0,
  client_ping_interval_seconds = 8,
  track_gap_seconds = 2,
  message_types = {
    announce = "announce",
    station_info = "station_info",
    now_playing = "now_playing",
    sync = "sync",
    ping = "ping",
    tune_request = "tune_request",
  },
}
