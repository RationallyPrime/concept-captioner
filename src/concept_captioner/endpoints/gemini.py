"""Gemini adapter over the official ``google-genai`` client (async)."""

from __future__ import annotations

import time
from typing import Any

from ..security import classify_provider_error, env_secret, redact_data
from ..types import Capabilities, EndpointError, Request, Response, Usage

_THINKING = {"none": None, "low": "LOW", "medium": "MEDIUM", "high": "HIGH"}


class GeminiEndpoint:
    name = "gemini"
    capabilities = Capabilities(
        images=True, structured_output=True, thinking=True, seed=True, max_images_per_request=16
    )

    def __init__(
        self,
        model: str,
        *,
        api_key: str | None = None,
        timeout_seconds: float = 120.0,
        store: bool = False,
    ) -> None:
        self.model = model
        self._api_key = api_key or env_secret("GEMINI_API_KEY")
        if timeout_seconds <= 0:
            raise EndpointError("timeout must be positive")
        failure: EndpointError | None = None
        try:
            from google import genai
            from google.genai import types

            self._types = types
            self._client = genai.Client(
                api_key=self._api_key,
                http_options=types.HttpOptions(
                    timeout=int(timeout_seconds * 1000), extra_body={"store": store}
                ),
            )
        except Exception as exc:
            failure = classify_provider_error(exc, self._api_key)
        if failure is not None:
            raise failure

    async def describe(self, request: Request) -> Response:
        types = self._types
        parts: list[Any] = [types.Part.from_text(text=request.user)]
        for image in request.images:
            parts.append(types.Part.from_bytes(data=image.data, mime_type=image.mime))
        config: dict[str, Any] = {
            "system_instruction": request.system,
            "max_output_tokens": request.max_output_tokens,
        }
        if request.response_schema is not None:
            config["response_mime_type"] = "application/json"
            config["response_json_schema"] = request.response_schema.model_json_schema()
        level = _THINKING[request.thinking]
        if level is not None:
            config["thinking_config"] = types.ThinkingConfig(thinking_level=level)
        if request.temperature is not None:
            config["temperature"] = request.temperature
        if request.seed is not None:
            config["seed"] = request.seed
        failure: EndpointError | None = None
        started = time.monotonic()
        try:
            response = await self._client.aio.models.generate_content(
                model=self.model,
                contents=types.Content(role="user", parts=parts),
                config=types.GenerateContentConfig(**config),
            )
        except Exception as exc:
            failure = classify_provider_error(exc, self._api_key)
        if failure is not None:
            raise failure
        latency = int((time.monotonic() - started) * 1000)
        try:
            raw = response.model_dump(mode="json", exclude_none=True)
        except Exception:
            raw = {"text": getattr(response, "text", None)}
        raw = redact_data(raw, self._api_key)
        text = getattr(response, "text", None)
        parsed = None
        if request.response_schema is not None and isinstance(text, str):
            try:
                parsed = request.response_schema.model_validate_json(text)
            except Exception:
                parsed = None
        usage_meta = getattr(response, "usage_metadata", None)
        usage = (
            Usage(
                input_tokens=getattr(usage_meta, "prompt_token_count", None),
                output_tokens=getattr(usage_meta, "candidates_token_count", None),
                thinking_tokens=getattr(usage_meta, "thoughts_token_count", None),
            )
            if usage_meta is not None
            else None
        )
        return Response(
            text=text if isinstance(text, str) else None,
            parsed=parsed,
            requested_model=self.model,
            served_model=getattr(response, "model_version", None),
            latency_ms=latency,
            request_sha256=request.sha256,
            usage=usage,
            raw=raw,
        )

    async def aclose(self) -> None:
        return None
