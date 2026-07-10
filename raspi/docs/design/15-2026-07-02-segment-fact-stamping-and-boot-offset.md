# ADR: Segment fact stamping and boot offset

- **Status:** Accepted
- **Date:** 2026-07-02
- **Owner:** raspi
- **Related:** `02-2026-06-22-app-pi-transport-and-api.md` (the `/v1/time`,
  `/v1/events`, `/v1/status`, and clip-list wire contract);
  `03-2026-06-23-storage-ring-buffer-incident-lock.md` (segment identity, ring
  storage, incident pre-sync holds, and no-RTC ordering)

## Context

The Pi has no real-time clock. At boot, wall time can be wrong, but
`CLOCK_BOOTTIME` is trustworthy and continues across service restarts within the same
kernel boot. The camera can begin recording before the phone connects and posts a wall
clock sync, and the car can cut power without warning while a segment is open.

Earlier ADRs put segment facts in a rebuildable `index.log` and put boot wall-time
anchors in `state/state.json`. That shape has two avoidable failure modes for the
timestamp problem: an index can skew from the file it describes, and losing a sidecar
write around a power cut can permanently lose a timestamp that was knowable from the
segment's own creation facts.

The product needs timestamps that are good enough for dashcam evidence without making
wall time part of the recording path. The phone's clock is already NTP-maintained, and
the camera-owner process can stamp monotonic facts at segment open without knowing
wall time.

## Decision

Use a derive model: store measurements, not conclusions.

> **Scoped-superseded by ADR 20 (segment filename grammar and parser canon only).**
> The stamped form now carries a `session` field --
> `seg_<seq>_<boottag>_<sess>_<monoMs>.ts` -- and both parsers bound the numeric fields to
> their integer types (`u32` seq, `u64` sess/mono). Everything else in this ADR (bare-form
> semantics, the watcher rename/emit, write-once per-boot offset durability, the
> `start_ms = monoMs + offset_ms` time model) stays live and is not superseded.

Each segment filename carries immutable per-segment facts:

```text
seg_<seq>_<boottag>_<monoMs>.ts
```

- `seq` remains the stable numeric segment id, zero-padded to at least five digits and
  growing wider after `99999`.
- `boottag` is the first 12 lowercase hex characters of the kernel boot UUID after
  dash stripping.
- `monoMs` is `CLOCK_BOOTTIME` milliseconds captured when the segment is first
  observed open.

The previous bare form remains valid:

```text
seg_<seq>.ts
```

Bare names mean the segment facts are unknown. They can exist while ffmpeg has just
created a file and the watcher has not stamped it yet, if power dies inside that
window, if a rename fails, or for older fixtures. Bare is not a compatibility shim; it
is a real live state and always derives to approximate time.

The camera-owner ffmpeg output pattern stays `seg_%05d.ts`. A watcher polls the
recording directory, detects newly opened segments, captures boottime, renames the
bare file to the stamped filename, and then emits `segment_opened`. ffmpeg keeps the
file descriptor open, so renaming the path does not interrupt writes. If the rename
fails, the watcher logs the error and emits anyway; recording must not fail because
timestamp facts were unavailable.

Rust owns the same filename canon. The parser accepts only exact round trips of the
bare or stamped renderers: no short sequence aliases, uppercase tags, short or long
tags, or leading-zero monotonic aliases. Directory scans parse both forms, dedupe
same-seq bare/stamped duplicates by preferring stamped, and use scan-based resolution
for clip listing, clip pull, current-segment status enrichment, and next-sequence
selection.

Wall time lives outside the segment filename. When the app syncs time, the service
writes one per-boot offset file:

```text
<rec_dir>/time/<full-boot-uuid>.json
```

with:

```json
{"boot_id":"...","offset_ms":0,"source":"app","synced_at_mono_ms":0}
```

`offset_ms = epoch_ms - boottime_now_ms`. The file is write-once for that boot and is
persisted with temp-file write, file fsync, rename, and best-effort directory fsync.
Startup loads parseable offset files into a map keyed by boottag; a boottag collision
marks that tag unresolvable. Torn or unparsable files are skipped so the boot remains
resyncable.

`POST /v1/time` uses a single body:

```json
{"epoch_ms": 1767225600000}
```

The service rejects values outside `2026-01-01T00:00:00Z` through
`2100-01-01T00:00:00Z` before writing the offset. The earlier RTT-refined
`{epoch_ms, tz, send_ts}` handshake is dropped: the watcher poll already bounds
segment-open precision to roughly 0.25 s, so a single phone-clock POST is the simpler
and more honest precision model.

At read time, a stamped segment resolves:

```text
start_ms = monoMs + offset_ms
```

using the offset for that segment's boottag. If the segment is bare, the offset is
missing, the boottag is ambiguous, or checked arithmetic fails, `start_ms` is null and
`time_approximate` is true. No wall timestamp is written back into the segment name or
stored per segment.

The events/status contract gains `time: {synced: bool}` in snapshots and a
`time_synced {at_ms}` delta on the false-to-true transition. Clip listings and
`clip_finalized` derive `start_ms` and `time_approximate` from segment facts plus the
offset store. `server_time_ms` is null until the current boot is synced, then derives
from boottime plus the current boot's offset.

## Consequences

- A power cut cannot permanently lose a timestamp that can later be derived from an
  already-stamped segment and a per-boot offset.
- The crash segment remains self-describing enough to resolve after reboot: the file
  carries its sequence, boot tag, and monotonic open time.
- The SD card stays readable without an index; filenames carry the segment facts.
- Directory scans must be authoritative for segment resolution. Any path that
  reconstructs `seg_<seq>.ts` would fail against stamped files and could make restart
  sequence selection overwrite footage.
- Segment facts are monotonic-time facts, not wall-time filenames. Wall time remains a
  derived read-time interpretation.
- On non-Linux development hosts, Rust falls back from `CLOCK_BOOTTIME` to monotonic
  time and the Python camera owner falls back to `time.monotonic()` plus a random boot
  tag. That is acceptable for Mac tests but does not prove cross-process boot-id
  matching.
- Write-once offsets deliberately drop two capabilities from the earlier ADRs: GPS may
  not silently rebind a boot after the first accepted value, and an in-window but wrong
  first phone value cannot be corrected. A future GPS time source must introduce an
  explicit source-priority policy rather than assuming rebind.

## Alternatives considered

- **Wall-time filenames.** Rejected. Wall time is garbage at boot and must not be on
  the recording path. This ADR's stamped filename stores monotonic facts only; the wall
  conclusion remains derived.
- **Rebuildable sidecar index of segment facts.** Rejected. It can skew from the file
  under power loss and makes the evidence segment depend on a second write.
- **Mutable per-segment sidecar files.** Rejected. They multiply crash windows and add
  GC/index consistency work without improving the facts available at read time.
- **RTT-refined time handshake.** Rejected for v1. A single POST is precise enough
  relative to the watcher poll and avoids freezing a later correction protocol into the
  first implementation.
- **GPS can override any existing offset.** Deferred. GPS remains a possible future
  source, but write-once app offsets are simpler and safer for the current phone-owned
  clock model.
