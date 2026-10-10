"""GPU inventory backends (POD-SPEC §5): the pure parser on fixtures, and ``NvidiaSmiBackend``
with ``subprocess.run`` monkeypatched so no test ever runs a binary."""

from __future__ import annotations

import logging
import subprocess
from typing import Any

import pytest

from podagent.gpus import (
    FAKE_GPU_MEMORY_MIB,
    FAKE_GPU_NAME,
    NVIDIA_SMI_ARGV,
    NVIDIA_SMI_TIMEOUT_S,
    FakeBackend,
    GpuInfo,
    InventoryUnavailable,
    NvidiaSmiBackend,
    parse_nvidia_smi,
)

# --- fixtures: what `nvidia-smi --query-gpu=index,name,memory.total,memory.used,uuid
# --format=csv,noheader,nounits` prints -------------------------------------------------------

ONE_GPU = "0, NVIDIA A100 80GB PCIe, 81920, 61440, GPU-0a1b2c3d-0000-1111-2222-333344445555\n"

TWO_GPUS = (
    "0, NVIDIA A100 80GB PCIe, 81920, 61440, GPU-0a1b2c3d-0000-1111-2222-333344445555\n"
    "1, NVIDIA A100 80GB PCIe, 81920, 0, GPU-0a1b2c3d-0000-1111-2222-333344445556\n"
)

FOUR_GPUS = (
    "0, NVIDIA H100 80GB HBM3, 81559, 1024, GPU-aaaaaaaa-0000-0000-0000-000000000000\n"
    "1, NVIDIA H100 80GB HBM3, 81559, 0, GPU-aaaaaaaa-0000-0000-0000-000000000001\n"
    "2, NVIDIA H100 80GB HBM3, 81559, 0, GPU-aaaaaaaa-0000-0000-0000-000000000002\n"
    "3, NVIDIA H100 80GB HBM3, 81559, 0, GPU-aaaaaaaa-0000-0000-0000-000000000003\n"
)


# --- parse_nvidia_smi -------------------------------------------------------------------------


def test_parse_one_gpu() -> None:
    gpus = parse_nvidia_smi(ONE_GPU)
    assert gpus == [
        GpuInfo(
            index=0,
            name="NVIDIA A100 80GB PCIe",
            memory_total_mib=81920,
            memory_used_mib=61440,
            uuid="GPU-0a1b2c3d-0000-1111-2222-333344445555",
        )
    ]


def test_parse_two_gpus() -> None:
    gpus = parse_nvidia_smi(TWO_GPUS)
    assert [g.index for g in gpus] == [0, 1]
    assert [g.memory_used_mib for g in gpus] == [61440, 0]
    assert gpus[1].uuid == "GPU-0a1b2c3d-0000-1111-2222-333344445556"
    assert all(g.name == "NVIDIA A100 80GB PCIe" for g in gpus)


def test_parse_four_gpus() -> None:
    gpus = parse_nvidia_smi(FOUR_GPUS)
    assert [g.index for g in gpus] == [0, 1, 2, 3]
    assert all(g.memory_total_mib == 81559 for g in gpus)
    assert gpus[0].memory_used_mib == 1024
    assert [g.uuid for g in gpus] == [
        f"GPU-aaaaaaaa-0000-0000-0000-00000000000{i}" for i in range(4)
    ]


def test_parse_empty_text_is_empty_inventory() -> None:
    assert parse_nvidia_smi("") == []
    assert parse_nvidia_smi("\n\n   \n") == []


def test_parse_skips_blank_lines_and_surrounding_whitespace() -> None:
    text = "\n\n  " + ONE_GPU.rstrip("\n") + "   \n\n\t\n" + TWO_GPUS.splitlines()[1] + "\n\n"
    gpus = parse_nvidia_smi(text)
    assert [g.index for g in gpus] == [0, 1]


def test_parse_accepts_crlf_and_missing_trailing_newline() -> None:
    text = (
        "0, NVIDIA A100 80GB PCIe, 81920, 61440, GPU-x\r\n1, NVIDIA A100 80GB PCIe, 81920, 0, GPU-y"
    )
    gpus = parse_nvidia_smi(text)
    assert [(g.index, g.uuid) for g in gpus] == [(0, "GPU-x"), (1, "GPU-y")]
    assert gpus[1].name == "NVIDIA A100 80GB PCIe"


def test_parse_unavailable_uuid_becomes_none() -> None:
    for token in ("[N/A]", "[Not Supported]", "N/A"):
        (gpu,) = parse_nvidia_smi(f"0, NVIDIA A100 80GB PCIe, 81920, 0, {token}\n")
        assert gpu.uuid is None, token
    (gpu,) = parse_nvidia_smi("0, NVIDIA A100 80GB PCIe, 81920, 0, \n")
    assert gpu.uuid is None


@pytest.mark.parametrize(
    "bad_line",
    [
        "0, NVIDIA A100 80GB PCIe, 81920, 61440",  # 4 fields
        "0, NVIDIA A100 80GB PCIe, 81920, 61440, GPU-x, extra",  # 6 fields
        "garbage",  # 1 field
        "x, NVIDIA A100 80GB PCIe, 81920, 61440, GPU-x",  # index not an integer
        "0, NVIDIA A100 80GB PCIe, 81920 MiB, 61440, GPU-x",  # units slipped in
        "0, NVIDIA A100 80GB PCIe, 81920, [N/A], GPU-x",  # memory.used unavailable
        "0, , 81920, 61440, GPU-x",  # empty name
    ],
)
def test_parse_malformed_line_raises_naming_it(bad_line: str) -> None:
    with pytest.raises(ValueError, match="nvidia-smi line 2") as info:
        parse_nvidia_smi(ONE_GPU + bad_line + "\n")
    assert bad_line.strip() in str(info.value)


def test_parse_names_with_commas_are_not_supported() -> None:
    # nvidia-smi does not quote CSV fields; a comma inside a name (MIG-style instance names)
    # breaks the field count. Quoting does not rescue it either: treated as malformed.
    unquoted = "0, NVIDIA A100 80GB PCIe MIG 1g.10gb, Instance 3, 9728, 0, MIG-abc\n"
    quoted = '0, "NVIDIA A100 80GB PCIe, MIG 1g.10gb", 9728, 0, MIG-abc\n'
    for text in (unquoted, quoted):
        with pytest.raises(ValueError, match="expected 5 fields"):
            parse_nvidia_smi(text)


def test_parse_error_line_number_counts_blank_lines() -> None:
    # The line number in the message is the physical line, so it can be found in the raw output.
    with pytest.raises(ValueError, match="nvidia-smi line 3"):
        parse_nvidia_smi("\n\nnope\n")


# --- NvidiaSmiBackend with subprocess.run monkeypatched -------------------------------------


class _RunRecorder:
    """Stand-in for ``subprocess.run`` that records the call and returns or raises as told."""

    def __init__(self, result: Any = None, raises: BaseException | None = None) -> None:
        self.result = result
        self.raises = raises
        self.calls: list[tuple[list[str], dict[str, Any]]] = []

    def __call__(self, argv: list[str], **kwargs: Any) -> Any:
        self.calls.append((list(argv), dict(kwargs)))
        if self.raises is not None:
            raise self.raises
        return self.result


def _completed(
    stdout: str = "", stderr: str = "", returncode: int = 0
) -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(
        list(NVIDIA_SMI_ARGV), returncode, stdout=stdout, stderr=stderr
    )


@pytest.fixture
def warnings(caplog: pytest.LogCaptureFixture) -> pytest.LogCaptureFixture:
    caplog.set_level(logging.WARNING, logger="podagent.gpus")
    return caplog


def test_backend_kind() -> None:
    assert NvidiaSmiBackend().kind == "nvidia-smi"
    assert FakeBackend(1).kind == "fake"


def test_backend_runs_fixed_argv_without_shell_and_with_timeout(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    recorder = _RunRecorder(result=_completed(stdout=TWO_GPUS))
    monkeypatch.setattr(subprocess, "run", recorder)

    gpus = NvidiaSmiBackend().list_gpus()

    assert [g.index for g in gpus] == [0, 1]
    assert len(recorder.calls) == 1
    argv, kwargs = recorder.calls[0]
    assert argv == list(NVIDIA_SMI_ARGV)
    assert argv[0] == "nvidia-smi"
    assert kwargs["timeout"] == NVIDIA_SMI_TIMEOUT_S == 10.0
    assert not kwargs.get("shell")
    assert kwargs.get("text") is True
    assert kwargs.get("capture_output") is True
    assert kwargs.get("check") is False


def test_backend_success_logs_no_warning(monkeypatch: pytest.MonkeyPatch, warnings) -> None:
    monkeypatch.setattr(subprocess, "run", _RunRecorder(result=_completed(stdout=FOUR_GPUS)))
    assert len(NvidiaSmiBackend().list_gpus()) == 4
    assert warnings.records == []


def test_backend_success_with_no_gpus_is_empty(monkeypatch: pytest.MonkeyPatch, warnings) -> None:
    # nvidia-smi present and happy but nothing to list: empty, and nothing to warn about.
    monkeypatch.setattr(subprocess, "run", _RunRecorder(result=_completed(stdout="")))
    assert NvidiaSmiBackend().list_gpus() == []
    assert warnings.records == []


def test_backend_missing_binary(monkeypatch: pytest.MonkeyPatch, warnings) -> None:
    monkeypatch.setattr(
        subprocess, "run", _RunRecorder(raises=FileNotFoundError(2, "No such file", "nvidia-smi"))
    )
    with pytest.raises(InventoryUnavailable, match="not found"):
        NvidiaSmiBackend().list_gpus()
    assert len(warnings.records) == 1
    assert warnings.records[0].levelno == logging.WARNING
    assert "not found" in warnings.records[0].getMessage()


def test_backend_other_os_error(monkeypatch: pytest.MonkeyPatch, warnings) -> None:
    monkeypatch.setattr(
        subprocess, "run", _RunRecorder(raises=PermissionError(13, "Permission denied"))
    )
    with pytest.raises(InventoryUnavailable, match="Permission denied"):
        NvidiaSmiBackend().list_gpus()
    assert len(warnings.records) == 1
    assert "Permission denied" in warnings.records[0].getMessage()


def test_backend_timeout(monkeypatch: pytest.MonkeyPatch, warnings) -> None:
    monkeypatch.setattr(
        subprocess,
        "run",
        _RunRecorder(raises=subprocess.TimeoutExpired(list(NVIDIA_SMI_ARGV), NVIDIA_SMI_TIMEOUT_S)),
    )
    with pytest.raises(InventoryUnavailable, match="10 s"):
        NvidiaSmiBackend().list_gpus()
    assert len(warnings.records) == 1
    message = warnings.records[0].getMessage()
    assert "10 s" in message
    assert "unavailable" in message and "no GPUs" not in message


def test_backend_nonzero_exit(monkeypatch: pytest.MonkeyPatch, warnings) -> None:
    monkeypatch.setattr(
        subprocess,
        "run",
        _RunRecorder(
            result=_completed(
                stdout="",
                stderr="NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver.\n",
                returncode=9,
            )
        ),
    )
    with pytest.raises(InventoryUnavailable, match="status 9"):
        NvidiaSmiBackend().list_gpus()
    assert len(warnings.records) == 1
    message = warnings.records[0].getMessage()
    assert "status 9" in message
    assert "couldn't communicate with the NVIDIA driver" in message


def test_backend_nonzero_exit_ignores_stdout(monkeypatch: pytest.MonkeyPatch, warnings) -> None:
    # A nonzero exit is a failure even if something parseable landed on stdout.
    monkeypatch.setattr(
        subprocess, "run", _RunRecorder(result=_completed(stdout=ONE_GPU, stderr="", returncode=1))
    )
    with pytest.raises(InventoryUnavailable, match="no stderr"):
        NvidiaSmiBackend().list_gpus()
    assert "no stderr" in warnings.records[0].getMessage()


def test_backend_unparseable_output(monkeypatch: pytest.MonkeyPatch, warnings) -> None:
    # The parser raises; the backend reports it as unavailable (plus a warning), never as [].
    monkeypatch.setattr(
        subprocess, "run", _RunRecorder(result=_completed(stdout="No devices were found\n"))
    )
    with pytest.raises(InventoryUnavailable, match="not understood"):
        NvidiaSmiBackend().list_gpus()
    assert len(warnings.records) == 1
    message = warnings.records[0].getMessage()
    assert "not understood" in message
    assert "No devices were found" in message


def test_backend_reads_inventory_fresh_on_every_call(monkeypatch: pytest.MonkeyPatch) -> None:
    # POD-SPEC §5: not cached; every call re-runs nvidia-smi.
    recorder = _RunRecorder(result=_completed(stdout=ONE_GPU))
    monkeypatch.setattr(subprocess, "run", recorder)
    backend = NvidiaSmiBackend()
    backend.list_gpus()
    recorder.result = _completed(stdout=TWO_GPUS)
    assert len(backend.list_gpus()) == 2
    assert len(recorder.calls) == 2


# --- FakeBackend (done before this unit; pinned here because /plan and tests depend on it) ----


@pytest.mark.parametrize("count", [0, 1, 2, 4])
def test_fake_backend_shape(count: int) -> None:
    gpus = FakeBackend(count).list_gpus()
    assert [g.index for g in gpus] == list(range(count))
    for gpu in gpus:
        assert gpu.name == FAKE_GPU_NAME
        assert gpu.memory_total_mib == FAKE_GPU_MEMORY_MIB == 81920
        assert gpu.memory_used_mib == 0
        assert gpu.uuid == f"GPU-FAKE-{gpu.index}"
