"""Local folder in; sidecar ``<stem>.txt`` captions and ``<stem>.json`` response records out."""

from __future__ import annotations

import json
import os
import tempfile
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

from ..types import ConfigurationError, Sample

IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp"}


def atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def atomic_write_json(path: Path, value: Any) -> None:
    atomic_write_text(path, json.dumps(value, ensure_ascii=False, indent=1))


class LocalFolderSource:
    name = "folder"

    def __init__(self, directory: str | Path) -> None:
        self.directory = Path(directory).expanduser().resolve()
        if not self.directory.is_dir():
            raise ConfigurationError(f"input directory does not exist: {self.directory}")
        self._files = sorted(
            p
            for p in self.directory.iterdir()
            if p.suffix.lower() in IMAGE_SUFFIXES and p.is_file()
        )
        if len({p.stem for p in self._files}) != len(self._files):
            raise ConfigurationError("image stems collide; sidecar captions would be ambiguous")

    @property
    def sample_ids(self) -> list[str]:
        return [p.name for p in self._files]

    @property
    def files(self) -> list[Path]:
        return list(self._files)

    async def count(self) -> int:
        return len(self._files)

    async def samples(self) -> AsyncIterator[Sample]:
        for path in self._files:
            yield Sample(sample_id=path.name, data=path.read_bytes(), suffix=path.suffix)


class SidecarSink:
    name = "sidecar"

    def __init__(self, directory: str | Path) -> None:
        self.directory = Path(directory).expanduser().resolve()
        self.directory.mkdir(parents=True, exist_ok=True)

    def caption_path(self, sample_id: str) -> Path:
        return self.directory / (Path(sample_id).stem + ".txt")

    def record_path(self, sample_id: str) -> Path:
        return self.directory / (Path(sample_id).stem + ".json")

    async def exists(self, sample_id: str) -> bool:
        return self.caption_path(sample_id).is_file()

    async def record(self, sample_id: str) -> dict[str, Any] | None:
        path = self.record_path(sample_id)
        if not path.is_file():
            return None
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return None

    async def write(self, sample_id: str, caption: str | None, record: dict[str, Any]) -> None:
        atomic_write_json(self.record_path(sample_id), record)
        if caption is not None:
            atomic_write_text(self.caption_path(sample_id), caption)

    async def finalize(self) -> dict[str, Any]:
        return {"directory": str(self.directory)}
