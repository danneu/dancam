# Pi operational telemetry and recording readiness

The Pi exposes one canonical operational view: the same snapshot drives one-shot
status checks and seeds the live event stream. Recording readiness is part of that
world rather than a separate health subsystem, and filesystem evidence is bounded so
a stalled recording card cannot hang the probe operators need to diagnose it.

This page owns operational status, recording-readiness derivation, the bounded
filesystem observation path, and recorder-writable capacity telemetry. The
[transport boundary](../boundary/transport.md) owns the snapshot and event wire
shapes; [recording](recording.md) owns recorder and camera lifecycle;
[storage](storage.md) owns the recording filesystem, mount witness, and ring-GC
floor; and [OS image](os-image.md) owns the `/data` partition layout.

## Canonical operational status

`GET /v1/status` is the Pi's sole operational probe. A successful response is the
canonical world snapshot with HTTP 200, including when the camera or recording
storage is not ready. There is no separate health, liveness, readiness, or ping
route. Successfully fetching and decoding status proves HTTP reachability; the
snapshot's `recording_readiness` value separately says whether recording can begin
now.

The first `/v1/events` frame contains the same snapshot plus the `type: "snapshot"`
event discriminator. Status and a new event connection both refresh the bounded
filesystem evidence before materializing their snapshot, so neither surface needs a
parallel operational model. The app uses the event stream for live state and
heartbeat liveness; deploy, reset, HDR, and operator workflows use status as a
bounded one-shot probe.

## Recording readiness

Every snapshot contains a required complete replacement:

```json
{"recording_readiness":{"ready":true,"reason":null}}
```

When readiness is false, `reason` is one of the following values, evaluated in this
camera-first precedence order:

1. `camera_starting`
2. `camera_restarting`
3. `camera_offline`
4. `recording_storage_unavailable`

The shared world derives readiness from camera state and the recording-storage mount
witness. Storage readiness uses the same configured `DANCAM_REQUIRE_REC_MOUNT`
witness as recording mutations. When no mount is required, storage readiness
succeeds; on the deployed unit, the required `/data` witness makes a missing or
wrong recording mount fail closed.

Camera and storage observations update readiness inside the same serialized world
transition. Every `camera_state_changed` event carries the new camera state and its
complete matching readiness replacement. Every `storage_changed` event carries the
complete nullable storage replacement and matching readiness. A mount-only
readiness change therefore emits `storage_changed` even when the quantized byte
values have not changed. Clients never have to combine a new camera or storage fact
with stale readiness.

Recorder lifecycle is deliberately not a readiness input. In particular, recorder
error remains retryable and is not another non-ready reason. Readiness answers
whether an operation should be attempted now; a recording command's stable result
code remains the terminal account of lifecycle, storage, timeout, channel, or
recorder failure after an attempt.

## Bounded filesystem observation

Startup, periodic telemetry, status, and initial SSE snapshots share one
`FilesystemObserver`. It combines three facts in one blocking observation:

- the authoritative recording-mount witness;
- `statvfs` disk usage and recording capacity; and
- the best-effort duration of the current segment when a snapshot needs it.

The observer has one semaphore permit and a fixed one-second end-to-end deadline.
The deadline includes both waiting for the permit and completing the blocking probe.
The blocking closure retains the permit until it actually exits, even after its
caller times out. A stalled filesystem therefore cannot accumulate blocking probes,
and a late result is discarded rather than overwriting newer state.

Before the server begins accepting requests, startup seeds storage and mount
availability through this observer. Periodic telemetry refreshes them every two
seconds. Status and the first SSE snapshot additionally observe the current segment
so they can publish a fresh best-effort duration without creating a second
filesystem path.

When the observation times out or its task fails, storage becomes `null` and current
segment duration becomes `null`. A configured recording mount becomes unavailable;
an environment with no required mount remains storage-ready. This distinction lets
the production unit fail closed while local mock runs remain usable without a
dedicated mount. Unavailable evidence replaces prior storage rather than retaining a
stale healthy sample.

## Recorder-writable capacity

Storage telemetry reports `used`, `total`, and exact
`recording_capacity_bytes`. Capacity is the maximum byte pool the non-root recorder
can cycle through while preserving the ring-GC floor. It is not current free space,
the amount of footage presently stored, or the time until the next eviction.

The calculation excludes ext4 blocks reserved from the non-root service and then
subtracts the shared GC floor:

```text
service_writable_bytes =
    total_bytes - ((f_bfree - f_bavail) * block_size)

recording_capacity_bytes =
    max(service_writable_bytes - gc_floor_bytes, 0)
```

Startup parses `DANCAM_GC_FLOOR_BYTES` once through the GC configuration and passes
that same value to both telemetry and ring GC. Saturating arithmetic keeps impossible
development configurations from underflowing. `used` and `total` are rounded down to
64 MiB buckets before entering the world, while `recording_capacity_bytes` stays exact
because the app uses it in retention arithmetic.

The snapshot's `storage` field and `storage_changed.storage` use the same complete
nullable shape. A successful production sample always derives capacity from
`statvfs`. Only the mock backend honors `DANCAM_MOCK_RECORDING_CAPACITY_BYTES`, which
provides a deterministic capacity for retention-UI smoke tests.

Capacity does not change when recording quality changes. The app estimates duration
from the capacity and the observed byte rate of fresh finalized clips, keeping codec
configuration and product sampling policy out of the Pi's storage authority.

## Decision log

### 2026-07-14 -- Report recorder-writable capacity

(absorbed from raspi ADR 22, 2026-07-14)

The Settings screen needed an honest estimate of how much footage the recording ring
could hold. Filesystem `total` was not that value because ext4 may reserve blocks for
root and ring GC deliberately preserves a non-root-writable free-space floor.
Configured encoder bitrate was also not a trustworthy observation of actual muxed
segment size.

The Pi already sampled `statvfs` for storage telemetry and separately parsed the GC
floor. Independently parsing that policy, or having the Pi compute duration, could
let telemetry and deletion policy disagree. The selected design therefore defined
an exact recorder-writable byte pool after root-reserved blocks and the shared GC
floor, while leaving duration estimation to the app's observed finalized clips.

Keeping capacity exact while quantizing `used` and `total` lets the app perform
duration arithmetic without turning the rest of storage telemetry into a noisy
high-frequency signal. Making snapshot and delta storage the same complete nullable
replacement also lets an online client converge from available evidence to probe
failure instead of retaining a stale value.

Exposing configured bitrate was rejected because actual muxed clip sizes are the
relevant observation and codec configuration is not storage authority. Having the Pi
report hours was rejected because it would make the Pi own a bitrate profile or
sampling policy that belongs in app product state. Using `f_bavail` directly as
capacity was rejected because it is current free space: the displayed retention
would shrink while the ring fills even though old footage remains replaceable.

### 2026-07-15 -- Make canonical status the recording-readiness probe

(absorbed from raspi ADR 24, 2026-07-15)

The old `/v1/health` route proved only that HTTP was responding. Deploy could announce
success while the Picamera2 owner was still starting, and operators had to combine
health, status, logs, and mount inspection to decide whether recording could begin.
Adding readiness through filesystem metadata also risked hanging the only useful
operational probe when `/data` stalled.

The canonical status snapshot became the sole operational probe, with one required
recording-readiness replacement derived inside the shared world. Pairing readiness
with camera and storage deltas prevents snapshot and event clients from observing
different capability worlds. The same bounded filesystem observer serves startup,
telemetry, status, and initial SSE so a stalled card makes evidence unavailable and
readiness fail closed without hanging status or spawning unbounded blocking work.

This gives operators, deploy, reset, and HDR workflows one body for HTTP reachability
and present-tense recording capability. It does not collapse readiness into recorder
lifecycle or typed recording-command outcomes: those remain separate evidence about
an operation that was actually attempted.

Keeping separate liveness and readiness routes was rejected because a successful
canonical status response already proves liveness and another body would duplicate
truth. Computing readiness only in the status handler was rejected because status
and SSE clients would observe different worlds. Retaining the last healthy filesystem
observation after a timeout was rejected because stale permission to record is more
dangerous than unavailable evidence. Making recorder error a readiness reason was
rejected because command ownership deliberately permits retry from that phase.
