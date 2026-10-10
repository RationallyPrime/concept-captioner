from __future__ import annotations

import io
from pathlib import Path

import pytest
from PIL import Image, ImageDraw

from concept_captioner.job import Concept, Job
from concept_captioner.profiles import load_profile
from concept_captioner.schemas import Claim, CritiqueResult, PrimaryResult
from concept_captioner.types import Request


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
        profile="h3-still",
        concepts=[Concept(trigger="NORA7", class_noun="woman"), Concept(trigger="IVAN9", class_noun="man")],
        samples={
            "solo.png": {"NORA7": "The only person in the crop."},
            "pair.png": {"NORA7": "The woman on the left.", "IVAN9": "The man on the right."},
            "unmapped.png": None,
        },
    )


@pytest.fixture
def profile():
    return load_profile("h3-still")


def h3(body: str) -> str:
    return f"integrated_multimodal_description: [Shot 1] {body}\n\noverall_soundscape: N/A\n\nnon_diegetic_music: N/A"


def good_caption_for(request: Request) -> str:
    """Pick a caption that names exactly the mapped triggers (read from the job view in the prompt)."""
    mapped = []
    for trigger in ("NORA7", "IVAN9"):
        if '"subject_mapping": {' in request.system and f'"{trigger}":' in request.system.split("ACTIVE JOB CONFIGURATION")[-1]:
            mapped.append(trigger)
    if mapped == ["NORA7", "IVAN9"]:
        return h3("A color photograph frames NORA7, a woman on the left, beside IVAN9, a man on the right. She wears a yellow cardigan; he wears a black jacket. Soft daylight.")
    return h3("A color photograph frames NORA7, a woman, seated by a window in a blue blouse with her blonde hair down, looking at the camera with a neutral expression. Soft window light.")


def primary_responder(request: Request):
    if request.response_schema is PrimaryResult:
        caption = good_caption_for(request)
        count = 2 if "IVAN9" in caption else 1
        return PrimaryResult(caption=caption, human_subject_count=count, mapped_subjects_usable=True)
    if request.response_schema is CritiqueResult:
        count = 2 if "IVAN9" in request.system else 1
        return approving_critique(count)
    raise AssertionError("unexpected request")


def approving_critique(count: int = 1, **overrides) -> CritiqueResult:
    base = dict(
        approved=True,
        claims=[Claim(claim="a woman is seated by a window", verified=True)],
        human_subject_count=count,
        mapped_subjects_usable=True,
        ambiguity_reason=None,
        concept_boundary_violation=False,
        unsupported_inference=False,
        subject_ambiguity=False,
        image_caption_mismatch=False,
        another_person_described_as_trigger=False,
        trigger_subject_visible_but_unbound=False,
        quoted_text_present=False,
        reasons=["triggers bound correctly", "all claims verified"],
    )
    base.update(overrides)
    return CritiqueResult(**base)
