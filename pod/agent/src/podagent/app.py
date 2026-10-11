"""FastAPI app factory: the routes of POD-SPEC §2 over the supervisor, plan and events modules.

What a client can observe is decided here and in ``errors.py``:

- ``EdgeGuard``, a pure-ASGI middleware ahead of routing, answers ``401`` from the headers
  alone, before a byte of the body is read, then refuses bodies above ``MAX_BODY_BYTES`` (or
  sent chunked, without a ``Content-Length``) with ``413``. The proxy URL is public (POD-SPEC
  §1), and FastAPI buffers the whole body before any dependency runs, so without this guard an
  anonymous client could fill the pod's RAM with request bodies;
- every route, ``/health`` included, also runs ``require_bearer`` as an app-level dependency:
  the second line of defence, and what keeps ``create_app`` honest without the middleware;
- FastAPI answers two things before that dependency runs (an unmatched path or method, and a
  body that is not JSON); ``_install_edge_handlers`` folds both into the error envelope and
  checks the bearer first, so an unauthenticated client never sees anything but ``401``;
- ``/tensorboard`` proxies the catalog's fixed loopback TensorBoard port; a browser reaches it
  with the derived session cookie that ``POST /tensorboard-session`` issues (``auth.py``);
- ``/runs/{id}/files`` serves the run's output directory and nothing else (``artifacts.py``);
- the lifespan's exit stops every running child: the agent is PID 1, so its shutdown is the
  container's.
"""

from __future__ import annotations

import contextlib
import inspect
import os
from collections.abc import AsyncIterator
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import httpx
from fastapi import Depends, FastAPI, Query, Request, Response
from fastapi.concurrency import run_in_threadpool
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, ConfigDict, Field
from starlette.datastructures import Headers
from starlette.exceptions import HTTPException
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from . import __version__
from .artifacts import RunFiles, list_run_files, resolve_run_file
from .auth import (
    TENSORBOARD_COOKIE,
    TENSORBOARD_PREFIX,
    TENSORBOARD_SESSION_PATH,
    Authenticator,
    require_bearer,
)
from .catalog import CATALOG
from .errors import (
    AgentError,
    BadRequest,
    NotFound,
    NotRunning,
    PayloadTooLarge,
    Unauthorized,
    Validation,
    install_handlers,
)
from .events import RUN_ID_RE, summarize_run
from .gpus import FakeBackend, GpuBackend, InventoryUnavailable, NvidiaSmiBackend
from .plan import PlanRequest, PlanResponse, plan
from .settings import Settings, load_settings
from .supervisor import Supervisor

# pydantic's error type for a request body that does not parse as JSON (POD-SPEC §2.2: 400).
JSON_INVALID = "json_invalid"
# Envelope codes for what the router answers on its own (an unmatched path is 404, a wrong
# method 405); a status the §2.2 table does not name maps by its class.
_ROUTER_CODES = {400: "bad_request", 401: "unauthorized", 404: "not_found", 422: "validation"}
# The largest body any route accepts. A trainer start carries a RunConfig (§4.1) with an
# ``extra`` tree: kilobytes. Anything beyond this is not a client of ours.
MAX_BODY_BYTES = 1 << 20
# Ceiling of ``timeout_s`` on a stop. The RunPod proxy cuts every request at 100 s (§1), so a
# longer SIGTERM wait would finish unobserved: the client gets a 524, the agent carries on.
MAX_STOP_TIMEOUT_S = 90.0
# Scope key under which ``EdgeGuard`` files the overflow it raised while the body was being
# read; FastAPI turns any error there into a bare 400, and ``_router_error`` restores the 413.
_OVERFLOW_KEY = "podagent.overflow"


class StartRequest(BaseModel):
    """``POST /services/{name}/start`` body: ``gpus`` defaults to ``[]``, ``params`` to ``{}``."""

    model_config = ConfigDict(extra="forbid")

    gpus: list[int] = []
    params: dict[str, Any] = {}


class StopRequest(BaseModel):
    """``POST /services/{name}/stop`` body, optional: SIGTERM grace before SIGKILL, 1-90 s.

    The call blocks for the whole wait, so the ceiling keeps it inside the proxy's 100 s.
    """

    model_config = ConfigDict(extra="forbid")

    timeout_s: float = Field(default=30.0, ge=1, le=MAX_STOP_TIMEOUT_S)


def make_backend(settings: Settings) -> GpuBackend:
    if settings.fake_gpus is not None:
        return FakeBackend(settings.fake_gpus)
    return NvidiaSmiBackend()


def _envelope(error: AgentError) -> JSONResponse:
    return JSONResponse(status_code=error.status, content=error.envelope())


def _denied(request: Request, auth: Authenticator) -> JSONResponse | None:
    """The ``401`` envelope when ``request`` carries no valid credential, else ``None``."""
    try:
        auth.check(request.url.path, request.headers.get("authorization"), request.cookies)
    except Unauthorized as error:
        return _envelope(error)
    return None


class EdgeGuard:
    """Pure-ASGI middleware ahead of routing: bearer, then body size, before any body is read.

    Starlette's own middleware stack (and so FastAPI's routing, which buffers the whole body
    before route dependencies run) sits behind this. A request that fails here is answered
    from its headers alone; ``receive`` is never called, so no body is buffered. A request
    that passes gets a ``receive`` that counts what the app actually reads and aborts the
    read past the cap, in case the declared ``Content-Length`` lied (a conforming server never
    delivers more than it declares; this costs nothing). FastAPI reports the aborted read as a
    bare 400, so the error is also filed on the scope for ``_router_error`` to answer as 413.
    """

    def __init__(
        self, app: ASGIApp, *, auth: Authenticator, max_body_bytes: int = MAX_BODY_BYTES
    ) -> None:
        self.app = app
        self.auth = auth
        self.max_body_bytes = max_body_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        error = self.reject(
            Headers(scope=scope), path=scope["path"], cookies=Request(scope).cookies
        )
        if error is not None:
            await _envelope(error)(scope, receive, send)
            return
        await self.app(scope, self._counted(scope, receive), send)

    def reject(
        self, headers: Headers, *, path: str = "", cookies: dict[str, str] | None = None
    ) -> AgentError | None:
        """The error this request earns from its headers, or ``None`` to let it through."""
        try:
            self.auth.check(path, headers.get("authorization"), cookies or {})
        except Unauthorized as error:
            return error
        if "chunked" in headers.get("transfer-encoding", "").lower():
            return PayloadTooLarge(
                "chunked request bodies are not accepted; send a Content-Length",
                detail={"max_bytes": self.max_body_bytes},
            )
        declared = headers.get("content-length")
        if declared is None:
            return None
        try:
            length = int(declared)
        except ValueError:
            length = -1
        if length < 0:
            return BadRequest("invalid Content-Length header")
        if length > self.max_body_bytes:
            return PayloadTooLarge(
                f"request body of {length} bytes exceeds the {self.max_body_bytes}-byte limit",
                detail={"content_length": length, "max_bytes": self.max_body_bytes},
            )
        return None

    def _counted(self, scope: Scope, receive: Receive) -> Receive:
        received = 0

        async def counted() -> Message:
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > self.max_body_bytes:
                    error = PayloadTooLarge(
                        f"request body exceeds the {self.max_body_bytes}-byte limit",
                        detail={"max_bytes": self.max_body_bytes},
                    )
                    scope[_OVERFLOW_KEY] = error
                    raise error
            return message

        return counted


def _install_edge_handlers(app: FastAPI, auth: Authenticator) -> None:
    """Envelope and bearer check for the answers FastAPI gives before route dependencies run.

    ``install_handlers`` (errors.py) owns the envelope for agent errors and for validation
    errors; this adds the two cases it cannot see from inside a route and must be installed
    after it, since it wraps the validation handler it registered.
    """
    validation_handler = app.exception_handlers[RequestValidationError]

    @app.exception_handler(HTTPException)
    async def _router_error(request: Request, error: HTTPException) -> Response:
        # An unmatched path or method is answered by the router; no dependency ever ran.
        if (denied := _denied(request, auth)) is not None:
            return denied
        overflow = request.scope.get(_OVERFLOW_KEY)
        if isinstance(overflow, AgentError):
            # FastAPI reports any failure while reading the body as a 400; this one was ours.
            return _envelope(overflow)
        status = error.status_code
        code = _ROUTER_CODES.get(status, "internal" if status >= 500 else "bad_request")
        return JSONResponse(
            status_code=status,
            content={"error": {"code": code, "message": str(error.detail), "detail": None}},
            headers=error.headers,
        )

    @app.exception_handler(RequestValidationError)
    async def _body_error(request: Request, error: RequestValidationError) -> Response:
        # The body is decoded before dependencies are solved, so a body that is not JSON
        # lands here with the bearer unchecked.
        if (denied := _denied(request, auth)) is not None:
            return denied
        errors = error.errors()
        if any(item.get("type") == JSON_INVALID for item in errors):
            return _envelope(BadRequest("request body is not valid JSON", detail=errors))
        result = validation_handler(request, error)
        return await result if inspect.isawaitable(result) else result


def create_app(settings: Settings | None = None, backend: GpuBackend | None = None) -> FastAPI:
    settings = settings or load_settings()
    backend = backend or make_backend(settings)
    settings.paths.ensure()

    @contextlib.asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        yield
        # Agent shutdown is container shutdown: take every running child down with it. The
        # supervisor waits for each child (SIGTERM, then SIGKILL), so keep that off the loop.
        await run_in_threadpool(app.state.supervisor.shutdown)

    app = FastAPI(
        title="podagent",
        version=__version__,
        lifespan=lifespan,
        dependencies=[Depends(require_bearer)],
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    app.state.settings = settings
    app.state.backend = backend
    app.state.supervisor = Supervisor(settings, backend)
    auth = app.state.auth = Authenticator(settings.token)
    install_handlers(app)
    _install_edge_handlers(app, auth)
    app.add_middleware(EdgeGuard, auth=auth, max_body_bytes=MAX_BODY_BYTES)

    def supervisor() -> Supervisor:
        return app.state.supervisor

    def secure_cookie(request: Request) -> bool:
        # RunPod terminates TLS before the agent, so a real pod is always https to the browser;
        # only fake mode over plain http may drop the Secure flag.
        return settings.fake_gpus is None or request.url.scheme == "https"

    @app.post(TENSORBOARD_SESSION_PATH)
    def tensorboard_session(request: Request, response: Response) -> dict[str, Any]:
        # Bearer only: this path is outside /tensorboard, so a session cannot renew itself.
        session = auth.issue_tensorboard_session()
        secure = secure_cookie(request)
        response.set_cookie(
            TENSORBOARD_COOKIE,
            session.value,
            max_age=session.max_age_s,
            path=TENSORBOARD_PREFIX,
            httponly=True,
            secure=secure,
            samesite="strict",
        )
        return {
            "cookie": TENSORBOARD_COOKIE,
            "value": session.value,
            "path": TENSORBOARD_PREFIX,
            "max_age_s": session.max_age_s,
            "expires_at": datetime.fromtimestamp(session.expires_at, tz=UTC).strftime(
                "%Y-%m-%dT%H:%M:%SZ"
            ),
            "secure": secure,
            "http_only": True,
            "same_site": "strict",
            "url": TENSORBOARD_PREFIX + "/",
        }

    @app.api_route(TENSORBOARD_PREFIX, methods=["GET", "POST", "HEAD"])
    @app.api_route(TENSORBOARD_PREFIX + "/{path:path}", methods=["GET", "POST", "HEAD"])
    async def tensorboard(request: Request, path: str = "") -> Response:
        del path  # the route's original path and query are forwarded to the fixed local service
        target = httpx.URL(
            scheme="http",
            host="127.0.0.1",
            port=CATALOG["tensorboard"].port,
            path=request.url.path,
            query=request.url.query.encode(),
        )
        headers = {
            name: value
            for name, value in request.headers.items()
            if name in {"accept", "content-type", "if-none-match", "if-modified-since"}
        }
        try:
            async with httpx.AsyncClient(timeout=30, trust_env=False) as client:
                upstream = await client.request(
                    request.method, target, headers=headers, content=await request.body()
                )
        except httpx.ConnectError as error:
            # Nothing listens on the catalog port: the service is not started (or has died).
            raise NotRunning("TensorBoard is not running") from error
        except httpx.HTTPError as error:
            raise AgentError("cannot reach local TensorBoard") from error
        return Response(
            upstream.content,
            status_code=upstream.status_code,
            headers={
                name: value
                for name, value in upstream.headers.items()
                if name in {"content-type", "cache-control", "etag", "last-modified", "location"}
            },
        )

    @app.get("/health")
    def health() -> dict[str, Any]:
        # The agent is healthy even when nvidia-smi is not answering: report the count as
        # unknown (null) rather than failing the probe or claiming an empty pod.
        try:
            gpu_count: int | None = len(backend.list_gpus())
        except InventoryUnavailable:
            gpu_count = None
        return {
            "status": "ok",
            "version": __version__,
            "workspace": str(settings.paths.workspace),
            "gpu_backend": backend.kind,
            "gpu_count": gpu_count,
            "runpod": {
                "pod_id": os.environ.get("RUNPOD_POD_ID"),
                "public_ip": os.environ.get("RUNPOD_PUBLIC_IP"),
            },
            "time": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }

    @app.get("/gpus")
    def gpus() -> dict[str, Any]:
        return {"gpus": supervisor().inventory()}

    @app.post("/plan", response_model=PlanResponse)
    def plan_route(body: PlanRequest) -> PlanResponse:
        # An explicit gpu_count needs no inventory; otherwise an unreadable one is 503, never
        # "no GPUs".
        count = body.gpu_count if body.gpu_count is not None else supervisor().gpu_count()
        return plan(body, count)

    @app.get("/services")
    def services() -> dict[str, Any]:
        return {"services": [state.model_dump(mode="json") for state in supervisor().states()]}

    @app.get("/services/{name}")
    def service(name: str) -> dict[str, Any]:
        return supervisor().state(name).model_dump(mode="json")

    @app.post("/services/{name}/start", status_code=201)
    def start(name: str, body: StartRequest) -> dict[str, Any]:
        return supervisor().start(name, body.gpus, body.params).model_dump(mode="json")

    @app.post("/services/{name}/stop")
    def stop(name: str, body: StopRequest | None = None) -> dict[str, Any]:
        timeout = body.timeout_s if body is not None else StopRequest().timeout_s
        return supervisor().stop(name, timeout).model_dump(mode="json")

    @app.get("/services/{name}/logs")
    def logs(name: str, tail: int = Query(default=200, ge=1, le=5000)) -> dict[str, Any]:
        return supervisor().logs(name, tail).model_dump(mode="json")

    def run_dir_or_404(run_id: str) -> Path:
        if not RUN_ID_RE.match(run_id):
            raise Validation("invalid run id", detail={"field": "run_id", "value": run_id})
        run_dir = settings.paths.run_dir(run_id)
        if not run_dir.is_dir():
            raise NotFound(f"no run {run_id!r}")
        return run_dir

    @app.get("/runs/{run_id}/events")
    def events(run_id: str) -> dict[str, Any]:
        logdir = run_dir_or_404(run_id) / "tensorboard"
        return summarize_run(run_id, logdir).model_dump(mode="json")

    @app.get("/runs/{run_id}/log")
    def run_log(run_id: str, tail: int = Query(default=200, ge=1, le=5000)) -> dict[str, Any]:
        # The trainer log persists on the volume: readable for runs from earlier agent
        # lifetimes, which /services/trainer-*/logs cannot reach.
        run_dir_or_404(run_id)
        return supervisor().run_log(run_id, tail).model_dump(mode="json")

    @app.get("/runs/{run_id}/files", response_model=RunFiles)
    def run_files(run_id: str) -> RunFiles:
        # Sync route: hashing runs in the threadpool, off the event loop.
        return list_run_files(run_id, run_dir_or_404(run_id))

    @app.api_route("/runs/{run_id}/files/{path:path}", methods=["GET", "HEAD"])
    def run_file(run_id: str, path: str) -> FileResponse:
        real = resolve_run_file(run_id, run_dir_or_404(run_id), path)
        return FileResponse(real, media_type="application/octet-stream", filename=real.name)

    return app
