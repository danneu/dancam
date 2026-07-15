# ADR: Operational status and recording readiness

- **Status:** Accepted
- **Date:** 2026-07-15
- **Owner:** raspi
- **Related:** [transport boundary](../../../docs/design/boundary/transport.md) (wire
  surface);
  `10-2026-06-30-recorder-fsm-and-events-sse.md` (canonical world and deltas);
  `23-2026-07-14-single-owner-camera-command-lifecycle.md` (command outcomes)

## Context

The old `/v1/health` route proved only that HTTP was responding. Deploy could
therefore announce success while the Picamera2 owner was still starting, and
operators had to combine health, status, logs, and mount inspection to decide
whether recording could actually begin. Adding readiness through filesystem
metadata also risked hanging the only useful operational probe when `/data`
stalled.

## Decision

`GET /v1/status` is the sole operational probe. It returns the canonical snapshot
with HTTP 200 whenever that snapshot can be serialized, including while camera or
storage readiness is false. `/v1/health` is removed; no separate live, ready, or
ping route replaces it. The first `/v1/events` frame is the same snapshot with
only the `type` discriminator added.

The snapshot has a required top-level `recording_readiness` replacement. Ready is
`{"ready":true,"reason":null}`. Non-ready reasons are `camera_starting`,
`camera_restarting`, `camera_offline`, and `recording_storage_unavailable`, in
that camera-first precedence order. Recorder error remains retryable and is not a
readiness reason. Storage readiness delegates to the same configured mount
witness used by recording mutations; without a required mount it succeeds.

Camera and storage changes derive readiness inside the shared world. Each
`camera_state_changed` and `storage_changed` delta carries the new direct value
and the complete matching readiness replacement. A mount-only readiness change
emits `storage_changed` even when quantized storage bytes are unchanged.

Startup, telemetry, status, and initial SSE use one single-permit filesystem
observer. Its fixed one-second end-to-end deadline covers permit acquisition and
probe completion. The blocking closure retains the permit until it actually
exits, so timed-out probes cannot accumulate or apply late. Each observation
combines the authoritative mount witness, disk usage, and best-effort current
segment duration. Timeout publishes unavailable storage and null duration; a
required mount fails closed, while an unconfigured mount remains ready. Startup
seeds this observation before the server begins serving.

Recording command results remain a separate boundary. Readiness explains whether
an operation should be attempted now; stable command codes describe the terminal
outcome of an attempted command, including lifecycle, storage, timeout, channel,
and recorder failures.

## Consequences

- Operators, deploy, reset, and HDR workflows use one canonical body for HTTP
  reachability and recording capability.
- Snapshot and delta folds cannot pair new camera or storage facts with stale
  readiness.
- A stalled recording filesystem makes evidence nullable and readiness fail
  closed without hanging status or spawning unbounded blocking work.
- Readiness is present-tense capability, not a replacement for recorder lifecycle
  or typed terminal command errors.

## Alternatives considered

- **Keep separate liveness and readiness routes.** Rejected because successful
  canonical status already proves liveness and another body would duplicate truth.
- **Compute readiness only in the status handler.** Rejected because status and
  SSE clients would observe different worlds.
- **Retain the last healthy filesystem observation on timeout.** Rejected because
  stale permission to record is more dangerous than unavailable evidence.
- **Make recorder error a readiness reason.** Rejected because command ownership
  deliberately permits retry from that phase.
