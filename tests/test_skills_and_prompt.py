from __future__ import annotations

from pathlib import Path

import pytest

from concept_captioner import skills
from concept_captioner.prompt import captioner_instructions, critic_instructions
from concept_captioner.types import ConfigurationError


def test_default_skill_loads_with_profiles():
    skill = skills.load()
    assert skill.name == "diffusion-training-captioner"
    assert "# Core Caption Policy" in skill.instructions()
    for profile in skill.profiles():
        assert skill.profile(profile)
    assert "[Shot 1]" in skill.profile("h3-still")
    with pytest.raises(ConfigurationError):
        skill.profile("nope")


def test_user_skill_with_named_reference_and_profile_path(tmp_path: Path):
    root = tmp_path / "my-skill"
    (root / "references").mkdir(parents=True)
    (root / "SKILL.md").write_text(
        "---\ndescription: Mine.\nmetadata:\n  references: [extra.md]\n---\nBODY TEXT\n"
    )
    (root / "references" / "extra.md").write_text("EXTRA TEXT")
    (root / "references" / "unused.md").write_text("NEVER")
    (tmp_path / "shape.md").write_text("SHAPE TEXT")
    skill = skills.load(root)
    assert skill.name == "my-skill" and skill.description == "Mine."
    text = skill.instructions()
    assert "BODY TEXT" in text and "EXTRA TEXT" in text and "NEVER" not in text
    assert skill.profile(str(tmp_path / "shape.md")) == "SHAPE TEXT"


def test_skill_validation(tmp_path: Path):
    bad = tmp_path / "Bad_Name"
    bad.mkdir()
    (bad / "SKILL.md").write_text("---\ndescription: x\n---\nbody")
    with pytest.raises(ConfigurationError):
        skills.load(bad)
    no_desc = tmp_path / "no-desc"
    no_desc.mkdir()
    (no_desc / "SKILL.md").write_text("---\nname: no-desc\n---\nbody")
    with pytest.raises(ConfigurationError):
        skills.load(no_desc)
    with pytest.raises(ConfigurationError):
        skills.load(tmp_path)  # no SKILL.md


def test_prompt_assembly(job):
    skill = skills.load()
    profile = skill.profile(job.profile)
    text = captioner_instructions(skill, profile, job, {"NORA7": "The only person."})
    assert (
        text.index("# Core Caption Policy")
        < text.index("[Shot 1]")
        < text.index("ACTIVE JOB CONFIGURATION")
    )
    assert text.rstrip().endswith("describe it generically.")
    job_view = text.split("ACTIVE JOB CONFIGURATION")[1]
    assert '"NORA7"' in job_view and "IVAN9" not in job_view
    review = critic_instructions(skill, profile, job, {"NORA7": "x"})
    assert "REVIEW TASK" in review and "RESPONSE\n" not in review


def test_h3_video_profile_carries_actual_target_type_and_keeps_still_convention(job):
    import json

    skill = skills.load()
    job.profile = "h3-video"
    profile = skill.profile(job.profile)
    video = captioner_instructions(
        skill, profile, job, {"NORA7": "the person in the selected clip"}, is_video=True
    )
    still = captioner_instructions(skill, profile, job, {"NORA7": "the person in the still"})

    def inputs(text):
        view = text.split("ACTIVE JOB CONFIGURATION\n", 1)[1].split("\n", 1)[0]
        return json.loads(view)["inputs"]

    assert inputs(video)["evidence"] == "attached_target_video"
    assert inputs(video)["audio_status"] == "uninspected"
    assert inputs(still)["evidence"] == "attached_target_image"
    assert inputs(still)["audio_status"] == "not_applicable"
    assert "## Still images in a mixed project" in profile
    assert "use the unchanged `h3-still` convention" in profile
    assert "never claim silence because audio was unavailable or uninspected" in profile


def test_style_defaults_do_not_request_identity_traits():
    from concept_captioner.job import Concept, Job

    concept = Concept(trigger="INKSTYLE", target_concept="style")
    assert concept.class_noun == "style"
    job = Job(concepts=[concept])
    assert concept.traits_to_learn == [
        "the visual style, including its rendering, texture and palette"
    ]
    assert "subject matter" in concept.attributes_to_describe
    text = captioner_instructions(
        skills.load(), "Plain prose", job, {"INKSTYLE": "the entire image"}
    )
    assert "For style, apply it to the declared whole target" in text
    assert "cannot be bound to one visible person" not in text
    review = critic_instructions(
        skills.load(), "Plain prose", job, {"INKSTYLE": "the entire image"}
    )
    assert "A whole-image style does not require a" in review


def test_explicit_category_boundary_remains_the_users_choice():
    from concept_captioner.job import Concept

    concept = Concept(
        trigger="INKSTYLE",
        target_concept="style",
        traits_to_learn=["line work only"],
        attributes_to_describe=["palette"],
    )
    assert concept.traits_to_learn == ["line work only"]
    assert concept.attributes_to_describe == ["palette"]


@pytest.mark.parametrize("category", [[], {}])
def test_malformed_category_uses_normal_configuration_error(category):
    from pydantic import ValidationError

    from concept_captioner.job import Job

    with pytest.raises(ValidationError):
        Job.model_validate({"concepts": [{"trigger": "BAD", "target_concept": category}]})
