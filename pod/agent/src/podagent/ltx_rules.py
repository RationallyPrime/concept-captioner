"""LTX rules shared by the agent and the isolated launch wrapper: one file, two readers.

The image copies this stdlib-only file beside the agent source layout under /opt/pod, so
``scripts/launch_ltx.py`` loads the same values with runpy under ``python -I``; the agent imports
it. Two things live here:

- the preprocess allowlist. Flags follow process_dataset.py at the pinned LTX-2 commit; paths,
  device and columns belong to the wrapper and cannot be overridden through extra arguments;
- the Hub sources the wrapper prepares on its own (``base_model`` naming one of
  ``LTX_HUB_SOURCES``), each pinned to a revision, and the files it takes from each.
"""

from __future__ import annotations

import re
from typing import Any

# Hub sources the wrapper downloads into <workspace>/models/<dir>. Every revision is pinned;
# moving one is a reviewable change, never a float. ``downloads`` lists (repo, revision, file
# patterns) fetched into that one directory; ``model`` names the trainer's model paths relative
# to it ("." is the directory itself, the Gemma root of a unified checkpoint).
#
# - LTX-2.3: unified checkpoint. Its repo carries no text encoder; LTX-2.3 uses the same Gemma 3
#   as LTX-2, so the Gemma root comes from the LTX-2 repo's mirror at the revision the verified
#   LTX-2 run of 2026-10-10 downloaded.
# - LTX-2.5: split layout, one file per component; Gemma 4 packed with its tokenizer and the
#   text projections. The repo is gated (licence accepted on the Hub, then a token).
# - LTX-2: kept so runs started on it still resume and generate; no longer offered by the app.
_LTX2_REVISION = "dfcc2108383fe1aaa0584bdf55d368a4bdadd90c"
_GEMMA3_FILES = (
    "text_encoder/model*.safetensors",
    "text_encoder/config.json",
    "text_encoder/generation_config.json",
    "tokenizer/*",
)
LTX_HUB_SOURCES: dict[str, dict[str, Any]] = {
    "Lightricks/LTX-2.3": {
        "dir": "ltx-2.3",
        "downloads": (
            (
                "Lightricks/LTX-2.3",
                "3c6a4e66e5d0a684231950b9c74dd4ded7b6fadc",
                ("ltx-2.3-22b-dev.safetensors",),
            ),
            ("Lightricks/LTX-2", _LTX2_REVISION, _GEMMA3_FILES),
        ),
        "model": {"model_path": "ltx-2.3-22b-dev.safetensors", "text_encoder_path": "."},
    },
    "Lightricks/LTX-2.5": {
        "dir": "ltx-2.5",
        "downloads": (
            (
                "Lightricks/LTX-2.5",
                "49b093a39c19169a8a81721dcc541e07e945232f",
                (
                    "diffusion_models/ltx-2.5-22b-dev-transformer-bf16.safetensors",
                    "text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors",
                    "vae/ltx-2.5-video-vae-bf16.safetensors",
                    "vae/ltx-2.5-audio-vae-bf16.safetensors",
                ),
            ),
        ),
        "model": {
            "model_path": "diffusion_models/ltx-2.5-22b-dev-transformer-bf16.safetensors",
            "text_encoder_path": "text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors",
            "video_vae_path": "vae/ltx-2.5-video-vae-bf16.safetensors",
            "audio_vae_path": "vae/ltx-2.5-audio-vae-bf16.safetensors",
        },
    },
    "Lightricks/LTX-2": {
        "dir": "ltx-2",
        "downloads": (
            (
                "Lightricks/LTX-2",
                _LTX2_REVISION,
                ("ltx-2-19b-dev.safetensors", *_GEMMA3_FILES),
            ),
        ),
        "model": {"model_path": "ltx-2-19b-dev.safetensors", "text_encoder_path": "."},
    },
}

BUCKET_RE = re.compile(r"\d+x\d+x\d+(?:;\d+x\d+x\d+)*")
PREPROCESS_SWITCHES = frozenset(
    {
        "--vae-tiling",
        "--decode",
        "--remove-llm-prefixes",
        "--skip-audio",
        "--load-text-encoder-in-8bit",
        "--overwrite",
    }
)
PREPROCESS_INTEGERS = {
    "--batch-size": (1, 64),
    "--reference-downscale-factor": (1, 64),
    "--reference-temporal-scale-factor": (1, 64),
}


def check_preprocess(options: Any) -> tuple[str | None, list[str]]:
    """``(bucket override or None, allowlisted args)``; ``ValueError`` for anything else."""
    if options is None:
        return None, []
    if not isinstance(options, dict):
        raise ValueError("extra.preprocess: must be an object")
    unknown = sorted(set(options) - {"resolution_buckets", "buckets_from_media", "args"})
    if unknown:
        raise ValueError("extra.preprocess: unknown keys: " + ", ".join(unknown))
    override = options.get("resolution_buckets")
    from_media = options.get("buckets_from_media", False)
    if not isinstance(from_media, bool):
        raise ValueError("extra.preprocess.buckets_from_media: must be a boolean")
    if from_media and override is not None:
        raise ValueError(
            "extra.preprocess: choose buckets_from_media or resolution_buckets, not both"
        )
    if override is not None and (
        not isinstance(override, str) or not BUCKET_RE.fullmatch(override)
    ):
        raise ValueError("extra.preprocess.resolution_buckets: must look like WxHxF[;WxHxF]")
    args = options.get("args", [])
    if not isinstance(args, list) or not all(isinstance(arg, str) for arg in args):
        raise ValueError("extra.preprocess.args: must be a list of strings")
    seen: set[str] = set()
    for arg in args:
        flag, separator, value = arg.partition("=")
        if flag in seen:
            raise ValueError(f"extra.preprocess.args: repeats {flag}")
        seen.add(flag)
        if flag in PREPROCESS_SWITCHES:
            if separator:
                raise ValueError(f"extra.preprocess.args: {flag} takes no value")
        elif flag in PREPROCESS_INTEGERS:
            low, high = PREPROCESS_INTEGERS[flag]
            if not separator or not re.fullmatch(r"[0-9]{1,3}", value):
                raise ValueError(f"extra.preprocess.args: {flag} needs an integer value")
            if not low <= int(value) <= high:
                raise ValueError(f"extra.preprocess.args: {flag} must be between {low} and {high}")
        else:
            raise ValueError(f"extra.preprocess.args: {flag} is not an allowed preprocess flag")
    return override, list(args)


def preprocess_options(options: Any, size: int) -> tuple[str, list[str]]:
    """Return the bucket and allowlisted args, or reject before any subprocess starts."""
    override, args = check_preprocess(options)
    return override if override is not None else f"{size}x{size}x1", args
