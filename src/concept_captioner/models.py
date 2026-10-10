"""Spec string or ``EndpointSpec`` -> pydantic-ai ``Model`` + ``ModelSettings`` + output mode.

Specs are pydantic-ai ``provider:model`` strings::

    google:gemini-3.8-flash
    anthropic:claude-opus-5-5
    openai:gpt-5.2
    openrouter:anthropic/claude-sonnet-4-6
    vllm:Qwen/Qwen3-VL-32B-Instruct        (base_url from the spec or VLLM_BASE_URL)

Anything else is passed to ``pydantic_ai.models.infer_model`` unchanged. Keys come from each
provider's own environment variable; this module never touches them.

A job file is data that may have been downloaded (``hf fetch-job``), so a ``base_url`` in it is
untrusted. Two rules keep a stored key from being sent to a host the file chose:

- ``kind: openai`` always talks to api.openai.com; a ``base_url`` on it is an error. Any other
  OpenAI-compatible server is ``kind: vllm``, whose key (``VLLM_API_KEY``) the user set for
  custom endpoints and nothing else.
- A custom ``base_url`` must be https, or http to a loopback / private-network host.
"""

from __future__ import annotations

import ipaddress
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlsplit

from pydantic import BaseModel
from pydantic_ai import NativeOutput, PromptedOutput, ToolOutput, UserError
from pydantic_ai.models import Model, infer_model
from pydantic_ai.settings import ModelSettings

from .job import EndpointSpec, OutputMode, ThinkingLevel
from .types import ConfigurationError


@dataclass(frozen=True)
class Resolved:
    model: Model
    settings: ModelSettings
    output_mode: OutputMode
    requested: str  # the model name as requested, for the response record
    concurrency: int = 4

    def output_type(self, schema: type[BaseModel]) -> Any:
        if self.output_mode == "native":
            return NativeOutput(schema)
        if self.output_mode == "tool":
            return ToolOutput(schema)
        return PromptedOutput(schema)


def parse_spec(spec: str) -> EndpointSpec:
    kind, sep, model = spec.partition(":")
    if not sep or not kind.strip() or not model.strip():
        raise ConfigurationError(f"endpoint spec must look like provider:model, got {spec!r}")
    return EndpointSpec(kind=kind.strip(), model=model.strip())


def _private_host(host: str) -> bool:
    # single-label names (docker service names, LAN hosts) never resolve through public DNS
    if "." not in host.strip("[]") and ":" not in host.strip("[]"):
        return True
    if host in {"localhost.localdomain"} or host.endswith((".local", ".internal")):
        return True
    try:
        address = ipaddress.ip_address(host.strip("[]"))
    except ValueError:
        return False
    return address.is_loopback or address.is_private or address.is_link_local


def check_base_url(url: str) -> str:
    """Accept https anywhere, or plain http only to a loopback / private host."""
    parts = urlsplit(url)
    if not parts.hostname:
        raise ConfigurationError(f"base_url {url!r} has no host")
    if parts.scheme == "https":
        return url
    if parts.scheme == "http" and _private_host(parts.hostname):
        return url
    raise ConfigurationError(
        f"base_url {url!r} must be https, or http to a loopback/private address; images and the "
        "endpoint key would otherwise travel in clear text to a public host"
    )


def _model(spec: EndpointSpec) -> Model:
    if spec.kind == "openai" and spec.base_url:
        raise ConfigurationError(
            "kind: openai always talks to api.openai.com and takes no base_url; for another "
            "OpenAI-compatible server use kind: vllm with base_url (its key is VLLM_API_KEY)"
        )
    if spec.kind == "vllm" and spec.base_url:
        from pydantic_ai.models.openai import OpenAIChatModel
        from pydantic_ai.providers.vllm import VLLMProvider

        base_url = check_base_url(spec.base_url)
        return OpenAIChatModel(spec.model, provider=VLLMProvider(base_url=base_url))
    if spec.base_url:
        raise ConfigurationError(f"base_url is only meaningful for kind vllm, not {spec.kind!r}")
    try:
        return infer_model(spec.spec)
    except UserError as error:
        hint = " (Gemini is kind: google)" if spec.kind == "gemini" else ""
        raise ConfigurationError(f"{error}{hint}") from None


def _settings(spec: EndpointSpec, thinking: ThinkingLevel) -> ModelSettings:
    settings: dict[str, Any] = dict(spec.settings)
    if thinking != "none":
        settings.setdefault("thinking", thinking)
    return ModelSettings(**settings)  # type: ignore[typeddict-item]


def resolve(spec: str | EndpointSpec, *, thinking: ThinkingLevel = "none") -> Resolved:
    endpoint = parse_spec(spec) if isinstance(spec, str) else spec
    return Resolved(
        model=_model(endpoint),
        settings=_settings(endpoint, thinking),
        output_mode=endpoint.output_mode,
        requested=endpoint.model,
        concurrency=endpoint.concurrency,
    )
