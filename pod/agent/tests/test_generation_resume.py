"""Concrete control-plane witnesses; no GPU, model download or provider calls."""

import hashlib
import json
import struct

import pytest
from pydantic import ValidationError

from podagent.catalog import CATALOG, parse_params

HEADER = json.dumps({"__metadata__": {"training_info": json.dumps({"step": 2})}}).encode()
CHECKPOINT = struct.pack("<Q", len(HEADER)) + HEADER


def saved_run(paths, *, model="black-forest-labs/FLUX.1-dev"):
    run = paths.run_dir("source-run")
    (run / "output").mkdir(parents=True)
    cfg = {
        "run_id": "source-run",
        "dataset": {"path": str(paths.datasets / "source-run")},
        "triggers": ["NORA7"],
        "base_model": model,
        "steps": 2,
        "rank": 2,
    }
    (paths.datasets / "source-run").mkdir(parents=True, exist_ok=True)
    (run / "run.json").write_text(json.dumps(cfg))
    checkpoint = (
        run / "output/lora_step_00002.safetensors"
        if model == "Lightricks/LTX-2.3"
        else run / "output/source-run/source-run_000002.safetensors"
    )
    checkpoint.parent.mkdir(exist_ok=True)
    checkpoint.write_bytes(CHECKPOINT)
    return run, cfg


def request():
    return {
        "run_id": "comparison-run",
        "source_run_id": "source-run",
        "checkpoint": "source-run/source-run_000002.safetensors",
        "prompts": ["NORA7 on a beach"],
        "seeds": [42, 7],
    }


def test_generation_writes_own_config_and_uses_exact_trainer_venv(settings):
    paths = settings.paths
    run, _ = saved_run(paths)
    params = parse_params("generate-aitoolkit", request(), paths)
    spec = CATALOG["generate-aitoolkit"]
    spec.prepare(params, paths)
    assert json.loads((paths.run_dir(params.run_id) / "generation.json").read_text())["seeds"] == [
        42,
        7,
    ]
    argv = spec.argv(params, [1], paths)
    assert argv[0] == paths.venv_bin("aitoolkit", "python")
    assert argv[1] == str(paths.scripts / "generate_results.py")
    assert argv[2:4] == ["--trainer", "aitoolkit"]
    assert (run / "output/source-run/source-run_000002.safetensors").read_bytes() == CHECKPOINT


@pytest.mark.parametrize(
    "change",
    [
        {"checkpoint": "../run.json"},
        {"checkpoint": "/etc/passwd"},
        {"prompts": ["NORA7 --seed 3"]},
        {"seeds": [-1]},
        {"run_id": "source-run"},
        {"num_frames": 17},
    ],
)
def test_bad_generation_rejected_before_creating_output(settings, change):
    saved_run(settings.paths)
    with pytest.raises(ValidationError):
        parse_params("generate-aitoolkit", {**request(), **change}, settings.paths)
    assert not settings.paths.run_dir("comparison-run").exists()


def test_generation_rejects_symlink_checkpoint_and_unsupported_family(settings, tmp_path):
    run, cfg = saved_run(settings.paths)
    cp = run / "output/source-run/source-run_000002.safetensors"
    cp.unlink()
    outside = tmp_path / "outside.safetensors"
    outside.write_bytes(b"other")
    cp.symlink_to(outside)
    with pytest.raises(ValidationError):
        parse_params("generate-aitoolkit", request(), settings.paths)
    cp.unlink()
    cp.write_bytes(b"checkpoint")
    cfg["base_model"] = "some/unsupported-model"
    (run / "run.json").write_text(json.dumps(cfg))
    with pytest.raises(ValidationError, match="supports"):
        parse_params("generate-aitoolkit", request(), settings.paths)


def test_resume_preserves_settings_and_requires_existing_checkpoint(settings):
    run, cfg = saved_run(settings.paths)
    params = parse_params("trainer-aitoolkit", {**cfg, "steps": 4, "resume": True}, settings.paths)
    assert params.resume and params.steps == 4
    with pytest.raises(ValidationError, match="Use Repeat"):
        parse_params("trainer-aitoolkit", {**cfg, "rank": 16, "resume": True}, settings.paths)
    assert not parse_params("trainer-aitoolkit", cfg, settings.paths).resume
    (run / "output/source-run/source-run_000002.safetensors").unlink()
    (run / "output/foreign.safetensors").write_bytes(b"unrelated weights")
    with pytest.raises(ValidationError, match="No trainer checkpoint"):
        parse_params("trainer-aitoolkit", {**cfg, "resume": True}, settings.paths)


def test_ltx_resume_requires_matching_native_training_state(settings):
    run, cfg = saved_run(settings.paths, model="Lightricks/LTX-2.3")
    with pytest.raises(ValidationError, match="training_state_step"):
        parse_params("trainer-ltx", {**cfg, "resume": True}, settings.paths)
    (run / "output/training_state_step_00002.pt").write_bytes(b"native state")
    assert parse_params("trainer-ltx", {**cfg, "steps": 4, "resume": True}, settings.paths).resume


def test_ltx_approved_bucket_mode_is_validated_by_shared_preprocess_policy(settings):
    _, cfg = saved_run(settings.paths, model="Lightricks/LTX-2.3")
    params = parse_params(
        "trainer-ltx",
        {**cfg, "extra": {"preprocess": {"buckets_from_media": True}}},
        settings.paths,
    )
    assert params.extra["preprocess"]["buckets_from_media"] is True
    for options in (
        {"buckets_from_media": "yes"},
        {"buckets_from_media": True, "resolution_buckets": "512x512x33"},
    ):
        with pytest.raises(ValidationError):
            parse_params("trainer-ltx", {**cfg, "extra": {"preprocess": options}}, settings.paths)


def test_authenticated_generation_shares_real_gpu_reservation(client, settings):
    saved_run(settings.paths)
    response = client.post(
        "/services/generate-aitoolkit/start", json={"gpus": [1], "params": request()}
    )
    assert response.status_code == 201
    conflict = client.post(
        "/services/vllm/start", json={"gpus": [1], "params": {"model": "org/model"}}
    )
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "gpu_busy"
    assert client.post("/services/generate-aitoolkit/stop").status_code == 200


def test_run_config_reports_captured_revision_and_hides_token(client, settings):
    run, cfg = saved_run(settings.paths)
    cfg["hf_token"] = "test-secret-not-a-real-key"
    (run / "run.json").write_text(json.dumps(cfg))
    (run / "dataset-manifest.json").write_text(
        json.dumps({"revision": "abc123", "repo_id": "me/data", "count": 2})
    )
    response = client.get("/runs/source-run/config")
    assert response.status_code == 200
    assert response.json()["dataset"] == {"revision": "abc123", "repo_id": "me/data", "count": 2}
    assert "hf_token" not in response.json()["config"]


def test_generation_prepares_private_immutable_checkpoint_and_config_snapshot(settings):
    paths = settings.paths
    run, source = saved_run(paths)
    source["hf_token"] = "private-not-real-token"
    (run / "run.json").write_text(json.dumps(source))
    params = parse_params("generate-aitoolkit", request(), paths)
    CATALOG["generate-aitoolkit"].prepare(params, paths)
    target = paths.run_dir(params.run_id)
    prepared = json.loads((target / "generation.json").read_text())
    captured = json.loads((target / "source-run.json").read_text())
    original = run / "output/source-run/source-run_000002.safetensors"
    original.write_bytes(b"resumed weights")
    source["steps"] = 3
    (run / "run.json").write_text(json.dumps(source))
    assert (target / "selected-checkpoint.safetensors").read_bytes() == CHECKPOINT
    assert prepared["checkpoint_sha256"] == hashlib.sha256(CHECKPOINT).hexdigest()
    assert captured["steps"] == 2 and "hf_token" not in captured
    assert not (target / "output").exists()  # snapshots are outside served run outputs


@pytest.mark.parametrize("steps", [1, 2])
def test_resume_refuses_no_op_or_regressing_saved_checkpoint_step(settings, steps):
    _, cfg = saved_run(settings.paths)
    with pytest.raises(ValidationError, match=r"must exceed.*step 2"):
        parse_params("trainer-aitoolkit", {**cfg, "steps": steps, "resume": True}, settings.paths)


def test_resume_refuses_unknown_checkpoint_step(settings):
    run, cfg = saved_run(settings.paths)
    (run / "output/source-run/source-run_000002.safetensors").write_bytes(
        b"not safetensors metadata"
    )
    with pytest.raises(ValidationError, match="readable saved training step"):
        parse_params("trainer-aitoolkit", {**cfg, "steps": 4, "resume": True}, settings.paths)


@pytest.mark.parametrize("steps", [1, 2])
def test_ltx_resume_refuses_no_op_with_matching_native_state(settings, steps):
    run, cfg = saved_run(settings.paths, model="Lightricks/LTX-2.3")
    (run / "output/training_state_step_00002.pt").write_bytes(b"native state")
    with pytest.raises(ValidationError, match=r"must exceed.*step 2"):
        parse_params("trainer-ltx", {**cfg, "steps": steps, "resume": True}, settings.paths)


def test_resume_pruned_dataset_requires_exact_manifest_before_prepare(settings):
    run, cfg = saved_run(settings.paths)
    (settings.paths.datasets / "source-run").rmdir()
    with pytest.raises(ValidationError, match="restore Resume inputs"):
        parse_params("trainer-aitoolkit", {**cfg, "steps": 4, "resume": True}, settings.paths)
    manifest = {
        "repo_id": "me/data",
        "revision": "a" * 40,
        "split": "validation",
        "image_column": "media",
        "caption_column": "text",
        "id_column": None,
        "only_metadata": True,
    }
    (run / "dataset-manifest.json").write_text(json.dumps(manifest))
    params = parse_params("trainer-aitoolkit", {**cfg, "steps": 4, "resume": True}, settings.paths)
    CATALOG["trainer-aitoolkit"].prepare(params, settings.paths)
    assert json.loads((run / "dataset-manifest.json").read_text()) == manifest
    assert not (settings.paths.datasets / "source-run").exists()  # child performs the pull
    manifest["revision"] = "main"
    (run / "dataset-manifest.json").write_text(json.dumps(manifest))
    with pytest.raises(ValidationError, match="exact resolved Hub commit"):
        parse_params("trainer-aitoolkit", {**cfg, "steps": 5, "resume": True}, settings.paths)


@pytest.mark.parametrize(
    "extra",
    [
        {"model": {"load_checkpoint": None}},
        {"model": {"load_checkpoint": "/workspace/models/older.safetensors"}},
        {"checkpoints": {"no_resume": True}},
    ],
)
def test_ltx_resume_refuses_overrides_that_restart_or_select_another_checkpoint(settings, extra):
    run, cfg = saved_run(settings.paths, model="Lightricks/LTX-2.3")
    extra = json.loads(json.dumps(extra))
    if extra.get("model", {}).get("load_checkpoint") is not None:
        extra["model"]["load_checkpoint"] = str(settings.paths.models / "older.safetensors")
    cfg["extra"] = extra
    (run / "run.json").write_text(json.dumps(cfg))
    (run / "output/training_state_step_00002.pt").write_bytes(b"native state")
    assert not parse_params("trainer-ltx", cfg, settings.paths).resume  # ordinary extra unchanged
    with pytest.raises(ValidationError, match="latest native checkpoint"):
        parse_params("trainer-ltx", {**cfg, "steps": 4, "resume": True}, settings.paths)


def test_ltx_resume_accepts_explicit_native_state_restoration(settings):
    run, cfg = saved_run(settings.paths, model="Lightricks/LTX-2.3")
    cfg["extra"] = {"checkpoints": {"no_resume": False}}
    (run / "run.json").write_text(json.dumps(cfg))
    (run / "output/training_state_step_00002.pt").write_bytes(b"native state")
    assert parse_params("trainer-ltx", {**cfg, "steps": 4, "resume": True}, settings.paths).resume
