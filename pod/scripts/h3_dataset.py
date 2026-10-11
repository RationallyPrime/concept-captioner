#!/usr/bin/env python3
"""Admit full approved H3 clips and group by exact frame count for the pinned loader."""

from __future__ import annotations

import argparse
import json
import math
import shutil
import subprocess
from fractions import Fraction
from itertools import pairwise
from pathlib import Path
from typing import Any

VIDEO_SUFFIXES = frozenset({".mp4", ".mov", ".m4v"})
IMAGE_SUFFIXES = frozenset({".jpg", ".jpeg", ".png", ".webp"})


def probe_clip(media: Path, resolution: int) -> dict[str, int]:
    result = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-count_frames",
            "-show_frames",
            "-show_entries",
            "stream=nb_read_frames,width,height,avg_frame_rate,time_base,duration:frame=best_effort_timestamp_time",
            "-of",
            "json",
            str(media),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    try:
        probe = json.loads(result.stdout)
        stream = probe["streams"][0]
        frames, width, height = (int(stream[key]) for key in ("nb_read_frames", "width", "height"))
        fps, tick = (float(Fraction(stream[key])) for key in ("avg_frame_rate", "time_base"))
        duration = float(stream["duration"])
        timestamps = [float(row["best_effort_timestamp_time"]) for row in probe["frames"]]
        if (
            result.returncode
            or len(timestamps) != frames
            or tick <= 0
            or not all(math.isfinite(v) for v in [fps, tick, duration, *timestamps])
        ):
            raise ValueError("incomplete decoded timing")
    except (ValueError, KeyError, IndexError, TypeError, ZeroDivisionError):
        raise ValueError(f"Cannot verify the complete approved H3 clip {media.name}") from None
    if not 5 <= frames <= 243 or frames % 17 != 5 or width % 32 or height % 32:
        raise ValueError(
            f"H3 clip {media.name} needs 17n+5 frames (5–243) and 32-aligned dimensions; "
            "approve its H3 segment in Images before captioning/training"
        )
    if width <= 0 or height <= 0 or width * height > resolution**2:
        raise ValueError(
            f"H3 clip {media.name} exceeds the training resolution cap. Increase the cap or "
            "approve a smaller segment in Images; the trainer will not crop approved clips"
        )
    # A coarse container tick is not permission to substitute 30/23.976 fps timing.
    tolerance = 0.000001  # ffprobe decimal timestamp rounding only
    intervals = [right - left for left, right in pairwise(timestamps)]
    intervals.append(duration - (timestamps[-1] - timestamps[0]))
    if abs(fps - 24) > 0.00001 or any(
        interval <= 0 or abs(interval - 1 / 24) > tolerance for interval in intervals
    ):
        raise ValueError(
            f"H3 clip {media.name} must have constant 24 fps timing. Choose a matching segment "
            "in Images; footage is never silently retimed"
        )
    return {"frames": frames, "width": width, "height": height, "fps": 24}


def dataset_groups(cfg: dict[str, Any], run_dir: Path) -> list[dict[str, Any]]:
    dataset = Path(cfg["dataset"]["path"])
    media = sorted(
        p for p in dataset.rglob("*") if p.suffix.lower() in IMAGE_SUFFIXES | VIDEO_SUFFIXES
    )
    groups: dict[int, list[Path]] = {}
    facts: list[dict[str, Any]] = []
    for file in media:
        if file.is_symlink() or not file.is_file():
            raise ValueError("H3 approved inputs must be regular media files")
        caption = file.with_suffix("." + cfg["dataset"]["caption_ext"].lstrip("."))
        if caption.is_symlink() or not caption.is_file():
            raise ValueError(f"H3 approved input {file.name} needs its saved caption")
        fact = (
            probe_clip(file, max(cfg["resolution"]))
            if file.suffix.lower() in VIDEO_SUFFIXES
            else {"frames": 1}
        )
        groups.setdefault(fact["frames"], []).append(file)
        facts.append({"file": file.relative_to(dataset).as_posix(), **fact})
    if not groups:
        raise ValueError("H3 training needs approved captioned images or clips")
    # A private view of the admitted dataset, not duplicate media bytes. The source path is
    # stable on Resume (pinned repull restores it); the view is rebuilt for each invocation.
    root = run_dir / "h3-inputs"
    if root.is_symlink():
        raise ValueError("H3 input view must not be a symbolic link")
    if root.exists():
        shutil.rmtree(root)
    root.mkdir()
    rows = []
    for count, files in sorted(groups.items()):
        folder = root / f"frames-{count}"
        folder.mkdir()
        for index, file in enumerate(files):
            # Nested dataset basenames may collide. Private aliases keep each caption paired.
            target = folder / f"input-{index:06d}{file.suffix.lower()}"
            target.symlink_to(file.resolve())
            target.with_suffix(".txt").symlink_to(
                file.with_suffix("." + cfg["dataset"]["caption_ext"].lstrip(".")).resolve()
            )
        rows.append(
            {
                "folder_path": str(folder),
                "caption_ext": "txt",
                "num_frames": count,
                "fps": 24,
                "auto_frame_count": False,
                "shrink_video_to_frames": True,
                "do_audio": count > 1,
                "buckets": True,
                "bucket_tolerance": 32,
                "square_crop": False,
                "random_crop": False,
                "random_scale": False,
                "resolution": [max(cfg["resolution"])] if count > 1 else list(cfg["resolution"]),
            }
        )
    (run_dir / "h3-inputs.json").write_text(json.dumps(facts, indent=2) + "\n")
    return rows


if __name__ == "__main__":
    argparse.ArgumentParser(description=__doc__).parse_args()
