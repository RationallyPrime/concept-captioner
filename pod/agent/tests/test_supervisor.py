"""Supervisor end-to-end with real ``podagent.fakeservice`` children (POD-SPEC §2.6, §9).

``FakeBackend(2)`` and a tmp workspace; every start spawns a real subprocess, so these tests
cover the process-group signalling, exit-code capture and log truncation for real. Fixture
triggers are NORA7 / IVAN9; nothing here names a real concept.
"""

from __future__ import annotations

import json
import os
import signal
import socket
import time
import urllib.request
from collections.abc import Callable, Iterator
from dataclasses import replace
from pathlib import Path
from typing import Any

import pytest

from podagent.catalog import CATALOG, SERVICE_NAMES
from podagent.errors import (
    AgentError,
    AlreadyRunning,
    GpuBusy,
    GpuCount,
    GpuInventoryUnavailable,
    InvalidParams,
    NotFound,
    NotRunning,
    UnknownGpu,
)
from podagent.gpus import FakeBackend, InventoryUnavailable
from podagent.settings import Settings
from podagent.supervisor import ServiceState, Supervisor, tail_file

pytestmark = pytest.mark.usefixtures("tensorboard_port")

WAIT_S = 10.0
POLL_S = 0.02


# --- helpers ---------------------------------------------------------------------------------------


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


def wait_for_log(path: str | Path, needle: str, timeout: float = WAIT_S) -> str:
    """Block until the service log contains ``needle``; return the log text."""
    file = Path(path)

    def present() -> bool:
        return file.exists() and needle in file.read_text(encoding="utf-8", errors="replace")

    wait_until(present, f"{needle!r} in {file.name}", timeout)
    return file.read_text(encoding="utf-8", errors="replace")


def wait_for_exit(sup: Supervisor, name: str, timeout: float = WAIT_S) -> ServiceState:
    wait_until(lambda: sup.state(name).state != "running", f"{name} to exit", timeout)
    return sup.state(name)


def http_get(port: int, path: str) -> tuple[int, bytes]:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=5) as response:
        return response.status, response.read()


def run_config(settings: Settings, **overrides: Any) -> dict[str, Any]:
    datasets = settings.paths.datasets
    body: dict[str, Any] = {
        "run_id": "nora7-h3-001",
        "dataset": {"path": str(datasets / "faces")},
        "triggers": ["NORA7"],
        "base_model": "black-forest-labs/FLUX.1-dev",
        "sample_prompts": ["NORA7 woman, studio portrait"],
    }
    body.update(overrides)
    return body


def vllm_params(**overrides: Any) -> dict[str, Any]:
    body: dict[str, Any] = {"model": "org/fake-vl-model", "port": free_port()}
    body.update(overrides)
    return body


# --- fixtures --------------------------------------------------------------------------------------


@pytest.fixture
def sup(settings: Settings, monkeypatch: pytest.MonkeyPatch) -> Iterator[Supervisor]:
    # Transfers finish quickly in tests; the fake reads this from the env it inherits.
    monkeypatch.setenv("PODAGENT_FAKE_TRANSFER_S", "0.3")
    supervisor = Supervisor(settings, FakeBackend(settings.fake_gpus or 0))
    yield supervisor
    supervisor.shutdown()


# --- idle state and lookups ------------------------------------------------------------------------


def test_everything_idle_at_boot(sup: Supervisor) -> None:
    states = sup.states()
    assert [s.name for s in states] == list(SERVICE_NAMES)
    assert sup.names() == list(SERVICE_NAMES)
    for state in states:
        assert state.state == "idle"
        assert state.pid is None and state.gpus == [] and state.params is None
        assert state.started_at is None and state.ended_at is None
        assert state.exit_code is None and state.log_path is None
    assert sup.state("vllm").state == "idle"
    with pytest.raises(NotFound):
        sup.state("no-such-service")
    with pytest.raises(NotFound):
        sup.logs("vllm")  # never started: no log yet
    with pytest.raises(NotFound):
        sup.logs("no-such-service")
    with pytest.raises(NotRunning):
        sup.stop("vllm")
    inventory = sup.inventory()
    assert [g["index"] for g in inventory] == [0, 1]
    assert all(g["in_use_by"] is None for g in inventory)
    assert inventory[0]["name"] == "FAKE GPU" and inventory[0]["uuid"] == "GPU-FAKE-0"


# --- the happy path: start, status, logs, stop ------------------------------------------------------


def test_vllm_start_status_logs_stop(sup: Supervisor, settings: Settings) -> None:
    params = vllm_params(api_key="super-secret-key-000")
    state = sup.start("vllm", [0], params)

    assert state.state == "running"
    assert isinstance(state.pid, int) and state.pid > 0
    assert state.gpus == [0]
    assert state.port == params["port"]
    assert state.run_id is None
    assert state.started_at is not None and state.ended_at is None
    assert state.exit_code is None and state.stopped_by_request is False
    assert state.log_path == str(settings.paths.logs / "vllm.log")
    assert state.params is not None
    assert state.params["api_key"] == "***"
    assert state.params["model"] == "org/fake-vl-model"

    text = wait_for_log(state.log_path, "listening on")
    assert "CUDA_VISIBLE_DEVICES='0'" in text
    assert f"HF_HOME='{settings.paths.hf_cache}'" in text
    assert "VLLM_API_KEY=set" in text
    assert "super-secret-key-000" not in text  # secrets ride in env, never argv or logs
    assert f"cwd={settings.paths.workspace}" in text

    status, body = http_get(params["port"], "/v1/models")
    assert status == 200
    assert json.loads(body)["data"][0]["id"] == "org/fake-vl-model"

    # Status reflects the live child; GPU 0 is booked by vllm.
    assert sup.state("vllm").state == "running"
    assert [s.state for s in sup.states() if s.name == "vllm"] == ["running"]
    inventory = sup.inventory()
    assert inventory[0]["in_use_by"] == "vllm" and inventory[1]["in_use_by"] is None

    tail = sup.logs("vllm", tail=3)
    assert tail.name == "vllm" and tail.path == state.log_path
    assert len(tail.lines) == 3 and tail.truncated is True
    everything = sup.logs("vllm", tail=5000)
    assert everything.truncated is False
    assert any(line.startswith("fakeservice: name=vllm") for line in everything.lines)

    stopped = sup.stop("vllm")
    assert stopped.state == "stopped"
    assert stopped.exit_code == 0
    assert stopped.stopped_by_request is True
    assert stopped.ended_at is not None and stopped.ended_at >= stopped.started_at
    assert stopped.pid == state.pid  # the state keeps the pid it ran with
    assert all(g["in_use_by"] is None for g in sup.inventory())
    with pytest.raises(NotRunning):
        sup.stop("vllm")
    # The log is still readable after the stop and records the signal.
    assert any("exiting 0" in line for line in sup.logs("vllm").lines)


def test_zero_gpu_service_sees_no_gpu(
    sup: Supervisor, settings: Settings, tensorboard_port: int
) -> None:
    port = tensorboard_port
    state = sup.start("tensorboard", [], {})
    assert state.gpus == [] and state.port == port
    assert state.params == {"logdir": None}
    text = wait_for_log(state.log_path, "listening on")
    assert "CUDA_VISIBLE_DEVICES=''" in text  # set to the empty string, not unset
    assert http_get(port, "/")[0] == 200
    assert all(g["in_use_by"] is None for g in sup.inventory())
    assert sup.stop("tensorboard").state == "stopped"


def test_trainer_runs_in_its_run_dir_with_assigned_gpus(
    sup: Supervisor, settings: Settings
) -> None:
    cfg = run_config(settings, hf_token="hf_secret_value_123")
    state = sup.start("trainer-aitoolkit", [1], cfg)
    run_dir = settings.paths.run_dir("nora7-h3-001")

    assert state.run_id == "nora7-h3-001"
    assert state.log_path == str(run_dir / "trainer.log")
    assert state.port is None
    assert state.params is not None and state.params["hf_token"] == "***"
    assert (run_dir / "run.json").is_file()  # prepare() ran before the spawn
    assert "hf_token" not in json.loads((run_dir / "run.json").read_text())

    text = wait_for_log(state.log_path, "sleeping until SIGTERM")
    assert f"cwd={run_dir}" in text
    assert "CUDA_VISIBLE_DEVICES='1'" in text
    assert "HF_TOKEN=set" in text and "hf_secret_value_123" not in text
    assert sup.inventory()[1]["in_use_by"] == "trainer-aitoolkit"
    assert sup.stop("trainer-aitoolkit").state == "stopped"


# --- the check order -------------------------------------------------------------------------------


def test_unknown_name_wins_over_bad_params(sup: Supervisor) -> None:
    with pytest.raises(NotFound):
        sup.start("no-such-service", [99], {"bogus": True})


def test_invalid_params_detail_is_json_safe_and_redacted(
    sup: Supervisor, settings: Settings
) -> None:
    with pytest.raises(InvalidParams) as excinfo:
        sup.start("vllm", [99], {})  # bad params and a bad GPU: params are checked first
    detail = excinfo.value.detail
    json.dumps(detail)
    assert any(tuple(err["loc"]) == ("model",) for err in detail)

    with pytest.raises(InvalidParams) as excinfo:
        sup.start("vllm", [0], {"model": "org/m", "bogus": 1})
    assert excinfo.value.detail[0]["type"] == "extra_forbidden"

    # The second validation step (workspace paths) maps to the same error.
    with pytest.raises(InvalidParams) as excinfo:
        sup.start("trainer-ltx", [1], run_config(settings, dataset={"path": "/elsewhere/faces"}))
    assert excinfo.value.detail[0]["type"] == "path_outside_workspace"

    # A model-level error echoes the whole input; secrets in it are redacted.
    with pytest.raises(InvalidParams) as excinfo:
        sup.start("pull-dataset", [], {"repo_id": "org/.hidden", "hf_token": "hf_secret_zzz"})
    detail = excinfo.value.detail
    json.dumps(detail)
    assert detail[0]["input"]["hf_token"] == "***"
    assert "hf_secret_zzz" not in json.dumps(detail)
    assert sup.state("pull-dataset").state == "idle"


@pytest.mark.parametrize(
    ("name", "gpus"),
    [
        ("vllm", []),
        ("vllm", [0, 1]),
        ("trainer-ltx", []),
        ("trainer-aitoolkit", [0, 0]),  # duplicates are not two GPUs
        ("tensorboard", [0]),  # 0-GPU services reject any list
        ("pull-dataset", [1]),
        ("push-lora", [0, 1]),
    ],
)
def test_gpu_count_out_of_range(
    sup: Supervisor, settings: Settings, name: str, gpus: list[int]
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
        params = {}
    with pytest.raises(GpuCount) as excinfo:
        sup.start(name, gpus, params)
    assert excinfo.value.detail["requested"] == gpus
    assert sup.state(name).state == "idle"


def test_unknown_gpu_index(sup: Supervisor, settings: Settings) -> None:
    with pytest.raises(UnknownGpu) as excinfo:
        sup.start("vllm", [2], vllm_params())
    assert excinfo.value.detail == {"gpu": 2, "known": [0, 1]}
    with pytest.raises(UnknownGpu):
        sup.start("trainer-ltx", [1, 7], run_config(settings))
    with pytest.raises(UnknownGpu):
        sup.start("vllm", [-1], vllm_params())
    assert sup.state("vllm").state == "idle"


def test_double_booking_refused(sup: Supervisor, settings: Settings) -> None:
    sup.start("vllm", [0], vllm_params())
    with pytest.raises(GpuBusy) as excinfo:
        sup.start("trainer-ltx", [0, 1], run_config(settings))
    assert excinfo.value.detail == {"gpu": 0, "service": "vllm"}
    assert sup.state("trainer-ltx").state == "idle"

    # The other GPU is free: both run concurrently.
    sup.start("trainer-ltx", [1], run_config(settings))
    inventory = sup.inventory()
    assert [g["in_use_by"] for g in inventory] == ["vllm", "trainer-ltx"]
    with pytest.raises(GpuBusy):
        sup.start("trainer-aitoolkit", [1], run_config(settings, run_id="ivan9-flux-001"))

    # Per the spec's order a restart of a running service on its own GPU is "busy" first ...
    with pytest.raises(GpuBusy) as excinfo:
        sup.start("vllm", [0], vllm_params())
    assert excinfo.value.detail["service"] == "vllm"
    # ... and "already running" is what a 0-GPU service reports.
    sup.start("tensorboard", [], {})
    with pytest.raises(AlreadyRunning):
        sup.start("tensorboard", [], {})

    sup.stop("vllm")
    assert sup.inventory()[0]["in_use_by"] is None
    # Released: the trainer can now take GPU 0 as well on a fresh run.
    sup.stop("trainer-ltx")
    sup.start("trainer-ltx", [0, 1], run_config(settings))
    assert [g["in_use_by"] for g in sup.inventory()] == ["trainer-ltx", "trainer-ltx"]


# --- exits the supervisor did not ask for ----------------------------------------------------------


def test_failed_exit_is_captured_and_releases_gpus(sup: Supervisor, settings: Settings) -> None:
    cfg = run_config(settings, extra={"fail": True})
    started = sup.start("trainer-ltx", [1], cfg)
    state = wait_for_exit(sup, "trainer-ltx")
    assert state.state == "failed"
    assert state.exit_code == 3
    assert state.stopped_by_request is False
    assert state.ended_at is not None and state.started_at == started.started_at
    assert state.pid == started.pid
    assert sup.inventory()[1]["in_use_by"] is None
    with pytest.raises(NotRunning):
        sup.stop("trainer-ltx")
    # The GPU really is free again.
    assert sup.start("vllm", [1], vllm_params()).state == "running"
    # A failed service can be started again; the exit bookkeeping resets.
    again = sup.start("trainer-ltx", [0], run_config(settings))
    assert again.state == "running" and again.exit_code is None and again.ended_at is None


def test_vllm_fail_switch_via_extra_args(sup: Supervisor) -> None:
    sup.start("vllm", [0], vllm_params(extra_args=["--fail"]))
    state = wait_for_exit(sup, "vllm")
    assert state.state == "failed" and state.exit_code == 3


def test_transfer_exits_zero(sup: Supervisor, settings: Settings) -> None:
    sup.start("pull-dataset", [], {"repo_id": "org/faces", "hf_token": "hf_secret_abc"})
    state = wait_for_exit(sup, "pull-dataset")
    assert state.state == "exited"
    assert state.exit_code == 0
    assert state.stopped_by_request is False
    assert state.params == {
        "repo_id": "org/faces",
        "local_name": None,
        "name": "faces",
        "split": "train",
        "revision": None,
        "image_column": "image",
        "caption_column": "caption",
        "id_column": None,
        "hf_token": "***",
        "only_metadata": False,
    }
    text = Path(state.log_path).read_text()
    assert "transfer complete" in text and "hf_secret_abc" not in text

    sup.start("push-lora", [], {"run_id": "nora7-h3-001", "repo_id": "org/nora7-lora"})
    state = wait_for_exit(sup, "push-lora")
    assert state.state == "exited" and state.exit_code == 0
    assert state.run_id == "nora7-h3-001"


def test_states_polls_every_child(sup: Supervisor) -> None:
    sup.start("pull-dataset", [], {"repo_id": "org/faces"})
    wait_until(
        lambda: next(s for s in sup.states() if s.name == "pull-dataset").state == "exited",
        "pull-dataset to show as exited through states()",
    )


# --- stop: SIGTERM, then SIGKILL ---------------------------------------------------------------------


def test_stop_escalates_to_sigkill(sup: Supervisor) -> None:
    state = sup.start("vllm", [0], vllm_params(extra_args=["--ignore-sigterm"]))
    wait_for_log(state.log_path, "sleeping until SIGTERM")
    t0 = time.monotonic()
    stopped = sup.stop("vllm", timeout_s=1.0)
    elapsed = time.monotonic() - t0
    assert stopped.state == "stopped"
    assert stopped.exit_code == -9  # SIGKILL
    assert stopped.stopped_by_request is True
    assert 1.0 <= elapsed < WAIT_S
    assert "ignoring SIGTERM" in Path(state.log_path).read_text()
    assert sup.inventory()[0]["in_use_by"] is None


def test_stop_signals_the_whole_process_group(sup: Supervisor, settings: Settings) -> None:
    """The child is its own session leader (``start_new_session``): pgid == pid."""
    state = sup.start("tensorboard", [], {})
    assert state.pid is not None
    assert os.getpgid(state.pid) == state.pid
    sup.stop("tensorboard")


def test_shutdown_stops_everything(sup: Supervisor, settings: Settings) -> None:
    sup.start("vllm", [0], vllm_params())
    sup.start("trainer-ltx", [1], run_config(settings))
    sup.start("tensorboard", [], {})
    sup.shutdown()
    states = {s.name: s for s in sup.states()}
    for name in ("vllm", "trainer-ltx", "tensorboard"):
        assert states[name].state == "stopped", name
        assert states[name].stopped_by_request is True
    assert states["pull-dataset"].state == "idle"
    assert all(g["in_use_by"] is None for g in sup.inventory())
    sup.shutdown()  # idempotent


def test_stop_finalizes_its_own_incarnation(
    sup: Supervisor, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A restart that lands while ``stop()`` waits outside the lock is not mistaken for the old child."""
    first = sup.start("tensorboard", [], {})
    wait_for_log(first.log_path, "listening on")
    proc = sup._runs["tensorboard"].proc  # white-box: the Popen of the first incarnation
    assert proc is not None
    real_wait = proc.wait
    restarted: list[ServiceState] = []

    def wait_then_restart(timeout: float | None = None) -> int:
        code = real_wait(timeout=timeout)
        # The old child is gone: a status poll reaps it, and a new start lands before stop()
        # re-acquires the lock.
        assert sup.state("tensorboard").state == "stopped"
        restarted.append(sup.start("tensorboard", [], {}))
        return code

    monkeypatch.setattr(proc, "wait", wait_then_restart)
    stopped = sup.stop("tensorboard")
    assert stopped.state == "stopped" and stopped.stopped_by_request is True
    assert stopped.pid == first.pid and stopped.exit_code == 0
    current = sup.state("tensorboard")
    assert current.state == "running" and current.pid == restarted[0].pid != first.pid


def test_fake_bind_failure_is_a_failed_exit(sup: Supervisor, tensorboard_port: int) -> None:
    port = tensorboard_port
    first = sup.start("tensorboard", [], {})
    wait_for_log(first.log_path, "listening on")
    sup.start("vllm", [0], vllm_params(port=port))  # same port: the fake cannot bind
    state = wait_for_exit(sup, "vllm")
    assert state.state == "failed" and state.exit_code == 4
    assert "could not bind" in Path(state.log_path).read_text()
    assert sup.state("tensorboard").state == "running"


def test_fakeservice_usage_errors(capsys: pytest.CaptureFixture[str]) -> None:
    from podagent import fakeservice

    assert fakeservice.main([]) == 2
    assert fakeservice.main(["vllm"]) == 2
    assert fakeservice.main(["vllm", "{not json"]) == 2
    assert fakeservice.main(["vllm", "[1, 2]"]) == 2
    assert fakeservice.main(["vllm", '{"fail": true}']) == 3
    assert fakeservice.main(["trainer-ltx", '{"extra": {"fail": true}}']) == 3
    captured = capsys.readouterr()
    assert "usage:" in captured.err
    assert "failing as requested" in captured.out


# --- logs --------------------------------------------------------------------------------------------


def test_log_is_truncated_at_every_start(sup: Supervisor) -> None:
    first = sup.start("tensorboard", [], {})
    wait_for_log(first.log_path, "listening on")
    sup.stop("tensorboard")
    assert Path(first.log_path).read_text().count("fakeservice: name=tensorboard") == 1

    second = sup.start("tensorboard", [], {})
    assert second.log_path == first.log_path
    wait_for_log(second.log_path, "listening on")
    text = Path(second.log_path).read_text()
    assert text.count("fakeservice: name=tensorboard") == 1
    assert f"pid={second.pid}" in text and f"pid={first.pid}" not in text


def test_logs_404_when_file_vanished(sup: Supervisor) -> None:
    state = sup.start("tensorboard", [], {})
    wait_for_log(state.log_path, "listening on")
    sup.stop("tensorboard")
    Path(state.log_path).unlink()
    with pytest.raises(NotFound):
        sup.logs("tensorboard")


def test_tail_file(tmp_path: Path) -> None:
    path = tmp_path / "x.log"
    path.write_bytes(b"")
    assert tail_file(path, 5) == ([], False)

    path.write_text("".join(f"line {i}\n" for i in range(10)))
    assert tail_file(path, 3) == (["line 7", "line 8", "line 9"], True)
    assert tail_file(path, 10) == ([f"line {i}" for i in range(10)], False)
    assert tail_file(path, 50) == ([f"line {i}" for i in range(10)], False)
    assert tail_file(path, 1) == (["line 9"], True)

    # A line still being written (no newline yet) is the last line.
    path.write_text("a\nb\npartial")
    assert tail_file(path, 2) == (["b", "partial"], True)
    assert tail_file(path, 3) == (["a", "b", "partial"], False)

    # Windows line ends and undecodable bytes do not break it.
    path.write_bytes(b"one\r\ntwo\r\n\xff\xfe\n")
    lines, truncated = tail_file(path, 10)
    assert lines[:2] == ["one", "two"] and len(lines) == 3 and truncated is False

    # Chunked reverse reads: chunks smaller than a line, cuts on and off newline boundaries.
    body = "".join(f"{i:04d} {'x' * (i % 7)}\n" for i in range(500))
    path.write_text(body)
    expected = body.splitlines()
    for chunk in (1, 2, 3, 5, 8, 13, 64, 1024):
        for n in (1, 2, 7, 100, 499, 500, 501):
            lines, truncated = tail_file(path, n, chunk_bytes=chunk)
            assert lines == expected[-n:], (chunk, n)
            assert truncated is (n < 500), (chunk, n)

    with pytest.raises(ValueError, match="tail"):
        tail_file(path, 0)


# --- real (non-fake) argv that cannot be spawned ------------------------------------------------------


def test_spawn_failure_is_reported_not_swallowed(settings: Settings) -> None:
    """Without fake mode the catalog argv points at /opt venvs that do not exist here."""
    real = replace(settings, fake_gpus=None)
    sup = Supervisor(real, FakeBackend(2))
    assert CATALOG["tensorboard"].argv  # sanity: the real builder is what will be used
    with pytest.raises(AgentError) as excinfo:
        sup.start("tensorboard", [], {})
    assert excinfo.value.code == "internal"
    assert "could not spawn tensorboard" in excinfo.value.message
    state = sup.state("tensorboard")
    assert state.state == "failed" and state.pid is None and state.exit_code is None
    assert state.ended_at is not None
    assert "could not spawn tensorboard" in sup.logs("tensorboard").lines[0]
    assert all(g["in_use_by"] is None for g in sup.inventory())
    # The failed attempt does not block a later one.
    with pytest.raises(AgentError):
        sup.start("tensorboard", [], {})
    sup.shutdown()


# --- the child environment ------------------------------------------------------------------------------


def test_child_env_drops_control_plane_secrets(
    sup: Supervisor, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    """PODAGENT_TOKEN and a stray VLLM_API_KEY never reach a child; TensorBoard gets no HF_TOKEN."""
    monkeypatch.setenv("PODAGENT_TOKEN", settings.token)
    monkeypatch.setenv("VLLM_API_KEY", "agent-env-vllm-key-000")
    monkeypatch.setenv("HF_TOKEN", "hf_agent_env_token")

    tb = sup.start("tensorboard", [], {})
    text = wait_for_log(tb.log_path, "listening on")
    assert "PODAGENT_TOKEN=unset" in text
    assert "VLLM_API_KEY=unset" in text
    assert "HF_TOKEN=unset" in text  # a public listener that never talks to the Hub
    assert "CUDA_DEVICE_ORDER='PCI_BUS_ID'" in text
    assert settings.token not in text

    # Services that do talk to the Hub inherit HF_TOKEN; the agent token still never leaks.
    pull = sup.start("pull-dataset", [], {"repo_id": "org/faces"})
    text = wait_for_log(pull.log_path, "params=")
    assert "HF_TOKEN=set" in text and "PODAGENT_TOKEN=unset" in text

    # vLLM gets its key explicitly from the spec (the agent token by default), not by
    # inheritance.
    vllm = sup.start("vllm", [0], vllm_params())
    text = wait_for_log(vllm.log_path, "listening on")
    assert "VLLM_API_KEY=set" in text and "PODAGENT_TOKEN=unset" in text
    assert "CUDA_VISIBLE_DEVICES='0'" in text and "CUDA_DEVICE_ORDER='PCI_BUS_ID'" in text


def test_child_env_function_shape(settings: Settings, monkeypatch: pytest.MonkeyPatch) -> None:
    from podagent.catalog import parse_params
    from podagent.supervisor import CHILD_ENV_DROP, child_env

    monkeypatch.setenv("PODAGENT_TOKEN", settings.token)
    monkeypatch.setenv("PODAGENT_WORKSPACE", str(settings.paths.workspace))
    monkeypatch.setenv("CUDA_DEVICE_ORDER", "FASTEST_FIRST")  # the agent's own value is overridden
    assert "PODAGENT_TOKEN" in CHILD_ENV_DROP
    parsed = parse_params("trainer-ltx", run_config(settings), settings.paths)
    env = child_env(CATALOG["trainer-ltx"], [1, 2], parsed, settings)
    assert "PODAGENT_TOKEN" not in env and "VLLM_API_KEY" not in env
    assert env["PODAGENT_WORKSPACE"] == str(settings.paths.workspace)  # the wrappers need it
    assert env["CUDA_VISIBLE_DEVICES"] == "1,2"
    assert env["CUDA_DEVICE_ORDER"] == "PCI_BUS_ID"
    assert env["HF_HOME"] == str(settings.paths.hf_cache)


# --- orphaned process groups ----------------------------------------------------------------------------


def orphan_pid(log_path: str | Path) -> int:
    text = wait_for_log(log_path, "orphan pid=")
    line = next(line for line in text.splitlines() if "orphan pid=" in line)
    return int(line.split("pid=")[1].split()[0])


def test_orphaned_group_keeps_gpus_booked_until_it_is_gone(
    sup: Supervisor, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A dead wrapper whose trainer lives on: GPUs stay booked, SIGTERM then SIGKILL the group."""
    monkeypatch.setattr("podagent.supervisor.ORPHAN_KILL_GRACE_S", 0.5)
    cfg = run_config(settings, extra={"orphan": True, "ignore_sigterm": True})
    started = sup.start("trainer-ltx", [1], cfg)
    orphan = orphan_pid(started.log_path)
    assert os.getpgid(orphan) == started.pid  # same group as the direct child

    state = wait_for_exit(sup, "trainer-ltx")
    assert state.state == "failed" and state.exit_code == 3
    assert state.group_alive is True
    assert state.holds_gpus()
    assert sup.inventory()[1]["in_use_by"] == "trainer-ltx"
    with pytest.raises(GpuBusy) as excinfo:
        sup.start("vllm", [1], vllm_params())
    assert excinfo.value.detail == {"gpu": 1, "service": "trainer-ltx"}
    with pytest.raises(AlreadyRunning) as excinfo:
        sup.start("trainer-ltx", [0], run_config(settings))
    assert excinfo.value.detail["group_alive"] is True
    os.kill(orphan, 0)  # still there: it ignores SIGTERM

    # After the grace a poll escalates to SIGKILL; once the group is empty the GPUs are free.
    wait_until(lambda: sup.state("trainer-ltx").group_alive is False, "the orphan group to die")
    final = sup.state("trainer-ltx")
    assert final.state == "failed" and final.exit_code == 3 and final.pid == started.pid
    assert sup.inventory()[1]["in_use_by"] is None
    with pytest.raises(ProcessLookupError):
        os.kill(orphan, 0)
    assert sup.start("vllm", [1], vllm_params()).state == "running"


def test_orphaned_group_that_honours_sigterm_is_released_promptly(
    sup: Supervisor, settings: Settings
) -> None:
    cfg = run_config(settings, extra={"orphan": True})
    started = sup.start("trainer-aitoolkit", [0, 1], cfg)
    orphan = orphan_pid(started.log_path)
    wait_for_exit(sup, "trainer-aitoolkit")
    # The reap SIGTERMed the group; the orphan dies on it and the next polls release the GPUs.
    wait_until(
        lambda: sup.state("trainer-aitoolkit").group_alive is False, "the orphan to honour SIGTERM"
    )
    with pytest.raises(ProcessLookupError):
        os.kill(orphan, 0)
    assert all(g["in_use_by"] is None for g in sup.inventory())


def test_stop_kills_an_orphaned_group_at_once(sup: Supervisor, settings: Settings) -> None:
    """``stop`` is the app's way out: no 409 while something of the service is still alive."""
    cfg = run_config(settings, extra={"orphan": True, "ignore_sigterm": True})
    started = sup.start("trainer-ltx", [1], cfg)
    orphan = orphan_pid(started.log_path)
    state = wait_for_exit(sup, "trainer-ltx")
    assert state.group_alive is True
    t0 = time.monotonic()
    stopped = sup.stop("trainer-ltx")
    assert time.monotonic() - t0 < 3.0
    assert stopped.group_alive is False
    assert stopped.state == "failed" and stopped.exit_code == 3  # the exit stays as filed
    with pytest.raises(ProcessLookupError):
        os.kill(orphan, 0)
    assert sup.inventory()[1]["in_use_by"] is None
    with pytest.raises(NotRunning):
        sup.stop("trainer-ltx")


# --- a child that survives SIGKILL --------------------------------------------------------------------


class _Swallow:
    """Wraps ``Supervisor._killpg`` so SIGKILL is dropped while ``active``; records every call."""

    def __init__(self) -> None:
        self.active = True
        self.calls: list[tuple[int, int]] = []
        self.real = Supervisor._killpg

    def __call__(self, pgid: int, sig: int) -> None:
        self.calls.append((pgid, int(sig)))
        if self.active and sig == signal.SIGKILL:
            return
        self.real(pgid, sig)


def test_stop_files_stuck_when_sigkill_does_not_end_the_child(
    sup: Supervisor, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("podagent.supervisor.SIGKILL_WAIT_S", 0.3)
    swallow = _Swallow()
    monkeypatch.setattr(Supervisor, "_killpg", staticmethod(swallow))
    started = sup.start("vllm", [0], vllm_params(extra_args=["--ignore-sigterm"]))
    wait_for_log(started.log_path, "sleeping until SIGTERM")

    t0 = time.monotonic()
    state = sup.stop("vllm", timeout_s=0.5)
    elapsed = time.monotonic() - t0
    assert 0.8 <= elapsed < 3.0  # SIGTERM grace + the bounded post-SIGKILL wait, not forever
    assert state.state == "stuck" and state.pid == started.pid
    assert state.stopped_by_request is True and state.exit_code is None
    assert state.holds_gpus()
    assert [sig for _, sig in swallow.calls] == [signal.SIGTERM, signal.SIGKILL]

    # The GPU stays booked and the service is not restartable while it is stuck.
    assert sup.inventory()[0]["in_use_by"] == "vllm"
    with pytest.raises(GpuBusy):
        sup.start("trainer-ltx", [0], run_config(settings))
    with pytest.raises(AlreadyRunning) as excinfo:
        sup.start("vllm", [1], vllm_params())  # on the free GPU: the stuck incarnation blocks it
    assert excinfo.value.detail == {"pid": started.pid, "state": "stuck"}
    assert sup.state("vllm").state == "stuck"

    # Another stop re-sends SIGKILL and waits the bounded time again.
    t0 = time.monotonic()
    assert sup.stop("vllm").state == "stuck"
    assert time.monotonic() - t0 < 2.0
    assert swallow.calls[-1] == (started.pid, signal.SIGKILL)

    # When the kill finally lands the incarnation is filed as stopped and the GPU released.
    swallow.active = False
    final = sup.stop("vllm")
    assert final.state == "stopped" and final.exit_code == -9 and final.pid == started.pid
    assert sup.inventory()[0]["in_use_by"] is None
    assert sup.start("vllm", [0], vllm_params()).state == "running"


def test_stuck_child_that_dies_later_is_filed_by_a_poll(
    sup: Supervisor, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("podagent.supervisor.SIGKILL_WAIT_S", 0.2)
    swallow = _Swallow()
    monkeypatch.setattr(Supervisor, "_killpg", staticmethod(swallow))
    started = sup.start("tensorboard", [], {})
    wait_for_log(started.log_path, "listening on")
    # The fake honours SIGTERM, so make the stop's SIGTERM disappear as well.
    swallow.active = True
    monkeypatch.setattr(swallow, "real", lambda _pgid, _sig: None)
    assert sup.stop("tensorboard", timeout_s=0.3).state == "stuck"
    os.killpg(started.pid, signal.SIGKILL)  # the driver lets go
    wait_until(lambda: sup.state("tensorboard").state == "stopped", "the stuck child to be filed")
    assert sup.state("tensorboard").exit_code == -9


# --- shutdown: everything at once, one deadline -------------------------------------------------------


def test_shutdown_signals_everything_at_once_within_one_deadline(
    sup: Supervisor, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("podagent.supervisor.SHUTDOWN_GRACE_S", 1.0)
    swallow = _Swallow()
    swallow.active = False  # record only
    monkeypatch.setattr(Supervisor, "_killpg", staticmethod(swallow))

    vllm = sup.start("vllm", [0], vllm_params(extra_args=["--ignore-sigterm"]))
    trainer = sup.start("trainer-ltx", [1], run_config(settings))
    tb = sup.start("tensorboard", [], {})
    for state in (vllm, trainer, tb):
        wait_for_log(state.log_path, "SIGTERM")  # "sleeping until SIGTERM" / "listening on"
    wait_for_log(tb.log_path, "listening on")

    t0 = time.monotonic()
    sup.shutdown()
    elapsed = time.monotonic() - t0
    # vLLM ignores SIGTERM, so the whole thing takes the grace plus a fast SIGKILL: nowhere
    # near 3 x 10 s. Everything else would have finished long before the deadline.
    assert 1.0 <= elapsed < 2.5

    terms = [pgid for pgid, sig in swallow.calls if sig == signal.SIGTERM]
    kills = [pgid for pgid, sig in swallow.calls if sig == signal.SIGKILL]
    assert terms[0] == trainer.pid  # the trainer has the only state worth flushing
    assert set(terms) == {vllm.pid, trainer.pid, tb.pid}
    assert kills == [vllm.pid]
    # Every SIGTERM went out before any SIGKILL.
    assert swallow.calls.index((vllm.pid, signal.SIGKILL)) > max(
        swallow.calls.index((pid, signal.SIGTERM)) for pid in terms
    )

    states = {s.name: s for s in sup.states()}
    assert states["vllm"].state == "stopped" and states["vllm"].exit_code == -9
    assert states["trainer-ltx"].state == "stopped" and states["trainer-ltx"].exit_code == 0
    assert states["tensorboard"].state == "stopped" and states["tensorboard"].exit_code == 0
    assert all(s.stopped_by_request for s in states.values() if s.state == "stopped")
    assert all(g["in_use_by"] is None for g in sup.inventory())
    for pid in (vllm.pid, trainer.pid, tb.pid):
        with pytest.raises(ProcessLookupError):
            os.kill(pid, 0)


def test_shutdown_is_bounded_even_when_sigkill_does_not_land(
    sup: Supervisor, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("podagent.supervisor.SHUTDOWN_GRACE_S", 0.5)
    monkeypatch.setattr("podagent.supervisor.SIGKILL_WAIT_S", 0.3)
    swallow = _Swallow()
    monkeypatch.setattr(Supervisor, "_killpg", staticmethod(swallow))
    started = sup.start("vllm", [0], vllm_params(extra_args=["--ignore-sigterm"]))
    wait_for_log(started.log_path, "sleeping until SIGTERM")
    t0 = time.monotonic()
    sup.shutdown()
    assert time.monotonic() - t0 < 2.0
    assert sup.state("vllm").state == "stuck"
    assert sup.inventory()[0]["in_use_by"] == "vllm"
    swallow.active = False
    sup.shutdown()  # a second pass kills it for real
    assert sup.state("vllm").state == "stopped" and sup.state("vllm").exit_code == -9


# --- inventory: unavailable is not empty --------------------------------------------------------------


class FlakyBackend:
    """A 2-GPU inventory that raises ``InventoryUnavailable`` while ``fail`` is set."""

    kind = "fake"

    def __init__(self, count: int = 2) -> None:
        self.inner = FakeBackend(count)
        self.fail = False
        self.calls = 0

    def list_gpus(self) -> list[Any]:
        self.calls += 1
        if self.fail:
            raise InventoryUnavailable("nvidia-smi did not finish within 10 s")
        return self.inner.list_gpus()


def test_inventory_unavailable_is_503_not_an_empty_pod(settings: Settings) -> None:
    backend = FlakyBackend()
    sup = Supervisor(settings, backend)
    backend.fail = True
    with pytest.raises(GpuInventoryUnavailable) as excinfo:
        sup.start("vllm", [0], vllm_params())
    assert excinfo.value.status == 503 and excinfo.value.code == "gpu_inventory_unavailable"
    assert "10 s" in excinfo.value.message
    assert excinfo.value.detail == {"last_known_count": None, "last_known_at": None}
    with pytest.raises(GpuInventoryUnavailable):
        sup.inventory()
    with pytest.raises(GpuInventoryUnavailable):
        sup.gpu_count()
    assert sup.state("vllm").state == "idle"  # nothing was started
    # 0-GPU services do not need the inventory at all.
    assert sup.start("tensorboard", [], {}).state == "running"

    backend.fail = False
    assert sup.gpu_count() == 2
    sup.start("vllm", [0], vllm_params())
    backend.fail = True
    with pytest.raises(GpuInventoryUnavailable) as excinfo:
        sup.start("trainer-ltx", [1], run_config(settings))
    detail = excinfo.value.detail
    assert detail["last_known_count"] == 2
    assert isinstance(detail["last_known_at"], str) and detail["last_known_at"].endswith("+00:00")
    # The running service is untouched by the hiccup, and once nvidia-smi answers again the
    # bookkeeping is where it was.
    backend.fail = False
    assert [g["in_use_by"] for g in sup.inventory()] == ["vllm", None]
    sup.shutdown()


def test_inventory_polls_children_before_reporting_holders(
    sup: Supervisor, settings: Settings
) -> None:
    """``/gpus`` alone must see a child's own exit; it must not wait for ``/services`` or a start."""
    sup.start("trainer-ltx", [1], run_config(settings, extra={"fail": True}))
    assert sup.inventory()[1]["in_use_by"] in ("trainer-ltx", None)
    wait_until(
        lambda: sup.inventory()[1]["in_use_by"] is None,
        "inventory() alone to release the GPU of a crashed child",
    )
    assert sup._runs["trainer-ltx"].state.state == "failed"  # white-box: reaped by inventory()


# --- logs that outlive the agent ------------------------------------------------------------------------


def test_logs_fall_back_to_the_volume_file_for_fixed_locations(
    sup: Supervisor, settings: Settings
) -> None:
    """A service that has not run since boot still serves ``/workspace/logs/<name>.log``."""
    settings.paths.logs.mkdir(parents=True, exist_ok=True)
    (settings.paths.logs / "vllm.log").write_text("earlier lifetime\nlast line\n")
    tail = sup.logs("vllm", tail=1)
    assert tail.lines == ["last line"] and tail.truncated is True
    assert tail.path == str(settings.paths.logs / "vllm.log")
    for name in ("tensorboard", "pull-dataset", "push-lora"):
        with pytest.raises(NotFound, match="no log file"):
            sup.logs(name)  # a fixed location, but nothing there yet
    # The trainers' log location depends on the run: point the caller at /runs/{id}/log.
    with pytest.raises(NotFound, match=r"/runs/\{id\}/log"):
        sup.logs("trainer-aitoolkit")
    # Once started, the incarnation's own path is what counts (and the file is truncated).
    state = sup.start("vllm", [0], vllm_params())
    wait_for_log(state.log_path, "listening on")
    assert "earlier lifetime" not in sup.logs("vllm", tail=5000).lines


def test_run_log_reads_the_trainer_log_of_any_run(sup: Supervisor, settings: Settings) -> None:
    with pytest.raises(NotFound) as excinfo:
        sup.run_log("ivan9-flux-001")
    assert excinfo.value.detail == {
        "path": str(settings.paths.run_dir("ivan9-flux-001") / "trainer.log")
    }
    run_dir = settings.paths.run_dir("ivan9-flux-001")
    run_dir.mkdir(parents=True)
    (run_dir / "trainer.log").write_text("".join(f"step {i}\n" for i in range(5)))
    log = sup.run_log("ivan9-flux-001", tail=2)
    assert log.run_id == "ivan9-flux-001"
    assert log.lines == ["step 3", "step 4"] and log.truncated is True
    assert log.path == str(run_dir / "trainer.log")

    # A run this agent started: the same file through either door.
    state = sup.start("trainer-ltx", [1], run_config(settings))
    wait_for_log(state.log_path, "sleeping until SIGTERM")
    sup.stop("trainer-ltx")
    assert sup.run_log("nora7-h3-001", tail=5000).lines == sup.logs("trainer-ltx", 5000).lines
