#!/usr/bin/env python3
import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


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


def build_submission() -> dict:
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
        source_url = prompt("Source URL")
        playback_url = prompt("Playback URL (.dfpwm)")
        duration = int(prompt("Duration seconds"))
        art_url = prompt("Art URL", required=False)

        track = {
            "id": f"track_{track_number:02d}",
            "title": title,
            "artist": artist,
            "source_url": source_url,
            "playback_url": playback_url,
            "duration": duration,
        }
        if art_url:
            track["art_url"] = art_url

        tracks.append(track)
        track_number += 1

        another = prompt("Add another track? (y/n)", default="n").lower()
        if another not in ("y", "yes"):
            break

    return {
        "submission_type": "rednet_radio_playlist",
        "submitted_at_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "station": {
            "station_id": station_id,
            "name": station_name,
            "description": description,
        },
        "playlist": {
            "name": f"{station_name} Playlist",
            "version": "1",
            "tracks": tracks,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Create a Rednet Radio playlist submission JSON.")
    parser.add_argument(
        "--output",
        help="Output file path. Defaults to ./<station_id>_submission.json after prompts.",
    )
    args = parser.parse_args()

    submission = build_submission()
    station_id = submission["station"]["station_id"]
    output = Path(args.output or f"{station_id}_submission.json")
    with output.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(submission, handle, indent=2)
        handle.write("\n")

    print("")
    print(f"Wrote submission file: {output.resolve()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
