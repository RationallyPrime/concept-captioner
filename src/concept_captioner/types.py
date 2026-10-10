"""Shared value types. Nothing in here knows about a provider, a skill, or a person."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Sample:
    """One training target as the pipeline sees it: an id, bytes, and a suffix for encoding."""

    sample_id: str
    data: bytes
    suffix: str


class ConfigurationError(ValueError):
    pass
