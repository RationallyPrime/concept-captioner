"""Dataset retention for completed runs; checkpoints, models and unknown work are never removed."""

from __future__ import annotations

import argparse
import json
import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .checkpoints import checkpoint_step, latest_checkpoint
from .errors import AgentError
from .events import RUN_ID_RE
from .settings import Paths

RUN_STATE_FILE = "run-state.json"
KEEP_RESUMABLE = 3


def _json(path: Path) -> dict[str, Any]:
    if path.is_symlink():
        raise ValueError("symlinked run metadata")
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError("invalid run metadata")
    return data


def dataset_folder(paths: Paths, value: Any) -> Path | None:
    if not isinstance(value, str):
        return None
    folder = Path(value)
    root = paths.datasets.resolve()
    # The app's per-run datasets are direct children. Custom nested layouts stay untouched.
    if folder.parent.resolve() != root or not RUN_ID_RE.fullmatch(folder.name):
        return None
    if folder.is_symlink() or folder.resolve() != root / folder.name:
        return None
    return folder


def dataset_ancestor(paths: Paths, value: Any) -> Path | None:
    """The top-level ``datasets/`` folder holding a nested path, which cleanup must leave alone."""
    if not isinstance(value, str):
        return None
    try:
        relative = Path(value).resolve().relative_to(paths.datasets.resolve())
    except ValueError:
        return None
    return paths.datasets / relative.parts[0] if relative.parts else None


def tree_bytes(root: Path) -> int:
    if root.is_symlink() or not root.is_dir():
        return 0
    total = 0
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = [name for name in dirs if not (Path(directory) / name).is_symlink()]
        for name in files:
            file = Path(directory) / name
            if not file.is_symlink() and file.is_file():
                total += file.stat().st_size
    return total


def regularization_folder(paths: Paths, config: dict[str, Any]) -> Path | None:
    """The ``datasets/`` folder a run's provided regularisation set was read from, if any.

    A run copies the set into its own directory, so the folder matters only to a Repeat or a
    restart, but it is protected exactly like ``dataset.path``: while its run is active or
    resumable it stays, afterwards it is as removable as any other run input.
    """
    block = config.get("regularization")
    if not isinstance(block, dict) or block.get("source") != "folder":
        return None
    return dataset_folder(paths, block.get("path"))


def nested_regularization_ancestor(paths: Paths, config: dict[str, Any]) -> Path | None:
    """For a provided set nested deeper in ``datasets/``, the top-level folder holding it.

    Like a nested primary dataset, it is never removed: it may be another run's input.
    """
    block = config.get("regularization")
    if not isinstance(block, dict) or block.get("source") != "folder":
        return None
    if dataset_folder(paths, block.get("path")) is not None:
        return None
    return dataset_ancestor(paths, block.get("path"))


@dataclass(frozen=True)
class _CompletedRun:
    run_id: str
    dataset: Path
    resumable_at: int | None
    regularization: Path | None = None

    @property
    def folders(self) -> tuple[Path, ...]:
        return (
            (self.dataset,) if self.regularization is None else (self.dataset, self.regularization)
        )


def cleanup_candidates(
    paths: Paths, *, keep_run_ids: set[str] | None = None, keep_datasets: set[Path] | None = None
) -> list[Path]:
    protected = set(keep_datasets or ())
    keep = set(keep_run_ids or ())
    completed: list[_CompletedRun] = []
    for run in sorted(paths.runs.iterdir()) if paths.runs.exists() else []:
        if run.is_symlink() or not run.is_dir() or not RUN_ID_RE.fullmatch(run.name):
            continue
        config = run / "run.json"
        if not config.exists():
            if (run / "generation.json").exists():
                try:
                    generation = _json(run / "generation.json")
                    state = _json(run / RUN_STATE_FILE)
                    if not (
                        state.get("state") == "exited"
                        and state.get("exit_code") == 0
                        and state.get("group_alive") is False
                    ):
                        keep.add(generation["source_run_id"])
                except (OSError, ValueError, KeyError):
                    return []
            continue
        try:
            cfg = _json(config)
        except (OSError, ValueError):
            return []  # an unreadable training record could reference a shared dataset
        dataset = cfg.get("dataset")
        if not isinstance(dataset, dict):
            return []
        nested_reg = nested_regularization_ancestor(paths, cfg)
        if nested_reg is not None:
            protected.add(nested_reg)
        folder = dataset_folder(paths, dataset.get("path"))
        if folder is None:
            ancestor = dataset_ancestor(paths, dataset.get("path"))
            if ancestor is not None:
                protected.add(ancestor)
            continue
        reg_folder = regularization_folder(paths, cfg)
        if run.name in keep:
            protected.add(folder)
            if reg_folder is not None:
                protected.add(reg_folder)
        try:
            state = _json(run / RUN_STATE_FILE)
            trainer = str(state.get("name", "")).removeprefix("trainer-")
            if not (
                cfg.get("run_id") == run.name == state.get("run_id")
                and state.get("state") == "exited"
                and state.get("exit_code") == 0
                and state.get("group_alive") is False
                and trainer in {"aitoolkit", "ltx"}
            ):
                protected.update(filter(None, (folder, reg_folder)))
                continue
        except (OSError, ValueError):
            protected.update(filter(None, (folder, reg_folder)))
            continue
        stamp = None
        try:
            checkpoint = latest_checkpoint(run, trainer, run.name)
            if checkpoint is not None:
                checkpoint_step(checkpoint, trainer)
                stamp = checkpoint.stat().st_mtime_ns
        except (OSError, ValueError, AgentError):
            pass
        completed.append(_CompletedRun(run.name, folder, stamp, reg_folder))
    resumable = sorted(
        (run for run in completed if run.resumable_at is not None),
        key=lambda run: (run.resumable_at, run.run_id),
        reverse=True,
    )
    protected.update(folder for run in resumable[:KEEP_RESUMABLE] for folder in run.folders)
    protected.update(folder for run in completed if run.run_id in keep for folder in run.folders)
    return sorted(
        {
            folder
            for run in completed
            for folder in run.folders
            if folder not in protected and folder.is_dir()
        }
    )


def cleanup_datasets(paths: Paths, **protection: Any) -> dict[str, Any]:
    removed = []
    reclaimed = 0
    for folder in cleanup_candidates(paths, **protection):
        if dataset_folder(paths, str(folder)) != folder or folder.is_symlink():
            continue
        size = tree_bytes(folder)
        shutil.rmtree(folder)
        removed.append(folder.name)
        reclaimed += size
    return {"removed": removed, "reclaimed_bytes": reclaimed}


def storage_usage(paths: Paths) -> dict[str, int]:
    disk = shutil.disk_usage(paths.workspace)
    return {
        "total_bytes": disk.total,
        "used_bytes": disk.used,
        "free_bytes": disk.free,
        "datasets_bytes": tree_bytes(paths.datasets),
        "reclaimable_dataset_bytes": sum(tree_bytes(p) for p in cleanup_candidates(paths)),
        # The reuse cache of generated regularisation images; cleanup never removes it.
        "regularization_cache_bytes": tree_bytes(paths.regsets),
    }


def write_run_state(paths: Paths, state: Any) -> None:
    if not state.name.startswith(("trainer-", "generate-")) or not state.run_id:
        return
    target = paths.run_dir(state.run_id) / RUN_STATE_FILE
    payload = {
        key: getattr(state, key) for key in ("name", "run_id", "state", "exit_code", "group_alive")
    }
    data = json.dumps(payload, sort_keys=True) + "\n"
    temporary = target.with_suffix(".tmp")
    try:
        if not target.is_symlink() and target.exists() and target.read_text() == data:
            return
        temporary.write_text(data)
        os.replace(temporary, target)
    except OSError:
        # Never let stale success evidence authorize pruning during a new/unknown incarnation.
        target.unlink(missing_ok=True)
        raise


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Print the cleanup completed by the validated catalog step"
    )
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    print(args.report.read_text(), end="", flush=True)


if __name__ == "__main__":
    main()
