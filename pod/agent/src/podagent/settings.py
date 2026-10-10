"""Settings from the environment, and the paths under the workspace volume (POD-SPEC §5, §6.4)."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

MIN_TOKEN_LENGTH = 16


class SettingsError(ValueError):
    """The agent cannot run with this environment (missing token, bad values)."""


@dataclass(frozen=True)
class Paths:
    workspace: Path
    prefix: Path  # /opt: venvs and scripts

    @property
    def datasets(self) -> Path:
        return self.workspace / "datasets"

    @property
    def runs(self) -> Path:
        return self.workspace / "runs"

    @property
    def models(self) -> Path:
        return self.workspace / "models"

    @property
    def hf_cache(self) -> Path:
        return self.models / "hf-cache"

    @property
    def logs(self) -> Path:
        return self.workspace / "logs"

    @property
    def scripts(self) -> Path:
        return self.prefix / "pod" / "scripts"

    def venv_bin(self, venv: str, binary: str) -> str:
        """Absolute path of ``binary`` in ``/opt/venvs/<venv>/bin``."""
        return str(self.prefix / "venvs" / venv / "bin" / binary)

    def run_dir(self, run_id: str) -> Path:
        return self.runs / run_id

    def ensure(self) -> None:
        for directory in (self.datasets, self.runs, self.hf_cache, self.logs):
            directory.mkdir(parents=True, exist_ok=True)


@dataclass(frozen=True)
class Settings:
    token: str
    paths: Paths
    # None: the nvidia-smi backend; N: the fake backend with N GPUs, and fake services
    fake_gpus: int | None

    @property
    def fake(self) -> bool:
        return self.fake_gpus is not None


def load_settings(env: dict[str, str] | None = None) -> Settings:
    """Build settings from ``env`` (default ``os.environ``); raise ``SettingsError`` if unusable."""
    source = os.environ if env is None else env
    token = source.get("PODAGENT_TOKEN", "").strip()
    if len(token) < MIN_TOKEN_LENGTH:
        raise SettingsError(
            f"PODAGENT_TOKEN must be set to at least {MIN_TOKEN_LENGTH} characters; refusing to start"
        )
    fake_raw = source.get("PODAGENT_FAKE_GPUS")
    fake_gpus: int | None = None
    if fake_raw is not None and fake_raw.strip() != "":
        try:
            fake_gpus = int(fake_raw)
        except ValueError:
            raise SettingsError("PODAGENT_FAKE_GPUS must be an integer") from None
        if fake_gpus < 0:
            raise SettingsError("PODAGENT_FAKE_GPUS must be >= 0")
    paths = Paths(
        workspace=Path(source.get("PODAGENT_WORKSPACE", "/workspace")).expanduser(),
        prefix=Path(source.get("PODAGENT_PREFIX", "/opt")),
    )
    return Settings(token=token, paths=paths, fake_gpus=fake_gpus)
