"""Contract of ``images/compose.fake.yaml`` (POD-SPEC §6.3).

The compose stack is the only way to drive the agent the way the app does without a pod, so
it publishes the agent and vLLM ports the app expects. TensorBoard stays on loopback and
is shown through the authenticated agent route. The fake vLLM moves off loopback or
``GET http://127.0.0.1:8000/v1/models`` from
the host is refused and the readiness loop cannot be exercised. Parsed with the stdlib so the
test suite gains no dependency: the file is simple enough for a line-level reading.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

POD = Path(__file__).resolve().parents[2]
REPO = POD.parent  # both Dockerfiles say "Build context: the repository root"
COMPOSE = POD / "images" / "compose.fake.yaml"
DOCKERFILE = POD / "images" / "Dockerfile.fake"
BASE_DOCKERFILE = POD / "images" / "Dockerfile.base"

# What a package build of pod/agent needs and nothing else (hatchling reads README.md for the
# `readme` field). The developer's .venv, caches and tests live beside these and must stay out.
AGENT_PACKAGE_INPUTS = {
    "pod/agent/pyproject.toml",
    "pod/agent/README.md",
    "pod/agent/src/",
    "pod/agent/src/podagent/ltx_preprocess.py",  # shared with the isolated wrapper
}

# Agent and vLLM: the public ports; TensorBoard is private behind the agent.
HTTP_PORTS = (8800, 8000)


def _lines() -> list[str]:
    return [line for line in COMPOSE.read_text().splitlines() if not line.lstrip().startswith("#")]


def _env(name: str) -> str | None:
    pattern = re.compile(rf"^\s+{re.escape(name)}:\s*(.+?)\s*$")
    for line in _lines():
        if match := pattern.match(line):
            return match.group(1).strip("\"'")
    return None


def _published_ports() -> set[tuple[int, int]]:
    """``host:container`` pairs under ``ports:``."""
    pairs: set[tuple[int, int]] = set()
    in_ports = False
    for line in _lines():
        if re.match(r"^\s+ports:\s*$", line):
            in_ports = True
            continue
        if in_ports:
            if match := re.match(r"^\s+-\s*[\"']?(\d+):(\d+)[\"']?\s*$", line):
                pairs.add((int(match.group(1)), int(match.group(2))))
                continue
            in_ports = False
    return pairs


def test_fake_responders_bind_all_interfaces() -> None:
    assert _env("PODAGENT_FAKE_HOST") == "0.0.0.0"


def test_fake_mode_is_on() -> None:
    assert _env("PODAGENT_FAKE_GPUS") == "2"


@pytest.mark.parametrize("port", HTTP_PORTS)
def test_http_port_published_unchanged(port: int) -> None:
    assert (port, port) in _published_ports()


def test_only_authenticated_service_ports_are_published() -> None:
    assert {host for host, _ in _published_ports()} == set(HTTP_PORTS)


def test_fake_image_exposes_the_same_ports() -> None:
    exposed = re.search(r"^EXPOSE\s+(.+)$", DOCKERFILE.read_text(), re.MULTILINE)
    assert exposed is not None
    assert {int(p) for p in exposed.group(1).split()} == set(HTTP_PORTS)


def _copy_sources(dockerfile: Path) -> list[str]:
    """Every source path of every ``COPY`` instruction, in order (``--flags`` dropped)."""
    text = dockerfile.read_text().replace("\\\n", " ")
    sources: list[str] = []
    for line in text.splitlines():
        if not line.startswith("COPY "):
            continue
        parts = [p for p in line.split()[1:] if not p.startswith("--")]
        sources.extend(parts[:-1])  # the last operand is the destination
    return sources


def test_fake_image_copies_only_the_agent_package_inputs() -> None:
    """The whole ``pod/agent`` directory would ship the dev .venv and caches into the layer."""
    agent_sources = {s for s in _copy_sources(DOCKERFILE) if s.startswith("pod/agent")}
    assert agent_sources == AGENT_PACKAGE_INPUTS


def test_fake_image_agent_sources_match_base_image() -> None:
    base_sources = {s for s in _copy_sources(BASE_DOCKERFILE) if s.startswith("pod/agent")}
    assert base_sources == AGENT_PACKAGE_INPUTS


def test_fake_image_copies_scripts_not_their_tests() -> None:
    scripts = [s for s in _copy_sources(DOCKERFILE) if s.startswith("pod/scripts")]
    assert scripts == ["pod/scripts/*.py"]


def test_fake_image_copy_sources_exist_in_build_context() -> None:
    for source in _copy_sources(DOCKERFILE):
        matches = list(REPO.glob(source.rstrip("/")))
        assert matches, f"COPY source {source!r} matches nothing under the repo root"
        if source.endswith("/"):
            assert all(m.is_dir() for m in matches), source
