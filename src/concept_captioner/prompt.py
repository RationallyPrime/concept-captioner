"""Assemble the instructions for one sample: skill + profile + job view + task text.

The task texts are the pipeline's own. They describe the output schemas; pydantic-ai supplies
the schema itself in whichever output mode is active, so no schema is dumped here.
"""

from __future__ import annotations

import json

from .job import Job
from .skills import Skill

USER_TURN = "Inspect this exact training target and return the configured JSON object."

CAPTIONER_TASK = """\
RESPONSE
Return one JSON object. `caption` is the training text only, in the profile's format, with
line breaks as JSON escapes. Keep uncertainty out of it. Apply the mapped triggers according
to each concept's target_concept and boundary. For person, object or character concepts, bind
the trigger to the correct visible subject. For style, apply it to the declared whole target
or region and describe subject matter without verbalizing the style being learned. For
motion, bind it to the observed movement and describe the performer and scene outside that
movement concept. Describe unrelated people and objects ordinarily. If the mapped concept is
absent, obscured or cannot be identified from the supplied evidence, set `usable` false, leave
`caption` empty and explain in `note`. Do not guess. For single_subject_only person jobs any
second identity makes the sample unusable. Do not quote readable text (labels, logos, signs)
verbatim; describe it generically."""

CRITIC_TASK = """\
REVIEW TASK (replaces the captioning task above)
Review the proposed caption against the supplied training target and ACTIVE JOB CONFIGURATION.
Approve only if every statement is supported by the target, each trigger is applied to the
correct person, object, character, style or motion, and no defining trait reserved for that
concept is described, including through synonyms. A whole-image style does not require a
visible person. Do not infer age, biography, sound or motion from a still. For a video, assess
only observed changes and inspected audio; never infer sound from thumbnails. No readable text
may be quoted verbatim. Otherwise reject with short, specific notes the captioner can act on."""


def _assemble(
    skill: Skill, profile_text: str, job: Job, mapping: dict[str, str], *, is_video: bool = False
) -> list[str]:
    sections = [skill.instructions(), profile_text]
    for key, text in job.policy_overrides.items():
        sections.append(f"# Job policy override: {key}\n\n{text.strip()}\n")
    view = job.sample_view(mapping)
    if is_video:
        view["inputs"]["evidence"] = "attached_target_video"
        view["inputs"]["audio_status"] = "uninspected"
    sections.append("ACTIVE JOB CONFIGURATION\n" + json.dumps(view, ensure_ascii=False))
    return sections


def captioner_instructions(
    skill: Skill, profile_text: str, job: Job, mapping: dict[str, str], *, is_video: bool = False
) -> str:
    sections = [*_assemble(skill, profile_text, job, mapping, is_video=is_video), CAPTIONER_TASK]
    return "\n\n".join(section.strip() for section in sections) + "\n"


def critic_instructions(
    skill: Skill, profile_text: str, job: Job, mapping: dict[str, str], *, is_video: bool = False
) -> str:
    sections = [*_assemble(skill, profile_text, job, mapping, is_video=is_video), CRITIC_TASK]
    return "\n\n".join(section.strip() for section in sections) + "\n"


def critic_user_turn(caption: str) -> str:
    return "Review this proposed caption against the attached training target:\n\n" + caption
