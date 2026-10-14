"""TensorBoard event-file summary: latest scalar per tag (POD-SPEC §2.7).

Two readers produce the same ``EventsSummary``:

* ``read_events_minimal``: the package's own tfrecord + protobuf decoder. It understands only
  the parts of ``Event`` / ``Summary`` / ``TensorProto`` that carry scalars, verifies no CRCs,
  and treats a truncated or corrupt trailing record (a file still being written) as the end of
  that file. It is always present, so the agent venv does not need TensorFlow-sized
  dependencies to answer the endpoint.
* ``tensorboard``'s ``EventAccumulator`` when the package is importable (the pod's agent venv
  has it; the test venv does not). Tensor summaries from that path are decoded by the same
  ``TensorProto`` decoder as the minimal reader, so both agree on what counts as a scalar.

``summarize_run`` picks the reader and folds every ``events.out.tfevents.*`` file under the
run's log directory, subdirectories included (ai-toolkit writes its native files to
``<log_dir>/<name>_<timestamp>/`` beside the wrapper's scraped file), into one timeline per
tag, oldest file first (mtime, then name). Within a tag's timeline the last point written is
the latest; a point whose step is below the step before it marks a restart (a trainer resumed
from a checkpoint opens a new event file and re-walks the steps after it), and the points at
or past that step belong to the dead attempt, so they are dropped. ``count`` is the number of
points the timeline keeps. ``last_step`` is the step of the most recently written scalar of any
tag (by wall time), so a resumed run reports progress as soon as it writes, not once it has
overtaken the crashed attempt. The tensorboard reader is per directory, so it runs once per
directory holding event files and the results fold into the same timelines.
"""

from __future__ import annotations

import bisect
import functools
import logging
import os
import re
import struct
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel

logger = logging.getLogger("podagent.events")

RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
EVENT_FILE_GLOB = "events.out.tfevents.*"

Reader = Literal["tensorboard", "minimal"]

# tfrecord framing: uint64 length, uint32 masked crc32c(length), data, uint32 masked crc32c(data)
_LENGTH = struct.Struct("<Q")
_CRC = struct.Struct("<I")
_DOUBLE = struct.Struct("<d")
_FLOAT = struct.Struct("<f")

# Protobuf wire types.
_WT_VARINT, _WT_FIXED64, _WT_LENGTH, _WT_FIXED32 = 0, 1, 2, 5

# Field numbers (tensorboard/compat/proto/{event,summary,tensor,types}.proto).
_EVENT_WALL_TIME, _EVENT_STEP, _EVENT_SUMMARY = 1, 2, 5
_SUMMARY_VALUE = 1
_VALUE_TAG, _VALUE_SIMPLE_VALUE, _VALUE_TENSOR = 1, 2, 8
_TENSOR_DTYPE, _TENSOR_CONTENT, _TENSOR_FLOAT_VAL, _TENSOR_DOUBLE_VAL = 1, 4, 5, 6
_DT_FLOAT, _DT_DOUBLE = 1, 2
_CONTENT_FORMATS: dict[int, struct.Struct] = {_DT_FLOAT: _FLOAT, _DT_DOUBLE: _DOUBLE}


class ScalarPoint(BaseModel):
    step: int
    value: float
    wall_time: float
    count: int


class EventsSummary(BaseModel):
    run_id: str
    logdir: str
    files: int
    scalars: dict[str, ScalarPoint]
    last_step: int | None
    last_wall_time: float | None
    reader: Reader


# --- tfrecord framing -------------------------------------------------------------------------


def iter_records(path: Path) -> Iterator[bytes]:
    """Yield the payload of each complete tfrecord in ``path``.

    Reading is sequential and bounded by the file size at open time; a record whose header
    claims more bytes than the file holds, or whose data/footer is cut short, ends the
    iteration silently (that is a file being written, or a crash mid-write). CRCs are read and
    ignored.
    """
    frame = _LENGTH.size + _CRC.size
    with path.open("rb") as handle:
        size = os.fstat(handle.fileno()).st_size
        while True:
            header = handle.read(frame)
            if len(header) < frame:
                return
            (length,) = _LENGTH.unpack_from(header)
            if length > size - handle.tell():
                return
            data = handle.read(length)
            footer = handle.read(_CRC.size)
            if len(data) < length or len(footer) < _CRC.size:
                return
            yield data


# --- protobuf decoding (only what carries scalars) --------------------------------------------


class _Corrupt(ValueError):
    """A message body that is not well-formed protobuf as far as this reader goes."""


def _read_varint(buf: bytes, pos: int) -> tuple[int, int]:
    result = 0
    shift = 0
    while True:
        if pos >= len(buf):
            raise _Corrupt("varint runs past the end of the message")
        byte = buf[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7
        if shift > 63:
            raise _Corrupt("varint longer than 10 bytes")


def _signed64(value: int) -> int:
    """A varint carrying an ``int64``: two's complement over 64 bits."""
    return value - (1 << 64) if value >= 1 << 63 else value


def _fields(buf: bytes) -> Iterator[tuple[int, int, Any]]:
    """Yield ``(field_number, wire_type, payload)``: an ``int`` for varints, ``bytes`` otherwise.

    Unknown fields are yielded like any other so callers skip them by not matching; groups
    (wire types 3 and 4, long deprecated and never written by TensorBoard) are corrupt.
    """
    pos, end = 0, len(buf)
    while pos < end:
        key, pos = _read_varint(buf, pos)
        number, wire = key >> 3, key & 0x7
        if wire == _WT_VARINT:
            value, pos = _read_varint(buf, pos)
            yield number, wire, value
            continue
        if wire == _WT_LENGTH:
            size, pos = _read_varint(buf, pos)
        elif wire == _WT_FIXED64:
            size = 8
        elif wire == _WT_FIXED32:
            size = 4
        else:
            raise _Corrupt(f"unsupported wire type {wire}")
        if pos + size > end:
            raise _Corrupt("field runs past the end of the message")
        yield number, wire, buf[pos : pos + size]
        pos += size


def decode_tensor_scalar(buf: bytes) -> float | None:
    """The single element of a serialized ``TensorProto``, or ``None`` if it is not one scalar.

    Accepts ``float_val`` / ``double_val`` (packed or not) and ``tensor_content`` for
    ``DT_FLOAT`` / ``DT_DOUBLE`` (a 4-byte ``tensor_content`` without a dtype is taken as a
    float). A tensor with zero or several elements is not a scalar.
    """
    dtype: int | None = None
    content: bytes | None = None
    elements: list[float] = []
    for number, wire, payload in _fields(buf):
        if number == _TENSOR_DTYPE and wire == _WT_VARINT:
            dtype = payload
        elif number == _TENSOR_CONTENT and wire == _WT_LENGTH:
            content = payload
        elif number in (_TENSOR_FLOAT_VAL, _TENSOR_DOUBLE_VAL):
            fmt = _FLOAT if number == _TENSOR_FLOAT_VAL else _DOUBLE
            if wire == _WT_LENGTH:  # packed repeated
                elements.extend(
                    v[0] for v in fmt.iter_unpack(payload[: len(payload) - len(payload) % fmt.size])
                )
            elif wire in (_WT_FIXED32, _WT_FIXED64) and len(payload) == fmt.size:
                elements.append(fmt.unpack(payload)[0])
    if len(elements) == 1:
        return float(elements[0])
    if elements or content is None:
        return None
    fmt = _CONTENT_FORMATS.get(dtype) if dtype is not None else _FLOAT
    if fmt is None or len(content) != fmt.size:
        return None
    return float(fmt.unpack(content)[0])


def _decode_value(buf: bytes) -> tuple[str, float] | None:
    """``(tag, value)`` of a ``Summary.Value`` carrying a scalar, else ``None``."""
    tag = ""
    value: float | None = None
    for number, wire, payload in _fields(buf):
        if number == _VALUE_TAG and wire == _WT_LENGTH:
            tag = payload.decode("utf-8", errors="replace")
        elif number == _VALUE_SIMPLE_VALUE and wire == _WT_FIXED32:
            value = float(_FLOAT.unpack(payload)[0])
        elif number == _VALUE_TENSOR and wire == _WT_LENGTH:
            decoded = decode_tensor_scalar(payload)
            if decoded is not None:
                value = decoded
    if not tag or value is None:
        return None
    return tag, value


def _decode_event(buf: bytes) -> tuple[float, int, list[tuple[str, float]]]:
    """``(wall_time, step, [(tag, value), ...])`` of a serialized ``Event``."""
    wall_time = 0.0
    step = 0
    scalars: list[tuple[str, float]] = []
    for number, wire, payload in _fields(buf):
        if number == _EVENT_WALL_TIME and wire == _WT_FIXED64:
            wall_time = _DOUBLE.unpack(payload)[0]
        elif number == _EVENT_STEP and wire == _WT_VARINT:
            step = _signed64(payload)
        elif number == _EVENT_SUMMARY and wire == _WT_LENGTH:
            for snumber, swire, spayload in _fields(payload):
                if snumber == _SUMMARY_VALUE and swire == _WT_LENGTH:
                    scalar = _decode_value(spayload)
                    if scalar is not None:
                        scalars.append(scalar)
    return wall_time, step, scalars


# --- per-tag accumulation ---------------------------------------------------------------------


@dataclass(slots=True)
class _TagState:
    """One tag's timeline: its latest point and the steps of every point it keeps.

    ``steps`` is non-decreasing: a point is appended with a step at or above the latest one,
    or it is a restart and the steps at or past it are cut first.
    """

    step: int
    value: float
    wall_time: float
    steps: list[int]


def _absorb(
    state: dict[str, _TagState], tag: str, step: int, value: float, wall_time: float
) -> None:
    """One scalar point, in writing order: it becomes the tag's latest.

    A step below the previous one is a restart (a resume from a checkpoint re-walks the steps
    after it, in a new file or the same one): the points at or past ``step`` belonged to the
    attempt that died, so they leave the count. Equal steps keep both points; the later wins.
    """
    current = state.get(tag)
    if current is None:
        state[tag] = _TagState(step, value, wall_time, [step])
        return
    if step < current.step:
        del current.steps[bisect.bisect_left(current.steps, step) :]
    current.steps.append(step)
    current.step, current.value, current.wall_time = step, value, wall_time


def _finish(state: dict[str, _TagState]) -> dict[str, ScalarPoint]:
    return {
        tag: ScalarPoint(step=s.step, value=s.value, wall_time=s.wall_time, count=len(s.steps))
        for tag, s in state.items()
    }


def _absorb_file(state: dict[str, _TagState], path: Path) -> None:
    """Fold one event file's scalars into ``state`` with the minimal reader.

    Records: ``uint64 length, uint32 masked_crc(length), bytes, uint32 masked_crc(data)``.
    ``Event``: field 1 ``wall_time`` (double), 2 ``step`` (int64), 5 ``summary``.
    ``Summary.value`` (field 1, repeated): ``tag`` (1), ``simple_value`` (2, float),
    ``tensor`` (8; float dtype, one element in ``float_val``/``tensor_content``).
    A truncated trailing record ends the read without error; so does a record whose body is
    not protobuf (everything after it is garbage too, since CRCs are not verified).
    """
    for data in iter_records(path):
        try:
            wall_time, step, scalars = _decode_event(data)
        except _Corrupt as error:
            logger.debug("%s: stopping at a corrupt record (%s)", path, error)
            break
        for tag, value in scalars:
            _absorb(state, tag, step, value, wall_time)


def read_events_minimal(path: Path) -> dict[str, ScalarPoint]:
    """Latest scalar per tag from one event file, with the package's own reader."""
    state: dict[str, _TagState] = {}
    _absorb_file(state, path)
    return _finish(state)


# --- run summary ------------------------------------------------------------------------------


def _sort_key(path: Path) -> tuple[int, str]:
    try:
        mtime = path.stat().st_mtime_ns
    except OSError:  # vanished between glob and stat: sort it first, it will be skipped
        mtime = 0
    return mtime, path.name


def list_event_files(logdir: Path) -> list[Path]:
    """Event files under ``logdir`` and its subdirectories, oldest first (mtime, then name).

    Recursive because trainers nest their native files: ai-toolkit writes to
    ``<log_dir>/<name>_<timestamp>/`` while the wrapper's scraper writes to ``<log_dir>``
    itself. ``[]`` if ``logdir`` is missing.
    """
    if not logdir.is_dir():
        return []
    return sorted((p for p in logdir.rglob(EVENT_FILE_GLOB) if p.is_file()), key=_sort_key)


def event_dirs(files: list[Path]) -> list[Path]:
    """The distinct directories of ``files`` (oldest first), each placed by its newest file.

    ``EventAccumulator`` reads one directory, so the tensorboard path reads these in turn and
    merges; the order makes the directory with the newest file win ties on step, as the
    minimal reader's per-file order does.
    """
    ordered: dict[Path, None] = {}
    for path in files:  # oldest first: re-inserting moves a directory to the end
        ordered.pop(path.parent, None)
        ordered[path.parent] = None
    return list(ordered)


@dataclass(frozen=True)
class TensorboardApi:
    """The slice of ``tensorboard`` the summary uses. Tests inject a fake through ``_load``."""

    EventAccumulator: Any
    SCALARS: str = "scalars"
    TENSORS: str = "tensors"


@functools.cache
def _load_tensorboard() -> TensorboardApi | None:
    """``tensorboard``'s event accumulator when importable, else ``None`` (decided once)."""
    try:
        from tensorboard.backend.event_processing import event_accumulator as ea
    except Exception as error:  # ImportError, or a broken install: the minimal reader serves
        logger.info("tensorboard reader unavailable (%s); using the minimal reader", error)
        return None
    return TensorboardApi(
        EventAccumulator=ea.EventAccumulator, SCALARS=ea.SCALARS, TENSORS=ea.TENSORS
    )


def _read_with_tensorboard(logdir: Path, api: TensorboardApi, state: dict[str, _TagState]) -> None:
    """Fold every scalar under ``logdir`` into ``state`` through ``EventAccumulator``.

    Files in one directory are read in name order. ``size_guidance`` 0 keeps every point (the
    default reservoir would cap counts) and ``purge_orphaned_data=False`` leaves restarts to
    ``_absorb``, which handles them per tag (the accumulator's own purge is across tags, and
    the tag-by-tag read here would make that purge eat one tag's resumed points with another's).
    TF2-style tensor summaries are decoded from the proto bytes by ``decode_tensor_scalar``.
    """
    accumulator = api.EventAccumulator(
        str(logdir),
        size_guidance={api.SCALARS: 0, api.TENSORS: 0},
        purge_orphaned_data=False,
    )
    accumulator.Reload()
    tags = accumulator.Tags()
    for tag in tags.get(api.SCALARS, ()):
        for event in accumulator.Scalars(tag):
            _absorb(state, tag, int(event.step), float(event.value), float(event.wall_time))
    for tag in tags.get(api.TENSORS, ()):
        for event in accumulator.Tensors(tag):
            value = decode_tensor_scalar(event.tensor_proto.SerializeToString())
            if value is not None:
                _absorb(state, tag, int(event.step), value, float(event.wall_time))


def _latest(scalars: dict[str, ScalarPoint]) -> ScalarPoint | None:
    """The most recently written point of any tag (wall time, then step)."""
    if not scalars:
        return None
    return max(scalars.values(), key=lambda p: (p.wall_time, p.step))


def summarize_run(run_id: str, logdir: Path) -> EventsSummary:
    """Fold every event file under ``logdir``, recursively, oldest file first.

    Uses ``tensorboard``'s ``EventAccumulator`` (one per directory holding event files) when
    importable, else the minimal reader; if the tensorboard reader fails on any directory,
    the minimal reader answers for the whole run instead.
    ``logdir`` missing is the caller's 404; this function returns an empty summary for a
    missing or empty directory alike.
    """
    files = list_event_files(logdir)
    api = _load_tensorboard()
    reader: Reader = "minimal" if api is None else "tensorboard"
    state: dict[str, _TagState] = {}
    if files and api is not None:
        try:
            for directory in event_dirs(files):
                _read_with_tensorboard(directory, api, state)
        except Exception:
            logger.warning(
                "tensorboard reader failed on %s; using the minimal reader", logdir, exc_info=True
            )
            reader, api = "minimal", None
            state = {}
    if files and api is None:
        for path in files:
            try:
                _absorb_file(state, path)
            except OSError as error:  # removed while we were reading the directory
                logger.warning("skipping event file %s: %s", path, error)
    scalars = _finish(state)
    latest = _latest(scalars)
    return EventsSummary(
        run_id=run_id,
        logdir=str(logdir),
        files=len(files),
        scalars=scalars,
        last_step=None if latest is None else latest.step,
        last_wall_time=None if latest is None else latest.wall_time,
        reader=reader,
    )
