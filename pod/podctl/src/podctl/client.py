"""Thin HTTP client over the agent API (POD-SPEC §2).

One method per endpoint, each returning the decoded JSON body (the run-file download streams
to disk and verifies size and SHA-256; TensorBoard returns the raw response). Agent errors (any status >= 400)
become ``AgentAPIError`` carrying the error envelope; a gateway answer that is not the agent's
envelope (the RunPod proxy's 502/503/504 or Cloudflare 520-526) becomes
``AgentUnreachable``; transport failures stay ``httpx`` exceptions. ``podctl.cli`` maps these
to exit codes 1 / 3 / 3.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
from typing import Any, TypeGuard
from urllib.parse import quote

import httpx

GATEWAY_STATUSES: frozenset[int] = frozenset({502, 503, 504, *range(520, 527)})
_MESSAGE_LIMIT = 300
_CHUNK = 1 << 20
TENSORBOARD_PREFIX = "/tensorboard"


class AgentAPIError(Exception):
    """The agent answered with its error envelope (POD-SPEC §2.2)."""

    def __init__(self, status: int, envelope: dict[str, Any]) -> None:
        error = envelope.get("error", {})
        super().__init__(f"{status} {error.get('code')}: {error.get('message')}")
        self.status = status
        self.envelope = envelope

    @property
    def code(self) -> str:
        return str(self.envelope.get("error", {}).get("code"))

    @property
    def message(self) -> str:
        return str(self.envelope.get("error", {}).get("message"))

    @property
    def detail(self) -> Any:
        return self.envelope.get("error", {}).get("detail")


class TransferMismatch(Exception):
    """A downloaded run file does not match the size and SHA-256 the agent listed."""

    def __init__(self, path: str, size: int, got_size: int, sha256: str, got_sha256: str) -> None:
        super().__init__(
            f"{path}: expected {size} bytes sha256 {sha256}, got {got_size} bytes sha256 "
            f"{got_sha256}; nothing was kept"
        )
        self.path = path


class AgentUnreachable(Exception):
    """A gateway in front of the agent answered instead of the agent."""

    def __init__(self, status: int, text: str) -> None:
        super().__init__(f"gateway returned {status}: {text}")
        self.status = status


def _is_envelope(value: Any) -> TypeGuard[dict[str, Any]]:
    return (
        isinstance(value, dict)
        and isinstance(value.get("error"), dict)
        and "code" in value["error"]
        and "message" in value["error"]
    )


def _envelope_of(response: httpx.Response) -> dict[str, Any]:
    """The agent's envelope, or a synthetic ``http`` one for any other error body."""
    try:
        parsed: Any = response.json()
    except ValueError:
        parsed = None
    if _is_envelope(parsed):
        return parsed
    text = response.text.strip()
    message = text[:_MESSAGE_LIMIT] or response.reason_phrase or f"HTTP {response.status_code}"
    return {
        "error": {
            "code": "http",
            "message": message,
            "detail": parsed if parsed is not None else None,
        }
    }


class AgentClient:
    """Synchronous client; ``transport`` is the test seam (``httpx.MockTransport``)."""

    def __init__(
        self,
        url: str,
        token: str,
        *,
        transport: httpx.BaseTransport | None = None,
        timeout: float = 30.0,
    ) -> None:
        self.url = url.rstrip("/")
        self._http = httpx.Client(
            base_url=self.url,
            headers={"Authorization": f"Bearer {token}"},
            timeout=httpx.Timeout(timeout, connect=10.0),
            transport=transport,
        )

    def close(self) -> None:
        self._http.close()

    def __enter__(self) -> AgentClient:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    @staticmethod
    def _raise_for_status(response: httpx.Response) -> None:
        if response.status_code >= 400:
            envelope = _envelope_of(response)
            if response.status_code in GATEWAY_STATUSES and envelope["error"]["code"] == "http":
                raise AgentUnreachable(response.status_code, envelope["error"]["message"])
            raise AgentAPIError(response.status_code, envelope)

    def _call(self, method: str, path: str, **kwargs: Any) -> Any:
        response = self._http.request(method, path, **kwargs)
        self._raise_for_status(response)
        try:
            return response.json()
        except ValueError as error:
            raise AgentAPIError(
                response.status_code,
                {
                    "error": {
                        "code": "invalid_response",
                        "message": f"agent returned a non-JSON body: {error}",
                        "detail": response.text[:_MESSAGE_LIMIT],
                    }
                },
            ) from error

    @staticmethod
    def _segment(value: str) -> str:
        """One path segment; anything odd is sent escaped and judged by the agent."""
        return quote(value, safe="")

    # --- endpoints (POD-SPEC §2.3 to §2.7) ----------------------------------------------

    def health(self) -> dict[str, Any]:
        return self._call("GET", "/health")

    def gpus(self) -> dict[str, Any]:
        return self._call("GET", "/gpus")

    def plan(self, *, caption: bool, train: bool, gpu_count: int | None = None) -> dict[str, Any]:
        body: dict[str, Any] = {"caption": caption, "train": train}
        if gpu_count is not None:
            body["gpu_count"] = gpu_count
        return self._call("POST", "/plan", json=body)

    def services(self) -> dict[str, Any]:
        return self._call("GET", "/services")

    def service(self, name: str) -> dict[str, Any]:
        return self._call("GET", f"/services/{self._segment(name)}")

    def start(self, name: str, gpus: list[int], params: dict[str, Any]) -> dict[str, Any]:
        return self._call(
            "POST",
            f"/services/{self._segment(name)}/start",
            json={"gpus": list(gpus), "params": params},
        )

    def stop(self, name: str, timeout_s: float = 30.0) -> dict[str, Any]:
        return self._call(
            "POST", f"/services/{self._segment(name)}/stop", json={"timeout_s": timeout_s}
        )

    def logs(self, name: str, tail: int = 200) -> dict[str, Any]:
        return self._call("GET", f"/services/{self._segment(name)}/logs", params={"tail": tail})

    def events(self, run_id: str) -> dict[str, Any]:
        return self._call("GET", f"/runs/{self._segment(run_id)}/events")

    def run_files(self, run_id: str) -> dict[str, Any]:
        return self._call("GET", f"/runs/{self._segment(run_id)}/files")

    def download_run_file(
        self, run_id: str, path: str, dest: Path, *, sha256: str, size: int
    ) -> None:
        """Stream ``GET /runs/{id}/files/{path}`` to ``dest`` through ``dest.partial``; the
        file appears under its name only once its size and SHA-256 match the listing."""
        url = f"/runs/{self._segment(run_id)}/files/" + "/".join(
            self._segment(part) for part in path.split("/")
        )
        partial = dest.with_name(dest.name + ".partial")
        dest.parent.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256()
        written = 0
        with self._http.stream("GET", url) as response:
            if response.status_code >= 400:
                response.read()
                self._raise_for_status(response)
            with partial.open("wb") as handle:
                for chunk in response.iter_bytes(_CHUNK):
                    handle.write(chunk)
                    digest.update(chunk)
                    written += len(chunk)
        if written != size or digest.hexdigest() != sha256:
            partial.unlink(missing_ok=True)
            raise TransferMismatch(path, size, written, sha256, digest.hexdigest())
        os.replace(partial, dest)

    # --- TensorBoard (POD-SPEC §2.1): the session handshake and the proxied route -----------

    def tensorboard_session(self) -> dict[str, Any]:
        return self._call("POST", "/tensorboard-session")

    def tensorboard(
        self, path: str = "", *, session: dict[str, Any] | None = None
    ) -> httpx.Response:
        """``GET /tensorboard/<path>``. With ``session`` (from ``tensorboard_session``) the
        request carries only the session cookie, no bearer: what a browser sends."""
        url = TENSORBOARD_PREFIX + "/" + path.lstrip("/")
        if session is None:
            response = self._http.get(url)
        else:
            request = self._http.build_request(
                "GET", url, headers={"Cookie": f"{session['cookie']}={session['value']}"}
            )
            del request.headers["authorization"]
            response = self._http.send(request)
        self._raise_for_status(response)
        return response
