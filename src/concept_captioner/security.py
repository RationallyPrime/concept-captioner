"""Credentials come from the process environment; redaction runs before anything is persisted."""

from __future__ import annotations

import os
import re
from collections.abc import Mapping
from typing import Any
from urllib.parse import quote, quote_plus

from .types import ConfigurationError, EndpointError

_CREDENTIAL_SHAPES = (
    re.compile(r"AIza[0-9A-Za-z_-]{20,}"),  # Google API keys
    re.compile(r"\bhf_[A-Za-z0-9]{20,}"),  # Hugging Face tokens
    re.compile(r"\bsk-[A-Za-z0-9_-]{20,}"),  # OpenAI-style keys
    re.compile(
        r"(?i)\b(api[_-]?key|key|x-goog-api-key|authorization|token)(\s*(?:=|:)\s*)([^\s,;&\"']+)"
    ),
    re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"),
)


def env_secret(name: str, environment: Mapping[str, str] | None = None) -> str:
    """Return a nonblank environment variable without ever formatting it into a message."""
    source = os.environ if environment is None else environment
    value = source.get(name)
    if value is None or not value.strip():
        raise ConfigurationError(f"{name} must be set in the process environment")
    return value


def optional_env_secret(name: str, environment: Mapping[str, str] | None = None) -> str | None:
    source = os.environ if environment is None else environment
    value = source.get(name)
    return value if value and value.strip() else None


def redact_text(value: object, *secrets: str | None) -> str:
    text = str(value)
    for secret in secrets:
        if not secret:
            continue
        for candidate in {secret, quote(secret, safe=""), quote_plus(secret, safe="")}:
            text = text.replace(candidate, "[REDACTED]")
    text = _CREDENTIAL_SHAPES[0].sub("[REDACTED]", text)
    text = _CREDENTIAL_SHAPES[1].sub("[REDACTED]", text)
    text = _CREDENTIAL_SHAPES[2].sub("[REDACTED]", text)
    text = _CREDENTIAL_SHAPES[3].sub(lambda m: f"{m.group(1)}{m.group(2)}[REDACTED]", text)
    return _CREDENTIAL_SHAPES[4].sub("Bearer [REDACTED]", text)


def redact_data(value: Any, *secrets: str | None) -> Any:
    if isinstance(value, str):
        return redact_text(value, *secrets)
    if isinstance(value, Mapping):
        return {redact_text(k, *secrets): redact_data(v, *secrets) for k, v in value.items()}
    if isinstance(value, list | tuple):
        return [redact_data(item, *secrets) for item in value]
    return value


def classify_provider_error(exc: BaseException, *secrets: str | None) -> EndpointError:
    """Build a chain-free error that carries a stable code and no credential material."""
    safe = redact_text(exc, *secrets).casefold()
    if "timeout" in safe or "timed out" in safe:
        code = "timeout"
    elif "429" in safe or "rate limit" in safe or "resource exhausted" in safe:
        code = "rate_limited"
    elif any(m in safe for m in ("401", "403", "unauthorized", "api key", "api_key", "key=")):
        code = "auth_failed"
    elif "safety" in safe or "blocked" in safe:
        code = "safety_block"
    elif any(m in safe for m in ("500", "502", "503", "server error", "overloaded")):
        code = "server_error"
    elif "connect" in safe or "connection" in safe or "refused" in safe:
        code = "connection_failed"
    else:
        code = "request_failed"
    return EndpointError(f"provider request failed: {code}")
