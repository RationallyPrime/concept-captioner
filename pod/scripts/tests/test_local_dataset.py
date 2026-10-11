"""Local install uses the shared imagefolder layout, exact bytes and no Hub dependency."""

import hashlib
import importlib.util
import json
import sys
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location(
    "local_pull", Path(__file__).parents[1] / "pull_dataset.py"
)
pull = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = pull
spec.loader.exec_module(pull)


def fixture(tmp_path, monkeypatch):
    monkeypatch.setenv("PODAGENT_WORKSPACE", str(tmp_path))
    source = tmp_path / "uploads/ready"
    source.mkdir(parents=True)
    bodies = {
        "clip.mp4": b"exact approved selected segment",
        "clip.txt": b"NORA7 moves",
        "clip.json": b'{"usable":true}',
        "job.yaml": b"name: functional\n",
        "metadata.jsonl": b'{"file_name":"clip.mp4","caption":"NORA7 moves"}\n',
    }
    for name, data in bodies.items():
        (source / name).write_bytes(data)

    def no_hub(*_, **__):
        raise AssertionError("Local inputs must not use Hub credentials or APIs")

    monkeypatch.setattr(pull, "Hub", no_hub)
    monkeypatch.setattr(pull, "token_from_env", no_hub)
    out = tmp_path / "datasets/training"
    return source, out, bodies


def test_local_install_exact_media_sidecars_job_and_digest_without_hub(tmp_path, monkeypatch):
    source, out, bodies = fixture(tmp_path, monkeypatch)
    (source / ".installing").touch()
    args = ["--local-dir", str(source), "--to", str(out), "--only-metadata"]
    assert pull.main(args) == 0
    for name in ["clip.mp4", "clip.txt", "clip.json", "job.yaml"]:
        assert (out / name).read_bytes() == bodies[name]
    manifest = json.loads((out / "manifest.json").read_text())
    expected = hashlib.sha256()
    for name, data in sorted(bodies.items()):
        expected.update(f"{name}\0{len(data)}\0{hashlib.sha256(data).hexdigest()}\n".encode())
    assert manifest["input_digest"] == expected.hexdigest()
    assert (
        manifest["source"] == "local"
        and manifest["repo_id"] is None
        and manifest["revision"] is None
    )
    assert manifest["requested_revision"] is None and manifest["only_metadata"]
    assert manifest["count"] == manifest["with_caption"] == 1 and manifest["without_caption"] == 0
    assert not source.exists()


@pytest.mark.parametrize("failure", ["missing", "caption", "symlink", "partial"])
def test_failed_local_install_preserves_old_dataset_and_uploads(tmp_path, monkeypatch, failure):
    source, out, _ = fixture(tmp_path, monkeypatch)
    out.mkdir(parents=True)
    (out / "old.png").write_bytes(b"previous dataset")
    if failure == "missing":
        (source / "clip.mp4").unlink()
    elif failure == "caption":
        (source / "metadata.jsonl").write_text('{"file_name":"clip.mp4"}\n')
        (source / "clip.txt").unlink()
    elif failure == "symlink":
        (source / "clip.mp4").unlink()
        (source / "clip.mp4").symlink_to(out / "old.png")
    else:
        (source / "clip.mp4.part").write_bytes(b"incomplete")
    assert pull.main(["--local-dir", str(source), "--to", str(out), "--only-metadata"]) == 1
    assert (out / "old.png").read_bytes() == b"previous dataset" and source.exists()
    assert not out.with_name(out.name + ".partial").exists()


def test_local_install_refuses_outside_source_or_destination_and_hub_revision(
    tmp_path, monkeypatch
):
    source, out, _ = fixture(tmp_path, monkeypatch)
    for args in (
        ["--local-dir", str(tmp_path), "--to", str(out), "--only-metadata"],
        ["--local-dir", str(source), "--to", str(tmp_path / "outside"), "--only-metadata"],
        ["--local-dir", str(source), "--to", str(out), "--only-metadata", "--revision", "main"],
        ["--local-dir", str(source), "--to", str(out)],
    ):
        assert pull.main(args) == 1
    assert source.exists() and not out.exists()


def test_native_and_backend_share_exact_utf8_filename_digest_fixture():
    import runpy

    fixture_path = Path(__file__).parents[3] / "tests/fixtures/local-input-digest.json"
    fixture = json.loads(fixture_path.read_text())
    rules = runpy.run_path(str(Path(__file__).parents[1] / "dataset_stage.py"))
    entries = [(row["name"], row["size"], row["sha256"]) for row in fixture["files"]]
    assert rules["digest_entries"](entries) == fixture["sha256"]


def test_completed_install_does_not_delete_a_new_upload_under_same_name(tmp_path, monkeypatch):
    source, out, bodies = fixture(tmp_path, monkeypatch)
    (source / ".installing").touch()
    original_remove = pull.shutil.rmtree
    witnessed = []

    def remove_old_stage(path, *args, **kwargs):
        if Path(path).name.startswith(".installed-"):
            assert Path(path) != source and not source.exists()
            source.mkdir()
            (source / "clip.mp4").write_bytes(b"new authenticated upload")
            witnessed.append(path)
        return original_remove(path, *args, **kwargs)

    monkeypatch.setattr(pull.shutil, "rmtree", remove_old_stage)
    assert pull.main(["--local-dir", str(source), "--to", str(out), "--only-metadata"]) == 0
    assert witnessed
    assert (source / "clip.mp4").read_bytes() == b"new authenticated upload"
    assert (out / "clip.mp4").read_bytes() == bodies["clip.mp4"]
    assert not list(source.parent.glob(".installed-*"))
