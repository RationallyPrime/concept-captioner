"""The Job: concepts, per-sample subject mappings, the skill and profile, the endpoints.

A job is user data that lives beside the dataset it describes (or inside the Hugging Face
dataset repo, see ``sources.hf``). The package itself has no notion of any particular person,
style, object or motion.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Literal

import yaml
from pydantic import BaseModel, ConfigDict, Field, PrivateAttr, field_validator, model_validator

from .types import ConfigurationError

TargetConcept = Literal[
    "facial_identity", "full_identity", "style", "object", "motion", "character_design", "custom"
]
ThinkingLevel = Literal["none", "minimal", "low", "medium", "high", "xhigh"]
OutputMode = Literal["native", "tool", "prompted"]


def _literal_text(value: str, what: str) -> str:
    if not isinstance(value, str) or not value.strip() or value != value.strip():
        raise ValueError(f"{what} must be nonblank text without surrounding whitespace")
    if any(ord(char) < 32 for char in value):
        raise ValueError(f"{what} must not contain control characters")
    return value


class Concept(BaseModel):
    """What one trigger stands for, and where its boundary lies."""

    model_config = ConfigDict(extra="forbid")

    trigger: str
    class_noun: str = "person"
    target_concept: TargetConcept = "facial_identity"
    traits_to_learn: list[str] = Field(default_factory=lambda: ["distinctive facial identity"])
    attributes_to_describe: list[str] = Field(
        default_factory=lambda: [
            "clothing and removable accessories",
            "hair presentation",
            "expression and gaze",
            "pose",
            "setting",
            "lighting",
            "framing and visible image treatment",
        ]
    )
    explicit_boundary_decisions: dict[str, str] = Field(default_factory=dict)

    @model_validator(mode="before")
    @classmethod
    def _category_defaults(cls, value: Any) -> Any:
        if not isinstance(value, dict):
            return value
        defaults = {
            "full_identity": (
                "the person's enduring face and physique",
                [
                    "expression and gaze",
                    "pose and action",
                    "permitted clothing changes",
                    "setting",
                    "lighting",
                    "framing",
                ],
            ),
            "character_design": (
                "the character's distinctive appearance and design",
                [
                    "expression and gaze",
                    "pose and action",
                    "permitted clothing changes",
                    "setting",
                    "lighting",
                    "framing",
                ],
            ),
            "style": (
                "the visual style, including its rendering, texture and palette",
                [
                    "subject matter",
                    "objects",
                    "actions",
                    "spatial arrangement",
                    "visible scene content",
                ],
            ),
            "object": (
                "the object's distinctive design",
                ["placement", "orientation", "use", "surroundings", "lighting", "occlusion"],
            ),
            "motion": (
                "the defining movement pattern",
                [
                    "performer",
                    "clothing",
                    "scene",
                    "framing",
                    "lighting",
                    "independent start and end state",
                ],
            ),
            "custom": (
                "the concept described by the user",
                ["observable details outside the stated concept"],
            ),
        }
        category = value.get("target_concept")
        if isinstance(category, str) and (selected := defaults.get(category)):
            value = dict(value)
            value.setdefault(
                "class_noun",
                {
                    "full_identity": "person",
                    "character_design": "character",
                    "custom": "concept",
                }.get(category, category),
            )
            value.setdefault("traits_to_learn", [selected[0]])
            value.setdefault("attributes_to_describe", selected[1])
        return value

    @field_validator("trigger", "class_noun")
    @classmethod
    def _literal(cls, value: str) -> str:
        return _literal_text(value, "trigger/class_noun")

    @field_validator("traits_to_learn", "attributes_to_describe")
    @classmethod
    def _nonblank_items(cls, items: list[str]) -> list[str]:
        if any(not isinstance(item, str) or not item.strip() for item in items):
            raise ValueError("list items must be nonblank strings")
        return items


class EndpointSpec(BaseModel):
    """A pydantic-ai model: ``kind`` is the provider prefix, exactly as pydantic-ai spells it.

    Secrets are never fields; each provider reads its own environment variable.
    """

    model_config = ConfigDict(extra="forbid")

    kind: str
    model: str
    base_url: str | None = None
    output_mode: OutputMode = "native"
    settings: dict[str, Any] = Field(default_factory=dict)
    concurrency: int = Field(default=4, ge=1, le=64)

    @field_validator("kind", "model")
    @classmethod
    def _nonblank(cls, value: str) -> str:
        return _literal_text(value, "endpoint kind/model")

    @property
    def spec(self) -> str:
        return f"{self.kind}:{self.model}"


class Endpoints(BaseModel):
    model_config = ConfigDict(extra="forbid")

    captioner: EndpointSpec
    critic: EndpointSpec | None = None  # absent: no critic pass


class Job(BaseModel):
    """A captioning job: concepts, per-sample subject mappings, skill, profile, endpoints."""

    model_config = ConfigDict(extra="forbid")
    _directory: Path | None = PrivateAttr(default=None)

    @property
    def directory(self) -> Path | None:
        """Loading context only; never a job field or part of content equality."""
        return self._directory

    def __eq__(self, other: object) -> bool:
        if type(other) is not type(self):
            return NotImplemented
        return self.model_dump() == other.model_dump()

    skill: str | None = None  # a skill directory; None: the bundled default
    profile: str = "h3-still"  # a profile in the skill, or a path to a .md file
    concepts: list[Concept]
    samples: dict[str, dict[str, str] | None] = Field(default_factory=dict)
    single_subject_only: bool = False
    endpoints: Endpoints | None = None
    captioner_thinking: ThinkingLevel = "low"
    critic_thinking: ThinkingLevel = "high"
    policy_overrides: dict[str, str] = Field(default_factory=dict)

    @model_validator(mode="after")
    def _check(self) -> Job:
        triggers = [concept.trigger for concept in self.concepts]
        if len(set(triggers)) != len(triggers):
            raise ValueError("concept triggers must be unique")
        for sample_id, mapping in self.samples.items():
            self._check_mapping(sample_id, mapping)
        return self

    def require_concepts(self) -> None:
        """Reject a draft job when starting work that needs a trigger."""
        if not self.concepts:
            raise ConfigurationError("Add a concept before captioning or training.")

    def _check_mapping(self, sample_id: str, mapping: dict[str, str] | None) -> None:
        if mapping is None:
            return
        if not mapping:
            raise ValueError(f"sample {sample_id!r}: mapping must name at least one trigger")
        unknown = set(mapping) - set(self.triggers)
        if unknown:
            raise ValueError(f"sample {sample_id!r}: unknown triggers {sorted(unknown)}")
        if any(not isinstance(v, str) or not v.strip() for v in mapping.values()):
            raise ValueError(f"sample {sample_id!r}: each trigger needs a locator sentence")
        if self.single_subject_only and len(mapping) != 1:
            raise ValueError("single_subject_only jobs map exactly one trigger per sample")

    @property
    def triggers(self) -> list[str]:
        return [concept.trigger for concept in self.concepts]

    def concept(self, trigger: str) -> Concept:
        for concept in self.concepts:
            if concept.trigger == trigger:
                return concept
        raise KeyError(trigger)

    def mapping_for(self, sample_id: str) -> dict[str, str] | None:
        return self.samples.get(sample_id)

    def unmapped(self, sample_ids: list[str]) -> list[str]:
        """Sample ids with no mapping: held for review, never captioned."""
        return [sid for sid in sample_ids if self.samples.get(sid) is None]

    def set_mapping(self, sample_id: str, mapping: dict[str, str] | None) -> None:
        self._check_mapping(sample_id, mapping)
        self.samples[sample_id] = mapping

    def sample_view(self, mapping: dict[str, str]) -> dict[str, Any]:
        """What the model sees for one sample: only the mapped concepts and their locators."""
        return {
            "training": {"profile": self.profile, "trigger_handling": "literal"},
            "concepts": [
                concept.model_dump() for concept in self.concepts if concept.trigger in mapping
            ],
            "inputs": {
                "actual_trainer_conditioning": [],
                "audio_status": "not_applicable",
                "subject_mapping": mapping,
                "evidence": "attached_target_image",
            },
            "single_subject_only": self.single_subject_only,
            "output": {"caption_language": "English", "delivery": "json_caption_field"},
        }

    @classmethod
    def load(cls, path: str | Path) -> Job:
        path = Path(path).expanduser().resolve()
        raw = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(raw, dict):
            raise ConfigurationError("job file must be a YAML mapping")
        try:
            job = cls.model_validate(raw)
            job._directory = path.parent
            return job
        except ValueError as error:
            raise ConfigurationError(str(error)) from None

    def dump(self) -> str:
        return yaml.safe_dump(self.model_dump(mode="json", exclude_none=True), sort_keys=False)

    def save(self, path: str | Path) -> None:
        Path(path).write_text(self.dump(), encoding="utf-8")
