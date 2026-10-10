"""Shared value types. Nothing in here knows about a provider, a profile, or a person."""

from __future__ import annotations

import hashlib
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any, Literal

from pydantic import BaseModel

ThinkingLevel = Literal["none", "low", "medium", "high"]


@dataclass(frozen=True, slots=True)
class ImageRef:
    """In-memory image bytes. Never a path: the pipeline hands endpoints a derivative, not a file."""

    data: bytes
    mime: str

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.data).hexdigest()


@dataclass(frozen=True, slots=True)
class Request:
    """One multimodal, optionally schema-constrained call."""

    system: str
    user: str
    images: Sequence[ImageRef] = ()
    response_schema: type[BaseModel] | None = None
    thinking: ThinkingLevel = "none"
    max_output_tokens: int = 4096
    temperature: float | None = None
    seed: int | None = None

    @property
    def sha256(self) -> str:
        parts = [
            self.system,
            self.user,
            *(image.sha256 for image in self.images),
            self.response_schema.__name__ if self.response_schema else "",
            self.thinking,
            str(self.max_output_tokens),
            str(self.temperature),
            str(self.seed),
        ]
        return hashlib.sha256("\x1f".join(parts).encode("utf-8")).hexdigest()


@dataclass(frozen=True, slots=True)
class Usage:
    input_tokens: int | None = None
    output_tokens: int | None = None
    thinking_tokens: int | None = None


@dataclass(frozen=True, slots=True)
class Response:
    """What came back. `served_model` is load-bearing: the runner compares it to the request."""

    text: str | None
    parsed: BaseModel | None
    requested_model: str
    served_model: str | None
    latency_ms: int
    request_sha256: str
    usage: Usage | None = None
    raw: Mapping[str, Any] = field(default_factory=dict)

    @property
    def model_matches(self) -> bool:
        return self.served_model is not None and self.served_model == self.requested_model


@dataclass(frozen=True, slots=True)
class Capabilities:
    images: bool = True
    structured_output: bool = False
    thinking: bool = False
    seed: bool = False
    max_images_per_request: int = 1


@dataclass(frozen=True, slots=True)
class Sample:
    """One training target as the pipeline sees it: an id, bytes, and a suffix for encoding."""

    sample_id: str
    data: bytes
    suffix: str

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.data).hexdigest()


class ModelMismatch(RuntimeError):
    """The provider served a different model than was requested."""


class EndpointError(RuntimeError):
    """A provider call failed. The message never contains credentials."""


class ConfigurationError(ValueError):
    pass


class IntegrityError(RuntimeError):
    pass
