"""The app's flat local-dataset staging area; no arbitrary workspace writes."""

from __future__ import annotations

import asyncio
import os
import runpy
import threading
from pathlib import Path

from fastapi import Request

from .errors import BadRequest, PayloadTooLarge, Validation
from .events import RUN_ID_RE
from .settings import Paths

_rules_path = Path(os.environ.get("PODAGENT_PREFIX", "/opt")) / "pod/scripts/dataset_stage.py"
if not _rules_path.is_file():
    _rules_path = Path(__file__).resolve().parents[3] / "scripts/dataset_stage.py"
_rules = runpy.run_path(str(_rules_path))
MAX_UPLOAD_BYTES = _rules["MAX_UPLOAD_BYTES"]
MAX_STAGED_BYTES = _rules["MAX_STAGED_BYTES"]
INSTALLING = _rules["INSTALLING"]
STAGING_LOCK = threading.RLock()


def upload_folder(paths: Paths, name: str) -> Path:
    if not RUN_ID_RE.fullmatch(name):
        raise Validation("Invalid upload dataset name")
    try:
        return _rules["confined_stage"](paths.uploads / name, paths.workspace)
    except ValueError as error:
        raise Validation(str(error)) from error


def upload_name(paths: Paths, file_name: str) -> None:
    if not file_name or file_name in {".", ".."} or any(c in file_name for c in ("/", "\\", "\0")):
        raise Validation("Upload file_name must be one basename")
    script = paths.scripts / "pull_dataset.py"
    if not script.is_file():
        script = Path(__file__).resolve().parents[3] / "scripts/pull_dataset.py"
    suffixes = runpy.run_path(str(script))["IMAGE_SUFFIXES"]
    if file_name not in {"metadata.jsonl", "job.yaml"} and Path(file_name).suffix.lower() not in (
        suffixes | {".txt", ".json"}
    ):
        raise Validation(
            "Upload accepts supported media, caption/response sidecars, metadata.jsonl and job.yaml"
        )


def stage_bytes(folder: Path) -> int:
    total = 0
    for file in folder.iterdir() if folder.exists() else []:
        if file.is_symlink() or not file.is_file():
            raise Validation("Upload staging must contain regular flat files only")
        if file.name != INSTALLING and not file.name.endswith(".part"):
            total += file.stat().st_size
    return total


def claim_stage(paths: Paths, name: str) -> None:
    with STAGING_LOCK:
        folder = upload_folder(paths, name)
        stage_bytes(folder)
        if not folder.is_dir() or not (folder / "metadata.jsonl").is_file():
            raise Validation(
                "Upload metadata.jsonl and its approved files before preparing the local dataset"
            )
        if (folder / INSTALLING).exists() or any(folder.glob("*.part")):
            raise Validation("Wait for the active upload or local dataset preparation to finish")
        (folder / INSTALLING).touch(exist_ok=False)


def release_stage(paths: Paths, name: str) -> None:
    with STAGING_LOCK:
        (upload_folder(paths, name) / INSTALLING).unlink(missing_ok=True)


class UploadWriter:
    def __init__(self, paths: Paths) -> None:
        self.paths = paths
        self.lock = asyncio.Lock()  # serialize staged byte accounting across file streams

    async def write(self, request: Request, name: str, file_name: str) -> dict[str, str | int]:
        upload_name(self.paths, file_name)
        folder = upload_folder(self.paths, name)
        declared = request.headers.get("content-length")
        if declared is None or not declared.isdecimal():
            raise BadRequest("An accurate Content-Length is required for upload")
        length = int(declared)
        if length > MAX_UPLOAD_BYTES:
            raise PayloadTooLarge("Upload exceeds the 2 GiB per-file limit")
        async with self.lock:
            with STAGING_LOCK:
                folder.mkdir(parents=True, exist_ok=True)
                destination = folder / file_name
                temporary = folder / (file_name + ".part")
                if destination.is_symlink() or temporary.is_symlink():
                    raise Validation("Upload destination must not be a symbolic link")
                if (folder / INSTALLING).exists():
                    raise Validation(
                        "Local dataset preparation is active; upload after it finishes"
                    )
                prior = destination.stat().st_size if destination.exists() else 0
                if stage_bytes(folder) - prior + length > MAX_STAGED_BYTES:
                    raise PayloadTooLarge("Upload exceeds the 20 GiB staged-dataset limit")
                file = temporary.open("wb")
            received = 0
            try:
                with file:
                    async for chunk in request.stream():
                        received += len(chunk)
                        if received > length or received > MAX_UPLOAD_BYTES:
                            raise PayloadTooLarge("Upload body exceeds its declared Content-Length")
                        file.write(chunk)
                if received != length:
                    raise BadRequest("Upload body does not match Content-Length")
                with STAGING_LOCK:
                    os.replace(temporary, destination)
                return {"name": name, "file_name": file_name, "size": received}
            finally:
                temporary.unlink(missing_ok=True)
