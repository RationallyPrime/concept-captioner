#!/usr/bin/env python3
"""Generate real, matched base/LoRA pairs through the pinned trainer's inference code.

The agent writes generation.json after validating the source checkpoint. Outputs and the
incremental comparison.json manifest live in this generation run's output directory, so
the existing authenticated files/download endpoints serve them. No listener is added.
FLUX uses ai-toolkit's StableDiffusion/GenerateImageConfig; LTX uses its official one-stage
CLI. Other families are deliberately unsupported. Heavy imports happen only at execution.
"""

from __future__ import annotations

import argparse
import gc
import hashlib
import json
import os
import re
import runpy
import subprocess
import sys
from pathlib import Path
from typing import Any

AI_PIN = "f7a1fb9a77e5418269b1e9eda4ace6d7c1b7bb47"
LTX_PIN = "9ec55f9f22798a3198d9c923856824821bc3317e"


def source_config(request: dict[str, Any], workspace: Path) -> tuple[dict[str, Any], Path]:
    if any(
        not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", request[key])
        for key in ("source_run_id", "run_id")
    ):
        raise ValueError("invalid source or generation run id")
    relative = request["checkpoint"]
    parts = relative.split("/")
    if any(p in {"", ".", ".."} for p in parts) or "\x00" in relative:
        raise ValueError("checkpoint must be relative to the source run's output")
    if Path(relative).suffix != ".safetensors":
        raise ValueError("checkpoint must be a safetensors file")
    source = workspace / "runs" / request["run_id"]
    cfg = json.loads((source / "source-run.json").read_text(encoding="utf-8"))
    checkpoint = source / "selected-checkpoint.safetensors"
    if checkpoint.is_symlink() or not checkpoint.is_file():
        raise ValueError("selected checkpoint snapshot is unavailable")
    with checkpoint.open("rb") as file:
        actual = hashlib.file_digest(file, "sha256").hexdigest()
    if actual != request["checkpoint_sha256"]:
        raise ValueError("selected checkpoint snapshot checksum changed")
    return cfg, checkpoint


def pairs(request: dict[str, Any], trainer: str) -> list[dict[str, Any]]:
    ext = "png" if trainer == "aitoolkit" else "mp4"
    return [
        {
            "prompt": prompt,
            "seed": seed,
            "base_path": f"pair-{index:03d}-base.{ext}",
            "lora_path": f"pair-{index:03d}-lora.{ext}",
        }
        for index, (prompt, seed) in enumerate(
            (p, s) for p in request["prompts"] for s in request["seeds"]
        )
    ]


def flux_generate(
    cfg: dict[str, Any],
    checkpoint: Path,
    request: dict[str, Any],
    rows: list[dict[str, Any]],
    out: Path,
) -> None:
    # Public source: toolkit/stable_diffusion_model.py load_model (fuses model.lora_path
    # before quantization), generate_images; config_modules.py GenerateImageConfig. The
    # built-in GenerateProcess has an invalid self.train_config fallback for legacy FLUX,
    # so call these same concrete primitives with the explicit flowmatch scheduler.
    import torch

    sys.path.insert(0, os.environ.get("AI_TOOLKIT_DIR", "/opt/ai-toolkit"))
    from toolkit.config_modules import GenerateImageConfig, ModelConfig
    from toolkit.sampler import get_sampler
    from toolkit.stable_diffusion_model import StableDiffusion

    for variant in ("base", "lora"):
        model = ModelConfig(
            name_or_path=cfg["base_model"],
            arch="flux",
            is_flux=True,
            quantize=True,
            dtype="bf16",
            lora_path=str(checkpoint) if variant == "lora" else None,
        )
        sd = StableDiffusion(
            device="cuda:0",
            model_config=model,
            dtype="bf16",
            noise_scheduler=get_sampler("flowmatch", arch="flux"),
        )
        with torch.no_grad():
            sd.load_model()
            configs = [
                GenerateImageConfig(
                    prompt=row["prompt"],
                    seed=row["seed"],
                    width=request["width"],
                    height=request["height"],
                    num_inference_steps=request["inference_steps"],
                    guidance_scale=request["guidance_scale"],
                    output_path=str(out / row[f"{variant}_path"]),
                    output_ext="png",
                )
                for row in rows
            ]
            # GenerateImageConfig parses '--' as prompt overrides. The API rejects those,
            # preserving the exact same prompt, seed and settings on both sides.
            sd.generate_images(configs, sampler="flowmatch")
        del sd
        gc.collect()
        torch.cuda.empty_cache()


def ltx_command(
    model: dict[str, Any],
    checkpoint: Path,
    request: dict[str, Any],
    row: dict[str, Any],
    variant: str,
    out: Path,
) -> list[str]:
    # Public source: ltx_pipelines/ti2vid_one_stage.py and utils/args.py at LTX_PIN.
    text_encoder = Path(model["text_encoder_path"])
    command = [
        sys.executable,
        "-m",
        "ltx_pipelines.ti2vid_one_stage",
        "--checkpoint-path",
        str(model["model_path"]),
        "--gemma-root" if text_encoder.is_dir() else "--text-encoder-path",
        str(text_encoder),
        "--prompt",
        row["prompt"],
        "--seed",
        str(row["seed"]),
        "--width",
        str(request["width"]),
        "--height",
        str(request["height"]),
        "--num-frames",
        str(request["num_frames"]),
        "--frame-rate",
        str(request["frame_rate"]),
        "--num-inference-steps",
        str(request["inference_steps"]),
        "--video-cfg-guidance-scale",
        str(request["guidance_scale"]),
        "--quantization",
        "fp8-cast",
        "--offload",
        "cpu",
        "--output-path",
        str(out / row[f"{variant}_path"]),
    ]
    if variant == "lora":
        command += ["--lora", str(checkpoint), "1.0"]
    return command


def ltx_generate(
    cfg: dict[str, Any],
    checkpoint: Path,
    request: dict[str, Any],
    rows: list[dict[str, Any]],
    out: Path,
) -> None:
    wrapper = runpy.run_path(str(Path(__file__).with_name("launch_ltx.py")))
    normalized = wrapper["validate_run_config"](cfg, wrapper["workspace_root"]())
    resolved = wrapper["resolve_hub_model"](normalized)
    model = wrapper["build_native_config"](resolved, checkpoint.parent.parent)["model"]
    wrapper["download_hub_model"](normalized)
    for row in rows:
        for variant in ("base", "lora"):
            subprocess.run(ltx_command(model, checkpoint, request, row, variant, out), check=True)


def generate(config_path: Path, trainer: str) -> int:
    request = json.loads(config_path.read_text(encoding="utf-8"))
    workspace = Path(os.environ.get("PODAGENT_WORKSPACE", "/workspace"))
    cfg, checkpoint = source_config(request, workspace)
    supported = (
        trainer == "aitoolkit" and cfg["base_model"] == "black-forest-labs/FLUX.1-dev"
    ) or (trainer == "ltx" and cfg["base_model"] == "Lightricks/LTX-2")
    if not supported:
        raise ValueError("Generation supports FLUX.1-dev with AI Toolkit and LTX-2 with LTX only")
    out = config_path.parent / "output"
    out.mkdir(exist_ok=True)
    rows = pairs(request, trainer)
    manifest = {
        **request,
        "trainer": trainer,
        "base_model": cfg["base_model"],
        "upstream_revision": AI_PIN if trainer == "aitoolkit" else LTX_PIN,
        "source_config": cfg,
        "state": "generating",
        "pairs": rows,
    }
    path = out / "comparison.json"
    path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    try:
        (flux_generate if trainer == "aitoolkit" else ltx_generate)(
            cfg, checkpoint, request, rows, out
        )
        missing = [
            row[key]
            for row in rows
            for key in ("base_path", "lora_path")
            if not (out / row[key]).is_file()
        ]
        if missing:
            raise ValueError(
                "Inference ended without the expected output files: " + ", ".join(missing)
            )
        manifest["state"] = "complete"
    except BaseException:
        manifest["state"] = "failed"
        raise
    finally:
        path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        # Provenance stays in the manifest; keep large private copies only during sampling.
        checkpoint.unlink()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--trainer", required=True, choices=("aitoolkit", "ltx"))
    args = parser.parse_args()
    try:
        return generate(args.config, args.trainer)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"generation failed: {error}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
