"""Stand-in child process for fake mode: ``python -m podagent.fakeservice <name> <params-json>``.

The supervisor runs this instead of the real argv whenever ``PODAGENT_FAKE_GPUS`` is set
(POD-SPEC §3). It is deliberately stdlib-only so it starts fast and never depends on what the
agent venv happens to hold. What it does:

- prints its argv, cwd, ``CUDA_VISIBLE_DEVICES``, ``CUDA_DEVICE_ORDER``, ``HF_HOME`` and the
  *presence* (never the value) of ``HF_TOKEN`` / ``VLLM_API_KEY`` / ``PODAGENT_TOKEN`` to
  stdout, which the supervisor has pointed at the service's log file;
- ``vllm`` and ``tensorboard``: binds ``params.port`` with a one-line HTTP responder
  (``/v1/models`` answers vLLM-shaped JSON so a readiness poll works) and sleeps until
  SIGTERM, then exits 0;
- ``pull-dataset`` and ``push-lora``: exit 0 after ``PODAGENT_FAKE_TRANSFER_S`` seconds
  (default 2);
- trainers: sleep until SIGTERM, exit 0.

Failure switches, so the supervisor's exit-code handling can be tested through real params
(every catalog model has ``extra="forbid"``, so a bare ``"fail": true`` only passes when a
caller bypasses the catalog):

- ``"fail": true`` at the top level, ``extra: {"fail": true}`` (trainers) or ``"--fail"`` in
  ``extra_args`` (vllm) → exit 3 immediately;
- ``"ignore_sigterm": true`` / ``extra: {"ignore_sigterm": true}`` / ``"--ignore-sigterm"`` →
  SIGTERM is ignored, so only the supervisor's SIGKILL escalation ends the process;
- ``"orphan": true`` / ``extra: {"orphan": true}`` / ``"--orphan"`` → spawns a grandchild in
  the same process group (sleeping; it ignores SIGTERM too when ``ignore_sigterm`` is set),
  then exits 3 at once, leaving the grandchild behind the way a crashed launch wrapper leaves
  its trainer, or a dead vLLM API server its engine workers.

Bind address: ``PODAGENT_FAKE_HOST`` (default ``127.0.0.1``). Only something on the same host
ever talks to a fake service; in a container that loopback is the container's own, so
``compose.fake.yaml`` sets ``0.0.0.0`` to make the responders reachable through the ports it
publishes.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

EXIT_USAGE = 2
EXIT_REQUESTED_FAILURE = 3
EXIT_BIND_FAILED = 4
DEFAULT_TRANSFER_S = 2.0
PORTED_SERVICES = frozenset({"vllm", "tensorboard"})
TRANSFER_SERVICES = frozenset({"pull-dataset", "push-lora", "cleanup-datasets"})
PRESENCE_ONLY_ENV = ("HF_TOKEN", "VLLM_API_KEY", "PODAGENT_TOKEN")
ORPHAN_SLEEP_S = 600
# The grandchild ``--orphan`` leaves behind: stdlib only, prints its pid, sleeps.
# argv: [ignore_sigterm "0"|"1", ready-pipe fd]. It writes one byte to the pipe once its signal
# disposition is in place, so the parent cannot exit (and the supervisor cannot SIGTERM the group)
# before the orphan is really ignoring SIGTERM.
_ORPHAN_PROGRAM = """
import os, signal, sys, time
if sys.argv[1] == "1":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
print(f"fakeservice: orphan pid={os.getpid()} pgid={os.getpgid(0)}", flush=True)
ready = int(sys.argv[2])
os.write(ready, b"x")
os.close(ready)
time.sleep({sleep})
""".replace("{sleep}", str(ORPHAN_SLEEP_S))


def _say(message: str) -> None:
    print(f"fakeservice: {message}", flush=True)


def _flag(params: dict[str, Any], key: str) -> bool:
    """A boolean switch given as ``key``, ``extra.key`` or ``--key-with-dashes`` in extra_args."""
    if params.get(key) is True:
        return True
    extra = params.get("extra")
    if isinstance(extra, dict) and extra.get(key) is True:
        return True
    extra_args = params.get("extra_args")
    flag = "--" + key.replace("_", "-")
    return isinstance(extra_args, list) and flag in extra_args


class _Handler(BaseHTTPRequestHandler):
    service = "fake"
    model = "fake-model"

    def do_GET(self) -> None:
        if self.service == "vllm" and self.path.startswith("/v1/models"):
            body = json.dumps(
                {"object": "list", "data": [{"id": self.model, "object": "model"}]}
            ).encode()
            content_type = "application/json"
        else:
            body = f"fakeservice {self.service} ok\n".encode()
            content_type = "text/plain; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: Any) -> None:
        _say(f"http {self.address_string()} {format % args}")


def _serve(name: str, params: dict[str, Any], stop: threading.Event) -> ThreadingHTTPServer | None:
    """Bind ``params.port`` and serve in a daemon thread; ``None`` and ``stop`` set on failure."""
    host = (
        "127.0.0.1" if name == "tensorboard" else os.environ.get("PODAGENT_FAKE_HOST", "127.0.0.1")
    )
    port = int(params.get("port") or 0)
    handler = type("Handler", (_Handler,), {"service": name, "model": params.get("model", "fake")})
    try:
        server = ThreadingHTTPServer((host, port), handler)
    except OSError as error:
        _say(f"could not bind {host}:{port}: {error}")
        stop.set()
        return None
    server.daemon_threads = True
    # A short poll interval so ``server.shutdown()`` returns promptly on SIGTERM.
    threading.Thread(
        target=server.serve_forever, kwargs={"poll_interval": 0.05}, name="http", daemon=True
    ).start()
    _say(f"listening on {host}:{server.server_address[1]}")
    return server


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 2:
        print("usage: python -m podagent.fakeservice <name> <params-json>", file=sys.stderr)
        return EXIT_USAGE
    name, raw = args
    try:
        params = json.loads(raw)
    except json.JSONDecodeError as error:
        print(f"fakeservice: params are not JSON: {error}", file=sys.stderr)
        return EXIT_USAGE
    if not isinstance(params, dict):
        print("fakeservice: params must be a JSON object", file=sys.stderr)
        return EXIT_USAGE

    _say(f"name={name}")
    _say(f"pid={os.getpid()}")
    _say(f"argv={sys.argv!r}")
    _say(f"cwd={os.getcwd()}")
    _say(f"CUDA_VISIBLE_DEVICES={os.environ.get('CUDA_VISIBLE_DEVICES')!r}")
    _say(f"CUDA_DEVICE_ORDER={os.environ.get('CUDA_DEVICE_ORDER')!r}")
    _say(f"HF_HOME={os.environ.get('HF_HOME')!r}")
    for key in PRESENCE_ONLY_ENV:
        _say(f"{key}={'set' if os.environ.get(key) else 'unset'}")
    _say(f"params={json.dumps(params, sort_keys=True)}")

    if _flag(params, "fail"):
        _say(f"failing as requested, exit {EXIT_REQUESTED_FAILURE}")
        return EXIT_REQUESTED_FAILURE

    ignore_sigterm = _flag(params, "ignore_sigterm")

    if _flag(params, "orphan"):
        # Same session and process group (no start_new_session), stdout inherited: the log.
        read_fd, write_fd = os.pipe()
        subprocess.Popen(
            [sys.executable, "-c", _ORPHAN_PROGRAM, "1" if ignore_sigterm else "0", str(write_fd)],
            stdin=subprocess.DEVNULL,
            pass_fds=(write_fd,),
        )
        os.close(write_fd)
        os.read(read_fd, 1)  # the orphan is set up
        os.close(read_fd)
        _say(f"leaving an orphan behind and failing, exit {EXIT_REQUESTED_FAILURE}")
        return EXIT_REQUESTED_FAILURE

    stop = threading.Event()

    def on_signal(signum: int, _frame: Any) -> None:
        if ignore_sigterm and signum == signal.SIGTERM:
            _say("ignoring SIGTERM as requested")
            return
        _say(f"received signal {signum}; exiting 0")
        stop.set()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    server: ThreadingHTTPServer | None = None
    if name in PORTED_SERVICES:
        server = _serve(name, params, stop)
        if server is None:
            return EXIT_BIND_FAILED

    if name in TRANSFER_SERVICES:
        duration = float(os.environ.get("PODAGENT_FAKE_TRANSFER_S", DEFAULT_TRANSFER_S))
        _say(f"pretending to transfer for {duration:g} s")
        deadline = time.monotonic() + duration
        while not stop.is_set() and time.monotonic() < deadline:
            stop.wait(min(0.1, max(0.0, deadline - time.monotonic())))
        if not stop.is_set():
            _say("transfer complete, exit 0")
        return 0

    _say("sleeping until SIGTERM")
    while not stop.wait(0.5):
        pass
    if server is not None:
        server.shutdown()
        server.server_close()
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
