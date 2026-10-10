"""Prompt assembly: shared concept policy + profile grammar + the job's view of one sample.

The policy text in this package is the "Diffusion Training Captioner" skill (2026-10-09), split
by section so a profile pulls only the grammar it needs. ``core.md`` is the format-agnostic
concept policy and is always included.
"""

from __future__ import annotations

import hashlib
import json
from importlib.resources import files

from ..job import Job
from ..profiles.base import CaptionProfile

POLICY_VERSION = 4


def policy_text(name: str) -> str:
    return files("concept_captioner.policy").joinpath(name).read_text(encoding="utf-8")


def _operating() -> str:
    text = policy_text("operating.md")
    # Keep the operating instructions; drop the fill-in YAML template and delivery notes, which
    # are superseded by the structured job view and the JSON response contract.
    head, _, _ = text.partition("## Job configuration")
    return head.rstrip() + "\n"


RESPONSE_CONTRACT = """
API RESPONSE CONTRACT
Return only one JSON object matching the requested schema, not labeled blocks. The caption field
contains only the actual training text, with any line breaks encoded as JSON escapes. Keep
uncertainty outside that string. Count all visible human identities. Set mapped_subjects_usable
false if a configured target is absent, too small or obscured, or cannot be mapped unambiguously.
Do not guess. For single_subject_only jobs, any second identity makes the sample unusable.
Otherwise, additional people are allowed: describe them ordinarily and apply only explicitly
mapped triggers. Set concept_boundary_violation for leaked protected traits, and
subject_binding_violation for absent, wrong or misbound triggers. Class nouns and unambiguous
pronouns are allowed. Do not quote readable text (labels, logos, signs) verbatim; describe it
generically. Use an empty caption with an ambiguity_reason if the sample cannot be captioned
safely from this mapping.
"""

CRITIQUE_CONTRACT = """
CRITIQUE TASK (overrides the caption-generation task)
You are auditing a proposed caption against the supplied target image and the ACTIVE JOB
CONFIGURATION. Return only the critique schema.

Build the claim ledger first: list every checkable statement the caption makes about the image
(subject count and positions, clothing, hair presentation, expression and gaze, pose, objects,
setting, lighting, treatment) and mark each one verified only if the image shows exactly that.
Then decide the flags:
- concept_boundary_violation: a trait the configuration reserves for a trigger is described.
- unsupported_inference: age, biography, audio, motion or anything the still cannot show.
- subject_ambiguity: a mapped trigger cannot be bound to one visible person with confidence.
- image_caption_mismatch: any ledger claim is not verified.
- another_person_described_as_trigger: a trigger is applied to the wrong person.
- trigger_subject_visible_but_unbound: a person who matches a configured concept's locator is
  visible (even partially, at an edge) but the caption calls them only "a man", "a woman",
  "another person" or similar. This is a mapping gap and must fail the caption.
- quoted_text_present: the caption quotes readable text verbatim.
approved is true only when every flag is false and every claim is verified. reasons must list
the specific grounds for the verdict, for approvals as well as rejections. Do not reject class
nouns or unambiguous pronouns. Count all human identities; apply the single-subject restriction
only when configured.
"""


def build_system_prompt(job: Job, profile: CaptionProfile, mapping: dict[str, str]) -> str:
    sections = [
        _operating(),
        policy_text("core.md"),
        profile.format_instructions(),
        profile.examples(),
    ]
    for key, text in job.policy_overrides.items():
        sections.append(f"# Job policy override: {key}\n\n{text.strip()}\n")
    sections.append(
        "ACTIVE JOB CONFIGURATION\n" + json.dumps(job.sample_view(mapping), ensure_ascii=False)
    )
    sections.append(RESPONSE_CONTRACT.strip())
    return "\n\n".join(section.strip() for section in sections) + "\n"


def build_critique_prompt(
    job: Job, profile: CaptionProfile, mapping: dict[str, str], caption: str
) -> str:
    return (
        build_system_prompt(job, profile, mapping)
        + "\n"
        + CRITIQUE_CONTRACT.strip()
        + "\nProposed caption:\n"
        + json.dumps(caption, ensure_ascii=False)
        + "\n"
    )


def policy_sha256(job: Job, profile: CaptionProfile, mapping: dict[str, str]) -> str:
    """Bind receipts to the exact prompt bytes, schemas and policy version."""
    from ..schemas import CritiqueResult, PrimaryResult

    payload = {
        "policy_version": POLICY_VERSION,
        "profile": profile.name,
        "primary_prompt": build_system_prompt(job, profile, mapping),
        "critique_prompt": build_critique_prompt(job, profile, mapping, "<PROPOSED_CAPTION>"),
        "primary_schema": PrimaryResult.model_json_schema(),
        "critique_schema": CritiqueResult.model_json_schema(),
    }
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()
