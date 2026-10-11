#!/usr/bin/env python3
"""Restore a pruned Resume dataset from the run's exact resolved Hub manifest."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any


def restore_arguments(raw: dict[str, Any], run_dir: Path, workspace: Path) -> list[str] | None:
    if raw.get("resume") is not True:
        return None
    path = Path(raw["dataset"]["path"]).resolve()
    root = (workspace / "datasets").resolve()
    if not path.is_relative_to(root) or path == root:
        raise ValueError("Resume dataset must be under the workspace datasets directory")
    if path.is_dir():
        saved = run_dir / "dataset-manifest.json"
        if saved.is_file():
            manifest = json.loads(saved.read_text())
            if isinstance(manifest, dict) and manifest.get("source") == "local":
                current = json.loads((path / "manifest.json").read_text())
                digest = manifest.get("input_digest")
                if (
                    not isinstance(digest, str)
                    or not re.fullmatch(r"[a-f0-9]{64}", digest)
                    or not isinstance(current, dict)
                    or current.get("source") != "local"
                    or current.get("input_digest") != digest
                ):
                    raise ValueError(
                        "Local Resume requires the exact original input digest; use Repeat after edits"
                    )
        return None
    manifest = json.loads((run_dir / "dataset-manifest.json").read_text())
    if not isinstance(manifest, dict):
        raise ValueError("Resume needs the saved dataset manifest")
    repo, revision = manifest.get("repo_id"), manifest.get("revision")
    if not isinstance(repo, str) or not re.fullmatch(r"[\w.-]+/[\w.-]+", repo):
        raise ValueError(
            "The pruned dataset has no Hub source; upload local inputs again before Resume"
        )
    if not isinstance(revision, str) or not re.fullmatch(r"[a-fA-F0-9]{40}", revision):
        raise ValueError(
            "Resume needs an exact resolved Hub commit; publish and pull the dataset again"
        )
    args = ["--repo", repo, "--revision", revision, "--to", str(path)]
    for key in ("split", "image_column", "caption_column"):
        value = manifest.get(key)
        if not isinstance(value, str) or not value:
            raise ValueError(f"Saved dataset manifest has no {key}")
        args += ["--" + key.replace("_", "-"), value]
    if manifest.get("id_column") is not None:
        if not isinstance(manifest["id_column"], str) or not manifest["id_column"]:
            raise ValueError("Saved dataset manifest has an invalid id_column")
        args += ["--id-column", manifest["id_column"]]
    if not isinstance(manifest.get("only_metadata"), bool):
        raise ValueError("Saved dataset manifest has no only_metadata selection")
    if manifest["only_metadata"]:
        args.append("--only-metadata")
    return args


def restore_dataset(raw: dict[str, Any], run_dir: Path, workspace: Path) -> None:
    args = restore_arguments(raw, run_dir, workspace)
    if args is None:
        return
    prefix = Path(os.environ.get("PODAGENT_PREFIX", "/opt"))
    try:
        subprocess.run(
            [
                str(prefix / "venvs/agent/bin/python"),
                str(Path(__file__).with_name("pull_dataset.py")),
                *args,
            ],
            check=True,
            env={**os.environ, "HF_TOKEN": raw["hf_token"]} if raw.get("hf_token") else None,
        )
    except subprocess.CalledProcessError as error:
        raise ValueError(
            "The exact pinned dataset pull failed; the saved checkpoint is kept"
        ) from error
    if not Path(raw["dataset"]["path"]).is_dir():
        raise ValueError("The pinned dataset pull did not restore the Resume inputs")


if __name__ == "__main__":
    argparse.ArgumentParser(description=__doc__).parse_args()
