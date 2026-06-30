# ADR: Recorder FSM and events SSE

- **Status:** Accepted
- **Date:** 2026-06-30
- **Owner:** raspi
- **Related:** `02-2026-06-22-app-pi-transport-and-api.md`;
  `03-2026-06-23-storage-ring-buffer-incident-lock.md`;
  `07-2026-06-25-picamera2-camera-owner.md`; root `AGENTS.md`

## Context

The Pi service initially exposed `/v1/status` as a polled dashboard snapshot. That
was a stopgap for the event plane already selected in ADR 02. It also left the
current recording segment inferred from the filesystem: while recording, the newest
`seg_*.ts` file was treated as the live segment and hidden from clips.

That inference is not authoritative enough. Start, rollover, stop, and camera
failure are domain transitions, not directory guesses. A partial segment can exist
before the recorder has observed it as open, and a crash after rollover must not
hide an already-finalized earlier segment.

## Decision

The Pi service owns a pure recorder state machine and broadcasts every accepted
transition over `GET /v1/events`.

The recorder state is:

- `phase`: `idle`, `starting`, `recording`, `stopping`, or `error`
- `session`: a monotonic per-boot session id, starting at 0 before the first start
- `current_segment`: the live segment id, present only after a real segment has
  been observed open
- `detail`: an error detail only in `error`

Internally the FSM also tracks `start_segment` and `unpullable_floor`. The floor is
the clips exclusion boundary: `None` only at clean idle, otherwise files with
`seq >= floor` are not listable or pullable. `start` seeds the floor from the
adapter-scanned next segment id, `segment_opened` advances it, clean stop clears
it, and failure preserves it at the last-opened segment.

Every child lifecycle event is session-guarded, and segment events are floor-guarded.
Stale sessions and below-floor segment ids are dropped. Failure is deliberately a
session-less control input: child `error`, child exit, spawn failure, and camera
offline do not carry a session to echo, so failure acts on the live session, clears
`current_segment`, preserves the clips floor, and emits `recorder_failed`.

`GET /v1/events` is an SSE stream:

- the first frame is `snapshot`
- subsequent frames are ordered deltas
- `heartbeat` is emitted periodically for liveness
- `seq` rides the SSE `id:` line, not the JSON body
- `at_ms` and `t_ms` are monotonic milliseconds since boot, not wall-clock time

`EventHub` owns `Mutex<{world, seq}>`, a `broadcast` channel for ordered `SeqEvent`s,
and a lean `watch<LiveStatus>` containing only recorder phase and camera state.
`drive()` mutates `World` and broadcasts each event while holding the mutex.
`connect()` subscribes, snapshots, and reads `seq` while holding the same mutex. This
gives the exactly-once invariant: an event is either represented in the snapshot or
delivered on the receiver, never both.

`GET /v1/status` now returns the same `Snapshot` type as the stream's first event,
as a one-shot JSON response. The pure hub snapshot contains only the FSM-owned
current segment id. The handlers enrich `current_segment.dur_ms` outside the hub
lock using the existing TS duration cache; failures leave it null.

Rollover and stop finalization are atomic inputs. Rollover emits
`clip_finalized(old)` and `segment_opened(new)` from one `World::apply`, so the floor
advances to the new open segment in the same lock hold that announces the old clip.
Stop emits `clip_finalized(last)` and `recording_stopped` together, clearing the
floor only when the last segment is already finalized.

`clip_finalized.dur_ms` is computed at finalization from the segment **file** (its PTS
span), outside the hub lock -- the same derivation `/v1/clips` uses, so the two agree by
construction even though they run at different times. The backend owns one
`DurationCache` that the finalize path and `/v1/clips` share; sharing it only avoids a
redundant re-scan at list time and is **not** what makes the values consistent (two
separate file-backed caches would derive the identical value from the same file).

The mock backend drives the full event taxonomy, and the real camera backend tracks
sessions and segments and finalizes duration-bearing `clip_finalized` events through
`parse_stderr` against ADR 07's session/segment child protocol. Both dev fakes -- the
Rust `MockBackend` writer and the Python `camera.py --fake` driver -- now write valid TS
(minimal PTS-bearing packets) so their finalized clips carry a real duration.

## Consequences

- The live row has a single authority: `snapshot.recorder.current_segment`.
- Partial open files are never listed or served during the start window, even if the
  encoder creates the file before the watcher reports it.
- A post-rollover crash hides only the unclean partial segment; the already-finalized
  previous segment remains listable and pullable.
- `/v1/status` remains useful for one-shot debug and CarPlay status, but liveness and
  live state move to `/v1/events`.
- The hub lock is never held across filesystem duration work.
- Clients reconnect on stream lag or EOF and receive a fresh snapshot. `Last-Event-ID`
  is intentionally ignored.

## Alternatives considered

- **Keep polling `/v1/status`.** Rejected. Polling recreates ordering races that the
  recorder FSM and ordered SSE stream are meant to remove.
- **Derive the clips floor from `current_segment`.** Rejected. Failure clears
  `current_segment`, but the unclean partial still has to stay hidden.
- **Put `seq` in the JSON body.** Rejected. The SSE `id:` line is the stream sequence,
  while the JSON body remains the language-neutral event corpus.
- **Use one failure event carrying camera state and recorder failure.** Rejected.
  Failure inputs do not carry camera state, and camera supervision inputs do not
  carry failure detail. Emitting each event from the input that owns its data keeps
  the model honest.
