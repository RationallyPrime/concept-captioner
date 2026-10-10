from __future__ import annotations

import httpx2
import pytest

from concept_captioner.job import EndpointSpec
from concept_captioner.models import check_base_url, resolve
from concept_captioner.types import ConfigurationError


@pytest.mark.parametrize(
    "target, configured, authenticated",
    [
        ("https://trusted.example/v1", "https://trusted.example/v1", True),
        ("https://TRUSTED.example/v1", "https://trusted.example/other", True),
        ("https://evil.example/v1", "https://trusted.example/v1", False),
        ("http://localhost:9000/v1", "http://localhost:8000/v1", True),
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
    resolved = resolve(EndpointSpec(kind="vllm", model="m", base_url=target))
    requests = []

    def reply(request):
        requests.append(request)
        return httpx2.Response(
            200,
            json={
                "id": "test",
                "object": "chat.completion",
                "created": 0,
                "model": "m",
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"}}],
            },
        )

    async with httpx2.AsyncClient(transport=httpx2.MockTransport(reply)) as client:
        resolved.model.client._client = client
        await resolved.model.client.chat.completions.create(
            model="m",
            messages=[{"role": "user", "content": "test"}],
            extra_headers=resolved.settings.get("extra_headers"),
        )
    assert requests[0].headers.get("authorization") == (
        "Bearer stored-vllm-key" if authenticated else None
    )


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
    assert resolve(f"{kind}:m").model.client.base_url.host == host


@pytest.mark.parametrize("kind", ["openai", "anthropic"])
def test_missing_hosted_credentials_remain_configuration_errors(monkeypatch, kind):
    monkeypatch.delenv(f"{kind.upper()}_API_KEY", raising=False)
    with pytest.raises(ConfigurationError):
        resolve(f"{kind}:m")
