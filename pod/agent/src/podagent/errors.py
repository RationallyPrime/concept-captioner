"""The one error envelope every response uses (POD-SPEC §2.2)."""

from __future__ import annotations

from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse


class AgentError(Exception):
    """An error with an HTTP status and a stable ``code``."""

    status: int = 500
    code: str = "internal"

    def __init__(self, message: str, *, detail: Any = None) -> None:
        super().__init__(message)
        self.message = message
        self.detail = detail

    def envelope(self) -> dict[str, Any]:
        return {"error": {"code": self.code, "message": self.message, "detail": self.detail}}


class BadRequest(AgentError):
    status, code = 400, "bad_request"


class Unauthorized(AgentError):
    status, code = 401, "unauthorized"


class NotFound(AgentError):
    status, code = 404, "not_found"


class AlreadyRunning(AgentError):
    status, code = 409, "already_running"


class PayloadTooLarge(AgentError):
    """A request body above the agent's cap, or one sent chunked (no ``Content-Length``)."""

    status, code = 413, "payload_too_large"


class GpuBusy(AgentError):
    status, code = 409, "gpu_busy"


class NotRunning(AgentError):
    status, code = 409, "not_running"


class InvalidParams(AgentError):
    status, code = 422, "invalid_params"


class GpuCount(AgentError):
    status, code = 422, "gpu_count"


class UnknownGpu(AgentError):
    status, code = 422, "unknown_gpu"


class Validation(AgentError):
    status, code = 422, "validation"


class GpuInventoryUnavailable(AgentError):
    """nvidia-smi could not answer right now; the GPUs may well be present and in use."""

    status, code = 503, "gpu_inventory_unavailable"


def install_handlers(app: FastAPI) -> None:
    @app.exception_handler(AgentError)
    async def _agent_error(_: Request, error: AgentError) -> JSONResponse:
        return JSONResponse(status_code=error.status, content=error.envelope())

    @app.exception_handler(RequestValidationError)
    async def _validation(_: Request, error: RequestValidationError) -> JSONResponse:
        return JSONResponse(
            status_code=422,
            content={
                "error": {
                    "code": "validation",
                    "message": "request validation failed",
                    "detail": error.errors(),
                }
            },
        )

    @app.exception_handler(Exception)
    async def _internal(_: Request, error: Exception) -> JSONResponse:
        # The traceback goes to the server log via uvicorn; the client gets no internals.
        return JSONResponse(
            status_code=500,
            content={"error": {"code": "internal", "message": "internal error", "detail": None}},
        )
