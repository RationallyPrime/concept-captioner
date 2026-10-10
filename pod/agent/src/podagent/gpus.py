"""GPU inventory backends: nvidia-smi and fake (POD-SPEC §5).

``NvidiaSmiBackend`` shells out to nothing: it runs ``NVIDIA_SMI_ARGV`` as an argv list with a
timeout and hands the CSV to the pure parser ``parse_nvidia_smi``. Any failure to obtain a
usable inventory (missing binary, timeout, nonzero exit, unparseable output) raises
``InventoryUnavailable`` (and logs a warning); an empty list is only ever a successful query of
a pod without GPUs. The distinction matters: nvidia-smi can stall past its timeout while a
driver is busy loading a model, and the supervisor must not mistake that for "no GPU here".
"""

from __future__ import annotations

import logging
import subprocess
from typing import Protocol

from pydantic import BaseModel

log = logging.getLogger(__name__)

NVIDIA_SMI_ARGV: tuple[str, ...] = (
    "nvidia-smi",
    "--query-gpu=index,name,memory.total,memory.used,uuid",
    "--format=csv,noheader,nounits",
)
NVIDIA_SMI_TIMEOUT_S = 10.0
FAKE_GPU_NAME = "FAKE GPU"
FAKE_GPU_MEMORY_MIB = 81920

# Number of comma-separated fields one ``NVIDIA_SMI_ARGV`` line carries. nvidia-smi does not
# quote CSV fields, so a GPU name containing a comma (MIG-style instance names, for example)
# produces more fields than this and is rejected as malformed: not supported, by design.
_FIELD_COUNT = 5

# What nvidia-smi prints for a query field the device or driver cannot answer.
_NOT_AVAILABLE = frozenset({"[N/A]", "[Not Supported]", "N/A"})


class GpuInfo(BaseModel):
    index: int
    name: str
    memory_total_mib: int
    memory_used_mib: int
    uuid: str | None = None


class InventoryUnavailable(RuntimeError):
    """The inventory could not be read right now (a transient or permanent nvidia-smi failure)."""


class GpuBackend(Protocol):
    kind: str  # "nvidia-smi" | "fake"

    def list_gpus(self) -> list[GpuInfo]:
        """The inventory; raises ``InventoryUnavailable`` when it cannot be read."""
        ...


def _int_field(value: str, what: str, line_no: int, line: str) -> int:
    try:
        return int(value)
    except ValueError:
        raise ValueError(
            f"nvidia-smi line {line_no}: {what} is not an integer ({value!r}): {line!r}"
        ) from None


def parse_nvidia_smi(text: str) -> list[GpuInfo]:
    """Parse the CSV ``nvidia-smi`` prints for ``NVIDIA_SMI_ARGV``.

    One GPU per line: ``0, NVIDIA A100 80GB PCIe, 81920, 61440, GPU-…``. Blank lines are
    skipped; a malformed line (wrong field count, non-integer index or memory) raises
    ``ValueError`` naming the line. A ``uuid`` the driver reports as not available becomes
    ``None``; memory fields must be integers (MiB, as ``nounits`` prints them).
    """
    gpus: list[GpuInfo] = []
    for line_no, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line:
            continue
        fields = [field.strip() for field in line.split(",")]
        if len(fields) != _FIELD_COUNT:
            raise ValueError(
                f"nvidia-smi line {line_no}: expected {_FIELD_COUNT} fields, got {len(fields)}: {line!r}"
            )
        index_s, name, total_s, used_s, uuid = fields
        if not name:
            raise ValueError(f"nvidia-smi line {line_no}: empty GPU name: {line!r}")
        gpus.append(
            GpuInfo(
                index=_int_field(index_s, "index", line_no, line),
                name=name,
                memory_total_mib=_int_field(total_s, "memory.total", line_no, line),
                memory_used_mib=_int_field(used_s, "memory.used", line_no, line),
                uuid=None if uuid in _NOT_AVAILABLE or not uuid else uuid,
            )
        )
    return gpus


class NvidiaSmiBackend:
    kind = "nvidia-smi"

    def list_gpus(self) -> list[GpuInfo]:
        """Run ``NVIDIA_SMI_ARGV`` (no shell, ``NVIDIA_SMI_TIMEOUT_S``) and parse.

        A missing binary, timeout, nonzero exit or unparseable output logs a warning and raises
        ``InventoryUnavailable``; the reason is its message.
        """
        argv = list(NVIDIA_SMI_ARGV)
        try:
            # Fixed argv, no shell, no client input anywhere near it.
            completed = subprocess.run(
                argv,
                capture_output=True,
                text=True,
                timeout=NVIDIA_SMI_TIMEOUT_S,
                check=False,
                stdin=subprocess.DEVNULL,
            )
        except FileNotFoundError:
            reason = "nvidia-smi not found on PATH"
        except OSError as error:
            reason = f"nvidia-smi could not be run ({error})"
        except subprocess.TimeoutExpired:
            reason = f"nvidia-smi did not finish within {NVIDIA_SMI_TIMEOUT_S:.0f} s"
        else:
            if completed.returncode != 0:
                stderr = (completed.stderr or "").strip() or "no stderr"
                reason = f"nvidia-smi exited with status {completed.returncode} ({stderr})"
            else:
                try:
                    return parse_nvidia_smi(completed.stdout or "")
                except ValueError as error:
                    reason = f"nvidia-smi output not understood ({error})"
        log.warning("%s; GPU inventory unavailable", reason)
        raise InventoryUnavailable(reason)


class FakeBackend:
    kind = "fake"

    def __init__(self, count: int) -> None:
        self.count = count

    def list_gpus(self) -> list[GpuInfo]:
        return [
            GpuInfo(
                index=i,
                name=FAKE_GPU_NAME,
                memory_total_mib=FAKE_GPU_MEMORY_MIB,
                memory_used_mib=0,
                uuid=f"GPU-FAKE-{i}",
            )
            for i in range(self.count)
        ]
