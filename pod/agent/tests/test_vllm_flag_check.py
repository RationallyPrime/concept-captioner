"""``images/check_vllm_flags.py``: the build-time probe of the vLLM flag allowlist (POD-SPEC §6.1).

The real run happens in ``Dockerfile.base`` against the installed wheel; here it runs against a
synthetic package tree, so what it counts as present and as missing is pinned down.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType

import pytest

from podagent.catalog import VLLM_EXTRA_FLAGS

POD = Path(__file__).resolve().parents[2]
SCRIPT = POD / "images" / "check_vllm_flags.py"


def load() -> ModuleType:
    spec = importlib.util.spec_from_file_location("check_vllm_flags", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


check = load()


def fake_vllm(root: Path, flags: list[str]) -> Path:
    """A package whose arg definitions name ``flags`` the way vLLM does: as config fields."""
    package = root / "vllm"
    (package / "engine").mkdir(parents=True)
    (package / "__init__.py").write_text("")
    fields = "\n".join(
        f"    {flag.removeprefix('--').replace('-', '_')}: int = 0" for flag in flags
    )
    (package / "engine" / "arg_utils.py").write_text(f"class EngineArgs:\n{fields or '    pass'}\n")
    return package


def test_spellings_cover_dashed_attribute_and_negated_forms() -> None:
    assert check.spellings("--max-num-batched-tokens") == (
        "--max-num-batched-tokens",
        "max_num_batched_tokens",
    )
    assert "enable_prefix_caching" in check.spellings("--no-enable-prefix-caching")


def test_every_allowlisted_flag_found(tmp_path: Path) -> None:
    flags = [flag.removeprefix("--no-").removeprefix("--") for flag in VLLM_EXTRA_FLAGS]
    package = fake_vllm(tmp_path, [f"--{flag}" for flag in flags])
    assert check.missing_flags(VLLM_EXTRA_FLAGS, package) == []
    assert check.main([str(package)]) == 0


@pytest.mark.parametrize("removed", ["--max-num-batched-tokens", "--enable-prefix-caching"])
def test_a_removed_flag_fails_the_build(
    tmp_path: Path, removed: str, capsys: pytest.CaptureFixture[str]
) -> None:
    kept = [flag for flag in VLLM_EXTRA_FLAGS if flag.removeprefix("--no-") != removed[2:]]
    kept = [flag for flag in kept if flag != removed]
    package = fake_vllm(tmp_path, [f"--{flag.removeprefix('--no-').lstrip('-')}" for flag in kept])
    missing = check.missing_flags(VLLM_EXTRA_FLAGS, package)
    assert removed in missing
    assert check.main([str(package)]) == 1
    assert removed in capsys.readouterr().err


def test_usage(tmp_path: Path) -> None:
    assert check.main([]) == 2
    assert check.main([str(tmp_path / "absent")]) == 2


def test_base_image_runs_the_check() -> None:
    dockerfile = (POD / "images" / "Dockerfile.base").read_text()
    assert "COPY pod/images/check_vllm_flags.py /opt/pod/checks/check_vllm_flags.py" in dockerfile
    assert "/opt/venvs/agent/bin/python -I /opt/pod/checks/check_vllm_flags.py" in dockerfile
