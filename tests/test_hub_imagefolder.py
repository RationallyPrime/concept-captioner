import json
from types import SimpleNamespace

import pytest

from concept_captioner.sources.hf import HFDatasetSink, HFDatasetSource

pytest.importorskip("datasets")
pytest.importorskip("huggingface_hub")


@pytest.fixture
def raw_hub(tmp_path, monkeypatch):
    import huggingface_hub

    payloads = {
        "a.mp4": b"exact-video",
        "nested/b.png": b"exact-image",
        "c.mov": b"unlisted-quicktime",
        "metadata.jsonl": (
            json.dumps(
                {
                    "file_name": "a.mp4",
                    "caption": "Saved motion",
                    "custom": "keep",
                    "caption_response": {"sample_id": "a.mp4", "source": "human"},
                    "rating": None,
                }
            )
            + "\n"
            + json.dumps(
                {
                    "file_name": "nested/b.png",
                    "caption": "Saved still",
                    "caption_response": json.dumps({"source": "human"}),
                }
            )
            + "\n"
            + json.dumps({"file_name": "old.png", "custom": "unrelated row"})
            + "\n"
        ).encode(),
    }
    downloads, commits = [], []

    class API:
        def __init__(self, **_kwargs):
            pass

        def list_repo_files(self, repo_id, **kwargs):
            assert repo_id == "offline/mixed" and kwargs["revision"] == "pinned"
            return list(payloads)

        def create_commit(self, **kwargs):
            commits.append(kwargs)
            return SimpleNamespace(oid="new-commit")

    def download(repo_id, name, **kwargs):
        assert repo_id == "offline/mixed" and kwargs["revision"] == "pinned"
        downloads.append(name)
        path = tmp_path / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payloads[name])
        return str(path)

    monkeypatch.setattr(huggingface_hub, "HfApi", API)
    monkeypatch.setattr(huggingface_hub, "hf_hub_download", download)
    return downloads, commits


async def test_mixed_raw_hub_reads_by_filename_and_keeps_exact_bytes(raw_hub):
    downloads, _ = raw_hub
    source = HFDatasetSource("offline/mixed", revision="pinned", token="fixture")
    assert downloads == ["metadata.jsonl"]
    assert source.sample_ids == ["a.mp4", "c.mov", "nested/b.png"]
    assert await source.count() == 3
    samples = [sample async for sample in source.samples()]
    assert [(s.sample_id, s.suffix, s.data) for s in samples] == [
        ("a.mp4", ".mp4", b"exact-video"),
        ("c.mov", ".mov", b"unlisted-quicktime"),
        ("nested/b.png", ".png", b"exact-image"),
    ]


async def test_root_imagefolder_metadata_wins_over_unrelated_tabular_file(raw_hub, monkeypatch):
    import datasets
    import huggingface_hub

    downloads, _ = raw_hub
    list_files = huggingface_hub.HfApi.list_repo_files
    monkeypatch.setattr(
        huggingface_hub.HfApi,
        "list_repo_files",
        lambda self, *args, **kwargs: [
            *list_files(self, *args, **kwargs),
            "unrelated/archive.parquet",
        ],
    )
    monkeypatch.setattr(
        datasets,
        "load_dataset",
        lambda *_a, **_k: pytest.fail("Explicit imagefolder dispatched to tabular loader"),
    )
    source = HFDatasetSource("offline/mixed", revision="pinned", token="fixture")
    samples = [sample async for sample in source.samples()]
    assert [(sample.sample_id, sample.suffix, sample.data) for sample in samples] == [
        ("a.mp4", ".mp4", b"exact-video"),
        ("c.mov", ".mov", b"unlisted-quicktime"),
        ("nested/b.png", ".png", b"exact-image"),
    ]
    assert "unrelated/archive.parquet" not in downloads
    sink = HFDatasetSink(source, token="fixture", push=False)
    assert (await sink.record("a.mp4"))["source"] == "human"


async def test_mixed_hub_caption_update_preserves_other_rows_and_media(raw_hub):
    _, commits = raw_hub
    source = HFDatasetSource("offline/mixed", revision="pinned", token="fixture")
    sink = HFDatasetSink(source, token="fixture")
    assert await sink.exists("a.mp4")
    assert (await sink.record("a.mp4"))["source"] == "human"
    await sink.write("c.mov", "New motion", {"source": "model", "sample_id": "c.mov"})
    result = await sink.finalize()
    assert result["pushed"] and result["commit_oid"] == "new-commit"
    assert len(commits) == 1
    operations = commits[0]["operations"]
    assert [op.path_in_repo for op in operations] == ["metadata.jsonl"]
    rows = {
        row["file_name"]: row
        for row in map(json.loads, operations[0].path_or_fileobj.decode().splitlines())
    }
    assert rows["a.mp4"]["custom"] == "keep"
    assert rows["a.mp4"]["caption"] == "Saved motion"
    assert rows["c.mov"]["caption"] == "New motion"
    assert rows["old.png"]["custom"] == "unrelated row"
    # Pinned reads do not change the existing default main write target.
    assert "revision" not in commits[0]


def test_tabular_hub_uses_existing_features_even_if_repo_has_loose_media(monkeypatch):
    import datasets
    import huggingface_hub

    dataset = datasets.Dataset.from_dict(
        {"image": [{"bytes": b"clip", "path": "clip.mp4"}], "file_name": ["clip.mp4"]}
    ).cast_column("image", datasets.Video())
    monkeypatch.setattr(
        huggingface_hub.HfApi,
        "list_repo_files",
        lambda *_a, **_k: ["data/train.parquet", "loose.png"],
    )
    monkeypatch.setattr(datasets, "load_dataset", lambda *_a, **_k: dataset)
    source = HFDatasetSource("offline/table", token="fixture")
    assert source._files is None
    assert source.dataset.features["image"].decode is False
    assert source.sample_ids == ["clip.mp4"]


async def test_raw_object_and_string_human_records_are_protected_in_runner(raw_hub, tmp_path):
    from conftest import function_model

    from concept_captioner.job import Concept, Job
    from concept_captioner.runner import Runner

    _, commits = raw_hub
    source = HFDatasetSource("offline/mixed", revision="pinned", token="fixture")
    sink = HFDatasetSink(source, token="fixture")
    job = Job(
        concepts=[Concept(trigger="NORA7")],
        samples={"a.mp4": {"NORA7": "target"}, "nested/b.png": {"NORA7": "target"}},
    )
    captioner = function_model(lambda *_: pytest.fail("Human-final target reached model"))
    summary = await Runner(job=job, captioner=captioner, overwrite=True).run(source, sink)
    assert {outcome.sample_id: outcome.status for outcome in summary.outcomes} == {
        "a.mp4": "skipped",
        "nested/b.png": "skipped",
        "c.mov": "needs_mapping",
    }
    rows = {
        row["file_name"]: row
        for row in map(
            json.loads, commits[0]["operations"][0].path_or_fileobj.decode().splitlines()
        )
    }
    assert isinstance(rows["a.mp4"]["caption_response"], dict)
    assert isinstance(rows["nested/b.png"]["caption_response"], str)
    assert rows["a.mp4"]["rating"] is None
    assert "rating" not in rows["nested/b.png"]
    assert "caption" not in rows["c.mov"] and "caption_response" not in rows["c.mov"]
    assert rows["a.mp4"]["caption"] == "Saved motion"
