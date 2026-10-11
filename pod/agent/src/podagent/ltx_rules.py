"""LTX rules shared by the agent and the isolated launch wrapper: one file, two readers.

The image copies this stdlib-only file beside the agent source layout under /opt/pod, so
``scripts/launch_ltx.py`` loads the same values with runpy under ``python -I``; the agent imports
it. Two things live here:

- the preprocess allowlist. Flags follow process_dataset.py at the pinned LTX-2 commit; paths,
  device and columns belong to the wrapper and cannot be overridden through extra arguments;
- the one Hub source the wrapper prepares on its own (``base_model: Lightricks/LTX-2``), pinned
  to the commit the live run on 2026-10-10 downloaded, and the files it takes from it.
"""

from __future__ import annotations

import re
from typing import Any

# Hub model repo the wrapper downloads into <workspace>/models/ltx-2. The revision is the repo's
# main head from 2026-08-04 until at least the verified run of 2026-10-10 (22 files matched the
# patterns below, the same 22 the run fetched); moving it is a reviewable change, never a float.
LTX_HUB_MODEL = "Lightricks/LTX-2"
LTX_HUB_REVISION = "dfcc2108383fe1aaa0584bdf55d368a4bdadd90c"
LTX_HUB_CHECKPOINT = "ltx-2-19b-dev.safetensors"
LTX_HUB_FILES = (
    LTX_HUB_CHECKPOINT,
    "text_encoder/model*.safetensors",
    "text_encoder/config.json",
    "text_encoder/generation_config.json",
    "tokenizer/*",
)

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
