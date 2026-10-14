#!/usr/bin/env python3
"""Upload a trained LoRA (+ samples, run.json, config.yaml, model card) to a model repo (POD-SPEC §7.2).

Usage:
  push_lora.py --run-dir DIR --repo ID [--private] [--no-samples] [--all-checkpoints]
               [--commit-message M]

What goes up, as ``upload_folder`` allow-patterns relative to DIR:

- the newest ``*.safetensors`` under DIR (by mtime; ``preprocessed/`` and dot-folders are not
  searched), or every one of them with ``--all-checkpoints``. None found: exit 1 and nothing is
  created on the Hub;
- ``run.json`` and ``config.yaml`` when present;
- every file under a ``samples`` folder (``DIR/samples`` or ``DIR/output/*/samples``) unless
  ``--no-samples``;
- ``README.md``: a model card generated from ``run.json`` (base model, triggers, steps, rank,
  profile, dataset name, the installed concept-captioner version). It overwrites
  ``DIR/README.md`` and, on the Hub, the repo's README. When the base model's row in the model
  table has ``license.show_notice``, the card also carries the licence in its front matter and a
  closing ``## Licence`` section.

The repo is created when missing (``create_repo(exist_ok=True)``; ``--private`` applies to that
creation). Prints the repo URL and writes ``DIR/push.json`` (repo, url, commit, files). Token
from ``HF_TOKEN``. Heavy imports happen inside ``main`` so ``python -I push_lora.py --help``
needs nothing beyond the standard library.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import runpy
import sys
from datetime import UTC, datetime
from importlib import metadata
from pathlib import Path
from typing import Any

SKIPPED_DIRS = frozenset({"preprocessed"})
SIDE_FILES = ("run.json", "config.yaml")
SAMPLE_PATTERNS = ("samples/*", "*/samples/*")
CARD_NAME = "README.md"
RECEIPT_NAME = "push.json"
# The Hub's licence identifiers (https://huggingface.co/docs/hub/en/repositories-licenses). A row
# whose ``license.id`` is one of them goes into the card as ``license: <id>``; any other id is a
# custom licence: ``license: other``, with the id as ``license_name`` and the url as
# ``license_link``.
HUB_LICENSES = frozenset(
    {
        "apache-2.0",
        "mit",
        "openrail",
        "bigscience-openrail-m",
        "creativeml-openrail-m",
        "bigscience-bloom-rail-1.0",
        "bigcode-openrail-m",
        "afl-3.0",
        "artistic-2.0",
        "bsl-1.0",
        "bsd",
        "bsd-2-clause",
        "bsd-3-clause",
        "bsd-3-clause-clear",
        "c-uda",
        "cc",
        "cc0-1.0",
        "cc-by-2.0",
        "cc-by-2.5",
        "cc-by-3.0",
        "cc-by-4.0",
        "cc-by-sa-3.0",
        "cc-by-sa-4.0",
        "cc-by-nc-2.0",
        "cc-by-nc-3.0",
        "cc-by-nc-4.0",
        "cc-by-nd-4.0",
        "cc-by-nc-nd-3.0",
        "cc-by-nc-nd-4.0",
        "cc-by-nc-sa-2.0",
        "cc-by-nc-sa-3.0",
        "cc-by-nc-sa-4.0",
        "cdla-sharing-1.0",
        "cdla-permissive-1.0",
        "cdla-permissive-2.0",
        "wtfpl",
        "ecl-2.0",
        "epl-1.0",
        "epl-2.0",
        "etalab-2.0",
        "eupl-1.1",
        "eupl-1.2",
        "agpl-3.0",
        "gfdl",
        "gpl",
        "gpl-2.0",
        "gpl-3.0",
        "lgpl",
        "lgpl-2.1",
        "lgpl-3.0",
        "isc",
        "h-research",
        "intel-research",
        "lppl-1.3c",
        "ms-pl",
        "apple-ascl",
        "apple-amlr",
        "mpl-2.0",
        "odc-by",
        "odbl",
        "openmdw-1.0",
        "openmdw-1.1",
        "openrail++",
        "osl-3.0",
        "postgresql",
        "ofl-1.1",
        "ncsa",
        "unlicense",
        "zlib",
        "pddl",
        "lgpl-lr",
        "deepfloyd-if-license",
        "fair-noncommercial-research-license",
        "llama2",
        "llama3",
        "llama3.1",
        "llama3.2",
        "llama3.3",
        "llama4",
        "grok2-community",
        "gemma",
        "unknown",
        "other",
    }
)


# --- file selection -----------------------------------------------------------------------------


def _skipped(run_dir: Path, path: Path) -> bool:
    parts = path.relative_to(run_dir).parts[:-1]
    return any(part.startswith(".") or part in SKIPPED_DIRS for part in parts)


def relative(run_dir: Path, path: Path) -> str:
    return path.relative_to(run_dir).as_posix()


def find_weights(run_dir: Path) -> list[Path]:
    """Every ``*.safetensors`` under ``run_dir``, oldest first (mtime, then path)."""
    found = [
        path
        for path in run_dir.rglob("*.safetensors")
        if path.is_file() and not _skipped(run_dir, path)
    ]
    return sorted(found, key=lambda p: (p.stat().st_mtime_ns, relative(run_dir, p)))


def select_weights(run_dir: Path, *, all_checkpoints: bool) -> list[Path]:
    found = find_weights(run_dir)
    if not found or all_checkpoints:
        return found
    return [found[-1]]


def sample_files(run_dir: Path) -> list[Path]:
    """Files under any ``samples`` folder that the ``SAMPLE_PATTERNS`` would upload."""
    files: list[Path] = []
    for folder in sorted(run_dir.rglob("samples")):
        if folder.is_dir() and not _skipped(run_dir, folder):
            files.extend(p for p in sorted(folder.rglob("*")) if p.is_file())
    return files


def escape_pattern(name: str) -> str:
    """A literal path as an fnmatch pattern."""
    return name.replace("[", "[[]").replace("*", "[*]").replace("?", "[?]")


def allow_patterns(run_dir: Path, *, weights: list[Path], include_samples: bool) -> list[str]:
    patterns = [escape_pattern(relative(run_dir, weight)) for weight in weights]
    patterns.extend(name for name in SIDE_FILES if (run_dir / name).is_file())
    if include_samples:
        patterns.extend(SAMPLE_PATTERNS)
    patterns.append(CARD_NAME)
    return patterns


# --- model card ---------------------------------------------------------------------------------


def concept_captioner_version() -> str:
    try:
        return metadata.version("concept-captioner")
    except metadata.PackageNotFoundError:
        return "unknown"


def load_run(run_dir: Path) -> dict[str, Any]:
    path = run_dir / "run.json"
    if not path.is_file():
        return {}
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(
            f"push_lora: {path} is not valid JSON ({exc}); the model card will be sparse",
            file=sys.stderr,
        )
        return {}
    return loaded if isinstance(loaded, dict) else {}


def dataset_info(run: dict[str, Any]) -> dict[str, Any]:
    """Name, manifest and job.yaml profile of the dataset the run trained on, when readable."""
    dataset = run.get("dataset") if isinstance(run.get("dataset"), dict) else {}
    info: dict[str, Any] = {"name": None, "manifest": None, "profile": None}
    raw = dataset.get("path")
    if not isinstance(raw, str) or not raw:
        return info
    path = Path(raw)
    info["name"] = path.name or None
    manifest = path / "manifest.json"
    if manifest.is_file():
        try:
            loaded = json.loads(manifest.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                info["manifest"] = loaded
        except (OSError, json.JSONDecodeError):
            pass
    job = path / "job.yaml"
    if job.is_file():
        try:
            match = re.search(
                r"^profile:\s*([^\s#]+)", job.read_text(encoding="utf-8"), re.MULTILINE
            )
        except OSError:
            match = None
        if match:
            info["profile"] = match.group(1).strip("'\"")
    return info


def _yaml(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False)


def _fmt(value: Any) -> str:
    if value is None:
        return "—"
    if isinstance(value, list):
        return ", ".join(str(v) for v in value)
    return str(value)


def model_row(base_model: Any) -> dict[str, Any] | None:
    """The model table's row for a run's ``base_model`` (``model_ref`` is unique), or None.

    The table is read by ``model_table.py`` beside this script; like the other
    scripts that run under ``python -I``, it is loaded by path.
    """
    table = runpy.run_path(str(Path(__file__).with_name("model_table.py")))
    return table["exact_row"](base_model)


def model_card(
    run: dict[str, Any],
    *,
    run_id: str,
    weights: list[str],
    samples: int,
    dataset: dict[str, Any],
    version: str,
) -> str:
    """The README.md pushed with the LoRA. Everything in it comes from run.json and the dataset folder."""
    triggers = [str(t) for t in (run.get("triggers") or [])]
    base_model = run.get("base_model")
    rank = run.get("rank")
    alpha = run.get("alpha") if run.get("alpha") is not None else rank
    profile = run.get("profile") or dataset.get("profile")
    manifest = dataset.get("manifest") or {}
    sample_prompts = [str(p) for p in (run.get("sample_prompts") or [])]

    row = model_row(base_model)
    licence = row["license"] if row is not None and row["license"]["show_notice"] else None

    front = ["---"]
    if base_model:
        front.append(f"base_model: {_yaml(base_model)}")
    if licence is not None and licence["id"] in HUB_LICENSES:
        front.append(f"license: {_yaml(licence['id'])}")
    elif licence is not None:
        front += [
            "license: other",
            f"license_name: {_yaml(licence['id'])}",
            f"license_link: {_yaml(licence['url'])}",
        ]
    if triggers:
        front.append(f"instance_prompt: {_yaml(triggers[0])}")
    front += ["tags:", "  - lora", "  - concept-captioner"]
    if manifest.get("repo_id"):
        front += ["datasets:", f"  - {_yaml(manifest['repo_id'])}"]
    front.append("---")

    dataset_cell = dataset.get("name") or "—"
    if manifest.get("repo_id"):
        dataset_cell += f" ({manifest['repo_id']}"
        if manifest.get("revision"):
            dataset_cell += f" @ {str(manifest['revision'])[:12]}"
        dataset_cell += ")"
    images_cell = "—"
    if manifest.get("count") is not None:
        images_cell = f"{manifest['count']} ({manifest.get('with_caption', '?')} captioned)"

    rows = [
        ("Base model", _fmt(base_model)),
        ("Triggers", ", ".join(f"`{t}`" for t in triggers) or "—"),
        ("Steps", _fmt(run.get("steps"))),
        ("Rank / alpha", f"{_fmt(rank)} / {_fmt(alpha)}"),
        ("Learning rate", _fmt(run.get("learning_rate"))),
        ("Resolution", _fmt(run.get("resolution"))),
        (
            "Batch size × accumulation",
            f"{_fmt(run.get('batch_size'))} × {_fmt(run.get('gradient_accumulation'))}",
        ),
        ("Seed", _fmt(run.get("seed"))),
        ("Caption profile", _fmt(profile)),
        ("Dataset", dataset_cell),
        ("Images", images_cell),
        ("concept-captioner", version),
    ]
    body = [
        f"# {run_id}",
        "",
        "LoRA trained on a dataset captioned with "
        f"[concept-captioner](https://github.com/rationallyprime/concept-captioner) {version}.",
        "",
        "| | |",
        "| --- | --- |",
        *(f"| {label} | {value} |" for label, value in rows),
        "",
        "## Files",
        "",
        *(f"- `{path}` — LoRA weights" for path in weights),
        *(f"- `{name}`" for name in SIDE_FILES),
        f"- `samples/` — {samples} sample image{'s' if samples != 1 else ''}"
        if samples
        else "- no samples uploaded",
    ]
    if sample_prompts:
        body += ["", "## Sample prompts", "", *(f"- {prompt}" for prompt in sample_prompts)]
    use: list[str] = []
    if triggers:
        use.append(
            f"Put the trigger `{triggers[0]}` in the prompt where the trained subject should appear"
            + (
                f"; the other trigger{'s' if len(triggers) > 2 else ''} ({', '.join(f'`{t}`' for t in triggers[1:])}) work the same way."
                if len(triggers) > 1
                else "."
            )
        )
    if row is not None and row.get("usage_note"):
        use.append(row["usage_note"])
    if use:
        body += ["", "## Use", *(line for paragraph in use for line in ("", paragraph))]
    if licence is not None:
        body += ["", "## Licence", "", licence["notice"]]
    return "\n".join([*front, "", *body]) + "\n"


# --- the Hub ------------------------------------------------------------------------------------


def token_from_env() -> str | None:
    return os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN") or None


class Hub:
    """Every call this script makes to the Hub, behind one object so tests can substitute a fake."""

    def __init__(self, token: str | None) -> None:
        from huggingface_hub import HfApi

        self.api = HfApi(token=token)

    def create_repo(self, repo_id: str, *, private: bool) -> str:
        return str(self.api.create_repo(repo_id, repo_type="model", private=private, exist_ok=True))

    def upload_folder(
        self, repo_id: str, folder: Path, *, allow_patterns: list[str], commit_message: str
    ) -> str | None:
        info = self.api.upload_folder(
            repo_id=repo_id,
            repo_type="model",
            folder_path=str(folder),
            allow_patterns=allow_patterns,
            commit_message=commit_message,
        )
        return getattr(info, "oid", None)


# --- entry point --------------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--run-dir", required=True, help="/workspace/runs/<id>")
    parser.add_argument("--repo", required=True, help="model repo id (owner/name)")
    parser.add_argument("--private", action="store_true", help="create the repo private")
    parser.add_argument("--no-samples", action="store_true", help="leave samples/ out")
    parser.add_argument(
        "--all-checkpoints", action="store_true", help="every .safetensors, not only the newest"
    )
    parser.add_argument("--commit-message", default=None)
    return parser


def main(argv: list[str] | None = None, hub: Hub | None = None) -> int:
    args = build_parser().parse_args(argv)
    run_dir = Path(args.run_dir).expanduser().resolve()
    if not run_dir.is_dir():
        print(f"push_lora: {run_dir} is not a directory", file=sys.stderr)
        return 1
    weights = select_weights(run_dir, all_checkpoints=args.all_checkpoints)
    if not weights:
        print(f"push_lora: no .safetensors under {run_dir}; nothing to push", file=sys.stderr)
        return 1

    run = load_run(run_dir)
    run_id = str(run.get("run_id") or run_dir.name)
    samples = [] if args.no_samples else sample_files(run_dir)
    weight_names = [relative(run_dir, w) for w in weights]
    version = concept_captioner_version()
    card = model_card(
        run,
        run_id=run_id,
        weights=weight_names,
        samples=len(samples),
        dataset=dataset_info(run),
        version=version,
    )
    (run_dir / CARD_NAME).write_text(card, encoding="utf-8")
    patterns = allow_patterns(run_dir, weights=weights, include_samples=not args.no_samples)
    files = (
        weight_names
        + [name for name in SIDE_FILES if (run_dir / name).is_file()]
        + [relative(run_dir, s) for s in samples]
        + [CARD_NAME]
    )
    print(
        f"push_lora: {run_id} -> {args.repo}: {len(files)} files ({', '.join(weight_names)})",
        flush=True,
    )

    if hub is None:
        hub = Hub(token_from_env())
    url = hub.create_repo(args.repo, private=args.private)
    commit = hub.upload_folder(
        args.repo,
        run_dir,
        allow_patterns=patterns,
        commit_message=args.commit_message or f"Upload LoRA {run_id} (push_lora.py)",
    )
    receipt = {
        "repo_id": args.repo,
        "url": url,
        "commit": commit,
        "run_id": run_id,
        "files": files,
        "concept_captioner_version": version,
        "pushed_at": datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z"),
    }
    (run_dir / RECEIPT_NAME).write_text(
        json.dumps(receipt, indent=1, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(url, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
