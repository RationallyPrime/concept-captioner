"""Run artifacts over the API: list and fetch what a trainer wrote (POD-SPEC §2.10, §2.11).

A user without a Hub account still has to get the trained LoRA off the pod, so the agent
serves the run's output directory, ``/workspace/runs/<id>/output/`` (both trainers write their
checkpoints, final weights and samples there), and its training logs, ``trainer.log`` and the
TensorBoard event files under ``tensorboard/`` (POD-SPEC §2.10a), and nothing else:

- the listing walks the directory without following symlinks and reports regular files only,
  each with its size, SHA-256 and modification time;
- a fetch takes a relative path, refuses ``..``, ``.``, empty segments and NUL (422), then
  resolves it and refuses (404) anything that is not a regular file whose real path is exactly
  ``<real output root>/<path>``: a symlink anywhere on the way, the root included, never matches.
  Log paths are relative to the run directory and must be ``trainer.log`` or lie under
  ``tensorboard/``; the same rules apply with the run directory as the root.

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
LOG_FILE = "trainer.log"
EVENTS_DIR = "tensorboard"
_CHUNK = 1 << 20


class RunFile(BaseModel):
    path: str  # relative to the listing's root, "/"-separated
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


def _plain_dir(path: Path) -> Path | None:
    """``path`` resolved, or ``None`` when it is absent or not a plain directory (a symlink)."""
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISDIR(info.st_mode):  # a symlink (or a file) of that name is not served
        return None
    return path.resolve()


def output_root(run_dir: Path) -> Path | None:
    """The run's real output directory, or ``None`` when it is absent or not a plain directory."""
    return _plain_dir(run_dir / OUTPUT_DIR)


def _run_file(path: Path, info: os.stat_result, root: Path) -> RunFile:
    return RunFile(
        path=path.relative_to(root).as_posix(),
        size=info.st_size,
        sha256=_CACHE.sha256(path, info),
        modified_at=_iso(info.st_mtime),
    )


def _walk(directory: Path, root: Path) -> list[RunFile]:
    """Every regular file under ``directory``, with paths relative to ``root``."""
    files: list[RunFile] = []
    for here, dirnames, filenames in os.walk(directory, followlinks=False):
        # os.walk lists symlinked directories but, without followlinks, never enters them.
        dirnames.sort()
        for name in sorted(filenames):
            path = Path(here) / name
            info = path.lstat()
            if stat.S_ISREG(info.st_mode):
                files.append(_run_file(path, info, root))
    return files


def list_run_files(run_id: str, run_dir: Path) -> RunFiles:
    root = output_root(run_dir)
    files = _walk(root, root) if root is not None else []
    files.sort(key=lambda item: item.path)
    return RunFiles(run_id=run_id, root=str(run_dir / OUTPUT_DIR), files=files)


def list_run_logs(run_id: str, run_dir: Path) -> RunFiles:
    """``trainer.log`` and every regular file under ``tensorboard/``, relative to the run directory."""
    root = run_dir.resolve()
    files: list[RunFile] = []
    log = root / LOG_FILE
    try:
        info = log.lstat()
    except FileNotFoundError:
        pass
    else:
        if stat.S_ISREG(info.st_mode):  # a symlink named trainer.log is not served
            files.append(_run_file(log, info, root))
    events = _plain_dir(root / EVENTS_DIR)
    if events is not None:
        files += _walk(events, root)
    files.sort(key=lambda item: item.path)
    return RunFiles(run_id=run_id, root=str(run_dir), files=files)


def _check_relative(relative: str, where: str) -> list[str]:
    parts = relative.split("/")
    if "\x00" in relative or any(part in {"", ".", ".."} for part in parts):
        raise Validation(
            f"file path must be relative to the run's {where}, without '.', '..' or empty segments",
            detail={"field": "path", "value": relative},
        )
    return parts


def _real_file(root: Path | None, parts: list[str], missing: NotFound) -> Path:
    """``root/<parts>`` when it is a regular file reached without a symlink, else ``missing``."""
    if root is None:
        raise missing
    try:
        real = root.joinpath(*parts).resolve(strict=True)
    except (OSError, RuntimeError):  # missing, or a symlink loop
        raise missing from None
    if real != root.joinpath(*parts):  # a symlink somewhere on the way
        raise missing
    if not stat.S_ISREG(real.lstat().st_mode):
        raise missing
    return real


def resolve_run_file(run_id: str, run_dir: Path, relative: str) -> Path:
    """The real path of output file ``relative``; ``Validation`` or ``NotFound`` otherwise."""
    parts = _check_relative(relative, "output directory")
    missing = NotFound(f"no file {relative!r} in the output of run {run_id!r}")
    return _real_file(output_root(run_dir), parts, missing)


def resolve_log_file(run_id: str, run_dir: Path, relative: str) -> Path:
    """The real path of log file ``relative`` (``trainer.log`` or under ``tensorboard/``)."""
    parts = _check_relative(relative, "directory")
    missing = NotFound(f"no log file {relative!r} in run {run_id!r}")
    if parts != [LOG_FILE] and (len(parts) < 2 or parts[0] != EVENTS_DIR):
        raise missing
    return _real_file(run_dir.resolve(), parts, missing)
