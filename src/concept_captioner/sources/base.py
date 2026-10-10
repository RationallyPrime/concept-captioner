"""Where samples come from and where captions go.

``ImageSource`` yields ``Sample`` objects; ``CaptionSink`` receives the caption and the receipt
for a sample id, and can say whether a sample already has a result (for resume).
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from typing import Any, Protocol, runtime_checkable

from ..types import Sample


@runtime_checkable
class ImageSource(Protocol):
    name: str

    async def samples(self) -> AsyncIterator[Sample]: ...

    async def count(self) -> int: ...


@runtime_checkable
class CaptionSink(Protocol):
    name: str

    async def existing(self, sample_id: str) -> tuple[str, dict[str, Any]] | None:
        """Return (caption, receipt) if this sample already has a committed result."""
        ...

    async def write_receipt(self, sample_id: str, receipt: dict[str, Any]) -> None: ...

    async def commit(self, sample_id: str, caption: str, receipt: dict[str, Any]) -> None: ...

    async def finalize(self) -> dict[str, Any]:
        """Flush anything buffered (e.g. push a dataset) and return a summary."""
        ...
