"""Process supervisor: one instance per service name, GPUs by CUDA_VISIBLE_DEVICES (POD-SPEC §2.6).

State is in memory and dies with the agent (which is PID 1's only child under ``tini``, so with
the container). Every public method is safe to call from the API's threadpool: bookkeeping
happens under ``self._lock``; the things that can block for a long time, the GPU backend
(nvidia-smi, up to 10 s) and waiting for a signalled child to exit, run outside it so status
polls keep answering while a stop is in flight.

Children are spawned as ``Popen(argv, cwd, env, stdout=<log>, stderr=STDOUT,
start_new_session=True)``: argv comes from the catalog (or ``fake_argv`` in fake mode), never
from a shell string; the env is built by ``child_env`` (the agent's environment minus the
control-plane secrets, plus ``CUDA_VISIBLE_DEVICES``, ``CUDA_DEVICE_ORDER``, ``HF_HOME`` and the
service's own additions). ``start_new_session`` puts the child in its own process group so the
whole tree (a launch wrapper plus its trainer, vLLM plus its workers) can be signalled, not just
the direct child.

GPU bookkeeping follows the process *group*, not the direct child: a service keeps its GPUs
while it is ``running``, while it is ``stuck`` (SIGKILL did not end it) and while
``group_alive`` is set (the direct child exited but something in its group lives on). The group
is probed with ``killpg(pgid, 0)``, which stays valid while any member exists, so orphans must
be reaped by the container's init: the entrypoint runs the agent under ``tini -s``.
"""

from __future__ import annotations

import contextlib
import json
import logging
import os
import signal
import subprocess
import threading
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, ValidationError

from .catalog import CATALOG, SECRET_FIELDS, ServiceSpec, fake_argv, parse_params
from .errors import (
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
from .gpus import GpuBackend, GpuInfo, InventoryUnavailable
from .settings import Settings
from .storage import write_run_state
from .uploads import release_stage

log = logging.getLogger(__name__)

State = Literal["idle", "running", "stopped", "failed", "exited", "stuck"]

DEFAULT_STOP_TIMEOUT_S = 30.0
# After SIGKILL a child normally dies within milliseconds; one that is still there after this
# long is in uninterruptible sleep (a wedged GPU driver) and is filed as ``stuck``.
SIGKILL_WAIT_S = 3.0
# Shutdown signals every running group at once and waits for all of them against this one
# deadline: well under the container runtime's stop grace (Docker's default is 10 s), so the
# SIGKILL escalation below still happens on our terms rather than by pid-namespace teardown.
SHUTDOWN_GRACE_S = 8.0
# Orphans left in a dead child's process group get SIGTERM at once and SIGKILL after this.
ORPHAN_KILL_GRACE_S = 5.0
GROUP_POLL_S = 0.05
TAIL_CHUNK_BYTES = 64 * 1024
# The trainers' log inside a run directory (catalog ``_trainer_log``); read back by
# ``run_log`` for runs that finished before this agent started.
TRAINER_LOG_NAME = "trainer.log"

# Never inherited by a child. The control-plane bearer is only the agent's business; vLLM's key
# is set explicitly by the ``vllm`` spec's ``env()`` and must not reach the other services.
CHILD_ENV_DROP: frozenset[str] = frozenset({"PODAGENT_TOKEN", "VLLM_API_KEY"})
# Per-service drops on top of that. TensorBoard is an unauthenticated public listener that never
# talks to the Hub, so it has no use for a Hub token.
CHILD_ENV_DROP_FOR: dict[str, frozenset[str]] = {
    "tensorboard": frozenset({"HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"}),
}


class ServiceState(BaseModel):
    name: str
    state: State = "idle"
    pid: int | None = None
    gpus: list[int] = []
    params: dict[str, Any] | None = None
    exit_code: int | None = None
    stopped_by_request: bool = False
    # The direct child has exited but its process group has not: an orphaned trainer or vLLM
    # worker still holds the GPUs, which stay booked until the group is gone.
    group_alive: bool = False
    started_at: datetime | None = None
    ended_at: datetime | None = None
    log_path: str | None = None
    port: int | None = None
    run_id: str | None = None

    def holds_gpus(self) -> bool:
        return self.state in ("running", "stuck") or self.group_alive


class LogTail(BaseModel):
    name: str
    path: str
    lines: list[str]
    truncated: bool


class RunLog(BaseModel):
    run_id: str
    path: str
    lines: list[str]
    truncated: bool


@dataclass
class _Run:
    """One incarnation of a service: its published state plus the live ``Popen`` while running.

    Every start creates a fresh record, so a ``stop()`` that is waiting outside the lock keeps
    finalizing the incarnation it signalled even if a later start has replaced it in
    ``Supervisor._runs``.
    """

    state: ServiceState
    proc: subprocess.Popen[bytes] | None = None
    # Protects against a double finalize when stop() and a status poll both see the exit.
    finalized: bool = True
    # When (monotonic) the process group was last sent SIGTERM, and whether SIGKILL went out.
    group_term_at: float | None = None
    group_killed: bool = False
    recorded_terminal: tuple[str, int | None, bool] | None = None


def _now() -> datetime:
    return datetime.now(UTC)


def _redact_errors(errors: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Pydantic's error list with secret inputs replaced by ``"***"``.

    A field error carries only that field's input, but a model-level error (an after-validator,
    for instance) carries the whole params dict, secrets included. Nothing a client sent as a
    secret may come back in a response.
    """
    redacted: list[dict[str, Any]] = []
    for error in errors:
        error = dict(error)
        loc = tuple(error.get("loc") or ())
        if loc and loc[-1] in SECRET_FIELDS:
            error["input"] = "***"
        elif isinstance(error.get("input"), dict):
            data = dict(error["input"])
            for key in SECRET_FIELDS:
                if key in data and data[key] is not None:
                    data[key] = "***"
            error["input"] = data
        redacted.append(error)
    return redacted


def tail_file(
    path: Path, tail: int, *, chunk_bytes: int = TAIL_CHUNK_BYTES
) -> tuple[list[str], bool]:
    """Last ``tail`` lines of ``path`` and whether the file held more.

    Reads backwards in ``chunk_bytes`` blocks, so a multi-gigabyte trainer log costs about
    ``tail`` lines of I/O. A trailing line still being written (no newline yet) counts as the
    last line. Bytes are decoded as UTF-8 with replacement; a trailing ``\\r`` is dropped.
    """
    if tail < 1:
        raise ValueError("tail must be >= 1")
    with path.open("rb") as handle:
        handle.seek(0, os.SEEK_END)
        pos = handle.tell()
        chunks: list[bytes] = []
        newlines = 0
        # Stop once the buffer holds more line ends than we need (so the partial first line
        # can be dropped) or the whole file is in hand.
        while pos > 0 and newlines <= tail:
            step = min(chunk_bytes, pos)
            pos -= step
            handle.seek(pos)
            chunk = handle.read(step)
            chunks.append(chunk)
            newlines += chunk.count(b"\n")
    data = b"".join(reversed(chunks))
    if not data:
        return [], False
    segments = data.split(b"\n")
    if pos > 0:
        segments = segments[1:]  # cut mid-line: the head segment is incomplete
    if segments and segments[-1] == b"":
        segments.pop()  # the file ends with a newline, not with an empty line
    truncated = pos > 0 or len(segments) > tail
    lines = [seg.decode("utf-8", errors="replace").rstrip("\r") for seg in segments[-tail:]]
    return lines, truncated


def child_env(
    spec: ServiceSpec, gpus: list[int], parsed: Any, settings: Settings
) -> dict[str, str]:
    """The environment a service child runs with (POD-SPEC §2.6).

    The agent's environment minus ``CHILD_ENV_DROP`` and the service's ``CHILD_ENV_DROP_FOR``
    entries, then ``CUDA_VISIBLE_DEVICES`` (comma-joined requested indices; ``""`` for 0-GPU
    services so they see no GPU), ``CUDA_DEVICE_ORDER=PCI_BUS_ID`` (nvidia-smi numbers GPUs in
    PCI bus order; without this the CUDA runtime's default FASTEST_FIRST enumeration may not
    match, and the index the agent booked would not be the board the child uses), ``HF_HOME``
    and the spec's own additions, which win over everything inherited.
    """
    dropped = CHILD_ENV_DROP | CHILD_ENV_DROP_FOR.get(spec.name, frozenset())
    env = {key: value for key, value in os.environ.items() if key not in dropped}
    env["CUDA_VISIBLE_DEVICES"] = ",".join(str(index) for index in gpus)
    env["CUDA_DEVICE_ORDER"] = "PCI_BUS_ID"
    env["HF_HOME"] = str(settings.paths.hf_cache)
    env.update(spec.env(parsed, settings))
    return env


class Supervisor:
    def __init__(self, settings: Settings, backend: GpuBackend) -> None:
        self.settings = settings
        self.backend = backend
        self._lock = threading.Lock()
        self._runs: dict[str, _Run] = {
            name: _Run(state=ServiceState(name=name)) for name in CATALOG
        }
        # The last inventory the backend answered with, and when: reported alongside a
        # ``gpu_inventory_unavailable`` error so the app can tell a hiccup from an empty pod.
        self._last_inventory: tuple[list[GpuInfo], datetime] | None = None

    def names(self) -> list[str]:
        return list(CATALOG)

    # --- reading -------------------------------------------------------------------------------

    def _inventory(self) -> list[GpuInfo]:
        """The backend's inventory; ``GpuInventoryUnavailable`` (503) when it cannot be read.

        Runs outside the lock (nvidia-smi may take seconds). ``[]`` is only ever a successful
        read of a pod without GPUs, never a failed one.
        """
        try:
            gpus = self.backend.list_gpus()
        except InventoryUnavailable as error:
            last = self._last_inventory
            raise GpuInventoryUnavailable(
                f"GPU inventory unavailable: {error}",
                detail={
                    "last_known_count": None if last is None else len(last[0]),
                    "last_known_at": None if last is None else last[1].isoformat(),
                },
            ) from None
        self._last_inventory = (gpus, _now())
        return gpus

    def gpu_count(self) -> int:
        """Number of GPUs in the inventory; raises like ``_inventory``."""
        return len(self._inventory())

    def inventory(self) -> list[dict[str, Any]]:
        """``GpuInfo`` dicts plus ``in_use_by`` from the services that hold GPUs.

        Every child is polled first, so a service that exited on its own since the last call
        releases its GPU here as it would through ``/services`` or a start.
        """
        gpus = self._inventory()
        with self._lock:
            for name in CATALOG:
                self._poll(name)
            holders = self._holders()
        return [{**gpu.model_dump(), "in_use_by": holders.get(gpu.index)} for gpu in gpus]

    def states(self) -> list[ServiceState]:
        with self._lock:
            return [self._poll(name).model_copy(deep=True) for name in CATALOG]

    def state(self, name: str) -> ServiceState:
        """Raises ``NotFound`` for an unknown name; polls the child so exits are reflected."""
        self._spec(name)
        with self._lock:
            return self._poll(name).model_copy(deep=True)

    def logs(self, name: str, tail: int = 200) -> LogTail:
        """Last ``tail`` lines of the service's log; ``NotFound`` when none exists.

        A service that has not run since the agent started still answers when its log lives at
        a fixed place (``/workspace/logs/<name>.log``): the file from an earlier agent lifetime
        is on the volume. The trainers' logs depend on the run, so they are reached through
        ``run_log`` instead.
        """
        spec = self._spec(name)
        with self._lock:
            log_path = self._runs[name].state.log_path
        path = Path(log_path) if log_path is not None else self._static_log_path(spec)
        if path is None:
            raise NotFound(
                f"{name} has not run since the agent started and its log location depends on "
                "the run; use /runs/{id}/log"
            )
        try:
            lines, truncated = tail_file(path, tail)
        except FileNotFoundError:
            raise NotFound(f"no log file for {name} at {path}") from None
        return LogTail(name=name, path=str(path), lines=lines, truncated=truncated)

    def run_log(self, run_id: str, tail: int = 200) -> RunLog:
        """Last ``tail`` lines of ``<run>/trainer.log``; ``NotFound`` when the file is absent.

        The caller validates ``run_id`` against the run-id pattern, so the path cannot escape
        the runs directory.
        """
        path = self.settings.paths.run_dir(run_id) / TRAINER_LOG_NAME
        try:
            lines, truncated = tail_file(path, tail)
        except FileNotFoundError:
            raise NotFound(
                f"no trainer log for run {run_id!r}", detail={"path": str(path)}
            ) from None
        return RunLog(run_id=run_id, path=str(path), lines=lines, truncated=truncated)

    def _static_log_path(self, spec: ServiceSpec) -> Path | None:
        """The catalog log path when it does not depend on the params, else ``None``.

        Catalog convention: a ``log_path`` builder that needs the params (the trainers, whose
        log sits in the run directory) raises ``TypeError`` when handed ``None``.
        """
        try:
            return spec.log_path(None, self.settings.paths)  # type: ignore[arg-type]
        except (TypeError, AttributeError):
            return None

    # --- starting ------------------------------------------------------------------------------

    def start(self, name: str, gpus: list[int], params: dict[str, Any]) -> ServiceState:
        """Validate (POD-SPEC §2.6 order), prepare, spawn with CUDA_VISIBLE_DEVICES; return state.

        Check order: name known → params validate → GPU count in the service's range → every
        index exists in the inventory → no service holds any of them → this service is not
        running (nor stuck, nor survived by an orphaned group). Then ``prepare()``, truncate and
        open the log, spawn, return.
        """
        spec = self._spec(name)
        try:
            parsed = parse_params(name, params, self.settings.paths, fake=self.settings.fake)
        except ValidationError as error:
            raise InvalidParams(
                f"invalid params for {name}",
                detail=_redact_errors(json.loads(error.json(include_url=False))),
            ) from None
        gpus = list(gpus)
        self._check_gpu_count(spec, gpus)
        if gpus:
            known = {gpu.index for gpu in self._inventory()}
            for index in gpus:
                if index not in known:
                    raise UnknownGpu(
                        f"GPU {index} is not in the inventory",
                        detail={"gpu": index, "known": sorted(known)},
                    )
        with self._lock:
            for other in CATALOG:
                self._poll(other)
            holders = self._holders()
            for index in gpus:
                holder = holders.get(index)
                if holder is not None:
                    raise GpuBusy(
                        f"GPU {index} is in use by {holder}",
                        detail={"gpu": index, "service": holder},
                    )
            current = self._runs[name].state
            if current.state in ("running", "stuck"):
                raise AlreadyRunning(
                    f"{name} is {current.state}",
                    detail={"pid": current.pid, "state": current.state},
                )
            if current.group_alive:
                raise AlreadyRunning(
                    f"{name}: the process group of the previous incarnation is still alive",
                    detail={"pid": current.pid, "state": current.state, "group_alive": True},
                )
            return self._spawn(spec, gpus, parsed).model_copy(deep=True)

    def _check_gpu_count(self, spec: ServiceSpec, gpus: list[int]) -> None:
        low, high = spec.gpus
        if len(set(gpus)) != len(gpus):
            raise GpuCount(
                f"{spec.name}: gpus must be distinct indices",
                detail={"requested": gpus, "min": low, "max": high},
            )
        if not spec.gpu_count_ok(len(gpus)):
            if low == high:
                expected = f"exactly {low}"
            elif high < 0:
                expected = f"at least {low}"
            else:
                expected = f"between {low} and {high}"
            raise GpuCount(
                f"{spec.name} takes {expected} GPU(s); {len(gpus)} requested",
                detail={"requested": gpus, "min": low, "max": high},
            )

    def _spawn(self, spec: ServiceSpec, gpus: list[int], parsed: Any) -> ServiceState:
        paths = self.settings.paths
        spec.prepare(parsed, paths)
        cwd = spec.cwd(parsed, paths)
        log_path = spec.log_path(parsed, paths)
        argv = (
            fake_argv(spec.name, parsed) if self.settings.fake else spec.argv(parsed, gpus, paths)
        )
        env = child_env(spec, gpus, parsed, self.settings)
        for directory in (cwd, log_path.parent, paths.hf_cache):
            directory.mkdir(parents=True, exist_ok=True)
        started_at = _now()
        state = ServiceState(
            name=spec.name,
            gpus=gpus,
            params=parsed.public(),
            started_at=started_at,
            log_path=str(log_path),
            port=getattr(parsed, "port", spec.port),
            run_id=spec.run_id(parsed),
        )
        # Truncate at every start so a tail always shows the current run. The parent closes its
        # handle right after the spawn; the child keeps its own file descriptor.
        try:
            opened_log = log_path.open("wb")
        except OSError:
            if spec.name == "pull-dataset" and getattr(parsed, "local_name", None):
                release_stage(paths, parsed.local_name)
            raise
        with opened_log as log_file:
            try:
                proc = subprocess.Popen(
                    argv,
                    cwd=str(cwd),
                    env=env,
                    stdin=subprocess.DEVNULL,
                    stdout=log_file,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
            except OSError as error:
                message = f"could not spawn {spec.name}: {error}"
                log_file.write((message + "\n").encode())
                log.error("%s (argv[0]=%r)", message, argv[0])
                state.state = "failed"
                state.ended_at = _now()
                self._record_training_state(state)
                self._runs[spec.name] = _Run(state=state)
                raise AgentError(message, detail={"argv0": argv[0]}) from None
        state.state = "running"
        state.pid = proc.pid
        self._record_training_state(state)
        self._runs[spec.name] = _Run(state=state, proc=proc, finalized=False)
        log.info("started %s pid=%d gpus=%s log=%s", spec.name, proc.pid, gpus, log_path)
        return state

    # --- stopping ------------------------------------------------------------------------------

    def stop(self, name: str, timeout_s: float = DEFAULT_STOP_TIMEOUT_S) -> ServiceState:
        """SIGTERM the process group, wait ``timeout_s``, SIGKILL, wait ``SIGKILL_WAIT_S``.

        Raises ``NotRunning`` when there is nothing to stop. A ``stuck`` service or one whose
        orphaned group is still alive is sent SIGKILL again and given the bounded wait only.
        A child that survives SIGKILL (uninterruptible sleep in the driver) is filed as
        ``stuck`` with its pid; its GPUs stay booked until a later poll finds it gone.
        """
        self._spec(name)
        with self._lock:
            run = self._runs[name]
            state = self._reap(run)
            proc = run.proc
            pgid = state.pid
            if state.state == "running" and proc is not None and pgid is not None:
                # Set before signalling so a concurrent poll that reaps the exit files it as
                # stopped.
                state.stopped_by_request = True
                self._killpg(pgid, signal.SIGTERM)
                run.group_term_at = time.monotonic()
                grace = timeout_s
            elif (state.state == "stuck" or state.group_alive) and pgid is not None:
                self._killpg(pgid, signal.SIGKILL)
                run.group_killed = True
                grace = 0.0
            else:
                raise NotRunning(f"{name} is not running", detail={"state": state.state})
        # Waiting happens outside the lock so status calls keep answering meanwhile. ``run`` is
        # this incarnation's record; a start that lands in the meantime installs a new one.
        if grace > 0 and proc is not None:
            try:
                proc.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                log.warning("%s did not exit %.0f s after SIGTERM; sending SIGKILL", name, grace)
                with self._lock:
                    self._killpg(pgid, signal.SIGKILL)
                    run.group_killed = True
                self._await_kill(run, proc, pgid)
        else:
            self._await_kill(run, proc, pgid)
        with self._lock:
            return self._reap(run).model_copy(deep=True)

    def _await_kill(self, run: _Run, proc: subprocess.Popen[bytes] | None, pgid: int) -> None:
        """Bounded wait after SIGKILL: the child, or (no child) the orphaned group. No lock held."""
        deadline = time.monotonic() + SIGKILL_WAIT_S
        if proc is not None:
            try:
                proc.wait(timeout=SIGKILL_WAIT_S)
            except subprocess.TimeoutExpired:
                with self._lock:
                    self._mark_stuck(run)
                return
        while self._group_alive(pgid) and time.monotonic() < deadline:
            time.sleep(GROUP_POLL_S)

    def shutdown(self, grace_s: float | None = None) -> None:
        """Stop everything at once (agent shutdown hook), within ``grace_s`` (``SHUTDOWN_GRACE_S``).

        Every running group gets SIGTERM first, trainers before the rest (they have the only
        state worth flushing: a checkpoint in progress); then all of them are waited on against
        one shared deadline; whatever is left gets SIGKILL and the bounded wait. Stuck services
        and orphaned groups are SIGKILLed straight away. The whole thing stays under the
        container runtime's stop grace, so no child is ever killed by namespace teardown while
        this method is still waiting on an earlier one.
        """
        grace = SHUTDOWN_GRACE_S if grace_s is None else grace_s
        signalled: list[tuple[_Run, subprocess.Popen[bytes] | None, int]] = []
        with self._lock:
            for name in CATALOG:
                self._poll(name)
            ordered = sorted(
                self._runs.values(),
                key=lambda run: 0 if run.state.name.startswith("trainer-") else 1,
            )
            for run in ordered:
                state = run.state
                if state.pid is None:
                    continue
                if state.state == "running" and run.proc is not None:
                    state.stopped_by_request = True
                    self._killpg(state.pid, signal.SIGTERM)
                    run.group_term_at = time.monotonic()
                    signalled.append((run, run.proc, state.pid))
                elif state.state == "stuck" or state.group_alive:
                    self._killpg(state.pid, signal.SIGKILL)
                    run.group_killed = True
                    signalled.append((run, run.proc, state.pid))
        if not signalled:
            return
        deadline = time.monotonic() + grace
        for _run, proc, _pgid in signalled:
            if proc is None:
                continue
            with contextlib.suppress(subprocess.TimeoutExpired):
                proc.wait(timeout=max(0.0, deadline - time.monotonic()))
        survivors = [
            (run, proc, pgid)
            for run, proc, pgid in signalled
            if proc is None or proc.poll() is None or run.state.group_alive
        ]
        if survivors:
            with self._lock:
                for run, _proc, pgid in survivors:
                    if not run.group_killed:
                        log.warning(
                            "%s did not exit within the %.0f s shutdown grace; sending SIGKILL",
                            run.state.name,
                            grace,
                        )
                    self._killpg(pgid, signal.SIGKILL)
                    run.group_killed = True
            for run, proc, pgid in survivors:
                self._await_kill(run, proc, pgid)
        with self._lock:
            for run, _proc, _pgid in signalled:
                self._reap(run)

    @staticmethod
    def _killpg(pgid: int, sig: signal.Signals) -> None:
        """Deliver ``sig`` to a child's process group (it is a session leader: pgid == pid)."""
        try:
            os.killpg(pgid, sig)
        except ProcessLookupError:
            return  # already gone
        except PermissionError:  # pragma: no cover - a stale pid reused by another user
            log.warning("no permission to signal process group %d", pgid)

    @staticmethod
    def _group_alive(pgid: int) -> bool:
        """Whether any process (zombies included, hence ``tini``) remains in the group."""
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:  # pragma: no cover - someone else's process holds the pgid
            return True
        return True

    # --- internals (callers hold self._lock) ------------------------------------------------------

    @staticmethod
    def _spec(name: str) -> ServiceSpec:
        try:
            return CATALOG[name]
        except KeyError:
            raise NotFound(f"unknown service {name!r}", detail={"known": list(CATALOG)}) from None

    def _holders(self) -> dict[int, str]:
        """GPU index → the service holding it (running, stuck, or survived by its group)."""
        holders: dict[int, str] = {}
        for name, run in self._runs.items():
            if run.state.holds_gpus():
                for index in run.state.gpus:
                    holders[index] = name
        return holders

    def _poll(self, name: str) -> ServiceState:
        """Reap the current incarnation of ``name``; returns the (live) state object."""
        return self._reap(self._runs[name])

    def _reap(self, run: _Run) -> ServiceState:
        """Reap an exited child, file its exit, chase its group; returns the (live) state object.

        When the direct child is gone but its process group is not, the group gets SIGTERM
        (unless a stop already sent it), ``group_alive`` is set and the GPUs stay booked. Each
        later poll re-probes the group, escalates to SIGKILL after ``ORPHAN_KILL_GRACE_S`` and
        clears ``group_alive`` once the group is empty.
        """
        state = run.state
        proc = run.proc
        if proc is not None and not run.finalized:
            code = proc.poll()
            if code is None:
                return state
            state.exit_code = code
            state.ended_at = _now()
            if state.stopped_by_request:
                state.state = "stopped"
            elif code == 0:
                state.state = "exited"
            else:
                state.state = "failed"
            run.proc = None
            run.finalized = True
            log.info("%s pid=%s exited with %d: %s", state.name, state.pid, code, state.state)
            if state.pid is not None and self._group_alive(state.pid):
                state.group_alive = True
                if run.group_term_at is None:
                    self._killpg(state.pid, signal.SIGTERM)
                    run.group_term_at = time.monotonic()
                log.warning(
                    "%s pid=%d exited but its process group is still alive; "
                    "GPUs %s stay booked until it is gone",
                    state.name,
                    state.pid,
                    state.gpus,
                )
        if state.group_alive and state.pid is not None:
            self._reclaim_group(run)
        terminal = (state.state, state.exit_code, state.group_alive)
        if (
            run.finalized
            and run.recorded_terminal != terminal
            and self._record_training_state(state)
        ):
            run.recorded_terminal = terminal
        return state

    def _record_training_state(self, state: ServiceState) -> bool:
        try:
            if (
                state.name == "pull-dataset"
                and state.state in {"failed", "stopped", "exited"}
                and not state.group_alive
            ):
                local_name = (state.params or {}).get("local_name")
                if local_name:
                    release_stage(self.settings.paths, local_name)
            write_run_state(self.settings.paths, state)
            return True
        except (OSError, AgentError):
            log.exception(
                "Could not record completion evidence for %s; its dataset stays protected",
                state.name,
            )
            return False

    def _reclaim_group(self, run: _Run) -> None:
        state = run.state
        pgid = state.pid
        assert pgid is not None
        if not self._group_alive(pgid):
            state.group_alive = False
            log.info("%s: process group %d is gone; GPUs %s released", state.name, pgid, state.gpus)
            return
        term_at = run.group_term_at
        if not run.group_killed and (
            term_at is None or time.monotonic() - term_at >= ORPHAN_KILL_GRACE_S
        ):
            log.warning(
                "%s: orphaned process group %d ignored SIGTERM for %.0f s; sending SIGKILL",
                state.name,
                pgid,
                ORPHAN_KILL_GRACE_S,
            )
            self._killpg(pgid, signal.SIGKILL)
            run.group_killed = True

    def _mark_stuck(self, run: _Run) -> None:
        """SIGKILL did not end the child within ``SIGKILL_WAIT_S``: file it, keep its GPUs booked."""
        state = run.state
        if run.proc is None or run.finalized or run.proc.poll() is not None:
            return  # it died after all; the next _reap files it
        if state.state != "stuck":
            state.state = "stuck"
            log.error(
                "%s pid=%s is still present %.0f s after SIGKILL (uninterruptible sleep?); "
                "GPUs %s stay booked until it disappears",
                state.name,
                state.pid,
                SIGKILL_WAIT_S,
                state.gpus,
            )


__all__ = [
    "CHILD_ENV_DROP",
    "CHILD_ENV_DROP_FOR",
    "DEFAULT_STOP_TIMEOUT_S",
    "ORPHAN_KILL_GRACE_S",
    "SHUTDOWN_GRACE_S",
    "SIGKILL_WAIT_S",
    "LogTail",
    "RunLog",
    "ServiceState",
    "State",
    "Supervisor",
    "child_env",
    "tail_file",
]
