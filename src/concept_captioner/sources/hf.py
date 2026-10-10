"""Hugging Face datasets as source and sink.

Read any dataset with an image column; write captions back as a text column plus a JSON-string
column of response records, and push to the Hub. The token comes from ``HF_TOKEN`` or the
cached ``hf auth login``; it is never a config field. ``job.yaml`` can be stored in the dataset
repo so the mappings travel with the images they describe (``push_job``/``fetch_job``).
"""

from __future__ import annotations

import contextlib
import io
import json
import os
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

from ..types import ConfigurationError, Sample
from .local import IMAGE_SUFFIXES, LocalFolderSource


def _require_datasets():
    try:
        import datasets  # noqa: F401
        from huggingface_hub import HfApi  # noqa: F401
    except ImportError as exc:  # pragma: no cover - optional dependency
        raise ConfigurationError("install concept-captioner[hf] for Hugging Face datasets") from exc


def _token(explicit: str | None) -> str | None:
    return explicit or os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN") or None


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
        return data, suffix if suffix in IMAGE_SUFFIXES else ".png"
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
    """Buffer captions in memory, then write them into a dataset and push once.

    With an ``HFDatasetSource`` the caption columns are added to that dataset (the originating
    repo by default). With a ``LocalFolderSource`` a new dataset is built from the folder.
    """

    name = "hf"

    def __init__(
        self,
        source: HFDatasetSource | LocalFolderSource,
        *,
        target_repo_id: str | None = None,
        caption_column: str = "caption",
        private: bool | None = None,
        commit_message: str = "Add captions (concept-captioner)",
        token: str | None = None,
        push: bool = True,
    ) -> None:
        _require_datasets()
        self.source = source
        if target_repo_id is None:
            if isinstance(source, HFDatasetSource):
                target_repo_id = source.repo_id
            else:
                raise ConfigurationError("a folder source needs an explicit target repo id")
        self.target_repo_id = target_repo_id
        self.caption_column = caption_column
        self.record_column = f"{caption_column}_response"
        self.private = private
        self.commit_message = commit_message
        self._token = _token(token)
        self._push = push
        self._captions: dict[str, str] = {}
        self._records: dict[str, dict[str, Any]] = {}
        self._existing_captions: dict[str, str] = {}
        self._existing_records: dict[str, dict[str, Any]] = {}
        if isinstance(source, HFDatasetSource):
            existing = source.dataset
            ids = source.sample_ids
            if caption_column in existing.column_names:
                for sample_id, caption in zip(ids, existing[caption_column], strict=True):
                    if caption:
                        self._existing_captions[sample_id] = caption
            if self.record_column in existing.column_names:
                for sample_id, record in zip(ids, existing[self.record_column], strict=True):
                    if record:
                        with contextlib.suppress(TypeError, json.JSONDecodeError):
                            self._existing_records[sample_id] = json.loads(record)

    async def exists(self, sample_id: str) -> bool:
        return sample_id in self._captions or sample_id in self._existing_captions

    async def record(self, sample_id: str) -> dict[str, Any] | None:
        return self._records.get(sample_id) or self._existing_records.get(sample_id)

    async def write(self, sample_id: str, caption: str | None, record: dict[str, Any]) -> None:
        self._records[sample_id] = record
        if caption is not None:
            self._captions[sample_id] = caption

    def materialize(self):
        """Return the dataset with the caption and record columns filled."""
        if isinstance(self.source, HFDatasetSource):
            ids = self.source.sample_ids
            dataset = self.source.dataset
            for column in (self.caption_column, self.record_column):
                if column in dataset.column_names:
                    dataset = dataset.remove_columns(column)
        else:
            from datasets import Dataset, Image

            files = self.source.files
            ids = [p.name for p in files]
            dataset = Dataset.from_dict(
                {"image": [str(p) for p in files], "file_name": ids}
            ).cast_column("image", Image())
        captions = [self._captions.get(i) or self._existing_captions.get(i) or "" for i in ids]
        records = [
            json.dumps(
                self._records.get(i) or self._existing_records.get(i) or {}, ensure_ascii=False
            )
            for i in ids
        ]
        dataset = dataset.add_column(self.caption_column, captions)
        return dataset.add_column(self.record_column, records)

    async def finalize(self) -> dict[str, Any]:
        dataset = self.materialize()
        summary = {
            "repo_id": self.target_repo_id,
            "rows": len(dataset),
            "captions": sum(1 for c in dataset[self.caption_column] if c),
            "pushed": False,
        }
        if self._push:
            split = self.source.split if isinstance(self.source, HFDatasetSource) else "train"
            dataset.push_to_hub(
                self.target_repo_id,
                split=split,
                token=self._token,
                private=self.private,
                commit_message=self.commit_message,
            )
            summary["pushed"] = True
        return summary


def push_job(
    repo_id: str,
    job_path: str | Path,
    *,
    token: str | None = None,
    path_in_repo: str = "concept-captioner/job.yaml",
) -> str:
    """Store the job file inside the dataset repo so the data carries its own mappings."""
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


def fetch_job(
    repo_id: str, *, token: str | None = None, path_in_repo: str = "concept-captioner/job.yaml"
) -> Path:
    _require_datasets()
    from huggingface_hub import hf_hub_download

    return Path(hf_hub_download(repo_id, path_in_repo, repo_type="dataset", token=_token(token)))


def pull_images(
    repo_id: str,
    destination: str | Path,
    *,
    split: str = "train",
    image_column: str = "image",
    token: str | None = None,
) -> int:
    """Download a dataset's images to a folder (sidecar workflow), returning the count."""
    source = HFDatasetSource(repo_id, split=split, image_column=image_column, token=token)
    out = Path(destination)
    out.mkdir(parents=True, exist_ok=True)
    written = 0
    for index, row in enumerate(source.dataset):
        data, suffix = _encode(row[image_column])
        sample_id = _sample_id(row, index, None)
        name = (
            sample_id
            if Path(sample_id).suffix.lower() in IMAGE_SUFFIXES
            else Path(sample_id).stem + suffix
        )
        (out / name).write_bytes(data)
        written += 1
    return written
