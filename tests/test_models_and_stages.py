from __future__ import annotations

import pytest
from pydantic_ai import NativeOutput, PromptedOutput, ToolOutput

from concept_captioner.job import EndpointSpec
from concept_captioner.models import parse_spec, resolve
from concept_captioner.schemas import Caption
from concept_captioner.stages import CaptionDeps, exact_trigger_spans, trigger_problems
from concept_captioner.types import ConfigurationError


@pytest.fixture(autouse=True)
def fake_keys(monkeypatch):
    for name in (
        "GOOGLE_API_KEY",
        "ANTHROPIC_API_KEY",
        "OPENAI_API_KEY",
        "OPENROUTER_API_KEY",
        "VERCEL_AI_GATEWAY_API_KEY",
    ):
        monkeypatch.setenv(name, "test-key")
    monkeypatch.setenv("VLLM_BASE_URL", "http://localhost:8000/v1")


@pytest.mark.parametrize(
    "spec, cls",
    [
        ("google:gemini-3.8-flash", "GoogleModel"),
        ("anthropic:claude-opus-5-5", "AnthropicModel"),
        ("openai:gpt-5.2", "OpenAIResponsesModel"),
        ("openrouter:anthropic/claude-sonnet-4-6", "OpenRouterModel"),
        ("vercel:anthropic/claude-sonnet-5-5", "OpenAIChatModel"),
        ("vllm:Qwen/Qwen3-VL-32B-Instruct", "OpenAIChatModel"),
    ],
)
def test_resolve_documented_prefixes(spec, cls):
    resolved = resolve(spec, thinking="low")
    assert type(resolved.model).__name__ == cls
    assert resolved.requested == spec.split(":", 1)[1]
    assert resolved.settings["thinking"] == "low"
    assert isinstance(resolved.output_type(Caption), NativeOutput)


def test_resolve_base_url_and_output_modes():
    vllm = resolve(
        EndpointSpec(
            kind="vllm", model="Qwen/x", base_url="http://pod:8000/v1", output_mode="prompted"
        )
    )
    assert str(vllm.model.client.base_url) == "http://pod:8000/v1/"
    assert isinstance(vllm.output_type(Caption), PromptedOutput)
    other = resolve(
        EndpointSpec(
            kind="vllm",
            model="m",
            base_url="http://127.0.0.1:8000/v1",
            output_mode="tool",
            settings={"temperature": 0.2},
        )
    )
    assert type(other.model).__name__ == "OpenAIChatModel"
    assert isinstance(other.output_type(Caption), ToolOutput)
    assert other.settings["temperature"] == 0.2 and "thinking" not in other.settings


def test_base_url_cannot_redirect_a_stored_key():
    # a job file can be downloaded; its base_url must never pair with the OpenAI key
    with pytest.raises(ConfigurationError, match="takes no base_url"):
        resolve(EndpointSpec(kind="openai", model="gpt-5.2", base_url="https://evil.example/v1"))
    # custom endpoints: https anywhere, plain http only to loopback/private hosts
    for ok in (
        "https://pod-1234.proxy.runpod.net/v1",
        "http://localhost:8000/v1",
        "http://10.0.0.5:8000/v1",
    ):
        resolve(EndpointSpec(kind="vllm", model="m", base_url=ok))
    # 203.0.113.0/24 is "not globally reachable" to ipaddress, so use a public host/IP here
    for bad in ("http://evil.example.com/v1", "http://8.8.8.8:8000/v1"):
        with pytest.raises(ConfigurationError, match="must be https"):
            resolve(EndpointSpec(kind="vllm", model="m", base_url=bad))


def test_resolve_rejects_gemini_kind_and_bad_specs():
    with pytest.raises(ConfigurationError, match="kind: google"):
        resolve("gemini:gemini-3.8-flash")
    with pytest.raises(ConfigurationError):
        parse_spec("no-colon")
    with pytest.raises(ConfigurationError):
        resolve(EndpointSpec(kind="google", model="x", base_url="http://nope"))


def test_trigger_check():
    assert exact_trigger_spans("NORA7 and NORA7x and xNORA7", "NORA7") == ((0, 5),)
    deps = CaptionDeps(mapping={"NORA7": "x"}, triggers=("NORA7", "IVAN9"))
    assert trigger_problems("A photo of NORA7, a woman.", deps) == []
    assert trigger_problems("A photo of a woman.", deps) == [
        "the mapped trigger NORA7 must appear exactly in the caption"
    ]
    assert trigger_problems("NORA7 with IVAN9.", deps) == [
        "IVAN9 is not mapped in this image; do not use that trigger"
    ]
