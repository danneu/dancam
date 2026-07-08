# ADR: In-flight segment durability and boot scrub

- **Status:** Accepted
- **Date:** 2026-07-08
- **Owner:** raspi
- **Related:** `01-2026-06-22-crash-safe-recording.md`;
  `07-2026-06-25-picamera2-camera-owner.md`;
  `16-2026-07-02-storage-coordinator-segment-id-witness.md`;
  `18-2026-07-04-sd-card-layout-and-readonly-root.md`

## Context

A field power cut while recording left an in-flight segment as a stamped 0-byte file.
The camera owner fsynced segments only at close, so the current segment could sit
entirely in page cache. The deployed dirty-writeback clamps were verified live during
the failure and still saved nothing: ext4 delayed allocation can preserve the directory
rename while no data blocks have reached storage. Explicit periodic `fdatasync` is the
only layer that bounds this loss window.

The leftover also exposed a recovery gap. On reboot, the recorder starts idle, the
service reserves the next id, and the 0-byte segment listed as a normal finished clip.
The app could pull the empty body successfully because a zero-length HTTP body is a
complete response, then remuxing failed later with no playable H.264 packets.

The boot repair has to preserve the segment-id witness invariant from ADR 16. Any
mutation that fully removes a segment id must raise `state/state.json` `high_water_seq`
before unlinking, under the `StorageCoordinator` mutation mutex, or a later start could
reuse an id that already had a public ETag.

It must also avoid treating canonical clip selection as recovery truth. Clip listing
prefers a stamped filename over a bare duplicate for the same sequence, but recovery is
per path: a power cut can leave a stamped 0-byte file beside a bare nonzero file for the
same id. Nonzero video bytes are always more important than timestamp facts.

## Decision

The camera owner periodically `fdatasync`s the open segment from the segment watcher,
about every 2 seconds. The watcher is a crash boundary: periodic sync swallows every
`OSError`, including rollover races and writeback failures, logs only the first failure
in a run of failures, and retries on the next cadence instead of on every watcher tick.
The periodic path only targets ids observed by the watcher, which are already filtered
to the recording session's baseline or above. The existing close-time and shutdown syncs
remain, but their wrapper now also catches every `OSError` so a sync-time `EIO` or
`ENOSPC` cannot kill the watcher thread.

The Rust mock writer mirrors the same durability shape. It has a 2 second in-flight
sync cadence for the open mock segment, logs and continues on periodic sync errors, and
keeps rollover and stop syncs fail-fast. This keeps mock behavior aligned with the real
camera path without hiding finalization errors.

At service startup, before either backend starts, the storage coordinator will run a
zero-byte repair pass. The pass scans raw segment candidates before dedupe, groups every
path by sequence id, and judges recoverability per path:

- If every path for a sequence is 0 bytes, the whole id is unrecoverable. The
  coordinator raises `high_water_seq` to at least the max fully-deleted id before the
  first unlink, then removes every path for those ids and fsyncs the directory.
- If a sequence has at least one nonzero path, the id survives. The repair removes only
  the zero-byte duplicate paths and leaves the nonzero segment in place. A preserved id
  needs no witness bump because the file scan still prevents reuse.

Boot scrub failure logs an error and startup continues. A missing or bad `/data` must
not keep the control API and diagnostics offline. No `clip_removed` events are emitted
for boot scrub because no clients are connected yet.

## Consequences

Power-cut loss for the active segment is bounded to roughly the sync cadence plus
encoder buffering, instead of a whole segment sitting in page cache. This adds small,
bounded SD-card write pressure and demotes dirty-page clamps to defense in depth rather
than relying on them for correctness.

Truly empty leftovers no longer appear in `/v1/clips`, and fully deleted ids are never
reissued because the witness is raised before unlink. Truncated-but-nonzero segments
still list and can play up to the cut.

A mixed duplicate group keeps recoverable video. Removing a stamped 0-byte duplicate can
promote a surviving bare file to canonical, so the clip's ETag changes from `N-0` to
`N-<nonzero-bytes>`. That is not an alias: the byte count differs and the nonzero body is
the only recoverable footage.

The widened `try_fsync_segment` no longer distinguishes a vanished segment from a
failed sync in its log message. Both cases correctly keep the watcher alive.

## Alternatives considered

- **Rely on writeback clamps alone.** Rejected. The field failure happened with the
  clamps verified live.
- **Open or write segments synchronously.** Rejected. Per-write sync would add latency
  and card wear on the hot path; a bounded periodic sync is the narrower durability
  lever.
- **Shorter segments.** Rejected as the primary fix. They reduce the maximum segment
  duration but do not bound page-cache loss inside the current segment.
- **Use `data=journal` or very short ext4 commits.** Rejected for now. They are
  system-wide costs and still do not replace explicit file sync.
- **Filter zero-byte clips in the app.** Rejected. The Pi owns the recording truth;
  every client should not have to rediscover and hide unrecoverable files.
- **Keep 0-byte files.** Rejected. They have no recoverable video and create false
  clips for clients.
