"""LTX preprocessing options shared by the agent and the isolated launch wrapper.

The image copies this stdlib-only file beside the agent source layout under /opt/pod,
so launch_ltx.py can load the same rules with runpy under ``python -I``.
Flags follow process_dataset.py at the pinned LTX-2 commit; paths, device and columns
belong to the wrapper and cannot be overridden through extra arguments.
"""

from __future__ import annotations

import re
from typing import Any

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


def preprocess_options(options: Any, size: int) -> tuple[str, list[str]]:
    """Return the bucket and allowlisted args, or reject before any subprocess starts."""
    bucket = f"{size}x{size}x1"
    if options is None:
        return bucket, []
    if not isinstance(options, dict):
        raise ValueError("extra.preprocess: must be an object")
    unknown = sorted(set(options) - {"resolution_buckets", "args"})
    if unknown:
        raise ValueError("extra.preprocess: unknown keys: " + ", ".join(unknown))
    override = options.get("resolution_buckets")
    if override is not None:
        if not isinstance(override, str) or not BUCKET_RE.fullmatch(override):
            raise ValueError("extra.preprocess.resolution_buckets: must look like WxHxF[;WxHxF]")
        bucket = override
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
    return bucket, list(args)
