"""Run artifact retrieval (POD-SPEC §2.10, §2.11): list and fetch the run's output directory.

A user without a Hub account gets the trained LoRA through these two routes, so they are
checked for what they serve (sizes, digests, bytes) and, mostly, for what they must never
serve: anything outside ``/workspace/runs/<id>/output/`` by ``..``, an absolute path, a
symlinked file, directory or root, or a request without the bearer.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path

import pytest
from conftest import TOKEN
from fastapi.testclient import TestClient

from podagent.auth import TENSORBOARD_COOKIE
from podagent.settings import Settings

RUN = "nora7-h3-001"
WEIGHTS = b"\x00safetensors-bytes\x01" * 1000
SAMPLE = b"\x89PNG fake sample"
SECRET = b"outside the output directory\n"


def expect_error(response, status: int, code: str) -> dict:  # type: ignore[no-untyped-def]
    assert response.status_code == status, response.text
    error = response.json()["error"]
    assert error["code"] == code, error
    return error


@pytest.fixture
def run_dir(settings: Settings, tmp_path: Path) -> Path:
    settings.paths.ensure()
    run = settings.paths.run_dir(RUN)
    output = run / "output"
    (output / "checkpoints").mkdir(parents=True)
    (output / "samples").mkdir()
    (output / "checkpoints" / "lora_weights_step_00002.safetensors").write_bytes(WEIGHTS)
    (output / "samples" / "step 2.png").write_bytes(SAMPLE)
    (run / "run.json").write_text("{}\n")
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "secret.txt").write_bytes(SECRET)
    # Symlinks of every kind: to a file outside, to a directory outside, and to a file inside.
    (output / "leak.txt").symlink_to(outside / "secret.txt")
    (output / "leakdir").symlink_to(outside, target_is_directory=True)
    (output / "latest.safetensors").symlink_to(
        output / "checkpoints" / "lora_weights_step_00002.safetensors"
    )
    return run


def test_list_reports_regular_files_with_size_and_sha256(client: TestClient, run_dir: Path) -> None:
    response = client.get(f"/runs/{RUN}/files")
    assert response.status_code == 200
    body = response.json()
    assert body["run_id"] == RUN and body["root"] == str(run_dir / "output")
    assert [item["path"] for item in body["files"]] == [
        "checkpoints/lora_weights_step_00002.safetensors",
        "samples/step 2.png",
    ]
    weights, sample = body["files"]
    assert set(weights) == {"path", "size", "sha256", "modified_at"}
    assert weights["size"] == len(WEIGHTS)
    assert weights["sha256"] == hashlib.sha256(WEIGHTS).hexdigest()
    assert sample["sha256"] == hashlib.sha256(SAMPLE).hexdigest()
    assert weights["modified_at"].endswith("Z")


def test_list_follows_changes(client: TestClient, run_dir: Path) -> None:
    target = run_dir / "output" / "samples" / "step 2.png"
    first = client.get(f"/runs/{RUN}/files").json()["files"][1]["sha256"]
    target.write_bytes(SAMPLE + b"more")
    os.utime(target, ns=(1, 2_000_000_000))  # a different mtime even on a coarse clock
    second = client.get(f"/runs/{RUN}/files").json()["files"][1]
    assert second["sha256"] == hashlib.sha256(SAMPLE + b"more").hexdigest() != first


def test_list_without_output_is_empty_and_unknown_runs_are_404(
    client: TestClient, settings: Settings
) -> None:
    settings.paths.run_dir("fresh-run").mkdir(parents=True)
    assert client.get("/runs/fresh-run/files").json()["files"] == []
    expect_error(client.get("/runs/no-such-run/files"), 404, "not_found")
    expect_error(client.get("/runs/no-such-run/files/a.bin"), 404, "not_found")
    expect_error(client.get("/runs/.hidden/files"), 422, "validation")


def test_fetch_streams_the_file(client: TestClient, run_dir: Path) -> None:
    response = client.get(f"/runs/{RUN}/files/checkpoints/lora_weights_step_00002.safetensors")
    assert response.status_code == 200 and response.content == WEIGHTS
    assert response.headers["content-type"] == "application/octet-stream"
    assert response.headers["content-length"] == str(len(WEIGHTS))
    assert "lora_weights_step_00002.safetensors" in response.headers["content-disposition"]
    spaced = client.get(f"/runs/{RUN}/files/samples/step%202.png")
    assert spaced.status_code == 200 and spaced.content == SAMPLE
    head = client.head(f"/runs/{RUN}/files/samples/step%202.png")
    assert head.status_code == 200 and head.headers["content-length"] == str(len(SAMPLE))
    # A broken transfer of a multi-gigabyte file resumes with a byte range.
    part = client.get(
        f"/runs/{RUN}/files/checkpoints/lora_weights_step_00002.safetensors",
        headers={"Range": "bytes=10-19"},
    )
    assert part.status_code == 206 and part.content == WEIGHTS[10:20]
    assert part.headers["content-range"] == f"bytes 10-19/{len(WEIGHTS)}"


@pytest.mark.parametrize(
    "path",
    [
        "%2E%2E/run.json",
        "checkpoints/%2E%2E/%2E%2E/run.json",
        "%2E%2E%2F%2E%2E%2F%2E%2E%2Fsettings",
        "%2Fetc%2Fpasswd",
        "/etc/passwd",
        "checkpoints//lora_weights_step_00002.safetensors",
        "%2E/samples/step%202.png",
        "samples/step%202.png%00",
        "",
    ],
)
def test_fetch_refuses_dot_absolute_and_empty_segments(
    client: TestClient, run_dir: Path, path: str
) -> None:
    response = client.get(f"/runs/{RUN}/files/{path}")
    expect_error(response, 422, "validation")


@pytest.mark.parametrize(
    "path", ["leak.txt", "leakdir/secret.txt", "latest.safetensors", "checkpoints", "missing.bin"]
)
def test_fetch_refuses_symlinks_directories_and_missing_files(
    client: TestClient, run_dir: Path, path: str
) -> None:
    response = client.get(f"/runs/{RUN}/files/{path}")
    expect_error(response, 404, "not_found")
    assert SECRET not in response.content


def test_symlinked_output_root_is_not_served(
    client: TestClient, settings: Settings, tmp_path: Path
) -> None:
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    (elsewhere / "secret.txt").write_bytes(SECRET)
    run = settings.paths.run_dir("linked-run")
    run.mkdir(parents=True)
    (run / "output").symlink_to(elsewhere, target_is_directory=True)
    assert client.get("/runs/linked-run/files").json()["files"] == []
    expect_error(client.get("/runs/linked-run/files/secret.txt"), 404, "not_found")


def test_files_need_the_bearer(anon_client: TestClient, run_dir: Path) -> None:
    for path in (f"/runs/{RUN}/files", f"/runs/{RUN}/files/samples/step%202.png"):
        expect_error(anon_client.get(path), 401, "unauthorized")
        expect_error(
            anon_client.get(path, headers={"Authorization": "Bearer wrong-token-000"}),
            401,
            "unauthorized",
        )


def test_tensorboard_session_does_not_reach_files(client: TestClient, run_dir: Path) -> None:
    session = client.post("/tensorboard-session").json()["value"]
    client.headers.pop("authorization")
    client.cookies.set(TENSORBOARD_COOKIE, session, path="/")
    expect_error(client.get(f"/runs/{RUN}/files"), 401, "unauthorized")
    client.cookies.set(TENSORBOARD_COOKIE, TOKEN, path="/")
    expect_error(client.get(f"/runs/{RUN}/files"), 401, "unauthorized")
