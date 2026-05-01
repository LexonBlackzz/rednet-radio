#!/usr/bin/env python3
import argparse
import json
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_PUBLIC_BASE = "https://raw.githubusercontent.com/LexonBlackzz/rednet-radio/main"


@dataclass
class Layout:
    root: Path
    stations_file: Path
    playlists_dir: Path


def find_layout(explicit_root: str | None) -> Layout:
    if explicit_root:
        base = Path(explicit_root).resolve()
        stations = base / "stations.json"
        playlists = base / "playlists"
        if not stations.exists():
            raise SystemExit(f"Could not find stations.json in {base}")
        return Layout(base, stations, playlists)

    cwd = Path.cwd()
    candidates = [
        cwd,
        cwd / "site",
    ]

    for base in candidates:
        stations = base / "stations.json"
        playlists = base / "playlists"
        if stations.exists():
            return Layout(base, stations, playlists)

    raise SystemExit(
        "Could not find stations.json. Run this from the repo root, site/ folder, or pass --root."
    )


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8-sig") as handle:
        return json.load(handle)


def save_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")


def prompt(label: str, default: str | None = None, required: bool = True) -> str:
    while True:
        suffix = f" [{default}]" if default else ""
        value = input(f"{label}{suffix}: ").strip()
        if value:
            return value
        if default is not None:
            return default
        if not required:
            return ""


def normalize_github_url(url: str) -> str:
    if not url:
        return url
    if "github.com/" not in url or "/blob/" not in url:
        return url

    before_blob, after_blob = url.split("/blob/", 1)
    github_prefix = "https://github.com/"
    if not before_blob.startswith(github_prefix):
        return url

    repo_path = before_blob[len(github_prefix):]
    if "/" not in repo_path or "/" not in after_blob:
        return url

    branch, file_path = after_blob.split("/", 1)
    return f"https://raw.githubusercontent.com/{repo_path}/{branch}/{file_path}"


def next_track_id(tracks: list[dict]) -> str:
    highest = 0
    for track in tracks:
        track_id = str(track.get("id", ""))
        if track_id.startswith("track_"):
            try:
                highest = max(highest, int(track_id.split("_", 1)[1]))
            except ValueError:
                pass
    return f"track_{highest + 1:02d}"


def bump_version(value: object) -> str:
    try:
        return str(int(str(value)) + 1)
    except (TypeError, ValueError):
        return datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S")


def get_station_entry(stations_doc: dict, station_id: str) -> dict | None:
    for station in stations_doc.get("stations", []):
        if station.get("station_id") == station_id:
            return station
    return None


def get_playlist_path(layout: Layout, station_id: str) -> Path:
    return layout.playlists_dir / f"{station_id}.json"


def command_list(layout: Layout, _args: argparse.Namespace) -> int:
    stations_doc = load_json(layout.stations_file)
    stations = stations_doc.get("stations", [])
    if not stations:
        print("No stations found.")
        return 0

    for station in stations:
        print(f"{station['station_id']}: {station['name']}")
        print(f"  playlist: {station['playlist_url']}")
        if station.get("description"):
            print(f"  description: {station['description']}")
    return 0


def command_add_track(layout: Layout, args: argparse.Namespace) -> int:
    stations_doc = load_json(layout.stations_file)
    station_id = args.station_id or prompt("Station ID")
    station = get_station_entry(stations_doc, station_id)
    if not station:
        raise SystemExit(f"Station '{station_id}' was not found in {layout.stations_file}")

    playlist_path = get_playlist_path(layout, station_id)
    if not playlist_path.exists():
        raise SystemExit(f"Playlist file does not exist: {playlist_path}")

    playlist_doc = load_json(playlist_path)
    tracks = playlist_doc.setdefault("tracks", [])

    track = {
        "id": args.track_id or next_track_id(tracks),
        "title": args.title or prompt("Track title"),
        "artist": args.artist or prompt("Artist"),
        "duration": int(args.duration or prompt("Duration seconds")),
    }

    source_url = args.source_url
    if source_url is None:
        source_url = prompt("Source URL", required=False)
    if source_url:
        track["source_url"] = source_url

    playback_url = args.playback_url
    if playback_url is None:
        playback_url = prompt("Playback URL (.dfpwm)", required=False)
    if playback_url:
        track["playback_url"] = normalize_github_url(playback_url)

    art_url = args.art_url
    if art_url is None:
        art_url = prompt("Art URL", required=False)
    if art_url:
        track["art_url"] = art_url

    tracks.append(track)
    playlist_doc["version"] = bump_version(playlist_doc.get("version", "0"))
    save_json(playlist_path, playlist_doc)

    print(f"Added track '{track['title']}' to {playlist_path}")
    print(f"Track ID: {track['id']}")
    print(f"Playlist version: {playlist_doc['version']}")
    return 0


def command_create_station(layout: Layout, args: argparse.Namespace) -> int:
    stations_doc = load_json(layout.stations_file)
    stations = stations_doc.setdefault("stations", [])

    station_id = args.station_id or prompt("Station ID")
    if get_station_entry(stations_doc, station_id):
        raise SystemExit(f"Station '{station_id}' already exists.")

    name = args.name or prompt("Station name")
    description = args.description
    if description is None:
        description = prompt("Description", required=False)

    playlist_path = get_playlist_path(layout, station_id)
    public_base = (args.public_base_url or DEFAULT_PUBLIC_BASE).rstrip("/")
    playlist_url = f"{public_base}/playlists/{station_id}.json"

    station = {
        "station_id": station_id,
        "name": name,
        "description": description or "",
        "playlist_url": playlist_url,
        "rednet_channel": args.rednet_channel or f"rednet_radio_v1:station:{station_id}",
        "host_label": args.host_label or "",
    }

    stations.append(station)
    save_json(layout.stations_file, stations_doc)

    playlist_doc = {
        "name": args.playlist_name or f"{name} Playlist",
        "version": "1",
        "tracks": [],
    }
    save_json(playlist_path, playlist_doc)

    print(f"Created station '{station_id}'")
    print(f"Stations file: {layout.stations_file}")
    print(f"Playlist file: {playlist_path}")
    print(f"Playlist URL: {playlist_url}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Manage Rednet Radio stations and playlists.")
    parser.add_argument(
        "--root",
        help="Directory containing stations.json and playlists/. Defaults to repo root or site/.",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    list_parser = subparsers.add_parser("list", help="List known stations.")
    list_parser.set_defaults(handler=command_list)

    add_track = subparsers.add_parser("add-track", help="Add a track to an existing station playlist.")
    add_track.add_argument("station_id", nargs="?", help="Station ID, such as demo_station.")
    add_track.add_argument("--track-id", help="Optional explicit track ID.")
    add_track.add_argument("--title", help="Track title.")
    add_track.add_argument("--artist", help="Track artist.")
    add_track.add_argument("--source-url", help="Original source URL.")
    add_track.add_argument("--playback-url", help="DFPWM playback URL.")
    add_track.add_argument("--art-url", help="Optional cover art URL.")
    add_track.add_argument("--duration", type=int, help="Track duration in seconds.")
    add_track.set_defaults(handler=command_add_track)

    create_station = subparsers.add_parser("create-station", help="Create a new station and empty playlist.")
    create_station.add_argument("station_id", nargs="?", help="New station ID.")
    create_station.add_argument("--name", help="Station display name.")
    create_station.add_argument("--description", help="Station description.")
    create_station.add_argument("--playlist-name", help="Playlist display name.")
    create_station.add_argument("--rednet-channel", help="Optional explicit rednet channel.")
    create_station.add_argument("--host-label", help="Optional host label.")
    create_station.add_argument("--public-base-url", help="Public base URL for raw playlist files.")
    create_station.set_defaults(handler=command_create_station)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    layout = find_layout(args.root)
    layout.playlists_dir.mkdir(parents=True, exist_ok=True)
    return args.handler(layout, args)


if __name__ == "__main__":
    sys.exit(main())
