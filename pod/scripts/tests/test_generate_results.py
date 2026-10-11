"""Offline inference-boundary tests; generated test bytes are explicitly synthetic."""

import hashlib
import importlib.util
import json
import os
import select
import signal
import subprocess
import sys
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
    assert not (path.parent / "selected-checkpoint.safetensors").exists()


@pytest.mark.parametrize("failure", ["request", "source", "family"])
def test_early_failures_remove_private_copy_and_preserve_source(tmp_path, monkeypatch, failure):
    path, _ = setup(tmp_path, monkeypatch)
    if failure == "request":
        path.write_text("not json")
    elif failure == "source":
        (path.parent / "source-run.json").unlink()
    else:
        (path.parent / "source-run.json").write_text(json.dumps({"base_model": "unsupported"}))
    with pytest.raises((OSError, ValueError)):
        generation.generate(path, "aitoolkit")
    assert not (path.parent / "selected-checkpoint.safetensors").exists()
    assert (
        tmp_path / "runs/source/output/chosen.safetensors"
    ).read_bytes() == b"synthetic checkpoint"


def test_real_sigterm_finalizes_failed_manifest_and_keeps_partial_outputs(tmp_path, monkeypatch):
    path, _ = setup(tmp_path, monkeypatch)
    script = """
import runpy, sys, time
from pathlib import Path
module = runpy.run_path(sys.argv[1])
generate = module['generate']
def wait(cfg, checkpoint, request, rows, output):
    (output / rows[0]['base_path']).write_bytes(b'partial output')
    print('ready', flush=True)
    time.sleep(30)
generate.__globals__['flux_generate'] = wait
try:
    generate(Path(sys.argv[2]), 'aitoolkit')
except InterruptedError:
    sys.exit(1)
"""
    proc = subprocess.Popen(
        [sys.executable, "-c", script, str(Path(generation.__file__)), str(path)],
        env={**os.environ, "PODAGENT_WORKSPACE": str(tmp_path)},
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        assert select.select([proc.stdout], [], [], 5)[0], "synthetic inference did not start"
        assert proc.stdout.readline().strip() == "ready"
        proc.send_signal(signal.SIGTERM)
        proc.communicate(timeout=5)
        assert proc.returncode == 1
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.communicate(timeout=5)
    manifest = json.loads((path.parent / "output/comparison.json").read_text())
    assert manifest["state"] == "failed"
    assert (path.parent / "output/pair-000-base.png").read_bytes() == b"partial output"
    assert not (path.parent / "selected-checkpoint.safetensors").exists()
    assert (
        tmp_path / "runs/source/output/chosen.safetensors"
    ).read_bytes() == b"synthetic checkpoint"


def test_ltx_generation_uses_retained_config_without_pruned_training_inputs(tmp_path, monkeypatch):
    monkeypatch.setenv("PODAGENT_WORKSPACE", str(tmp_path))
    wrapper = generation.runpy.run_path(str(Path(generation.__file__).with_name("launch_ltx.py")))
    calls = []
    wrapper["download_hub_model"] = lambda _: None  # model preparation is outside this CPU witness
    monkeypatch.setattr(generation.runpy, "run_path", lambda _: wrapper)
    monkeypatch.setattr(generation.subprocess, "run", lambda argv, **_: calls.append(argv))
    cfg = {
        "run_id": "source",
        "dataset": {"path": str(tmp_path / "datasets/pruned")},
        "triggers": ["NORA7"],
        "base_model": "Lightricks/LTX-2",
        "steps": 2,
    }
    request = {
        "width": 512,
        "height": 512,
        "num_frames": 49,
        "frame_rate": 24,
        "inference_steps": 2,
        "guidance_scale": 4,
    }
    row = {"prompt": "NORA7 moves", "seed": 42, "base_path": "base.mp4", "lora_path": "lora.mp4"}
    checkpoint = tmp_path / "runs/comparison/selected-checkpoint.safetensors"
    generation.ltx_generate(cfg, checkpoint, request, [row], tmp_path)
    assert len(calls) == 2
    assert "--lora" not in calls[0] and str(checkpoint) in calls[1]
    assert not Path(cfg["dataset"]["path"]).exists()  # no restore/pull for inference
