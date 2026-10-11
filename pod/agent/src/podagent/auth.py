"""Bearer-token check for every route, and the TensorBoard browser session (POD-SPEC §2.1).

The master credential is ``PODAGENT_TOKEN``: every route accepts it as ``Authorization: Bearer``.
A browser cannot attach that header to the scripts, stylesheets and XHRs TensorBoard's page
loads, so ``POST /tensorboard-session`` (bearer only) issues a second, narrower credential:

- it is derived, never the token itself: ``v1.<expires>.<HMAC-SHA256(key, purpose|expires)>``,
  keyed by 32 random bytes drawn once per agent process, so a leaked cookie cannot be turned
  back into the token and every session dies with the agent;
- it expires: ``TENSORBOARD_SESSION_TTL_S`` after issue, checked on every request;
- it is accepted only on ``/tensorboard`` and below. The handshake route sits outside that
  subtree, so a session can never mint another one, and no control route ever reads it.
"""

from __future__ import annotations

import hashlib
import hmac
import secrets
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass

from fastapi import Header, Request

from .errors import Unauthorized

TENSORBOARD_PREFIX = "/tensorboard"
TENSORBOARD_COOKIE = "podagent_tensorboard"
TENSORBOARD_SESSION_PATH = "/tensorboard-session"
TENSORBOARD_SESSION_TTL_S = 12 * 3600
_SESSION_VERSION = "v1"
_SESSION_PURPOSE = b"podagent tensorboard session"


@dataclass(frozen=True)
class TensorboardSession:
    """One issued TensorBoard credential: the cookie value and when it stops working."""

    value: str
    expires_at: int  # unix seconds
    max_age_s: int


def is_tensorboard_path(path: str) -> bool:
    return path == TENSORBOARD_PREFIX or path.startswith(TENSORBOARD_PREFIX + "/")


class Authenticator:
    """The agent's two credentials: the master bearer, and TensorBoard sessions derived from a
    per-process key. ``clock`` (unix seconds) is the test seam for expiry."""

    def __init__(
        self,
        token: str,
        *,
        session_key: bytes | None = None,
        ttl_s: int = TENSORBOARD_SESSION_TTL_S,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.token = token
        self._key = session_key if session_key is not None else secrets.token_bytes(32)
        self._ttl_s = ttl_s
        self._clock = clock

    def _mac(self, expires: str) -> str:
        message = (
            _SESSION_PURPOSE + b"\x00" + _SESSION_VERSION.encode() + b"\x00" + expires.encode()
        )
        return hmac.new(self._key, message, hashlib.sha256).hexdigest()

    def issue_tensorboard_session(self) -> TensorboardSession:
        expires = int(self._clock()) + self._ttl_s
        value = f"{_SESSION_VERSION}.{expires}.{self._mac(str(expires))}"
        return TensorboardSession(value=value, expires_at=expires, max_age_s=self._ttl_s)

    def check_tensorboard_session(self, value: str) -> None:
        """Raise ``Unauthorized`` unless ``value`` is an unexpired session this process issued."""
        version, _, rest = value.partition(".")
        expires, _, mac = rest.partition(".")
        if version != _SESSION_VERSION or not expires.isdigit() or not mac:
            raise Unauthorized("invalid TensorBoard session")
        if not hmac.compare_digest(mac.encode(), self._mac(expires).encode()):
            raise Unauthorized("invalid TensorBoard session")
        if int(expires) <= self._clock():
            raise Unauthorized("TensorBoard session expired; open a new one")

    def check(self, path: str, authorization: str | None, cookies: Mapping[str, str]) -> None:
        """The bearer everywhere; the session cookie only under ``/tensorboard``, never controls."""
        if authorization is None and is_tensorboard_path(path):
            cookie = cookies.get(TENSORBOARD_COOKIE)
            if cookie:
                self.check_tensorboard_session(cookie)
                return
        check_bearer(authorization, self.token)


def check_bearer(header_value: str | None, token: str) -> None:
    """Raise ``Unauthorized`` unless ``header_value`` is ``Bearer <token>`` (constant-time)."""
    if not header_value:
        raise Unauthorized("missing bearer token")
    scheme, _, presented = header_value.partition(" ")
    if scheme.lower() != "bearer" or not presented.strip():
        raise Unauthorized("malformed Authorization header")
    if not secrets.compare_digest(presented.strip().encode(), token.encode()):
        raise Unauthorized("invalid bearer token")


async def require_bearer(
    request: Request, authorization: str | None = Header(default=None)
) -> None:
    """FastAPI dependency: the app's ``Authenticator`` decides."""
    request.app.state.auth.check(request.url.path, authorization, request.cookies)
