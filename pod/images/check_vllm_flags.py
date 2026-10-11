"""Build-time check: every flag in ``podagent.catalog.VLLM_EXTRA_FLAGS`` exists in the vLLM
installed in this image.

    /opt/venvs/agent/bin/python -I check_vllm_flags.py <vllm package directory>

The allowlist is tied to the pinned vLLM release; a flag that release removed would pass the
agent's 422 check and then kill vLLM at startup. A flag counts as present when its dashed form
(``--max-num-batched-tokens``) or its attribute form (``max_num_batched_tokens``) appears in some
``.py`` file of the package; vLLM builds most flags from config dataclass fields, so the dashed
literal is often absent while the field name is not. ``--no-X`` switches are argparse
``BooleanOptionalAction`` negations and count when ``X`` does. This is the source probe that the
2026-10-10 verification ran by hand: it found the four flags vLLM 0.31 removed (``--swap-space``,
``--max-seq-len-to-capture``, ``--disable-mm-preprocessor-cache``, ``--disable-log-requests``) in
no file at all. Standard library plus ``podagent``; exit 0 when every flag is found, 1 listing
the missing ones, 2 on usage.
"""

from __future__ import annotations

import sys
from collections.abc import Iterable
from pathlib import Path


def spellings(flag: str) -> tuple[str, ...]:
    """The strings that show ``flag`` exists: dashed and attribute forms, negation stripped."""
    name = flag.removeprefix("--")
    names = [name]
    if name.startswith("no-"):
        names.append(name.removeprefix("no-"))
    forms: list[str] = []
    for item in names:
        forms += [f"--{item}", item.replace("-", "_")]
    return tuple(forms)


def missing_flags(flags: Iterable[str], package_dir: Path) -> list[str]:
    """The flags none of whose spellings appear in any ``.py`` file under ``package_dir``."""
    remaining = {flag: spellings(flag) for flag in flags}
    for source in sorted(package_dir.rglob("*.py")):
        if not remaining:
            break
        text = source.read_text(encoding="utf-8", errors="replace")
        for flag in [flag for flag, forms in remaining.items() if any(f in text for f in forms)]:
            del remaining[flag]
    return sorted(remaining)


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1 or not Path(args[0]).is_dir():
        print("usage: check_vllm_flags.py <vllm package directory>", file=sys.stderr)
        return 2
    from podagent.catalog import VLLM_EXTRA_FLAGS

    package_dir = Path(args[0])
    sources = sum(1 for _ in package_dir.rglob("*.py"))
    missing = missing_flags(VLLM_EXTRA_FLAGS, package_dir)
    if missing:
        print(
            f"vLLM at {package_dir} has none of these allowlisted flags: {', '.join(missing)}. "
            "Remove them from VLLM_EXTRA_FLAGS in podagent/catalog.py (or pin a vLLM that has them).",
            file=sys.stderr,
        )
        return 1
    print(f"vLLM flag allowlist: {len(VLLM_EXTRA_FLAGS)} flags found in {sources} source files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
