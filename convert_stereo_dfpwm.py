#!/usr/bin/env python3
"""Batch-convert audio files into paired left/right DFPWM outputs.

Examples:
  python convert_stereo_dfpwm.py input_music
  python convert_stereo_dfpwm.py input_music --output converted
  python convert_stereo_dfpwm.py input_music --recursive --overwrite
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

DEFAULT_SAMPLE_RATE = 48_000
DEFAULT_LOWPASS_HZ = 12000
DEFAULT_LIMIT = 0.90


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert audio files into _L.dfpwm and _R.dfpwm pairs."
    )
    parser.add_argument("input", type=Path, help="Folder containing source audio files.")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Output folder. Defaults to '<input>/dfpwm_stereo'.",
    )
    parser.add_argument(
        "-r",
        "--recursive",
        action="store_true",
        help="Scan subfolders recursively.",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite existing .dfpwm outputs.",
    )
    parser.add_argument(
        "--sample-rate",
        type=int,
        default=DEFAULT_SAMPLE_RATE,
        help=f"Target sample rate for DFPWM output. Default: {DEFAULT_SAMPLE_RATE}.",
    )
    parser.add_argument(
        "--normalize",
        action="store_true",
        help="Apply loudness normalization before channel split.",
    )
    parser.add_argument(
        "--tame-highs",
        action="store_true",
        help="Apply a gentle low-pass filter to reduce high-frequency squeakiness.",
    )
    parser.add_argument(
        "--lowpass-hz",
        type=int,
        default=DEFAULT_LOWPASS_HZ,
        help=f"Cutoff used by --tame-highs. Default: {DEFAULT_LOWPASS_HZ}.",
    )
    parser.add_argument(
        "--dither-8bit",
        action="store_true",
        help="Quantize through 8-bit unsigned PCM with triangular high-pass dither before DFPWM encode.",
    )
    parser.add_argument(
        "--limiter",
        action="store_true",
        help="Apply a lookahead limiter before channel split.",
    )
    parser.add_argument(
        "--limit",
        type=float,
        default=DEFAULT_LIMIT,
        help=f"Limiter ceiling for --limiter, from 0.0625 to 1. Default: {DEFAULT_LIMIT}.",
    )
    return parser.parse_args()


def ensure_ffmpeg_tools() -> None:
    missing = [tool for tool in ("ffmpeg", "ffprobe") if shutil.which(tool) is None]
    if missing:
        joined = ", ".join(missing)
        raise SystemExit(f"Missing required tool(s): {joined}. Please install FFmpeg.")


def list_candidate_files(input_dir: Path, recursive: bool, output_dir: Path) -> list[Path]:
    iterator = input_dir.rglob("*") if recursive else input_dir.glob("*")
    resolved_output = output_dir.resolve()
    candidates = []
    for path in iterator:
        if not path.is_file():
            continue
        if path.suffix.lower() == ".dfpwm":
            continue
        try:
            if resolved_output in path.resolve().parents:
                continue
        except OSError:
            pass
        candidates.append(path)
    return sorted(candidates)


def probe_channel_count(path: Path) -> int:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-select_streams",
        "a:0",
        "-show_entries",
        "stream=channels",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(path),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    value = result.stdout.strip()
    if not value:
        raise RuntimeError(f"Could not read audio channel count from '{path}'.")
    return max(1, int(value))


def is_ffmpeg_readable_audio(path: Path) -> bool:
    try:
        probe_channel_count(path)
        return True
    except Exception:
        return False


def build_pan_filters(channel_count: int) -> tuple[str, str]:
    if channel_count <= 1:
        return "pan=mono|c0=c0", "pan=mono|c0=c0"
    return "pan=mono|c0=c0", "pan=mono|c0=c1"


def build_filter_complex(
    channel_count: int,
    sample_rate: int,
    normalize: bool,
    tame_highs: bool,
    lowpass_hz: int,
    dither_8bit: bool,
    limiter: bool,
    limit: float,
) -> str:
    left_pan, right_pan = build_pan_filters(channel_count)

    pre_filters = []
    if normalize:
        pre_filters.append("loudnorm=I=-18:LRA=11:TP=-1.5")
    if tame_highs:
        pre_filters.append(f"lowpass=f={max(1000, int(lowpass_hz))}")
    if limiter:
        clamped_limit = min(1.0, max(0.0625, float(limit)))
        pre_filters.append(f"alimiter=limit={clamped_limit:.4f}:level=false")

    head = ",".join(pre_filters) if pre_filters else "anull"
    resample = f"aresample={sample_rate}"
    if dither_8bit:
        resample = f"aresample={sample_rate}:osf=u8:dither_method=triangular_hp"

    left_chain = f"{left_pan},{resample},aformat=sample_fmts=s16[left]"
    right_chain = f"{right_pan},{resample},aformat=sample_fmts=s16[right]"
    return f"[0:a:0]{head},asplit=2[l][r];[l]{left_chain};[r]{right_chain}"


def convert_file(
    source: Path,
    input_root: Path,
    output_root: Path,
    sample_rate: int,
    overwrite: bool,
    normalize: bool,
    tame_highs: bool,
    lowpass_hz: int,
    dither_8bit: bool,
    limiter: bool,
    limit: float,
) -> tuple[Path, Path]:
    relative_parent = source.parent.relative_to(input_root)
    target_dir = output_root / relative_parent
    target_dir.mkdir(parents=True, exist_ok=True)

    stem = source.stem
    left_output = target_dir / f"{stem}_L.dfpwm"
    right_output = target_dir / f"{stem}_R.dfpwm"

    if not overwrite and left_output.exists() and right_output.exists():
        print(f"Skipping {source.name}: outputs already exist")
        return left_output, right_output

    channel_count = probe_channel_count(source)
    filter_complex = build_filter_complex(
        channel_count, sample_rate, normalize, tame_highs, lowpass_hz, dither_8bit, limiter, limit
    )

    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-y" if overwrite else "-n",
        "-i",
        str(source),
        "-filter_complex",
        filter_complex,
        "-map",
        "[left]",
        "-c:a",
        "dfpwm",
        str(left_output),
        "-map",
        "[right]",
        "-c:a",
        "dfpwm",
        str(right_output),
    ]
    subprocess.run(cmd, check=True)
    return left_output, right_output


def main() -> int:
    args = parse_args()
    ensure_ffmpeg_tools()

    input_dir = args.input.resolve()
    if not input_dir.exists() or not input_dir.is_dir():
        print(f"Input folder does not exist: {input_dir}", file=sys.stderr)
        return 1

    output_dir = (args.output or (input_dir / "dfpwm_stereo")).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    candidates = list_candidate_files(input_dir, args.recursive, output_dir)
    files = [path for path in candidates if is_ffmpeg_readable_audio(path)]
    if not files:
        print("No FFmpeg-readable audio files found.")
        return 1

    failures = 0
    print(f"Found {len(files)} audio file(s). Writing DFPWM pairs to: {output_dir}")
    for index, source in enumerate(files, start=1):
        print(f"[{index}/{len(files)}] Converting {source.relative_to(input_dir)}")
        try:
            left_output, right_output = convert_file(
                source,
                input_dir,
                output_dir,
                args.sample_rate,
                args.overwrite,
                args.normalize,
                args.tame_highs,
                args.lowpass_hz,
                args.dither_8bit,
                args.limiter,
                args.limit,
            )
            print(f"  -> {left_output.name}")
            print(f"  -> {right_output.name}")
        except subprocess.CalledProcessError as exc:
            failures += 1
            print(f"  !! ffmpeg failed for {source.name} (exit {exc.returncode})", file=sys.stderr)
        except Exception as exc:  # noqa: BLE001
            failures += 1
            print(f"  !! {source.name}: {exc}", file=sys.stderr)

    if failures:
        print(f"Finished with {failures} failure(s).", file=sys.stderr)
        return 1

    print("Finished successfully.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
