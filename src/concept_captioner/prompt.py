"""Assemble the instructions for one sample: skill + profile + job view + task text.

The task texts are the pipeline's own. They describe the output schemas; pydantic-ai supplies
the schema itself in whichever output mode is active, so no schema is dumped here.
"""

from __future__ import annotations

import json

from .job import Job
from .skills import Skill

USER_TURN = "Inspect this exact target image and return the configured JSON object."

CAPTIONER_TASK = """\
RESPONSE
Return one JSON object. `caption` is the training text only, in the profile's format, with
line breaks as JSON escapes. Keep uncertainty out of it. Apply exactly the mapped triggers to
exactly the mapped subjects; describe any other people ordinarily. If a mapped subject is
absent, too small or obscured, or cannot be bound to one visible person, set `usable` false,
leave `caption` empty and explain in `note`. Do not guess. For single_subject_only jobs any
second identity makes the sample unusable. Do not quote readable text (labels, logos, signs)
verbatim; describe it generically."""

CRITIC_TASK = """\
REVIEW TASK (replaces the captioning task above)
You are reviewing a proposed caption against the supplied target image and the ACTIVE JOB
CONFIGURATION. Approve only if every statement in the caption is visible in the image, the
mapped triggers are bound to the right people, no trait the configuration reserves for a
trigger is described, nothing is inferred that a still cannot show (age, biography, sound,
motion), and no readable text is quoted verbatim. Otherwise reject with short, specific notes
the captioner can act on."""


def _assemble(skill: Skill, profile_text: str, job: Job, mapping: dict[str, str]) -> list[str]:
    sections = [skill.instructions(), profile_text]
    for key, text in job.policy_overrides.items():
        sections.append(f"# Job policy override: {key}\n\n{text.strip()}\n")
    sections.append(
        "ACTIVE JOB CONFIGURATION\n" + json.dumps(job.sample_view(mapping), ensure_ascii=False)
    )
    return sections


def captioner_instructions(
    skill: Skill, profile_text: str, job: Job, mapping: dict[str, str]
) -> str:
    sections = [*_assemble(skill, profile_text, job, mapping), CAPTIONER_TASK]
    return "\n\n".join(section.strip() for section in sections) + "\n"


def critic_instructions(skill: Skill, profile_text: str, job: Job, mapping: dict[str, str]) -> str:
    sections = [*_assemble(skill, profile_text, job, mapping), CRITIC_TASK]
    return "\n\n".join(section.strip() for section in sections) + "\n"


def critic_user_turn(caption: str) -> str:
    return "Review this proposed caption against the attached image:\n\n" + caption
