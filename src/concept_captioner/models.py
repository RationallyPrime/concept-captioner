"""Spec string or ``EndpointSpec`` -> pydantic-ai ``Model`` + ``ModelSettings`` + output mode.

Specs are pydantic-ai ``provider:model`` strings::

    google:gemini-3.8-flash
    anthropic:claude-opus-5-5
    openai:gpt-5.2
    openrouter:anthropic/claude-sonnet-4-6
    vercel:anthropic/claude-sonnet-5-5
    gateway/anthropic:claude-opus-5-5      (Pydantic AI Gateway; upstreams below)
    vllm:Qwen/Qwen3-VL-32B-Instruct        (base_url from the spec or VLLM_BASE_URL)

Anything else is passed to ``pydantic_ai.models.infer_model`` unchanged. Hosted providers read
their own keys, except ``kind: openai``, whose ``OPENAI_API_KEY`` this module reads itself to pin
the origin (below); the vLLM key is sent only to the user-configured ``VLLM_BASE_URL`` host.

Pydantic AI Gateway upstreams are a finite set, ``GATEWAY_UPSTREAMS`` below, and this is the one
place it is written down. ``openai``, ``openai-responses`` and the alias ``responses`` use the
Responses API; ``openai-chat`` and the alias ``chat`` use Chat Completions; ``google`` and
``google-cloud`` both reach Vertex. Any other ``gateway/<upstream>`` (``groq``, ``bedrock``,
``converse``) is a configuration error: those need SDKs this package does not install, and the
macOS app accepts the same finite set, so a job file means the same thing in both.

Origins. ``kind: openai`` and ``kind: anthropic`` are pinned to https://api.openai.com/v1 and
https://api.anthropic.com in code (owner decision). ``OPENAI_BASE_URL`` and
``ANTHROPIC_BASE_URL`` are ignored on purpose: the provider SDKs would otherwise send the user's
real key and every training image to whatever host an inherited shell variable names, and the
app, which has no environment, would send the same job somewhere else. Any other
OpenAI-compatible server (a proxy, a mock, a pod) is ``kind: vllm`` with an explicit
``base_url``, where the key boundary below is spelled out.

A job file is data that may have been downloaded (``hf fetch-job``), so a ``base_url`` in it is
untrusted. Two rules keep a stored key from being sent to a host the file chose:

- ``kind: openai`` always talks to api.openai.com; a ``base_url`` on it is an error. Any other
  OpenAI-compatible server is ``kind: vllm``, whose key (``VLLM_API_KEY``) the user set for
  custom endpoints and nothing else. To any other vLLM host the request carries no
  ``Authorization`` header at all.
- A custom ``base_url`` must be https, or http to a loopback / private-network host.

Every OpenAI Responses route (``kind: openai`` and the gateway's Responses upstreams) is sent
with ``store`` false, so OpenAI does not retain captions or images, matching the app.
"""

from __future__ import annotations

import ipaddress
import os
import typing
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlsplit

import httpx2
from pydantic import BaseModel
from pydantic_ai import NativeOutput, PromptedOutput, ToolOutput, UserError
from pydantic_ai.models import Model, infer_model
from pydantic_ai.models.openai import OpenAIResponsesModel
from pydantic_ai.settings import ModelSettings

from .job import EndpointSpec, OutputMode, ThinkingLevel
from .types import ConfigurationError

GATEWAY_UPSTREAMS = frozenset(
    {
        "openai",
        "openai-responses",
        "responses",
        "openai-chat",
        "chat",
        "anthropic",
        "google",
        "google-cloud",
    }
)
"""The Pydantic AI Gateway upstreams a ``gateway/<upstream>:<model>`` spec may name."""

OPENAI_ORIGIN = "https://api.openai.com/v1"
ANTHROPIC_ORIGIN = "https://api.anthropic.com"


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
    if any(char.isspace() or ord(char) < 32 or char == "\\" for char in url):
        raise ConfigurationError("base_url must not contain whitespace, controls or backslashes")
    try:
        parts = urlsplit(url)
        _ = parts.port  # validate malformed / out-of-range ports before a client parses them
    except ValueError:
        raise ConfigurationError("base_url is not a valid URL") from None
    if not parts.hostname:
        raise ConfigurationError(f"base_url {url!r} has no host")
    if parts.username is not None or parts.password is not None or "%" in parts.netloc:
        raise ConfigurationError("base_url must not contain userinfo or an escaped host")
    try:
        normalized = httpx2.URL(url)
    except (httpx2.InvalidURL, ValueError):
        raise ConfigurationError("base_url is not a valid URL") from None
    # This is the SDK's own URL parser: Unicode full stops and IDNA must be normalized
    # before deciding whether a name is local, and the same URL goes to the HTTP client.
    if normalized.scheme == "https":
        return str(normalized)
    if normalized.scheme == "http" and _private_host(normalized.host):
        return str(normalized)
    raise ConfigurationError(
        f"base_url {url!r} must be https, or http to a loopback/private address; images and the "
        "endpoint key would otherwise travel in clear text to a public host"
    )


async def _drop_authorization(request: httpx2.Request) -> None:
    # A request hook runs for every send, redirects included, after the SDK has set its headers.
    request.headers.pop("Authorization", None)


def _model(spec: EndpointSpec, http_client: httpx2.AsyncClient | None) -> Model:
    if spec.kind == "openai" and spec.base_url:
        raise ConfigurationError(
            "kind: openai always talks to api.openai.com and takes no base_url; for another "
            "OpenAI-compatible server use kind: vllm with base_url (its key is VLLM_API_KEY)"
        )
    if spec.kind == "vllm":
        from pydantic_ai.models import create_async_httpx2_client
        from pydantic_ai.models.openai import OpenAIChatModel
        from pydantic_ai.providers.vllm import VLLMProvider

        configured = os.getenv("VLLM_BASE_URL")
        target = spec.base_url or configured
        if not target:
            raise ConfigurationError("kind vllm needs base_url or VLLM_BASE_URL")
        base_url = check_base_url(target)
        host = urlsplit(base_url).hostname
        configured_host = urlsplit(check_base_url(configured)).hostname if configured else None
        key = os.getenv("VLLM_API_KEY", "") if host == configured_host else ""
        client = http_client or create_async_httpx2_client()
        if not key:
            # The SDK insists on some key and would otherwise read OPENAI_API_KEY / VLLM_API_KEY
            # itself, so it gets a placeholder that never leaves the process: the hook removes the
            # header before every send.
            hooks = client.event_hooks
            if _drop_authorization not in hooks["request"]:
                client.event_hooks = {**hooks, "request": [*hooks["request"], _drop_authorization]}
        provider = VLLMProvider(base_url=base_url, api_key=key or "unused", http_client=client)
        return OpenAIChatModel(spec.model, provider=provider)
    if spec.base_url:
        raise ConfigurationError(f"base_url is only meaningful for kind vllm, not {spec.kind!r}")
    if spec.kind.startswith("gateway/") and spec.kind[len("gateway/") :] not in GATEWAY_UPSTREAMS:
        raise ConfigurationError(
            f"{spec.kind!r} is not a supported gateway upstream; use one of "
            + ", ".join(f"gateway/{name}" for name in sorted(GATEWAY_UPSTREAMS))
        )
    if http_client is not None and spec.kind not in {"openai", "anthropic"}:
        raise ConfigurationError(
            f"http_client applies to kinds openai, anthropic and vllm, not {spec.kind!r}"
        )
    try:
        if spec.kind == "openai":
            from pydantic_ai.providers.openai import OpenAIProvider

            key = os.getenv("OPENAI_API_KEY")
            if not key:
                raise UserError("Set OPENAI_API_KEY to use the OpenAI provider")
            return OpenAIResponsesModel(
                spec.model,
                provider=OpenAIProvider(
                    base_url=OPENAI_ORIGIN, api_key=key, http_client=http_client
                ),
            )
        if spec.kind == "anthropic":
            from pydantic_ai.models.anthropic import AnthropicModel
            from pydantic_ai.providers.anthropic import AnthropicProvider

            return AnthropicModel(
                spec.model,
                provider=AnthropicProvider(base_url=ANTHROPIC_ORIGIN, http_client=http_client),
            )
        return infer_model(spec.spec)
    except UserError as error:
        hint = " (Gemini is kind: google)" if spec.kind == "gemini" else ""
        raise ConfigurationError(f"{error}{hint}") from None


_PRIVACY_BODY_KEYS = frozenset({"store", "metadata", "user", "safety_identifier"})
"""Request-body keys that control what the provider retains or attributes; never from a job file."""

JOB_SETTING_KEYS = frozenset(typing.get_type_hints(ModelSettings))
"""The settings keys a job file may carry: pydantic-ai's unified ``ModelSettings`` and nothing else.

Provider-prefixed keys (``openai_store``, ``openai_user``, ``anthropic_*``...) are refused, as the
Swift core refuses them (CORE-SPEC, RequestSettings): a job file is portable between the two
implementations, and the provider-specific keys include ones that control what a provider retains
or attributes, which a downloaded file must not be able to set.
"""


def _settings(spec: EndpointSpec, thinking: ThinkingLevel) -> ModelSettings:
    settings: dict[str, Any] = dict(spec.settings)
    for key in settings:
        if key not in JOB_SETTING_KEYS:
            raise ConfigurationError(
                f"job setting {key!r} is not a job-file setting; provider-prefixed settings are "
                "not portable and are refused in both implementations. Allowed: "
                + ", ".join(sorted(JOB_SETTING_KEYS))
            )
    for header in settings.get("extra_headers") or {}:
        name = header.lower().replace("-", "").replace("_", "")
        if (
            "authorization" in name
            or "apikey" in name
            or name.endswith("token")
            or name in {"cookie", "setcookie", "host"}
        ):
            raise ConfigurationError(f"job setting header {header!r} is not allowed")
    for key in settings.get("extra_body") or {}:
        if str(key).lower().replace("-", "_") in _PRIVACY_BODY_KEYS:
            # extra_body is merged over the request last, so a downloaded job could switch
            # provider-side retention back on with it. Retention is not the job file's to set.
            raise ConfigurationError(f"job setting extra_body may not set {key!r}")
    if thinking != "none":
        settings.setdefault("thinking", thinking)
    return ModelSettings(**settings)  # type: ignore[typeddict-item]


def resolve(
    spec: str | EndpointSpec,
    *,
    thinking: ThinkingLevel = "none",
    http_client: httpx2.AsyncClient | None = None,
) -> Resolved:
    """Build the model for ``spec``.

    ``http_client`` replaces pydantic-ai's default HTTP client for the providers this module builds
    itself (``openai``, ``anthropic``, ``vllm``); tests pass one with a mock transport. Pass a fresh
    client per call: on a vLLM route that gets no key, the client gains a request hook that strips
    ``Authorization`` from every request it sends afterwards, for any endpoint.
    """
    endpoint = parse_spec(spec) if isinstance(spec, str) else spec
    settings = _settings(endpoint, thinking)
    model = _model(endpoint, http_client)
    if isinstance(model, OpenAIResponsesModel):
        # Retention is not the job file's to set: off on every Responses route, after the job's
        # own keys have been validated above.
        settings["openai_store"] = False
    return Resolved(
        model=model,
        settings=settings,
        output_mode=endpoint.output_mode,
        requested=endpoint.model,
        concurrency=endpoint.concurrency,
    )
