"""The ModelEndpoint protocol and the composable wrappers that every adapter gets for free.

An adapter implements exactly one coroutine, ``describe(request) -> Response``, and declares
its ``capabilities``. Everything cross-cutting (schema enforcement for backends without
constrained decoding, retries, rate limiting, receipts) is a wrapper that itself implements
``ModelEndpoint`` and holds another one, so a stack reads as::

    Retrying(RateLimited(Recording(GeminiEndpoint(...))))
"""

from __future__ import annotations

import asyncio
import json
import random
import re
import time
from collections.abc import Awaitable, Callable
from typing import Any, Protocol, runtime_checkable

from pydantic import BaseModel, ValidationError

from ..types import Capabilities, EndpointError, Request, Response


@runtime_checkable
class ModelEndpoint(Protocol):
    name: str
    model: str
    capabilities: Capabilities

    async def describe(self, request: Request) -> Response: ...

    async def aclose(self) -> None: ...


class _Wrapper:
    """Base for wrappers: forwards identity to the inner endpoint."""

    def __init__(self, inner: ModelEndpoint) -> None:
        self.inner = inner

    @property
    def name(self) -> str:  # type: ignore[override]
        return self.inner.name

    @property
    def model(self) -> str:  # type: ignore[override]
        return self.inner.model

    @property
    def capabilities(self) -> Capabilities:  # type: ignore[override]
        return self.inner.capabilities

    async def aclose(self) -> None:
        await self.inner.aclose()


_FENCE = re.compile(r"^\s*```(?:json)?\s*|\s*```\s*$", re.IGNORECASE)


def extract_json_object(text: str) -> dict[str, Any]:
    """Pull the first JSON object out of free text (handles fences and leading prose)."""
    stripped = _FENCE.sub("", text.strip())
    try:
        value = json.loads(stripped)
        if isinstance(value, dict):
            return value
    except json.JSONDecodeError:
        pass
    start = stripped.find("{")
    depth = 0
    for index in range(start, len(stripped)) if start >= 0 else ():
        char = stripped[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                value = json.loads(stripped[start : index + 1])
                if isinstance(value, dict):
                    return value
                break
    raise ValueError("no JSON object in response text")


def parse_into(schema: type[BaseModel], text: str) -> BaseModel:
    return schema.model_validate(extract_json_object(text))


class SchemaEnforcer(_Wrapper):
    """Give any endpoint structured output.

    Backends with native constrained decoding pass straight through. For the others, the JSON
    schema is appended to the system prompt, the reply is parsed and validated, and a failed
    parse is retried with the validation error quoted back to the model.
    """

    def __init__(self, inner: ModelEndpoint, *, parse_retries: int = 2) -> None:
        super().__init__(inner)
        self.parse_retries = parse_retries

    @property
    def capabilities(self) -> Capabilities:  # type: ignore[override]
        inner = self.inner.capabilities
        return Capabilities(
            images=inner.images,
            structured_output=True,
            thinking=inner.thinking,
            seed=inner.seed,
            max_images_per_request=inner.max_images_per_request,
        )

    async def describe(self, request: Request) -> Response:
        if request.response_schema is None or self.inner.capabilities.structured_output:
            return await self.inner.describe(request)
        schema = request.response_schema
        instruction = (
            "\n\nRESPONSE FORMAT\nReturn exactly one JSON object and nothing else. It must validate "
            "against this JSON schema:\n" + json.dumps(schema.model_json_schema(), ensure_ascii=False)
        )
        prompted = Request(
            system=request.system + instruction,
            user=request.user,
            images=request.images,
            response_schema=None,
            thinking=request.thinking,
            max_output_tokens=request.max_output_tokens,
            temperature=request.temperature,
            seed=request.seed,
        )
        last: Response | None = None
        feedback = ""
        for _ in range(self.parse_retries + 1):
            attempt = prompted if not feedback else Request(
                system=prompted.system,
                user=prompted.user + "\n\n" + feedback,
                images=prompted.images,
                thinking=prompted.thinking,
                max_output_tokens=prompted.max_output_tokens,
                temperature=prompted.temperature,
                seed=prompted.seed,
            )
            last = await self.inner.describe(attempt)
            if last.text is None:
                feedback = "The previous reply was empty. Return the JSON object."
                continue
            try:
                parsed = parse_into(schema, last.text)
            except (ValueError, ValidationError) as error:
                feedback = (
                    "The previous reply did not validate against the schema: "
                    + str(error)[:800]
                    + "\nReturn only the corrected JSON object."
                )
                continue
            return Response(
                text=last.text,
                parsed=parsed,
                requested_model=last.requested_model,
                served_model=last.served_model,
                latency_ms=last.latency_ms,
                request_sha256=request.sha256,
                usage=last.usage,
                raw=last.raw,
            )
        assert last is not None
        return last  # parsed is None; the caller treats it as an invalid payload


class Retrying(_Wrapper):
    """Exponential backoff on transient provider errors."""

    TRANSIENT = ("timeout", "rate_limited", "server_error", "connection_failed")

    def __init__(
        self,
        inner: ModelEndpoint,
        *,
        attempts: int = 4,
        base_delay: float = 1.5,
        max_delay: float = 30.0,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    ) -> None:
        super().__init__(inner)
        self.attempts = attempts
        self.base_delay = base_delay
        self.max_delay = max_delay
        self._sleep = sleep

    async def describe(self, request: Request) -> Response:
        delay = self.base_delay
        for attempt in range(1, self.attempts + 1):
            try:
                return await self.inner.describe(request)
            except EndpointError as error:
                transient = any(code in str(error) for code in self.TRANSIENT)
                if not transient or attempt == self.attempts:
                    raise
                await self._sleep(min(self.max_delay, delay * (0.5 + random.random())))
                delay *= 2
        raise AssertionError("unreachable")


class RateLimited(_Wrapper):
    """A semaphore and a minimum spacing between call starts."""

    def __init__(self, inner: ModelEndpoint, *, concurrency: int = 4, min_interval: float = 0.0) -> None:
        super().__init__(inner)
        self._semaphore = asyncio.Semaphore(concurrency)
        self._min_interval = min_interval
        self._last_start = 0.0
        self._lock = asyncio.Lock()

    async def describe(self, request: Request) -> Response:
        async with self._semaphore:
            if self._min_interval > 0:
                async with self._lock:
                    wait = self._last_start + self._min_interval - time.monotonic()
                    if wait > 0:
                        await asyncio.sleep(wait)
                    self._last_start = time.monotonic()
            return await self.inner.describe(request)


RecordSink = Callable[[dict[str, Any]], Awaitable[None] | None]


class Recording(_Wrapper):
    """Emit one receipt per call: request hash, models, latency, usage, raw payload."""

    def __init__(self, inner: ModelEndpoint, sink: RecordSink) -> None:
        super().__init__(inner)
        self._sink = sink

    async def describe(self, request: Request) -> Response:
        started = time.time()
        error: str | None = None
        response: Response | None = None
        try:
            response = await self.inner.describe(request)
            return response
        except EndpointError as exc:
            error = str(exc)
            raise
        finally:
            record = {
                "endpoint": self.inner.name,
                "requested_model": self.inner.model,
                "served_model": response.served_model if response else None,
                "request_sha256": request.sha256,
                "image_sha256": [image.sha256 for image in request.images],
                "schema": request.response_schema.__name__ if request.response_schema else None,
                "thinking": request.thinking,
                "started_at": started,
                "latency_ms": response.latency_ms if response else int((time.time() - started) * 1000),
                "usage": response.usage.__dict__ if response and response.usage else None,
                "error": error,
                "raw": dict(response.raw) if response else None,
            }
            result = self._sink(record)
            if asyncio.iscoroutine(result):
                await result
