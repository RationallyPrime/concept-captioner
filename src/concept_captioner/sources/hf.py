"""Hugging Face datasets as source and sink.

Read any dataset with an image column; write captions back as a text column and push to the
Hub. The token comes from ``HF_TOKEN`` or the cached ``huggingface-cli login``; it is never a
config field. ``job.yaml`` can be stored in the dataset repo so the identity semantics travel
with the images they describe (``push_job``/``fetch_job``).

Receipts are stored as a JSON-string column (``<caption_column>_receipt``) so an audit trail
survives the round trip without a second repo.
"""

from __future__ import annotations

import contextlib
import io
import json
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

from ..security import optional_env_secret
from ..types import ConfigurationError, Sample


def _require_datasets():
    try:
        import datasets  # noqa: F401
        from huggingface_hub import HfApi  # noqa: F401
    except ImportError as exc:  # pragma: no cover - optional dependency
        raise ConfigurationError("install concept-captioner[hf] for Hugging Face datasets") from exc


def _token(explicit: str | None) -> str | None:
    return explicit or optional_env_secret("HF_TOKEN") or optional_env_secret("HUGGINGFACE_HUB_TOKEN")


def _sample_id(row: dict[str, Any], index: int, id_column: str | None) -> str:
    if id_column and row.get(id_column) is not None:
        return str(row[id_column])
    for key in ("file_name", "filename", "image_id", "id", "name"):
        if row.get(key) is not None:
            return str(row[key])
    return str(index)


def _encode(image: Any) -> tuple[bytes, str]:
    """PIL image (or datasets Image dict) -> (bytes, suffix)."""
    if isinstance(image, dict) and image.get("bytes"):
        data = image["bytes"]
        suffix = Path(image.get("path") or "").suffix.lower() or ".png"
        return data, suffix if suffix in {".png", ".jpg", ".jpeg", ".webp"} else ".png"
    from PIL import Image

    if isinstance(image, dict) and image.get("path"):
        image = Image.open(image["path"])
    out = io.BytesIO()
    fmt = (getattr(image, "format", None) or "PNG").upper()
    if fmt == "JPEG":
        image.save(out, format="JPEG", quality=95)
        return out.getvalue(), ".jpg"
    image.save(out, format="PNG")
    return out.getvalue(), ".png"


class HFDatasetSource:
    name = "hf"

    def __init__(
        self,
        repo_id: str,
        *,
        split: str = "train",
        image_column: str = "image",
        id_column: str | None = None,
        revision: str | None = None,
        token: str | None = None,
    ) -> None:
        _require_datasets()
        from datasets import load_dataset

        self.repo_id = repo_id
        self.split = split
        self.image_column = image_column
        self.id_column = id_column
        self._dataset = load_dataset(repo_id, split=split, revision=revision, token=_token(token))
        if image_column not in self._dataset.column_names:
            raise ConfigurationError(
                f"dataset has no column {image_column!r}; columns: {self._dataset.column_names}"
            )

    @property
    def dataset(self):
        return self._dataset

    @property
    def sample_ids(self) -> list[str]:
        ids: list[str] = []
        for index, row in enumerate(self._dataset.remove_columns([self.image_column])):
            ids.append(_sample_id(row, index, self.id_column))
        return ids

    async def count(self) -> int:
        return len(self._dataset)

    async def samples(self) -> AsyncIterator[Sample]:
        for index, row in enumerate(self._dataset):
            data, suffix = _encode(row[self.image_column])
            yield Sample(sample_id=_sample_id(row, index, self.id_column), data=data, suffix=suffix)


class HFDatasetSink:
    """Buffer captions in memory, then write them into the dataset and push once."""

    name = "hf"

    def __init__(
        self,
        source: HFDatasetSource,
        *,
        target_repo_id: str | None = None,
        caption_column: str = "caption",
        private: bool | None = None,
        commit_message: str = "Add captions (concept-captioner)",
        token: str | None = None,
        push: bool = True,
    ) -> None:
        self.source = source
        self.target_repo_id = target_repo_id or source.repo_id
        self.caption_column = caption_column
        self.private = private
        self.commit_message = commit_message
        self._token = _token(token)
        self._push = push
        self._captions: dict[str, str] = {}
        self._receipts: dict[str, dict[str, Any]] = {}
        existing = source.dataset
        self._existing_captions: dict[str, str] = {}
        if caption_column in existing.column_names:
            ids = source.sample_ids
            for sample_id, caption in zip(ids, existing[caption_column], strict=True):
                if caption:
                    self._existing_captions[sample_id] = caption
        receipt_column = f"{caption_column}_receipt"
        self._existing_receipts: dict[str, dict[str, Any]] = {}
        if receipt_column in existing.column_names:
            ids = source.sample_ids
            for sample_id, receipt in zip(ids, existing[receipt_column], strict=True):
                if receipt:
                    with contextlib.suppress(TypeError, json.JSONDecodeError):
                        self._existing_receipts[sample_id] = json.loads(receipt)

    async def existing(self, sample_id: str) -> tuple[str, dict[str, Any]] | None:
        caption = self._captions.get(sample_id) or self._existing_captions.get(sample_id)
        if caption is None:
            return None
        return caption, self._receipts.get(sample_id) or self._existing_receipts.get(sample_id, {})

    async def write_receipt(self, sample_id: str, receipt: dict[str, Any]) -> None:
        self._receipts[sample_id] = receipt

    async def commit(self, sample_id: str, caption: str, receipt: dict[str, Any]) -> None:
        self._captions[sample_id] = caption
        self._receipts[sample_id] = receipt

    def materialize(self):
        """Return the dataset with caption and receipt columns filled."""
        ids = self.source.sample_ids
        captions = [
            self._captions.get(i) or self._existing_captions.get(i) or "" for i in ids
        ]
        receipts = [
            json.dumps(self._receipts.get(i) or self._existing_receipts.get(i) or {}, ensure_ascii=False)
            for i in ids
        ]
        dataset = self.source.dataset
        receipt_column = f"{self.caption_column}_receipt"
        for column in (self.caption_column, receipt_column):
            if column in dataset.column_names:
                dataset = dataset.remove_columns(column)
        dataset = dataset.add_column(self.caption_column, captions)
        return dataset.add_column(receipt_column, receipts)

    async def finalize(self) -> dict[str, Any]:
        dataset = self.materialize()
        summary = {
            "repo_id": self.target_repo_id,
            "rows": len(dataset),
            "captions": sum(1 for c in dataset[self.caption_column] if c),
            "pushed": False,
        }
        if self._push:
            dataset.push_to_hub(
                self.target_repo_id,
                split=self.source.split,
                token=self._token,
                private=self.private,
                commit_message=self.commit_message,
            )
            summary["pushed"] = True
        return summary


def push_job(repo_id: str, job_path: str | Path, *, token: str | None = None, path_in_repo: str = "concept-captioner/job.yaml") -> str:
    """Store the job file inside the dataset repo so the data carries its own semantics."""
    _require_datasets()
    from huggingface_hub import HfApi

    api = HfApi(token=_token(token))
    info = api.upload_file(
        path_or_fileobj=str(job_path),
        path_in_repo=path_in_repo,
        repo_id=repo_id,
        repo_type="dataset",
        commit_message="Add concept-captioner job",
    )
    return str(info)


def fetch_job(repo_id: str, *, token: str | None = None, path_in_repo: str = "concept-captioner/job.yaml") -> Path:
    _require_datasets()
    from huggingface_hub import hf_hub_download

    return Path(hf_hub_download(repo_id, path_in_repo, repo_type="dataset", token=_token(token)))


def pull_images(repo_id: str, destination: str | Path, *, split: str = "train", image_column: str = "image", token: str | None = None) -> int:
    """Download a dataset's images to a folder (sidecar workflow), returning the count."""
    source = HFDatasetSource(repo_id, split=split, image_column=image_column, token=token)
    out = Path(destination)
    out.mkdir(parents=True, exist_ok=True)
    written = 0
    for index, row in enumerate(source.dataset):
        data, suffix = _encode(row[image_column])
        sample_id = _sample_id(row, index, None)
        name = Path(sample_id).stem + suffix if Path(sample_id).suffix.lower() not in {".png", ".jpg", ".jpeg", ".webp"} else sample_id
        (out / name).write_bytes(data)
        written += 1
    return written
