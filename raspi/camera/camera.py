#!/usr/bin/env python3
"""DanCam camera-owner process.

stdout is raw concatenated JPEG frames only. stderr carries newline-delimited
JSON events and any plain-text diagnostics.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import queue
import re
import sys
import threading
import time
from typing import Any


SEGMENT_RE = re.compile(r"^seg_(\d{5})\.ts$")
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


def compute_skip(sensor_fps: float, preview_fps: float) -> int:
    return max(1, math.ceil(sensor_fps / preview_fps))


def next_segment_index(rec_dir: Path) -> int:
    highest = -1
    for path in rec_dir.iterdir():
        match = SEGMENT_RE.match(path.name)
        if match:
            highest = max(highest, int(match.group(1)))
    return highest + 1


def ensure_rec_dir(rec_dir: Path) -> None:
    rec_dir.mkdir(parents=True, exist_ok=True)
    if not rec_dir.is_dir():
        raise RuntimeError(f"{rec_dir} is not a directory")
    if not os.access(rec_dir, os.W_OK):
        raise RuntimeError(f"{rec_dir} is not writable")


def recording_ffmpeg_output(rec_dir: Path, segment_start_number: int) -> str:
    pattern = rec_dir / "seg_%05d.ts"
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


def run_self_test() -> int:
    assert compute_skip(30, 12) == 3
    assert compute_skip(30, 10) == 3
    assert compute_skip(30, 15) == 2
    assert compute_skip(30, 30) == 1
    assert compute_skip(30, 60) == 1
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
        frames: "queue.Queue[bytes]",
        shutdown: threading.Event,
    ):
        self.rec_dir = rec_dir
        self.preview_fps = preview_fps
        self.fake_sensor_fps = fake_sensor_fps
        self.fake_crash_after = fake_crash_after
        self.frames = frames
        self.shutdown = shutdown
        self.skip = compute_skip(fake_sensor_fps, preview_fps)
        self.preview_thread: threading.Thread | None = None
        self.recording_thread: threading.Thread | None = None
        self.recording = threading.Event()
        self.lock = threading.Lock()
        self.current_segment: Path | None = None

    def start(self) -> None:
        ensure_rec_dir(self.rec_dir)
        self.preview_thread = threading.Thread(target=self._preview_loop, name="fake-preview", daemon=True)
        self.preview_thread.start()
        emit_event("ready")

    def start_recording(self) -> None:
        with self.lock:
            if self.recording.is_set():
                emit_event("recording_started")
                return

            index = next_segment_index(self.rec_dir)
            self.current_segment = self.rec_dir / f"seg_{index:05d}.ts"
            self.current_segment.write_bytes(b"fake segment\n")
            self.recording.set()
            self.recording_thread = threading.Thread(
                target=self._recording_loop,
                name="fake-recording",
                daemon=True,
            )
            self.recording_thread.start()

        emit_event("recording_started")

    def stop_recording(self) -> None:
        with self.lock:
            was_recording = self.recording.is_set()
            self.recording.clear()
            thread = self.recording_thread
            self.recording_thread = None
            self.current_segment = None

        if was_recording and thread is not None:
            thread.join(timeout=1)

        emit_event("recording_stopped")

    def shutdown_driver(self) -> None:
        self.stop_recording()
        self.shutdown.set()
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
        while self.recording.is_set():
            segment = self.current_segment
            if segment is not None:
                with segment.open("ab") as file:
                    file.write(b"tick\n")
                    file.flush()
            time.sleep(0.1)


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
        self.picam2 = None
        self.preview_encoder = None
        self.h264_encoder = None
        self.recording = False

    def start(self) -> None:
        ensure_rec_dir(self.rec_dir)

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
        self.picam2.start()

        self.preview_encoder = MJPEGEncoder()
        self.preview_encoder.frame_skip_count = compute_skip(30, self.preview_fps)
        self.picam2.start_encoder(
            self.preview_encoder,
            PreviewQueueOutput(self.frames),
            name="lores",
        )
        emit_event("ready")

    def start_recording(self) -> None:
        if self.recording:
            emit_event("recording_started")
            return

        from picamera2.encoders import H264Encoder
        from picamera2.outputs import FfmpegOutput

        index = next_segment_index(self.rec_dir)
        output = recording_ffmpeg_output(self.rec_dir, index)
        self.h264_encoder = H264Encoder(bitrate=10_000_000, repeat=True, iperiod=30)
        self.picam2.start_encoder(
            self.h264_encoder,
            FfmpegOutput(output, audio=False),
            name="main",
        )
        self.recording = True
        emit_event("recording_started")

    def stop_recording(self) -> None:
        if self.recording and self.h264_encoder is not None:
            self.picam2.stop_encoder(self.h264_encoder)
            self.h264_encoder = None
            self.recording = False
        emit_event("recording_stopped")

    def shutdown_driver(self) -> None:
        try:
            self.stop_recording()
            if self.picam2 is not None:
                self.picam2.stop_encoder()
                self.picam2.stop()
        finally:
            self.shutdown.set()


def run(args: argparse.Namespace) -> int:
    if args.preview_fps <= 0:
        emit_event("error", detail="--preview-fps must be positive")
        return 1
    if args.fake_sensor_fps <= 0:
        emit_event("error", detail="--fake-sensor-fps must be positive")
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
                    driver.start_recording()
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rec-dir", default=os.environ.get("DANCAM_REC_DIR", "/home/dan/rec"))
    parser.add_argument("--preview-fps", type=float, default=10)
    parser.add_argument("--fake", action="store_true")
    parser.add_argument("--fake-sensor-fps", type=float, default=30)
    parser.add_argument("--fake-crash-after", type=int)
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        return run_self_test()
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
