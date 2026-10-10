"""Any ``/v1/chat/completions`` server: vLLM, SGLang, Ollama, LM Studio, OpenRouter, OpenAI.

This is the adapter for running an open-weights VLM on the same box that will train afterwards:
``vllm serve <hf-model-id>`` on the pod, point this at ``http://localhost:8000/v1``, caption,
kill vLLM, train. No SDK dependency; plain ``httpx``.
"""

from __future__ import annotations

import base64
import time
from typing import Any

import httpx

from ..security import classify_provider_error, optional_env_secret, redact_data
from ..types import Capabilities, EndpointError, Request, Response, Usage

_REASONING = {"none": None, "low": "low", "medium": "medium", "high": "high"}


class OpenAICompatibleEndpoint:
    name = "openai"

    def __init__(
        self,
        model: str,
        *,
        base_url: str,
        api_key: str | None = None,
        api_key_env: str = "OPENAI_API_KEY",
        timeout_seconds: float = 180.0,
        structured_output: bool = True,
        reasoning_effort_supported: bool = False,
        extra_body: dict[str, Any] | None = None,
    ) -> None:
        self.model = model
        self.base_url = base_url.rstrip("/")
        self._api_key = api_key or optional_env_secret(api_key_env) or "none"
        self._extra_body = extra_body or {}
        self._reasoning = reasoning_effort_supported
        self.capabilities = Capabilities(
            images=True,
            structured_output=structured_output,
            thinking=reasoning_effort_supported,
            seed=True,
            max_images_per_request=8,
        )
        self._client = httpx.AsyncClient(
            base_url=self.base_url,
            timeout=httpx.Timeout(timeout_seconds, connect=30.0),
            headers={"Authorization": f"Bearer {self._api_key}"},
        )

    def _body(self, request: Request) -> dict[str, Any]:
        content: list[dict[str, Any]] = [{"type": "text", "text": request.user}]
        for image in request.images:
            encoded = base64.b64encode(image.data).decode("ascii")
            content.append(
                {"type": "image_url", "image_url": {"url": f"data:{image.mime};base64,{encoded}"}}
            )
        body: dict[str, Any] = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": request.system},
                {"role": "user", "content": content},
            ],
            "max_tokens": request.max_output_tokens,
        }
        if request.temperature is not None:
            body["temperature"] = request.temperature
        if request.seed is not None:
            body["seed"] = request.seed
        if request.response_schema is not None and self.capabilities.structured_output:
            body["response_format"] = {
                "type": "json_schema",
                "json_schema": {
                    "name": request.response_schema.__name__,
                    "schema": request.response_schema.model_json_schema(),
                    "strict": True,
                },
            }
        effort = _REASONING[request.thinking]
        if effort and self._reasoning:
            body["reasoning_effort"] = effort
        body.update(self._extra_body)
        return body

    async def describe(self, request: Request) -> Response:
        body = self._body(request)
        failure: EndpointError | None = None
        started = time.monotonic()
        payload: dict[str, Any] = {}
        try:
            http = await self._client.post("/chat/completions", json=body)
            http.raise_for_status()
            payload = http.json()
        except Exception as exc:
            failure = classify_provider_error(exc, self._api_key)
        if failure is not None:
            raise failure
        latency = int((time.monotonic() - started) * 1000)
        choices = payload.get("choices") or []
        message = (choices[0].get("message") or {}) if choices else {}
        text = message.get("content")
        if isinstance(text, list):  # some servers return content parts
            text = "".join(part.get("text", "") for part in text if isinstance(part, dict))
        parsed = None
        if request.response_schema is not None and isinstance(text, str):
            try:
                parsed = request.response_schema.model_validate_json(text)
            except Exception:
                parsed = None
        usage_raw = payload.get("usage") or {}
        usage = Usage(
            input_tokens=usage_raw.get("prompt_tokens"),
            output_tokens=usage_raw.get("completion_tokens"),
            thinking_tokens=(usage_raw.get("completion_tokens_details") or {}).get(
                "reasoning_tokens"
            ),
        )
        return Response(
            text=text if isinstance(text, str) else None,
            parsed=parsed,
            requested_model=self.model,
            served_model=payload.get("model"),
            latency_ms=latency,
            request_sha256=request.sha256,
            usage=usage,
            raw=redact_data(payload, self._api_key),
        )

    async def aclose(self) -> None:
        await self._client.aclose()
