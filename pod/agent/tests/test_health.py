from __future__ import annotations

import pytest

from podagent import __version__
from podagent.settings import SettingsError, load_settings


def test_health_reports_fake_backend(client) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["version"] == __version__
    assert body["gpu_backend"] == "fake"
    assert body["gpu_count"] == 2
    assert body["workspace"].endswith("workspace")


def test_health_requires_bearer(anon_client) -> None:
    response = anon_client.get("/health")
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthorized"

    response = anon_client.get("/health", headers={"Authorization": "Bearer wrong-token-000000"})
    assert response.status_code == 401


def test_workspace_directories_are_created(client, settings) -> None:
    client.get("/health")
    for name in ("datasets", "runs", "models/hf-cache", "logs"):
        assert (settings.paths.workspace / name).is_dir()


def test_settings_refuse_without_token() -> None:
    with pytest.raises(SettingsError):
        load_settings({})
    with pytest.raises(SettingsError):
        load_settings({"PODAGENT_TOKEN": "short"})


def test_settings_fake_gpus() -> None:
    settings = load_settings({"PODAGENT_TOKEN": "x" * 16, "PODAGENT_FAKE_GPUS": "3"})
    assert settings.fake_gpus == 3 and settings.fake
    settings = load_settings({"PODAGENT_TOKEN": "x" * 16})
    assert settings.fake_gpus is None and not settings.fake
    with pytest.raises(SettingsError):
        load_settings({"PODAGENT_TOKEN": "x" * 16, "PODAGENT_FAKE_GPUS": "-1"})
