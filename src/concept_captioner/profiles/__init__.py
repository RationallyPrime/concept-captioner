"""Profile registry. Built-ins by name; a directory path loads a user profile."""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

from ..types import ConfigurationError
from .base import (
    CaptionProfile,
    DirectoryProfile,
    FluxImageProfile,
    FormatCheck,
    H3StillProfile,
    LtxImageProfile,
    PlainProfile,
    quoted_text_present,
    word_count,
)

__all__ = [
    "CaptionProfile",
    "DirectoryProfile",
    "FluxImageProfile",
    "FormatCheck",
    "H3StillProfile",
    "LtxImageProfile",
    "PlainProfile",
    "load_profile",
    "quoted_text_present",
    "register",
    "word_count",
]

_BUILTINS: dict[str, Callable[[], CaptionProfile]] = {
    "h3-still": H3StillProfile,
    "flux-image": FluxImageProfile,
    "ltx-image": LtxImageProfile,
    "plain": PlainProfile,
}


def register(name: str, factory: Callable[[], CaptionProfile]) -> None:
    _BUILTINS[name] = factory


def load_profile(name_or_path: str) -> CaptionProfile:
    if name_or_path in _BUILTINS:
        return _BUILTINS[name_or_path]()
    path = Path(name_or_path)
    if path.is_dir() and (path / "profile.yaml").exists():
        return DirectoryProfile(path)
    raise ConfigurationError(
        f"unknown profile {name_or_path!r}; built-ins: {sorted(_BUILTINS)}, or a directory with profile.yaml"
    )
