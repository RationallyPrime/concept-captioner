"""Offline inference-boundary tests; generated test bytes are explicitly synthetic."""

import hashlib
import importlib.util
import json
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location(
    "generate_results", Path(__file__).parents[1] / "generate_results.py"
)
generation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generation)


def setup(tmp_path, monkeypatch):
    monkeypatch.setenv("PODAGENT_WORKSPACE", str(tmp_path))
    source = tmp_path / "runs/source"
    (source / "output").mkdir(parents=True)
    (source / "run.json").write_text(json.dumps({"base_model": "black-forest-labs/FLUX.1-dev"}))
    (source / "output/chosen.safetensors").write_bytes(b"synthetic checkpoint")
    target = tmp_path / "runs/comparison"
    target.mkdir()
    request = {
        "run_id": "comparison",
        "source_run_id": "source",
        "checkpoint": "chosen.safetensors",
        "prompts": ["NORA7 at a desk", "NORA7 outdoors"],
        "seeds": [42, 7],
        "width": 512,
        "height": 512,
        "inference_steps": 20,
        "guidance_scale": 4,
        "num_frames": 1,
        "frame_rate": 24,
    }
    request["checkpoint_sha256"] = hashlib.sha256(b"synthetic checkpoint").hexdigest()
    (target / "source-run.json").write_text((source / "run.json").read_text())
    (target / "selected-checkpoint.safetensors").write_bytes(b"synthetic checkpoint")
    path = target / "generation.json"
    path.write_text(json.dumps(request))
    return path, request


def test_manifest_pairs_same_exact_prompts_and_seeds_with_selected_checkpoint(
    tmp_path, monkeypatch
):
    path, request = setup(tmp_path, monkeypatch)
    calls = []

    def fake_inference(cfg, checkpoint, params, rows, out):
        calls.append((cfg, checkpoint, params))
        for row in rows:
            for key in ("base_path", "lora_path"):
                (out / row[key]).write_bytes(b"synthetic output")

    monkeypatch.setattr(generation, "flux_generate", fake_inference)
    assert generation.generate(path, "aitoolkit") == 0
    manifest = json.loads((path.parent / "output/comparison.json").read_text())
    assert manifest["state"] == "complete"
    assert [(p["prompt"], p["seed"]) for p in manifest["pairs"]] == [
        (p, s) for p in request["prompts"] for s in request["seeds"]
    ]
    assert calls[0][1].name == "selected-checkpoint.safetensors"
    assert manifest["checkpoint_sha256"] == request["checkpoint_sha256"]
    assert not calls[0][1].exists()
    assert len({p[k] for p in manifest["pairs"] for k in ("base_path", "lora_path")}) == 8


def test_missing_or_interrupted_outputs_never_report_complete(tmp_path, monkeypatch):
    path, _ = setup(tmp_path, monkeypatch)
    monkeypatch.setattr(generation, "flux_generate", lambda *args: None)
    with pytest.raises(ValueError, match="expected output files"):
        generation.generate(path, "aitoolkit")
    manifest = json.loads((path.parent / "output/comparison.json").read_text())
    assert manifest["state"] == "failed"


def test_ltx_argv_preserves_pair_settings_and_loads_lora_only_on_trained_side(tmp_path):
    encoder = tmp_path / "encoder"
    encoder.mkdir()
    model = {"model_path": str(tmp_path / "base.safetensors"), "text_encoder_path": str(encoder)}
    request = {
        "width": 512,
        "height": 512,
        "num_frames": 17,
        "frame_rate": 24,
        "inference_steps": 20,
        "guidance_scale": 4,
    }
    row = {"prompt": "NORA7 walks", "seed": 42, "base_path": "base.mp4", "lora_path": "lora.mp4"}
    cp = tmp_path / "chosen.safetensors"
    base = generation.ltx_command(model, cp, request, row, "base", tmp_path)
    trained = generation.ltx_command(model, cp, request, row, "lora", tmp_path)
    assert base[1:3] == ["-m", "ltx_pipelines.ti2vid_one_stage"]
    assert "--lora" not in base
    assert trained[-3:] == ["--lora", str(cp), "1.0"]
    for flag in (
        "--prompt",
        "--seed",
        "--width",
        "--height",
        "--num-frames",
        "--num-inference-steps",
    ):
        assert base[base.index(flag) + 1] == trained[trained.index(flag) + 1]


def test_checkpoint_escape_fails_before_inference(tmp_path, monkeypatch):
    path, request = setup(tmp_path, monkeypatch)
    request["checkpoint"] = "../run.json"
    path.write_text(json.dumps(request))
    with pytest.raises(ValueError, match="relative"):
        generation.generate(path, "aitoolkit")
    assert not (path.parent / "output").exists()


def test_resume_replacing_original_config_and_weights_cannot_change_chosen_generation(
    tmp_path, monkeypatch
):
    path, _ = setup(tmp_path, monkeypatch)
    source = tmp_path / "runs/source"
    # Simulate a resume on another GPU after prepare, before base then LoRA sampling.
    (source / "run.json").write_text(json.dumps({"base_model": "some/different-model", "steps": 3}))
    (source / "output/chosen.safetensors").write_bytes(b"new resumed checkpoint")
    seen = []

    def fake_inference(cfg, checkpoint, params, rows, out):
        seen.append((cfg["base_model"], checkpoint.read_bytes()))
        for row in rows:
            for key in ("base_path", "lora_path"):
                (out / row[key]).write_bytes(b"synthetic output")

    monkeypatch.setattr(generation, "flux_generate", fake_inference)
    assert generation.generate(path, "aitoolkit") == 0
    manifest = json.loads((path.parent / "output/comparison.json").read_text())
    assert seen == [("black-forest-labs/FLUX.1-dev", b"synthetic checkpoint")]
    assert manifest["source_config"]["base_model"] == "black-forest-labs/FLUX.1-dev"
    assert manifest["checkpoint_sha256"] == hashlib.sha256(b"synthetic checkpoint").hexdigest()
    assert not (path.parent / "selected-checkpoint.safetensors").exists()
    assert (source / "output/chosen.safetensors").read_bytes() == b"new resumed checkpoint"


def test_changed_snapshot_fails_before_inference(tmp_path, monkeypatch):
    path, _ = setup(tmp_path, monkeypatch)
    (path.parent / "selected-checkpoint.safetensors").write_bytes(b"changed copy")
    with pytest.raises(ValueError, match="snapshot checksum changed"):
        generation.generate(path, "aitoolkit")
    assert not (path.parent / "output").exists()
