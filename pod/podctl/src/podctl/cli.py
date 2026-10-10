"""``podctl`` command line (POD-SPEC §8): one subcommand per agent endpoint plus two sugars.

Exit codes: 0 success, 1 agent error (the envelope is printed to stderr; also a ``--wait`` that
ends in state ``failed``), 2 usage, 3 connection failure (transport error or a gateway answering
for a pod that is not up yet), 130 interrupted.

Output: a compact table or key/value listing by default; ``--json`` prints the raw response,
one JSON document per line. ``--follow`` and ``--wait`` poll every ``POLL_INTERVAL_S`` seconds
through the module-level ``sleep``; ``make_client`` builds the HTTP client. Both are
module-level names so tests can replace them.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from collections.abc import Callable, Iterable, Sequence
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import httpx

from . import __version__
from .client import AgentAPIError, AgentClient, AgentUnreachable

EXIT_OK, EXIT_AGENT_ERROR, EXIT_USAGE, EXIT_CONNECTION = 0, 1, 2, 3
EXIT_INTERRUPTED = 130
POLL_INTERVAL_S = 2.0
TRAINERS: tuple[str, ...] = ("aitoolkit", "ltx")
TAIL_RANGE = (1, 5000)
STOP_TIMEOUT_RANGE = (1.0, 90.0)

# Test seams: tests swap in a MockTransport-backed client and a recording no-op sleep.
make_client: Callable[[str, str], AgentClient] = AgentClient
sleep: Callable[[float], None] = time.sleep


class UsageError(Exception):
    """A client-side input problem; exit 2 without talking to the agent."""


# --- argument parsing -------------------------------------------------------------------


def parse_gpus(text: str) -> list[int]:
    """``"0,1"`` -> ``[0, 1]``; empty -> ``[]``. Rejects negatives, junk and duplicates."""
    text = text.strip()
    if not text:
        return []
    gpus: list[int] = []
    for item in text.split(","):
        item = item.strip()
        if not item.isdigit():
            raise argparse.ArgumentTypeError(f"GPU index {item!r} is not a non-negative integer")
        index = int(item)
        if index in gpus:
            raise argparse.ArgumentTypeError(f"GPU index {index} given twice")
        gpus.append(index)
    return gpus


def _add_params_args(parser: argparse.ArgumentParser, *, what: str = "params") -> None:
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--params", metavar="JSON", help=f"{what} as a JSON object")
    group.add_argument(
        "--params-file", metavar="FILE", type=Path, help=f"{what} from a JSON file ('-' = stdin)"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="podctl",
        description="concept-captioner pod agent client (POD-SPEC §8)",
        epilog=(
            "exit codes: 0 ok, 1 agent error, 2 usage, 3 cannot reach the agent. "
            "--wait and --follow poll every 2 s."
        ),
    )
    parser.add_argument(
        "--url", default=os.environ.get("PODCTL_URL"), help="agent base URL (env PODCTL_URL)"
    )
    parser.add_argument(
        "--token",
        default=os.environ.get("PODAGENT_TOKEN"),
        help="bearer token (env PODAGENT_TOKEN)",
    )
    parser.add_argument(
        "--json", action="store_true", help="print raw JSON responses, one document per line"
    )
    parser.add_argument("--version", action="version", version=f"podctl {__version__}")
    sub = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")

    sub.add_parser("health", help="GET /health")
    sub.add_parser("gpus", help="GET /gpus")

    plan = sub.add_parser("plan", help="POST /plan: the GPU assignment for caption and/or train")
    plan.add_argument("--caption", action="store_true", help="plan a captioning (vLLM) service")
    plan.add_argument("--train", action="store_true", help="plan a trainer service")
    plan.add_argument(
        "--gpu-count", type=int, default=None, help="plan for N GPUs instead of the inventory"
    )

    sub.add_parser("services", help="GET /services")

    status = sub.add_parser("status", help="GET /services/NAME")
    status.add_argument("name")

    start = sub.add_parser("start", help="POST /services/NAME/start")
    start.add_argument("name")
    start.add_argument(
        "--gpus", type=parse_gpus, default=[], help="comma-separated GPU indices, e.g. 0,1"
    )
    _add_params_args(start)
    start.add_argument(
        "--wait",
        action="store_true",
        help="poll status every 2 s until the service is no longer running",
    )

    stop = sub.add_parser("stop", help="POST /services/NAME/stop")
    stop.add_argument("name")
    stop.add_argument(
        "--timeout",
        type=float,
        default=30.0,
        help="seconds between SIGTERM and SIGKILL (1-90, default 30; the agent caps it under the proxy's 100 s)",
    )

    logs = sub.add_parser("logs", help="GET /services/NAME/logs")
    logs.add_argument("name")
    logs.add_argument("--tail", type=int, default=200, help="lines to fetch (1-5000, default 200)")
    logs.add_argument(
        "--follow",
        "-f",
        action="store_true",
        help="re-poll every 2 s and print new lines until the service stops",
    )

    events = sub.add_parser("events", help="GET /runs/RUN_ID/events")
    events.add_argument("run_id")

    train = sub.add_parser("train", help="start trainer-<TRAINER> with a run config file as params")
    train.add_argument("trainer", choices=TRAINERS)
    train.add_argument(
        "--config", required=True, type=Path, help="run.json (POD-SPEC §4.1); '-' = stdin"
    )
    train.add_argument(
        "--gpus", type=parse_gpus, required=True, help="comma-separated GPU indices, e.g. 1,2"
    )
    train.add_argument(
        "--wait", action="store_true", help="poll status every 2 s until the run ends"
    )

    caption_up = sub.add_parser("caption-up", help="start vllm serving MODEL")
    caption_up.add_argument("model", help="Hub id or a path under /workspace/models/")
    caption_up.add_argument(
        "--gpus", type=parse_gpus, default=[0], help="GPU index for vLLM (default 0)"
    )
    _add_params_args(caption_up, what="extra vLLM params (merged under 'model')")
    return parser


# --- input helpers ----------------------------------------------------------------------


def _read_text(path: Path, *, source: str) -> str:
    if str(path) == "-":
        return sys.stdin.read()
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise UsageError(f"{source}: cannot read {path}: {error.strerror or error}") from error


def load_json_object(text: str, *, source: str) -> dict[str, Any]:
    try:
        value = json.loads(text)
    except ValueError as error:
        raise UsageError(f"{source}: invalid JSON: {error}") from error
    if not isinstance(value, dict):
        raise UsageError(f"{source}: expected a JSON object, got {type(value).__name__}")
    return value


def load_params(args: argparse.Namespace) -> dict[str, Any]:
    """``--params`` / ``--params-file`` -> dict; ``{}`` when neither is given."""
    if args.params is not None:
        return load_json_object(args.params, source="--params")
    if args.params_file is not None:
        text = _read_text(args.params_file, source="--params-file")
        return load_json_object(text, source=f"--params-file {args.params_file}")
    return {}


def _check_range(name: str, value: float, low: float, high: float) -> None:
    if not low <= value <= high:
        raise UsageError(f"{name} must be between {low:g} and {high:g}, got {value:g}")


# --- formatting -------------------------------------------------------------------------


def fmt_scalar(value: Any) -> str:
    """One cell: ``None``/empty -> ``-``, bools lowercase, int lists comma-joined, rest JSON."""
    if value is None:
        return "-"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return value or "-"
    if isinstance(value, float):
        return f"{value:g}"
    if isinstance(value, list):
        if not value:
            return "-"
        if all(isinstance(v, int) and not isinstance(v, bool) for v in value):
            return ",".join(str(v) for v in value)
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, dict):
        return json.dumps(value, ensure_ascii=False) if value else "-"
    return str(value)


def flatten(mapping: dict[str, Any], prefix: str = "") -> Iterable[tuple[str, Any]]:
    """Nested dicts as ``a.b`` keys, in the agent's order."""
    for key, value in mapping.items():
        name = f"{prefix}{key}"
        if isinstance(value, dict) and value:
            yield from flatten(value, f"{name}.")
        else:
            yield name, value


def fmt_pairs(pairs: Iterable[tuple[str, Any]]) -> str:
    rows = [(key, fmt_scalar(value)) for key, value in pairs]
    if not rows:
        return ""
    width = max(len(key) for key, _ in rows)
    return "\n".join(f"{key.ljust(width)}  {value}" for key, value in rows)


def fmt_kv(mapping: dict[str, Any]) -> str:
    return fmt_pairs(flatten(mapping))


def fmt_table(header: Sequence[str], rows: Iterable[Sequence[Any]]) -> str:
    cells = [[fmt_scalar(cell) for cell in row] for row in rows]
    widths = [max([len(name), *(len(row[i]) for row in cells)]) for i, name in enumerate(header)]
    lines = [_table_line(header, widths), *(_table_line(row, widths) for row in cells)]
    return "\n".join(lines)


def _table_line(cells: Sequence[str], widths: Sequence[int]) -> str:
    return "  ".join(cell.ljust(width) for cell, width in zip(cells, widths, strict=True)).rstrip()


def fmt_time(epoch: Any) -> str:
    try:
        return datetime.fromtimestamp(float(epoch), tz=UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError, OverflowError, OSError):
        return fmt_scalar(epoch)


def fmt_gpus(payload: dict[str, Any]) -> str:
    gpus = payload.get("gpus") or []
    if not gpus:
        return "no GPUs"
    rows = [
        [
            gpu.get("index"),
            gpu.get("name"),
            f"{fmt_scalar(gpu.get('memory_used_mib'))}/{fmt_scalar(gpu.get('memory_total_mib'))}",
            gpu.get("in_use_by"),
        ]
        for gpu in gpus
    ]
    return fmt_table(("IDX", "NAME", "MEM_MIB", "IN_USE_BY"), rows)


def fmt_plan(payload: dict[str, Any]) -> str:
    pairs: list[tuple[str, Any]] = [
        ("gpu_count", payload.get("gpu_count")),
        ("mode", payload.get("mode")),
    ]
    for key in ("caption", "train"):
        assignment = payload.get(key)
        pairs.append(
            (
                key,
                f"{assignment.get('service')} on {fmt_scalar(assignment.get('gpus'))}"
                if isinstance(assignment, dict)
                else None,
            )
        )
    order = " -> ".join(
        f"{step.get('action')} {step.get('service')}" for step in payload.get("order") or []
    )
    pairs.append(("order", order or None))
    return fmt_pairs(pairs)


SERVICE_COLUMNS = ("NAME", "STATE", "PID", "GPUS", "PORT", "RUN_ID", "STARTED", "EXIT")


def _service_row(state: dict[str, Any]) -> list[Any]:
    return [
        state.get("name"),
        state.get("state"),
        state.get("pid"),
        state.get("gpus"),
        state.get("port"),
        state.get("run_id"),
        state.get("started_at"),
        state.get("exit_code"),
    ]


def fmt_services(payload: dict[str, Any]) -> str:
    services = payload.get("services") or []
    if not services:
        return "no services"
    return fmt_table(SERVICE_COLUMNS, (_service_row(state) for state in services))


def fmt_events(payload: dict[str, Any]) -> str:
    header = fmt_pairs(
        (key, payload.get(key)) for key in ("run_id", "logdir", "files", "last_step", "reader")
    )
    scalars = payload.get("scalars") or {}
    if not scalars:
        return f"{header}\n\nno scalars yet"
    rows = [
        [
            tag,
            point.get("step"),
            point.get("value"),
            point.get("count"),
            fmt_time(point.get("wall_time")),
        ]
        for tag, point in sorted(scalars.items())
    ]
    return f"{header}\n\n{fmt_table(('TAG', 'STEP', 'VALUE', 'COUNT', 'WALL_TIME'), rows)}"


def fmt_logs(payload: dict[str, Any]) -> str:
    return "\n".join(payload.get("lines") or [])


# --- output -----------------------------------------------------------------------------


def emit(value: Any, *, raw: bool, render: Callable[[Any], str] = fmt_kv) -> None:
    text = json.dumps(value, ensure_ascii=False) if raw else render(value)
    if text:
        print(text)


def note(message: str) -> None:
    print(f"podctl: {message}", file=sys.stderr)


def print_error(error: AgentAPIError, *, raw: bool) -> None:
    if raw:
        print(json.dumps(error.envelope, ensure_ascii=False), file=sys.stderr)
        return
    print(f"podctl: error {error.code} ({error.status}): {error.message}", file=sys.stderr)
    detail = error.detail
    if isinstance(detail, list) and detail and all(_is_pydantic_error(item) for item in detail):
        for item in detail:
            loc = ".".join(str(part) for part in item.get("loc") or ()) or "params"
            print(f"  - {loc}: {item.get('msg')}", file=sys.stderr)
    elif detail is not None:
        print(f"  detail: {json.dumps(detail, ensure_ascii=False)}", file=sys.stderr)


def _is_pydantic_error(item: Any) -> bool:
    return isinstance(item, dict) and "msg" in item


# --- polling loops ----------------------------------------------------------------------


def wait_until_not_running(client: AgentClient, name: str) -> dict[str, Any]:
    """Poll ``GET /services/NAME`` until ``state != running``; return the final state."""
    while True:
        state = client.service(name)
        if state.get("state") != "running":
            return state
        sleep(POLL_INTERVAL_S)


def overlap(previous: Sequence[str], current: Sequence[str]) -> int:
    """How many leading lines of ``current`` were already at the end of ``previous``."""
    for size in range(min(len(previous), len(current)), 0, -1):
        if list(previous[-size:]) == list(current[:size]):
            return size
    return 0


def follow_logs(client: AgentClient, name: str, tail: int, *, raw: bool) -> None:
    """Tail-and-poll until the service is not running; the state is read before each fetch so
    the final lines are never missed."""
    previous: list[str] = []
    first = True
    while True:
        running = client.service(name).get("state") == "running"
        payload = client.logs(name, tail)
        lines: list[str] = list(payload.get("lines") or [])
        if first:
            new = lines
        else:
            skip = overlap(previous, lines)
            new = lines[skip:]
            if skip == 0 and previous and lines and payload.get("truncated"):
                note(f"log window moved by more than {tail} lines; some lines were not shown")
        if new:
            emit({**payload, "lines": new}, raw=raw, render=fmt_logs)
        previous, first = lines, False
        if not running:
            return
        sleep(POLL_INTERVAL_S)


# --- commands ---------------------------------------------------------------------------


def _start(
    client: AgentClient,
    name: str,
    gpus: list[int],
    params: dict[str, Any],
    *,
    wait: bool,
    raw: bool,
) -> int:
    state = client.start(name, gpus, params)
    emit(state, raw=raw)
    if not wait:
        return EXIT_OK
    note(f"waiting for {name} to finish (polling every {POLL_INTERVAL_S:g} s)")
    final = wait_until_not_running(client, name)
    emit(final, raw=raw)
    if final.get("state") == "failed":
        note(f"{name} failed with exit code {fmt_scalar(final.get('exit_code'))}")
        return EXIT_AGENT_ERROR
    return EXIT_OK


def cmd_health(client: AgentClient, args: argparse.Namespace) -> int:
    emit(client.health(), raw=args.json)
    return EXIT_OK


def cmd_gpus(client: AgentClient, args: argparse.Namespace) -> int:
    emit(client.gpus(), raw=args.json, render=fmt_gpus)
    return EXIT_OK


def cmd_plan(client: AgentClient, args: argparse.Namespace) -> int:
    if not (args.caption or args.train):
        raise UsageError("plan needs --caption and/or --train")
    payload = client.plan(caption=args.caption, train=args.train, gpu_count=args.gpu_count)
    emit(payload, raw=args.json, render=fmt_plan)
    return EXIT_OK


def cmd_services(client: AgentClient, args: argparse.Namespace) -> int:
    emit(client.services(), raw=args.json, render=fmt_services)
    return EXIT_OK


def cmd_status(client: AgentClient, args: argparse.Namespace) -> int:
    emit(client.service(args.name), raw=args.json)
    return EXIT_OK


def cmd_start(client: AgentClient, args: argparse.Namespace) -> int:
    params = load_params(args)
    return _start(client, args.name, args.gpus, params, wait=args.wait, raw=args.json)


def cmd_stop(client: AgentClient, args: argparse.Namespace) -> int:
    _check_range("--timeout", args.timeout, *STOP_TIMEOUT_RANGE)
    emit(client.stop(args.name, args.timeout), raw=args.json)
    return EXIT_OK


def cmd_logs(client: AgentClient, args: argparse.Namespace) -> int:
    _check_range("--tail", args.tail, *TAIL_RANGE)
    if args.follow:
        follow_logs(client, args.name, args.tail, raw=args.json)
    else:
        emit(client.logs(args.name, args.tail), raw=args.json, render=fmt_logs)
    return EXIT_OK


def cmd_events(client: AgentClient, args: argparse.Namespace) -> int:
    emit(client.events(args.run_id), raw=args.json, render=fmt_events)
    return EXIT_OK


def cmd_train(client: AgentClient, args: argparse.Namespace) -> int:
    text = _read_text(args.config, source="--config")
    config = load_json_object(text, source=f"--config {args.config}")
    return _start(
        client, f"trainer-{args.trainer}", args.gpus, config, wait=args.wait, raw=args.json
    )


def cmd_caption_up(client: AgentClient, args: argparse.Namespace) -> int:
    params = {**load_params(args), "model": args.model}
    return _start(client, "vllm", args.gpus, params, wait=False, raw=args.json)


COMMANDS: dict[str, Callable[[AgentClient, argparse.Namespace], int]] = {
    "health": cmd_health,
    "gpus": cmd_gpus,
    "plan": cmd_plan,
    "services": cmd_services,
    "status": cmd_status,
    "start": cmd_start,
    "stop": cmd_stop,
    "logs": cmd_logs,
    "events": cmd_events,
    "train": cmd_train,
    "caption-up": cmd_caption_up,
}


# --- entry point ------------------------------------------------------------------------


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as exit_:  # argparse already printed usage (2) or --help/--version (0)
        return exit_.code if isinstance(exit_.code, int) else EXIT_USAGE
    if not args.url or not args.token:
        parser.print_usage(sys.stderr)
        note("--url/PODCTL_URL and --token/PODAGENT_TOKEN are required")
        return EXIT_USAGE
    try:
        with make_client(args.url, args.token) as client:
            return COMMANDS[args.command](client, args)
    except UsageError as error:
        note(f"error: {error}")
        return EXIT_USAGE
    except AgentAPIError as error:
        print_error(error, raw=args.json)
        return EXIT_AGENT_ERROR
    except AgentUnreachable as error:
        note(f"cannot reach the agent at {args.url}: {error}")
        return EXIT_CONNECTION
    except httpx.HTTPError as error:
        note(f"cannot reach {args.url}: {error.__class__.__name__}: {error}")
        return EXIT_CONNECTION
    except KeyboardInterrupt:
        print(file=sys.stderr)
        return EXIT_INTERRUPTED


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
