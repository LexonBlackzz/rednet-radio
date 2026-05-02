# Rednet Radio

Modular `CC:Tweaked` radio scripts backed by a simple website that hosts station and playlist JSON.

## What This Includes

- `radio_host.lua`: runs a radio station host on a ComputerCraft computer
- `radio_client.lua`: browses stations and tunes in on another ComputerCraft computer
- `rednet_radio/`: shared Lua modules for HTTP, playlist parsing, rednet sync, and station state
- `site/`: sample static files you can upload to InfinityFree or another free host

## How It Works

1. Your website hosts `stations.json` plus one or more playlist JSON files.
2. A station host fetches its station definition and playlist from the website.
3. The host rotates through the playlist and broadcasts `now playing` and `sync` data over `rednet`.
4. Listener computers fetch the station directory from the website, tune in over `rednet`, and stay synchronized.

## ComputerCraft Requirements

- `CC:Tweaked`
- `http.enabled=true`
- a modem attached to each participating computer

## Quick Start
1. On the station computer, run:

```lua
radio_host demo_station
```

2. On another computer, run:

```lua
radio_client
```

## Pastebin Installer

You can also install this inside ComputerCraft using a single installer script.

1. Upload [install.lua](https://github.com/LexonBlackzz/rednet-radio/blob/main/install.lua) to Pastebin.
2. Upload the installable Lua files to a static host under one folder, for example:
   - `radio_host.lua`
   - `radio_client.lua`
   - `rednet_radio/config.lua`
   - `rednet_radio/util.lua`
   - `rednet_radio/directory.lua`
   - `rednet_radio/playlist.lua`
   - `rednet_radio/station.lua`
   - `rednet_radio/rednet_api.lua`
   - `rednet_radio/audio.lua`
   - `rednet_radio/monitor.lua`
3. On a ComputerCraft computer, run:

```lua
pastebin run <your-pastebin-id>
```

4. The installer will ask for:
   - install role: `host`, `client`, or `all`
   - package base URL: the folder URL containing the Lua files
   - website base URL: the site URL containing `stations.json`

Current package URL:

```text
https://raw.githubusercontent.com/LexonBlackzz/rednet-radio/main/package
```

Current website URL:

```text
https://raw.githubusercontent.com/LexonBlackzz/rednet-radio/main
```

With your current layout, keep `stations.json` and `playlists/` at the repo root, and keep installable Lua files under `package/`.

## Website Layout

- `stations.json`: station directory
- `playlists/<station-id>.json`: playlist data for each station

## Playlist Tool

Use [manage_radio.py](https://github.com/LexonBlackzz/rednet-radio/blob/main/manage_radio.py) to avoid hand-editing JSON.

List stations:

```text
python manage_radio.py list
```

Add a track interactively:

```text
python manage_radio.py add-track demo_station
```

Create a new station plus an empty playlist:

```text
python manage_radio.py create-station chill
```

If your `stations.json` and `playlists/` live somewhere else, pass `--root`:

```text
python manage_radio.py --root C:\path\to\repo create-station chill
```

## Submission Tool

Use [playlist_submission.py](https://github.com/LexonBlackzz/rednet-radio/blob/main/playlist_submission.py) if you want contributors to build a ready-to-send JSON file.

They run:

```text
python playlist_submission.py
```

It asks for:
- station ID
- station name
- description
- each track's title, artist, source URL, playback URL, and duration

It writes a file like:

```text
demo_station.json
```

By default this is a drop-in playlist file you can place in `playlists/`.

If you want the older wrapped submission format with station metadata too:

```text
python playlist_submission.py --wrap-submission
```

That writes a file like:

```text
demo_station_submission.json
```

The host now accepts both plain playlist files and wrapped submission JSON.

## Monitor Support

If a `monitor` peripheral is attached:

- `radio_client` mirrors its now-playing screen to the monitor
- `radio_host` shows the current station/track on the monitor and logs track changes in the terminal

## Track Gaps

Tracks now include a short intermission gap by default so the next song start is less likely to get clipped during re-sync.

The default gap is:

```text
2 seconds
```

You can change it in [rednet_radio/config.lua]([/d:/Projects/rednet%20radio/rednet_radio/config.lua](https://github.com/LexonBlackzz/rednet-radio/blob/main/package/rednet_radio/config.lua)) with:

```lua
track_gap_seconds = 2,
```

Automatic playlist/directory refresh is disabled by default for stability during long-running broadcasts:

```lua
playlist_refresh_seconds = 0,
directory_refresh_seconds = 0,
```

If you want live reloads later, set them to a positive number of seconds.

## Notes About Audio

This project now supports client-side `.dfpwm` playback through the speaker peripheral.

Normal MP3 links are still just source assets and metadata. For in-game playback, tracks should provide a `playback_url` pointing to a `.dfpwm` file.

If you use GitHub-hosted audio, use raw file URLs, not `github.com/.../blob/...` page URLs. The helper scripts will convert common GitHub blob links to `raw.githubusercontent.com` automatically.
