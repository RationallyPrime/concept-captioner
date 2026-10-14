#!/usr/bin/env python3
"""Generate real, matched base/LoRA pairs through the pinned trainer's inference code.

The agent writes generation.json after validating the source checkpoint. Outputs and the
incremental comparison.json manifest live in this generation run's output directory, so
the existing authenticated files/download endpoints serve them. No listener is added.
Which models can be compared, and how, comes from the model table (model_table.py): a row
names a generator hook. ``aitoolkit_image`` uses ai-toolkit's StableDiffusion/GenerateImageConfig
with the row's model settings (FLUX is one such row); ``aitoolkit_arch_image`` uses the model class
ai-toolkit registers for the row's ``arch`` with the trained LoRA bound as a network (Z-Image is one
such row); ``minimax_h3`` uses H3's registered model and the trained LoRASpecialNetwork recipe;
``ltx_one_stage`` uses LTX's official one-stage CLI.
Heavy imports happen only at execution.
"""

from __future__ import annotations

import argparse
import gc
import hashlib
import json
import os
import re
import runpy
import signal
import subprocess
import sys
from pathlib import Path
from typing import Any

AI_PIN = "f7a1fb9a77e5418269b1e9eda4ace6d7c1b7bb47"
LTX_PIN = "9ec55f9f22798a3198d9c923856824821bc3317e"

# Generator hook name -> (function that renders the pairs, function that adds the hook's fields to
# the manifest or None). Names, not functions: they are looked up in this module's globals when
# a request runs. ``model_table.HOOKS["generator"]`` registers the same names.
GENERATOR_HOOKS: dict[str, tuple[str, str | None]] = {
    "aitoolkit_image": ("flux_generate", None),
    "aitoolkit_arch_image": ("arch_generate", None),
    "ltx_one_stage": ("ltx_generate", None),
    "minimax_h3": ("h3_generate", "h3_manifest"),
}


def model_table() -> dict[str, Any]:
    """``model_table.py``'s namespace: the scripts run under ``python -I``, so no sibling import."""
    return runpy.run_path(str(Path(__file__).with_name("model_table.py")))


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
    ext = "png" if trainer == "aitoolkit" and request.get("num_frames", 1) == 1 else "mp4"
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
    """The ``aitoolkit_image`` generator: still images through ai-toolkit's own primitives.

    The model settings (arch, extra model keys, quantisation, precision) come from the model
    table row for the source run's base model; for FLUX that is the call this function always made.
    """
    # Public source: toolkit/stable_diffusion_model.py load_model (fuses model.lora_path
    # before quantization), generate_images; config_modules.py GenerateImageConfig. The
    # built-in GenerateProcess has an invalid self.train_config fallback for legacy FLUX,
    # so call these same concrete primitives with the explicit flowmatch scheduler.
    import torch

    sys.path.insert(0, os.environ.get("AI_TOOLKIT_DIR", "/opt/ai-toolkit"))
    from toolkit.config_modules import GenerateImageConfig, ModelConfig
    from toolkit.sampler import get_sampler
    from toolkit.stable_diffusion_model import StableDiffusion

    table = model_table()
    spec = table["exact_row"](cfg["base_model"], "aitoolkit")
    architecture = spec["architecture"]
    for variant in ("base", "lora"):
        model = ModelConfig(
            **table["aitoolkit_model_values"](spec, cfg["base_model"]),
            dtype=architecture["dtype"],
            lora_path=str(checkpoint) if variant == "lora" else None,
        )
        sd = StableDiffusion(
            device="cuda:0",
            model_config=model,
            dtype=architecture["dtype"],
            noise_scheduler=get_sampler("flowmatch", arch=architecture["arch"]),
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


def bind_h3_network(sd: Any, network_config: Any, checkpoint: Path, torch: Any) -> Any:
    """The concrete pinned BaseSDTrainProcess construction, without optimizer/training state."""
    from toolkit.lora_special import LoRASpecialNetwork

    target = sd.get_model_to_train()
    network = LoRASpecialNetwork(
        text_encoder=None,
        unet=target,
        lora_dim=network_config.linear,
        multiplier=1.0,
        alpha=network_config.linear_alpha,
        train_unet=True,
        train_text_encoder=False,
        conv_lora_dim=network_config.conv,
        conv_alpha=network_config.conv_alpha,
        dropout=network_config.dropout,
        network_config=network_config,
        network_type=network_config.type,
        transformer_only=network_config.transformer_only,
        is_transformer=sd.is_transformer,
        base_model=sd,
        **{**network_config.network_kwargs, "target_lin_modules": sd.target_lora_modules},
    )
    network.force_to(sd.device_torch, dtype=torch.float32)
    sd.network = network
    network._update_torch_multiplier()
    network.apply_to(None, target, False, True)
    # Use the live network for both arms; do not fuse changing model weights between arms.
    # load_weights uses base_model_ref to convert H3's Comfy diffusion_model + A/B keys.
    network.can_merge_in = False
    network.load_weights(str(checkpoint))
    network.eval()
    return network


def h3_generate(
    cfg: dict[str, Any],
    checkpoint: Path,
    request: dict[str, Any],
    rows: list[dict[str, Any]],
    out: Path,
) -> None:
    import torch

    sys.path.insert(0, os.environ.get("AI_TOOLKIT_DIR", "/opt/ai-toolkit"))
    from toolkit.config_modules import GenerateImageConfig, ModelConfig, NetworkConfig
    from toolkit.util.get_model import get_model_class

    native = json.loads((checkpoint.parent / "source-native-config.json").read_text())
    process = native["config"]["process"][0]
    model_values = process["model"].copy()
    if model_values.get("arch") != "minimax_h3" or process["network"].get("type") != "lora":
        raise ValueError("H3 comparison requires the trained minimax_h3 LoRA recipe")
    # The frozen image-training adapter is disabled by upstream previews. Omit it entirely
    # here on both sides; it is never the trained adapter or a base-only hidden addition.
    for key in ("assistant_lora_path", "inference_lora_path", "lora_path"):
        model_values.pop(key, None)
    rules = runpy.run_path(str(Path(__file__).with_name("h3_recipe.py")))
    rules["download_assets"](
        Path(os.environ.get("PODAGENT_WORKSPACE", "/workspace")), training_adapter=False
    )
    model = ModelConfig(**model_values)
    cls = get_model_class(model)
    sd = cls(
        device="cuda:0",
        model_config=model,
        dtype=process["train"].get("dtype", "bf16"),
        noise_scheduler=cls.get_train_scheduler(),
    )
    try:
        with torch.no_grad():
            sd.load_model()
            network_values = process["network"].copy()
            network_values.pop("pretrained_lora_path", None)
            bind_h3_network(sd, NetworkConfig(**network_values), checkpoint, torch)
            for variant, multiplier in (("base", 0.0), ("lora", 1.0)):
                configs = [
                    GenerateImageConfig(
                        prompt=row["prompt"],
                        seed=row["seed"],
                        width=request["width"],
                        height=request["height"],
                        num_inference_steps=request["inference_steps"],
                        guidance_scale=request["guidance_scale"],
                        num_frames=request["num_frames"],
                        fps=24,
                        network_multiplier=multiplier,
                        output_path=str(out / row[f"{variant}_path"]),
                        output_ext="png" if request["num_frames"] == 1 else "mp4",
                    )
                    for row in rows
                ]
                sd.generate_images(configs, sampler="flowmatch")
    finally:
        del sd
        gc.collect()
        torch.cuda.empty_cache()


def h3_manifest(checkpoint: Path, manifest: dict[str, Any]) -> None:
    """The ``minimax_h3`` generator's manifest fields: the recipe actually trained, minus paths."""
    captured = json.loads((checkpoint.parent / "source-native-config.json").read_text())
    rules = runpy.run_path(str(Path(__file__).with_name("h3_recipe.py")))
    manifest["effective_native_config"] = rules["comparison_recipe"](
        captured["config"]["process"][0]
    )
    manifest["comparison_training_adapter"] = False


def arch_generate(
    cfg: dict[str, Any],
    checkpoint: Path,
    request: dict[str, Any],
    rows: list[dict[str, Any]],
    out: Path,
) -> None:
    """The ``aitoolkit_arch_image`` generator: stills from the model class registered for ``arch``.

    ``aitoolkit_image`` builds the legacy ``StableDiffusion`` class, which only serves the older
    architectures (FLUX among them). A newer architecture such as Z-Image is its own ``BaseModel``
    subclass and takes the trained LoRA as a network, the way the trainer's previews do. So the
    model and the network are rebuilt from the source run's captured native config (the
    ``model`` and ``network`` blocks the trainer ran with), the base side renders with the network
    at multiplier 0 and the trained side at 1: one model load, the same weights, prompts and seeds.
    """
    import torch

    sys.path.insert(0, os.environ.get("AI_TOOLKIT_DIR", "/opt/ai-toolkit"))
    from toolkit.config_modules import GenerateImageConfig, ModelConfig, NetworkConfig
    from toolkit.util.get_model import get_model_class

    native = json.loads((checkpoint.parent / "source-native-config.json").read_text())
    process = native["config"]["process"][0]
    if process["network"].get("type") != "lora":
        raise ValueError("Comparison requires a trained LoRA network")
    model = ModelConfig(**process["model"])
    cls = get_model_class(model)
    sd = cls(
        device="cuda:0",
        model_config=model,
        dtype=process["train"].get("dtype", "bf16"),
        noise_scheduler=cls.get_train_scheduler(),
    )
    try:
        with torch.no_grad():
            sd.load_model()
            network_values = process["network"].copy()
            network_values.pop("pretrained_lora_path", None)
            # H3 in name only: this is the trainer's own network construction for any
            # BaseModel architecture, applied here without optimizer or training state.
            bind_h3_network(sd, NetworkConfig(**network_values), checkpoint, torch)
            for variant, multiplier in (("base", 0.0), ("lora", 1.0)):
                configs = [
                    GenerateImageConfig(
                        prompt=row["prompt"],
                        seed=row["seed"],
                        width=request["width"],
                        height=request["height"],
                        num_inference_steps=request["inference_steps"],
                        guidance_scale=request["guidance_scale"],
                        network_multiplier=multiplier,
                        output_path=str(out / row[f"{variant}_path"]),
                        output_ext="png",
                    )
                    for row in rows
                ]
                sd.generate_images(configs, sampler="flowmatch")
    finally:
        del sd
        gc.collect()
        torch.cuda.empty_cache()


def ltx_generate(
    cfg: dict[str, Any],
    checkpoint: Path,
    request: dict[str, Any],
    rows: list[dict[str, Any]],
    out: Path,
) -> None:
    wrapper = runpy.run_path(str(Path(__file__).with_name("launch_ltx.py")))
    # Inference needs the captured model/config/weights, not the source training images.
    # Completed dataset copies may already have been reclaimed by retention.
    normalized = wrapper["validate_run_config"](
        cfg, wrapper["workspace_root"](), allow_missing_dataset=True
    )
    resolved = wrapper["resolve_hub_model"](normalized)
    model = wrapper["build_native_config"](resolved, checkpoint.parent.parent)["model"]
    wrapper["download_hub_model"](normalized)
    for row in rows:
        for variant in ("base", "lora"):
            subprocess.run(ltx_command(model, checkpoint, request, row, variant, out), check=True)


def _stopped(_signum: int, _frame: Any) -> None:
    raise InterruptedError("generation stopped by SIGTERM")


def check_frames(table: dict[str, Any], spec: dict[str, Any], request: dict[str, Any]) -> None:
    """The row's frame law and cadence, the same rules the agent applies before a run starts.

    An image-only row takes one frame; a video row takes ``first + k * step`` frames (and one
    still when it previews stills); a row with a fixed cadence takes exactly that frame rate.
    """
    video = spec["video"]
    fps = video["fixed_fps"] if video is not None else None
    if table["frame_count_ok"](spec, request["num_frames"]) and (
        fps is None or request["frame_rate"] == fps
    ):
        return
    short = spec["short_name"]
    if video is None:
        raise ValueError(f"{short} comparison produces images; num_frames must be 1")
    law = video["frame_law"]
    stills = "1 or " if spec["preview"]["still"] else ""
    cadence = f" at exactly {fps} fps" if fps is not None else ""
    raise ValueError(
        f"{short} comparison needs {stills}{law['step']}n+{law['first']} frames{cadence}"
    )


def generate(config_path: Path, trainer: str) -> int:
    # Own the private copy before reading either config: validation can fail before inference.
    checkpoint = config_path.parent / "selected-checkpoint.safetensors"
    manifest: dict[str, Any] | None = None
    path = config_path.parent / "output" / "comparison.json"
    previous_handler = signal.signal(signal.SIGTERM, _stopped)
    try:
        request = json.loads(config_path.read_text(encoding="utf-8"))
        workspace = Path(os.environ.get("PODAGENT_WORKSPACE", "/workspace"))
        cfg, checkpoint = source_config(request, workspace)
        table = model_table()
        spec = table["exact_row"](cfg["base_model"], trainer)
        hook = table["hook"](spec, "generator") if spec is not None else None
        if spec is None or hook is None:
            raise ValueError(f"Generation supports {table['generation_support']()}")
        check_frames(table, spec, request)
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
        render, add_to_manifest = GENERATOR_HOOKS[hook]
        if add_to_manifest is not None:
            globals()[add_to_manifest](checkpoint, manifest)
        path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        globals()[render](cfg, checkpoint, request, rows, out)
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
        return 0
    except BaseException:
        if manifest is not None:
            manifest["state"] = "failed"
        raise
    finally:
        try:
            if manifest is not None:
                path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        finally:
            try:
                # The source checkpoint and available outputs remain. SIGKILL cannot run this.
                checkpoint.unlink(missing_ok=True)
            finally:
                signal.signal(signal.SIGTERM, previous_handler)


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
