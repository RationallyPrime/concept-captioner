"""Where samples come from and where captions go.

``ImageSource`` yields ``Sample`` objects. ``CaptionSink`` receives a caption (or ``None`` for
a sample that produced none) and the response record for that sample, and can say whether a
sample already has a caption and what its record says.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from typing import Any, Protocol, runtime_checkable

from ..types import Sample


@runtime_checkable
class ImageSource(Protocol):
    name: str

    def samples(self) -> AsyncIterator[Sample]: ...

    async def count(self) -> int: ...


@runtime_checkable
class CaptionSink(Protocol):
    name: str

    async def exists(self, sample_id: str) -> bool:
        """True if this sample already has a caption."""
        ...

    async def record(self, sample_id: str) -> dict[str, Any] | None:
        """The stored response record for this sample, if any."""
        ...

    async def write(self, sample_id: str, caption: str | None, record: dict[str, Any]) -> None:
        """Store the caption (when there is one) and the record."""
        ...

    async def finalize(self) -> dict[str, Any]:
        """Flush anything buffered (e.g. push a dataset) and return a summary."""
        ...
