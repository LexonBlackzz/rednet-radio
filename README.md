# Rednet Radio

Modular `CC:Tweaked` radio scripts backed by a simple website that hosts station and playlist JSON.

## What This Includes

- `radio_host.lua`: runs a radio station host on a ComputerCraft computer
- `radio_client.lua`: browses stations and tunes in on another ComputerCraft computer
- `rednet_radio/`: shared Lua modules for HTTP, playlist parsing, rednet sync, and station state
- `radio_studio.py`: A Python GUI desktop app to easily create stations and edit playlists without hand-typing JSON.
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

1. Upload `install.lua` to Pastebin.
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

## Rednet Radio Studio (GUI)

Forget hand-editing JSON! We now include a unified, easy-to-use desktop application for managing stations and playlists. 

**Requirements:** Python 3 (No external libraries required; runs entirely on the standard `tkinter` library).

**To launch:**
```text
python radio_studio.py
```
*(Or simply double-click the file on Windows).*

### Studio Features:
- **Workspace Initialization:** Run the tool in an empty folder and it will offer to automatically build your `stations.json` and `playlists/` layout for you.
- **Station Manager:** Create and configure stations directly in the UI.
- **Playlist Editor:** Add, edit, or delete tracks seamlessly.
- **Auto-Fill:** Paste a GitHub `.dfpwm` link and click Auto-Fill. It automatically converts the URL to a raw download link, and guesses the Artist and Title directly from the filename.
- **Smart Duration Parser:** You no longer need to calculate seconds manually. Type natural durations like `3:45` or `1:05:20` and the app handles the math automatically.
- **Standalone Submissions:** Allows community contributors to build ready-to-send JSON playlists to submit to you, without needing write-access to your workspace.

## Monitor Support

If a `monitor` peripheral is attached:

- `radio_client` mirrors its now-playing screen to the monitor, complete with interactive touch buttons, a fast-updating audio visualizer, and a stream buffer health bar.
- `radio_host` shows the current station/track on the monitor, including interactive settings buttons, and logs track changes in the terminal.

## Track Gaps

Tracks now include a short intermission gap by default so the next song start is less likely to get clipped during re-sync.

The default gap is:

```text
2 seconds
```

You can change it in `rednet_radio/config.lua` with:

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

If you use GitHub-hosted audio, use raw file URLs, not `github.com/.../blob/...` page URLs. The Radio Studio GUI will convert common GitHub blob links to `raw.githubusercontent.com` automatically for you!
