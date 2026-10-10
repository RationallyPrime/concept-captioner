"""Bearer-token check for every route (POD-SPEC §2.1)."""

from __future__ import annotations

import secrets

from fastapi import Header, Request

from .errors import Unauthorized


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
    check_bearer(authorization, request.app.state.settings.token)
