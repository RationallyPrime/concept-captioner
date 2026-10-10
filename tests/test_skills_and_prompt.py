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
    assert skill.profiles() == ["flux-image", "h3-still", "ltx-image", "plain"]
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
