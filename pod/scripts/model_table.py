#!/usr/bin/env python3
"""The model table: one JSON file of supported models (docs/model-table.md).

    model_table.py [--table PATH]

Prints one line per model: id, trainer and ``model_ref``. Stdlib only, nothing heavy at import,
so ``python -I model_table.py --help`` works from any interpreter (the image build runs it).

The wrapper scripts run under ``python -I`` and cannot import siblings, so they load this file
with ``runpy.run_path`` as they load ``h3_recipe.py``; the agent loads it the same way. There is
one table file, ``app/Sources/ConceptStudio/Resources/Training/model-table.json``, which the app
bundles. The images ``COPY`` it to ``/opt/pod/scripts/model-table.json``; that file is read when
it exists, otherwise the one in the repository checkout this script sits in.

Three lookups, used consistently (docs/model-table.md, "Lookup rules"):

- ``exact_row(base_model, trainer)``: the row whose ``model_ref`` equals ``base_model``. Hooks,
  generation, GPU verification and project-profile following use it;
- ``effective_row(trainer, base_model)``: the exact row, else the trainer's default model. Defaults
  and capabilities use it;
- ``aitoolkit_model_block(base_model)``: the AI Toolkit ``model`` section, from the exact row,
  else from a family match (custom paths such as ``/workspace/models/MiniMax-H3``), else the
  name only. A family match supplies the block and nothing else.

No code outside a hook tests a model's name. A hook is a named strategy for one concern; the
row names it and ``HOOKS`` below registers every name this side knows. A row that names an
unregistered hook fails loudly in ``hook()``.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

TABLE_FORMAT = "conceptstudio-model-table"
TABLE_VERSION = 1
IMAGE_TABLE_PATH = Path("/opt/pod/scripts/model-table.json")
CHECKOUT_TABLE_PATH = (
    Path(__file__).resolve().parents[2]
    / "app/Sources/ConceptStudio/Resources/Training/model-table.json"
)

# concern -> hook name -> what implements it on the pod: a file that defines it, or None when
# the hook acts only in the app (nothing to do on the pod). Consumers keep their own dispatch
# next to the code that calls it (``launch_aitoolkit.TRAINER_CONFIG_HOOKS``,
# ``generate_results.GENERATOR_HOOKS``, ``podagent.catalog``).
HOOKS: dict[str, dict[str, str | None]] = {
    "trainer_config": {"minimax_h3": "launch_aitoolkit.py"},
    "native_recipe": {"minimax_h3": "h3_recipe.py"},
    "generator": {
        "aitoolkit_image": "generate_results.py",
        "aitoolkit_arch_image": "generate_results.py",
        "ltx_one_stage": "generate_results.py",
        "minimax_h3": "generate_results.py",
    },
    "run_extra": {"ltx_video_buckets": None},
}


def load(path: Path | None = None) -> dict[str, Any]:
    """The parsed table. Key order is the file's (``model_extra`` and ``run_extra`` rely on it)."""
    table_path = path or (IMAGE_TABLE_PATH if IMAGE_TABLE_PATH.is_file() else CHECKOUT_TABLE_PATH)
    table = json.loads(table_path.read_text(encoding="utf-8"))
    if not isinstance(table, dict) or table.get("format") != TABLE_FORMAT:
        raise ValueError(f"{table_path}: not a {TABLE_FORMAT} document")
    if table.get("version") != TABLE_VERSION:
        raise ValueError(f"{table_path}: unsupported model table version {table.get('version')!r}")
    return table


def _table(table: dict[str, Any] | None) -> dict[str, Any]:
    return table if table is not None else load()


def models(table: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """Every row, in table order (picker order, message order, family-match order)."""
    return list(_table(table)["models"])


def row_by_id(row_id: str, table: dict[str, Any] | None = None) -> dict[str, Any]:
    for row in models(table):
        if row["id"] == row_id:
            return row
    raise KeyError(f"no model table row {row_id!r}")


def exact_row(
    base_model: Any, trainer: str | None = None, table: dict[str, Any] | None = None
) -> dict[str, Any] | None:
    """The row whose ``model_ref`` is ``base_model`` (case-sensitive) on ``trainer``, else None.

    ``model_ref`` is unique across the table, so a caller that only has run.json may leave
    ``trainer`` out.
    """
    if not isinstance(base_model, str):
        return None
    for row in models(table):
        if row["model_ref"] == base_model and (trainer is None or row["trainer"] == trainer):
            return row
    return None


def trainer_default_row(trainer: str, table: dict[str, Any] | None = None) -> dict[str, Any]:
    """The row ``trainers[trainer].default_model`` names; an unknown trainer gets the table's."""
    document = _table(table)
    settings = document["trainers"].get(trainer)
    default = settings["default_model"] if settings else document["default_model"]
    return row_by_id(default, document)


def effective_row(
    trainer: str, base_model: Any, table: dict[str, Any] | None = None
) -> dict[str, Any]:
    """The exact row, else the trainer's default: a custom model behaves like that default."""
    document = _table(table)
    return exact_row(base_model, trainer, document) or trainer_default_row(trainer, document)


def _family_matches(family: dict[str, Any], lowered: str) -> bool:
    if any(substring in lowered for substring in family["substrings"]):
        return True
    return any(
        re.search(rf"(?<![a-z0-9]){re.escape(token)}(?![a-z0-9])", lowered)
        for token in family["tokens"]
    )


def family_row(base_model: str, table: dict[str, Any] | None = None) -> dict[str, Any] | None:
    """First AI Toolkit row, in table order, whose ``family_match`` matches ``base_model``."""
    lowered = base_model.lower()
    for row in models(table):
        family = row["family_match"]
        if (
            row["trainer"] == "aitoolkit"
            and family is not None
            and _family_matches(family, lowered)
        ):
            return row
    return None


def aitoolkit_model_values(row: dict[str, Any], name_or_path: str) -> dict[str, Any]:
    """AI Toolkit ``model`` keys for a row: name, arch, extras, quantize, quantize_te (if set)."""
    architecture = row["architecture"]
    values: dict[str, Any] = {"name_or_path": name_or_path}
    if architecture["arch"] is not None:
        values["arch"] = architecture["arch"]  # VERIFY: newer ai-toolkit selects by `arch`
    values.update(architecture["model_extra"])  # e.g. FLUX's legacy is_flux, for older checkouts
    values["quantize"] = architecture["quantize"]
    if architecture["quantize_text_encoder"] is not None:
        values["quantize_te"] = architecture["quantize_text_encoder"]
    return values


def aitoolkit_model_block(base_model: str, table: dict[str, Any] | None = None) -> dict[str, Any]:
    """ai-toolkit ``model`` section for a base model id or path (POD-SPEC §4.3).

    The exact AI Toolkit row, else the first family match, else ``name_or_path`` only: any other
    family needs ``extra.model.arch`` in run.json.
    """
    document = _table(table)
    row = exact_row(base_model, "aitoolkit", document) or family_row(base_model, document)
    if row is None:
        return {"name_or_path": base_model}
    return aitoolkit_model_values(row, base_model)


def hook(row: dict[str, Any], concern: str) -> str | None:
    """The row's hook for ``concern``; None for the generic behaviour. Unregistered names raise."""
    name = row["hooks"].get(concern)
    if name is not None and name not in HOOKS.get(concern, {}):
        raise ValueError(
            f"model table row {row['id']!r} names unregistered {concern} hook {name!r}"
        )
    return name


def generator_rows(table: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """Rows that support comparison generation (they name a ``generator`` hook), table order."""
    return [row for row in models(table) if hook(row, "generator") is not None]


def join_names(names: list[str]) -> str:
    """``A``, ``A and B``, ``A, B and C``."""
    if len(names) < 2:
        return "".join(names)
    return ", ".join(names[:-1]) + " and " + names[-1]


def generation_support(table: dict[str, Any] | None = None) -> str:
    """The display names of every model that supports generation, as one phrase."""
    return join_names([row["display_name"] for row in generator_rows(table)])


def frame_count_ok(row: dict[str, Any], num_frames: int) -> bool:
    """Whether ``num_frames`` is a frame count the row can generate.

    An image-only row takes one frame. A video row takes ``first + k * step`` frames (k >= 0),
    and one still frame as well when it also previews stills.
    """
    video = row["video"]
    if video is None:
        return num_frames == 1
    if row["preview"]["still"] and num_frames == 1:
        return True
    law = video["frame_law"]
    return num_frames >= law["first"] and (num_frames - law["first"]) % law["step"] == 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--table",
        type=Path,
        default=None,
        help="model table to read (default: the image or checkout table)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    for row in models(load(args.table)):
        print(f"{row['id']}\t{row['trainer']}\t{row['model_ref']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
