"""Bearer-token check for every route (POD-SPEC §2.1)."""

from __future__ import annotations

import secrets
from collections.abc import Mapping

from fastapi import Header, Request

from .errors import Unauthorized

TENSORBOARD_PREFIX = "/tensorboard"
TENSORBOARD_COOKIE = "podagent_tensorboard"


def check_request_auth(
    path: str, authorization: str | None, cookies: Mapping[str, str], token: str
) -> None:
    """The browser cookie authenticates only TensorBoard subresources, never agent controls."""
    is_tensorboard = path == TENSORBOARD_PREFIX or path.startswith(TENSORBOARD_PREFIX + "/")
    if authorization is None and is_tensorboard and (cookie := cookies.get(TENSORBOARD_COOKIE)):
        authorization = f"Bearer {cookie}"
    check_bearer(authorization, token)


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
    """FastAPI dependency: the app's settings carry the expected token."""
    check_request_auth(
        request.url.path, authorization, request.cookies, request.app.state.settings.token
    )
