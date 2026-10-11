from __future__ import annotations

import pytest

from concept_captioner.job import EndpointSpec
from concept_captioner.models import resolve
from concept_captioner.types import ConfigurationError


@pytest.mark.parametrize("key", ["store", "Store", "metadata", "user", "safety_identifier"])
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


def test_harmless_extra_body_keys_still_pass(monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "test-only-key")
    resolved = resolve(
        EndpointSpec(kind="openai", model="m", settings={"extra_body": {"top_k": 5}})
    )
    assert resolved.settings["extra_body"] == {"top_k": 5}
