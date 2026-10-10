"""Structured responses from the captioner and the critic.

The critic schema is deliberately stronger than a yes/no: it must produce a claim ledger (every
checkable statement in the caption, each marked verified or not), and it has flags for the two
failure modes a yes/no critic structurally cannot see: a mapped subject visible in the crop but
left unnamed, and quoted text in the caption.
"""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field


class PrimaryResult(BaseModel):
    """What the captioner returns. ``caption`` is the training text and nothing else."""

    model_config = ConfigDict(extra="forbid")

    caption: str
    human_subject_count: int = Field(ge=0)
    mapped_subjects_usable: bool
    ambiguity_reason: str | None = None
    concept_boundary_violation: bool = False
    subject_binding_violation: bool = False


class Claim(BaseModel):
    model_config = ConfigDict(extra="forbid")

    claim: str = Field(description="One checkable statement taken from the caption.")
    verified: bool = Field(description="True only if the target image shows exactly this.")
    note: str | None = Field(default=None, description="What differs, when not verified.")


class CritiqueResult(BaseModel):
    """What the critic returns. ``approved`` is only meaningful with a non-empty ledger."""

    model_config = ConfigDict(extra="forbid")

    approved: bool
    claims: list[Claim] = Field(
        description="Every checkable claim in the caption, each verified against the image."
    )
    human_subject_count: int = Field(ge=0)
    mapped_subjects_usable: bool
    ambiguity_reason: str | None = None
    concept_boundary_violation: bool = Field(
        description="A trait reserved for a trigger was described in the caption."
    )
    unsupported_inference: bool = Field(
        description="The caption asserts something the image cannot support (age, biography, audio)."
    )
    subject_ambiguity: bool
    image_caption_mismatch: bool = Field(
        description="Any claim in the ledger is not verified."
    )
    another_person_described_as_trigger: bool
    trigger_subject_visible_but_unbound: bool = Field(
        description=(
            "A person matching a configured trigger's locator is visible in the crop but the "
            "caption describes them without that trigger. The mapping is incomplete."
        )
    )
    quoted_text_present: bool = Field(
        description="The caption quotes readable text (labels, logos, signs) verbatim."
    )
    reasons: list[str] = Field(
        description="Specific reasons for the verdict, approvals included. Never empty."
    )
