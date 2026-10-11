"""Run artifacts over the API: list and fetch what a trainer wrote (POD-SPEC §2.10, §2.11).

A user without a Hub account still has to get the trained LoRA off the pod, so the agent
serves the run's output directory, ``/workspace/runs/<id>/output/`` (both trainers write their
checkpoints, final weights and samples there), and nothing else:

- the listing walks the directory without following symlinks and reports regular files only,
  each with its size, SHA-256 and modification time;
- a fetch takes a relative path, refuses ``..``, ``.``, empty segments and NUL (422), then
  resolves it and refuses (404) anything that is not a regular file whose real path is exactly
  ``<real output root>/<path>``: a symlink anywhere on the way, the root included, never matches.

Hashing a multi-gigabyte output takes seconds, so digests are cached per process by (path,
size, mtime, inode): a repeated listing only hashes what changed.
"""

from __future__ import annotations

import hashlib
import os
import stat
import threading
from datetime import UTC, datetime
from pathlib import Path

from pydantic import BaseModel

from .errors import NotFound, Validation

OUTPUT_DIR = "output"
_CHUNK = 1 << 20


class RunFile(BaseModel):
    path: str  # relative to the output root, "/"-separated
    size: int
    sha256: str
    modified_at: str


class RunFiles(BaseModel):
    run_id: str
    root: str
    files: list[RunFile]


class _DigestCache:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._digests: dict[tuple[str, int, int, int], str] = {}

    def sha256(self, path: Path, info: os.stat_result) -> str:
        key = (str(path), info.st_size, info.st_mtime_ns, info.st_ino)
        with self._lock:
            cached = self._digests.get(key)
        if cached is not None:
            return cached
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            while chunk := handle.read(_CHUNK):
                digest.update(chunk)
        value = digest.hexdigest()
        with self._lock:
            self._digests[key] = value
        return value


_CACHE = _DigestCache()


def _iso(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, tz=UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def output_root(run_dir: Path) -> Path | None:
    """The run's real output directory, or ``None`` when it is absent or not a plain directory."""
    root = run_dir / OUTPUT_DIR
    try:
        info = root.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISDIR(info.st_mode):  # a symlink (or a file) named output is not served
        return None
    return root.resolve()


def list_run_files(run_id: str, run_dir: Path) -> RunFiles:
    root = output_root(run_dir)
    files: list[RunFile] = []
    if root is not None:
        for directory, dirnames, filenames in os.walk(root, followlinks=False):
            here = Path(directory)
            # os.walk lists symlinked directories but, without followlinks, never enters them.
            dirnames.sort()
            for name in sorted(filenames):
                path = here / name
                info = path.lstat()
                if not stat.S_ISREG(info.st_mode):
                    continue
                files.append(
                    RunFile(
                        path=path.relative_to(root).as_posix(),
                        size=info.st_size,
                        sha256=_CACHE.sha256(path, info),
                        modified_at=_iso(info.st_mtime),
                    )
                )
    files.sort(key=lambda item: item.path)
    return RunFiles(run_id=run_id, root=str(run_dir / OUTPUT_DIR), files=files)


def resolve_run_file(run_id: str, run_dir: Path, relative: str) -> Path:
    """The real path of output file ``relative``; ``Validation`` or ``NotFound`` otherwise."""
    parts = relative.split("/")
    if "\x00" in relative or any(part in {"", ".", ".."} for part in parts):
        raise Validation(
            "file path must be relative to the run's output directory, without '.', '..' "
            "or empty segments",
            detail={"field": "path", "value": relative},
        )
    missing = NotFound(f"no file {relative!r} in the output of run {run_id!r}")
    root = output_root(run_dir)
    if root is None:
        raise missing
    try:
        real = (root / relative).resolve(strict=True)
    except (OSError, RuntimeError):  # missing, or a symlink loop
        raise missing from None
    if real != root.joinpath(*parts):  # a symlink somewhere on the way
        raise missing
    if not stat.S_ISREG(real.lstat().st_mode):
        raise missing
    return real
