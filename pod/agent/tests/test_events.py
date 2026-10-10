"""Events reader (POD-SPEC §2.7): the minimal tfrecord/protobuf reader, the run summary, and
``GET /runs/{id}/events``.

The encoder below is hand-written so the tests carry no tensorboard dependency. It produces
real masked CRC32C footers so the same files also satisfy TensorBoard's own reader (which
verifies them) in the optional parity test.
"""

from __future__ import annotations

import os
import struct
from pathlib import Path
from types import SimpleNamespace

import pytest

from podagent import events
from podagent.events import (
    EventsSummary,
    ScalarPoint,
    decode_tensor_scalar,
    iter_records,
    list_event_files,
    read_events_minimal,
    summarize_run,
)

# --- encoder helpers ---------------------------------------------------------------------------

DT_FLOAT, DT_DOUBLE = 1, 2
T0 = 1760097600.0

_CRC32C_TABLE: list[int] = []
for _i in range(256):
    _crc = _i
    for _ in range(8):
        _crc = (_crc >> 1) ^ 0x82F63B78 if _crc & 1 else _crc >> 1
    _CRC32C_TABLE.append(_crc)


def crc32c(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for byte in data:
        crc = _CRC32C_TABLE[(crc ^ byte) & 0xFF] ^ (crc >> 8)
    return crc ^ 0xFFFFFFFF


def masked_crc(data: bytes) -> int:
    crc = crc32c(data)
    rotated = ((crc >> 15) | (crc << 17)) & 0xFFFFFFFF
    return (rotated + 0xA282EAD8) & 0xFFFFFFFF


def varint(value: int) -> bytes:
    if value < 0:
        value += 1 << 64
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def key(field: int, wire: int) -> bytes:
    return varint((field << 3) | wire)


def f_varint(field: int, value: int) -> bytes:
    return key(field, 0) + varint(value)


def f_fixed64(field: int, value: float) -> bytes:
    return key(field, 1) + struct.pack("<d", value)


def f_fixed32(field: int, value: float) -> bytes:
    return key(field, 5) + struct.pack("<f", value)


def f_bytes(field: int, payload: bytes) -> bytes:
    return key(field, 2) + varint(len(payload)) + payload


def tensor_proto(
    *,
    dtype: int | None = DT_FLOAT,
    float_val: list[float] | None = None,
    packed: bool = True,
    double_val: list[float] | None = None,
    content: bytes | None = None,
) -> bytes:
    out = b""
    if dtype is not None:
        out += f_varint(1, dtype)
    out += f_bytes(2, b"")  # tensor_shape: no dims, a scalar
    if content is not None:
        out += f_bytes(4, content)
    if float_val is not None:
        if packed:
            out += f_bytes(5, b"".join(struct.pack("<f", v) for v in float_val))
        else:
            out += b"".join(f_fixed32(5, v) for v in float_val)
    if double_val is not None:
        if packed:
            out += f_bytes(6, b"".join(struct.pack("<d", v) for v in double_val))
        else:
            out += b"".join(key(6, 1) + struct.pack("<d", v) for v in double_val)
    return out


def simple(tag: str, value: float) -> bytes:
    """``Summary.Value`` with ``simple_value`` (what torch's SummaryWriter writes)."""
    return f_bytes(1, tag.encode()) + f_fixed32(2, value)


def tensor(tag: str, proto: bytes) -> bytes:
    """``Summary.Value`` with a ``tensor`` (what ``tf.summary.scalar`` writes)."""
    return f_bytes(1, tag.encode()) + f_bytes(8, proto)


def event(wall_time: float, step: int, *values: bytes) -> bytes:
    summary = b"".join(f_bytes(1, v) for v in values)
    return f_fixed64(1, wall_time) + f_varint(2, step) + f_bytes(5, summary)


def file_version_event() -> bytes:
    return f_fixed64(1, T0) + f_bytes(3, b"brain.Event:2")


def record(data: bytes, *, bad_crc: bool = False) -> bytes:
    length = struct.pack("<Q", len(data))
    if bad_crc:
        return length + b"\0\0\0\0" + data + b"\0\0\0\0"
    return (
        length + struct.pack("<I", masked_crc(length)) + data + struct.pack("<I", masked_crc(data))
    )


def write_event_file(
    path: Path,
    *events_: bytes,
    trailing: bytes = b"",
    bad_crc: bool = False,
    mtime: float | None = None,
) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    body = record(file_version_event(), bad_crc=bad_crc)
    body += b"".join(record(e, bad_crc=bad_crc) for e in events_)
    path.write_bytes(body + trailing)
    if mtime is not None:
        os.utime(path, (mtime, mtime))
    return path


def loss_curve(start: int, stop: int, value_at: float, *, t0: float = T0) -> list[bytes]:
    """``loss`` events for steps ``start..stop`` whose final value is ``value_at``.

    Wall times are ``t0 + step``; a resumed attempt passes a later ``t0`` so its records are
    newer in time than the crashed attempt's at the same steps.
    """
    return [
        event(t0 + step, step, simple("loss", value_at if step == stop else 1.0 / step))
        for step in range(start, stop + 1)
    ]


@pytest.fixture
def minimal_only(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(events, "_load_tensorboard", lambda: None)


# --- helper sanity -----------------------------------------------------------------------------


def test_crc32c_known_vector() -> None:
    assert crc32c(b"123456789") == 0xE3069283
    assert masked_crc(b"") == (((0 >> 15) | (0 << 17)) + 0xA282EAD8) & 0xFFFFFFFF


def test_varint_round_trips_through_the_reader() -> None:
    for value in (0, 1, 127, 128, 300, 1 << 31, (1 << 63) - 1):
        assert events._read_varint(varint(value), 0) == (value, len(varint(value)))
    assert events._signed64(events._read_varint(varint(-1), 0)[0]) == -1


# --- tfrecord framing --------------------------------------------------------------------------


def test_iter_records_yields_each_payload(tmp_path: Path) -> None:
    path = write_event_file(tmp_path / "events.out.tfevents.1.h.1.0", b"abc", b"")
    assert list(iter_records(path)) == [file_version_event(), b"abc", b""]


def test_iter_records_ignores_truncated_tail(tmp_path: Path) -> None:
    good = event(T0, 1, simple("loss", 0.5))
    # header claims 100 bytes, only 10 follow
    tail = struct.pack("<Q", 100) + b"\0\0\0\0" + b"0123456789"
    path = write_event_file(tmp_path / "events.out.tfevents.1.h.1.0", good, trailing=tail)
    assert list(iter_records(path)) == [file_version_event(), good]
    # a partial header
    path = write_event_file(tmp_path / "events.out.tfevents.2.h.1.0", good, trailing=b"\x05\0\0")
    assert list(iter_records(path)) == [file_version_event(), good]
    # a complete record body with its footer cut short
    cut = record(good)[:-2]
    path = write_event_file(tmp_path / "events.out.tfevents.3.h.1.0", trailing=cut)
    assert list(iter_records(path)) == [file_version_event()]
    # an empty file
    empty = tmp_path / "events.out.tfevents.4.h.1.0"
    empty.write_bytes(b"")
    assert list(iter_records(empty)) == []


# --- minimal reader ----------------------------------------------------------------------------


def test_minimal_reader_simple_value(tmp_path: Path) -> None:
    path = write_event_file(
        tmp_path / "events.out.tfevents.1.h.1.0",
        *loss_curve(1, 5, 0.25),
        event(T0 + 1, 1, simple("learning_rate", 1e-4)),
        event(T0 + 5, 5, simple("learning_rate", 1e-4)),
    )
    latest = read_events_minimal(path)
    assert set(latest) == {"loss", "learning_rate"}
    loss = latest["loss"]
    assert isinstance(loss, ScalarPoint)
    assert loss.step == 5 and loss.count == 5
    assert loss.value == pytest.approx(0.25)
    assert loss.wall_time == pytest.approx(T0 + 5)
    lr = latest["learning_rate"]
    assert (lr.step, lr.count) == (5, 2)
    assert lr.value == pytest.approx(1e-4) and lr.wall_time == pytest.approx(T0 + 5)


def test_minimal_reader_restart_within_a_file_drops_orphaned_points(tmp_path: Path) -> None:
    # A trainer resumed from step 3 after reaching step 6, in the same file: the live point is
    # the last one written (step 4), and steps 3..6 of the dead attempt leave the count.
    path = write_event_file(
        tmp_path / "events.out.tfevents.1.h.1.0",
        *loss_curve(1, 6, 0.6),
        *loss_curve(3, 4, 0.4, t0=T0 + 100),
    )
    loss = read_events_minimal(path)["loss"]
    assert loss.step == 4 and loss.value == pytest.approx(0.4) and loss.count == 4
    assert loss.wall_time == pytest.approx(T0 + 104)


def test_minimal_reader_same_step_later_record_wins(tmp_path: Path) -> None:
    path = write_event_file(
        tmp_path / "events.out.tfevents.1.h.1.0",
        event(T0, 7, simple("loss", 1.0)),
        event(T0 + 1, 7, simple("loss", 2.0)),
    )
    loss = read_events_minimal(path)["loss"]
    assert loss.step == 7 and loss.value == 2.0 and loss.wall_time == T0 + 1 and loss.count == 2


def test_minimal_reader_tensor_encodings(tmp_path: Path) -> None:
    path = write_event_file(
        tmp_path / "events.out.tfevents.1.h.1.0",
        event(
            T0,
            3,
            tensor("packed", tensor_proto(float_val=[0.125])),
            tensor("unpacked", tensor_proto(float_val=[0.25], packed=False)),
            tensor("content_f32", tensor_proto(content=struct.pack("<f", 0.375))),
            tensor(
                "content_f32_no_dtype", tensor_proto(dtype=None, content=struct.pack("<f", 0.5))
            ),
            tensor("content_f64", tensor_proto(dtype=DT_DOUBLE, content=struct.pack("<d", 0.625))),
            tensor("double_val", tensor_proto(dtype=DT_DOUBLE, double_val=[0.75])),
            tensor(
                "double_val_unpacked",
                tensor_proto(dtype=DT_DOUBLE, double_val=[0.875], packed=False),
            ),
        ),
    )
    latest = read_events_minimal(path)
    assert {tag: p.value for tag, p in latest.items()} == {
        "packed": 0.125,
        "unpacked": 0.25,
        "content_f32": 0.375,
        "content_f32_no_dtype": 0.5,
        "content_f64": 0.625,
        "double_val": 0.75,
        "double_val_unpacked": 0.875,
    }
    assert all(p.step == 3 and p.count == 1 for p in latest.values())


def test_decode_tensor_scalar_rejects_non_scalars() -> None:
    assert decode_tensor_scalar(tensor_proto(float_val=[1.0, 2.0])) is None
    assert decode_tensor_scalar(tensor_proto(float_val=[1.0, 2.0], packed=False)) is None
    assert decode_tensor_scalar(tensor_proto(content=struct.pack("<ff", 1.0, 2.0))) is None
    assert decode_tensor_scalar(tensor_proto(float_val=[])) is None
    assert decode_tensor_scalar(tensor_proto()) is None
    # an int32 tensor_content is not a float scalar this reader reports
    assert decode_tensor_scalar(tensor_proto(dtype=3, content=struct.pack("<i", 7))) is None
    # unpacked double_val that is actually two values is not a scalar either
    assert decode_tensor_scalar(tensor_proto(double_val=[1.0, 2.0], packed=False)) is None


def test_minimal_reader_skips_what_is_not_a_scalar(tmp_path: Path) -> None:
    image = f_bytes(1, b"samples/0") + f_bytes(
        4, f_varint(1, 64) + f_varint(2, 64) + f_bytes(4, b"PNG")
    )
    untagged = f_fixed32(2, 1.0)
    with_metadata = simple("tagged", 2.0) + f_bytes(9, f_bytes(1, f_bytes(1, b"scalars")))
    multi = tensor("vector", tensor_proto(float_val=[1.0, 2.0, 3.0]))
    unknown_event_field = (
        f_fixed64(1, T0)
        + f_varint(2, 9)
        + f_bytes(12, b"future")
        + f_bytes(5, f_bytes(1, simple("loss", 0.5)))
    )
    path = write_event_file(
        tmp_path / "events.out.tfevents.1.h.1.0",
        event(T0, 1, image, untagged, with_metadata, multi),
        f_bytes(3, b"brain.Event:2"),  # a second file_version record: no scalars
        unknown_event_field,
    )
    latest = read_events_minimal(path)
    assert set(latest) == {"tagged", "loss"}
    assert latest["tagged"].step == 1 and latest["tagged"].value == 2.0
    assert latest["loss"].step == 9 and latest["loss"].value == 0.5


def test_minimal_reader_does_not_verify_crcs(tmp_path: Path) -> None:
    path = write_event_file(
        tmp_path / "events.out.tfevents.1.h.1.0", event(T0, 2, simple("loss", 0.5)), bad_crc=True
    )
    assert read_events_minimal(path)["loss"].step == 2


def test_minimal_reader_stops_at_a_corrupt_record(tmp_path: Path) -> None:
    group = key(1, 3) + b"\xff\xff"  # wire type 3 (start group): not something an Event holds
    path = write_event_file(
        tmp_path / "events.out.tfevents.1.h.1.0",
        event(T0, 1, simple("loss", 0.5)),
        group,
        event(T0, 2, simple("loss", 0.25)),
    )
    loss = read_events_minimal(path)["loss"]
    assert loss.step == 1 and loss.count == 1
    # a length-delimited field that overruns its message is corrupt as well
    overrun = key(5, 2) + varint(200) + b"short"
    path = write_event_file(tmp_path / "events.out.tfevents.2.h.1.0", overrun)
    assert read_events_minimal(path) == {}


def test_minimal_reader_large_and_default_fields(tmp_path: Path) -> None:
    big_step = (1 << 40) + 3
    path = write_event_file(
        tmp_path / "events.out.tfevents.1.h.1.0",
        event(T0, big_step, simple("loss", 0.5)),
        f_bytes(5, f_bytes(1, simple("bare", 1.5))),  # no wall_time, no step: proto3 defaults
    )
    latest = read_events_minimal(path)
    assert latest["loss"].step == big_step
    assert latest["bare"] == ScalarPoint(step=0, value=1.5, wall_time=0.0, count=1)


def test_minimal_reader_truncated_tail_keeps_earlier_points(tmp_path: Path) -> None:
    partial = record(event(T0 + 3, 3, simple("loss", 0.1)))[:-7]
    path = write_event_file(
        tmp_path / "events.out.tfevents.1.h.1.0", *loss_curve(1, 2, 0.2), trailing=partial
    )
    loss = read_events_minimal(path)["loss"]
    assert loss.step == 2 and loss.value == pytest.approx(0.2) and loss.count == 2


# --- summarize_run -----------------------------------------------------------------------------


def test_list_event_files_oldest_first(tmp_path: Path) -> None:
    newer = write_event_file(tmp_path / "events.out.tfevents.1.h.1.0", mtime=T0 + 100)
    older = write_event_file(tmp_path / "events.out.tfevents.2.h.1.0", mtime=T0)
    (tmp_path / "trainer.log").write_text("not an event file\n")
    (tmp_path / "events.out.tfevents.3.h.1.0").mkdir()  # a directory with the name: skipped
    assert list_event_files(tmp_path) == [older, newer]
    assert list_event_files(tmp_path / "missing") == []


def test_list_event_files_is_recursive(tmp_path: Path) -> None:
    """ai-toolkit writes natively to ``<log_dir>/<name>_<timestamp>/``; the scraper to ``<log_dir>``."""
    scraped = write_event_file(tmp_path / "events.out.tfevents.1.pod.1.0.scraped", mtime=T0)
    native = write_event_file(
        tmp_path / "nora7-h3-001_20261010-120000" / "events.out.tfevents.2.pod.1.0", mtime=T0 + 5
    )
    deeper = write_event_file(tmp_path / "a" / "b" / "events.out.tfevents.3.pod.1.0", mtime=T0 + 1)
    assert list_event_files(tmp_path) == [scraped, deeper, native]
    assert events.event_dirs([scraped, deeper, native]) == [tmp_path, deeper.parent, native.parent]
    # a directory's place is that of its newest file
    later = write_event_file(tmp_path / "events.out.tfevents.4.pod.1.0", mtime=T0 + 9)
    assert events.event_dirs(list_event_files(tmp_path)) == [deeper.parent, native.parent, tmp_path]
    assert later in list_event_files(tmp_path)


def test_summarize_run_reads_nested_native_files(tmp_path: Path, minimal_only: None) -> None:
    """The finding: native scalars under ``<log_dir>/<name>_<timestamp>/`` reach the summary."""
    logdir = tmp_path / "tensorboard"
    write_event_file(
        logdir / "events.out.tfevents.1.pod.1.0.scraped",
        event(T0 + 100, 100, simple("scraped/loss", 0.5), simple("scraped/lr", 1e-4)),
        mtime=T0,
    )
    write_event_file(
        logdir / "nora7-h3-001_20261010-120000" / "events.out.tfevents.2.pod.1.0",
        *loss_curve(1, 120, 0.12),
        event(T0 + 120, 120, simple("lr", 1e-4)),
        mtime=T0 + 60,
    )
    summary = summarize_run("nora7-h3-001", logdir)
    assert summary.files == 2
    assert set(summary.scalars) == {"scraped/loss", "scraped/lr", "loss", "lr"}
    assert summary.scalars["loss"].step == 120 and summary.scalars["loss"].count == 120
    assert summary.scalars["loss"].value == pytest.approx(0.12)
    assert summary.scalars["scraped/loss"].step == 100
    assert summary.last_step == 120


def test_summarize_run_merges_files_newest_wins_ties(tmp_path: Path, minimal_only: None) -> None:
    logdir = tmp_path / "tensorboard"
    write_event_file(
        logdir / "events.out.tfevents.1.h.1.0",
        *loss_curve(1, 10, 1.0),
        event(T0, 10, simple("old_only", 1.0)),
        mtime=T0,
    )
    write_event_file(
        logdir / "events.out.tfevents.2.h.1.0",
        *loss_curve(5, 10, 2.0),
        event(T0, 5, simple("new_only", 2.0)),
        mtime=T0 + 60,
    )
    summary = summarize_run("nora7-h3-001", logdir)
    assert isinstance(summary, EventsSummary)
    assert summary.run_id == "nora7-h3-001"
    assert summary.logdir == str(logdir)
    assert summary.files == 2
    assert summary.reader == "minimal"
    assert summary.last_step == 10
    loss = summary.scalars["loss"]
    # the second file re-walks steps 5..10: the first file's 5..10 are orphaned, 1..4 remain
    assert loss.step == 10 and loss.value == pytest.approx(2.0) and loss.count == 10
    assert summary.scalars["old_only"].count == 1 and summary.scalars["new_only"].count == 1


def test_summarize_run_resumed_file_wins_over_the_crashed_attempt(
    tmp_path: Path, minimal_only: None
) -> None:
    """The finding: a trainer that crashed at step 1200 and resumed from the step-1000
    checkpoint opens a new file; while it is at step 1150 the summary must say 1150 with the
    resumed file's wall time, not the dead attempt's 1200, and count 1150 points, not 1350."""
    logdir = tmp_path / "tensorboard"
    write_event_file(
        logdir / "events.out.tfevents.1.pod.1.0.scraped",
        *loss_curve(1, 1200, 0.12),
        event(T0 + 1000, 1000, simple("samples", 1.0)),
        mtime=T0 + 1200,
    )
    write_event_file(
        logdir / "events.out.tfevents.2.pod.2.0.scraped",
        *loss_curve(1001, 1150, 0.115, t0=T0 + 3600),
        mtime=T0 + 3600 + 1150,
    )
    summary = summarize_run("ivan9-ltx-001", logdir)
    loss = summary.scalars["loss"]
    assert loss.step == 1150 and loss.value == pytest.approx(0.115)
    assert loss.wall_time == pytest.approx(T0 + 3600 + 1150)
    assert loss.count == 1150
    assert summary.last_step == 1150
    assert summary.last_wall_time == pytest.approx(T0 + 3600 + 1150)
    # a tag the resumed attempt has not written yet keeps its point; it does not pin last_step
    assert summary.scalars["samples"].step == 1000 and summary.scalars["samples"].count == 1


def test_summarize_run_last_step_follows_the_newest_write(
    tmp_path: Path, minimal_only: None
) -> None:
    """A rarely logged tag from before the crash (step 1200) sits above the resumed loss (1050);
    ``last_step`` is where the trainer is now, which is what was written last."""
    logdir = tmp_path / "tensorboard"
    write_event_file(
        logdir / "events.out.tfevents.1.pod.1.0",
        *loss_curve(1, 1200, 0.12),
        event(T0 + 1200.5, 1200, simple("samples", 1.0)),
        mtime=T0 + 1200,
    )
    write_event_file(
        logdir / "events.out.tfevents.2.pod.2.0",
        *loss_curve(1001, 1050, 0.105, t0=T0 + 3600),
        mtime=T0 + 3600 + 1050,
    )
    summary = summarize_run("nora7-h3-001", logdir)
    assert summary.scalars["samples"].step == 1200
    assert summary.scalars["loss"].step == 1050
    assert summary.last_step == 1050
    assert summary.last_wall_time == pytest.approx(T0 + 3600 + 1050)
    # before the resumed attempt writes anything, the crashed attempt's point is still the latest
    write_event_file(logdir / "events.out.tfevents.3.pod.3.0", mtime=T0 + 7200)
    summary = summarize_run("nora7-h3-001", logdir)
    assert summary.files == 3 and summary.last_step == 1050


def test_summarize_run_newest_by_mtime_not_name(tmp_path: Path, minimal_only: None) -> None:
    logdir = tmp_path / "tensorboard"
    write_event_file(
        logdir / "events.out.tfevents.9.h.1.0", event(T0, 1, simple("loss", 9.0)), mtime=T0
    )
    write_event_file(
        logdir / "events.out.tfevents.1.h.1.0", event(T0, 1, simple("loss", 1.0)), mtime=T0 + 60
    )
    assert summarize_run("nora7", logdir).scalars["loss"].value == 1.0


def test_summarize_run_empty_and_missing_logdir(tmp_path: Path, minimal_only: None) -> None:
    logdir = tmp_path / "tensorboard"
    logdir.mkdir()
    (logdir / "notes.txt").write_text("not events\n")
    for candidate in (logdir, tmp_path / "absent"):
        summary = summarize_run("nora7", candidate)
        assert summary.files == 0
        assert summary.scalars == {}
        assert summary.last_step is None
        assert summary.reader == "minimal"
        assert summary.logdir == str(candidate)


def test_summarize_run_tolerates_a_truncated_file_among_good_ones(
    tmp_path: Path, minimal_only: None
) -> None:
    logdir = tmp_path / "tensorboard"
    write_event_file(logdir / "events.out.tfevents.1.h.1.0", *loss_curve(1, 3, 0.3), mtime=T0)
    write_event_file(
        logdir / "events.out.tfevents.2.h.1.0",
        trailing=struct.pack("<Q", 5000) + b"\0\0\0\0garbage",
        mtime=T0 + 60,
    )
    summary = summarize_run("nora7", logdir)
    assert summary.files == 2 and summary.scalars["loss"].step == 3 and summary.last_step == 3


# --- the tensorboard path, with a fake accumulator ---------------------------------------------


class FakeAccumulator:
    """Stands in for ``tensorboard``'s ``EventAccumulator`` (same surface the summary uses)."""

    instances: list[FakeAccumulator] = []

    def __init__(self, path: str, size_guidance=None, purge_orphaned_data=True) -> None:
        self.path = path
        self.size_guidance = size_guidance
        self.purge_orphaned_data = purge_orphaned_data
        self.reloaded = False
        FakeAccumulator.instances.append(self)

    def Reload(self) -> FakeAccumulator:
        self.reloaded = True
        return self

    def Tags(self) -> dict[str, list[str]]:
        return {"scalars": ["loss"], "tensors": ["lr", "samples/0"], "images": ["samples/0"]}

    def Scalars(self, tag: str) -> list[SimpleNamespace]:
        assert tag == "loss"
        return [
            SimpleNamespace(wall_time=T0 + 1, step=1, value=0.5),
            SimpleNamespace(wall_time=T0 + 2, step=2, value=0.25),
        ]

    def Tensors(self, tag: str) -> list[SimpleNamespace]:
        proto = {
            "lr": tensor_proto(float_val=[1e-4]),
            "samples/0": tensor_proto(dtype=7, content=b"PNG..."),  # a string tensor: not a scalar
        }[tag]
        serialized = SimpleNamespace(SerializeToString=lambda: proto)
        return [SimpleNamespace(wall_time=T0 + 2, step=2, tensor_proto=serialized)]


class BrokenAccumulator:
    def __init__(self, *args, **kwargs) -> None:
        raise RuntimeError("no protobuf runtime")


@pytest.fixture
def fake_tensorboard(monkeypatch: pytest.MonkeyPatch) -> None:
    FakeAccumulator.instances.clear()
    api = events.TensorboardApi(EventAccumulator=FakeAccumulator)
    monkeypatch.setattr(events, "_load_tensorboard", lambda: api)


def test_summarize_run_uses_tensorboard_when_available(
    tmp_path: Path, fake_tensorboard: None
) -> None:
    logdir = tmp_path / "tensorboard"
    write_event_file(logdir / "events.out.tfevents.1.h.1.0", event(T0, 1, simple("loss", 0.5)))
    summary = summarize_run("nora7", logdir)
    assert summary.reader == "tensorboard"
    assert summary.files == 1
    assert set(summary.scalars) == {"loss", "lr"}  # the string tensor is not a scalar
    assert summary.scalars["loss"] == ScalarPoint(step=2, value=0.25, wall_time=T0 + 2, count=2)
    lr = summary.scalars["lr"]
    assert (lr.step, lr.count, lr.wall_time) == (2, 1, T0 + 2)
    assert lr.value == pytest.approx(1e-4)
    assert summary.last_step == 2
    (accumulator,) = FakeAccumulator.instances
    assert accumulator.path == str(logdir)
    assert accumulator.reloaded
    assert accumulator.size_guidance == {"scalars": 0, "tensors": 0}
    assert accumulator.purge_orphaned_data is False


def test_summarize_run_tensorboard_reads_each_directory(
    tmp_path: Path, fake_tensorboard: None
) -> None:
    """``EventAccumulator`` is single-directory: one per directory, oldest directory first."""
    logdir = tmp_path / "tensorboard"
    nested = logdir / "nora7-h3-001_20261010-120000"
    write_event_file(
        nested / "events.out.tfevents.1.pod.1.0", event(T0, 1, simple("loss", 0.5)), mtime=T0
    )
    write_event_file(
        logdir / "events.out.tfevents.2.pod.1.0.scraped",
        event(T0, 1, simple("scraped/loss", 0.5)),
        mtime=T0 + 60,
    )
    summary = summarize_run("nora7", logdir)
    assert summary.reader == "tensorboard" and summary.files == 2
    assert [a.path for a in FakeAccumulator.instances] == [str(nested), str(logdir)]
    assert all(a.reloaded for a in FakeAccumulator.instances)
    # the fake answers the same steps for both directories: the second read is a restart of
    # ``loss`` (step 1 after step 2), so the first directory's points are orphaned; ``lr``
    # repeats step 2, which is a tie that keeps both points
    assert summary.scalars["loss"].count == 2 and summary.scalars["loss"].step == 2
    assert summary.scalars["lr"].count == 2
    assert summary.last_step == 2 and summary.last_wall_time == pytest.approx(T0 + 2)


def test_summarize_run_skips_tensorboard_for_an_empty_dir(
    tmp_path: Path, fake_tensorboard: None
) -> None:
    logdir = tmp_path / "tensorboard"
    logdir.mkdir()
    summary = summarize_run("nora7", logdir)
    assert summary.reader == "tensorboard" and summary.scalars == {} and summary.files == 0
    assert FakeAccumulator.instances == []


def test_summarize_run_falls_back_when_tensorboard_fails(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    api = events.TensorboardApi(EventAccumulator=BrokenAccumulator)
    monkeypatch.setattr(events, "_load_tensorboard", lambda: api)
    logdir = tmp_path / "tensorboard"
    write_event_file(logdir / "events.out.tfevents.1.h.1.0", *loss_curve(1, 4, 0.4))
    summary = summarize_run("nora7", logdir)
    assert summary.reader == "minimal"
    assert summary.scalars["loss"].step == 4 and summary.scalars["loss"].count == 4


# --- the route ---------------------------------------------------------------------------------


def test_events_route_returns_summary(client, settings, minimal_only: None) -> None:
    logdir = settings.paths.run_dir("nora7-h3-001") / "tensorboard"
    write_event_file(
        logdir / "events.out.tfevents.1760097600.pod.1.0",
        *loss_curve(1, 1250, 0.1182),
        event(T0 + 1250, 1250, simple("learning_rate", 1e-4)),
    )
    response = client.get("/runs/nora7-h3-001/events")
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["run_id"] == "nora7-h3-001"
    assert body["logdir"] == str(logdir)
    assert body["files"] == 1
    assert body["reader"] == "minimal"
    assert body["last_step"] == 1250
    assert body["last_wall_time"] == pytest.approx(T0 + 1250)
    loss = body["scalars"]["loss"]
    assert loss["step"] == 1250 and loss["count"] == 1250
    assert loss["value"] == pytest.approx(0.1182)
    assert loss["wall_time"] == pytest.approx(T0 + 1250)
    assert body["scalars"]["learning_rate"]["count"] == 1


def test_events_route_sees_nested_native_files(client, settings, minimal_only: None) -> None:
    logdir = settings.paths.run_dir("nora7-h3-001") / "tensorboard"
    write_event_file(
        logdir / "events.out.tfevents.1760097600.pod.1.0.scraped",
        event(T0 + 50, 50, simple("scraped/loss", 0.3)),
        mtime=T0,
    )
    write_event_file(
        logdir / "nora7-h3-001_20261010-120000" / "events.out.tfevents.1760097601.pod.1.0",
        *loss_curve(1, 60, 0.06),
        mtime=T0 + 60,
    )
    body = client.get("/runs/nora7-h3-001/events").json()
    assert body["files"] == 2
    assert body["scalars"]["loss"]["step"] == 60 and body["scalars"]["scraped/loss"]["step"] == 50
    assert body["last_step"] == 60


def test_events_route_reports_a_resumed_run_as_alive(client, settings, minimal_only: None) -> None:
    """The finding, end to end: after a crash at 1200 and a resume from 1000, the endpoint
    tracks the resumed attempt's step and wall time instead of freezing at 1200."""
    logdir = settings.paths.run_dir("nora7-h3-001") / "tensorboard"
    write_event_file(
        logdir / "events.out.tfevents.1760097600.pod.1.0.scraped",
        *loss_curve(1, 1200, 0.12),
        mtime=T0 + 1200,
    )
    write_event_file(
        logdir / "events.out.tfevents.1760101200.pod.2.0.scraped",
        *loss_curve(1001, 1100, 0.11, t0=T0 + 3600),
        mtime=T0 + 3600 + 1100,
    )
    body = client.get("/runs/nora7-h3-001/events").json()
    assert body["files"] == 2
    assert body["last_step"] == 1100
    assert body["last_wall_time"] == pytest.approx(T0 + 3600 + 1100)
    loss = body["scalars"]["loss"]
    assert loss["step"] == 1100 and loss["count"] == 1100
    assert loss["wall_time"] == pytest.approx(T0 + 3600 + 1100)


def test_events_route_with_whatever_reader_is_installed(client, settings) -> None:
    # Not forced to the minimal reader: on a venv with tensorboard this exercises the
    # EventAccumulator path against the same file and expects the same numbers.
    logdir = settings.paths.run_dir("ivan9-ltx-001") / "tensorboard"
    write_event_file(
        logdir / "events.out.tfevents.1760097600.pod.1.0",
        *loss_curve(1, 3, 0.3),
        event(T0 + 3, 3, tensor("lr", tensor_proto(float_val=[1e-4]))),
    )
    body = client.get("/runs/ivan9-ltx-001/events").json()
    assert body["reader"] in ("minimal", "tensorboard")
    assert body["scalars"]["loss"]["step"] == 3 and body["scalars"]["loss"]["count"] == 3
    assert body["scalars"]["lr"]["value"] == pytest.approx(1e-4)
    assert body["last_step"] == 3


def test_events_route_empty_run(client, settings, minimal_only: None) -> None:
    settings.paths.run_dir("nora7-h3-002").mkdir(parents=True)
    body = client.get("/runs/nora7-h3-002/events").json()
    assert body == {
        "run_id": "nora7-h3-002",
        "logdir": str(settings.paths.run_dir("nora7-h3-002") / "tensorboard"),
        "files": 0,
        "scalars": {},
        "last_step": None,
        "last_wall_time": None,
        "reader": "minimal",
    }
    # the directory exists but holds no event files yet: still empty, still 200
    (settings.paths.run_dir("nora7-h3-002") / "tensorboard").mkdir()
    response = client.get("/runs/nora7-h3-002/events")
    assert response.status_code == 200 and response.json()["files"] == 0


def test_events_route_unknown_run(client) -> None:
    response = client.get("/runs/nora7-h3-404/events")
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "not_found"


@pytest.mark.parametrize("run_id", ["-nora7", "nora7 x", ".hidden", "a" * 65, "nora7!"])
def test_events_route_bad_run_id(client, run_id: str) -> None:
    response = client.get(f"/runs/{run_id}/events")
    assert response.status_code == 422, response.text
    error = response.json()["error"]
    assert error["code"] == "validation"
    assert error["detail"] == {"field": "run_id", "value": run_id}


def test_events_route_requires_bearer(anon_client) -> None:
    response = anon_client.get("/runs/nora7-h3-001/events")
    assert response.status_code == 401


# --- parity with tensorboard's reader, when it happens to be installed -------------------------


def test_parity_with_tensorboard_reader(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    pytest.importorskip("tensorboard")
    events._load_tensorboard.cache_clear()
    assert events._load_tensorboard() is not None, "tensorboard imports but its reader does not"
    logdir = tmp_path / "tensorboard"
    # file names sort like their mtimes, so both readers see the same file order
    write_event_file(
        logdir / "events.out.tfevents.1760097600.pod.1.0",
        *loss_curve(1, 10, 1.0),
        event(T0 + 10, 10, tensor("lr", tensor_proto(float_val=[1e-4]))),
        event(T0, 10, simple("old_only", 1.0)),
        mtime=T0,
    )
    write_event_file(
        logdir / "events.out.tfevents.1760097700.pod.2.0",
        *loss_curve(5, 10, 2.0),
        event(T0 + 100, 10, tensor("lr", tensor_proto(content=struct.pack("<f", 2e-4)))),
        event(T0, 5, simple("new_only", 2.0)),
        mtime=T0 + 100,
    )
    with_tensorboard = summarize_run("nora7-h3-001", logdir)
    assert with_tensorboard.reader == "tensorboard"
    monkeypatch.setattr(events, "_load_tensorboard", lambda: None)
    with_minimal = summarize_run("nora7-h3-001", logdir)
    assert with_minimal.reader == "minimal"

    assert set(with_tensorboard.scalars) == set(with_minimal.scalars)
    for tag, point in with_minimal.scalars.items():
        other = with_tensorboard.scalars[tag]
        assert (other.step, other.count) == (point.step, point.count), tag
        assert other.value == pytest.approx(point.value), tag
        assert other.wall_time == pytest.approx(point.wall_time), tag
    assert with_tensorboard.last_step == with_minimal.last_step == 10
    assert with_tensorboard.files == with_minimal.files == 2
