"""A deterministic endpoint for tests and dry runs. It never touches the network."""

from __future__ import annotations

import json
import time
from collections.abc import Callable

from pydantic import BaseModel

from ..types import Capabilities, Request, Response

Responder = Callable[[Request], BaseModel | str | dict]


class FakeEndpoint:
    """Answer every request with whatever ``responder`` returns.

    ``served_model`` can be overridden to exercise the runner's model-mismatch failure path.
    """

    def __init__(
        self,
        responder: Responder,
        *,
        model: str = "fake-model",
        served_model: str | None = None,
        structured_output: bool = True,
    ) -> None:
        self.name = "fake"
        self.model = model
        self._served = served_model if served_model is not None else model
        self._responder = responder
        self.capabilities = Capabilities(
            images=True, structured_output=structured_output, thinking=True, seed=True
        )
        self.requests: list[Request] = []

    async def describe(self, request: Request) -> Response:
        self.requests.append(request)
        started = time.monotonic()
        value = self._responder(request)
        parsed: BaseModel | None = None
        if isinstance(value, BaseModel):
            parsed = value
            text = value.model_dump_json()
        elif isinstance(value, dict):
            text = json.dumps(value, ensure_ascii=False)
            if request.response_schema is not None and self.capabilities.structured_output:
                parsed = request.response_schema.model_validate(value)
        else:
            text = str(value)
        if not self.capabilities.structured_output:
            parsed = None
        return Response(
            text=text,
            parsed=parsed,
            requested_model=self.model,
            served_model=self._served,
            latency_ms=int((time.monotonic() - started) * 1000),
            request_sha256=request.sha256,
            raw={"fake": True},
        )

    async def aclose(self) -> None:
        return None
