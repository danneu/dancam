#!/usr/bin/env python3
"""DanCam camera-owner process.

stdout is raw concatenated JPEG frames only. stderr carries newline-delimited
JSON events and any plain-text diagnostics.
"""

from __future__ import annotations

import argparse
import errno
from fractions import Fraction
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
LIFECYCLE_DEADLINE_SECS = 2.0
LIFECYCLE_RETRY_SECS = 0.25
RECORDING_FPS = 30
SEGMENT_FRAMES = 30 * RECORDING_FPS
SENSOR_TEMP_INTERVAL_SECS = 2.0
SENSOR_TEMP_JOIN_TIMEOUT = 1.0
FAKE_SENSOR_TEMP_BASE_C = 40.0
FAKE_SENSOR_TEMP_STEP_C = 0.25
FAKE_SENSOR_TEMP_SPAN_C = 8.0
U32_MAX = 0xFFFF_FFFF
U64_MAX = 0xFFFF_FFFF_FFFF_FFFF
BOOT_TAG_WIDTH = 12
SEGMENT_RE = re.compile(r"^seg_([0-9]+)(?:_([0-9a-f]{12})_([0-9]+)_([0-9]+)(?:_([0-9]+))?)?\.ts$")
ARTIFACT_RE = re.compile(
    r"^\.dancam-seg_([0-9]+)_([0-9a-f]{12})_([0-9]+)_([0-9]+)(\.pending|\.open\.ts)$"
)
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


# A fixed three-packet segment (100 ms at 30 fps). The fake writes this at each segment
# open so every finalized fake segment carries a deterministic, non-null duration that
# `/v1/clips` recomputes identically; the per-segment value has no product meaning.
FAKE_SEGMENT = ts_pts_packet(0) + ts_pts_packet(3000) + ts_pts_packet(6000)


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


def recording_artifact_filename(
    state: str,
    seq: int,
    boot_tag: str,
    session_id: int,
    mono_ms_value: int,
) -> str:
    suffix = {"uncommitted": ".pending", "committed_open": ".open.ts"}[state]
    return (
        f".dancam-seg_{seq:0{SEGMENT_WIDTH}d}_{boot_tag}_{session_id}_"
        f"{mono_ms_value}{suffix}"
    )


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


def emit_event(event: str, **fields: Any) -> None:
    payload = {"event": event}
    payload.update(fields)
    print(json.dumps(payload, separators=(",", ":")), file=sys.stderr, flush=True)


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


class LifecycleExchange:
    def __init__(self):
        self.condition = threading.Condition()
        self.responses: dict[tuple[str, int, int | None], dict[str, Any]] = {}

    def deliver(self, command: dict[str, Any]) -> bool:
        cmd = command.get("cmd")
        if cmd == "ack_segment":
            session = command_int(command, "session_id")
            seq = command_int(command, "id")
            kind = command.get("kind")
            if session is None or seq is None or kind not in {"opened", "finalized"}:
                return True
            key = (f"ack_{kind}", session, seq)
        elif cmd == "segment_reserved":
            session = command_int(command, "session_id")
            seq = command_int(command, "id")
            if session is None or seq is None:
                return True
            key = ("reserved", session, None)
        elif cmd == "transaction_rejected":
            session = command_int(command, "session_id")
            if session is None:
                return True
            key = ("reserved", session, None)
        else:
            return False
        with self.condition:
            self.responses[key] = command
            self.condition.notify_all()
        return True

    def acknowledge(self, event: str, session_id: int, seq: int, **fields: Any) -> None:
        kind = event.removeprefix("segment_")
        key = (f"ack_{kind}", session_id, seq)
        self._request(key, event, session_id=session_id, id=seq, **fields)

    def reserve(self, session_id: int) -> int:
        response = self._request(("reserved", session_id, None), "segment_needed", session_id=session_id)
        if response.get("cmd") == "transaction_rejected":
            raise RuntimeError(response.get("detail") or "segment reservation rejected")
        seq = command_int(response, "id")
        if seq is None:
            raise RuntimeError("segment reservation response omitted id")
        return seq

    def _request(
        self,
        key: tuple[str, int, int | None],
        event: str,
        **fields: Any,
    ) -> dict[str, Any]:
        deadline = time.monotonic() + LIFECYCLE_DEADLINE_SECS
        next_emit = 0.0
        with self.condition:
            self.responses.pop(key, None)
            while True:
                now = time.monotonic()
                if now >= deadline:
                    raise TimeoutError(f"{event} acknowledgement timed out")
                if now >= next_emit:
                    emit_event(event, **fields)
                    next_emit = now + LIFECYCLE_RETRY_SECS
                response = self.responses.pop(key, None)
                if response is not None:
                    return response
                self.condition.wait(max(0.0, min(next_emit, deadline) - now))


class TransactionalFile:
    def __init__(
        self,
        rec_dir: Path,
        boot_tag: str,
        session_id: int,
        seq: int,
        exchange: LifecycleExchange,
    ):
        self.rec_dir = rec_dir
        self.boot_tag = boot_tag
        self.session_id = session_id
        self.seq = seq
        self.exchange = exchange
        self.opened_mono_ms = mono_ms()
        self.pending_path = rec_dir / recording_artifact_filename(
            "uncommitted", seq, boot_tag, session_id, self.opened_mono_ms
        )
        self.open_path = rec_dir / recording_artifact_filename(
            "committed_open", seq, boot_tag, session_id, self.opened_mono_ms
        )
        self.file = self.pending_path.open("w+b", buffering=0)
        self.committed = False
        self.frames = 0
        self.last_sync = time.monotonic()

    def sync(self) -> None:
        self.file.flush()
        if hasattr(os, "fdatasync"):
            os.fdatasync(self.file.fileno())
        else:
            os.fsync(self.file.fileno())
        self.last_sync = time.monotonic()

    def commit(self) -> None:
        self.sync()
        os.rename(self.pending_path, self.open_path)
        fsync_dir(self.rec_dir)
        self.committed = True
        self.exchange.acknowledge("segment_opened", self.session_id, self.seq)

    def periodic_sync(self) -> None:
        if time.monotonic() - self.last_sync >= INFLIGHT_FLUSH_INTERVAL_SECS:
            self.sync()

    def finalize(self) -> Path | None:
        if not self.file.closed:
            self.sync()
            self.file.close()
        else:
            path = self.open_path if self.committed else self.pending_path
            fd = os.open(path, os.O_RDONLY)
            try:
                if hasattr(os, "fdatasync"):
                    os.fdatasync(fd)
                else:
                    os.fsync(fd)
            finally:
                os.close(fd)
        if not self.committed:
            self.pending_path.unlink(missing_ok=True)
            fsync_dir(self.rec_dir)
            return None
        dur_ms = round(self.frames * 1000 / RECORDING_FPS)
        destination = self.rec_dir / stamped_segment_filename(
            self.seq,
            self.boot_tag,
            self.session_id,
            self.opened_mono_ms,
            dur_ms,
        )
        os.rename(self.open_path, destination)
        fsync_dir(self.rec_dir)
        self.exchange.acknowledge(
            "segment_finalized", self.session_id, self.seq, dur_ms=dur_ms
        )
        return destination


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

    failing_sampler = SensorTempSampler(
        raise_read, stopped, interval=0, emit=capture_temp
    )
    failing_sampler.start()
    assert failing_sampler.join(SENSOR_TEMP_JOIN_TIMEOUT)
    assert emitted == [("sensor_temp", None)]

    emitted.clear()
    value_sampler = SensorTempSampler(
        lambda: 43.2, stopped, interval=0, emit=capture_temp
    )
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

    blocking_sampler = SensorTempSampler(
        blocking_read, shutdown, interval=60, emit=capture_temp
    )
    blocking_sampler.start()
    assert read_entered.wait(SENSOR_TEMP_JOIN_TIMEOUT)
    shutdown.set()
    release_read.set()
    assert blocking_sampler.join(SENSOR_TEMP_JOIN_TIMEOUT)

    for seq in [0, 5, 99999, 100000, U32_MAX]:
        assert parse_segment_filename(segment_filename(seq)) == seq
    assert segment_filename(0) == "seg_00000.ts"
    assert segment_filename(100000) == "seg_100000.ts"
    assert segment_filename(U32_MAX) == "seg_4294967295.ts"
    assert (
        stamped_segment_filename(5, "abc123def456", 7, 987654321)
        == "seg_00005_abc123def456_7_987654321.ts"
    )
    finalized = stamped_segment_filename(5, "abc123def456", 7, 987654321, 30016)
    assert finalized == "seg_00005_abc123def456_7_987654321_30016.ts"
    assert parse_segment_filename(finalized) == 5
    assert (
        parse_segment_filename(
            stamped_segment_filename(5, "abc123def456", U64_MAX, 987654321)
        )
        == 5
    )
    for name in [
        "seg_999.ts",
        "seg_000005.ts",
        "seg_+5.ts",
        "seg_.ts",
        "seg_abc.ts",
        "seg_00005.mp4",
        "seg_4294967296.ts",
        "seg_00005_ABC123DEF456_7_987654321.ts",
        "seg_00005_abc123def456_007_987654321.ts",
        "seg_00005_abc123def456_7_007.ts",
        "seg_00005_abc123def456_7_987654321_030016.ts",
        "seg_00005_abc123def456_18446744073709551616_7.ts",
        "seg_00005_abc123def456_7_18446744073709551616.ts",
    ]:
        assert parse_segment_filename(name) is None
    assert (
        recording_artifact_filename(
            "uncommitted", 5, "abc123def456", 7, 987654321
        )
        == ".dancam-seg_00005_abc123def456_7_987654321.pending"
    )
    assert ARTIFACT_RE.fullmatch(
        recording_artifact_filename(
            "committed_open", 5, "abc123def456", 7, 987654321
        )
    )
    for name in [
        ".dancam-seg_00005_ABC123DEF456_7_987654321.open.ts",
        ".dancam-seg_00005_abc123def456_7_987654321.ts",
    ]:
        assert ARTIFACT_RE.fullmatch(name) is None
    assert boot_tag_from_boot_id("3f1c0e7a-8f3b-4e15-b196-20e0416af749") == "3f1c0e7a8f3b"

    # Import and initialize the same PyAV binding before a real owner may claim ready.
    try:
        import av
    except ModuleNotFoundError:
        return 0

    packet = av.Packet(b"\x00\x00\x00\x01\x09\x10")
    packet.pts = 0
    packet.dts = 0
    packet.time_base = Fraction(1, RECORDING_FPS)
    assert packet.pts == packet.dts == 0

    class TestOutput:
        def __init__(self) -> None:
            self.recording = False

        def start(self) -> None:
            self.recording = True

        def stop(self) -> None:
            self.recording = False

    class ImmediateExchange:
        def __init__(self, rec_dir: Path) -> None:
            self.rec_dir = rec_dir
            self.opened_prefix_decoded = False

        def acknowledge(self, event: str, session_id: int, seq: int, **fields: Any) -> None:
            del session_id, seq, fields
            if event != "segment_opened":
                return
            paths = list(self.rec_dir.glob(".dancam-seg_*.open.ts"))
            assert len(paths) == 1
            prefix = paths[0].read_bytes()
            with av.open(io.BytesIO(prefix), mode="r", format="mpegts") as source:
                assert next(source.decode(video=0), None) is not None
            self.opened_prefix_decoded = True

        def reserve(self, session_id: int) -> int:
            raise AssertionError(f"unexpected rollover for session {session_id}")

    fixture = Path(__file__).parent.parent / "service/assets/clips/seg_00000.ts"
    with av.open(str(fixture)) as source:
        access_units = [
            (bytes(source_packet), bool(source_packet.is_keyframe))
            for source_packet in source.demux(video=0)
            if source_packet.size > 0
        ][:3]
    assert access_units and access_units[0][1]
    with tempfile.TemporaryDirectory() as temp_dir:
        rec_dir = Path(temp_dir)
        exchange = ImmediateExchange(rec_dir)
        output_type = segmented_pyav_output_type(TestOutput, av)
        output = output_type(
            rec_dir, "abc123def456", 7, 5, exchange
        )
        output.start()
        output._add_stream("video", "h264", width=1920, height=1080)
        for access_unit, keyframe in access_units:
            output.outputframe(access_unit, keyframe=keyframe)
        output.stop()
        assert exchange.opened_prefix_decoded
        finalized = list(rec_dir.glob("seg_*.ts"))
        assert len(finalized) == 1
        assert finalized[0].name.endswith("_100.ts")
        with av.open(str(finalized[0])) as result:
            packets = [packet for packet in result.demux(video=0) if packet.size > 0]
        assert [packet.pts for packet in packets] == [0, 3000, 6000]
        assert all(packet.pts == packet.dts for packet in packets)
        with av.open(str(finalized[0])) as result:
            assert next(result.decode(video=0), None) is not None

    exchange = LifecycleExchange()
    assert not exchange.deliver({"cmd": "start_recording"})
    assert exchange.deliver(
        {"cmd": "ack_segment", "kind": "opened", "session_id": 7, "id": 5}
    )
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
    def __init__(
        self,
        commands: "queue.Queue[dict[str, Any]]",
        shutdown: threading.Event,
        exchange: LifecycleExchange,
    ):
        self.commands = commands
        self.shutdown = shutdown
        self.exchange = exchange
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
                command = json.loads(line)
                if not isinstance(command, dict):
                    raise ValueError("command must be a JSON object")
                if not self.exchange.deliver(command):
                    self.commands.put(command)
            except json.JSONDecodeError as error:
                emit_event("error", detail=f"invalid command JSON: {error}")
            except ValueError as error:
                emit_event("error", detail=str(error))
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
        exchange: LifecycleExchange,
    ):
        self.rec_dir = rec_dir
        self.fake_sensor_fps = fake_sensor_fps
        self.fake_crash_after = fake_crash_after
        self.fake_segment_secs = fake_segment_secs
        self.frames = frames
        self.shutdown = shutdown
        self.exchange = exchange
        self.skip = compute_skip(fake_sensor_fps, preview_fps)
        self.boot_tag = read_boot_tag()
        self.preview_thread: threading.Thread | None = None
        self.recording_thread: threading.Thread | None = None
        self.recording = threading.Event()
        self.lock = threading.Lock()
        self.segment: TransactionalFile | None = None
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
        self.preview_thread = threading.Thread(
            target=self._preview_loop, name="fake-preview", daemon=True
        )
        self.preview_thread.start()
        emit_event("ready")
        self.sensor_sampler.start()

    def start_recording(self, session_id: int, start_segment_index: int) -> None:
        ensure_rec_dir(self.rec_dir)
        with self.lock:
            if self.recording.is_set():
                return
            self.current_session_id = session_id
            self.segment = self._open_segment(start_segment_index)
            self.segment_started_at = time.monotonic()
            self.recording.set()
            self.recording_thread = threading.Thread(
                target=self._recording_loop, name="fake-recording", daemon=True
            )
            self.recording_thread.start()

    def stop_recording(self) -> None:
        with self.lock:
            was_recording = self.recording.is_set()
            session_id = self.current_session_id
            self.recording.clear()
            thread = self.recording_thread
            self.recording_thread = None
        if was_recording and thread is not None:
            thread.join(timeout=LIFECYCLE_DEADLINE_SECS + 1)
            if thread.is_alive():
                raise TimeoutError("fake recording thread did not stop")
        with self.lock:
            if self.segment is not None:
                self._finish_segment(self.segment)
            self.segment = None
            self.current_session_id = None
            self.segment_started_at = None
        if was_recording and session_id is not None:
            emit_event("recording_stopped", session_id=session_id)

    def shutdown_driver(self) -> None:
        self.stop_recording()
        self.shutdown.set()
        if not self.sensor_sampler.join(SENSOR_TEMP_JOIN_TIMEOUT):
            raise TimeoutError("sensor temperature sampler did not stop")
        if self.preview_thread is not None:
            self.preview_thread.join(timeout=1)

    def _open_segment(self, seq: int) -> TransactionalFile:
        if seq < 0 or seq > U32_MAX:
            raise RuntimeError("segment id outside u32 range")
        assert self.current_session_id is not None
        segment = TransactionalFile(
            self.rec_dir, self.boot_tag, self.current_session_id, seq, self.exchange
        )
        segment.file.write(FAKE_SEGMENT[: 2 * 188])
        segment.frames = 2
        segment.commit()
        return segment

    @staticmethod
    def _finish_segment(segment: TransactionalFile) -> None:
        segment.file.write(FAKE_SEGMENT[2 * 188 :])
        segment.frames += 1
        segment.finalize()

    def _recording_loop(self) -> None:
        try:
            while self.recording.is_set():
                with self.lock:
                    if not self.recording.is_set():
                        return
                    if (
                        self.segment is not None
                        and self.segment_started_at is not None
                        and time.monotonic() - self.segment_started_at >= self.fake_segment_secs
                    ):
                        self._finish_segment(self.segment)
                        next_seq = self.exchange.reserve(self.current_session_id or 0)
                        self.segment = self._open_segment(next_seq)
                        self.segment_started_at = time.monotonic()
                    elif self.segment is not None:
                        self.segment.periodic_sync()
                time.sleep(0.05)
        except Exception as error:
            emit_event("error", detail=f"fake recording lifecycle failed: {error}")
            os._exit(70)

    def _preview_loop(self) -> None:
        frame_count = 0
        interval = 1.0 / self.fake_sensor_fps
        while not self.shutdown.wait(interval):
            if frame_count % self.skip == 0:
                try:
                    self.frames.put_nowait(FAKE_JPEG)
                except queue.Full:
                    pass
            frame_count += 1
            if self.fake_crash_after is not None and frame_count >= self.fake_crash_after:
                os._exit(42)


def segmented_pyav_output_type(Output: type[Any], av: Any) -> type[Any]:
    class SegmentedPyavOutput(Output):
        def __init__(
            self,
            rec_dir: Path,
            boot_tag: str,
            session_id: int,
            start_segment_index: int,
            exchange: LifecycleExchange,
        ):
            super().__init__()
            self.needs_add_stream = True
            self.rec_dir = rec_dir
            self.boot_tag = boot_tag
            self.session_id = session_id
            self.seq = start_segment_index
            self.exchange = exchange
            self.transaction: TransactionalFile | None = None
            self.container: Any = None
            self.stream: Any = None
            self.stream_spec: tuple[str, dict[str, Any]] | None = None

        def start(self) -> None:
            self._open_container(self.seq)
            super().start()

        def _add_stream(self, encoder_stream: Any, codec_name: str, **kwargs: Any) -> None:
            if encoder_stream != "video" or codec_name != "h264":
                raise RuntimeError("transactional output accepts only H.264 video")
            self.stream_spec = (codec_name, kwargs)
            self._install_stream()

        def _install_stream(self) -> None:
            if self.container is None or self.stream_spec is None:
                return
            codec_name, kwargs = self.stream_spec
            self.stream = self.container.add_stream(
                codec_name,
                rate=RECORDING_FPS,
                **{key: value for key, value in kwargs.items() if key != "rate"},
            )

        def outputframe(
            self,
            frame: Any,
            keyframe: bool = True,
            timestamp: int | None = None,
            packet: Any = None,
            audio: bool = False,
        ) -> None:
            del timestamp, packet
            try:
                if audio or not self.recording or self.transaction is None:
                    return
                if self.stream is None:
                    raise RuntimeError("H.264 stream was not initialized")
                if self.transaction.frames == 0 and not keyframe:
                    raise RuntimeError("segment did not begin with SPS/PPS/IDR")
                if self.transaction.frames >= SEGMENT_FRAMES and keyframe:
                    self._finalize_container()
                    self.seq = self.exchange.reserve(self.session_id)
                    self._open_container(self.seq)
                encoded = av.Packet(bytes(frame))
                encoded.pts = self.transaction.frames
                encoded.dts = self.transaction.frames
                encoded.time_base = Fraction(1, RECORDING_FPS)
                encoded.is_keyframe = keyframe
                encoded.stream = self.stream
                self.container.mux(encoded)
                self.transaction.frames += 1
                if not self.transaction.committed:
                    self.transaction.commit()
                else:
                    self.transaction.periodic_sync()
            except BaseException as error:
                emit_event("error", detail=f"recording mux lifecycle failed: {error}")
                os._exit(70)

        def stop(self) -> None:
            super().stop()
            self._finalize_container()

        def _open_container(self, seq: int) -> None:
            self.transaction = TransactionalFile(
                self.rec_dir, self.boot_tag, self.session_id, seq, self.exchange
            )
            try:
                self.container = av.open(
                    self.transaction.file,
                    mode="w",
                    format="mpegts",
                    options={"flush_packets": "1", "mpegts_flags": "+resend_headers"},
                )
                self._install_stream()
            except BaseException:
                self.transaction.finalize()
                raise

        def _finalize_container(self) -> None:
            if self.container is None or self.transaction is None:
                return
            container = self.container
            transaction = self.transaction
            self.container = None
            self.transaction = None
            self.stream = None
            container.close()
            transaction.finalize()

    return SegmentedPyavOutput


class RealCameraDriver:
    def __init__(
        self,
        rec_dir: Path,
        preview_fps: float,
        frames: "queue.Queue[bytes]",
        shutdown: threading.Event,
        exchange: LifecycleExchange,
    ):
        self.rec_dir = rec_dir
        self.preview_fps = preview_fps
        self.frames = frames
        self.shutdown = shutdown
        self.exchange = exchange
        self.boot_tag = read_boot_tag()
        self.picam2: Any = None
        self.preview_encoder: Any = None
        self.h264_encoder: Any = None
        self.segment_output: Any = None
        self.output_type: Any = None
        self.recording = False
        self.current_session_id: int | None = None
        self._latest_sensor_temp: Any = None
        self.sensor_sampler = SensorTempSampler(lambda: self._latest_sensor_temp, shutdown)

    def start(self) -> None:
        import av
        from libcamera import controls
        from picamera2 import Picamera2
        from picamera2.encoders import H264Encoder, MJPEGEncoder
        from picamera2.outputs import Output

        # Force the binding and codec registry initialization into readiness, not start.
        probe = av.Packet(b"")
        del probe, H264Encoder
        self.output_type = segmented_pyav_output_type(Output, av)

        class PreviewQueueOutput(Output):
            def __init__(self, frames: "queue.Queue[bytes]"):
                super().__init__()
                self.frames = frames

            def outputframe(
                self,
                frame: Any,
                keyframe: bool = True,
                timestamp: int | None = None,
                packet: Any = None,
                audio: bool = False,
            ) -> None:
                del keyframe, timestamp, packet, audio
                try:
                    self.frames.put_nowait(bytes(frame))
                except queue.Full:
                    pass

        self.picam2 = Picamera2()
        config = self.picam2.create_video_configuration(
            main={"size": (1920, 1080), "format": "YUV420"},
            lores={"size": (640, 480), "format": "YUV420"},
            controls={
                "FrameRate": RECORDING_FPS,
                "AfMode": controls.AfModeEnum.Manual,
                "LensPosition": 0.0,
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
        self.preview_encoder.frame_skip_count = compute_skip(RECORDING_FPS, self.preview_fps)
        self.picam2.start_encoder(
            self.preview_encoder, PreviewQueueOutput(self.frames), name="lores"
        )
        self.sensor_sampler.start()
        emit_event("ready")

    def start_recording(self, session_id: int, start_segment_index: int) -> None:
        ensure_rec_dir(self.rec_dir)
        if self.recording:
            return
        from picamera2.encoders import H264Encoder

        self.segment_output = self.output_type(
            self.rec_dir,
            self.boot_tag,
            session_id,
            start_segment_index,
            self.exchange,
        )
        self.h264_encoder = H264Encoder(
            bitrate=10_000_000, repeat=True, iperiod=RECORDING_FPS
        )
        self.picam2.start_encoder(
            self.h264_encoder, self.segment_output, name="main"
        )
        self.recording = True
        self.current_session_id = session_id

    def stop_recording(self) -> None:
        session_id = self.current_session_id
        if self.recording and self.h264_encoder is not None:
            self.picam2.stop_encoder(self.h264_encoder)
        self.h264_encoder = None
        self.segment_output = None
        self.recording = False
        self.current_session_id = None
        if session_id is not None:
            emit_event("recording_stopped", session_id=session_id)

    def shutdown_driver(self) -> None:
        self.stop_recording()
        self.shutdown.set()
        if not self.sensor_sampler.join(SENSOR_TEMP_JOIN_TIMEOUT):
            raise TimeoutError("sensor temperature sampler did not stop")
        if self.preview_encoder is not None:
            self.picam2.stop_encoder(self.preview_encoder)
        if self.picam2 is not None:
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
    exchange = LifecycleExchange()

    stdout_writer = StdoutWriter(frames, shutdown)
    stdin_reader = StdinReader(commands, shutdown, exchange)

    if args.fake:
        driver = FakeCameraDriver(
            rec_dir=rec_dir,
            preview_fps=args.preview_fps,
            fake_sensor_fps=args.fake_sensor_fps,
            fake_crash_after=args.fake_crash_after,
            fake_segment_secs=args.fake_segment_secs,
            frames=frames,
            shutdown=shutdown,
            exchange=exchange,
        )
    else:
        driver = RealCameraDriver(
            rec_dir=rec_dir,
            preview_fps=args.preview_fps,
            frames=frames,
            shutdown=shutdown,
            exchange=exchange,
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
