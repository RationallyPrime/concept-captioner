"""The two credentials of POD-SPEC §2.1: the master bearer and the derived TensorBoard session."""

from __future__ import annotations

import pytest

from podagent.auth import TENSORBOARD_COOKIE, Authenticator
from podagent.errors import Unauthorized

TOKEN = "test-token-0123456789"
NOW = 1_790_000_000.0


def make(clock: list[float], key: bytes = b"k" * 32) -> Authenticator:
    return Authenticator(TOKEN, session_key=key, ttl_s=3600, clock=lambda: clock[0])


def test_session_is_derived_and_expires() -> None:
    clock = [NOW]
    auth = make(clock)
    session = auth.issue_tensorboard_session()
    assert session.expires_at == int(NOW) + 3600 and session.max_age_s == 3600
    assert TOKEN not in session.value
    auth.check_tensorboard_session(session.value)
    clock[0] = NOW + 3599
    auth.check_tensorboard_session(session.value)
    clock[0] = NOW + 3600
    with pytest.raises(Unauthorized, match="expired"):
        auth.check_tensorboard_session(session.value)


@pytest.mark.parametrize(
    "tamper",
    [
        lambda v: v.replace("v1.", "v2.", 1),  # unknown version
        lambda v: "v1." + str(int(v.split(".")[1]) + 10_000) + "." + v.split(".")[2],  # extended
        lambda v: v[:-1] + ("0" if v[-1] != "0" else "1"),  # forged MAC
        lambda v: "v1.abc." + v.split(".")[2],
        lambda v: "v1." + v.split(".")[1],  # no MAC
        lambda _v: TOKEN,  # the master token is not a session
        lambda _v: "",
    ],
)
def test_tampered_sessions_are_refused(tamper) -> None:  # type: ignore[no-untyped-def]
    auth = make([NOW])
    value = auth.issue_tensorboard_session().value
    with pytest.raises(Unauthorized):
        auth.check_tensorboard_session(tamper(value))


def test_sessions_die_with_the_process_key() -> None:
    value = make([NOW], key=b"a" * 32).issue_tensorboard_session().value
    with pytest.raises(Unauthorized):
        make([NOW], key=b"b" * 32).check_tensorboard_session(value)
    # A fresh agent process draws its own random key.
    first, second = Authenticator(TOKEN), Authenticator(TOKEN)
    with pytest.raises(Unauthorized):
        second.check_tensorboard_session(first.issue_tensorboard_session().value)


def test_check_scopes_the_cookie_to_tensorboard() -> None:
    auth = make([NOW])
    cookies = {TENSORBOARD_COOKIE: auth.issue_tensorboard_session().value}
    for path in ("/tensorboard", "/tensorboard/", "/tensorboard/data/runs"):
        auth.check(path, None, cookies)
    for path in ("/health", "/tensorboard-session", "/tensorboardx", "/runs/x/files"):
        with pytest.raises(Unauthorized):
            auth.check(path, None, cookies)
    # The bearer works everywhere; a present header is judged on its own, cookie or not.
    auth.check("/health", f"Bearer {TOKEN}", {})
    with pytest.raises(Unauthorized):
        auth.check("/tensorboard/", "Bearer nope-nope-nope", cookies)
