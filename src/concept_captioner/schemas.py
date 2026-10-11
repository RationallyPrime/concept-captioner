"""Structured responses from the captioner and the (optional) critic."""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field


class Caption(BaseModel):
    """What the captioner returns. ``caption`` is the training text and nothing else."""

    model_config = ConfigDict(extra="forbid")

    caption: str = Field(description="The training caption in the selected profile's format.")
    usable: bool = Field(
        default=True,
        description=(
            "False when the declared training target cannot be found in the sample. "
            "Then leave the caption empty and explain in note."
        ),
    )
    note: str | None = Field(default=None, description="Why the sample is not usable.")


class Critique(BaseModel):
    """What the critic returns."""

    model_config = ConfigDict(extra="forbid")

    approved: bool
    notes: list[str] = Field(
        default_factory=list,
        description="What the captioner must change, when not approved. Specific and short.",
    )
