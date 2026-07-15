#!/usr/bin/env python3
"""DanCam camera-owner process.

stdout is raw concatenated JPEG frames only. stderr carries newline-delimited
JSON events and any plain-text diagnostics.
"""

from __future__ import annotations

import argparse
import errno
import io
import json
import math
import os
from pathlib import Path
import queue
import re
import secrets
import sys
import tempfile
import threading
import time
from typing import Any, Callable


SEGMENT_WIDTH = 5
INFLIGHT_FLUSH_INTERVAL_SECS = 2.0
SENSOR_TEMP_INTERVAL_SECS = 2.0
SENSOR_TEMP_JOIN_TIMEOUT = 1.0
FAKE_SENSOR_TEMP_BASE_C = 40.0
FAKE_SENSOR_TEMP_STEP_C = 0.25
FAKE_SENSOR_TEMP_SPAN_C = 8.0
U32_MAX = 0xFFFF_FFFF
U64_MAX = 0xFFFF_FFFF_FFFF_FFFF
BOOT_TAG_WIDTH = 12
SEGMENT_RE = re.compile(r"^seg_([0-9]+)(?:_([0-9a-f]{12})_([0-9]+)_([0-9]+)(?:_([0-9]+))?)?\.ts$")
FAKE_JPEG = (
    b"\xff\xd8"
    b"\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
    b"\xff\xdb\x00C\x00"
    + bytes([16]) * 64
    + b"\xff\xc0\x00\x11\x08\x00\x01\x00\x01\x03\x01\x11\x00\x02\x11\x00\x03\x11\x00"
    b"\xff\xc4\x00\x14\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    b"\xff\xc4\x00\x14\x10\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    b"\xff\xda\x00\x0c\x03\x01\x00\x02\x11\x03\x11\x00?\x00"
    b"\x00"
    b"\xff\xd9"
)


def encode_pts(pts: int) -> bytes:
    return bytes(
        [
            0x20 | (((pts >> 30) & 0x07) << 1) | 0x01,
            (pts >> 22) & 0xFF,
            (((pts >> 15) & 0x7F) << 1) | 0x01,
            (pts >> 7) & 0xFF,
            ((pts & 0x7F) << 1) | 0x01,
        ]
    )


def ts_pts_packet(pts: int) -> bytes:
    """A 188-byte MPEG-TS packet carrying one video PES whose only payload is `pts`
    (90 kHz ticks) -- a direct port of `ts_duration.rs#ts_pts_packet` so the Rust
    duration scanner recovers a span from segments this fake writes."""
    packet = bytearray([0xFF] * 188)
    packet[0] = 0x47
    packet[1] = 0x40
    packet[2] = 0x00
    packet[3] = 0x10
    packet[4:13] = bytes([0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x80, 0x05])
    packet[13:18] = encode_pts(pts)
    return bytes(packet)


# A fixed three-packet segment (~300 ms PTS span). The fake writes this at each segment
# open so every finalized fake segment carries a deterministic, non-null duration that
# `/v1/clips` recomputes identically; the per-segment value has no product meaning.
FAKE_SEGMENT = ts_pts_packet(0) + ts_pts_packet(9000) + ts_pts_packet(18000)


def compute_skip(sensor_fps: float, preview_fps: float) -> int:
    return max(1, math.ceil(sensor_fps / preview_fps))


def sensor_temp_payload(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    value = float(value)
    return value if math.isfinite(value) else None


def fake_sensor_temp_c(sample_index: int) -> float:
    sample_count = int(FAKE_SENSOR_TEMP_SPAN_C / FAKE_SENSOR_TEMP_STEP_C) + 1
    return FAKE_SENSOR_TEMP_BASE_C + (sample_index % sample_count) * FAKE_SENSOR_TEMP_STEP_C


def ensure_rec_dir(rec_dir: Path) -> None:
    rec_dir.mkdir(parents=True, exist_ok=True)
    if not rec_dir.is_dir():
        raise RuntimeError(f"{rec_dir} is not a directory")
    if not os.access(rec_dir, os.W_OK):
        raise RuntimeError(f"{rec_dir} is not writable")


def segment_filename(seq: int) -> str:
    return f"seg_{seq:0{SEGMENT_WIDTH}d}.ts"


def stamped_segment_filename(
    seq: int,
    boot_tag: str,
    session_id: int,
    mono_ms_value: int,
    dur_ms_value: int | None = None,
) -> str:
    stem = f"seg_{seq:0{SEGMENT_WIDTH}d}_{boot_tag}_{session_id}_{mono_ms_value}"
    return f"{stem}{f'_{dur_ms_value}' if dur_ms_value is not None else ''}.ts"


def segment_ffmpeg_pattern() -> str:
    return f"seg_%0{SEGMENT_WIDTH}d.ts"


def next_segment_index(seq: int) -> int | None:
    """The seq that follows `seq`, or None at the u32 ceiling. Python ints are unbounded,
    so without this guard a rollover past U32_MAX would open an out-of-range name the
    parser rejects (silently dropped from the event stream and scanner)."""
    if seq >= U32_MAX:
        return None
    return seq + 1


def parse_segment_filename(name: str) -> int | None:
    match = SEGMENT_RE.match(name)
    if match is None:
        return None

    seq = int(match.group(1))
    boot_tag = match.group(2)
    session_value = match.group(3)
    mono_ms_value = match.group(4)
    dur_ms_value = match.group(5)
    if seq > U32_MAX:
        return None
    if boot_tag is None and session_value is None and mono_ms_value is None and dur_ms_value is None:
        rendered = segment_filename(seq)
    elif boot_tag is not None and session_value is not None and mono_ms_value is not None:
        # Bound both numeric fields before re-rendering: Python ints are unbounded, so an
        # oversized session/mono_ms would re-render byte-identically yet must not parse
        # (Rust's u64 scan drops it, and this grammar stays byte-identical).
        if (
            int(session_value) > U64_MAX
            or int(mono_ms_value) > U64_MAX
            or (dur_ms_value is not None and int(dur_ms_value) > U64_MAX)
        ):
            return None
        rendered = stamped_segment_filename(
            seq,
            boot_tag,
            int(session_value),
            int(mono_ms_value),
            int(dur_ms_value) if dur_ms_value is not None else None,
        )
    else:
        return None
    if rendered != name:
        return None
    return seq


def boot_tag_from_boot_id(boot_id: str) -> str | None:
    stripped = boot_id.strip().replace("-", "").lower()
    tag = stripped[:BOOT_TAG_WIDTH]
    if len(tag) != BOOT_TAG_WIDTH or not re.fullmatch(r"[0-9a-f]{12}", tag):
        return None
    return tag


def read_boot_tag() -> str:
    try:
        raw = Path("/proc/sys/kernel/random/boot_id").read_text()
    except OSError:
        return secrets.token_hex(6)
    return boot_tag_from_boot_id(raw) or secrets.token_hex(6)


def mono_ms() -> int:
    clock_id = getattr(time, "CLOCK_BOOTTIME", None)
    if clock_id is not None:
        return int(time.clock_gettime(clock_id) * 1000)
    return int(time.monotonic() * 1000)


def recording_ffmpeg_output(rec_dir: Path, segment_start_number: int) -> str:
    pattern = rec_dir / segment_ffmpeg_pattern()
    return (
        "-bsf:v setts=pts=N*DURATION:dts=N*DURATION "
        "-f segment "
        "-segment_time 30 "
        "-segment_format mpegts "
        "-reset_timestamps 1 "
        f"-segment_start_number {segment_start_number} "
        f"{pattern}"
    )


def emit_event(event: str, **fields: Any) -> None:
    payload = {"event": event}
    payload.update(fields)
    print(json.dumps(payload, separators=(",", ":")), file=sys.stderr, flush=True)


def detect_segment_events(baseline: int, prev_max: int | None, names: list[str]) -> list[dict[str, int]]:
    seq_set: set[int] = set()
    for name in names:
        seq = parse_segment_filename(name)
        if seq is not None and seq >= baseline and (prev_max is None or seq > prev_max):
            seq_set.add(seq)
    seqs = sorted(seq_set)

    events: list[dict[str, int]] = []
    current = prev_max
    for seq in seqs:
        if current is not None:
            events.append({"event": "segment_closed", "id": current})
        events.append({"event": "segment_opened", "id": seq})
        current = seq
    return events


def stamp_segment(rec_dir: Path, seq: int, boot_tag: str, session_id: int, mono_ms_value: int) -> None:
    bare = rec_dir / segment_filename(seq)
    if not bare.exists():
        return

    stamped = rec_dir / stamped_segment_filename(seq, boot_tag, session_id, mono_ms_value)
    try:
        os.rename(bare, stamped)
    except OSError as error:
        print(
            f"failed to stamp segment {bare.name} -> {stamped.name}: {error}",
            file=sys.stderr,
            flush=True,
        )


def resolve_segment_path(rec_dir: Path, seq: int) -> Path | None:
    selected: tuple[int, str, Path] | None = None
    try:
        paths = list(rec_dir.iterdir())
    except FileNotFoundError:
        return None

    for path in paths:
        match = SEGMENT_RE.match(path.name)
        if match is None:
            continue
        parsed = parse_segment_filename(path.name)
        if parsed != seq:
            continue
        rank = 2 if match.group(5) is not None else 1 if match.group(2) is not None else 0
        key = (-rank, path.name)
        if selected is None or key < (selected[0], selected[1]):
            selected = (key[0], key[1], path)
    return selected[2] if selected is not None else None


def fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        try:
            os.fsync(fd)
        except OSError as error:
            # Some development hosts do not support fsync on directories; Linux ext4 does.
            if error.errno != errno.EINVAL:
                raise
    finally:
        os.close(fd)


def fsync_segment(rec_dir: Path, seq: int) -> Path:
    segment = resolve_segment_path(rec_dir, seq)
    if segment is None:
        raise FileNotFoundError(errno.ENOENT, f"segment {seq} not found", str(rec_dir))

    fd = os.open(segment, os.O_RDONLY)
    try:
        if hasattr(os, "fdatasync"):
            os.fdatasync(fd)
        else:
            os.fsync(fd)
    finally:
        os.close(fd)
    fsync_dir(rec_dir)
    return segment


def try_fsync_segment(rec_dir: Path, seq: int) -> bool:
    try:
        fsync_segment(rec_dir, seq)
    except OSError as error:
        print(
            f"failed to fsync segment {seq}: {error}",
            file=sys.stderr,
            flush=True,
        )
        return False
    return True


class InflightFlusher:
    def __init__(
        self,
        flush: Callable[[int], Any],
        interval: float = INFLIGHT_FLUSH_INTERVAL_SECS,
        now: Callable[[], float] = time.monotonic,
        log: Callable[[int, OSError], None] | None = None,
    ):
        self.flush = flush
        self.interval = interval
        self.now = now
        self.log = log or self._log
        self.last_flush = now()
        self.failure_logged = False

    def tick(self, seq: int | None) -> bool:
        if seq is None:
            return False

        now = self.now()
        if now - self.last_flush < self.interval:
            return False

        self.last_flush = now
        try:
            self.flush(seq)
        except OSError as error:
            if not self.failure_logged:
                self.log(seq, error)
                self.failure_logged = True
            return False

        self.failure_logged = False
        return True

    @staticmethod
    def _log(seq: int, error: OSError) -> None:
        print(
            f"failed to fsync in-flight segment {seq}: {error}",
            file=sys.stderr,
            flush=True,
        )


class SensorTempSampler:
    def __init__(
        self,
        read: Callable[[], Any],
        shutdown: threading.Event,
        interval: float = SENSOR_TEMP_INTERVAL_SECS,
        emit: Callable[..., None] = emit_event,
    ):
        self.read = read
        self.shutdown = shutdown
        self.interval = interval
        self.emit = emit
        self.thread = threading.Thread(target=self._run, name="sensor-temp", daemon=True)

    def start(self) -> None:
        self.thread.start()

    def join(self, timeout: float | None = None) -> bool:
        self.thread.join(timeout)
        return not self.thread.is_alive()

    def _run(self) -> None:
        self._sample()
        while not self.shutdown.wait(self.interval):
            self._sample()

    def _sample(self) -> None:
        try:
            celsius = sensor_temp_payload(self.read())
        except Exception:
            celsius = None
        self.emit("sensor_temp", celsius=celsius)


def watch_segment_events(
    rec_dir: Path,
    session_id: int,
    baseline: int,
    watcher_shutdown: threading.Event,
    boot_tag: str,
    flush: Callable[[int], Any] | None = None,
    flush_interval: float = INFLIGHT_FLUSH_INTERVAL_SECS,
) -> None:
    prev_max: int | None = None
    if flush is None:
        flush = lambda seq: fsync_segment(rec_dir, seq)
    flusher = InflightFlusher(flush, interval=flush_interval)

    def scan_once() -> None:
        nonlocal prev_max
        try:
            names = [path.name for path in rec_dir.iterdir()]
        except FileNotFoundError:
            names = []
        for event in detect_segment_events(baseline, prev_max, names):
            if event["event"] == "segment_closed" and not try_fsync_segment(rec_dir, event["id"]):
                continue
            if event["event"] == "segment_opened":
                opened_mono_ms = mono_ms()
                stamp_segment(rec_dir, event["id"], boot_tag, session_id, opened_mono_ms)
            emit_event(event["event"], session_id=session_id, id=event["id"])
            if event["event"] == "segment_opened":
                # detect_segment_events filters opened ids to seqs >= baseline.
                prev_max = event["id"]

    while not watcher_shutdown.wait(0.25):
        scan_once()
        flusher.tick(prev_max)
    scan_once()
    if prev_max is not None:
        try_fsync_segment(rec_dir, prev_max)


def run_self_test() -> int:
    assert compute_skip(30, 12) == 3
    assert compute_skip(30, 10) == 3
    assert compute_skip(30, 15) == 2
    assert compute_skip(30, 30) == 1
    assert compute_skip(30, 60) == 1
    assert sensor_temp_payload(43.2) == 43.2
    assert sensor_temp_payload(43) == 43.0
    for invalid in [math.nan, math.inf, -math.inf, None, True, False, "43.2"]:
        assert sensor_temp_payload(invalid) is None
    assert fake_sensor_temp_c(0) == 40.0
    assert fake_sensor_temp_c(1) == 40.25
    assert fake_sensor_temp_c(32) == 48.0
    assert fake_sensor_temp_c(33) == 40.0

    emitted: list[tuple[str, float | None]] = []

    def capture_temp(event: str, **fields: Any) -> None:
        emitted.append((event, fields["celsius"]))

    stopped = threading.Event()
    stopped.set()

    def raise_read() -> Any:
        raise RuntimeError("unreadable")

    failing_sampler = SensorTempSampler(raise_read, stopped, interval=0, emit=capture_temp)
    failing_sampler.start()
    assert failing_sampler.join(SENSOR_TEMP_JOIN_TIMEOUT)
    assert emitted == [("sensor_temp", None)]

    emitted.clear()
    value_sampler = SensorTempSampler(lambda: 43.2, stopped, interval=0, emit=capture_temp)
    value_sampler.start()
    assert value_sampler.join(SENSOR_TEMP_JOIN_TIMEOUT)
    assert emitted == [("sensor_temp", 43.2)]

    shutdown = threading.Event()
    read_entered = threading.Event()
    release_read = threading.Event()

    def blocking_read() -> float:
        read_entered.set()
        release_read.wait()
        return 44.0

    blocking_sampler = SensorTempSampler(blocking_read, shutdown, interval=60, emit=capture_temp)
    blocking_sampler.start()
    assert read_entered.wait(SENSOR_TEMP_JOIN_TIMEOUT)
    shutdown.set()
    release_read.set()
    assert blocking_sampler.join(SENSOR_TEMP_JOIN_TIMEOUT)
    assert not blocking_sampler.thread.is_alive()

    output = recording_ffmpeg_output(Path("/rec"), 7)
    assert output.split() == [
        "-bsf:v",
        "setts=pts=N*DURATION:dts=N*DURATION",
        "-f",
        "segment",
        "-segment_time",
        "30",
        "-segment_format",
        "mpegts",
        "-reset_timestamps",
        "1",
        "-segment_start_number",
        "7",
        "/rec/seg_%05d.ts",
    ]
    for seq in [0, 5, 99999, 100000, U32_MAX]:
        assert parse_segment_filename(segment_filename(seq)) == seq
    assert segment_filename(0) == "seg_00000.ts"
    assert segment_filename(100000) == "seg_100000.ts"
    assert segment_filename(U32_MAX) == "seg_4294967295.ts"
    assert (
        stamped_segment_filename(5, "abc123def456", 7, 987654321)
        == "seg_00005_abc123def456_7_987654321.ts"
    )
    assert parse_segment_filename("seg_00005_abc123def456_7_987654321.ts") == 5
    assert parse_segment_filename("seg_100000_abc123def456_7_987654321.ts") == 100000
    finalized = stamped_segment_filename(5, "abc123def456", 7, 987654321, 30016)
    assert finalized == "seg_00005_abc123def456_7_987654321_30016.ts"
    assert parse_segment_filename(finalized) == 5
    # A u64::MAX session round-trips byte-for-byte (a valid parse).
    assert (
        parse_segment_filename(stamped_segment_filename(5, "abc123def456", U64_MAX, 987654321))
        == 5
    )
    # The seq-ceiling guard: rollover fails closed at U32_MAX; U32_MAX - 1 still advances.
    assert next_segment_index(U32_MAX) is None
    assert next_segment_index(U32_MAX - 1) == U32_MAX
    with tempfile.TemporaryDirectory() as temp_dir:
        rec_dir = Path(temp_dir)
        stamped = rec_dir / finalized
        stamped.write_bytes(b"segment")
        assert fsync_segment(rec_dir, 5) == stamped
    for reverse in [False, True]:
        with tempfile.TemporaryDirectory() as temp_dir:
            rec_dir = Path(temp_dir)
            names = [
                segment_filename(5),
                stamped_segment_filename(5, "fff123def456", 7, 987654321),
                stamped_segment_filename(5, "fff123def456", 7, 987654321, 400),
                stamped_segment_filename(5, "abc123def456", 7, 987654321, 300),
                stamped_segment_filename(6, "fff123def456", 7, 987654321),
                stamped_segment_filename(6, "abc123def456", 7, 987654321),
            ]
            for name in reversed(names) if reverse else names:
                (rec_dir / name).write_bytes(name.encode())
            expected = rec_dir / stamped_segment_filename(
                5, "abc123def456", 7, 987654321, 300
            )
            assert resolve_segment_path(rec_dir, 5) == expected
            assert fsync_segment(rec_dir, 5) == expected
            expected_stamped = rec_dir / stamped_segment_filename(
                6, "abc123def456", 7, 987654321
            )
            assert resolve_segment_path(rec_dir, 6) == expected_stamped
    attempts: list[int] = []
    failures: list[tuple[int, str]] = []
    fake_now = 0.0

    def now() -> float:
        return fake_now

    def flush(seq: int) -> None:
        attempts.append(seq)

    flusher = InflightFlusher(
        flush,
        interval=2.0,
        now=now,
        log=lambda seq, error: failures.append((seq, str(error))),
    )
    assert not flusher.tick(None)
    assert attempts == []
    assert not flusher.tick(7)
    assert attempts == []
    fake_now = 2.0
    assert flusher.tick(7)
    assert attempts == [7]
    assert not flusher.tick(7)
    assert attempts == [7]
    fake_now = 4.1
    assert flusher.tick(8)
    assert attempts == [7, 8]

    failing_attempts: list[int] = []
    failing_now = 0.0
    errors: list[OSError] = [
        OSError(errno.EIO, "card failed"),
        FileNotFoundError(errno.ENOENT, "rolled over"),
        OSError(errno.EIO, "card failed again"),
    ]

    def failing_clock() -> float:
        return failing_now

    def failing_flush(seq: int) -> None:
        failing_attempts.append(seq)
        if errors:
            raise errors.pop(0)

    flusher = InflightFlusher(
        failing_flush,
        interval=2.0,
        now=failing_clock,
        log=lambda seq, error: failures.append((seq, str(error))),
    )
    failing_now = 2.0
    assert not flusher.tick(9)
    assert failing_attempts == [9]
    assert len(failures) == 1
    assert not flusher.tick(9)
    assert failing_attempts == [9]
    failing_now = 4.0
    assert not flusher.tick(9)
    assert failing_attempts == [9, 9]
    assert len(failures) == 1
    failing_now = 6.0
    assert not flusher.tick(9)
    assert failing_attempts == [9, 9, 9]
    assert len(failures) == 1
    failing_now = 8.0
    assert flusher.tick(9)
    assert failing_attempts == [9, 9, 9, 9]
    failing_now = 10.0
    errors.append(OSError(errno.EIO, "card failed after recovery"))
    assert not flusher.tick(9)
    assert len(failures) == 2

    with tempfile.TemporaryDirectory() as temp_dir:
        rec_dir = Path(temp_dir)
        (rec_dir / segment_filename(5)).write_bytes(b"older")
        (rec_dir / segment_filename(6)).write_bytes(b"newer")
        shutdown = threading.Event()
        shutdown.set()
        original_fsync_segment = globals()["fsync_segment"]
        stderr = io.StringIO()
        original_stderr = sys.stderr

        def raise_sync(_rec_dir: Path, _seq: int) -> Path:
            raise OSError(errno.EIO, "writeback failed")

        try:
            globals()["fsync_segment"] = raise_sync
            sys.stderr = stderr
            assert not try_fsync_segment(rec_dir, 5)
            watch_segment_events(rec_dir, 1, 5, shutdown, "abc123def456")
        finally:
            globals()["fsync_segment"] = original_fsync_segment
            sys.stderr = original_stderr
        assert stderr.getvalue().count("failed to fsync segment") >= 1

    with tempfile.TemporaryDirectory() as temp_dir:
        rec_dir = Path(temp_dir)
        (rec_dir / segment_filename(7)).write_bytes(b"open")
        shutdown = threading.Event()
        periodic_attempts: list[int] = []

        def spy_flush(seq: int) -> None:
            periodic_attempts.append(seq)
            shutdown.set()

        thread = threading.Thread(
            target=watch_segment_events,
            args=(rec_dir, 1, 7, shutdown, "abc123def456"),
            kwargs={"flush": spy_flush, "flush_interval": 0.0},
            daemon=True,
        )
        thread.start()
        thread.join(timeout=1)
        assert not thread.is_alive()
        assert periodic_attempts == [7]
    for name in [
        "seg_999.ts",
        "seg_000005.ts",
        "seg_+5.ts",
        "seg_.ts",
        "seg_abc.ts",
        "seg_00005.mp4",
        "seg_4294967296.ts",
        "seg_00005_ABC123DEF456_7_987654321.ts",
        "seg_00005_abc123def45_7_987654321.ts",
        "seg_00005_abc123def4567_7_987654321.ts",
        "seg_00005_abc123def456_007_987654321.ts",
        "seg_00005_abc123def456_+7_987654321.ts",
        "seg_00005_abc123def456_7_007.ts",
        "seg_00005_abc123def456_7_+9.ts",
        "seg_00005_abc123xyz456_7_987654321.ts",
        # The old 3-part stamped form is rejected outright -- no legacy parse.
        "seg_00005_abc123def456_7.ts",
        # Oversized sess / mono_ms round-trip textually but exceed u64, so the range guard
        # (not just re-render) must drop them -- mirrors the Rust overflow rejects.
        "seg_00005_abc123def456_18446744073709551616_7.ts",
        "seg_00005_abc123def456_7_18446744073709551616.ts",
        "seg_00005_abc123def456_7_987654321_030016.ts",
        "seg_00005_abc123def456_7_987654321_.ts",
        "seg_00005_abc123def456_7_987654321_18446744073709551616.ts",
    ]:
        assert parse_segment_filename(name) is None
    assert (
        boot_tag_from_boot_id("3f1c0e7a-8f3b-4e15-b196-20e0416af749")
        == "3f1c0e7a8f3b"
    )
    assert boot_tag_from_boot_id("ABCDEF12-3456-7890-abcd-ef1234567890") == "abcdef123456"
    assert boot_tag_from_boot_id("unknown") is None
    assert detect_segment_events(43, None, ["seg_00042.ts"]) == []
    assert detect_segment_events(43, None, ["seg_00042.ts", "seg_00043.ts"]) == [
        {"event": "segment_opened", "id": 43}
    ]
    assert detect_segment_events(
        43, 43, ["seg_00042.ts", "seg_00043.ts", "seg_00044.ts"]
    ) == [
        {"event": "segment_closed", "id": 43},
        {"event": "segment_opened", "id": 44},
    ]
    assert detect_segment_events(99999, 99999, ["seg_99999.ts", "seg_100000.ts"]) == [
        {"event": "segment_closed", "id": 99999},
        {"event": "segment_opened", "id": 100000},
    ]
    assert detect_segment_events(
        43,
        43,
        [
            "seg_00043_abc123def456_1_1000.ts",
            "seg_00044.ts",
            "seg_00044_abc123def456_1_2000.ts",
        ],
    ) == [
        {"event": "segment_closed", "id": 43},
        {"event": "segment_opened", "id": 44},
    ]
    return 0


class StdoutWriter:
    def __init__(self, frames: "queue.Queue[bytes]", shutdown: threading.Event):
        self.frames = frames
        self.shutdown = shutdown
        self.thread = threading.Thread(target=self._run, name="stdout-writer", daemon=True)

    def start(self) -> None:
        self.thread.start()

    def join(self, timeout: float | None = None) -> None:
        self.thread.join(timeout)

    def _run(self) -> None:
        while not self.shutdown.is_set():
            try:
                frame = self.frames.get(timeout=0.1)
            except queue.Empty:
                continue

            try:
                sys.stdout.buffer.write(frame)
                sys.stdout.buffer.flush()
            except BrokenPipeError:
                self.shutdown.set()
                return


class StdinReader:
    def __init__(self, commands: "queue.Queue[dict[str, Any]]", shutdown: threading.Event):
        self.commands = commands
        self.shutdown = shutdown
        self.thread = threading.Thread(target=self._run, name="stdin-reader", daemon=True)

    def start(self) -> None:
        self.thread.start()

    def _run(self) -> None:
        for line in sys.stdin:
            if self.shutdown.is_set():
                return
            line = line.strip()
            if not line:
                continue
            try:
                self.commands.put(json.loads(line))
            except json.JSONDecodeError as error:
                emit_event("error", detail=f"invalid command JSON: {error}")
        self.shutdown.set()


class FakeCameraDriver:
    def __init__(
        self,
        rec_dir: Path,
        preview_fps: float,
        fake_sensor_fps: float,
        fake_crash_after: int | None,
        fake_segment_secs: float,
        frames: "queue.Queue[bytes]",
        shutdown: threading.Event,
    ):
        self.rec_dir = rec_dir
        self.preview_fps = preview_fps
        self.fake_sensor_fps = fake_sensor_fps
        self.fake_crash_after = fake_crash_after
        self.fake_segment_secs = fake_segment_secs
        self.frames = frames
        self.shutdown = shutdown
        self.skip = compute_skip(fake_sensor_fps, preview_fps)
        self.boot_tag = read_boot_tag()
        self.preview_thread: threading.Thread | None = None
        self.recording_thread: threading.Thread | None = None
        self.segment_watcher_shutdown: threading.Event | None = None
        self.segment_watcher_thread: threading.Thread | None = None
        self.recording = threading.Event()
        self.lock = threading.Lock()
        self.current_segment: Path | None = None
        self.current_segment_file: Any | None = None
        self.current_segment_index: int | None = None
        self.current_session_id: int | None = None
        self.segment_started_at: float | None = None
        sample_index = 0

        def read_sensor_temp() -> float:
            nonlocal sample_index
            value = fake_sensor_temp_c(sample_index)
            sample_index += 1
            return value

        self.sensor_sampler = SensorTempSampler(read_sensor_temp, shutdown)

    def start(self) -> None:
        self.preview_thread = threading.Thread(target=self._preview_loop, name="fake-preview", daemon=True)
        self.preview_thread.start()
        emit_event("ready")
        self.sensor_sampler.start()

    def start_recording(self, session_id: int, start_segment_index: int) -> None:
        ensure_rec_dir(self.rec_dir)
        with self.lock:
            if self.recording.is_set():
                emit_event("recording_started", session_id=self.current_session_id or session_id)
                return

            self.current_session_id = session_id
            self.current_segment_index = start_segment_index
            self._open_segment_locked(start_segment_index)
            self.segment_started_at = time.monotonic()
            self.recording.set()
            self.recording_thread = threading.Thread(
                target=self._recording_loop,
                name="fake-recording",
                daemon=True,
            )
            self.recording_thread.start()

        emit_event("recording_started", session_id=session_id)

        watcher_shutdown = threading.Event()
        watcher_thread = threading.Thread(
            target=watch_segment_events,
            args=(self.rec_dir, session_id, start_segment_index, watcher_shutdown, self.boot_tag),
            name="segment-watcher",
            daemon=True,
        )
        watcher_thread.start()
        self.segment_watcher_shutdown = watcher_shutdown
        self.segment_watcher_thread = watcher_thread

    def stop_recording(self) -> None:
        with self.lock:
            was_recording = self.recording.is_set()
            session_id = self.current_session_id
            self.recording.clear()
            thread = self.recording_thread
            self.recording_thread = None

        if was_recording and thread is not None:
            thread.join(timeout=1)

        with self.lock:
            self._finish_segment_locked()
            self.current_segment = None
            self.current_segment_index = None
            self.current_session_id = None
            self.segment_started_at = None

        if self.segment_watcher_shutdown is not None:
            self.segment_watcher_shutdown.set()
        if self.segment_watcher_thread is not None:
            self.segment_watcher_thread.join(timeout=1)
        self.segment_watcher_shutdown = None
        self.segment_watcher_thread = None

        if was_recording and session_id is not None:
            emit_event("recording_stopped", session_id=session_id)

    def shutdown_driver(self) -> None:
        self.shutdown.set()
        if not self.sensor_sampler.join(SENSOR_TEMP_JOIN_TIMEOUT):
            print("sensor temperature sampler did not stop", file=sys.stderr, flush=True)
        self.stop_recording()
        if self.preview_thread is not None:
            self.preview_thread.join(timeout=1)

    def _preview_loop(self) -> None:
        frame_count = 0
        interval = 1.0 / self.fake_sensor_fps

        while not self.shutdown.is_set():
            if frame_count % self.skip == 0:
                try:
                    self.frames.put_nowait(FAKE_JPEG)
                except queue.Full:
                    pass

            frame_count += 1
            if self.fake_crash_after is not None and frame_count >= self.fake_crash_after:
                os._exit(42)
            time.sleep(interval)

    def _recording_loop(self) -> None:
        while True:
            with self.lock:
                if not self.recording.is_set():
                    return
                if (
                    self.segment_started_at is not None
                    and self.current_segment_index is not None
                    and time.monotonic() - self.segment_started_at >= self.fake_segment_secs
                ):
                    new = next_segment_index(self.current_segment_index)
                    if new is None:
                        # Fail closed at the seq ceiling rather than opening an out-of-range
                        # name: finish the last legal segment, stop, and emit an error the
                        # supervisor turns into a failed recorder.
                        self._finish_segment_locked()
                        self.recording.clear()
                        emit_event("error", detail="segment ids exhausted at u32::MAX")
                        return
                    self._finish_segment_locked()
                    self.current_segment_index = new
                    self._open_segment_locked(new)
                    self.segment_started_at = time.monotonic()

            time.sleep(0.1)

    def _open_segment_locked(self, seq: int) -> None:
        self.current_segment = self.rec_dir / segment_filename(seq)
        self.current_segment_file = self.current_segment.open("wb")
        self.current_segment_file.write(FAKE_SEGMENT[:188])
        self.current_segment_file.flush()

    def _finish_segment_locked(self) -> None:
        if self.current_segment_file is None:
            return
        self.current_segment_file.write(FAKE_SEGMENT[188:])
        self.current_segment_file.flush()
        self.current_segment_file.close()
        self.current_segment_file = None


class RealCameraDriver:
    def __init__(
        self,
        rec_dir: Path,
        preview_fps: float,
        frames: "queue.Queue[bytes]",
        shutdown: threading.Event,
    ):
        self.rec_dir = rec_dir
        self.preview_fps = preview_fps
        self.frames = frames
        self.shutdown = shutdown
        self.boot_tag = read_boot_tag()
        self.picam2 = None
        self.preview_encoder = None
        self.h264_encoder = None
        self.recording = False
        self.current_session_id: int | None = None
        self.segment_watcher_shutdown: threading.Event | None = None
        self.segment_watcher_thread: threading.Thread | None = None
        self._latest_sensor_temp: Any = None
        self.sensor_sampler = SensorTempSampler(lambda: self._latest_sensor_temp, shutdown)

    def start(self) -> None:
        from picamera2 import Picamera2
        from picamera2.encoders import MJPEGEncoder
        from picamera2.outputs import Output
        from libcamera import controls

        class PreviewQueueOutput(Output):
            def __init__(self, frames: "queue.Queue[bytes]"):
                super().__init__()
                self.frames = frames

            def outputframe(self, frame, keyframe=True, timestamp=None, packet=None, audio=False):
                try:
                    self.frames.put_nowait(bytes(frame))
                except queue.Full:
                    pass

        self.picam2 = Picamera2()
        config = self.picam2.create_video_configuration(
            main={"size": (1920, 1080), "format": "YUV420"},
            lores={"size": (640, 480), "format": "YUV420"},
            controls={
                "FrameRate": 30,
                "AfMode": controls.AfModeEnum.Manual,  # disable autofocus; never hunt onto glass
                "LensPosition": 0.0,  # diopters: 0.0 = infinity
            },
            buffer_count=4,
            queue=False,
        )
        self.picam2.configure(config)

        def cache_sensor_temp(request: Any) -> None:
            self._latest_sensor_temp = request.get_metadata().get("SensorTemperature")

        self.picam2.pre_callback = cache_sensor_temp
        self.picam2.start()

        self.preview_encoder = MJPEGEncoder()
        self.preview_encoder.frame_skip_count = compute_skip(30, self.preview_fps)
        self.picam2.start_encoder(
            self.preview_encoder,
            PreviewQueueOutput(self.frames),
            name="lores",
        )
        emit_event("ready")
        self.sensor_sampler.start()

    def start_recording(self, session_id: int, start_segment_index: int) -> None:
        ensure_rec_dir(self.rec_dir)
        if self.recording:
            emit_event("recording_started", session_id=self.current_session_id or session_id)
            return

        from picamera2.encoders import H264Encoder
        from picamera2.outputs import FfmpegOutput

        watcher_shutdown = threading.Event()
        watcher_thread = threading.Thread(
            target=watch_segment_events,
            args=(self.rec_dir, session_id, start_segment_index, watcher_shutdown, self.boot_tag),
            name="segment-watcher",
            daemon=True,
        )
        watcher_thread.start()

        output = recording_ffmpeg_output(self.rec_dir, start_segment_index)
        self.h264_encoder = H264Encoder(bitrate=10_000_000, repeat=True, iperiod=30)
        try:
            self.picam2.start_encoder(
                self.h264_encoder,
                FfmpegOutput(output, audio=False),
                name="main",
            )
        except Exception:
            watcher_shutdown.set()
            watcher_thread.join(timeout=1)
            raise

        self.recording = True
        self.current_session_id = session_id
        self.segment_watcher_shutdown = watcher_shutdown
        self.segment_watcher_thread = watcher_thread
        emit_event("recording_started", session_id=session_id)

    def stop_recording(self) -> None:
        session_id = self.current_session_id
        if self.recording and self.h264_encoder is not None:
            self.picam2.stop_encoder(self.h264_encoder)
            self.h264_encoder = None
            self.recording = False
        if self.segment_watcher_shutdown is not None:
            self.segment_watcher_shutdown.set()
        if self.segment_watcher_thread is not None:
            self.segment_watcher_thread.join(timeout=1)
        self.segment_watcher_shutdown = None
        self.segment_watcher_thread = None
        self.current_session_id = None
        if session_id is not None:
            emit_event("recording_stopped", session_id=session_id)

    def shutdown_driver(self) -> None:
        self.shutdown.set()
        if not self.sensor_sampler.join(SENSOR_TEMP_JOIN_TIMEOUT):
            print("sensor temperature sampler did not stop", file=sys.stderr, flush=True)
        self.stop_recording()
        if self.picam2 is not None:
            self.picam2.stop_encoder()
            self.picam2.stop()


def run(args: argparse.Namespace) -> int:
    if args.preview_fps <= 0:
        emit_event("error", detail="--preview-fps must be positive")
        return 1
    if args.fake_sensor_fps <= 0:
        emit_event("error", detail="--fake-sensor-fps must be positive")
        return 1
    if args.fake_segment_secs <= 0:
        emit_event("error", detail="--fake-segment-secs must be positive")
        return 1

    rec_dir = Path(args.rec_dir).expanduser()
    frames: "queue.Queue[bytes]" = queue.Queue(maxsize=1)
    commands: "queue.Queue[dict[str, Any]]" = queue.Queue()
    shutdown = threading.Event()

    stdout_writer = StdoutWriter(frames, shutdown)
    stdin_reader = StdinReader(commands, shutdown)

    if args.fake:
        driver = FakeCameraDriver(
            rec_dir=rec_dir,
            preview_fps=args.preview_fps,
            fake_sensor_fps=args.fake_sensor_fps,
            fake_crash_after=args.fake_crash_after,
            fake_segment_secs=args.fake_segment_secs,
            frames=frames,
            shutdown=shutdown,
        )
    else:
        driver = RealCameraDriver(
            rec_dir=rec_dir,
            preview_fps=args.preview_fps,
            frames=frames,
            shutdown=shutdown,
        )

    try:
        stdout_writer.start()
        stdin_reader.start()
        driver.start()

        while not shutdown.is_set():
            try:
                command = commands.get(timeout=0.1)
            except queue.Empty:
                continue

            match command.get("cmd"):
                case "start_recording":
                    session_id = command_int(command, "session_id")
                    start_segment_index = command_int(command, "start_segment_index")
                    if session_id is None or start_segment_index is None:
                        emit_event(
                            "error",
                            detail="start_recording requires integer session_id and start_segment_index",
                        )
                        continue
                    driver.start_recording(session_id, start_segment_index)
                case "stop_recording":
                    driver.stop_recording()
                case "shutdown":
                    driver.shutdown_driver()
                case other:
                    emit_event("error", detail=f"unknown command: {other}")

        stdout_writer.join(timeout=1)
        return 0
    except Exception as error:
        emit_event("error", detail=str(error))
        return 1


def command_int(command: dict[str, Any], field: str) -> int | None:
    value = command.get(field)
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rec-dir", default=os.environ.get("DANCAM_REC_DIR", "/var/lib/dancam/rec"))
    parser.add_argument("--preview-fps", type=float, default=10)
    parser.add_argument("--fake", action="store_true")
    parser.add_argument("--fake-sensor-fps", type=float, default=30)
    parser.add_argument("--fake-crash-after", type=int)
    parser.add_argument("--fake-segment-secs", type=float, default=30)
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        return run_self_test()
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
