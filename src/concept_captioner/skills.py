"""Agent Skills loader.

A skill is a directory per the Agent Skills specification (https://agentskills.io/specification):
``SKILL.md`` with YAML frontmatter (``name`` optional but must match the directory,
``description`` required) and a Markdown body, plus an optional ``references/`` directory.

Two conventions of our own on top of the spec:

- ``metadata.references: [file.md, ...]`` names files under ``references/`` to inline after the
  body on every run. Unnamed references are never read.
- ``references/profiles/<name>.md`` is a caption profile: the trainer's caption shape, in prose.

The skill is loaded eagerly; its text goes straight into the agent's instructions.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field
from importlib.resources import files
from pathlib import Path
from typing import Any

import yaml

from .types import ConfigurationError

DEFAULT_SKILL_NAME = "diffusion-training-captioner"
_NAME = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


def default_skill_dir() -> Path:
    return Path(str(files("concept_captioner").joinpath("skills", DEFAULT_SKILL_NAME)))


@dataclass(frozen=True)
class Skill:
    name: str
    description: str
    body: str
    directory: Path
    references: tuple[str, ...] = ()
    metadata: dict[str, Any] = field(default_factory=dict)

    def reference(self, relative: str) -> str:
        path = self.directory / "references" / relative
        if not path.is_file():
            raise ConfigurationError(f"skill {self.name!r} has no reference {relative!r}")
        return path.read_text(encoding="utf-8")

    def instructions(self) -> str:
        parts = [self.body.strip()]
        parts.extend(self.reference(name).strip() for name in self.references)
        return "\n\n".join(parts) + "\n"

    def profiles(self) -> list[str]:
        root = self.directory / "references" / "profiles"
        return sorted(p.stem for p in root.glob("*.md")) if root.is_dir() else []

    def profile(self, name_or_path: str, *, relative_to: Path | None = None) -> str:
        """``h3-still`` -> ``references/profiles/h3-still.md``; or any ``.md`` path."""
        candidate = resolve_path(name_or_path, relative_to=relative_to)
        if candidate.suffix == ".md" and candidate.is_file():
            return candidate.read_text(encoding="utf-8")
        path = self.directory / "references" / "profiles" / f"{name_or_path}.md"
        if path.is_file():
            return path.read_text(encoding="utf-8")
        raise ConfigurationError(
            f"unknown profile {name_or_path!r}; skill {self.name!r} has {self.profiles()}, "
            "or pass a path to a .md file"
        )


def _frontmatter(text: str) -> tuple[dict[str, Any], str]:
    if not text.startswith("---"):
        return {}, text
    match = re.match(r"^---[ \t]*\r?\n(.*?)\r?\n---[ \t]*\r?\n?", text, re.DOTALL)
    if match is None:
        raise ConfigurationError("SKILL.md frontmatter is not closed")
    try:
        meta = yaml.safe_load(match.group(1)) or {}
    except yaml.YAMLError as error:
        raise ConfigurationError(f"SKILL.md frontmatter is not valid YAML: {error}") from None
    if not isinstance(meta, dict):
        raise ConfigurationError("SKILL.md frontmatter must be a mapping")
    return meta, text[match.end() :]


def resolve_path(path: str | Path, *, relative_to: Path | None = None) -> Path:
    candidate = Path(path).expanduser()
    return relative_to / candidate if relative_to and not candidate.is_absolute() else candidate


def load(path: str | Path | None = None, *, relative_to: Path | None = None) -> Skill:
    directory = (
        resolve_path(path, relative_to=relative_to) if path is not None else default_skill_dir()
    )
    skill_md = directory / "SKILL.md"
    if not skill_md.is_file():
        raise ConfigurationError(f"not a skill directory (no SKILL.md): {directory}")
    meta, body = _frontmatter(skill_md.read_text(encoding="utf-8"))
    dir_name = unicodedata.normalize("NFKC", directory.resolve().name)
    name = unicodedata.normalize("NFKC", str(meta.get("name") or dir_name))
    if not _NAME.match(name) or len(name) > 64:
        raise ConfigurationError(
            f"skill name {name!r} must be lowercase letters/digits separated by single hyphens"
        )
    if name != dir_name:
        raise ConfigurationError(f"skill name {name!r} does not match directory {dir_name!r}")
    description = str(meta.get("description") or "").strip()
    if not description:
        raise ConfigurationError(f"skill {name!r}: frontmatter needs a non-blank description")
    metadata = meta.get("metadata") or {}
    if not isinstance(metadata, dict):
        raise ConfigurationError(f"skill {name!r}: metadata must be a mapping")
    references = tuple(str(r) for r in (metadata.get("references") or []))
    skill = Skill(name, description, body, directory, references, metadata)
    for reference in references:
        skill.reference(reference)  # fail at load time, not mid-run
    return skill
