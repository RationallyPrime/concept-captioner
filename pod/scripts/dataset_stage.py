#!/usr/bin/env python3
"""The flat local upload layout and input digest shared by the agent and dataset installer."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

MAX_UPLOAD_BYTES = 2 * 1024**3
MAX_STAGED_BYTES = 20 * 1024**3
INSTALLING = ".installing"


def confined_stage(directory: Path, workspace: Path) -> Path:
    root = workspace.resolve() / "uploads"
    if directory.parent.resolve() != root or directory.is_symlink() or root.is_symlink():
        raise ValueError("Local inputs must be one nonsymlinked folder under workspace/uploads")
    if (root.exists() and not root.is_dir()) or (directory.exists() and not directory.is_dir()):
        raise ValueError("Local upload staging must be a directory")
    return directory.resolve()


def staged_files(directory: Path) -> list[Path]:
    if not directory.is_dir():
        raise ValueError("Upload the approved local inputs before preparing the dataset")
    files = sorted(directory.iterdir(), key=lambda p: p.name.encode())
    if any(file.is_symlink() or not file.is_file() for file in files):
        raise ValueError("Local upload staging must contain regular flat files only")
    if any(file.name.endswith(".part") for file in files):
        raise ValueError("Wait for every file upload to finish")
    return [file for file in files if file.name != INSTALLING]


def input_digest(files: list[Path]) -> str:
    entries = []
    for file in sorted(files, key=lambda p: p.name.encode()):
        content = hashlib.sha256()
        with file.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                content.update(chunk)
        entries.append((file.name, file.stat().st_size, content.hexdigest()))
    return digest_entries(entries)


def digest_entries(entries: list[tuple[str, int, str]]) -> str:
    digest = hashlib.sha256()
    for name, size, sha256 in sorted(entries, key=lambda row: row[0].encode()):
        digest.update(f"{name}\0{size}\0{sha256}\n".encode())
    return digest.hexdigest()


if __name__ == "__main__":
    argparse.ArgumentParser(description=__doc__).parse_args()
