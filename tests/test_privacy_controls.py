from __future__ import annotations

import pytest

from concept_captioner.job import EndpointSpec
from concept_captioner.models import JOB_SETTING_KEYS, resolve
from concept_captioner.types import ConfigurationError


@pytest.mark.parametrize("key", ["store", "Store", "safety-identifier", "metadata", "user"])
@pytest.mark.parametrize("kind", ["openai", "vllm"])
def test_job_extra_body_cannot_control_provider_retention(monkeypatch, kind, key):
    # extra_body is merged over the request body last, so a downloaded job file could otherwise
    # switch provider-side retention back on. Retention is not the job file's to decide.
    monkeypatch.setenv("OPENAI_API_KEY", "test-only-key")
    spec = EndpointSpec(
        kind=kind,
        model="m",
        base_url="https://pod.example/v1" if kind == "vllm" else None,
        settings={"extra_body": {key: True}},
    )
    with pytest.raises(ConfigurationError, match="extra_body"):
        resolve(spec)


@pytest.mark.parametrize(
    "key",
    [
        "openai_store",
        "openai_user",
        "openai_prompt_cache_key",
        "openai_previous_response_id",
        "anthropic_metadata",
    ],
)
def test_provider_prefixed_settings_are_refused(monkeypatch, key):
    # The typed provider settings include retention and attribution controls; Swift refuses every
    # provider-prefixed key, and so does Python, so a job file means the same thing in both.
    monkeypatch.setenv("OPENAI_API_KEY", "test-only-key")
    with pytest.raises(ConfigurationError, match="not a job-file setting"):
        resolve(EndpointSpec(kind="openai", model="m", settings={key: True}))


def test_allowed_settings_are_the_unified_pydantic_ai_set():
    assert "extra_body" in JOB_SETTING_KEYS
    assert "temperature" in JOB_SETTING_KEYS
    assert not any(key.startswith(("openai_", "anthropic_", "google_")) for key in JOB_SETTING_KEYS)


def test_openai_responses_store_is_forced_off(monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "test-only-key")
    resolved = resolve(EndpointSpec(kind="openai", model="m", settings={"temperature": 0.2}))
    assert resolved.settings["openai_store"] is False
    assert resolved.settings["temperature"] == 0.2


def test_harmless_extra_body_keys_still_pass(monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "test-only-key")
    resolved = resolve(
        EndpointSpec(kind="openai", model="m", settings={"extra_body": {"top_k": 5}})
    )
    assert resolved.settings["extra_body"] == {"top_k": 5}
