"""Retention acts only on attributable, successful, terminal training inputs."""

import json
import os
import struct
import time
from types import SimpleNamespace

from podagent.catalog import CATALOG, parse_params
from podagent.storage import cleanup_candidates, cleanup_datasets, write_run_state


def completed(paths, name, *, stamp=1, dataset=None, state="exited", code=0, group=False):
    folder = paths.datasets / (dataset or name)
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "media.png").write_bytes(b"training bytes")
    run = paths.run_dir(name)
    checkpoint = run / "output" / name / f"{name}_000002.safetensors"
    checkpoint.parent.mkdir(parents=True)
    header = json.dumps({"__metadata__": {"training_info": json.dumps({"step": 2})}}).encode()
    checkpoint.write_bytes(struct.pack("<Q", len(header)) + header)
    os.utime(checkpoint, ns=(stamp, stamp))
    cfg = {
        "run_id": name,
        "dataset": {"path": str(folder)},
        "triggers": ["NORA7"],
        "base_model": "black-forest-labs/FLUX.1-dev",
        "steps": 2,
    }
    (run / "run.json").write_text(json.dumps(cfg))
    write_run_state(
        paths,
        SimpleNamespace(
            name="trainer-aitoolkit", run_id=name, state=state, exit_code=code, group_alive=group
        ),
    )
    return folder, run, cfg


def test_retention_keeps_latest_three_current_and_all_checkpoints(settings):
    paths = settings.paths
    for index in range(6):
        completed(paths, f"run{index}", stamp=index + 1)
    assert [p.name for p in cleanup_candidates(paths, keep_run_ids={"run0"})] == ["run1", "run2"]
    report = cleanup_datasets(paths, keep_run_ids={"run0"})
    assert report == {"removed": ["run1", "run2"], "reclaimed_bytes": 28}
    assert len(list(paths.runs.rglob("*.safetensors"))) == 6
    assert all((paths.run_dir(f"run{i}") / "run.json").exists() for i in range(6))


def test_unknown_failed_active_shared_and_symlink_inputs_stay(settings, tmp_path):
    paths = settings.paths
    for index in range(4):
        completed(paths, f"run{index}", stamp=index + 1)
    completed(paths, "failed", dataset="run0", state="failed", code=1)
    completed(paths, "active", state="running", code=None)
    _, unknown, _ = completed(paths, "unknown")
    (unknown / "run-state.json").unlink()
    outside = tmp_path / "outside"
    outside.mkdir()
    (paths.datasets / "linked").symlink_to(outside, target_is_directory=True)
    assert cleanup_candidates(paths) == []
    assert cleanup_datasets(paths)["removed"] == []
    assert outside.exists() and (paths.datasets / "unknown").exists()


def test_generation_source_is_kept_while_not_terminal(settings):
    paths = settings.paths
    for index in range(4):
        completed(paths, f"run{index}", stamp=index + 1)
    run = paths.run_dir("comparison")
    run.mkdir()
    (run / "generation.json").write_text(json.dumps({"source_run_id": "run0"}))
    write_run_state(
        paths,
        SimpleNamespace(
            name="generate-aitoolkit",
            run_id="comparison",
            state="running",
            exit_code=None,
            group_alive=False,
        ),
    )
    assert cleanup_candidates(paths) == []


def test_usage_and_explicit_cpu_cleanup_have_same_policy(client, anon_client, settings):
    paths = settings.paths
    for index in range(4):
        completed(paths, f"run{index}", stamp=index + 1)
    assert anon_client.get("/storage").status_code == 401
    usage = client.get("/storage").json()
    assert set(usage) == {
        "total_bytes",
        "used_bytes",
        "free_bytes",
        "datasets_bytes",
        "reclaimable_dataset_bytes",
        "regularization_cache_bytes",
    }
    assert all(type(value) is int for value in usage.values())
    assert usage["datasets_bytes"] == 56 and usage["reclaimable_dataset_bytes"] == 14
    response = client.post("/services/cleanup-datasets/start", json={"gpus": [], "params": {}})
    assert response.status_code == 201
    assert not (paths.datasets / "run0").exists()
    assert client.get("/storage").json()["reclaimable_dataset_bytes"] == 0
    assert CATALOG["cleanup-datasets"].argv(parse_params("cleanup-datasets", {}, paths), [], paths)[
        1:3
    ] == ["-m", "podagent.storage"]


def test_success_evidence_is_replaced_on_new_incarnation(settings):
    paths = settings.paths
    _, run, _ = completed(paths, "one")
    write_run_state(
        paths,
        SimpleNamespace(
            name="trainer-aitoolkit",
            run_id="one",
            state="running",
            exit_code=None,
            group_alive=False,
        ),
    )
    assert json.loads((run / "run-state.json").read_text())["state"] == "running"


def test_training_prepare_protects_current_and_prunes_only_completed(settings):
    paths = settings.paths
    for index in range(5):
        _, _, cfg = completed(paths, f"run{index}", stamp=index + 1)
    cfg["run_id"] = "new-run"
    cfg["dataset"]["path"] = str(paths.datasets / "run0")
    params = parse_params("trainer-aitoolkit", cfg, paths)
    CATALOG["trainer-aitoolkit"].prepare(params, paths)
    assert (paths.datasets / "run0").exists()
    assert not (paths.datasets / "run1").exists()


def test_supervisor_persists_terminal_success(client, settings, monkeypatch):
    # A trainer still uses the real supervisor lifecycle; its fake child exits after one tick.
    import sys

    monkeypatch.setattr("podagent.supervisor.fake_argv", lambda *_: [sys.executable, "-c", "pass"])
    params = {
        "run_id": "observed",
        "dataset": {"path": str(settings.paths.datasets / "observed")},
        "triggers": ["NORA7"],
        "base_model": "black-forest-labs/FLUX.1-dev",
        "steps": 1,
    }
    assert (
        client.post(
            "/services/trainer-aitoolkit/start", json={"gpus": [1], "params": params}
        ).status_code
        == 201
    )
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        states = client.get("/services").json()["services"]
        if any(s["name"] == "trainer-aitoolkit" and s["state"] == "exited" for s in states):
            break
        time.sleep(0.05)
    record = json.loads((settings.paths.run_dir("observed") / "run-state.json").read_text())
    assert record["state"] == "exited" and record["exit_code"] == 0 and not record["group_alive"]


def test_failed_new_prepare_cannot_restore_old_success_evidence(client, settings, monkeypatch):
    import sys
    from dataclasses import replace

    import pytest

    monkeypatch.setattr("podagent.supervisor.fake_argv", lambda *_: [sys.executable, "-c", "pass"])
    params = {
        "run_id": "again",
        "dataset": {"path": str(settings.paths.datasets / "again")},
        "triggers": ["NORA7"],
        "base_model": "black-forest-labs/FLUX.1-dev",
        "steps": 1,
    }
    supervisor = client.app.state.supervisor
    supervisor.start("trainer-aitoolkit", [1], params)
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if any(
            state.name == "trainer-aitoolkit" and state.state == "exited"
            for state in supervisor.states()
        ):
            break
        time.sleep(0.05)
    target = settings.paths.run_dir("again") / "run-state.json"
    assert target.exists()
    spec = CATALOG["trainer-aitoolkit"]

    def failed_prepare(parsed, paths):
        spec.prepare(parsed, paths)
        raise OSError("synthetic prepare failure after config write")

    monkeypatch.setitem(CATALOG, spec.name, replace(spec, prepare=failed_prepare))
    with pytest.raises(OSError, match="synthetic prepare failure"):
        supervisor.start(spec.name, [1], {**params, "steps": 2})
    supervisor.states()
    assert not target.exists()  # old finalized incarnation must not recreate success
