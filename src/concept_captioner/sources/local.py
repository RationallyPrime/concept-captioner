"""Local folder in, sidecar ``.txt`` captions and ``_receipts/*.json`` out."""

from __future__ import annotations

import json
import os
import tempfile
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

from ..types import ConfigurationError, IntegrityError, Sample

IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp"}


def atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def atomic_write_json(path: Path, value: Any) -> None:
    atomic_write_text(path, json.dumps(value, ensure_ascii=False, indent=1, sort_keys=True))


class LocalFolderSource:
    name = "local"

    def __init__(self, directory: str | Path) -> None:
        self.directory = Path(directory).expanduser().resolve()
        if not self.directory.is_dir():
            raise ConfigurationError(f"input directory does not exist: {self.directory}")
        self._files = sorted(
            p for p in self.directory.iterdir() if p.suffix.lower() in IMAGE_SUFFIXES
        )
        if any(p.is_symlink() or not p.is_file() for p in self._files):
            raise ConfigurationError("input must contain regular image files, not symlinks")
        if len({p.stem for p in self._files}) != len(self._files):
            raise ConfigurationError("image stems collide; sidecar captions would be ambiguous")

    @property
    def sample_ids(self) -> list[str]:
        return [p.name for p in self._files]

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
        self.receipts = self.directory / "_receipts"

    def _caption_path(self, sample_id: str) -> Path:
        return self.directory / (Path(sample_id).stem + ".txt")

    def _receipt_path(self, sample_id: str) -> Path:
        return self.receipts / (Path(sample_id).stem + ".json")

    async def existing(self, sample_id: str) -> tuple[str, dict[str, Any]] | None:
        caption_path, receipt_path = self._caption_path(sample_id), self._receipt_path(sample_id)
        if caption_path.is_symlink() or receipt_path.is_symlink():
            raise IntegrityError("caption outputs must not be symlinks")
        if not caption_path.exists():
            return None
        receipt = json.loads(receipt_path.read_text(encoding="utf-8")) if receipt_path.exists() else {}
        return caption_path.read_text(encoding="utf-8"), receipt

    async def write_receipt(self, sample_id: str, receipt: dict[str, Any]) -> None:
        atomic_write_json(self._receipt_path(sample_id), receipt)

    async def commit(self, sample_id: str, caption: str, receipt: dict[str, Any]) -> None:
        atomic_write_json(self._receipt_path(sample_id), receipt)
        atomic_write_text(self._caption_path(sample_id), caption)

    async def finalize(self) -> dict[str, Any]:
        return {"directory": str(self.directory)}
