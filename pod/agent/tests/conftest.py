"""Shared fixtures for the agent test suite.

Everything runs in fake mode (``FakeBackend`` for the inventory, ``podagent.fakeservice``
children for the services) over a tmp workspace. ``client`` and ``anon_client`` enter the
app's lifespan, so the supervisor's shutdown hook stops whatever a test left running;
``make_client`` builds extra clients over inventories of other sizes (the topology rule needs
1 and 4 GPUs as well as the default 2).
"""

from __future__ import annotations

import contextlib
import socket
from collections.abc import Callable, Iterator
from dataclasses import replace
from pathlib import Path

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from podagent.app import create_app
from podagent.catalog import CATALOG
from podagent.gpus import FakeBackend
from podagent.settings import Paths, Settings

TOKEN = "test-token-0123456789"
AUTH = {"Authorization": f"Bearer {TOKEN}"}
GPU_COUNT = 2

ClientFactory = Callable[..., TestClient]


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(
        token=TOKEN,
        paths=Paths(workspace=tmp_path / "workspace", prefix=tmp_path / "opt"),
        fake_gpus=GPU_COUNT,
    )


@pytest.fixture
def fast_transfers(monkeypatch: pytest.MonkeyPatch) -> None:
    """Fake ``pull-dataset`` / ``push-lora`` children exit after 0.3 s instead of 2 s."""
    monkeypatch.setenv("PODAGENT_FAKE_TRANSFER_S", "0.3")


@pytest.fixture
def app(settings: Settings, fast_transfers: None) -> FastAPI:
    return create_app(settings, FakeBackend(settings.fake_gpus or 0))


@pytest.fixture
def client(app: FastAPI) -> Iterator[TestClient]:
    """Authenticated client over the 2-GPU fake app; leaving it runs the shutdown hook."""
    with TestClient(app, headers=AUTH) as client:
        yield client


@pytest.fixture
def anon_client(settings: Settings, fast_transfers: None) -> Iterator[TestClient]:
    """No default bearer, over its own app (nothing is ever started through it)."""
    with TestClient(create_app(settings, FakeBackend(GPU_COUNT))) as client:
        yield client


@pytest.fixture
def make_client(settings: Settings, fast_transfers: None) -> Iterator[ClientFactory]:
    """``make_client(gpu_count, auth=True)``: a client over a fresh app with that inventory."""
    with contextlib.ExitStack() as stack:

        def factory(gpu_count: int = GPU_COUNT, *, auth: bool = True) -> TestClient:
            app = create_app(replace(settings, fake_gpus=gpu_count), FakeBackend(gpu_count))
            return stack.enter_context(TestClient(app, headers=AUTH if auth else None))

        yield factory


@pytest.fixture
def tensorboard_port(monkeypatch: pytest.MonkeyPatch) -> int:
    """TensorBoard's port is fixed by the catalog (6006 on a pod, and the proxy's target); tests
    that start one move it to a free port so they never collide with each other or the host."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        port = int(sock.getsockname()[1])
    monkeypatch.setitem(CATALOG, "tensorboard", replace(CATALOG["tensorboard"], port=port))
    return port
