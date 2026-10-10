"""podctl against a scripted fake agent behind ``httpx.MockTransport`` (POD-SPEC §8, §9).

No network, no agent process: ``cli.make_client`` is replaced with a MockTransport-backed
``AgentClient`` and ``cli.sleep`` with a recorder, so ``--wait`` / ``--follow`` loops run
against a scripted sequence of responses.
"""

from __future__ import annotations

import io
import json
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

import httpx
import pytest

from podctl import cli
from podctl.client import AgentAPIError, AgentClient, AgentUnreachable

TOKEN = "t" * 32
URL = "http://agent"

Response = tuple[int, Any] | Callable[[httpx.Request], httpx.Response]


def envelope(code: str, message: str, detail: Any = None) -> dict[str, Any]:
    return {"error": {"code": code, "message": message, "detail": detail}}


def state(name: str, **overrides: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "name": name,
        "state": "running",
        "pid": 4242,
        "gpus": [0],
        "params": {"model": "Qwen/Qwen3-VL-32B-Instruct", "port": 8000},
        "exit_code": None,
        "stopped_by_request": False,
        "started_at": "2026-10-10T12:00:00Z",
        "ended_at": None,
        "log_path": f"/workspace/logs/{name}.log",
        "port": 8000,
        "run_id": None,
    }
    base.update(overrides)
    return base


@dataclass
class Seen:
    method: str
    path: str  # percent-decoded, as httpx exposes it
    raw_path: str  # exactly as sent on the wire, query stripped
    query: dict[str, str]
    body: Any


def pairs(out: str) -> dict[str, str]:
    """A key/value listing back into a dict (keys and values are separated by 2+ spaces)."""
    result: dict[str, str] = {}
    for line in out.splitlines():
        key, sep, value = line.partition("  ")
        if sep:
            result[key] = value.strip()
    return result


@dataclass
class FakeAgent:
    """Routes ``(METHOD, path)`` to a queue of responses; the last one repeats."""

    requests: list[Seen] = field(default_factory=list)
    routes: dict[tuple[str, str], list[Response]] = field(default_factory=dict)
    sleeps: list[float] = field(default_factory=list)
    auth: list[str] = field(default_factory=list)

    def on(self, method: str, path: str, *responses: Response) -> None:
        self.routes[(method, path)] = list(responses)

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.auth.append(request.headers.get("Authorization", ""))
        body = json.loads(request.content) if request.content else None
        raw_path = request.url.raw_path.decode().split("?", 1)[0]
        self.requests.append(
            Seen(request.method, request.url.path, raw_path, dict(request.url.params), body)
        )
        queue = self.routes.get((request.method, request.url.path))
        if not queue:
            return httpx.Response(404, json=envelope("not_found", "no such route"))
        scripted = queue.pop(0) if len(queue) > 1 else queue[0]
        if callable(scripted):
            return scripted(request)
        status, payload = scripted
        return httpx.Response(status, json=payload)

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)

    def calls(self, method: str, path: str) -> list[Seen]:
        return [r for r in self.requests if r.method == method and r.path == path]


@pytest.fixture
def agent(monkeypatch: pytest.MonkeyPatch) -> FakeAgent:
    fake = FakeAgent()
    monkeypatch.setattr(
        cli,
        "make_client",
        lambda url, token: AgentClient(url, token, transport=httpx.MockTransport(fake.handler)),
    )
    monkeypatch.setattr(cli, "sleep", fake.sleep)
    monkeypatch.delenv("PODCTL_URL", raising=False)
    monkeypatch.delenv("PODAGENT_TOKEN", raising=False)
    return fake


@pytest.fixture
def run(capsys: pytest.CaptureFixture[str]) -> Callable[..., tuple[int, str, str]]:
    def _run(*argv: str, auth: bool = True) -> tuple[int, str, str]:
        prefix = ["--url", URL, "--token", TOKEN] if auth else []
        code = cli.main([*prefix, *argv])
        captured = capsys.readouterr()
        return code, captured.out, captured.err

    return _run


# --- parsing ----------------------------------------------------------------------------


def test_parser_covers_every_spec_command() -> None:
    parser = cli.build_parser()
    for argv in (
        ["health"],
        ["gpus"],
        ["plan", "--caption", "--train", "--gpu-count", "4"],
        ["services"],
        ["status", "vllm"],
        ["start", "vllm", "--gpus", "0", "--params", "{}", "--wait"],
        ["stop", "vllm", "--timeout", "5"],
        ["logs", "vllm", "--tail", "10", "--follow"],
        ["events", "nora7-h3-001"],
        ["train", "aitoolkit", "--config", "run.json", "--gpus", "1,2"],
        ["train", "ltx", "--config", "run.json", "--gpus", "1", "--wait"],
        ["caption-up", "Qwen/Qwen3-VL-32B-Instruct", "--gpus", "1"],
    ):
        args = parser.parse_args(["--url", URL, "--token", TOKEN, *argv])
        assert args.command == argv[0]
    assert set(cli.COMMANDS) == {
        "health",
        "gpus",
        "plan",
        "services",
        "status",
        "start",
        "stop",
        "logs",
        "events",
        "train",
        "caption-up",
    }


@pytest.mark.parametrize(
    ("text", "expected"),
    [("0", [0]), ("0,1", [0, 1]), (" 1 , 2 ", [1, 2]), ("", []), ("3", [3])],
)
def test_parse_gpus(text: str, expected: list[int]) -> None:
    assert cli.parse_gpus(text) == expected


@pytest.mark.parametrize("text", ["a", "-1", "0,0", "0,", "1.5"])
def test_parse_gpus_rejects(text: str) -> None:
    import argparse

    with pytest.raises(argparse.ArgumentTypeError):
        cli.parse_gpus(text)


def test_caption_up_defaults_to_gpu_zero() -> None:
    args = cli.build_parser().parse_args(["caption-up", "some/model"])
    assert args.gpus == [0]


# --- formatting -------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        (None, "-"),
        (True, "true"),
        (False, "false"),
        ("", "-"),
        ("x", "x"),
        (0.9, "0.9"),
        (1e-4, "0.0001"),
        ([], "-"),
        ([0, 1], "0,1"),
        (["NORA7 woman", "b"], '["NORA7 woman", "b"]'),
        ({}, "-"),
        ({"a": 1}, '{"a": 1}'),
        (42, "42"),
    ],
)
def test_fmt_scalar(value: Any, expected: str) -> None:
    assert cli.fmt_scalar(value) == expected


def test_fmt_kv_flattens_nested_dicts() -> None:
    text = cli.fmt_kv({"a": 1, "b": {"c": None, "d": {"e": [1, 2]}}, "f": {}})
    assert text.splitlines() == ["a      1", "b.c    -", "b.d.e  1,2", "f      -"]


def test_fmt_table_pads_columns_and_handles_empty() -> None:
    text = cli.fmt_table(("A", "LONGER"), [[1, "x"], ["yy", None]])
    assert text.splitlines() == ["A   LONGER", "1   x", "yy  -"]
    assert cli.fmt_table(("A", "B"), []) == "A  B"


@pytest.mark.parametrize(
    ("previous", "current", "expected"),
    [
        ([], ["a"], 0),
        (["a", "b"], ["a", "b"], 2),
        (["a", "b", "c"], ["b", "c", "d"], 2),
        (["a", "b"], ["a", "b", "c"], 2),
        (["a", "b", "c"], ["d", "e", "f"], 0),
        (["x", "x", "x"], ["x", "x", "y"], 2),
    ],
)
def test_overlap(previous: list[str], current: list[str], expected: int) -> None:
    assert cli.overlap(previous, current) == expected


# --- plain commands: request shape and table output -------------------------------------


def test_health_table_and_bearer(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on(
        "GET",
        "/health",
        (
            200,
            {
                "status": "ok",
                "version": "0.1.0",
                "workspace": "/workspace",
                "gpu_backend": "fake",
                "gpu_count": 2,
                "runpod": {"pod_id": "abc123xyz", "public_ip": None},
                "time": "2026-10-10T12:00:00Z",
            },
        ),
    )
    code, out, err = run("health")
    assert code == 0 and err == ""
    assert agent.auth == [f"Bearer {TOKEN}"]
    lines = out.splitlines()
    assert lines[0] == "status            ok"
    assert "runpod.pod_id     abc123xyz" in lines
    assert "runpod.public_ip  -" in lines


def test_json_flag_prints_raw_response(agent: FakeAgent, run: Callable[..., Any]) -> None:
    payload = {"status": "ok", "runpod": {"pod_id": None}}
    agent.on("GET", "/health", (200, payload))
    code, out, _ = run("--json", "health")
    assert code == 0
    assert json.loads(out) == payload
    assert out.count("\n") == 1  # one document per line


def test_gpus_table(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on(
        "GET",
        "/gpus",
        (
            200,
            {
                "gpus": [
                    {
                        "index": 0,
                        "name": "FAKE GPU",
                        "memory_total_mib": 81920,
                        "memory_used_mib": 61440,
                        "uuid": "GPU-FAKE-0",
                        "in_use_by": "vllm",
                    },
                    {
                        "index": 1,
                        "name": "FAKE GPU",
                        "memory_total_mib": 81920,
                        "memory_used_mib": 0,
                        "uuid": "GPU-FAKE-1",
                        "in_use_by": None,
                    },
                ]
            },
        ),
    )
    code, out, _ = run("gpus")
    assert code == 0
    assert out.splitlines() == [
        "IDX  NAME      MEM_MIB      IN_USE_BY",
        "0    FAKE GPU  61440/81920  vllm",
        "1    FAKE GPU  0/81920      -",
    ]


def test_gpus_empty_inventory(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on("GET", "/gpus", (200, {"gpus": []}))
    assert run("gpus") == (0, "no GPUs\n", "")


def test_plan_body_and_table(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on(
        "POST",
        "/plan",
        (
            200,
            {
                "gpu_count": 1,
                "mode": "sequential",
                "caption": {"service": "vllm", "gpus": [0]},
                "train": {"service": "trainer", "gpus": [0]},
                "order": [
                    {"action": "start", "service": "vllm"},
                    {"action": "stop", "service": "vllm"},
                    {"action": "start", "service": "trainer"},
                ],
            },
        ),
    )
    code, out, _ = run("plan", "--caption", "--train", "--gpu-count", "1")
    assert code == 0
    assert agent.requests[0].body == {"caption": True, "train": True, "gpu_count": 1}
    assert out.splitlines() == [
        "gpu_count  1",
        "mode       sequential",
        "caption    vllm on 0",
        "train      trainer on 0",
        "order      start vllm -> stop vllm -> start trainer",
    ]


def test_plan_omits_gpu_count_when_not_given(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on(
        "POST",
        "/plan",
        (
            200,
            {
                "gpu_count": 2,
                "mode": "single",
                "caption": None,
                "train": {"service": "trainer", "gpus": [1]},
                "order": [{"action": "start", "service": "trainer"}],
            },
        ),
    )
    code, out, _ = run("plan", "--train")
    assert code == 0
    assert agent.requests[0].body == {"caption": False, "train": True}
    assert "caption    -" in out.splitlines()
    assert "train      trainer on 1" in out.splitlines()


def test_plan_requires_a_side(agent: FakeAgent, run: Callable[..., Any]) -> None:
    code, _, err = run("plan")
    assert code == 2 and "--caption and/or --train" in err
    assert agent.requests == []


def test_services_table(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on(
        "GET",
        "/services",
        (
            200,
            {
                "services": [
                    state("vllm"),
                    state(
                        "tensorboard", pid=None, gpus=[], state="idle", port=6006, started_at=None
                    ),
                    state(
                        "trainer-aitoolkit",
                        state="exited",
                        pid=None,
                        gpus=[1, 2],
                        port=None,
                        run_id="nora7-h3-001",
                        exit_code=0,
                    ),
                ]
            },
        ),
    )
    code, out, _ = run("services")
    assert code == 0
    lines = out.splitlines()
    assert lines[0].split() == ["NAME", "STATE", "PID", "GPUS", "PORT", "RUN_ID", "STARTED", "EXIT"]
    assert lines[1].split() == [
        "vllm",
        "running",
        "4242",
        "0",
        "8000",
        "-",
        "2026-10-10T12:00:00Z",
        "-",
    ]
    assert lines[2].split() == ["tensorboard", "idle", "-", "-", "6006", "-", "-", "-"]
    assert lines[3].split() == [
        "trainer-aitoolkit",
        "exited",
        "-",
        "1,2",
        "-",
        "nora7-h3-001",
        "2026-10-10T12:00:00Z",
        "0",
    ]


def test_status_path_and_redacted_params(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on("GET", "/services/vllm", (200, state("vllm", params={"model": "m", "api_key": "***"})))
    code, out, _ = run("status", "vllm")
    assert code == 0
    assert agent.requests[0].method == "GET"
    listing = pairs(out)
    assert listing["params.api_key"] == "***"
    assert listing["state"] == "running"
    assert listing["ended_at"] == "-"


def test_status_quotes_odd_names(agent: FakeAgent, run: Callable[..., Any]) -> None:
    code, _, _err = run("status", "a/b")
    assert code == 1
    assert agent.requests[0].raw_path == "/services/a%2Fb"


# --- start / stop / logs / events -------------------------------------------------------


def test_start_inline_params(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on("POST", "/services/vllm/start", (201, state("vllm")))
    code, out, _ = run("start", "vllm", "--gpus", "0", "--params", '{"model": "m", "port": 8000}')
    assert code == 0
    seen = agent.requests[0]
    assert seen.path == "/services/vllm/start"
    assert seen.body == {"gpus": [0], "params": {"model": "m", "port": 8000}}
    assert pairs(out)["name"] == "vllm"
    assert agent.sleeps == []


def test_start_params_file(agent: FakeAgent, run: Callable[..., Any], tmp_path: Any) -> None:
    params = tmp_path / "vllm.json"
    params.write_text('{"model": "m"}')
    agent.on("POST", "/services/vllm/start", (201, state("vllm")))
    code, _, _ = run("start", "vllm", "--params-file", str(params))
    assert code == 0
    assert agent.requests[0].body == {"gpus": [], "params": {"model": "m"}}


def test_start_params_from_stdin(
    agent: FakeAgent, run: Callable[..., Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("sys.stdin", io.StringIO('{"repo_id": "you/nora7-faces"}'))
    agent.on("POST", "/services/pull-dataset/start", (201, state("pull-dataset", gpus=[])))
    code, _, _ = run("start", "pull-dataset", "--params-file", "-")
    assert code == 0
    assert agent.requests[0].body == {"gpus": [], "params": {"repo_id": "you/nora7-faces"}}


@pytest.mark.parametrize(
    "argv",
    [
        ["start", "vllm", "--params", "{not json"],
        ["start", "vllm", "--params", "[1, 2]"],
        ["start", "vllm", "--params", "{}", "--params-file", "x.json"],
        ["start", "vllm", "--gpus", "0,x"],
        ["start", "vllm", "--params-file", "/nonexistent/params.json"],
        ["stop", "vllm", "--timeout", "0"],
        ["stop", "vllm", "--timeout", "91"],
        ["logs", "vllm", "--tail", "0"],
        ["logs", "vllm", "--tail", "5001"],
        ["train", "nope", "--config", "run.json", "--gpus", "1"],
        ["train", "ltx", "--config", "run.json"],
        ["bogus"],
    ],
)
def test_usage_errors_exit_2_without_a_request(
    agent: FakeAgent, run: Callable[..., Any], argv: list[str]
) -> None:
    code, _, err = run(*argv)
    assert code == 2
    assert err != ""
    assert agent.requests == []


def test_missing_url_or_token_is_usage(agent: FakeAgent, run: Callable[..., Any]) -> None:
    code, _, err = run("health", auth=False)
    assert code == 2 and "PODCTL_URL" in err
    assert agent.requests == []


def test_url_and_token_from_env(
    agent: FakeAgent, run: Callable[..., Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("PODCTL_URL", URL)
    monkeypatch.setenv("PODAGENT_TOKEN", TOKEN)
    agent.on("GET", "/health", (200, {"status": "ok"}))
    assert run("health", auth=False)[0] == 0
    assert agent.auth == [f"Bearer {TOKEN}"]


def test_help_and_version_exit_zero(run: Callable[..., Any]) -> None:
    code, out, _ = run("--help", auth=False)
    assert code == 0 and "caption-up" in out
    code, out, _ = run("--version", auth=False)
    assert code == 0 and out.startswith("podctl ")


def test_stop_body_default_and_custom(agent: FakeAgent, run: Callable[..., Any]) -> None:
    stopped = state("vllm", state="stopped", pid=None, stopped_by_request=True, exit_code=-15)
    agent.on("POST", "/services/vllm/stop", (200, stopped))
    code, out, _ = run("stop", "vllm")
    assert code == 0
    assert agent.requests[0].body == {"timeout_s": 30.0}
    assert pairs(out)["state"] == "stopped"
    assert pairs(out)["stopped_by_request"] == "true"
    assert run("stop", "vllm", "--timeout", "45")[0] == 0
    assert agent.requests[1].body == {"timeout_s": 45.0}


def test_logs_tail_query_and_plain_lines(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on(
        "GET",
        "/services/vllm/logs",
        (
            200,
            {
                "name": "vllm",
                "path": "/workspace/logs/vllm.log",
                "lines": ["a", "b"],
                "truncated": True,
            },
        ),
    )
    code, out, err = run("logs", "vllm", "--tail", "50")
    assert code == 0 and err == ""
    assert agent.requests[0].query == {"tail": "50"}
    assert out == "a\nb\n"


def test_logs_default_tail_and_empty(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on(
        "GET",
        "/services/vllm/logs",
        (200, {"name": "vllm", "path": "p", "lines": [], "truncated": False}),
    )
    assert run("logs", "vllm") == (0, "", "")
    assert agent.requests[0].query == {"tail": "200"}


def test_events_table(agent: FakeAgent, run: Callable[..., Any]) -> None:
    wall_time = datetime(2026, 10, 10, 12, 0, 0, tzinfo=UTC).timestamp()
    agent.on(
        "GET",
        "/runs/nora7-h3-001/events",
        (
            200,
            {
                "run_id": "nora7-h3-001",
                "logdir": "/workspace/runs/nora7-h3-001/tensorboard",
                "files": 1,
                "scalars": {
                    "loss": {"step": 1250, "value": 0.1182, "wall_time": wall_time, "count": 1250},
                    "learning_rate": {
                        "step": 1250,
                        "value": 0.0001,
                        "wall_time": wall_time,
                        "count": 1250,
                    },
                },
                "last_step": 1250,
                "reader": "minimal",
            },
        ),
    )
    code, out, _ = run("events", "nora7-h3-001")
    assert code == 0
    lines = out.splitlines()
    assert lines[0] == "run_id     nora7-h3-001"
    assert lines[3] == "last_step  1250"
    assert lines[5] == ""
    assert lines[6].split() == ["TAG", "STEP", "VALUE", "COUNT", "WALL_TIME"]
    assert lines[7].split() == ["learning_rate", "1250", "0.0001", "1250", "2026-10-10T12:00:00Z"]
    assert lines[8].split() == ["loss", "1250", "0.1182", "1250", "2026-10-10T12:00:00Z"]


def test_events_without_scalars(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on(
        "GET",
        "/runs/ivan9-ltx-001/events",
        (
            200,
            {
                "run_id": "ivan9-ltx-001",
                "logdir": "x",
                "files": 0,
                "scalars": {},
                "last_step": None,
                "reader": "minimal",
            },
        ),
    )
    code, out, _ = run("events", "ivan9-ltx-001")
    assert code == 0 and out.endswith("\nno scalars yet\n")


# --- sugar: train and caption-up --------------------------------------------------------


@pytest.mark.parametrize("trainer", ["aitoolkit", "ltx"])
def test_train_posts_run_config_as_params(
    agent: FakeAgent, run: Callable[..., Any], tmp_path: Any, trainer: str
) -> None:
    config = {
        "run_id": "nora7-h3-001",
        "dataset": {"path": "/workspace/datasets/faces"},
        "triggers": ["NORA7"],
        "base_model": "black-forest-labs/FLUX.1-dev",
    }
    path = tmp_path / "run.json"
    path.write_text(json.dumps(config))
    name = f"trainer-{trainer}"
    agent.on(
        "POST",
        f"/services/{name}/start",
        (201, state(name, gpus=[1, 2], run_id="nora7-h3-001", port=None)),
    )
    code, out, _ = run("train", trainer, "--config", str(path), "--gpus", "1,2")
    assert code == 0
    seen = agent.requests[0]
    assert seen.path == f"/services/{name}/start"
    assert seen.body == {"gpus": [1, 2], "params": config}
    assert pairs(out)["run_id"] == "nora7-h3-001"
    assert pairs(out)["gpus"] == "1,2"


def test_train_rejects_non_object_config(
    agent: FakeAgent, run: Callable[..., Any], tmp_path: Any
) -> None:
    path = tmp_path / "run.json"
    path.write_text("[]")
    code, _, err = run("train", "ltx", "--config", str(path), "--gpus", "1")
    assert code == 2 and "expected a JSON object" in err
    assert agent.requests == []


def test_caption_up_default_gpu_and_model(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on("POST", "/services/vllm/start", (201, state("vllm")))
    code, _, _ = run("caption-up", "Qwen/Qwen3-VL-32B-Instruct")
    assert code == 0
    assert agent.requests[0].body == {
        "gpus": [0],
        "params": {"model": "Qwen/Qwen3-VL-32B-Instruct"},
    }


def test_caption_up_custom_gpu_and_extra_params(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on("POST", "/services/vllm/start", (201, state("vllm", gpus=[1])))
    code, _, _ = run(
        "caption-up",
        "local/model",
        "--gpus",
        "1",
        "--params",
        '{"max_model_len": 8192, "model": "ignored"}',
    )
    assert code == 0
    assert agent.requests[0].body == {
        "gpus": [1],
        "params": {"max_model_len": 8192, "model": "local/model"},
    }


# --- errors and exit codes --------------------------------------------------------------


def test_agent_error_envelope_exit_1_table(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on(
        "POST",
        "/services/vllm/start",
        (409, envelope("gpu_busy", "GPU 0 is in use by vllm", {"gpu": 0, "service": "vllm"})),
    )
    code, out, err = run("start", "vllm", "--gpus", "0", "--params", '{"model": "m"}')
    assert code == 1 and out == ""
    assert err.splitlines() == [
        "podctl: error gpu_busy (409): GPU 0 is in use by vllm",
        '  detail: {"gpu": 0, "service": "vllm"}',
    ]


def test_agent_error_envelope_exit_1_json(agent: FakeAgent, run: Callable[..., Any]) -> None:
    body = envelope("not_found", "no service 'nope'")
    agent.on("GET", "/services/nope", (404, body))
    code, out, err = run("--json", "status", "nope")
    assert code == 1 and out == ""
    assert json.loads(err) == body


def test_invalid_params_detail_is_listed(agent: FakeAgent, run: Callable[..., Any]) -> None:
    detail = [
        {"type": "missing", "loc": ["model"], "msg": "Field required"},
        {"type": "extra_forbidden", "loc": ["modle"], "msg": "Extra inputs are not permitted"},
    ]
    agent.on(
        "POST", "/services/vllm/start", (422, envelope("invalid_params", "params rejected", detail))
    )
    code, _, err = run("start", "vllm", "--params", '{"modle": "m"}')
    assert code == 1
    assert err.splitlines() == [
        "podctl: error invalid_params (422): params rejected",
        "  - model: Field required",
        "  - modle: Extra inputs are not permitted",
    ]


def test_non_envelope_error_body_is_wrapped(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on("GET", "/health", lambda _: httpx.Response(500, text="boom"))
    code, _, err = run("health")
    assert code == 1
    assert err.splitlines()[0] == "podctl: error http (500): boom"


def test_gateway_error_is_connection_failure(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on("GET", "/health", lambda _: httpx.Response(502, text="<html>bad gateway</html>"))
    code, _, err = run("health")
    assert code == 3 and "cannot reach the agent" in err


def test_gateway_status_with_envelope_is_agent_error(
    agent: FakeAgent, run: Callable[..., Any]
) -> None:
    agent.on("GET", "/health", (503, envelope("internal", "draining")))
    assert run("health")[0] == 1


def test_connection_error_exit_3(agent: FakeAgent, run: Callable[..., Any]) -> None:
    def refuse(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    agent.on("GET", "/health", refuse)
    code, out, err = run("health")
    assert code == 3 and out == ""
    assert err.startswith("podctl: cannot reach http://agent: ConnectError")


def test_timeout_exit_3(agent: FakeAgent, run: Callable[..., Any]) -> None:
    def slow(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("timed out", request=request)

    agent.on("GET", "/services/vllm/logs", slow)
    assert run("logs", "vllm")[0] == 3


def test_non_json_success_body_exit_1(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on("GET", "/health", lambda _: httpx.Response(200, text="<html>login</html>"))
    code, _, err = run("health")
    assert code == 1 and "invalid_response" in err


# --- --wait ------------------------------------------------------------------------------


def test_start_wait_polls_until_not_running(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on(
        "POST", "/services/pull-dataset/start", (201, state("pull-dataset", gpus=[], port=None))
    )
    agent.on(
        "GET",
        "/services/pull-dataset",
        (200, state("pull-dataset", gpus=[], port=None)),
        (200, state("pull-dataset", gpus=[], port=None)),
        (200, state("pull-dataset", gpus=[], port=None, state="exited", pid=None, exit_code=0)),
    )
    code, out, err = run(
        "start", "pull-dataset", "--params", '{"repo_id": "you/nora7-faces"}', "--wait"
    )
    assert code == 0
    assert [r.path for r in agent.requests] == [
        "/services/pull-dataset/start",
        "/services/pull-dataset",
        "/services/pull-dataset",
        "/services/pull-dataset",
    ]
    assert agent.sleeps == [2.0, 2.0]
    assert "waiting for pull-dataset" in err
    blocks = [line.split() for line in out.splitlines()]
    assert blocks.count(["name", "pull-dataset"]) == 2  # the start state, then the final state
    assert blocks.count(["state", "running"]) == 1
    assert blocks.count(["state", "exited"]) == 1
    assert ["exit_code", "0"] in blocks


def test_start_wait_failed_state_exits_1(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on("POST", "/services/push-lora/start", (201, state("push-lora", gpus=[], port=None)))
    agent.on(
        "GET",
        "/services/push-lora",
        (200, state("push-lora", gpus=[], port=None, state="failed", pid=None, exit_code=1)),
    )
    code, out, err = run(
        "--json", "start", "push-lora", "--params", '{"run_id": "r", "repo_id": "a/b"}', "--wait"
    )
    assert code == 1
    assert agent.sleeps == []
    documents = [json.loads(line) for line in out.splitlines()]
    assert [d["state"] for d in documents] == ["running", "failed"]
    assert "push-lora failed with exit code 1" in err


def test_train_wait(agent: FakeAgent, run: Callable[..., Any], tmp_path: Any) -> None:
    path = tmp_path / "run.json"
    path.write_text('{"run_id": "ivan9-ltx-001"}')
    agent.on(
        "POST",
        "/services/trainer-ltx/start",
        (201, state("trainer-ltx", gpus=[1], run_id="ivan9-ltx-001")),
    )
    agent.on(
        "GET",
        "/services/trainer-ltx",
        (200, state("trainer-ltx", gpus=[1], run_id="ivan9-ltx-001")),
        (200, state("trainer-ltx", gpus=[1], run_id="ivan9-ltx-001", state="exited", exit_code=0)),
    )
    code, _, _ = run("train", "ltx", "--config", str(path), "--gpus", "1", "--wait")
    assert code == 0 and agent.sleeps == [2.0]


def test_wait_propagates_agent_error(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on("POST", "/services/vllm/start", (201, state("vllm")))
    agent.on("GET", "/services/vllm", (500, envelope("internal", "internal error")))
    code, _, err = run("start", "vllm", "--params", '{"model": "m"}', "--wait")
    assert code == 1 and "internal (500)" in err


# --- --follow ---------------------------------------------------------------------------


def logs_response(lines: list[str], *, truncated: bool = False) -> tuple[int, dict[str, Any]]:
    return 200, {
        "name": "vllm",
        "path": "/workspace/logs/vllm.log",
        "lines": lines,
        "truncated": truncated,
    }


def test_logs_follow_prints_new_lines_until_stopped(
    agent: FakeAgent, run: Callable[..., Any]
) -> None:
    agent.on(
        "GET",
        "/services/vllm",
        (200, state("vllm")),
        (200, state("vllm")),
        (200, state("vllm")),
        (200, state("vllm", state="stopped", pid=None)),
    )
    agent.on(
        "GET",
        "/services/vllm/logs",
        logs_response(["a", "b"]),
        logs_response(["a", "b", "c"]),
        logs_response(["a", "b", "c"]),  # nothing new: prints nothing
        logs_response(["b", "c", "d"], truncated=True),  # window of 3 slid by one
    )
    code, out, err = run("logs", "vllm", "--tail", "3", "--follow")
    assert code == 0 and err == ""
    assert out == "a\nb\nc\nd\n"
    assert agent.sleeps == [2.0, 2.0, 2.0]
    assert [r.path for r in agent.requests] == ["/services/vllm", "/services/vllm/logs"] * 4
    assert all(r.query == {"tail": "3"} for r in agent.calls("GET", "/services/vllm/logs"))


def test_logs_follow_json_emits_only_new_lines(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on("GET", "/services/vllm", (200, state("vllm")), (200, state("vllm", state="exited")))
    agent.on("GET", "/services/vllm/logs", logs_response(["a"]), logs_response(["a", "b"]))
    code, out, _ = run("--json", "logs", "vllm", "--follow")
    assert code == 0
    documents = [json.loads(line) for line in out.splitlines()]
    assert [d["lines"] for d in documents] == [["a"], ["b"]]
    assert documents[0]["path"] == "/workspace/logs/vllm.log"


def test_logs_follow_stops_immediately_when_not_running(
    agent: FakeAgent, run: Callable[..., Any]
) -> None:
    agent.on("GET", "/services/pull-dataset", (200, state("pull-dataset", state="exited")))
    agent.on("GET", "/services/pull-dataset/logs", logs_response(["done"]))
    code, out, _ = run("logs", "pull-dataset", "--follow")
    assert code == 0 and out == "done\n"
    assert agent.sleeps == []


def test_logs_follow_notes_a_gap(agent: FakeAgent, run: Callable[..., Any]) -> None:
    agent.on("GET", "/services/vllm", (200, state("vllm")), (200, state("vllm", state="exited")))
    agent.on(
        "GET",
        "/services/vllm/logs",
        logs_response(["a", "b"], truncated=True),
        logs_response(["x", "y"], truncated=True),
    )
    code, out, err = run("logs", "vllm", "--tail", "2", "--follow")
    assert code == 0
    assert out == "a\nb\nx\ny\n"
    assert "more than 2 lines" in err


def test_logs_follow_restart_without_truncation_is_silent(
    agent: FakeAgent, run: Callable[..., Any]
) -> None:
    agent.on("GET", "/services/vllm", (200, state("vllm")), (200, state("vllm", state="exited")))
    agent.on("GET", "/services/vllm/logs", logs_response(["old"]), logs_response(["fresh"]))
    code, out, err = run("logs", "vllm", "--follow")
    assert code == 0 and out == "old\nfresh\n" and err == ""


def test_follow_interrupted_exits_130(
    agent: FakeAgent, run: Callable[..., Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    def interrupt(_: float) -> None:
        raise KeyboardInterrupt

    monkeypatch.setattr(cli, "sleep", interrupt)
    agent.on("GET", "/services/vllm", (200, state("vllm")))
    agent.on("GET", "/services/vllm/logs", logs_response(["a"]))
    code, out, _ = run("logs", "vllm", "--follow")
    assert code == 130 and out == "a\n"


def test_follow_unknown_service_exit_1(agent: FakeAgent, run: Callable[..., Any]) -> None:
    code, _, err = run("logs", "nope", "--follow")
    assert code == 1 and "not_found" in err


# --- client ------------------------------------------------------------------------------


def test_client_sends_bearer_and_raises_envelope() -> None:
    seen: dict[str, str] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["auth"] = request.headers.get("Authorization", "")
        if request.url.path == "/health":
            return httpx.Response(200, json={"status": "ok"})
        return httpx.Response(404, json=envelope("not_found", "no"))

    with AgentClient("http://agent/", TOKEN, transport=httpx.MockTransport(handler)) as client:
        assert client.url == "http://agent"
        assert client.health() == {"status": "ok"}
        assert seen["auth"] == f"Bearer {TOKEN}"
        with pytest.raises(AgentAPIError) as info:
            client.service("nope")
    error = info.value
    assert (error.status, error.code, error.message, error.detail) == (404, "not_found", "no", None)


def test_client_method_paths_and_bodies() -> None:
    calls: list[tuple[str, str, dict[str, str], Any]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content) if request.content else None
        raw_path = request.url.raw_path.decode().split("?", 1)[0]
        calls.append((request.method, raw_path, dict(request.url.params), body))
        return httpx.Response(200, json={})

    client = AgentClient("http://agent", TOKEN, transport=httpx.MockTransport(handler))
    client.gpus()
    client.plan(caption=True, train=False, gpu_count=4)
    client.services()
    client.start("trainer-ltx", [1, 2], {"run_id": "ivan9-ltx-001"})
    client.stop("vllm", 12.5)
    client.logs("vllm", 7)
    client.events("nora7 h3")
    assert calls == [
        ("GET", "/gpus", {}, None),
        ("POST", "/plan", {}, {"caption": True, "train": False, "gpu_count": 4}),
        ("GET", "/services", {}, None),
        (
            "POST",
            "/services/trainer-ltx/start",
            {},
            {"gpus": [1, 2], "params": {"run_id": "ivan9-ltx-001"}},
        ),
        ("POST", "/services/vllm/stop", {}, {"timeout_s": 12.5}),
        ("GET", "/services/vllm/logs", {"tail": "7"}, None),
        ("GET", "/runs/nora7%20h3/events", {}, None),
    ]


def test_client_gateway_vs_envelope() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/gateway":
            return httpx.Response(504, text="upstream timed out")
        return httpx.Response(502, json=envelope("internal", "really the agent"))

    client = AgentClient("http://agent", TOKEN, transport=httpx.MockTransport(handler))
    with pytest.raises(AgentUnreachable) as unreachable:
        client._call("GET", "/gateway")
    assert unreachable.value.status == 504
    with pytest.raises(AgentAPIError) as api:
        client._call("GET", "/agent")
    assert api.value.code == "internal"


def test_client_wraps_non_envelope_json_error() -> None:
    client = AgentClient(
        "http://agent",
        TOKEN,
        transport=httpx.MockTransport(lambda _: httpx.Response(404, json={"detail": "Not Found"})),
    )
    with pytest.raises(AgentAPIError) as info:
        client.health()
    assert info.value.code == "http"
    assert info.value.detail == {"detail": "Not Found"}
