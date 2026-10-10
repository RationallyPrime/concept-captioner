"""Endpoint registry. A spec string or mapping builds a fully wrapped endpoint.

Spec strings::

    gemini:gemini-3.8-flash
    openai:http://localhost:8000/v1#Qwen/Qwen3-VL-32B-Instruct
    openai:https://openrouter.ai/api/v1#google/gemma-3-27b-it
    transformers:Qwen/Qwen3-VL-8B-Instruct
    fake:any-name

Mappings (from a job file) take the same ``kind`` plus keyword options for the adapter.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from ..types import ConfigurationError
from .base import (
    ModelEndpoint,
    RateLimited,
    Recording,
    RecordSink,
    Retrying,
    SchemaEnforcer,
    extract_json_object,
    parse_into,
)
from .fake import FakeEndpoint

__all__ = [
    "FakeEndpoint",
    "ModelEndpoint",
    "RateLimited",
    "Recording",
    "Retrying",
    "SchemaEnforcer",
    "build_endpoint",
    "extract_json_object",
    "parse_into",
    "parse_spec",
    "register",
]

_FACTORIES: dict[str, Callable[..., ModelEndpoint]] = {}


def register(kind: str, factory: Callable[..., ModelEndpoint]) -> None:
    _FACTORIES[kind] = factory


def _gemini(model: str, **options: Any) -> ModelEndpoint:
    from .gemini import GeminiEndpoint

    return GeminiEndpoint(model, **options)


def _openai(model: str, *, base_url: str, **options: Any) -> ModelEndpoint:
    from .openai_compat import OpenAICompatibleEndpoint

    return OpenAICompatibleEndpoint(model, base_url=base_url, **options)


def _transformers(model: str, **options: Any) -> ModelEndpoint:
    from .transformers_local import TransformersEndpoint

    return TransformersEndpoint(model, **options)


def _fake(model: str, **options: Any) -> ModelEndpoint:
    responder = options.pop("responder", None)
    if responder is None:
        raise ConfigurationError("fake endpoint needs a responder")
    return FakeEndpoint(responder, model=model, **options)


register("gemini", _gemini)
register("openai", _openai)
register("transformers", _transformers)
register("fake", _fake)


def parse_spec(spec: str) -> dict[str, Any]:
    """``kind:target`` where target is a model id, or ``base_url#model`` for openai."""
    kind, sep, target = spec.partition(":")
    if not sep or not kind or not target:
        raise ConfigurationError(f"endpoint spec must look like kind:model, got {spec!r}")
    if kind == "openai":
        base_url, hashsep, model = target.rpartition("#")
        if not hashsep or not model:
            raise ConfigurationError("openai spec must be openai:<base_url>#<model>")
        return {"kind": kind, "model": model, "base_url": base_url}
    return {"kind": kind, "model": target}


def build_endpoint(
    spec: str | dict[str, Any],
    *,
    concurrency: int = 4,
    min_interval: float = 0.0,
    retries: int = 4,
    record: RecordSink | None = None,
    enforce_schema: bool = True,
) -> ModelEndpoint:
    """Instantiate an adapter and wrap it: Retrying(RateLimited(Recording(SchemaEnforcer(x))))."""
    config = dict(parse_spec(spec)) if isinstance(spec, str) else dict(spec)
    kind = config.pop("kind", None)
    model = config.pop("model", None)
    if kind not in _FACTORIES:
        raise ConfigurationError(f"unknown endpoint kind {kind!r}; known: {sorted(_FACTORIES)}")
    if not isinstance(model, str) or not model.strip():
        raise ConfigurationError("endpoint needs a model id")
    endpoint: ModelEndpoint = _FACTORIES[kind](model, **config)
    if enforce_schema:
        endpoint = SchemaEnforcer(endpoint)
    if record is not None:
        endpoint = Recording(endpoint, record)
    endpoint = RateLimited(endpoint, concurrency=concurrency, min_interval=min_interval)
    if retries > 1:
        endpoint = Retrying(endpoint, attempts=retries)
    return endpoint
