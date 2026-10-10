from __future__ import annotations

import io
import json
from collections.abc import Callable
from pathlib import Path

import pytest
from PIL import Image, ImageDraw
from pydantic_ai.messages import ModelMessage, ModelResponse, TextPart
from pydantic_ai.models.function import AgentInfo, FunctionModel

from concept_captioner.job import Concept, Job
from concept_captioner.models import Resolved
from concept_captioner.schemas import Caption, Critique


def synthetic_png(seed: int, size: tuple[int, int] = (256, 256)) -> bytes:
    image = Image.new("RGB", size, (40 + seed * 20 % 200, 90, 160))
    draw = ImageDraw.Draw(image)
    draw.ellipse([64, 48, 192, 176], fill=(230, 200, 180))
    draw.rectangle([80, 180, 176, 256], fill=(30 + seed * 7 % 200, 60, 120))
    out = io.BytesIO()
    image.save(out, format="PNG")
    return out.getvalue()


@pytest.fixture
def images(tmp_path: Path) -> Path:
    folder = tmp_path / "images"
    folder.mkdir()
    for name, seed in (("solo.png", 1), ("pair.png", 2), ("unmapped.png", 3)):
        (folder / name).write_bytes(synthetic_png(seed))
    return folder


@pytest.fixture
def job() -> Job:
    return Job(
        concepts=[
            Concept(trigger="NORA7", class_noun="woman"),
            Concept(trigger="IVAN9", class_noun="man"),
        ],
        samples={
            "solo.png": {"NORA7": "The only person in the crop."},
            "pair.png": {"NORA7": "The woman on the left.", "IVAN9": "The man on the right."},
            "unmapped.png": None,
        },
    )


def mapped_triggers(messages: list[ModelMessage]) -> list[str]:
    """Read the mapped triggers back out of the ACTIVE JOB CONFIGURATION in the instructions."""
    instructions = messages[0].instructions or ""
    view = json.loads(instructions.split("ACTIVE JOB CONFIGURATION\n", 1)[1].split("\n", 1)[0])
    return list(view["inputs"]["subject_mapping"])


def h3(body: str) -> str:
    return (
        f"integrated_multimodal_description: [Shot 1] {body}\n\n"
        "overall_soundscape: N/A\n\nnon_diegetic_music: N/A"
    )


def good_caption(messages: list[ModelMessage]) -> str:
    mapped = mapped_triggers(messages)
    if mapped == ["NORA7", "IVAN9"]:
        return h3(
            "A photograph frames NORA7, a woman on the left, beside IVAN9, a man on the right."
        )
    return h3("A photograph frames NORA7, a woman, seated by a window in a blue blouse.")


def function_model(
    respond: Callable[[list[ModelMessage], AgentInfo], object], *, model_name: str = "fake"
) -> Resolved:
    """A Resolved wrapping a FunctionModel whose responder returns a pydantic object or a str."""

    def fn(messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        out = respond(messages, info)
        text = out if isinstance(out, str) else out.model_dump_json()
        return ModelResponse(parts=[TextPart(text)], model_name=model_name)

    return Resolved(
        model=FunctionModel(fn, model_name=model_name),
        settings={},
        output_mode="native",
        requested=model_name,
    )


def captioner_ok(messages: list[ModelMessage], info: AgentInfo) -> Caption:
    return Caption(caption=good_caption(messages))


def critic_ok(messages: list[ModelMessage], info: AgentInfo) -> Critique:
    return Critique(approved=True, notes=["looks right"])
