# ADR: Picamera2 camera-owner subprocess

- **Status:** Accepted
- **Date:** 2026-06-25
- **Owner:** raspi
- **Related:** `01-2026-06-22-crash-safe-recording.md`;
  `02-2026-06-22-app-pi-transport-and-api.md`;
  `05-2026-06-23-service-language-rust.md`

## Context

`fox` proved the app can render live MJPEG preview over the Pi AP, but it did so by
spawning `rpicam-vid --codec mjpeg` per preview request. That cannot satisfy `jet`:
the camera must record 1080p30 H.264 while still serving a low-res preview. libcamera
only allows one process to own the camera, and `rpicam-vid` does not provide the
process contract we need for independent recording and preview streams.

Picamera2 can configure one camera owner with a `main` stream for H.264 recording and
a `lores` stream for MJPEG preview. The Rust service should still own the HTTP API,
state transitions, restart policy, and future storage integration; the camera stack is
best isolated behind a small subprocess boundary.

## Decision

Use a single long-lived Python Picamera2 subprocess as the camera owner for `jet`.
The Rust service supervises it over stdio:

- stdout is raw concatenated JPEG frames from the lores preview stream.
- stdin is newline-delimited JSON commands: `start_recording`, `stop_recording`,
  and `shutdown`.
- stderr is newline-delimited JSON events: `ready`, `recording_started`,
  `recording_stopped`, and `error`; non-JSON stderr is treated as logging.
- recording bytes stay inside the camera process, which writes segmented MPEG-TS
  files under `DANCAM_REC_DIR`.

The process configures Picamera2 once, starts the camera once, keeps preview running,
and toggles only the H.264 encoder/output for recording. It uses MPEG-TS segments with
inline H.264 headers and monotonically continued `seg_NNNNN.ts` numbering so a second
recording session cannot overwrite earlier footage.

Keep the process boundary even if the camera owner is later rewritten in Rust. A crash
in libcamera, Picamera2, ffmpeg, or a future camera binary must not take down the
control API; the parent can restart the child and surface camera state to the app.

## Consequences

- Concurrent preview plus recording is now architecturally possible: one camera owner
  emits independent main and lores streams, and the Rust service fans preview frames
  out to clients without touching recording bytes.
- The Rust service language decision still stands. The service remains Rust, deployed
  as a static binary under systemd; only the camera subprocess changes from
  `rpicam-vid` to Picamera2.
- ADR 05's rejection of Python+Picamera2 as the service language is partly reopened
  for the camera subprocess. The dev image now needs CPython, Picamera2, numpy, and
  ffmpeg installed from apt.
- The read-only car image must account for that Python stack. Either the future
  all-Rust camera owner lands before the read-only image, or the Python/Picamera2
  stack is deliberately baked into the image as inert files rather than installed at
  runtime.
- RAM headroom on the 512 MB Zero 2 W is now a gate, not an assumption. The hardware
  spike must measure camera-process RSS and swap behavior while recording and
  previewing; sustained swap or OOM is a failure even if CPU and temperatures look
  acceptable.
- The app and HTTP contract do not depend on Python specifics. A future Rust camera
  binary can reimplement the same stdio contract without changing the app or HTTP
  routes.

## Alternatives considered

- **Continue with `rpicam-vid`.** Rejected. It is fine for preview-only bring-up, but
  it cannot own the camera once while emitting both recording and preview streams for
  the service.
- **Run separate preview and recording processes.** Rejected. libcamera permits only
  one camera owner, so the second process would fail or contend with the first.
- **Link libcamera/Picamera2 in-process.** Rejected. It would remove the crash
  boundary and tie the HTTP service's uptime to camera-stack failures.
- **Build the all-Rust camera owner now.** Deferred. It is still the likely end state
  for the car image, but Picamera2 is the fastest supported path to validate the
  concurrency risk on real hardware.
