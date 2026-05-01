#!/usr/bin/env python3
import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse


def prompt(label: str, required: bool = True, default: str | None = None) -> str:
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

    parsed = urlparse(url)
    if parsed.netloc not in {"github.com", "www.github.com"}:
        return url

    parts = [part for part in parsed.path.split("/") if part]
    if len(parts) < 5 or parts[2] != "blob":
        return url

    owner, repo, _blob, branch = parts[:4]
    rest = "/".join(parts[4:])
    return f"https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{rest}"


def build_submission(wrap_submission: bool) -> tuple[str, dict]:
    station_id = prompt("Station ID")
    station_name = prompt("Station name")
    description = prompt("Description", required=False)

    tracks = []
    track_number = 1
    while True:
        print("")
        print(f"Track {track_number}")
        title = prompt("Title")
        artist = prompt("Artist")
        source_url = prompt("Source URL", required=False)
        playback_url = normalize_github_url(prompt("Playback URL (.dfpwm)"))
        duration = int(prompt("Duration seconds"))
        art_url = prompt("Art URL", required=False)

        track = {
            "id": f"track_{track_number:02d}",
            "title": title,
            "artist": artist,
            "duration": duration,
        }
        if source_url:
            track["source_url"] = source_url
        if playback_url:
            track["playback_url"] = playback_url
        if art_url:
            track["art_url"] = art_url

        tracks.append(track)
        track_number += 1

        another = prompt("Add another track? (y/n)", default="n").lower()
        if another not in ("y", "yes"):
            break

    playlist = {
        "name": f"{station_name} Playlist",
        "version": "1",
        "tracks": tracks,
    }

    if not wrap_submission:
        return station_id, playlist

    return station_id, {
        "submission_type": "rednet_radio_playlist",
        "submitted_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "station": {
            "station_id": station_id,
            "name": station_name,
            "description": description,
        },
        "playlist": playlist,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Create a Rednet Radio playlist submission JSON.")
    parser.add_argument(
        "--output",
        help="Output file path. Defaults to ./<station_id>_submission.json after prompts.",
    )
    parser.add_argument(
        "--wrap-submission",
        action="store_true",
        help="Wrap the playlist in a submission envelope with station metadata.",
    )
    args = parser.parse_args()

    station_id, submission = build_submission(args.wrap_submission)
    if args.wrap_submission:
        default_name = f"{station_id}_submission.json"
    else:
        default_name = f"{station_id}.json"
    output = Path(args.output or default_name)
    with output.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(submission, handle, indent=2)
        handle.write("\n")

    print("")
    print(f"Wrote submission file: {output.resolve()}")
    if not args.wrap_submission:
        print("This file is a drop-in playlist JSON for playlists/<station_id>.json")
    else:
        print("This file is a wrapped submission JSON; the host now accepts this too.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
