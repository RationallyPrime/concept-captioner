"""The pinned trainers' saved checkpoint layout and training-step facts, without torch."""

from __future__ import annotations

import json
import re
import struct
from pathlib import Path

from .artifacts import resolve_run_file


def latest_checkpoint(run_dir: Path, trainer: str, run_id: str) -> Path | None:
    output = run_dir / "output"
    if trainer == "aitoolkit":
        weights = (output / run_id).glob(f"{run_id}*.safetensors")
        candidates = [
            p for p in weights if not any(s in p.name for s in ("_LoRA", "_refiner", "_t2i", "_cn"))
        ]
    else:
        candidates = list(output.rglob("*.safetensors"))
    candidates = [
        resolve_run_file(run_id, run_dir, p.relative_to(output).as_posix()) for p in candidates
    ]
    if not candidates:
        return None
    # AI Toolkit selects by creation time; the LTX wrapper selects by modification time.
    return max(
        candidates,
        key=lambda p: (
            p.stat().st_ctime_ns if trainer == "aitoolkit" else p.stat().st_mtime_ns,
            str(p),
        ),
    )


def checkpoint_step(checkpoint: Path, trainer: str) -> int:
    if trainer == "ltx":
        match = re.search(r"step_(\d+)\.safetensors$", checkpoint.name)
        state = checkpoint.parent / f"training_state_step_{match.group(1)}.pt" if match else None
        if state is None or state.is_symlink() or not state.is_file():
            raise ValueError(
                "LTX resume needs the matching training_state_step file on this storage"
            )
        return int(match.group(1))
    with checkpoint.open("rb") as file:
        prefix = file.read(8)
        if len(prefix) != 8:
            raise ValueError("Checkpoint has no readable saved training step")
        length = struct.unpack("<Q", prefix)[0]
        if not 0 < length <= 16 * 1024 * 1024:
            raise ValueError("Checkpoint has no readable saved training step")
        header = json.loads(file.read(length))
    metadata = header.get("__metadata__") if isinstance(header, dict) else None
    encoded = metadata.get("training_info") if isinstance(metadata, dict) else None
    if not isinstance(encoded, str):
        raise ValueError("Checkpoint has no readable saved training step")
    info = json.loads(encoded)
    if not isinstance(info, dict):
        raise ValueError("Checkpoint has no readable saved training step")
    step = info.get("step")
    if type(step) is not int or step < 0:
        raise ValueError("Checkpoint has no readable saved training step")
    return step
