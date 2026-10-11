#!/usr/bin/env python3
"""Hub dataset -> local folder of images + sidecar captions (POD-SPEC §7.1).

Usage:
  pull_dataset.py --repo ID --to DIR [--split train] [--revision R] [--image-column image]
                  [--caption-column caption] [--id-column C]
                  [--job-path concept-captioner/job.yaml] [--require-captions]

Two Hub conventions are recognised from the repo's file list (``HfApi.list_repo_files``):

1. imagefolder: image files plus ``metadata.jsonl`` (``file_name`` and ``caption`` or ``text``;
   ``metadata.csv`` is accepted too). The repo is snapshotted and the images are copied into
   DIR flat: ``file_name`` relative to its metadata file, with ``/`` replaced by ``__``. Images
   the metadata does not list are copied as well (their caption comes from a ``<stem>.txt``
   sidecar in the repo when there is one). Name or stem collisions are an error. With several
   metadata files in different folders, ``--split`` picks the folder(s) whose path contains it.
2. anything else (parquet, arrow, a loading script): ``datasets.load_dataset``. The sample id
   follows concept-captioner's rules (``--id-column``, else ``file_name``/``filename``/
   ``image_id``/``id``/``name``, else the row index); image bytes are written with their original
   suffix (sniffed from the bytes when the path has none; PNG when unknown); the caption is
   ``--caption-column`` when present and non-empty; a ``<caption-column>_response`` column is
   written as the ``<stem>.json`` response record.

Always written: ``<stem>.txt`` per captioned image, ``metadata.jsonl`` (``file_name``,
``caption``) and ``manifest.json`` (``repo_id``, ``revision``, ``convention``, ``count``,
``with_caption``, ``without_caption``, ``job_yaml``, ...). ``job.yaml`` is fetched from
``--job-path`` when the repo has it. DIR is replaced atomically: everything lands in
``DIR.partial`` first and is swapped in at the end, so a failed pull leaves a previous dataset
untouched and a re-pull never keeps stale images.

Exit 0 on success; 1 with a message on stderr on any error, and with ``--require-captions`` when
an image has no caption (the folder is still swapped in so the client can inspect it). The token
comes from ``HF_TOKEN``. Heavy imports happen inside ``main`` so ``python -I pull_dataset.py
--help`` needs nothing beyond the standard library.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
import shutil
import sys
from collections.abc import Iterable, Iterator
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath
from typing import Any

IMAGE_SUFFIXES = frozenset({".png", ".jpg", ".jpeg", ".webp", ".mp4", ".mov", ".m4v"})
TABULAR_SUFFIXES = frozenset({".parquet", ".arrow"})
METADATA_NAMES = ("metadata.jsonl", "metadata.csv")  # jsonl wins when a folder has both
ID_KEYS = ("file_name", "filename", "image_id", "id", "name")
IMAGEFOLDER = "imagefolder"
DATASETS = "datasets"
PARTIAL_SUFFIX = ".partial"
OLD_SUFFIX = ".old"

# What an imagefolder snapshot needs: images (both suffix cases), sidecars, metadata files.
SNAPSHOT_PATTERNS: tuple[str, ...] = (
    *(f"*{suffix}" for suffix in sorted(IMAGE_SUFFIXES)),
    *(f"*{suffix.upper()}" for suffix in sorted(IMAGE_SUFFIXES)),
    "*.txt",
    "*.json",
    *(f"*{name}" for name in METADATA_NAMES),
)


class PullError(Exception):
    """A condition that ends the pull with exit 1 and this message."""


@dataclass
class Entry:
    """One image headed for DIR: where its bytes come from, and its caption."""

    file_name: str
    source: Path | None = None  # copy from here (imagefolder) ...
    data: bytes | None = None  # ... or write these bytes (datasets)
    caption: str | None = None
    record: str | None = None  # JSON text of the response record -> <stem>.json

    @property
    def stem(self) -> str:
        return Path(self.file_name).stem


# --- pure helpers -------------------------------------------------------------------------------


def detect_convention(files: Iterable[str]) -> str:
    """``imagefolder`` for image files with metadata (or with no tabular data), else ``datasets``."""
    names = [PurePosixPath(name) for name in files]
    has_images = any(p.suffix.lower() in IMAGE_SUFFIXES for p in names)
    has_metadata = any(p.name in METADATA_NAMES for p in names)
    has_tabular = any(p.suffix.lower() in TABULAR_SUFFIXES for p in names)
    if has_images and (has_metadata or not has_tabular):
        return IMAGEFOLDER
    return DATASETS


def _sample_id(row: dict[str, Any], index: int, id_column: str | None) -> str:
    """Copied from ``concept_captioner.sources.hf._sample_id``; keep the two in step."""
    if id_column and row.get(id_column) is not None:
        return str(row[id_column])
    for key in ID_KEYS:
        if row.get(key) is not None:
            return str(row[key])
    return str(index)


def flatten(relative: str) -> str:
    """``sub/dir/a.png`` -> ``sub__dir__a.png``; refuses empty names and ``..``."""
    parts = [p for p in relative.replace("\\", "/").split("/") if p not in ("", ".")]
    if not parts or ".." in parts:
        raise PullError(f"unusable file name {relative!r}")
    return "__".join(parts)


def file_name_for(sample_id: str, suffix: str) -> str:
    """A flat file name for a dataset row: the id, plus ``suffix`` unless it already has one."""
    name = sample_id.replace("\\", "/").strip("/").replace("/", "__").lstrip(".") or "sample"
    if Path(name).suffix.lower() in IMAGE_SUFFIXES:
        return name
    return name + suffix


def sniff_suffix(data: bytes) -> str | None:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    if data.startswith(b"\xff\xd8\xff"):
        return ".jpg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return ".webp"
    return None


def caption_of(row: dict[str, Any], keys: Iterable[str]) -> str | None:
    """The first non-empty string among ``keys`` in ``row``, stripped; else None."""
    for key in keys:
        value = row.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def sidecar_caption(image: Path) -> str | None:
    sidecar = image.with_suffix(".txt")
    if sidecar.is_file():
        return sidecar.read_text(encoding="utf-8").strip() or None
    return None


def default_image_roots() -> list[Path]:
    """Where the datasets library may legitimately point an image cell's ``path``."""
    roots: list[Path] = []
    for name in ("HF_DATASETS_CACHE", "HF_HUB_CACHE", "HF_HOME"):
        value = os.environ.get(name)
        if value:
            roots.append(Path(value).expanduser().resolve())
    roots.append((Path.home() / ".cache" / "huggingface").resolve())
    return roots


def _confined_read(path: str, allowed_roots: Iterable[Path]) -> bytes:
    """Read an image file only if it lives under one of the allowed roots."""
    candidate = Path(path).expanduser()
    if candidate.suffix.lower() not in IMAGE_SUFFIXES:
        raise PullError(f"image cell path {path!r} is not an image file")
    resolved = candidate.resolve()
    if not any(resolved.is_relative_to(root) for root in allowed_roots):
        raise PullError(f"image cell path {path!r} is outside the dataset cache")
    return resolved.read_bytes()


def image_payload(
    value: Any, *, allowed_roots: Iterable[Path] | None = None
) -> tuple[bytes, str | None]:
    """A datasets image cell -> (bytes, suffix from its path when it is an image suffix).

    A cell that carries only a ``path`` is read only when that path is under one of
    ``allowed_roots`` (the Hugging Face cache by default): dataset rows are untrusted input.
    """
    if isinstance(value, dict):
        data = value.get("bytes")
        path = value.get("path")
        if not data and path:
            roots = list(allowed_roots) if allowed_roots is not None else default_image_roots()
            data = _confined_read(str(path), roots)
        if not data:
            raise PullError("an image cell has neither bytes nor a path")
        suffix = Path(path).suffix.lower() if path else ""
        return bytes(data), suffix if suffix in IMAGE_SUFFIXES else None
    if isinstance(value, bytes | bytearray):
        return bytes(value), None
    if hasattr(value, "save"):  # a decoded PIL image
        out = io.BytesIO()
        if (getattr(value, "format", None) or "").upper() == "JPEG":
            value.save(out, format="JPEG", quality=95)
            return out.getvalue(), ".jpg"
        value.save(out, format="PNG")
        return out.getvalue(), ".png"
    raise PullError(f"unsupported image cell of type {type(value).__name__}")


class NameSet:
    """Rejects a second image with the same name, or the same stem (sidecars would collide)."""

    def __init__(self) -> None:
        self._stems: dict[str, str] = {}

    def add(self, file_name: str) -> None:
        stem = Path(file_name).stem
        other = self._stems.get(stem)
        if other == file_name:
            raise PullError(f"two images would land as {file_name!r}")
        if other is not None:
            raise PullError(f"{file_name!r} and {other!r} share a stem; captions would collide")
        self._stems[stem] = file_name


# --- imagefolder --------------------------------------------------------------------------------


def _hidden(path: Path, root: Path) -> bool:
    return any(part.startswith(".") for part in path.relative_to(root).parts)


def read_metadata(path: Path) -> list[dict[str, Any]]:
    if path.suffix == ".jsonl":
        rows: list[dict[str, Any]] = []
        with path.open(encoding="utf-8") as handle:
            for lineno, raw in enumerate(handle, 1):
                line = raw.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise PullError(f"{path}:{lineno}: {exc}") from None
                if not isinstance(row, dict):
                    raise PullError(f"{path}:{lineno}: expected an object per line")
                rows.append(row)
        return rows
    with path.open(encoding="utf-8", newline="") as handle:
        return [dict(row) for row in csv.DictReader(handle)]


def metadata_files(snapshot: Path, split: str | None) -> list[Path]:
    """One metadata file per folder (jsonl preferred), narrowed to ``split`` when that selects any."""
    by_dir: dict[Path, Path] = {}
    for name in METADATA_NAMES:
        for path in sorted(snapshot.rglob(name)):
            if path.is_file() and not _hidden(path, snapshot):
                by_dir.setdefault(path.parent, path)
    chosen = sorted(by_dir.values())
    if split and len(chosen) > 1:
        in_split = [p for p in chosen if split in p.parent.relative_to(snapshot).parts]
        if in_split:
            chosen = in_split
    return chosen


def collect_imagefolder(
    snapshot: Path, *, split: str | None, caption_column: str, only_metadata: bool = False
) -> list[Entry]:
    """Entries for every image in the snapshot: metadata rows first, then unlisted images."""
    entries: list[Entry] = []
    seen: set[Path] = set()
    caption_keys = (caption_column, "caption", "text")
    metadata = metadata_files(snapshot, split)
    if only_metadata and not metadata:
        raise PullError("This training dataset needs metadata listing its included media.")
    for meta in metadata:
        for row in read_metadata(meta):
            raw = row.get("file_name")
            if not isinstance(raw, str) or not raw:
                raise PullError(f"{meta}: a row has no file_name")
            if PurePosixPath(raw).is_absolute() or raw.startswith(("\\", "/")):
                raise PullError(f"{meta}: {raw!r} must be a relative path")
            # Lexical, not resolve(): Hub snapshots are symlinks into the cache's blobs/ directory,
            # so a resolved path never sits under the snapshot. normpath still collapses "..".
            source = Path(os.path.normpath(meta.parent / raw))
            if not source.is_relative_to(snapshot):
                raise PullError(f"{meta}: {raw!r} points outside the repo snapshot")
            if not source.is_file():
                raise PullError(f"{meta}: {raw!r} is listed but not in the repo")
            if source.suffix.lower() not in IMAGE_SUFFIXES:
                raise PullError(
                    f"{meta}: {raw!r} is not an image ({' '.join(sorted(IMAGE_SUFFIXES))})"
                )
            caption = caption_of(row, caption_keys) or sidecar_caption(source)
            entries.append(
                Entry(
                    file_name=flatten(raw),
                    source=source,
                    caption=caption,
                    record=source.with_suffix(".json").read_text(encoding="utf-8")
                    if source.with_suffix(".json").is_file()
                    else None,
                )
            )
            seen.add(source)
    for root in [] if only_metadata else [meta.parent for meta in metadata] or [snapshot]:
        for path in sorted(root.rglob("*")):
            if (
                path.suffix.lower() not in IMAGE_SUFFIXES
                or not path.is_file()
                or _hidden(path, snapshot)
                or path in seen
            ):
                continue
            seen.add(path)
            name = flatten(path.relative_to(root).as_posix())
            entries.append(
                Entry(
                    file_name=name,
                    source=path,
                    caption=sidecar_caption(path),
                    record=path.with_suffix(".json").read_text(encoding="utf-8")
                    if path.with_suffix(".json").is_file()
                    else None,
                )
            )
    return entries


# --- datasets -----------------------------------------------------------------------------------


def prepare_dataset(dataset: Any, image_column: str) -> Any:
    """Check the image column and make it yield raw bytes instead of decoded images."""
    from datasets import Image

    if image_column not in dataset.column_names:
        raise PullError(f"dataset has no column {image_column!r}; columns: {dataset.column_names}")
    return dataset.cast_column(image_column, Image(decode=False))


def iter_dataset_entries(
    rows: Iterable[dict[str, Any]],
    *,
    image_column: str,
    caption_column: str,
    id_column: str | None,
    allowed_roots: Iterable[Path] | None = None,
) -> Iterator[Entry]:
    record_column = f"{caption_column}_response"
    roots = list(allowed_roots) if allowed_roots is not None else default_image_roots()
    for index, row in enumerate(rows):
        if image_column not in row:
            raise PullError(f"row {index} has no {image_column!r} column")
        data, suffix = image_payload(row[image_column], allowed_roots=roots)
        meta = {key: value for key, value in row.items() if key != image_column}
        record = meta.get(record_column)
        if not isinstance(record, str) or record.strip() in ("", "{}", "null"):
            record = None
        yield Entry(
            file_name=file_name_for(
                _sample_id(meta, index, id_column), suffix or sniff_suffix(data) or ".png"
            ),
            data=data,
            caption=caption_of(meta, (caption_column,)),
            record=record,
        )


# --- writing ------------------------------------------------------------------------------------


def write_entries(entries: Iterable[Entry], out: Path) -> list[Entry]:
    """Land every entry in ``out`` and write ``metadata.jsonl``; returns the (byte-free) entries."""
    out.mkdir(parents=True, exist_ok=True)
    names = NameSet()
    written: list[Entry] = []
    for entry in entries:
        names.add(entry.file_name)
        target = out / entry.file_name
        if entry.source is not None:
            shutil.copyfile(entry.source, target)
        elif entry.data is not None:
            target.write_bytes(entry.data)
        else:
            raise PullError(f"{entry.file_name!r} has no bytes")
        if entry.caption is not None:
            (out / f"{entry.stem}.txt").write_text(entry.caption, encoding="utf-8")
        if entry.record is not None:
            (out / f"{entry.stem}.json").write_text(entry.record, encoding="utf-8")
        written.append(Entry(file_name=entry.file_name, caption=entry.caption))
    with (out / "metadata.jsonl").open("w", encoding="utf-8") as handle:
        for entry in written:
            handle.write(
                json.dumps(
                    {"file_name": entry.file_name, "caption": entry.caption}, ensure_ascii=False
                )
            )
            handle.write("\n")
    return written


def build_manifest(
    args: argparse.Namespace,
    *,
    sha: str | None,
    convention: str,
    entries: list[Entry],
    job_yaml: str | None,
) -> dict[str, Any]:
    with_caption = sum(1 for entry in entries if entry.caption is not None)
    return {
        "repo_id": args.repo,
        "revision": sha or args.revision,
        "requested_revision": args.revision,
        "only_metadata": getattr(args, "only_metadata", False),
        "split": args.split,
        "convention": convention,
        "image_column": args.image_column,
        "caption_column": args.caption_column,
        "id_column": args.id_column,
        "count": len(entries),
        "with_caption": with_caption,
        "without_caption": len(entries) - with_caption,
        "job_yaml": job_yaml,
        "pulled_at": datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z"),
    }


def _remove(path: Path) -> None:
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()


def swap_in(stage: Path, out: Path) -> None:
    """Replace ``out`` with ``stage`` in two renames; the previous ``out`` is deleted last."""
    old = out.with_name(out.name + OLD_SUFFIX)
    _remove(old)
    if out.exists():
        out.rename(old)
    stage.rename(out)
    _remove(old)


# --- the Hub ------------------------------------------------------------------------------------


def token_from_env() -> str | None:
    return os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN") or None


class Hub:
    """Every call this script makes to the Hub, behind one object so tests can substitute a fake."""

    def __init__(self, token: str | None) -> None:
        from huggingface_hub import HfApi

        self.token = token
        self.api = HfApi(token=token)

    def list_files(self, repo_id: str, revision: str | None) -> list[str]:
        return list(self.api.list_repo_files(repo_id, repo_type="dataset", revision=revision))

    def resolve_sha(self, repo_id: str, revision: str | None) -> str | None:
        return getattr(self.api.dataset_info(repo_id, revision=revision), "sha", None)

    def snapshot(self, repo_id: str, revision: str | None, allow_patterns: list[str]) -> Path:
        from huggingface_hub import snapshot_download

        return Path(
            snapshot_download(
                repo_id,
                repo_type="dataset",
                revision=revision,
                token=self.token,
                allow_patterns=allow_patterns,
            )
        )

    def download_file(self, repo_id: str, path_in_repo: str, revision: str | None) -> Path:
        from huggingface_hub import hf_hub_download

        return Path(
            hf_hub_download(
                repo_id, path_in_repo, repo_type="dataset", revision=revision, token=self.token
            )
        )

    def load_dataset(
        self, repo_id: str, *, split: str, revision: str | None, image_column: str
    ) -> Iterable[dict[str, Any]]:
        from datasets import load_dataset

        dataset = load_dataset(repo_id, split=split, revision=revision, token=self.token)
        return prepare_dataset(dataset, image_column)


# --- entry point --------------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True, help="dataset repo id (owner/name)")
    parser.add_argument("--to", required=True, help="destination folder; replaced atomically")
    parser.add_argument("--split", default="train")
    parser.add_argument("--revision", default=None, help="branch, tag or commit; default main")
    parser.add_argument("--image-column", default="image")
    parser.add_argument("--caption-column", default="caption")
    parser.add_argument("--id-column", default=None)
    parser.add_argument(
        "--only-metadata",
        action="store_true",
        help="train only media listed by metadata; require it",
    )
    parser.add_argument(
        "--job-path", default="concept-captioner/job.yaml", help="job.yaml path in the repo"
    )
    parser.add_argument(
        "--require-captions", action="store_true", help="exit 1 when an image has no caption"
    )
    return parser


def run(args: argparse.Namespace, hub: Hub | None) -> int:
    out = Path(args.to).expanduser().resolve()
    if hub is None:
        hub = Hub(token_from_env())
    try:
        files = hub.list_files(args.repo, args.revision)
        sha = hub.resolve_sha(args.repo, args.revision)
    except Exception as exc:  # not found, no access, offline: one line instead of a traceback
        raise PullError(f"cannot read {args.repo}: {exc}") from None
    revision = sha or args.revision
    convention = detect_convention(files)
    print(f"pull_dataset: {args.repo} @ {revision or 'main'} -> {out} ({convention})", flush=True)

    stage = out.with_name(out.name + PARTIAL_SUFFIX)
    _remove(stage)
    stage.mkdir(parents=True)
    try:
        if convention == IMAGEFOLDER:
            snapshot = hub.snapshot(args.repo, revision, list(SNAPSHOT_PATTERNS))
            entries: Iterable[Entry] = collect_imagefolder(
                snapshot,
                split=args.split,
                caption_column=args.caption_column,
                only_metadata=args.only_metadata,
            )
        else:
            rows = hub.load_dataset(
                args.repo, split=args.split, revision=revision, image_column=args.image_column
            )
            entries = iter_dataset_entries(
                rows,
                image_column=args.image_column,
                caption_column=args.caption_column,
                id_column=args.id_column,
            )
        written = write_entries(entries, stage)
        job_yaml = None
        if args.job_path and args.job_path in files:
            shutil.copyfile(
                hub.download_file(args.repo, args.job_path, revision), stage / "job.yaml"
            )
            job_yaml = "job.yaml"
        manifest = build_manifest(
            args, sha=sha, convention=convention, entries=written, job_yaml=job_yaml
        )
        (stage / "manifest.json").write_text(
            json.dumps(manifest, indent=1, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        swap_in(stage, out)
    except BaseException:
        _remove(stage)
        raise

    print(
        f"pull_dataset: {manifest['count']} images, {manifest['with_caption']} with captions, "
        f"{manifest['without_caption']} without; job.yaml: {'yes' if job_yaml else 'no'}",
        flush=True,
    )
    if args.require_captions and manifest["without_caption"]:
        missing = [entry.file_name for entry in written if entry.caption is None]
        shown = ", ".join(missing[:10]) + (", ..." if len(missing) > 10 else "")
        raise PullError(f"{len(missing)} of {len(written)} images have no caption: {shown}")
    return 0


def main(argv: list[str] | None = None, hub: Hub | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return run(args, hub)
    except PullError as exc:
        print(f"pull_dataset: {exc}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
