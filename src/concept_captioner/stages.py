"""The two model-facing stages as pydantic-ai Agents: the captioner and the optional critic.

The captioner carries the pipeline's one mechanical check as an output validator: every mapped
trigger must appear in the caption as an exact token, and no unmapped trigger may. On failure
pydantic-ai sends the problem back to the model in the same conversation and asks once more.
"""

from __future__ import annotations

import unicodedata
from dataclasses import dataclass
from typing import Any

from pydantic_ai import Agent, BinaryContent, ModelRetry, RunContext
from pydantic_ai.messages import ModelMessage

from .images import provider_image
from .models import Resolved
from .schemas import Caption, Critique
from .sources.local import VIDEO_SAMPLING_FPS, VIDEO_SUFFIXES
from .types import Sample


@dataclass(frozen=True, slots=True)
class CaptionDeps:
    mapping: dict[str, str]
    triggers: tuple[str, ...]  # every trigger the job knows


def _is_word_char(char: str) -> bool:
    return char == "_" or unicodedata.category(char)[0] in {"L", "M", "N"}


def exact_trigger_spans(text: str, trigger: str) -> tuple[tuple[int, int], ...]:
    """Whole-token occurrences of ``trigger`` (NFC-normalized, case-sensitive)."""
    spans: list[tuple[int, int]] = []
    start = 0
    while True:
        index = text.find(trigger, start)
        if index < 0:
            return tuple(spans)
        end = index + len(trigger)
        left = index == 0 or not _is_word_char(text[index - 1])
        right = end == len(text) or not _is_word_char(text[end])
        if left and right:
            spans.append((index, end))
        start = index + 1


def trigger_problems(caption: str, deps: CaptionDeps) -> list[str]:
    text = unicodedata.normalize("NFC", caption)
    problems = []
    for trigger in deps.mapping:
        if not exact_trigger_spans(text, unicodedata.normalize("NFC", trigger)):
            problems.append(f"the mapped trigger {trigger} must appear exactly in the caption")
    for trigger in deps.triggers:
        if trigger not in deps.mapping and exact_trigger_spans(text, trigger):
            problems.append(f"{trigger} is not mapped in this image; do not use that trigger")
    return problems


def image_content(sample: Sample) -> BinaryContent:
    if sample.suffix.lower() in VIDEO_SUFFIXES:
        media_type = "video/quicktime" if sample.suffix.lower() == ".mov" else "video/mp4"
        return BinaryContent(
            data=sample.data, media_type=media_type, vendor_metadata={"fps": VIDEO_SAMPLING_FPS}
        )
    data, media_type = provider_image(sample.data, suffix=sample.suffix)
    return BinaryContent(data=data, media_type=media_type)


def build_captioner(resolved: Resolved) -> Agent[CaptionDeps, Any]:
    agent: Agent[CaptionDeps, Any] = Agent(
        resolved.model,
        name="captioner",
        output_type=resolved.output_type(Caption),
        deps_type=CaptionDeps,
        model_settings=resolved.settings,
        retries=1,
    )

    @agent.output_validator
    def triggers_present(ctx: RunContext[CaptionDeps], result: Caption) -> Caption:
        if not result.usable:
            return result
        problems = trigger_problems(result.caption, ctx.deps)
        if problems:
            raise ModelRetry(
                "Fix the caption: "
                + "; ".join(problems)
                + ". If a mapped subject is not actually visible in this image, do not invent it: "
                "set usable to false, leave the caption empty and say why in note."
            )
        return result

    return agent


def build_critic(resolved: Resolved) -> Agent[None, Any]:
    return Agent(
        resolved.model,
        name="critic",
        output_type=resolved.output_type(Critique),
        model_settings=resolved.settings,
        retries=1,
    )


def served_model(messages: list[ModelMessage]) -> str | None:
    for message in reversed(messages):
        if message.kind == "response":
            return message.model_name
    return None
