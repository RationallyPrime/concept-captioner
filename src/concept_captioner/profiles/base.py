"""CaptionProfile: the injectable "captioning skill".

A profile knows three things about a target trainer: the format text the captioner must follow,
the worked examples that show it, and how to validate and unwrap a caption in that format. The
concept policy (what belongs to a trigger, how to bind subjects, what counts as nuisance) is
shared and lives in ``policy.core``; a profile only adds the trainer-specific grammar.

Built-in profiles cover MiniMax H3 stills, FLUX images and LTX images. A user profile is a
directory with ``profile.yaml`` plus ``format.md`` and ``examples.md``; see ``DirectoryProfile``.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from importlib.resources import files
from pathlib import Path
from typing import Protocol, runtime_checkable

import yaml

from ..types import ConfigurationError

_MARKDOWN = re.compile(r"```|^\s*(?:#+\s+|[>*+-]\s+|[*_]{1,3}|caption\s*:|`)|`\s*$", re.IGNORECASE)
_WORDS = re.compile(r"[^\W_]+(?:['’-][^\W_]+)*", re.UNICODE)
_QUOTED = re.compile(r"[\"“”‘’'][^\"“”‘’']{2,}[\"“”‘’']")


@dataclass(frozen=True, slots=True)
class FormatCheck:
    failures: tuple[str, ...]
    body: str  # the descriptive text with any wrapper removed
    word_count: int

    @property
    def valid(self) -> bool:
        return not self.failures


@runtime_checkable
class CaptionProfile(Protocol):
    name: str
    media: str  # "image" | "video"

    def format_instructions(self) -> str: ...

    def examples(self) -> str: ...

    def check(self, caption: str) -> FormatCheck: ...

    def wrap(self, body: str) -> str: ...


def _policy_text(name: str) -> str:
    return files("concept_captioner.policy").joinpath(name).read_text(encoding="utf-8")


def _section(markdown: str, heading: str, level: int = 2) -> str:
    """Return a ``## heading`` section (including subsections) from a markdown document."""
    marker = "#" * level + " " + heading
    lines = markdown.split("\n")
    start = next((i for i, line in enumerate(lines) if line.strip() == marker), None)
    if start is None:
        raise ConfigurationError(f"policy section {heading!r} not found")
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if re.match(r"^#{1," + str(level) + r"} ", lines[i]):
            end = i
            break
    return "\n".join(lines[start:end]).rstrip() + "\n"


def common_checks(caption: str) -> list[str]:
    failures: list[str] = []
    if not caption.strip():
        failures.append("caption:empty")
    if caption != caption.strip():
        failures.append("caption:leading_or_trailing_whitespace")
    if any(unicodedata.category(c).startswith("C") and c != "\n" for c in caption):
        failures.append("caption:control_character")
    if _MARKDOWN.search(caption):
        failures.append("caption:markdown_wrapper")
    return failures


def quoted_text_present(body: str) -> bool:
    return bool(_QUOTED.search(body))


def word_count(text: str) -> int:
    return len(_WORDS.findall(text))


class H3StillProfile:
    """Three H3 fields, one ``[Shot 1]``, ``N/A`` in both audio fields."""

    name = "h3-still"
    media = "image"
    _PATTERN = re.compile(
        r"integrated_multimodal_description: \[Shot 1\] ([^\n]+)\n\n"
        r"overall_soundscape: N/A\n\nnon_diegetic_music: N/A"
    )

    def format_instructions(self) -> str:
        h3 = _policy_text("h3.md")
        return "\n".join(
            [
                "# MiniMax H3 training-caption format (still images)\n",
                _section(h3, "Scope"),
                _section(h3, "Three fields"),
                _section(h3, "Stills"),
            ]
        )

    def examples(self) -> str:
        ex = _policy_text("examples.md")
        return "\n".join(
            [
                "# Worked examples (fictional; triggers are placeholders)\n",
                _section(ex, "H3 identity still"),
                _section(ex, "Two trained identities"),
                _section(ex, "Audit corrections"),
            ]
        )

    def check(self, caption: str) -> FormatCheck:
        caption = unicodedata.normalize("NFC", caption)
        failures = common_checks(caption)
        match = self._PATTERN.fullmatch(caption)
        if not match:
            failures.append("caption:h3_still_format")
            body = caption
        else:
            body = match[1]
            if re.search(r"\[Shot |<Picture |\b\d{1,2}:\d{2}(?:\.\d+)?\b", body):
                failures.append("caption:still_has_timeline_or_reference")
        return FormatCheck(tuple(dict.fromkeys(failures)), body, word_count(body))

    def wrap(self, body: str) -> str:
        return (
            f"integrated_multimodal_description: [Shot 1] {body.strip()}\n\n"
            "overall_soundscape: N/A\n\nnon_diegetic_music: N/A"
        )


class _ProseProfile:
    """One paragraph of visual prose, no H3 fields, no timeline."""

    name = "prose"
    media = "image"
    _FORBIDDEN = re.compile(
        r"integrated_multimodal_description:|overall_soundscape:|non_diegetic_music:|\[Shot |<Picture "
    )

    def check(self, caption: str) -> FormatCheck:
        caption = unicodedata.normalize("NFC", caption)
        failures = common_checks(caption)
        if "\n" in caption or self._FORBIDDEN.search(caption):
            failures.append("caption:visual_prose_format")
        return FormatCheck(tuple(dict.fromkeys(failures)), caption, word_count(caption))

    def wrap(self, body: str) -> str:
        return " ".join(body.split())


class FluxImageProfile(_ProseProfile):
    name = "flux-image"

    def format_instructions(self) -> str:
        fl = _policy_text("flux_ltx.md")
        return "# FLUX image training format\n\n" + _section(fl, "FLUX image training")

    def examples(self) -> str:
        ex = _policy_text("examples.md")
        return "# Worked example (fictional)\n\n" + _section(ex, "FLUX image", level=3)


class LtxImageProfile(_ProseProfile):
    name = "ltx-image"

    def format_instructions(self) -> str:
        fl = _policy_text("flux_ltx.md")
        return "# LTX image training format\n\n" + _section(fl, "LTX image training")

    def examples(self) -> str:
        ex = _policy_text("examples.md")
        return "# Worked example (fictional)\n\n" + _section(ex, "FLUX image", level=3)


class PlainProfile(_ProseProfile):
    """Trainer-agnostic prose. Use when the target trainer has no special grammar."""

    name = "plain"

    def format_instructions(self) -> str:
        return (
            "# Plain prose format\n\nWrite one connected paragraph of visual prose. Introduce the "
            "exact trigger and class noun early. No field names, shot tags, timestamps, lists or "
            "Markdown. Describe only what is visible in the supplied target.\n"
        )

    def examples(self) -> str:
        ex = _policy_text("examples.md")
        return "# Worked example (fictional)\n\n" + _section(ex, "FLUX image", level=3)


class DirectoryProfile(_ProseProfile):
    """A user-supplied profile loaded from a directory.

    ``profile.yaml``::

        name: my-trainer
        media: image
        wrapper: "{body}"            # optional; Python format string with {body}
        pattern: "^(?P<body>.+)$"    # optional; regex with a ``body`` group, DOTALL
        forbid: ["\\[Shot "]          # optional; regexes that must not appear in the body

    plus ``format.md`` (instructions) and ``examples.md`` (worked examples).
    """

    def __init__(self, directory: str | Path) -> None:
        root = Path(directory)
        meta = yaml.safe_load((root / "profile.yaml").read_text(encoding="utf-8")) or {}
        self.name = str(meta.get("name") or root.name)
        self.media = str(meta.get("media") or "image")
        self._wrapper = str(meta.get("wrapper") or "{body}")
        pattern = meta.get("pattern")
        self._pattern = re.compile(pattern, re.DOTALL) if pattern else None
        self._forbid = [re.compile(p) for p in (meta.get("forbid") or [])]
        self._format = (root / "format.md").read_text(encoding="utf-8")
        examples = root / "examples.md"
        self._examples = examples.read_text(encoding="utf-8") if examples.exists() else ""

    def format_instructions(self) -> str:
        return self._format

    def examples(self) -> str:
        return self._examples

    def check(self, caption: str) -> FormatCheck:
        caption = unicodedata.normalize("NFC", caption)
        failures: list[str] = []
        body = caption
        if self._pattern is not None:
            match = self._pattern.fullmatch(caption)
            if not match:
                failures.append(f"caption:{self.name}_format")
            else:
                body = match.group("body") if "body" in match.groupdict() else caption
        # Markdown/whitespace checks apply to the descriptive body; the wrapper is the profile's own.
        failures.extend(common_checks(body))
        if any(p.search(body) for p in self._forbid):
            failures.append(f"caption:{self.name}_forbidden_token")
        return FormatCheck(tuple(dict.fromkeys(failures)), body, word_count(body))

    def wrap(self, body: str) -> str:
        return self._wrapper.format(body=body.strip())
