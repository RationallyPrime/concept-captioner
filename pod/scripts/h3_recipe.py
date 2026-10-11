#!/usr/bin/env python3
"""H3 quality recipe fields and confined new-run initialization; stdlib at import time."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import struct
from pathlib import Path
from typing import Any

MODEL = "Comfy-Org/MiniMax-H3"
MODEL_REVISION = "e5eb578a89295337b8ff433a035929ce0279e0b6"
ADAPTER_REPO = "circlestone-labs/MiniMax-H3-Image-Training-Adapter"
ADAPTER_REVISION = "7c6c04f75ba597232d4ce2bb4a14709948ec723a"
INITIAL_FILES = frozenset({"initial-lora.safetensors", "initial-recipe.json"})
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
SHA_RE = re.compile(r"[0-9a-f]{64}")


def field_policy() -> dict[str, list[str]]:
    path = Path(__file__).with_name("h3-recipe-fields.json")
    if not path.is_file():
        path = (
            Path(__file__).resolve().parents[2]
            / "app/Sources/ConceptStudio/Resources/Training/h3-recipe-fields.json"
        )
    return json.loads(path.read_text(encoding="utf-8"))


ASSETS = {
    key.removeprefix("asset."): value[0]
    for key, value in field_policy().items()
    if key.startswith("asset.")
}
ADAPTER_FILE = ASSETS.pop("assistant_lora_path")


def comparison_recipe(process: dict[str, Any]) -> dict[str, Any]:
    """Quality settings for an exported result; private input/initializer paths stay private."""
    policy = field_policy()

    def selected(node: dict[str, Any], scope: str) -> dict[str, Any]:
        return {
            key: selected(value, f"{scope}.{key}") if f"{scope}.{key}" in policy else value
            for key, value in node.items()
            if key in policy[scope]
        }

    return {
        "model": selected(process["model"], "model"),
        "network": selected(process["network"], "network"),
        "train": selected(process["train"], "train"),
        "datasets": [
            {
                **selected(row, "dataset"),
                "num_frames": row["num_frames"],
                "fps": row["fps"],
                "resolution": row["resolution"],
            }
            for row in process["datasets"]
        ],
    }


def validate_recipe(raw: Any) -> dict[str, Any]:
    """Only effective quality settings cross the wire, never an old native job or its paths."""
    policy = field_policy()
    sections = {"model", "network", "train", "dataset"}
    if not isinstance(raw, dict) or set(raw) != sections:
        raise ValueError("Initial recipe must contain exactly model, network, train and dataset")

    def check(node: Any, scope: str) -> None:
        if not isinstance(node, dict):
            raise ValueError(f"Initial recipe {scope} must be an object")
        unknown = set(node) - set(policy[scope])
        if unknown:
            raise ValueError(f"Initial recipe {scope}: unsupported fields {sorted(unknown)}")
        for key, value in node.items():
            child = f"{scope}.{key}"
            if child in policy:
                check(value, child)
            elif isinstance(value, dict):
                raise ValueError(f"Initial recipe {child} must not contain nested settings")

    for section in sections:
        check(raw[section], section)
    model = raw["model"]
    if model.get("name_or_path") != MODEL or model.get("arch") != "minimax_h3":
        raise ValueError("Initial recipe must use Comfy-Org/MiniMax-H3 with arch minimax_h3")
    if model.get("model_kwargs", {}).get("partition", "fl2va_pruned") != "fl2va_pruned":
        raise ValueError("Initial recipe currently supports the fl2va_pruned H3 partition")
    if "use_training_adapter" in model and type(model["use_training_adapter"]) is not bool:
        raise ValueError("use_training_adapter must be a boolean")
    network = raw["network"]
    if network.get("type", "lora") != "lora":
        raise ValueError("Initial H3 weights must be a LoRA network")
    for key in ("linear", "linear_alpha"):
        if type(network.get(key)) is not int or network[key] < 1:
            raise ValueError(f"Initial recipe network.{key} must be a positive integer")
    for key, value in network.get("network_kwargs", {}).items():
        if not isinstance(value, list) or not all(isinstance(v, str) and v for v in value):
            raise ValueError(f"Initial recipe network.network_kwargs.{key} must be strings")
    # Reject non-finite JSON values before either native config writer sees them.
    json.dumps(raw, allow_nan=False)
    return raw


def validate_initialization(value: Any) -> dict[str, str] | None:
    if value is None:
        return None
    if not isinstance(value, dict) or set(value) != {"name", "lora_sha256", "recipe_sha256"}:
        raise ValueError("initialization needs name, lora_sha256 and recipe_sha256")
    if not isinstance(value["name"], str) or not NAME_RE.fullmatch(value["name"]):
        raise ValueError("Invalid initialization stage name")
    if any(
        not isinstance(value[key], str) or not SHA_RE.fullmatch(value[key])
        for key in ("lora_sha256", "recipe_sha256")
    ):
        raise ValueError("Initialization checksums must be lowercase SHA256")
    return value


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def validate_weights(path: Path, rank: int, network_kwargs: dict[str, Any] | None = None) -> None:
    """Read only the safetensors header; a malformed/non-H3 adapter never starts training."""
    with path.open("rb") as stream:
        prefix = stream.read(8)
        length = struct.unpack("<Q", prefix)[0] if len(prefix) == 8 else 0
        if not 0 < length <= 16 * 1024 * 1024:
            raise ValueError("Initial weights have no valid safetensors header")
        header = json.loads(stream.read(length))
    if not isinstance(header, dict):
        raise ValueError("Initial weights have no valid safetensors header")
    tensors = {k: v for k, v in header.items() if k != "__metadata__"}
    # H3 exports Comfy's diffusion_model.<module>.lora_A/B PEFT names. The pinned
    # BaseModel converts diffusion_model -> transformer; ToolkitNetworkMixin maps A/B.
    down = {
        k.removesuffix(".lora_A.weight"): v
        for k, v in tensors.items()
        if k.startswith(("diffusion_model.", "transformer.")) and k.endswith(".lora_A.weight")
    }
    up = {
        k.removesuffix(".lora_B.weight"): v
        for k, v in tensors.items()
        if k.startswith(("diffusion_model.", "transformer.")) and k.endswith(".lora_B.weight")
    }
    if (
        not down
        or down.keys() != up.keys()
        or any(
            not isinstance(v, dict)
            or not isinstance(v.get("shape"), list)
            or len(v["shape"]) != 2
            or v["shape"][0] != rank
            for v in down.values()
        )
        or any(
            not isinstance(v, dict)
            or not isinstance(v.get("shape"), list)
            or len(v["shape"]) != 2
            or v["shape"][1] != rank
            for v in up.values()
        )
    ):
        raise ValueError("Initial H3 LoRA rank must match the requested rank and native recipe")
    selectors = network_kwargs or {}
    for key in down:
        module = key.split(".", 1)[1]
        only = selectors.get("only_if_contains")
        ignored = selectors.get("ignore_if_contains", [])
        if (only is not None and not any(word in module for word in only)) or any(
            word in module for word in ignored
        ):
            raise ValueError(
                "Initial weights contain a module excluded by the imported network recipe"
            )
    available = path.stat().st_size - 8 - length
    for tensor in tensors.values():
        offsets = tensor.get("data_offsets") if isinstance(tensor, dict) else None
        if (
            not isinstance(offsets, list)
            or len(offsets) != 2
            or any(type(v) is not int for v in offsets)
            or not 0 <= offsets[0] <= offsets[1] <= available
        ):
            raise ValueError("Initial weights contain invalid tensor offsets")


def read_initialization(folder: Path, value: dict[str, str], rank: int) -> dict[str, Any]:
    for name, key in (
        ("initial-lora.safetensors", "lora_sha256"),
        ("initial-recipe.json", "recipe_sha256"),
    ):
        path = folder / name
        if path.is_symlink() or not path.is_file() or sha256(path) != value[key]:
            raise ValueError(f"Initialization {name} is unavailable or its checksum changed")
    recipe = validate_recipe(json.loads((folder / "initial-recipe.json").read_text()))
    if recipe["network"]["linear"] != rank:
        raise ValueError("Requested rank must match the imported initial LoRA recipe")
    validate_weights(
        folder / "initial-lora.safetensors", rank, recipe["network"].get("network_kwargs")
    )
    return recipe


def model_config(workspace: Path, *, training_adapter: bool = True) -> dict[str, Any]:
    root = workspace / "models/h3-bf16-quality"
    config = {
        "name_or_path": MODEL,
        "arch": "minimax_h3",
        "quantize": False,
        "quantize_te": False,
        "low_vram": False,
        "te_name_or_path": str(root / ASSETS["text_encoder_path"]),
        "model_kwargs": {
            "partition": "fl2va_pruned",
            **{key: str(root / file) for key, file in ASSETS.items()},
        },
    }
    if training_adapter:
        config["assistant_lora_path"] = str(root / ADAPTER_FILE)
    return config


def quality_settings(*, video: bool = False) -> dict[str, Any]:
    """Concrete BF16 image recipe; clip inputs add joint audio without a hidden frame change."""
    return {
        "model": {
            "name_or_path": MODEL,
            "arch": "minimax_h3",
            "quantize": False,
            "quantize_te": False,
            "low_vram": False,
            "use_training_adapter": True,
            "model_kwargs": {"partition": "fl2va_pruned"},
        },
        "network": {
            "type": "lora",
            "transformer_only": True,
            "network_kwargs": {
                "only_if_contains": [
                    f"blocks.{block}.{module}"
                    for block in range(20, 50)
                    for module in ("attn.qkv_proj", "attn.out_proj", "mlp.fc1", "mlp.fc2")
                ]
            },
        },
        "train": {
            "dtype": "bf16",
            "optimizer": "adamw",
            "noise_scheduler": "flowmatch",
            "timestep_type": "sigmoid",
            "optimizer_params": {"weight_decay": 0.01},
            "lr_scheduler": "constant_with_warmup",
            "lr_scheduler_params": {"num_warmup_steps": 35},
            "gradient_checkpointing": True,
            "train_unet": True,
            "train_text_encoder": False,
            "cache_text_embeddings": True,
            "skip_first_sample": True,
            "force_first_sample": False,
            "audio_loss_multiplier": 1.0 if video else 0.0,
            "ema_config": {"use_ema": False},
        },
        "dataset": {
            "caption_dropout_rate": 0.0,
            "shuffle_tokens": False,
            "cache_latents_to_disk": True,
            "cache_text_embeddings": True,
            "num_workers": 2,
            "pin_memory": True,
            "num_repeats": 1,
        },
    }


def download_assets(workspace: Path, *, training_adapter: bool = True) -> None:
    # Pinned controlled destinations. No old pod path or client-supplied download location.
    from huggingface_hub import hf_hub_download

    root = workspace / "models/h3-bf16-quality"
    for filename in ASSETS.values():
        hf_hub_download(
            repo_id=MODEL,
            filename=filename,
            revision=MODEL_REVISION,
            local_dir=str(root),
            token=os.environ.get("HF_TOKEN") or None,
        )
    if training_adapter:
        hf_hub_download(
            repo_id=ADAPTER_REPO,
            filename=ADAPTER_FILE,
            revision=ADAPTER_REVISION,
            local_dir=str(root),
            token=os.environ.get("HF_TOKEN") or None,
        )


if __name__ == "__main__":
    argparse.ArgumentParser(description=__doc__).parse_args()
