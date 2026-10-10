"""The HTTP API end to end (POD-SPEC §2) with ``TestClient`` in fake mode.

Every route and every error code of §2.2 through HTTP, over real ``podagent.fakeservice``
children: the bearer on every route (whatever the path, method or body), the one error
envelope, service start/stop/logs, ``/gpus`` bookkeeping, the topology rule driven through
``/plan`` and the start calls it prescribes, secret redaction in every echo, the lifespan
shutdown hook, and ``python -m podagent`` refusing to start without a token. Fixture triggers
are NORA7 / IVAN9; nothing here names a real concept.
"""

from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

import httpx
import pytest
from conftest import AUTH, TOKEN, ClientFactory
from fastapi import FastAPI
from fastapi.testclient import TestClient

from podagent import __version__
from podagent.__main__ import main as podagent_main
from podagent.app import MAX_BODY_BYTES, MAX_STOP_TIMEOUT_S, create_app
from podagent.catalog import SERVICE_NAMES
from podagent.gpus import FakeBackend, InventoryUnavailable
from podagent.settings import Settings

WAIT_S = 10.0
POLL_S = 0.02
VLLM_SECRET = "super-secret-key-000"
HF_SECRET = "hf_secret_value_123"

STATE_KEYS = {
    "name",
    "state",
    "pid",
    "gpus",
    "params",
    "exit_code",
    "stopped_by_request",
    "group_alive",
    "started_at",
    "ended_at",
    "log_path",
    "port",
    "run_id",
}
GPU_KEYS = {"index", "name", "memory_total_mib", "memory_used_mib", "uuid", "in_use_by"}
HEALTH_KEYS = {"status", "version", "workspace", "gpu_backend", "gpu_count", "runpod", "time"}
ERROR_KEYS = {"code", "message", "detail"}
ISO_SECONDS_UTC = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
ISO_UTC = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$")


# --- helpers -----------------------------------------------------------------------------------


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def wait_until(predicate: Callable[[], bool], what: str, timeout: float = WAIT_S) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(POLL_S)
    raise AssertionError(f"timed out after {timeout} s waiting for {what}")


def wait_for_log(path: str, needle: str) -> str:
    """Block until the service log contains ``needle``; return the log text."""
    file = Path(path)

    def present() -> bool:
        return file.exists() and needle in file.read_text(encoding="utf-8", errors="replace")

    wait_until(present, f"{needle!r} in {file.name}")
    return file.read_text(encoding="utf-8", errors="replace")


def wait_for_exit(client: TestClient, name: str) -> dict[str, Any]:
    """Poll ``GET /services/{name}`` until it is no longer running; return that state."""
    wait_until(
        lambda: client.get(f"/services/{name}").json()["state"] != "running", f"{name} to exit"
    )
    return client.get(f"/services/{name}").json()


def vllm_params(**overrides: Any) -> dict[str, Any]:
    body: dict[str, Any] = {"model": "org/fake-vl-model", "port": free_port()}
    body.update(overrides)
    return body


def run_config(settings: Settings, **overrides: Any) -> dict[str, Any]:
    body: dict[str, Any] = {
        "run_id": "nora7-h3-001",
        "dataset": {"path": str(settings.paths.datasets / "faces")},
        "triggers": ["NORA7"],
        "base_model": "black-forest-labs/FLUX.1-dev",
        "sample_prompts": ["NORA7 woman, studio portrait"],
    }
    body.update(overrides)
    return body


def start(client: TestClient, name: str, gpus: list[int], params: dict[str, Any]) -> dict[str, Any]:
    response = client.post(f"/services/{name}/start", json={"gpus": gpus, "params": params})
    assert response.status_code == 201, response.text
    return response.json()


def in_use(client: TestClient) -> list[str | None]:
    return [gpu["in_use_by"] for gpu in client.get("/gpus").json()["gpus"]]


def expect_error(response: httpx.Response, status: int, code: str) -> dict[str, Any]:
    """Assert the envelope of POD-SPEC §2.2 and return its ``error`` object."""
    assert response.status_code == status, response.text
    body = response.json()
    assert set(body) == {"error"}, body
    error = body["error"]
    assert set(error) == ERROR_KEYS, error
    assert error["code"] == code, error
    assert isinstance(error["message"], str) and error["message"]
    return error


# --- §2.1 authentication -----------------------------------------------------------------------

# (method, path, json body): one request per route, with a body the route would accept.
ROUTES: list[tuple[str, str, dict[str, Any] | None]] = [
    ("GET", "/health", None),
    ("GET", "/gpus", None),
    ("POST", "/plan", {"caption": True, "train": True}),
    ("GET", "/services", None),
    ("GET", "/services/vllm", None),
    ("POST", "/services/vllm/start", {"gpus": [0], "params": {"model": "org/fake-vl-model"}}),
    ("POST", "/services/vllm/stop", {"timeout_s": 5}),
    ("GET", "/services/vllm/logs", None),
    ("GET", "/runs/nora7-h3-001/events", None),
]

BAD_HEADERS: dict[str, dict[str, str]] = {
    "missing": {},
    "wrong-token": {"Authorization": "Bearer wrong-token-000000"},
    "token-prefix": {"Authorization": f"Bearer {TOKEN[:-1]}"},
    "token-suffix": {"Authorization": f"Bearer {TOKEN}x"},
    "wrong-scheme": {"Authorization": f"Basic {TOKEN}"},
    "bare-scheme": {"Authorization": "Bearer"},
    "empty": {"Authorization": ""},
}


@pytest.mark.parametrize(("method", "path", "body"), ROUTES, ids=[r[1] for r in ROUTES])
@pytest.mark.parametrize("headers", list(BAD_HEADERS.values()), ids=list(BAD_HEADERS))
def test_every_route_requires_the_bearer(
    anon_client: TestClient,
    method: str,
    path: str,
    body: dict[str, Any] | None,
    headers: dict[str, str],
) -> None:
    response = anon_client.request(method, path, json=body, headers=headers)
    error = expect_error(response, 401, "unauthorized")
    assert error["detail"] is None
    assert TOKEN not in response.text


def test_unauthenticated_start_changes_nothing(anon_client: TestClient) -> None:
    body = {"gpus": [0], "params": {"model": "org/fake-vl-model", "port": free_port()}}
    assert anon_client.post("/services/vllm/start", json=body).status_code == 401
    states = anon_client.get("/services", headers=AUTH).json()["services"]
    assert all(state["state"] == "idle" for state in states)
    assert all(holder is None for holder in in_use_with(anon_client))


def in_use_with(client: TestClient) -> list[str | None]:
    return [gpu["in_use_by"] for gpu in client.get("/gpus", headers=AUTH).json()["gpus"]]


def http_scope(method: str, path: str, headers: dict[str, str]) -> dict[str, Any]:
    """A minimal ASGI 3 HTTP scope, for driving the app without a client in the way."""
    return {
        "type": "http",
        "asgi": {"version": "3.0", "spec_version": "2.3"},
        "http_version": "1.1",
        "method": method,
        "scheme": "http",
        "path": path,
        "raw_path": path.encode(),
        "query_string": b"",
        "root_path": "",
        "headers": [(k.lower().encode(), v.encode()) for k, v in headers.items()],
        "client": ("testclient", 50000),
        "server": ("testserver", 80),
    }


async def call_asgi(
    app: FastAPI, scope: dict[str, Any], receive: Callable[[], Any]
) -> tuple[int, dict[str, Any]]:
    """Run one request through the raw ASGI app; return (status, decoded JSON body)."""
    sent: list[dict[str, Any]] = []

    async def send(message: dict[str, Any]) -> None:
        sent.append(message)

    await app(scope, receive, send)
    assert [m["type"] for m in sent] == ["http.response.start", "http.response.body"], sent
    return sent[0]["status"], json.loads(sent[1]["body"])


JSON_HEADERS = {"Content-Type": "application/json"}
BODY_ROUTES = ["/plan", "/services/vllm/start", "/services/vllm/stop"]


@pytest.mark.parametrize("path", BODY_ROUTES)
async def test_unauthenticated_body_is_never_read(app: FastAPI, path: str) -> None:
    # The proxy URL is public: an anonymous client must not make the agent buffer a body of any
    # size. The guard answers 401 from the headers; ``receive`` is never called.
    async def receive() -> dict[str, Any]:
        raise AssertionError("the request body was read before the bearer was checked")

    headers = {**JSON_HEADERS, "Content-Length": str(50 * 1024**3)}
    for extra in ({}, {"Authorization": "Bearer wrong-token-000000"}):
        status, body = await call_asgi(app, http_scope("POST", path, {**headers, **extra}), receive)
        assert status == 401, body
        assert body == {
            "error": {"code": "unauthorized", "message": body["error"]["message"], "detail": None}
        }
        assert TOKEN not in json.dumps(body)


@pytest.mark.parametrize("path", BODY_ROUTES)
def test_oversized_body_is_413_authenticated_and_401_otherwise(
    client: TestClient, anon_client: TestClient, path: str
) -> None:
    # An explicit Content-Length wins over httpx's own, so this declares a body it never sends.
    headers = {**JSON_HEADERS, "Content-Length": str(MAX_BODY_BYTES + 1)}
    error = expect_error(
        client.post(path, content=b"{}", headers=headers), 413, "payload_too_large"
    )
    assert error["detail"] == {"content_length": MAX_BODY_BYTES + 1, "max_bytes": MAX_BODY_BYTES}
    expect_error(anon_client.post(path, content=b"{}", headers=headers), 401, "unauthorized")
    assert all(state["state"] == "idle" for state in client.get("/services").json()["services"])


@pytest.mark.parametrize("path", BODY_ROUTES)
def test_chunked_body_is_413_authenticated_and_401_otherwise(
    client: TestClient, anon_client: TestClient, path: str
) -> None:
    # A chunked body has no length to check up front, so it is refused outright.
    def chunks() -> Any:
        yield b'{"caption": true}'

    error = expect_error(
        client.post(path, content=chunks(), headers=JSON_HEADERS), 413, "payload_too_large"
    )
    assert error["detail"] == {"max_bytes": MAX_BODY_BYTES}
    assert "Content-Length" in error["message"]
    expect_error(
        anon_client.post(path, content=chunks(), headers=JSON_HEADERS), 401, "unauthorized"
    )


def test_body_at_the_cap_is_accepted_and_validated(client: TestClient) -> None:
    # Exactly MAX_BODY_BYTES passes the guard and reaches the route: a valid /plan padded with
    # an unknown key is 422 from pydantic, not 413 from the guard.
    padding = "x" * (MAX_BODY_BYTES - len('{"caption": true, "pad": ""}'))
    body = f'{{"caption": true, "pad": "{padding}"}}'.encode()
    assert len(body) == MAX_BODY_BYTES
    response = client.post("/plan", content=body, headers=JSON_HEADERS)
    assert response.status_code in (200, 422), response.text
    assert response.json().get("error", {}).get("code") in (None, "validation")
    assert client.post("/plan", json={"caption": True}).status_code == 200


async def test_body_longer_than_its_content_length_is_413(app: FastAPI) -> None:
    # The declared length passed the guard; the bytes actually delivered are counted too.
    headers = {**JSON_HEADERS, "Content-Length": "2", **AUTH}
    oversized = b"{" + b" " * MAX_BODY_BYTES + b"}"
    delivered = False

    async def receive() -> dict[str, Any]:
        nonlocal delivered
        if delivered:
            return {"type": "http.disconnect"}
        delivered = True
        return {"type": "http.request", "body": oversized, "more_body": False}

    status, body = await call_asgi(app, http_scope("POST", "/plan", headers), receive)
    assert status == 413, body
    assert body["error"]["code"] == "payload_too_large"
    assert body["error"]["detail"] == {"max_bytes": MAX_BODY_BYTES}


def test_bad_content_length_is_400(client: TestClient) -> None:
    for value in ("-1", "many"):
        headers = {**JSON_HEADERS, "Content-Length": value}
        error = expect_error(
            client.post("/plan", content=b"{}", headers=headers), 400, "bad_request"
        )
        assert "Content-Length" in error["message"]


def test_bearer_scheme_is_case_insensitive(anon_client: TestClient) -> None:
    for scheme in ("Bearer", "bearer", "BEARER"):
        response = anon_client.get("/health", headers={"Authorization": f"{scheme} {TOKEN}"})
        assert response.status_code == 200, scheme


@pytest.mark.parametrize(
    ("method", "path"),
    [("GET", "/"), ("GET", "/nope"), ("GET", "/services/vllm/nope"), ("DELETE", "/health")],
)
def test_unknown_paths_and_methods_are_401_without_a_bearer(
    anon_client: TestClient, method: str, path: str
) -> None:
    # The router answers these before any dependency runs; the agent still demands the token
    # first, so an unauthenticated probe cannot map which routes exist.
    expect_error(anon_client.request(method, path), 401, "unauthorized")
    expect_error(
        anon_client.request(method, path, headers={"Authorization": "Bearer wrong-token-00"}),
        401,
        "unauthorized",
    )


def test_unknown_path_is_a_not_found_envelope(client: TestClient) -> None:
    # The last one stays a router 404: Starlette does not fold ``%2F`` into a path parameter.
    for path in ("/", "/nope", "/services/vllm/nope", "/runs/nora7-h3-001", "/services/vllm%2Fx"):
        error = expect_error(client.get(path), 404, "not_found")
        assert error["detail"] is None, path


def test_wrong_method_is_an_envelope_with_allow_header(client: TestClient) -> None:
    response = client.delete("/health")
    error = expect_error(response, 405, "bad_request")
    assert error["message"] == "Method Not Allowed"
    assert "GET" in response.headers["allow"]
    expect_error(client.get("/plan"), 405, "bad_request")
    expect_error(client.put("/services/vllm/start", json={}), 405, "bad_request")


# --- §2.2 the envelope -------------------------------------------------------------------------


def test_malformed_json_is_400_authenticated_and_401_otherwise(
    client: TestClient, anon_client: TestClient
) -> None:
    raw = {"content": b'{"caption": tru', "headers": {"Content-Type": "application/json"}}
    for path in ("/plan", "/services/vllm/start", "/services/vllm/stop"):
        error = expect_error(client.post(path, **raw), 400, "bad_request")
        assert "JSON" in error["message"]
        assert isinstance(error["detail"], list) and error["detail"]
        assert error["detail"][0]["type"] == "json_invalid"
        # The body is decoded before the bearer dependency runs; the agent checks it anyway.
        expect_error(anon_client.post(path, **raw), 401, "unauthorized")
    assert all(state["state"] == "idle" for state in client.get("/services").json()["services"])


def test_every_error_uses_the_one_envelope(client: TestClient, settings: Settings) -> None:
    """One request per row of the §2.2 table (the 500 has its own test)."""
    tb_port = free_port()
    start(client, "tensorboard", [], {"port": tb_port})
    start(client, "vllm", [0], vllm_params())
    rows: list[tuple[int, str, httpx.Response]] = [
        (400, "bad_request", client.post("/plan", json={})),
        (401, "unauthorized", client.get("/health", headers={"Authorization": "Bearer nope"})),
        (404, "not_found", client.get("/services/nope")),
        (409, "already_running", client.post("/services/tensorboard/start", json={})),
        (
            409,
            "gpu_busy",
            client.post(
                "/services/trainer-ltx/start",
                json={"gpus": [0, 1], "params": run_config(settings)},
            ),
        ),
        (409, "not_running", client.post("/services/pull-dataset/stop")),
        (
            422,
            "invalid_params",
            client.post("/services/push-lora/start", json={"gpus": [], "params": {}}),
        ),
        (
            422,
            "gpu_count",
            client.post(
                "/services/pull-dataset/start",
                json={"gpus": [1], "params": {"repo_id": "org/faces"}},
            ),
        ),
        (
            422,
            "unknown_gpu",
            client.post(
                "/services/trainer-aitoolkit/start",
                json={"gpus": [9], "params": run_config(settings)},
            ),
        ),
        (422, "validation", client.get("/services/vllm/logs", params={"tail": 0})),
    ]
    for status, code, response in rows:
        expect_error(response, status, code)
    # Nothing in that list changed the world: vllm and tensorboard still run alone.
    assert in_use(client) == ["vllm", None]
    states = {s["name"]: s["state"] for s in client.get("/services").json()["services"]}
    assert states == {
        "vllm": "running",
        "tensorboard": "running",
        "trainer-aitoolkit": "idle",
        "trainer-ltx": "idle",
        "pull-dataset": "idle",
        "push-lora": "idle",
    }


def test_internal_error_is_generic(app: FastAPI) -> None:
    def explode() -> list[dict[str, Any]]:
        raise RuntimeError("driver exploded at /very/private/path")

    app.state.supervisor.inventory = explode
    with TestClient(app, headers=AUTH, raise_server_exceptions=False) as client:
        response = client.get("/gpus")
    error = expect_error(response, 500, "internal")
    assert error == {"code": "internal", "message": "internal error", "detail": None}
    assert "exploded" not in response.text and "private" not in response.text


# --- §2.3 /health ------------------------------------------------------------------------------


def test_health_shape(
    client: TestClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.delenv("RUNPOD_POD_ID", raising=False)
    monkeypatch.delenv("RUNPOD_PUBLIC_IP", raising=False)
    body = client.get("/health").json()
    assert set(body) == HEALTH_KEYS
    assert body["status"] == "ok"
    assert body["version"] == __version__
    assert body["workspace"] == str(settings.paths.workspace)
    assert body["gpu_backend"] == "fake"
    assert body["gpu_count"] == 2
    assert body["runpod"] == {"pod_id": None, "public_ip": None}
    assert ISO_SECONDS_UTC.match(body["time"]), body["time"]

    monkeypatch.setenv("RUNPOD_POD_ID", "abc123xyz")
    monkeypatch.setenv("RUNPOD_PUBLIC_IP", "203.0.113.7")
    assert client.get("/health").json()["runpod"] == {
        "pod_id": "abc123xyz",
        "public_ip": "203.0.113.7",
    }


@pytest.mark.parametrize("count", [0, 1, 4])
def test_health_gpu_count_follows_the_backend(make_client: ClientFactory, count: int) -> None:
    body = make_client(count).get("/health").json()
    assert body["status"] == "ok" and body["gpu_count"] == count


# --- §2.4 /gpus --------------------------------------------------------------------------------


def test_gpus_inventory_idle(client: TestClient) -> None:
    gpus = client.get("/gpus").json()["gpus"]
    assert len(gpus) == 2
    for index, gpu in enumerate(gpus):
        assert set(gpu) == GPU_KEYS
        assert gpu["index"] == index
        assert gpu["name"] == "FAKE GPU"
        assert gpu["memory_total_mib"] == 81920 and gpu["memory_used_mib"] == 0
        assert gpu["uuid"] == f"GPU-FAKE-{index}"
        assert gpu["in_use_by"] is None


def test_gpus_in_use_by_follows_running_services(client: TestClient, settings: Settings) -> None:
    assert in_use(client) == [None, None]
    vllm = start(client, "vllm", [0], vllm_params())
    assert in_use(client) == ["vllm", None]
    # 0-GPU services never hold anything.
    start(client, "tensorboard", [], {"port": free_port()})
    assert in_use(client) == ["vllm", None]
    start(client, "trainer-ltx", [1], run_config(settings))
    assert in_use(client) == ["vllm", "trainer-ltx"]

    wait_for_log(vllm["log_path"], "listening on")
    assert client.post("/services/vllm/stop").status_code == 200
    assert in_use(client) == [None, "trainer-ltx"]
    assert client.post("/services/trainer-ltx/stop").status_code == 200
    assert in_use(client) == [None, None]

    # A child that dies on its own releases its GPU as soon as the agent sees the exit.
    start(client, "trainer-aitoolkit", [0], run_config(settings, extra={"fail": True}))
    assert in_use(client) == ["trainer-aitoolkit", None]
    assert wait_for_exit(client, "trainer-aitoolkit")["state"] == "failed"
    assert in_use(client) == [None, None]


def test_gpus_empty_inventory(make_client: ClientFactory) -> None:
    client = make_client(0)
    assert client.get("/gpus").json() == {"gpus": []}
    error = expect_error(client.post("/plan", json={"caption": True}), 400, "bad_request")
    assert "no GPUs" in error["message"]
    error = expect_error(
        client.post("/services/vllm/start", json={"gpus": [0], "params": vllm_params()}),
        422,
        "unknown_gpu",
    )
    assert error["detail"] == {"gpu": 0, "known": []}
    # 0-GPU services still work on such a pod.
    start(client, "tensorboard", [], {"port": free_port()})


# --- §2.5 /plan, driven end to end -------------------------------------------------------------


def test_topology_one_gpu_is_sequential(make_client: ClientFactory, settings: Settings) -> None:
    client = make_client(1)
    plan = client.post("/plan", json={"caption": True, "train": True}).json()
    assert plan["gpu_count"] == 1 and plan["mode"] == "sequential"
    assert plan["caption"] == {"service": "vllm", "gpus": [0]}
    assert plan["train"] == {"service": "trainer", "gpus": [0]}
    assert [(step["action"], step["service"]) for step in plan["order"]] == [
        ("start", "vllm"),
        ("stop", "vllm"),
        ("start", "trainer"),
    ]

    vllm = start(client, "vllm", plan["caption"]["gpus"], vllm_params())
    wait_for_log(vllm["log_path"], "listening on")
    # The plan's stop step is not advisory on one GPU: the trainer cannot share it.
    error = expect_error(
        client.post(
            "/services/trainer-ltx/start",
            json={"gpus": plan["train"]["gpus"], "params": run_config(settings)},
        ),
        409,
        "gpu_busy",
    )
    assert error["detail"] == {"gpu": 0, "service": "vllm"}
    assert client.get("/services/trainer-ltx").json()["state"] == "idle"

    assert client.post("/services/vllm/stop").json()["state"] == "stopped"
    trainer = start(client, "trainer-ltx", plan["train"]["gpus"], run_config(settings))
    assert trainer["gpus"] == [0]
    assert in_use(client) == ["trainer-ltx"]
    text = wait_for_log(trainer["log_path"], "sleeping until SIGTERM")
    assert "CUDA_VISIBLE_DEVICES='0'" in text
    # ... and vLLM cannot come back until the trainer is done.
    error = expect_error(
        client.post("/services/vllm/start", json={"gpus": [0], "params": vllm_params()}),
        409,
        "gpu_busy",
    )
    assert error["detail"] == {"gpu": 0, "service": "trainer-ltx"}


def test_topology_two_gpus_is_concurrent(client: TestClient, settings: Settings) -> None:
    plan = client.post("/plan", json={"caption": True, "train": True}).json()
    assert plan["gpu_count"] == 2 and plan["mode"] == "concurrent"
    assert plan["caption"]["gpus"] == [0] and plan["train"]["gpus"] == [1]
    assert [(step["action"], step["service"]) for step in plan["order"]] == [
        ("start", "vllm"),
        ("start", "trainer"),
    ]

    vllm = start(client, "vllm", plan["caption"]["gpus"], vllm_params())
    trainer = start(client, "trainer-ltx", plan["train"]["gpus"], run_config(settings))
    assert in_use(client) == ["vllm", "trainer-ltx"]
    assert "CUDA_VISIBLE_DEVICES='0'" in wait_for_log(vllm["log_path"], "listening on")
    assert "CUDA_VISIBLE_DEVICES='1'" in wait_for_log(trainer["log_path"], "sleeping until")

    # A second trainer cannot take GPU 1; a 0-GPU service runs alongside both.
    error = expect_error(
        client.post(
            "/services/trainer-aitoolkit/start",
            json={"gpus": [1], "params": run_config(settings, run_id="ivan9-flux-001")},
        ),
        409,
        "gpu_busy",
    )
    assert error["detail"] == {"gpu": 1, "service": "trainer-ltx"}
    start(client, "tensorboard", [], {"port": free_port()})
    assert in_use(client) == ["vllm", "trainer-ltx"]

    # Train-only on 2+ GPUs leaves GPU 0 to captioning.
    plan = client.post("/plan", json={"train": True}).json()
    assert plan["mode"] == "single" and plan["caption"] is None
    assert plan["train"]["gpus"] == [1]


def test_topology_four_gpus_reserves_gpu_zero_and_allows_override(
    make_client: ClientFactory, settings: Settings
) -> None:
    client = make_client(4)
    plan = client.post("/plan", json={"train": True}).json()
    assert plan["gpu_count"] == 4 and plan["train"]["gpus"] == [1, 2, 3]
    both = client.post("/plan", json={"caption": True, "train": True}).json()
    assert both["mode"] == "concurrent"
    assert both["caption"]["gpus"] == [0] and both["train"]["gpus"] == [1, 2, 3]

    trainer = start(client, "trainer-ltx", plan["train"]["gpus"], run_config(settings))
    assert trainer["gpus"] == [1, 2, 3]
    assert in_use(client) == [None, "trainer-ltx", "trainer-ltx", "trainer-ltx"]
    text = wait_for_log(trainer["log_path"], "sleeping until SIGTERM")
    assert "CUDA_VISIBLE_DEVICES='1,2,3'" in text
    # GPU 0 stayed free for a re-caption during training.
    vllm = start(client, "vllm", both["caption"]["gpus"], vllm_params())
    assert in_use(client) == ["vllm", "trainer-ltx", "trainer-ltx", "trainer-ltx"]
    wait_for_log(vllm["log_path"], "listening on")

    # The plan is advisory: all four GPUs for training is a legal explicit request, once
    # nothing else holds GPU 0.
    assert client.post("/services/trainer-ltx/stop").json()["state"] == "stopped"
    error = expect_error(
        client.post(
            "/services/trainer-ltx/start",
            json={"gpus": [0, 1, 2, 3], "params": run_config(settings)},
        ),
        409,
        "gpu_busy",
    )
    assert error["detail"] == {"gpu": 0, "service": "vllm"}
    assert client.post("/services/vllm/stop").json()["state"] == "stopped"
    trainer = start(client, "trainer-ltx", [0, 1, 2, 3], run_config(settings))
    assert in_use(client) == ["trainer-ltx"] * 4
    assert "CUDA_VISIBLE_DEVICES='0,1,2,3'" in wait_for_log(
        trainer["log_path"], "sleeping until SIGTERM"
    )


# --- §2.6 services: listing and the state object ------------------------------------------------


def test_services_lists_every_catalog_name_idle(client: TestClient) -> None:
    services = client.get("/services").json()["services"]
    assert [s["name"] for s in services] == list(SERVICE_NAMES)
    assert len(services) == 6
    for state in services:
        assert set(state) == STATE_KEYS
        assert state["state"] == "idle"
        assert state["pid"] is None and state["gpus"] == [] and state["params"] is None
        assert state["exit_code"] is None and state["stopped_by_request"] is False
        assert state["started_at"] is None and state["ended_at"] is None
        assert state["log_path"] is None and state["port"] is None and state["run_id"] is None
    for name in SERVICE_NAMES:
        assert client.get(f"/services/{name}").json() == next(
            s for s in services if s["name"] == name
        )


def test_start_returns_201_and_the_state_object(client: TestClient, settings: Settings) -> None:
    params = vllm_params(api_key=VLLM_SECRET)
    state = start(client, "vllm", [0], params)
    assert set(state) == STATE_KEYS
    assert state["name"] == "vllm" and state["state"] == "running"
    assert isinstance(state["pid"], int) and state["pid"] > 0
    assert state["gpus"] == [0]
    assert state["params"] == {
        "model": "org/fake-vl-model",
        "port": params["port"],
        "max_model_len": 16384,
        "gpu_memory_utilization": 0.9,
        "dtype": "auto",
        "max_num_seqs": 16,
        "served_model_name": None,
        "api_key": "***",
        "extra_args": [],
    }
    assert state["exit_code"] is None and state["stopped_by_request"] is False
    assert ISO_UTC.match(state["started_at"]) and state["ended_at"] is None
    assert state["log_path"] == str(settings.paths.logs / "vllm.log")
    assert state["port"] == params["port"] and state["run_id"] is None

    # Every service endpoint returns the same object.
    assert client.get("/services/vllm").json() == state
    listed = client.get("/services").json()["services"]
    assert next(s for s in listed if s["name"] == "vllm") == state
    assert "VLLM_API_KEY=set" in wait_for_log(state["log_path"], "listening on")

    response = client.post("/services/vllm/stop")
    assert response.status_code == 200, response.text
    stopped = response.json()
    assert stopped["state"] == "stopped"
    assert stopped["exit_code"] == 0 and stopped["stopped_by_request"] is True
    assert stopped["pid"] == state["pid"] and stopped["started_at"] == state["started_at"]
    assert ISO_UTC.match(stopped["ended_at"])
    assert stopped["params"] == state["params"] and stopped["gpus"] == [0]
    assert client.get("/services/vllm").json() == stopped


def test_trainer_start_prepares_the_run_and_reports_run_id(
    client: TestClient, settings: Settings
) -> None:
    state = start(client, "trainer-aitoolkit", [1], run_config(settings, hf_token=HF_SECRET))
    run_dir = settings.paths.run_dir("nora7-h3-001")
    assert state["run_id"] == "nora7-h3-001" and state["port"] is None
    assert state["gpus"] == [1]
    assert state["log_path"] == str(run_dir / "trainer.log")
    assert state["params"]["hf_token"] == "***"
    assert state["params"]["triggers"] == ["NORA7"]
    assert state["params"]["alpha"] == 16  # defaults are filled in and echoed
    written = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
    assert "hf_token" not in written and written["run_id"] == "nora7-h3-001"
    text = wait_for_log(state["log_path"], "sleeping until SIGTERM")
    assert f"cwd={run_dir}" in text
    assert "CUDA_VISIBLE_DEVICES='1'" in text
    assert "HF_TOKEN=set" in text and HF_SECRET not in text
    assert client.get("/gpus").json()["gpus"][1]["in_use_by"] == "trainer-aitoolkit"


def test_transfers_run_to_completion(client: TestClient) -> None:
    state = start(client, "pull-dataset", [], {"repo_id": "org/nora7-faces", "hf_token": HF_SECRET})
    assert state["state"] == "running" and state["gpus"] == [] and state["port"] is None
    assert state["params"]["name"] == "nora7-faces" and state["params"]["hf_token"] == "***"
    done = wait_for_exit(client, "pull-dataset")
    assert done["state"] == "exited" and done["exit_code"] == 0
    assert done["stopped_by_request"] is False and ISO_UTC.match(done["ended_at"])
    assert done["pid"] == state["pid"]
    listed = client.get("/services").json()["services"]
    assert next(s for s in listed if s["name"] == "pull-dataset")["state"] == "exited"
    error = expect_error(client.post("/services/pull-dataset/stop"), 409, "not_running")
    assert error["detail"] == {"state": "exited"}
    lines = client.get("/services/pull-dataset/logs").json()["lines"]
    assert any("transfer complete" in line for line in lines)
    assert HF_SECRET not in "\n".join(lines)

    state = start(client, "push-lora", [], {"run_id": "nora7-h3-001", "repo_id": "org/nora7-lora"})
    assert state["run_id"] == "nora7-h3-001"
    done = wait_for_exit(client, "push-lora")
    assert done["state"] == "exited" and done["exit_code"] == 0


def test_failed_child_is_reported_and_can_be_restarted(
    client: TestClient, settings: Settings
) -> None:
    first = start(client, "trainer-ltx", [1], run_config(settings, extra={"fail": True}))
    done = wait_for_exit(client, "trainer-ltx")
    assert done["state"] == "failed" and done["exit_code"] == 3
    assert done["stopped_by_request"] is False and done["pid"] == first["pid"]
    error = expect_error(client.post("/services/trainer-ltx/stop"), 409, "not_running")
    assert error["detail"] == {"state": "failed"}
    assert in_use(client) == [None, None]
    again = start(client, "trainer-ltx", [1], run_config(settings))
    assert again["state"] == "running" and again["exit_code"] is None
    assert again["ended_at"] is None and again["pid"] != first["pid"]


# --- §2.6 start: the check order and its error codes ------------------------------------------------


def test_unknown_service_is_404_on_every_service_route(client: TestClient) -> None:
    body = {"gpus": [99], "params": {"bogus": 1}}
    for response in (
        client.get("/services/nope"),
        client.post("/services/nope/start", json=body),  # name is checked before params/GPUs
        client.post("/services/nope/stop"),
        client.get("/services/nope/logs"),
        client.get("/services/VLLM"),
    ):
        error = expect_error(response, 404, "not_found")
        assert error["detail"] == {"known": list(SERVICE_NAMES)}


def test_start_invalid_params_422(client: TestClient, settings: Settings) -> None:
    error = expect_error(
        client.post("/services/vllm/start", json={"gpus": [0], "params": {}}),
        422,
        "invalid_params",
    )
    assert "vllm" in error["message"]
    assert isinstance(error["detail"], list)
    assert [(e["type"], e["loc"]) for e in error["detail"]] == [("missing", ["model"])]

    error = expect_error(
        client.post(
            "/services/vllm/start",
            json={"gpus": [0], "params": {"model": "org/m", "bogus": 1}},
        ),
        422,
        "invalid_params",
    )
    assert error["detail"][0]["type"] == "extra_forbidden"

    outside = run_config(settings, dataset={"path": "/elsewhere/faces"})
    error = expect_error(
        client.post("/services/trainer-ltx/start", json={"gpus": [1], "params": outside}),
        422,
        "invalid_params",
    )
    assert error["detail"][0]["type"] == "path_outside_workspace"
    assert error["detail"][0]["loc"] == ["dataset", "path"]
    assert not settings.paths.run_dir("nora7-h3-001").exists()  # prepare() never ran
    assert all(s["state"] == "idle" for s in client.get("/services").json()["services"])


@pytest.mark.parametrize(
    ("name", "gpus"),
    [
        ("vllm", []),
        ("vllm", [0, 1]),
        ("trainer-ltx", []),
        ("trainer-aitoolkit", [1, 1]),
        ("tensorboard", [0]),
        ("pull-dataset", [1]),
        ("push-lora", [0, 1]),
    ],
)
def test_start_gpu_count_422(
    client: TestClient, settings: Settings, name: str, gpus: list[int]
) -> None:
    params: dict[str, Any]
    if name == "vllm":
        params = vllm_params()
    elif name.startswith("trainer-"):
        params = run_config(settings)
    elif name == "pull-dataset":
        params = {"repo_id": "org/faces"}
    elif name == "push-lora":
        params = {"run_id": "nora7-h3-001", "repo_id": "org/nora7-lora"}
    else:
        params = {"port": free_port()}
    error = expect_error(
        client.post(f"/services/{name}/start", json={"gpus": gpus, "params": params}),
        422,
        "gpu_count",
    )
    assert error["detail"]["requested"] == gpus
    assert set(error["detail"]) == {"requested", "min", "max"}
    assert client.get(f"/services/{name}").json()["state"] == "idle"


def test_start_unknown_gpu_422(client: TestClient, settings: Settings) -> None:
    error = expect_error(
        client.post("/services/vllm/start", json={"gpus": [2], "params": vllm_params()}),
        422,
        "unknown_gpu",
    )
    assert error["detail"] == {"gpu": 2, "known": [0, 1]}
    error = expect_error(
        client.post(
            "/services/trainer-ltx/start", json={"gpus": [1, 7], "params": run_config(settings)}
        ),
        422,
        "unknown_gpu",
    )
    assert error["detail"]["gpu"] == 7
    expect_error(
        client.post("/services/vllm/start", json={"gpus": [-1], "params": vllm_params()}),
        422,
        "unknown_gpu",
    )
    assert in_use(client) == [None, None]


def test_start_gpu_busy_409(client: TestClient, settings: Settings) -> None:
    start(client, "vllm", [0], vllm_params())
    error = expect_error(
        client.post(
            "/services/trainer-ltx/start", json={"gpus": [0, 1], "params": run_config(settings)}
        ),
        409,
        "gpu_busy",
    )
    assert error["detail"] == {"gpu": 0, "service": "vllm"}
    assert error["message"] == "GPU 0 is in use by vllm"
    assert client.get("/services/trainer-ltx").json()["state"] == "idle"
    assert in_use(client) == ["vllm", None]


def test_start_already_running_409(client: TestClient) -> None:
    first = start(client, "tensorboard", [], {"port": free_port()})
    error = expect_error(
        client.post("/services/tensorboard/start", json={"params": {"port": free_port()}}),
        409,
        "already_running",
    )
    assert error["detail"] == {"pid": first["pid"], "state": "running"}
    assert client.get("/services/tensorboard").json()["pid"] == first["pid"]


def test_start_check_order(client: TestClient, settings: Settings) -> None:
    """name → params → GPU count → index exists → not busy → not already running."""
    # params before GPU count: an empty list would be a gpu_count error, but params fail first
    expect_error(
        client.post("/services/vllm/start", json={"gpus": [], "params": {}}), 422, "invalid_params"
    )
    # GPU count before the index check: 7 does not exist, but two GPUs is the earlier problem
    error = expect_error(
        client.post("/services/vllm/start", json={"gpus": [0, 7], "params": vllm_params()}),
        422,
        "gpu_count",
    )
    assert error["detail"]["requested"] == [0, 7]
    start(client, "vllm", [0], vllm_params())
    # index before busy: 5 does not exist, even though vllm is running
    expect_error(
        client.post("/services/vllm/start", json={"gpus": [5], "params": vllm_params()}),
        422,
        "unknown_gpu",
    )
    # busy before already_running: restarting vllm on its own GPU is reported as busy
    error = expect_error(
        client.post("/services/vllm/start", json={"gpus": [0], "params": vllm_params()}),
        409,
        "gpu_busy",
    )
    assert error["detail"]["service"] == "vllm"
    # ... and on the free GPU, as already running
    expect_error(
        client.post("/services/vllm/start", json={"gpus": [1], "params": vllm_params()}),
        409,
        "already_running",
    )
    assert in_use(client) == ["vllm", None]


@pytest.mark.parametrize(
    "body",
    [
        None,
        [],
        "vllm",
        {"gpus": "0", "params": {}},
        {"gpus": [0.5], "params": {}},
        {"gpus": ["a"], "params": {}},
        {"gpus": [0], "params": []},
        {"gpus": [0], "params": "model=x"},
        {"gpus": [0], "params": {}, "extra": 1},
        {"gpus": [0], "params": {"model": "org/m"}, "name": "vllm"},
    ],
    ids=[
        "no-body",
        "list",
        "string",
        "gpus-str",
        "gpus-float",
        "gpus-strs",
        "params-list",
        "params-str",
        "extra-key",
        "name-key",
    ],
)
def test_start_body_shape_422(client: TestClient, body: Any) -> None:
    error = expect_error(client.post("/services/vllm/start", json=body), 422, "validation")
    assert isinstance(error["detail"], list) and error["detail"]
    assert all(entry["loc"][0] == "body" for entry in error["detail"])
    assert client.get("/services/vllm").json()["state"] == "idle"


# --- §2.6 stop -------------------------------------------------------------------------------------


def test_stop_not_running_409(client: TestClient) -> None:
    for name in SERVICE_NAMES:
        error = expect_error(client.post(f"/services/{name}/stop"), 409, "not_running")
        assert error["detail"] == {"state": "idle"}
    state = start(client, "tensorboard", [], {"port": free_port()})
    wait_for_log(state["log_path"], "listening on")
    assert client.post("/services/tensorboard/stop").status_code == 200
    error = expect_error(client.post("/services/tensorboard/stop"), 409, "not_running")
    assert error["detail"] == {"state": "stopped"}


def test_stop_accepts_no_body_or_an_empty_one(client: TestClient) -> None:
    for body in (None, {}, {"timeout_s": 5}):
        state = start(client, "tensorboard", [], {"port": free_port()})
        wait_for_log(state["log_path"], "listening on")
        response = client.post("/services/tensorboard/stop", json=body)
        assert response.status_code == 200, (body, response.text)
        assert response.json()["state"] == "stopped" and response.json()["exit_code"] == 0


def test_stop_timeout_escalates_to_sigkill(client: TestClient) -> None:
    state = start(client, "vllm", [0], vllm_params(extra_args=["--ignore-sigterm"]))
    wait_for_log(state["log_path"], "sleeping until SIGTERM")
    t0 = time.monotonic()
    response = client.post("/services/vllm/stop", json={"timeout_s": 1})
    elapsed = time.monotonic() - t0
    assert response.status_code == 200, response.text
    stopped = response.json()
    assert stopped["state"] == "stopped" and stopped["stopped_by_request"] is True
    assert stopped["exit_code"] == -9
    assert 1.0 <= elapsed < WAIT_S
    assert in_use(client) == [None, None]


@pytest.mark.parametrize(
    "body",
    [
        {"timeout_s": 0},
        {"timeout_s": 0.5},
        {"timeout_s": MAX_STOP_TIMEOUT_S + 1},
        {"timeout_s": "soon"},
        {"timeout": 5},
        [],
    ],
    ids=["zero", "half", "too-long", "string", "wrong-key", "list"],
)
def test_stop_body_shape_422(client: TestClient, body: Any) -> None:
    state = start(client, "tensorboard", [], {"port": free_port()})
    error = expect_error(client.post("/services/tensorboard/stop", json=body), 422, "validation")
    assert isinstance(error["detail"], list) and error["detail"]
    assert client.get("/services/tensorboard").json()["pid"] == state["pid"]
    assert client.get("/services/tensorboard").json()["state"] == "running"


def test_stop_timeout_is_capped_under_the_proxy_cutoff(client: TestClient) -> None:
    # The call blocks for the whole SIGTERM wait and the RunPod proxy cuts requests at 100 s,
    # so the largest accepted wait stays observable; one second more is refused up front.
    assert MAX_STOP_TIMEOUT_S <= 90
    state = start(client, "tensorboard", [], {"port": free_port()})
    wait_for_log(state["log_path"], "listening on")
    error = expect_error(
        client.post("/services/tensorboard/stop", json={"timeout_s": MAX_STOP_TIMEOUT_S + 0.5}),
        422,
        "validation",
    )
    assert error["detail"][0]["loc"] == ["body", "timeout_s"]
    assert client.get("/services/tensorboard").json()["state"] == "running"
    # The cap itself is accepted; a cooperative child exits long before it.
    response = client.post("/services/tensorboard/stop", json={"timeout_s": MAX_STOP_TIMEOUT_S})
    assert response.status_code == 200, response.text
    assert response.json()["state"] == "stopped" and response.json()["exit_code"] == 0


# --- §2.6 logs -------------------------------------------------------------------------------------


def test_logs_404_before_the_first_start(client: TestClient) -> None:
    for name in SERVICE_NAMES:
        error = expect_error(client.get(f"/services/{name}/logs"), 404, "not_found")
        assert name in error["message"]


def test_logs_tail_bounds_and_truncation(client: TestClient) -> None:
    state = start(client, "tensorboard", [], {"port": free_port()})
    wait_for_log(state["log_path"], "listening on")

    full = client.get("/services/tensorboard/logs", params={"tail": 5000}).json()
    assert set(full) == {"name", "path", "lines", "truncated"}
    assert full["name"] == "tensorboard" and full["path"] == state["log_path"]
    assert full["truncated"] is False
    assert full["lines"][0] == "fakeservice: name=tensorboard"
    assert 5 <= len(full["lines"]) < 200
    assert client.get("/services/tensorboard/logs").json() == full  # default tail 200

    one = client.get("/services/tensorboard/logs", params={"tail": 1}).json()
    assert one["lines"] == full["lines"][-1:] and one["truncated"] is True
    two = client.get("/services/tensorboard/logs", params={"tail": 2}).json()
    assert two["lines"] == full["lines"][-2:] and two["truncated"] is True
    exact = client.get("/services/tensorboard/logs", params={"tail": len(full["lines"])}).json()
    assert exact["lines"] == full["lines"] and exact["truncated"] is False

    for bad in ("0", "5001", "-1", "abc", "1.5", ""):
        error = expect_error(
            client.get("/services/tensorboard/logs", params={"tail": bad}), 422, "validation"
        )
        assert error["detail"][0]["loc"] == ["query", "tail"], bad


def test_logs_survive_a_stop_and_restart_truncates(client: TestClient) -> None:
    port = free_port()
    first = start(client, "tensorboard", [], {"port": port})
    wait_for_log(first["log_path"], "listening on")
    assert client.post("/services/tensorboard/stop").status_code == 200
    lines = client.get("/services/tensorboard/logs").json()["lines"]
    assert any("exiting 0" in line for line in lines)
    assert sum(line == "fakeservice: name=tensorboard" for line in lines) == 1

    second = start(client, "tensorboard", [], {"port": port})
    assert second["log_path"] == first["log_path"]
    wait_for_log(second["log_path"], "listening on")
    lines = client.get("/services/tensorboard/logs").json()["lines"]
    assert sum(line == "fakeservice: name=tensorboard" for line in lines) == 1
    assert f"fakeservice: pid={second['pid']}" in lines
    assert f"fakeservice: pid={first['pid']}" not in lines


def test_logs_404_when_the_file_is_gone(client: TestClient) -> None:
    state = start(client, "tensorboard", [], {"port": free_port()})
    wait_for_log(state["log_path"], "listening on")
    assert client.post("/services/tensorboard/stop").status_code == 200
    Path(state["log_path"]).unlink()
    expect_error(client.get("/services/tensorboard/logs"), 404, "not_found")


# --- secrets never come back ------------------------------------------------------------------------


def test_params_echo_redacts_secrets_everywhere(client: TestClient, settings: Settings) -> None:
    vllm = start(client, "vllm", [0], vllm_params(api_key=VLLM_SECRET))
    trainer = start(client, "trainer-ltx", [1], run_config(settings, hf_token=HF_SECRET))
    pull = start(client, "pull-dataset", [], {"repo_id": "org/faces", "hf_token": HF_SECRET})
    assert vllm["params"]["api_key"] == "***"
    assert trainer["params"]["hf_token"] == "***"
    assert pull["params"]["hf_token"] == "***"
    wait_for_log(vllm["log_path"], "listening on")
    wait_for_log(trainer["log_path"], "sleeping until SIGTERM")
    wait_for_exit(client, "pull-dataset")

    responses = [
        client.get("/services"),
        client.get("/services/vllm"),
        client.get("/services/trainer-ltx"),
        client.get("/services/pull-dataset"),
        client.get("/services/vllm/logs"),
        client.get("/services/trainer-ltx/logs"),
        client.get("/services/pull-dataset/logs"),
        client.get("/gpus"),
        client.post("/services/vllm/stop"),
        client.post("/services/trainer-ltx/stop"),
        client.get("/services"),
    ]
    for response in responses:
        assert response.status_code == 200, response.text
        assert VLLM_SECRET not in response.text
        assert HF_SECRET not in response.text
    listed = {s["name"]: s for s in responses[-1].json()["services"]}
    assert listed["vllm"]["params"]["api_key"] == "***"
    assert listed["trainer-ltx"]["params"]["hf_token"] == "***"
    # Nor do they land on disk where a push could pick them up.
    run_json = (settings.paths.run_dir("nora7-h3-001") / "run.json").read_text(encoding="utf-8")
    assert HF_SECRET not in run_json
    for log in (vllm["log_path"], trainer["log_path"], pull["log_path"]):
        assert HF_SECRET not in Path(log).read_text() and VLLM_SECRET not in Path(log).read_text()


def test_invalid_params_detail_redacts_secrets(client: TestClient) -> None:
    # A model-level error (name derived from an unusable repo name) echoes the whole input.
    response = client.post(
        "/services/pull-dataset/start",
        json={"gpus": [], "params": {"repo_id": "org/.hidden", "hf_token": HF_SECRET}},
    )
    error = expect_error(response, 422, "invalid_params")
    assert error["detail"][0]["input"]["hf_token"] == "***"
    assert error["detail"][0]["input"]["repo_id"] == "org/.hidden"
    assert HF_SECRET not in response.text
    # A field-level error on the secret itself echoes nothing of it either.
    response = client.post(
        "/services/vllm/start",
        json={"gpus": [0], "params": {"model": "org/m", "api_key": ""}},
    )
    error = expect_error(response, 422, "invalid_params")
    assert error["detail"][0]["loc"] == ["api_key"] and error["detail"][0]["input"] == "***"


# --- lifespan ---------------------------------------------------------------------------------------


def test_lifespan_shutdown_stops_every_running_child(app: FastAPI) -> None:
    with TestClient(app, headers=AUTH) as client:
        vllm = start(client, "vllm", [0], vllm_params())
        tensorboard = start(client, "tensorboard", [], {"port": free_port()})
        wait_for_log(vllm["log_path"], "listening on")
        wait_for_log(tensorboard["log_path"], "listening on")
        assert in_use(client) == ["vllm", None]
    states = {s.name: s for s in app.state.supervisor.states()}
    for name in ("vllm", "tensorboard"):
        assert states[name].state == "stopped", name
        assert states[name].stopped_by_request is True and states[name].exit_code == 0
    assert all(s.state == "idle" for n, s in states.items() if n not in ("vllm", "tensorboard"))
    for pid in (vllm["pid"], tensorboard["pid"]):
        with pytest.raises(ProcessLookupError):
            os.kill(pid, 0)
    assert app.state.supervisor.inventory()[0]["in_use_by"] is None


# --- python -m podagent -----------------------------------------------------------------------------


def _clean_env() -> dict[str, str]:
    return {k: v for k, v in os.environ.items() if not k.startswith("PODAGENT_")}


@pytest.mark.parametrize(
    ("env", "needle"),
    [
        ({}, "PODAGENT_TOKEN"),
        ({"PODAGENT_TOKEN": ""}, "PODAGENT_TOKEN"),
        ({"PODAGENT_TOKEN": "short"}, "16 characters"),
        ({"PODAGENT_TOKEN": TOKEN, "PODAGENT_FAKE_GPUS": "two"}, "PODAGENT_FAKE_GPUS"),
    ],
    ids=["unset", "blank", "short", "bad-fake-gpus"],
)
def test_main_exits_2_without_a_usable_token(
    tmp_path: Path, env: dict[str, str], needle: str
) -> None:
    completed = subprocess.run(
        [sys.executable, "-m", "podagent", "--port", "0"],
        env={**_clean_env(), **env},
        cwd=tmp_path,  # nothing importable here: the installed package is what runs
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert completed.returncode == 2, completed
    assert completed.stdout == ""
    assert completed.stderr.startswith("podagent: ")
    assert needle in completed.stderr
    assert "refusing to start" in completed.stderr or "must be" in completed.stderr
    assert "Traceback" not in completed.stderr


def test_main_in_process_refuses_without_token(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.delenv("PODAGENT_TOKEN", raising=False)
    assert podagent_main([]) == 2
    captured = capsys.readouterr()
    assert captured.out == "" and "PODAGENT_TOKEN" in captured.err


def test_main_serves_the_configured_app(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    import uvicorn

    calls: list[tuple[Any, dict[str, Any]]] = []
    monkeypatch.setattr(uvicorn, "run", lambda app, **kwargs: calls.append((app, kwargs)))
    monkeypatch.setenv("PODAGENT_TOKEN", TOKEN)
    monkeypatch.setenv("PODAGENT_FAKE_GPUS", "1")
    monkeypatch.setenv("PODAGENT_WORKSPACE", str(tmp_path / "ws"))
    monkeypatch.setenv("PODAGENT_PREFIX", str(tmp_path / "opt"))

    assert podagent_main(["--host", "127.0.0.1", "--port", "18800"]) == 0

    ((app, kwargs),) = calls
    assert isinstance(app, FastAPI)
    assert app.state.settings.token == TOKEN
    assert app.state.backend.kind == "fake" and len(app.state.backend.list_gpus()) == 1
    assert app.state.settings.paths.workspace == tmp_path / "ws"
    assert kwargs["host"] == "127.0.0.1" and kwargs["port"] == 18800
    assert (tmp_path / "ws" / "logs").is_dir()  # the workspace layout exists before serving
    with TestClient(app, headers=AUTH) as client:
        assert client.get("/health").json()["gpu_count"] == 1


# --- §2.4/§2.5 inventory unavailable is 503, never "no GPUs" ----------------------------------------


class _FlakyBackend:
    kind = "fake"

    def __init__(self, count: int = 1) -> None:
        self.inner = FakeBackend(count)
        self.fail = False

    def list_gpus(self) -> list[Any]:
        if self.fail:
            raise InventoryUnavailable("nvidia-smi did not finish within 10 s")
        return self.inner.list_gpus()


def test_inventory_unavailable_is_503_on_gpus_plan_and_start(settings: Settings) -> None:
    backend = _FlakyBackend(1)
    backend.fail = True
    with TestClient(create_app(settings, backend), headers=AUTH) as client:
        # /health keeps answering: the agent is fine, the count is unknown.
        health = client.get("/health").json()
        assert health["status"] == "ok" and health["gpu_count"] is None
        assert set(health) == HEALTH_KEYS

        error = expect_error(client.get("/gpus"), 503, "gpu_inventory_unavailable")
        assert "10 s" in error["message"]
        assert error["detail"] == {"last_known_count": None, "last_known_at": None}
        error = expect_error(
            client.post("/plan", json={"caption": True, "train": True}),
            503,
            "gpu_inventory_unavailable",
        )
        assert "no GPUs" not in error["message"]
        # An explicit gpu_count needs no inventory.
        plan = client.post("/plan", json={"caption": True, "train": True, "gpu_count": 1}).json()
        assert plan["mode"] == "sequential"
        error = expect_error(
            client.post("/services/vllm/start", json={"gpus": [0], "params": vllm_params()}),
            503,
            "gpu_inventory_unavailable",
        )
        assert error["code"] != "unknown_gpu"
        assert client.get("/services/vllm").json()["state"] == "idle"
        # A 0-GPU service does not consult the inventory.
        start(client, "tensorboard", [], {"port": free_port()})

        backend.fail = False
        assert client.get("/health").json()["gpu_count"] == 1
        vllm = start(client, "vllm", [0], vllm_params())
        backend.fail = True
        error = expect_error(client.get("/gpus"), 503, "gpu_inventory_unavailable")
        assert error["detail"]["last_known_count"] == 1
        assert ISO_UTC.match(error["detail"]["last_known_at"].replace("+00:00", "Z"))
        # The running service is unaffected by the hiccup.
        assert client.get("/services/vllm").json()["pid"] == vllm["pid"]
        backend.fail = False
        assert in_use(client) == ["vllm"]


# --- §2.8 /runs/{id}/log ---------------------------------------------------------------------------


def test_run_log_serves_the_trainer_log_of_any_run(client: TestClient, settings: Settings) -> None:
    expect_error(client.get("/runs/nora7-h3-001/log"), 404, "not_found")  # no such run
    error = expect_error(client.get("/runs/-leading-dash/log"), 422, "validation")
    assert error["detail"]["field"] == "run_id"
    expect_error(client.get("/runs/nora7-h3-001/log", params={"tail": 0}), 422, "validation")

    # A run from an earlier agent lifetime: only the files on the volume exist.
    run_dir = settings.paths.run_dir("nora7-h3-001")
    run_dir.mkdir(parents=True)
    error = expect_error(client.get("/runs/nora7-h3-001/log"), 404, "not_found")
    assert error["detail"] == {"path": str(run_dir / "trainer.log")}
    (run_dir / "trainer.log").write_text("".join(f"step {i}\n" for i in range(300)))
    body = client.get("/runs/nora7-h3-001/log").json()
    assert set(body) == {"run_id", "path", "lines", "truncated"}
    assert body["run_id"] == "nora7-h3-001" and body["path"] == str(run_dir / "trainer.log")
    assert len(body["lines"]) == 200 and body["truncated"] is True  # default tail
    assert body["lines"][-1] == "step 299"
    two = client.get("/runs/nora7-h3-001/log", params={"tail": 2}).json()
    assert two["lines"] == ["step 298", "step 299"]
    # /services/trainer-*/logs cannot reach it (no run since boot), and says where to look.
    error = expect_error(client.get("/services/trainer-aitoolkit/logs"), 404, "not_found")
    assert "/runs/{id}/log" in error["message"]

    # A run this agent started is the same file through either door.
    state = start(client, "trainer-ltx", [1], run_config(settings))
    wait_for_log(state["log_path"], "sleeping until SIGTERM")
    assert client.post("/services/trainer-ltx/stop").status_code == 200
    via_run = client.get("/runs/nora7-h3-001/log", params={"tail": 5000}).json()["lines"]
    via_service = client.get("/services/trainer-ltx/logs", params={"tail": 5000}).json()["lines"]
    assert via_run == via_service and "fakeservice: name=trainer-ltx" in via_run


def test_service_logs_fall_back_to_the_volume_file(client: TestClient, settings: Settings) -> None:
    (settings.paths.logs / "pull-dataset.log").write_text("from before the restart\n")
    body = client.get("/services/pull-dataset/logs").json()
    assert body["lines"] == ["from before the restart"]
    assert body["path"] == str(settings.paths.logs / "pull-dataset.log")


def test_run_log_requires_the_bearer(anon_client: TestClient) -> None:
    assert anon_client.get("/runs/nora7-h3-001/log").status_code == 401
