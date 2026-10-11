"""Authenticated binary staging: size/confinement refusals and recoverable replacement."""

import asyncio

import pytest
from pydantic import ValidationError
from starlette.requests import Request

from podagent.catalog import CATALOG, parse_params
from podagent.uploads import MAX_UPLOAD_BYTES, UploadWriter, claim_stage, release_stage


def test_large_header_anonymous_and_wrong_names_do_not_create_files(client, anon_client, settings):
    headers = {"Content-Length": str(MAX_UPLOAD_BYTES + 1)}
    assert (
        anon_client.put("/uploads/ready/clip.mp4", content=b"x", headers=headers).status_code == 401
    )
    assert client.put("/uploads/ready/clip.mp4", content=b"x", headers=headers).status_code == 413
    assert client.put("/uploads/.bad/clip.mp4", content=b"x").status_code == 422
    assert client.put("/uploads/ready/program.py", content=b"x").status_code == 422
    assert client.put("/uploads/ready/a%5Cb.mp4", content=b"x").status_code == 422
    assert not settings.paths.uploads.exists()


def test_real_binary_upload_exceeds_control_body_cap_and_replaces_atomically(client, settings):
    body = b"synthetic media" * 100_000  # larger than the ordinary 1 MiB JSON control limit
    response = client.put("/uploads/ready/clip.mp4", content=body)
    assert response.status_code == 200
    assert response.json() == {"name": "ready", "file_name": "clip.mp4", "size": len(body)}
    file = settings.paths.uploads / "ready/clip.mp4"
    assert file.read_bytes() == body
    assert client.put("/uploads/ready/clip.mp4", content=b"replacement").status_code == 200
    assert file.read_bytes() == b"replacement" and not list(file.parent.glob("*.part"))


def test_staged_quota_counts_replacements_and_keeps_prior_files(client, settings, monkeypatch):
    monkeypatch.setattr("podagent.uploads.MAX_STAGED_BYTES", 12)
    assert client.put("/uploads/ready/clip.mp4", content=b"12345678").status_code == 200
    assert client.put("/uploads/ready/other.png", content=b"123456").status_code == 413
    root = settings.paths.uploads / "ready"
    assert (root / "clip.mp4").read_bytes() == b"12345678" and not (root / "other.png").exists()
    assert client.put("/uploads/ready/clip.mp4", content=b"12").status_code == 200
    assert client.put("/uploads/ready/other.png", content=b"123456").status_code == 200
    assert sum(file.stat().st_size for file in root.iterdir()) == 8


def test_symlinked_stages_and_destinations_refused(client, settings, tmp_path):
    root = settings.paths.uploads
    root.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    (root / "ready").symlink_to(outside, target_is_directory=True)
    assert client.put("/uploads/ready/clip.mp4", content=b"data").status_code == 422
    (root / "ready").unlink()
    (root / "ready").mkdir()
    (root / "ready/clip.mp4").symlink_to(outside / "private.mp4")
    assert client.put("/uploads/ready/clip.mp4", content=b"data").status_code == 422
    assert not (outside / "private.mp4").exists()


def request(chunks, length):
    messages = iter(
        [
            {"type": "http.request", "body": chunk, "more_body": index < len(chunks) - 1}
            for index, chunk in enumerate(chunks)
        ]
    )

    async def receive():
        return next(messages)

    return Request(
        {"type": "http", "headers": [(b"content-length", str(length).encode())]}, receive
    )


@pytest.mark.parametrize("chunks,length", [([b"123", b"456"], 3), ([b"12"], 5)])
async def test_declared_received_mismatch_keeps_successful_file(settings, chunks, length):
    writer = UploadWriter(settings.paths)
    await writer.write(request([b"old"], 3), "ready", "clip.mp4")
    with pytest.raises(Exception, match="Content-Length"):
        await writer.write(request(chunks, length), "ready", "clip.mp4")
    root = settings.paths.uploads / "ready"
    assert (root / "clip.mp4").read_bytes() == b"old" and not list(root.glob("*.part"))


async def test_cancelled_stream_cleans_partial_and_releases_writer(settings):
    writer = UploadWriter(settings.paths)

    async def receive():
        raise asyncio.CancelledError

    incoming = Request({"type": "http", "headers": [(b"content-length", b"4")]}, receive)
    with pytest.raises(asyncio.CancelledError):
        await writer.write(incoming, "ready", "clip.mp4")
    assert not list((settings.paths.uploads / "ready").glob("*.part"))
    await writer.write(request([b"next"], 4), "ready", "clip.mp4")
    assert (settings.paths.uploads / "ready/clip.mp4").read_bytes() == b"next"


def test_local_catalog_is_typed_fixed_and_protects_installing_stage(client, settings):
    for file, content in {
        "metadata.jsonl": b'{"file_name":"clip.mp4","caption":"NORA7"}\n',
        "clip.mp4": b"selected segment",
    }.items():
        assert client.put(f"/uploads/ready/{file}", content=content).status_code == 200
    params = parse_params(
        "pull-dataset",
        {"local_name": "ready", "name": "training", "only_metadata": True},
        settings.paths,
    )
    argv = CATALOG["pull-dataset"].argv(params, [], settings.paths)
    assert argv[argv.index("--local-dir") + 1] == str(settings.paths.uploads / "ready")
    assert "--repo" not in argv and "--revision" not in argv
    claim_stage(settings.paths, "ready")
    assert client.put("/uploads/ready/clip.mp4", content=b"changed").status_code == 422
    release_stage(settings.paths, "ready")
    assert client.put("/uploads/ready/clip.mp4", content=b"changed").status_code == 200
    for change in (
        {"repo_id": "me/data"},
        {"revision": "main"},
        {"hf_token": "synthetic"},
        {"only_metadata": False},
    ):
        with pytest.raises(ValidationError):
            parse_params(
                "pull-dataset",
                {"local_name": "ready", "only_metadata": True, **change},
                settings.paths,
            )


def test_missing_length_is_rejected_before_body_read(settings):
    from starlette.datastructures import Headers

    from podagent.app import EdgeGuard
    from podagent.auth import Authenticator

    guard = EdgeGuard(None, auth=Authenticator(settings.token))
    error = guard.reject(
        Headers({"Authorization": f"Bearer {settings.token}"}),
        path="/uploads/ready/clip.mp4",
        method="PUT",
    )
    assert error.status == 413 and "Content-Length" in error.message


def test_failed_spawn_releases_stage_claim_without_discarding_uploads(
    client, settings, monkeypatch
):
    body = b'{"file_name":"clip.mp4","caption":"NORA7"}\n'
    assert client.put("/uploads/ready/metadata.jsonl", content=body).status_code == 200

    def fail(*_, **__):
        raise OSError("synthetic spawn failure")

    monkeypatch.setattr("podagent.supervisor.subprocess.Popen", fail)
    response = client.post(
        "/services/pull-dataset/start",
        json={"params": {"local_name": "ready", "only_metadata": True}},
    )
    assert response.status_code == 500
    root = settings.paths.uploads / "ready"
    assert not (root / ".installing").exists() and (root / "metadata.jsonl").read_bytes() == body
    assert client.put("/uploads/ready/clip.mp4", content=b"retry").status_code == 200


def test_log_write_failure_releases_local_stage_for_retry(client, settings, monkeypatch):
    from pathlib import Path

    assert client.put("/uploads/ready/metadata.jsonl", content=b"{}\n").status_code == 200
    original = Path.open

    def fail_log(path, *args, **kwargs):
        if path.name == "pull-dataset.log":
            raise OSError("synthetic full log filesystem")
        return original(path, *args, **kwargs)

    monkeypatch.setattr(Path, "open", fail_log)
    with pytest.raises(OSError, match="synthetic full log"):
        client.app.state.supervisor.start(
            "pull-dataset", [], {"local_name": "ready", "only_metadata": True}
        )
    assert not (settings.paths.uploads / "ready/.installing").exists()
    assert client.put("/uploads/ready/clip.mp4", content=b"retry").status_code == 200


async def test_active_upload_refuses_dataset_claim_until_stream_finishes(settings):
    writer = UploadWriter(settings.paths)
    await writer.write(request([b"{}\n"], 3), "ready", "metadata.jsonl")
    entered = asyncio.Event()
    finish = asyncio.Event()

    async def receive():
        entered.set()
        await finish.wait()
        return {"type": "http.request", "body": b"data", "more_body": False}

    incoming = Request({"type": "http", "headers": [(b"content-length", b"4")]}, receive)
    task = asyncio.create_task(writer.write(incoming, "ready", "clip.mp4"))
    await asyncio.wait_for(entered.wait(), 2)
    try:
        with pytest.raises(Exception, match="finish"):
            claim_stage(settings.paths, "ready")
    finally:
        finish.set()
        await asyncio.wait_for(task, 2)
    claim_stage(settings.paths, "ready")
    release_stage(settings.paths, "ready")
    assert (settings.paths.uploads / "ready/clip.mp4").read_bytes() == b"data"


def test_upload_write_failure_returns_existing_error_envelope(client, monkeypatch):
    async def fail(*_, **__):
        raise OSError("synthetic full upload filesystem")

    monkeypatch.setattr(UploadWriter, "write", fail)
    response = client.put("/uploads/ready/clip.mp4", content=b"data")
    assert response.status_code == 500
    assert "storage" in response.json()["error"]["message"]
