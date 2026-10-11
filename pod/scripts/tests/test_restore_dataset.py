"""Missing Resume inputs use exact stored selection facts, never a moving branch."""

import importlib.util
import json
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location(
    "restore_dataset", Path(__file__).parents[1] / "restore_dataset.py"
)
restore = importlib.util.module_from_spec(spec)
spec.loader.exec_module(restore)


def fixture(tmp_path):
    workspace = tmp_path / "workspace"
    run = workspace / "runs" / "example"
    run.mkdir(parents=True)
    raw = {"resume": True, "dataset": {"path": str(workspace / "datasets" / "example")}}
    manifest = {
        "repo_id": "example/data",
        "revision": "a" * 40,
        "split": "train",
        "image_column": "image",
        "caption_column": "caption",
        "id_column": "id",
        "only_metadata": True,
    }
    (run / "dataset-manifest.json").write_text(json.dumps(manifest))
    return workspace, run, raw, manifest


def test_exact_revision_columns_and_metadata_are_restored(tmp_path, monkeypatch):
    workspace, run, raw, _ = fixture(tmp_path)
    calls = []

    def pull(argv, *, check, env):
        calls.append(argv)
        Path(raw["dataset"]["path"]).mkdir(parents=True)
        assert check
        assert env is None

    monkeypatch.setattr(restore.subprocess, "run", pull)
    restore.restore_dataset(raw, run, workspace)
    args = calls[0]
    assert args[args.index("--revision") + 1] == "a" * 40
    assert args[args.index("--split") + 1] == "train"
    assert args[args.index("--id-column") + 1] == "id"
    assert "--only-metadata" in args
    restore.restore_dataset(raw, run, workspace)
    assert len(calls) == 1


@pytest.mark.parametrize(
    "change",
    [
        {"revision": "main"},
        {"revision": None},
        {"repo_id": None},
        {"only_metadata": None},
        {"split": None},
    ],
)
def test_unknown_restore_facts_refused(tmp_path, change):
    workspace, run, raw, manifest = fixture(tmp_path)
    (run / "dataset-manifest.json").write_text(json.dumps({**manifest, **change}))
    with pytest.raises(ValueError):
        restore.restore_arguments(raw, run, workspace)


def test_no_restore_for_repeat_and_no_escape(tmp_path):
    workspace, run, raw, _ = fixture(tmp_path)
    assert restore.restore_arguments({**raw, "resume": False}, run, workspace) is None
    raw["dataset"]["path"] = str(tmp_path / "outside")
    with pytest.raises(ValueError, match="workspace"):
        restore.restore_arguments(raw, run, workspace)


def test_direct_wrapper_token_is_only_forwarded_through_environment(tmp_path, monkeypatch):
    workspace, run, raw, _ = fixture(tmp_path)
    raw["hf_token"] = "synthetic-hub-token"

    def pull(argv, *, check, env):
        assert "synthetic-hub-token" not in argv
        assert env.get("HF_TOKEN") == "synthetic-hub-token"
        Path(raw["dataset"]["path"]).mkdir(parents=True)

    monkeypatch.setattr(restore.subprocess, "run", pull)
    restore.restore_dataset(raw, run, workspace)


def test_local_resume_requires_reupload_of_identical_source_and_no_hub_pull(tmp_path):
    workspace, run, raw, _ = fixture(tmp_path)
    dataset = Path(raw["dataset"]["path"])
    dataset.mkdir(parents=True)
    saved = {"source": "local", "input_digest": "a" * 64, "repo_id": None, "revision": None}
    (run / "dataset-manifest.json").write_text(json.dumps(saved))
    (dataset / "manifest.json").write_text(json.dumps(saved))
    assert restore.restore_arguments(raw, run, workspace) is None
    (dataset / "manifest.json").write_text(json.dumps({**saved, "input_digest": "b" * 64}))
    with pytest.raises(ValueError, match="original input digest"):
        restore.restore_arguments(raw, run, workspace)
    (dataset / "manifest.json").unlink()
    dataset.rmdir()
    with pytest.raises(ValueError, match="upload local inputs again"):
        restore.restore_arguments(raw, run, workspace)
