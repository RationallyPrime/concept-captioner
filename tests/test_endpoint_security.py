from __future__ import annotations

import json

import httpx2
import pytest
from pydantic_ai.direct import model_request
from pydantic_ai.messages import ModelRequest

from concept_captioner.job import EndpointSpec
from concept_captioner.models import GATEWAY_UPSTREAMS, check_base_url, resolve
from concept_captioner.types import ConfigurationError


def _recording_client(requests: list[httpx2.Request], body: dict) -> httpx2.AsyncClient:
    def reply(request: httpx2.Request) -> httpx2.Response:
        requests.append(request)
        return httpx2.Response(200, json=body)

    return httpx2.AsyncClient(transport=httpx2.MockTransport(reply))


CHAT_REPLY = {
    "id": "test",
    "object": "chat.completion",
    "created": 0,
    "model": "m",
    "choices": [
        {
            "index": 0,
            "finish_reason": "stop",
            "message": {"role": "assistant", "content": "ok"},
        }
    ],
}

RESPONSES_REPLY = {
    "id": "resp_test",
    "object": "response",
    "created_at": 0,
    "model": "m",
    "status": "completed",
    "parallel_tool_calls": False,
    "tool_choice": "auto",
    "tools": [],
    "output": [
        {
            "type": "message",
            "id": "msg_test",
            "role": "assistant",
            "status": "completed",
            "content": [{"type": "output_text", "text": "ok", "annotations": []}],
        }
    ],
}


async def _send_one(resolved) -> None:
    await model_request(
        resolved.model, [ModelRequest.user_text_prompt("test")], model_settings=resolved.settings
    )


@pytest.mark.parametrize(
    "target, configured, authenticated",
    [
        ("https://trusted.example/v1", "https://trusted.example/v1", True),
        ("https://TRUSTED.example/v1", "https://trusted.example/other", True),
        ("https://evil.example/v1", "https://trusted.example/v1", False),
        ("http://localhost:9000/v1", "http://localhost:8000/v1", False),
        ("https://trusted.example:443/v1", "https://trusted.example/v1", True),
        ("http://localhost:8000/v1", "https://localhost:8000/v1", False),
        ("https://evil.example/v1", None, False),
        (None, "http://localhost:8000/v1", True),
    ],
)
async def test_vllm_key_only_reaches_the_user_configured_host(
    monkeypatch, target, configured, authenticated
):
    monkeypatch.setenv("VLLM_API_KEY", "stored-vllm-key")
    monkeypatch.setenv("OPENAI_API_KEY", "unrelated-openai-key")
    if configured is None:
        monkeypatch.delenv("VLLM_BASE_URL", raising=False)
    else:
        monkeypatch.setenv("VLLM_BASE_URL", configured)
    requests: list[httpx2.Request] = []
    async with _recording_client(requests, CHAT_REPLY) as client:
        resolved = resolve(
            EndpointSpec(kind="vllm", model="m", base_url=target), http_client=client
        )
        await _send_one(resolved)
    assert len(requests) == 1
    assert requests[0].headers.get("authorization") == (
        "Bearer stored-vllm-key" if authenticated else None
    )


def test_unauthenticated_vllm_hook_is_installed_once(monkeypatch):
    monkeypatch.delenv("VLLM_BASE_URL", raising=False)
    client = httpx2.AsyncClient()
    spec = EndpointSpec(kind="vllm", model="m", base_url="https://pod.example/v1")
    resolve(spec, http_client=client)
    resolve(spec, http_client=client)
    assert len(client.event_hooks["request"]) == 1


async def test_openai_responses_requests_are_not_stored(monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "test-only-key")
    requests: list[httpx2.Request] = []
    async with _recording_client(requests, RESPONSES_REPLY) as client:
        # A job file cannot carry openai_store at all (test_privacy_controls); this checks the
        # forced-off value actually reaches the wire alongside an ordinary unified setting.
        resolved = resolve(
            EndpointSpec(kind="openai", model="m", settings={"temperature": 0.2}),
            http_client=client,
        )
        await _send_one(resolved)
    assert requests[0].url.host == "api.openai.com"
    assert json.loads(requests[0].content)["store"] is False


@pytest.mark.parametrize(
    "header",
    [
        "Authorization",
        "aUtHoRiZaTiOn",
        "Proxy-Authorization",
        "x-api-key",
        "x-goog-api-key",
        "api_key",
        "X-Auth-Token",
        "Cookie",
        "Host",
    ],
)
def test_job_settings_cannot_supply_authentication_headers(monkeypatch, header):
    monkeypatch.setenv("VLLM_BASE_URL", "http://localhost:8000/v1")
    with pytest.raises(ConfigurationError, match=r"header.*not allowed"):
        resolve(EndpointSpec(kind="vllm", model="m", settings={"extra_headers": {header: "bad"}}))


@pytest.mark.parametrize(
    "url",
    [
        "http://localhost@evil.example/v1",
        "https://localhost@evil.example/v1",
        "http://local%68ost/v1",
        "http://localhost\\@evil.example/v1",
        "http://local\thost/v1",
        "http://localhost/\npath",
        "http://localhost:99999/v1",
        "http://evil。com/v1",
        "http://evil．com/v1",
        "http://evil｡com/v1",
    ],
)
def test_ambiguous_base_urls_are_rejected(url):
    with pytest.raises(ConfigurationError):
        check_base_url(url)


def test_non_authentication_headers_still_work(monkeypatch):
    monkeypatch.setenv("VLLM_BASE_URL", "http://localhost:8000/v1")
    result = resolve(
        EndpointSpec(kind="vllm", model="m", settings={"extra_headers": {"X-Title": "test"}})
    )
    assert result.settings["extra_headers"]["X-Title"] == "test"


@pytest.mark.parametrize(
    "kind, host", [("openai", "api.openai.com"), ("anthropic", "api.anthropic.com")]
)
def test_hosted_providers_keep_their_fixed_origin(monkeypatch, kind, host):
    monkeypatch.setenv(f"{kind.upper()}_API_KEY", "test-only-key")
    monkeypatch.setenv(f"{kind.upper()}_BASE_URL", "https://custom.example/v1")
    assert httpx2.URL(resolve(f"{kind}:m").model.base_url).host == host


@pytest.mark.parametrize("kind", ["openai", "anthropic"])
def test_missing_hosted_credentials_remain_configuration_errors(monkeypatch, kind):
    monkeypatch.delenv(f"{kind.upper()}_API_KEY", raising=False)
    with pytest.raises(ConfigurationError):
        resolve(f"{kind}:m")


def test_openai_base_url_is_ignored_but_vllm_base_url_is_honoured(monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "test-only-key")
    monkeypatch.setenv("OPENAI_BASE_URL", "https://custom.example/v1")
    monkeypatch.delenv("VLLM_BASE_URL", raising=False)
    assert resolve("openai:m").model.base_url == "https://api.openai.com/v1/"
    vllm = resolve(EndpointSpec(kind="vllm", model="m", base_url="https://pod.example/v1"))
    assert vllm.model.base_url == "https://pod.example/v1/"


GATEWAY_ROUTES = {
    "openai": "OpenAIResponsesModel",
    "openai-responses": "OpenAIResponsesModel",
    "responses": "OpenAIResponsesModel",
    "openai-chat": "OpenAIChatModel",
    "chat": "OpenAIChatModel",
    "anthropic": "AnthropicModel",
    "google": "GoogleModel",
    "google-cloud": "GoogleModel",
}


def test_gateway_upstream_set_is_the_documented_one():
    assert set(GATEWAY_ROUTES) == GATEWAY_UPSTREAMS


@pytest.mark.parametrize("upstream", sorted(GATEWAY_ROUTES))
def test_each_gateway_upstream_resolves_to_a_fixed_host(monkeypatch, upstream):
    monkeypatch.setenv("PYDANTIC_AI_GATEWAY_API_KEY", "pylf_v1_us_test-only-key")
    resolved = resolve(f"gateway/{upstream}:m")
    assert type(resolved.model).__name__ == GATEWAY_ROUTES[upstream]
    assert resolved.model.base_url.startswith("https://gateway-us.pydantic.dev/")
    responses = GATEWAY_ROUTES[upstream] == "OpenAIResponsesModel"
    assert resolved.settings.get("openai_store") is (False if responses else None)


@pytest.mark.parametrize("upstream", ["groq", "bedrock", "converse", "nonsense"])
def test_other_gateway_upstreams_are_configuration_errors(monkeypatch, upstream):
    monkeypatch.setenv("PYDANTIC_AI_GATEWAY_API_KEY", "pylf_v1_us_test-only-key")
    with pytest.raises(ConfigurationError, match="gateway/chat"):
        resolve(f"gateway/{upstream}:m")
