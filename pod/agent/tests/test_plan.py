"""The GPU topology rule (POD-SPEC §2.5): ``plan()`` directly and through ``POST /plan``."""

from __future__ import annotations

import itertools
from dataclasses import replace
from typing import Any

import pytest
from fastapi.testclient import TestClient

from podagent.app import create_app
from podagent.errors import BadRequest
from podagent.gpus import FakeBackend
from podagent.plan import CAPTION_SERVICE, MAX_GPUS, TRAIN_SERVICE, PlanRequest, plan
from podagent.settings import Settings

# (gpu_count, caption, train) -> (mode, caption gpus, train gpus, order).
# Written out literally, one row per cell of the spec's table, so this is an independent
# statement of the rule rather than a second implementation of it.
EXPECTED: dict[tuple[int, bool, bool], tuple[str, list[int] | None, list[int] | None, list]] = {
    (1, True, False): ("single", [0], None, [("start", "vllm")]),
    (1, False, True): ("single", None, [0], [("start", "trainer")]),
    (1, True, True): (
        "sequential",
        [0],
        [0],
        [("start", "vllm"), ("stop", "vllm"), ("start", "trainer")],
    ),
    (2, True, False): ("single", [0], None, [("start", "vllm")]),
    (2, False, True): ("single", None, [1], [("start", "trainer")]),
    (2, True, True): ("concurrent", [0], [1], [("start", "vllm"), ("start", "trainer")]),
    (4, True, False): ("single", [0], None, [("start", "vllm")]),
    (4, False, True): ("single", None, [1, 2, 3], [("start", "trainer")]),
    (4, True, True): ("concurrent", [0], [1, 2, 3], [("start", "vllm"), ("start", "trainer")]),
}

SHAPES = [(True, False), (False, True), (True, True)]


def expected_json(count: int, caption: bool, train: bool) -> dict[str, Any]:
    """The exact wire form of the expected plan, as POD-SPEC §2.5 shows it."""
    mode, caption_gpus, train_gpus, order = EXPECTED[(count, caption, train)]
    return {
        "gpu_count": count,
        "mode": mode,
        "caption": None if caption_gpus is None else {"service": "vllm", "gpus": caption_gpus},
        "train": None if train_gpus is None else {"service": "trainer", "gpus": train_gpus},
        "order": [{"action": action, "service": service} for action, service in order],
    }


def client_with_gpus(settings: Settings, count: int) -> TestClient:
    """An authenticated client over an app whose fake inventory has ``count`` GPUs."""
    settings = replace(settings, fake_gpus=count)
    app = create_app(settings, FakeBackend(count))
    return TestClient(app, headers={"Authorization": f"Bearer {settings.token}"})


# --- plan() directly ---------------------------------------------------------------------


@pytest.mark.parametrize(("count", "caption", "train"), sorted(EXPECTED))
def test_plan_table(count: int, caption: bool, train: bool) -> None:
    mode, caption_gpus, train_gpus, order = EXPECTED[(count, caption, train)]
    result = plan(PlanRequest(caption=caption, train=train), count)

    assert result.gpu_count == count
    assert result.mode == mode
    if caption_gpus is None:
        assert result.caption is None
    else:
        assert result.caption is not None
        assert result.caption.service == CAPTION_SERVICE == "vllm"
        assert result.caption.gpus == caption_gpus
    if train_gpus is None:
        assert result.train is None
    else:
        assert result.train is not None
        assert result.train.service == TRAIN_SERVICE == "trainer"
        assert result.train.gpus == train_gpus
    assert [(step.action, step.service) for step in result.order] == order


def test_plan_matches_spec_example() -> None:
    """The response for one GPU and both stages is the example in POD-SPEC §2.5, verbatim."""
    result = plan(PlanRequest(caption=True, train=True), 1)
    assert result.model_dump(mode="json") == {
        "gpu_count": 1,
        "mode": "sequential",
        "caption": {"service": "vllm", "gpus": [0]},
        "train": {"service": "trainer", "gpus": [0]},
        "order": [
            {"action": "start", "service": "vllm"},
            {"action": "stop", "service": "vllm"},
            {"action": "start", "service": "trainer"},
        ],
    }


@pytest.mark.parametrize(("caption", "train"), SHAPES)
def test_plan_zero_gpus_is_bad_request(caption: bool, train: bool) -> None:
    with pytest.raises(BadRequest) as excinfo:
        plan(PlanRequest(caption=caption, train=train), 0)
    assert excinfo.value.code == "bad_request"
    assert excinfo.value.status == 400
    assert "no GPUs" in excinfo.value.message
    assert excinfo.value.detail == {"gpu_count": 0}


@pytest.mark.parametrize("count", [0, 1, 2, 4])
def test_plan_neither_requested_is_bad_request(count: int) -> None:
    with pytest.raises(BadRequest) as excinfo:
        plan(PlanRequest(), count)
    assert excinfo.value.code == "bad_request"
    assert "caption" in excinfo.value.message and "train" in excinfo.value.message


def test_plan_request_gpu_count_overrides_inventory() -> None:
    # The app plans before the pod exists: the body's count wins over whatever the agent has.
    result = plan(PlanRequest(caption=True, train=True, gpu_count=1), 4)
    assert result.gpu_count == 1 and result.mode == "sequential"
    assert result.train is not None and result.train.gpus == [0]

    result = plan(PlanRequest(caption=True, train=True, gpu_count=4), 1)
    assert result.gpu_count == 4 and result.mode == "concurrent"
    assert result.train is not None and result.train.gpus == [1, 2, 3]

    with pytest.raises(BadRequest):
        plan(PlanRequest(caption=True, gpu_count=0), 8)


def test_plan_request_rejects_negative_and_unknown_fields() -> None:
    with pytest.raises(ValueError):
        PlanRequest(caption=True, gpu_count=-1)
    with pytest.raises(ValueError):
        PlanRequest(caption=True, gpus=[0])  # type: ignore[call-arg]


def test_plan_request_gpu_count_is_bounded_above() -> None:
    """A client cannot ask the agent to materialise an arbitrarily large assignment."""
    assert PlanRequest(caption=True, gpu_count=MAX_GPUS).gpu_count == MAX_GPUS
    with pytest.raises(ValueError):
        PlanRequest(caption=True, gpu_count=MAX_GPUS + 1)
    with pytest.raises(ValueError):
        PlanRequest(caption=True, gpu_count=2_000_000_000)


def test_plan_clamps_inventory_count_to_max_gpus() -> None:
    """A corrupt or hostile inventory size cannot blow up the assignment either."""
    result = plan(PlanRequest(caption=True, train=True), 2_000_000_000)
    assert result.gpu_count == MAX_GPUS
    assert result.train is not None
    assert result.train.gpus == list(range(1, MAX_GPUS))
    assert len(result.train.gpus) == MAX_GPUS - 1

    # At the ceiling itself nothing is clamped.
    result = plan(PlanRequest(train=True), MAX_GPUS)
    assert result.gpu_count == MAX_GPUS and len(result.train.gpus) == MAX_GPUS - 1  # type: ignore[union-attr]


@pytest.mark.parametrize(
    ("count", "caption", "train"),
    [(n, c, t) for n in range(1, 9) for c, t in SHAPES],
)
def test_plan_invariants(count: int, caption: bool, train: bool) -> None:
    """Properties that hold for every GPU count, beyond the four the table spells out."""
    result = plan(PlanRequest(caption=caption, train=train), count)
    assignments = [a for a in (result.caption, result.train) if a is not None]

    # Every assigned index exists, assignments are non-empty and ascending without gaps.
    for assignment in assignments:
        assert assignment.gpus, assignment
        assert all(0 <= g < count for g in assignment.gpus)
        assert assignment.gpus == list(range(assignment.gpus[0], assignment.gpus[-1] + 1))

    # Captioning always has GPU 0; with 2+ GPUs the trainer never touches it.
    if result.caption is not None:
        assert result.caption.gpus == [0]
    if result.train is not None and count >= 2:
        assert 0 not in result.train.gpus
        assert result.train.gpus == list(range(1, count))

    # Mode follows the request shape and the count alone.
    if caption and train:
        assert result.mode == ("sequential" if count == 1 else "concurrent")
    else:
        assert result.mode == "single"

    # Concurrent means disjoint; sequential means the stop sits between the two starts.
    if result.mode == "concurrent":
        assert result.caption is not None and result.train is not None
        assert not set(result.caption.gpus) & set(result.train.gpus)
    if result.mode == "sequential":
        actions = [(s.action, s.service) for s in result.order]
        assert actions.index(("stop", "vllm")) == actions.index(("start", "vllm")) + 1
        assert actions.index(("start", "trainer")) == actions.index(("stop", "vllm")) + 1

    # The order only names services that have an assignment, and starts each exactly once.
    named = {a.service for a in assignments}
    assert {s.service for s in result.order} == named
    starts = [s.service for s in result.order if s.action == "start"]
    assert sorted(starts) == sorted(named)


# --- POST /plan through the app ----------------------------------------------------------


@pytest.mark.parametrize(("count", "caption", "train"), sorted(EXPECTED))
def test_plan_route_table(client: TestClient, count: int, caption: bool, train: bool) -> None:
    # The fixture's inventory is 2 fake GPUs; the body's gpu_count overrides it.
    response = client.post("/plan", json={"caption": caption, "train": train, "gpu_count": count})
    assert response.status_code == 200, response.text
    assert response.json() == expected_json(count, caption, train)


@pytest.mark.parametrize("count", [1, 2, 4])
@pytest.mark.parametrize(("caption", "train"), SHAPES)
def test_plan_route_defaults_to_inventory(
    settings: Settings, count: int, caption: bool, train: bool
) -> None:
    with client_with_gpus(settings, count) as client:
        response = client.post("/plan", json={"caption": caption, "train": train})
    assert response.status_code == 200, response.text
    assert response.json() == expected_json(count, caption, train)


def test_plan_route_explicit_null_gpu_count_means_inventory(client: TestClient) -> None:
    response = client.post("/plan", json={"caption": True, "train": True, "gpu_count": None})
    assert response.status_code == 200
    assert response.json() == expected_json(2, True, True)


def test_plan_route_override_beats_inventory(settings: Settings) -> None:
    with client_with_gpus(settings, 4) as client:
        response = client.post("/plan", json={"caption": True, "train": True, "gpu_count": 1})
    assert response.status_code == 200
    assert response.json() == expected_json(1, True, True)


@pytest.mark.parametrize(("caption", "train"), SHAPES)
def test_plan_route_zero_gpus(settings: Settings, caption: bool, train: bool) -> None:
    # Zero by override ...
    with client_with_gpus(settings, 2) as client:
        response = client.post("/plan", json={"caption": caption, "train": train, "gpu_count": 0})
    assert response.status_code == 400
    body = response.json()
    assert body["error"]["code"] == "bad_request"
    assert "no GPUs" in body["error"]["message"]
    assert body["error"]["detail"] == {"gpu_count": 0}

    # ... and zero by inventory (the nvidia-smi backend returns [] when the driver is absent).
    with client_with_gpus(settings, 0) as client:
        response = client.post("/plan", json={"caption": caption, "train": train})
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "bad_request"


@pytest.mark.parametrize(
    "body",
    [{}, {"caption": False, "train": False}, {"caption": False, "train": False, "gpu_count": 4}],
)
def test_plan_route_neither_requested(client: TestClient, body: dict[str, Any]) -> None:
    response = client.post("/plan", json=body)
    assert response.status_code == 400
    error = response.json()["error"]
    assert error["code"] == "bad_request"
    assert "caption" in error["message"] and "train" in error["message"]


@pytest.mark.parametrize(
    "body",
    [
        {"caption": True, "gpu_count": -1},
        {"caption": True, "gpu_count": MAX_GPUS + 1},
        {"train": True, "gpu_count": 2_000_000_000},
        {"caption": True, "gpus": [0]},
        {"caption": "maybe"},
        {"caption": True, "train": 2},
        {"caption": True, "gpu_count": 1.5},
    ],
)
def test_plan_route_rejects_bad_shapes(client: TestClient, body: dict[str, Any]) -> None:
    response = client.post("/plan", json=body)
    assert response.status_code == 422, response.text
    error = response.json()["error"]
    assert error["code"] == "validation"
    assert isinstance(error["detail"], list) and error["detail"]


def test_plan_route_accepts_the_ceiling(client: TestClient) -> None:
    response = client.post("/plan", json={"caption": True, "train": True, "gpu_count": MAX_GPUS})
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["gpu_count"] == MAX_GPUS
    assert body["train"]["gpus"] == list(range(1, MAX_GPUS))


def test_plan_route_requires_bearer(anon_client: TestClient) -> None:
    body = {"caption": True, "train": True}
    response = anon_client.post("/plan", json=body)
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthorized"

    response = anon_client.post(
        "/plan", json=body, headers={"Authorization": "Bearer wrong-token-000000"}
    )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthorized"


@pytest.mark.parametrize("count", [1, 2, 4])
def test_plan_route_is_pure(client: TestClient, count: int) -> None:
    """Planning never touches the supervisor: repeated calls return the same answer."""
    body = {"caption": True, "train": True, "gpu_count": count}
    first = client.post("/plan", json=body).json()
    for _ in range(3):
        assert client.post("/plan", json=body).json() == first
    assert set(first) == {"gpu_count", "mode", "caption", "train", "order"}


def test_every_cell_of_the_rule_is_covered() -> None:
    """Guard: the expectation table spans counts {1, 2, 4} x every request shape."""
    assert set(EXPECTED) == set(itertools.product((1, 2, 4), (True,), (False,))) | set(
        itertools.product((1, 2, 4), (False,), (True,))
    ) | set(itertools.product((1, 2, 4), (True,), (True,)))
