"""Thin HTTP client over the agent API (POD-SPEC §2).

One method per endpoint, each returning the decoded JSON body. Agent errors (any status >= 400)
become ``AgentAPIError`` carrying the error envelope; a gateway answer that is not the agent's
envelope (the RunPod proxy's 502/503/504 while the pod is booting) becomes
``AgentUnreachable``; transport failures stay ``httpx`` exceptions. ``podctl.cli`` maps these
to exit codes 1 / 3 / 3.
"""

from __future__ import annotations

from typing import Any
from urllib.parse import quote

import httpx

GATEWAY_STATUSES: frozenset[int] = frozenset({502, 503, 504})
_MESSAGE_LIMIT = 300


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


class AgentUnreachable(Exception):
    """A gateway in front of the agent answered instead of the agent."""

    def __init__(self, status: int, text: str) -> None:
        super().__init__(f"gateway returned {status}: {text}")
        self.status = status


def _is_envelope(value: Any) -> bool:
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

    def _call(self, method: str, path: str, **kwargs: Any) -> Any:
        response = self._http.request(method, path, **kwargs)
        if response.status_code >= 400:
            envelope = _envelope_of(response)
            if response.status_code in GATEWAY_STATUSES and envelope["error"]["code"] == "http":
                raise AgentUnreachable(response.status_code, envelope["error"]["message"])
            raise AgentAPIError(response.status_code, envelope)
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
