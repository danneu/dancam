# Plan: unified `/v1/events` event model + Pi-owned recorder state machine

> Supersedes and absorbs `plans/wip/recorder-state-machine-source-of-truth.md`.
> That plan should be deleted (or marked superseded) when this lands -- its
> recorder FSM, child-protocol extension, and live-row bug fix are folded in
> here, reconciled to the event model. Suggested rename for this file once
> approved: `plans/wip/events-sse-recorder-fsm.md`.

## Context

We are migrating dancam from a **poll-based** app<->Pi link to a **push-based,
event-sourced** one, and in the same move restructuring both sides' state into
enum state machines so impossible states are unrepresentable. This is the event
plane the transport ADR (`raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md`,
"Events / heartbeat") committed to from day one and then deferred -- `fern`
shipped `/v1/status` polling as an explicit stopgap ("add `GET /v1/events` only if
polling makes the dashboard worse"), and connection truth was built on ADR 04's
three-strike debounce riding a 1.5s `/v1/status` poll (the interval is owned by ADR 06
and restated in ADR 09; ADR 04 states no interval). We are now realizing the SSE
plane and retiring the stopgap.

Two forces converge here:

1. **The user's goal:** a robust event model -- a typed sum of fixed event types,
   state machines, impossible-states-impossible, maximally testable on both the
   Rust service and the iOS app.
2. **A discovered, unimplemented sibling plan:** `recorder-state-machine-source-of-truth.md`
   (dated today) independently designs a Pi-owned recorder state machine to fix a
   real bug -- pressing Record briefly shows the last *finished* clip as the live
   `REC` row, because three layers each guess at "which segment is open." It claimed
   raspi ADR 10 and restructured the same files.

These are the same refactor from two angles: the recorder plan owns the *domain
authority* (who decides the current segment), this migration owns the *transport*
(how state reaches the app). **Decision (confirmed): unify them.** The recorder
FSM's lifecycle transitions become the SSE wire events; its child-protocol
extension is exactly what makes real-camera rollover events work; and because SSE
delivers in order, we **drop the recorder plan's `revision` guard and its
read-your-writes mutation bodies** -- the out-of-order-poll problem they solve does
not exist without polling. The unified design is *less* machinery, fixes the
live-row bug by construction, and is the "ideal solution, full stop."

**Intended outcome:** the Pi owns an explicit recorder state machine that is the
single source of truth for recording phase + current segment; every accepted
transition emits a typed event; events flow over one ordered `GET /v1/events` SSE
stream (snapshot-on-connect, then deltas, then heartbeat); the app's live state is
a **pure fold** over that stream; connection liveness is heartbeat-presence; and
both sides model state as sum types. `/v1/status` and `/v1/clips` survive only as
one-shot reads; the 1.5s status poll, the 10s clips poll, the three-strike
debounce, the cross-feature diff-coupling, and the connection flag-cluster are all
deleted.

## Locked decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Snapshot delivery | **Snapshot as the first SSE event.** `/v1/events` = `snapshot` then deltas then heartbeat. App state = pure fold. `/v1/status` survives as a thin one-shot of the same `Snapshot` type. |
| 2 | Scope | **Status + clips.** Retire both polls; `clip_finalized` folds new clips; `/v1/clips` stays one-shot history. |
| 3 | Landing | **Short stack** (now 5 commits -- the unification adds the atomic child-protocol commit). Each green on its own; ADR notes land in lockstep. |
| 4 | Recorder relationship | **Unify** the recorder FSM into this migration. One raspi ADR 10. |
| 5 | Recorder shape | **Recorder plan's model, minus `revision`:** `RecorderPhase` Idle/Starting/Recording/Stopping/Error + `SessionId` + `current_segment{id, dur_ms?}`. SSE ordering subsumes `revision`. |
| 6 | Forward-compat | Clients **ignore unknown event types** (ADR 02's "clients ignore unknown keys"), so future variants are additive with no wire bump. |

## Architecture (one picture)

```
  camera child (camera.py)                          Pi service (Rust)
  --------------------------                        ------------------------------------
  stdin:  {start_recording, session_id,             backend scans rec_dir -> start_segment (I/O)
           start_segment_index}                     |
  stderr: recording_started{session}      --------> RecorderState (pure FSM, recorder.rs)
          segment_opened{session,id}      --------> apply(event) -> Vec<Event>  (session+floor guards)
          segment_closed{session,id}      --------> |
          recording_stopped{session}      --------> EventHub (event_hub.rs)
          error{detail}                             |  std::sync::Mutex<{world, seq}>
                                                     |  broadcast<SeqEvent>  + lean watch<LiveStatus>
                                                     v
                                          GET /v1/events  (SSE: snapshot-first, deltas, heartbeat)
                                          GET /v1/status  (one-shot Snapshot, debug/CarPlay)
                                                     |
                                                     v  one ordered stream, pinned NWConnection
  iOS app (DanCam)                                   |
  ----------------                                   v
  EventsClient -> SSEEventParser -> CameraEvent  -> World.folding (pure fold)
                                                  -> Link {connecting | online(World) | offline(last:)}
                                                  -> live REC row from world.recorder.current_segment ONLY
                                                  -> heartbeat-gap -> offline; reconnect -> fresh snapshot
```

The keel everywhere is a **pure function**: `apply(state, input) -> events` (Rust)
and `folding(world, event) -> world` (Swift). No tokio, no HTTP, no UIKit in
either -- they are unit-tested in isolation, and the same golden JSON corpus pins
the wire shape both sides decode.

---

## The wire contract (commit 1 -- the keel)

One externally-tagged sum type, `#[serde(tag = "type", rename_all = "snake_case")]`,
following serde's externally-tagged-enum pattern. (This is a *new* HTTP enum, **not** a
reuse of `status.rs#enum ChildEvent`: that child-stderr enum is `Deserialize`-only and
discriminates on `#[serde(tag = "event")]` -- a separate discriminator at a separate
layer. The two never share a type; the parallel is the serde shape, not the enum.)

```rust
#[serde(tag = "type", rename_all = "snake_case")]
enum Event {
    Snapshot(Snapshot),                              // first SSE frame; also GET /v1/status body
    RecordingStarting { session: u64, at_ms: u64 },  // start command accepted; phase -> Starting (no encoder/file yet)
    RecordingStarted { session: u64, at_ms: u64 },   // phase -> Recording (encoder up, no file yet)
    SegmentOpened    { session: u64, id: u32, at_ms: u64 },  // current_segment := Some(id)
    ClipFinalized(ClipMeta),                         // a finished segment is now listable/pullable
    RecordingStopping { session: u64, at_ms: u64 },  // stop command accepted; phase -> Stopping
    RecordingStopped { session: u64, at_ms: u64 },   // phase -> Idle
    RecorderFailed   { session: u64, detail: String, at_ms: u64 },  // phase -> Error
    CameraStateChanged { state: CameraState },       // child-supervision health (orthogonal)
    StorageChanged   { used: u64, total: u64 },
    TempChanged      { soc: Option<f32>, sensor: Option<f32> },
    MemChanged       { total: u64, available: u64, swap_total: u64, swap_used: u64 },  // quantized; see telemetry task
    Heartbeat        { t_ms: u64 },                  // liveness; per-boot seq rides the SSE id: line
}
```

`Snapshot` is the full bootstrap state; its recorder slice is the FSM projection:

```rust
struct Snapshot {
    recorder: RecorderSnapshot,   // { phase, session, current_segment: { id, dur_ms? }?, detail? }
    camera_state: CameraState,    // Starting | Running | Restarting | Offline
    boot_id: String,
    uptime_s: u64,
    storage: Option<DiskUsage>,
    temp_c: TempC,
    mem: Option<MemInfo>,
}
```

Key contract decisions:

- **`seq` rides the SSE `id:` line, not the JSON body.** Each frame is
  `id: <seq>\n` then `data: <event-json>\n\n`. So the `data:` line is *byte-for-byte*
  the golden `Event` value -- the corpus files are exactly what crosses the wire, and
  fixtures stay deterministic (no per-boot counter to pin). We deliberately ignore
  `Last-Event-ID` on reconnect: any uncertainty -> reconnect -> fresh snapshot. We **commit to
  the bare-`Event` body + `id:` line** -- no `Frame { seq, event }` envelope: the app's SSE parser
  is hand-rolled (`SSEEventParser`, below), so it reads the `id:` line directly (ignoring it, or
  surfacing it for debug), and there is no opaque client library that could fail to expose `id:`.
  Locking this in commit 1 keeps the corpus byte-for-byte the `Event` value, with no envelope
  branch left dangling on a commit-4 discovery.
- **`at_ms` / `t_ms` are monotonic-since-boot, never wall-clock.** The Pi has no RTC and wall-clock
  provenance is owned by `moss` (ADR 02), so every event timestamp is milliseconds since boot -- a
  **display/ordering aid only, never evidence-grade**, paired with the snapshot's `boot_id` epoch.
  Authoritative ordering is `seq` (the `id:` line); authoritative finished duration is `clip_finalized`.
  An implementer must **not** stamp wall-clock here (meaningless pre-sync, and falsely evidence-looking).
  (We keep them rather than drop them: `t_ms` makes heartbeat spacing visible in `curl -N` and composes
  with `boot_id` -- a specified affordance, not a just-in-case field. `seq` alone would also order, so
  dropping them is the cheaper alternative if a future reviewer prefers it.)
- **`segment_opened` and `clip_finalized` are separate** (not a combined `segment_rolled`).
  Start emits `segment_opened` only; rollover emits `clip_finalized`(old) + `segment_opened`(new);
  stop emits `recording_stopped` + `clip_finalized`(last). Decomposing matches the recorder
  child events and composes correctly at all three moments.
- **Struct/struct-newtype variants only.** serde cannot internally-tag a newtype wrapping a
  bare enum/primitive, so payloads carrying a `CameraState`/`Storage`/`TempC` are struct
  variants (`{type, state}`), and `Snapshot`/`ClipMeta` newtypes serialize as maps. Confirmed
  constraint; the corpus enforces it.
- **The `Starting`/`Stopping` command-phases are first-class events, not optional.** The accepted
  `start`/`stop` transition emits `recording_starting` / `recording_stopping` *synchronously* (from the
  command path in `apply`, before any child confirmation), so the stream is a complete record of every
  accepted transition: an already-connected non-commanding client (a second phone, a future CarPlay
  status surface) sees "Starting..." the instant the command is accepted, not only after the later
  `recording_started`/child event or a reconnect snapshot. They are *also* carried in
  `snapshot.recorder.phase` for a client that joins mid-phase. The commanding client still overlays its
  own optimism locally (the Record button), but that is a UI nicety layered on the authoritative phase,
  not the source of it. This is what makes "app state = pure fold of all authoritative state" literally
  true rather than true-modulo-two-phases.

**Golden corpus:** repo-root `contract/events/<variant>.json`, one canonical file per
variant. Both suites read it directly from the source tree at compile-time anchors -- Rust via
`env!("CARGO_MANIFEST_DIR")` + `../../contract/events`, Swift via `#filePath` walked to repo
root (the `DanCamTests/Media/MediaFixtureURLs.swift` + `PreviewClientTests#mockPreviewFrameURL`
precedent). No bundling, no `.pbxproj` edit, single source of truth. Use exactly-representable
floats in fixtures (e.g. `51.5`, not `51.234`) to avoid f32 shortest-representation drift
between serde_json (`ryu`) and Swift's decoder.

---

## Rust service (commits 2-3)

### New module layout

| Module | Status | Responsibility | tokio/axum? |
|---|---|---|---|
| `raspi/service/src/recorder.rs` | new | Pure recorder FSM: `RecorderPhase`, `RecorderSnapshot`, `RecorderEvent`, `RecorderState` (session + floor guards), `is_active`, `unpullable_from` (the clips exclusion floor). No I/O. | No |
| `raspi/service/src/world.rs` | new | `World` (recorder + camera + telemetry), pure `apply(&mut World, Input, now_ms) -> Vec<Event>`, pure `World::snapshot` (FSM projection -- `current_segment.id` only, no `dur_ms` I/O). serde only. | No |
| `raspi/service/src/events.rs` | new | Wire `Event` enum, `Snapshot`, the `/v1/events` + `/v1/status` handlers, golden-corpus tests. | axum |
| `raspi/service/src/event_hub.rs` | new | Runtime glue: `EventHub` (`Mutex<{world,seq}>` + `broadcast` + lean `watch`), `drive`/`connect`/`snapshot`/`tick`, heartbeat task. | tokio |
| `raspi/service/src/status.rs` | deleted | `Status` removed; handlers -> `events.rs`; `CameraState`/`TempC` -> `world.rs`; `ChildEvent` -> `camera/mod.rs`. | -- |

`world.rs` (pure) is split from `event_hub.rs` (tokio) so the FSM is the unit-test keel that
imports only serde + the plain data structs `ClipMeta`/`DiskUsage`/`MemInfo`/`CameraState`.

### The recorder FSM (`recorder.rs`) -- recorder plan's model, minus `revision`

```rust
type SessionId = u64;   // 0 = never started; +1 each start
type SegmentId = u32;   // the seq; reuses seg_NNNNN.ts numbering

enum RecorderPhase { Idle, Starting, Recording, Stopping, Error }

struct RecorderState {            // internal; also retains start_segment + unpullable_floor (never on the wire)
    phase: RecorderPhase,
    session: SessionId,
    current_segment: Option<SegmentId>,   // live REC row; Some only once a real file is open; cleared on stop/fail
    start_segment: SegmentId,             // immutable baseline for the floor guard
    unpullable_floor: Option<SegmentId>,  // clips exclusion floor; advances on SegmentOpened, preserved on fail(), None only at clean Idle
    detail: Option<String>,
}

enum RecorderEvent {                         // child -> FSM (internal); every variant is session-guarded
    RecordingStarted { session },
    SegmentOpened    { session, id },
    SegmentClosed    { session, id },        // informational; current advances on next Opened
    RecordingStopped { session },
}                                            // NB: failure is NOT a child event -- see fail() (control-driven, session-less)

impl RecorderState {
    fn start(&mut self, session, start_segment);  // Idle/Error -> Starting{current:None}; start_segment + unpullable_floor := start_segment
    fn stop(&mut self, session);                  // Starting/Recording -> Stopping
    fn apply(&mut self, RecorderEvent);           // guarded transitions; SegmentOpened advances unpullable_floor
    fn fail(&mut self, detail);                   // control-driven, session-LESS, bypasses both guards: active phase -> Error (clears current_segment, PRESERVES unpullable_floor); Idle/Error -> no-op
    fn snapshot(&self) -> RecorderSnapshot;
    fn is_active(&self) -> bool;                  // Starting | Recording | Stopping
    fn unpullable_from(&self) -> Option<SegmentId>;  // returns unpullable_floor (None only at clean Idle)
}
```

Two guards on every child event (rejected events are dropped + logged, change nothing):

1. **Session guard:** event `session != live session` -> dropped. A late event from a stopped
   session cannot leak into a new one.
2. **Floor guard:** `SegmentOpened`/`SegmentClosed` with `id < start_segment` -> dropped. A
   pre-existing file (always below the floor) can never be promoted to `current_segment`. This
   is the Rust-side enforcement of the same baseline the child watcher applies -- defense in
   depth, FSM as final authority.

**Failure is the exception to the session guard (carried verbatim from the superseded recorder
plan's `fail`).** `fail(detail)` is *control-driven, not a child event* -- it acts on whatever
session is live, so it carries no `session` and bypasses both guards. This is correct because **no
failure source has a session to echo:** the child `error` event is session-less
(`status.rs#ChildEvent::Error { detail }`; today `camera/mod.rs#parse_stderr` maps it to a bare
`tracing::error!`), and child exit, spawn failure, and the camera-offline transition are all driven
from `camera/mod.rs#supervise` with no session in hand (they only flip `camera_state` via
`Status::restarting()`/`offline()`). Routing failure through the session guard would let a camera
death whose *synthesized* session didn't match be silently **dropped** -- stranding `current_segment`
and leaving a phantom live row while the camera is offline. So failure stays a session-less control
input.

`current_segment` is `None` during `Starting` and `Recording{None}`, `Some(id)` only after
`SegmentOpened` -- **this is the live-row bug fix:** a phantom row can never appear for a
not-yet-written segment, and old clips stay listed during `Starting`. The Record button's
optimism lives in *local app state*, not in `current_segment`. We **drop `revision`**: the
ordered SSE stream removes the out-of-order-poll window it guarded.

**Clips exclusion floor (`unpullable_floor`) -- a field, not a derivation.** `current_segment` drives
the live row and so clears on stop/fail; the *clips* floor must not, so the FSM tracks it separately:
`start` sets it to `Some(start_segment)`; each accepted `SegmentOpened{id}` advances it to `Some(id)`;
`RecordingStopped` clears it to `None` (clean Idle -- the last segment is finalized in the same `apply`
that emits `clip_finalized(last)`, so no exclusion gap opens); a **`fail` preserves it** at the
last-opened id. Deriving it as `current_segment.unwrap_or(start_segment)` is wrong: after a roll
(43 finalized, 44 open) a crash clears `current_segment`, and a `start_segment`-derived Error floor (43)
would hide the already-finalized 43, whereas the preserved last-opened floor (44) keeps 43 listable and
excludes only the unclean partial 44. `unpullable_floor` is internal (like `start_segment`), never on
the wire `RecorderSnapshot`.

**Transition robustness (carried verbatim from the superseded recorder plan -- pin these in tests).**
The child's segment watcher runs on its own thread, so its first `SegmentOpened` can reach the FSM
*before* the driver's `RecordingStarted`. So: a `SegmentOpened{id}` (`id >= floor`) accepted out of
`Starting` promotes straight to `Recording{current: Some(id)}`, and a later `RecordingStarted` observed
while already `Recording` is a **no-op that never clears `current`**. Whichever of the two arrives first
moves `Starting -> Recording`; the open file becomes authoritative the instant it is observed. Without
this, a lost race would strand `current_segment` at `None` and the open partial would be listed/pullable
until the next rollover. The accepted `start`/`stop` *commands* are themselves transitions and emit
`recording_starting` / `recording_stopping` (see world.rs); a rejected or idempotent-no-op command emits
nothing.

### The world + pure transition (`world.rs`)

`World` wraps the recorder FSM plus orthogonal camera/telemetry state. `Input` unifies child
events, commands, telemetry, tick, **camera-supervision health** (the input that updates
`world.camera_state` and emits `camera_state_changed`), and **failure**; `apply` mutates `World` and
returns the wire events to broadcast. `now_ms` is injected so `apply` stays pure and deterministic. `ClipMeta` flows *in*
via the input (built by the I/O adapter with its TS-PTS `dur_ms`), keeping `apply` free of
filesystem work while guaranteeing `clip_finalized` is emitted in order with the lifecycle. **This
holds at stop as well as at rollover:** the watcher only signals a segment's close when a *successor*
opens (`detect_segment_events` emits `closed{prev}+opened{new}` on a new max), so the **last** segment
of a session has no closing event -- the child's `recording_stopped` is its only finalize signal. So
the adapter, on `recording_stopped`, builds `ClipMeta(last)` (the same I/O step as every other
`ClipMeta`) and drives a *single* input that `apply` turns into `[clip_finalized(last),
recording_stopped]` atomically: the last segment is finalized in the same `apply` that clears
`unpullable_floor` to `None`, so no clips-exclusion gap opens on `/v1/clips`/`serve_clip` and the
just-recorded clip reaches the app as a `clip_finalized` delta -- not only after a `/v1/clips` reload.
**Rollover is finalized the same atomic way -- and more pressingly than stop:** on the child's
`segment_closed{old}` + `segment_opened{new}` the adapter builds `ClipMeta(old)` and drives a *single*
combined input that `apply` turns into `[clip_finalized(old), segment_opened(new)]`, so the floor
advances `old -> new` in the **same** `apply` (one lock hold) that emits `clip_finalized(old)`. Two
separate inputs would open a window where the floor is still `old` *after* a client has already
observed `clip_finalized(old)`, and `serve_clip(old)` 404s in that window -- a transient violation of
"`clip_finalized` means listable + pullable" on *every* rollover. (At stop the floor goes to `None`, so
a split there is benign; only at rollover does the intermediate `old`-floor 404 the just-finalized clip,
so rollover gets the same single-input treatment stop already has.) **The closing id comes from one
place:** the adapter keeps a local cursor over the last `segment_opened{id}` it forwarded -- fed by the
same child stream the FSM consumes, not a fourth independent guesser, and deliberately *not* read from
the hub (whose lean `watch<LiveStatus>` carries `phase`/`camera_state`, no segment id). At rollover the
child's `segment_closed{old}` agrees with that cursor; at stop (no closing event at all) the cursor is
the *only* source of `last`.
Without this the real camera path silently drops the last clip from the stream (only `MockBackend`
finalizes today); it is the one seam mock-first coverage structurally cannot protect.
`World::snapshot` is **pure**: its `recorder.current_segment` carries only the FSM-owned `id`
(`dur_ms: None`) and it touches no filesystem, so the `world.rs` "serde only / no I/O" row holds
literally and `connect()` builds the snapshot under the hub lock with zero blocking I/O. The
mid-segment `dur_ms` offset is enriched **outside** the lock, in the async `/v1/events` and
`/v1/status` handlers: from the captured `current_segment.id` they read the open file's duration via
the existing `ts_duration::DurationCache` in a `spawn_blocking` (the current `status.rs#fn status`
pattern), best-effort (`None` on any failure, or on a roll between capture and read), before
serializing. Duration is a display offset, never authoritative (`clip_finalized` carries the
finished duration), so it stays out of the exactly-once proof. The accepted
`start`/`stop` command inputs are first-class transitions, and they carry their I/O-derived data
the same way `ClipMeta` does: `Input::StartCommand { start_segment }` carries the adapter-scanned
next index (`max_seq+1` from a `rec_dir` scan), so the FSM never touches the filesystem. On that
input `apply` selects only the session (`session = prev+1`, pure in-memory -- the FSM owns the
monotonic session counter), calls `RecorderState::start(session, start_segment)`, and emits
`recording_starting`; `stop` emits `recording_stopping`. Both fire synchronously from the command
(a rejected or idempotent-no-op command emits nothing), so every accepted phase change --
command-driven or child-driven -- is on the wire exactly once. The adapter learns the apply-selected
session from the events `drive` returns (the emitted `recording_starting` carries it; allocation is
atomic under the hub lock) and forwards it to the camera child. Failure is the one control input that
is **session-less**: `Input::Fail { detail }` routes to `recorder.fail(detail)` on the live session
(bypassing the session guard, since no failure source carries a session) and emits **only**
`recorder_failed`; it never emits `clip_finalized`/`recording_stopped` (the interrupted segment is an
unclean partial), and the preserved `unpullable_floor` keeps that partial excluded from clips.
`Input::Fail` carries no camera state, so it cannot and does not emit `camera_state_changed`: when the
failure *is* the camera going offline, the supervisor drives **two** inputs -- the camera-supervision
input (carrying `CameraState::Offline`, which emits `camera_state_changed`) **and** `Input::Fail {
detail }` (which emits `recorder_failed`) -- each event sourced from the input that actually carries its
data. A child-`error` failure with the camera still `Running` drives only `Input::Fail`, hence only
`recorder_failed` and no spurious `camera_state_changed`. The wire `recorder_failed` still carries the
live `session` (stamped by `apply` for display); the session-less-ness is purely about the *input* side.

### EventHub + the exactly-once invariant (`event_hub.rs`)

```rust
struct SeqEvent { seq: u64, event: Event }
struct EventConnection { snapshot: Snapshot, seq: u64, rx: broadcast::Receiver<SeqEvent> }

struct EventHub {
    inner: std::sync::Mutex<Inner>,        // Inner { world, seq } -- std Mutex: no .await held
    events_tx: broadcast::Sender<SeqEvent>,
    live_tx: watch::Sender<LiveStatus>,    // lean { phase: RecorderPhase, camera_state } for command_and_wait
}
```

`std::sync::Mutex` is correct: `broadcast::send` and `watch::send_if_modified` are synchronous,
no `.await` under the lock (precedent: `ts_duration.rs#DurationCache`). The `watch` carries a
**lean `LiveStatus { phase: RecorderPhase, camera_state: CameraState }`**, not `Snapshot`, so
per-second `uptime_s`/heartbeat/storage/temp ticks don't spuriously wake `command_and_wait` (only a
real phase or camera-state change does). It carries the full `RecorderPhase`, not a `recording: bool`:
now that `recording_starting` moves the phase to `Starting` before the encoder/file is confirmed, a
bool would conflate `Starting` with `Recording` and let `start_recording` return one phase too early.

**Lock discipline (the airtight part):** `drive()` holds `inner` while it *both* mutates `World`
*and* broadcasts each `SeqEvent`. `connect()` holds the *same* lock while it *both* `subscribe()`s
*and* reads `snapshot` + `seq` -- and that snapshot read is **pure in-memory** (the FSM projection;
`current_segment.dur_ms` is enriched later, in the handler, outside the lock), so the lock is never
held across filesystem work. A `broadcast::Receiver` receives only messages sent strictly after
its `subscribe()`. Therefore, for any event E and connecting client C:
- E `drive`d before C locks: E's mutation is in C's snapshot, and E was sent before C subscribed
  -> not redelivered. (folded in once)
- E `drive`d after C unlocks: E's send is after C's subscribe -> delivered; E's mutation is not in
  C's snapshot (read earlier under the lock) -> delivered once.
- No interleaving sends E between C's subscribe and snapshot read -- both are in C's single
  critical section. **Exactly-once, proven.** The impl must keep `subscribe()`+`snapshot()`+`seq`
  in one `lock()` scope in `connect()`, and the broadcast `send` in `drive()`'s `lock()` scope.

**Lag -> reconnect:** on `BroadcastStreamRecvError::Lagged(n)` the handler stream yields `None`,
terminating the SSE body; the client sees EOF, reconnects, re-snapshots. No mid-stream gap
recovery. `EVENT_CHANNEL_CAPACITY = 256` (a client must stall ~8 min at 2s heartbeat to lag).

### `GET /v1/events` handler (`events.rs`)

axum 0.8 `Sse` (no new deps -- confirmed `tokio` `sync`, `tokio-stream` `sync`/`BroadcastStream`,
and axum's `sse`/`json` are already present). `let conn = state.backend.connect();` captures the
snapshot **pure** under the hub lock; the handler then enriches `current_segment.dur_ms` from the
captured id **outside** the lock (the shared best-effort `spawn_blocking` + `DurationCache` step) ->
emit `Sse::default().id(conn.seq).json_data(Event::Snapshot(enriched))` first, then
`BroadcastStream::new(conn.rx)` mapping `SeqEvent { seq, event }` -> `Event::default().id(seq).json_data(event)`,
`Lagged -> None -> take_while` terminates. No `.event(...)` (the JSON `type` is the sole
discriminator). The two existing middleware layers (`host_allowlist`, `proto_headers`) wrap SSE
stream-safely -- `proto_headers` mutates only the response head and returns; the body streams
after. `x-dancam-proto`/`x-dancam-boot-id` still stamp the events response.

Heartbeat: a `spawn_heartbeat(hub, 2s)` task in `main.rs` (not `app()`, so in-process tests stay
timer-free and deterministic) drives `Input::Tick` -> broadcasts `Heartbeat{t_ms}`. A
`spawn_telemetry(hub, rec_dir, interval)` task likewise drives `Input::Telemetry`, which emits
`storage_changed` / `temp_changed` / `mem_changed` -- each only when its value changes. Because memory
jitters every sample, `mem_changed` fires on a **quantized** view (`available`/swap rounded to a coarse
granularity) so it does not spam a delta each tick; without it `mem` would freeze at the connect
snapshot while its Health-panel neighbors (storage, temp) keep ticking -- `HealthTelemetry.rows(for:)`
reads all three telemetry rows from one `World`, so a frozen `mem` is a visible regression from today's
1.5s-polled live memory.

### Backend trait delta + driving the FSM

```rust
trait Backend {
    fn preview_frames(&self) -> FrameStream;            // unchanged
    async fn start_recording(&self) -> Result<(), BackendError>;   // unchanged sig (bare ack)
    async fn stop_recording(&self) -> Result<(), BackendError>;    // unchanged sig (bare ack)
    fn snapshot(&self) -> Snapshot;                     // REPLACES fn status() -> Status
    fn connect(&self) -> EventConnection;               // NEW: atomic snapshot + subscribe
    fn unpullable_from(&self) -> Option<SegmentId>;     // NEW: clips exclusion floor = the recorder's unpullable_floor
}
```

`connect()` is one method (not snapshot + separate subscribe) -- the exactly-once proof depends
on it. **Start/stop stay bare `200` acks** (the event model deletes the recorder plan's
read-your-writes mutation bodies: the SSE stream + local optimistic overlay reconcile state in
order).

- **`MockBackend` drives the full path** (project rule: app swoops pass against the mock first):
  on start, the mock scans `rec_dir` for `start_segment = max_seq+1` (the filesystem read the pure
  FSM must not do) and drives `Input::StartCommand { start_segment }` through the hub (`apply` selects
  `session = prev+1` -- pure, no scan -- calls `RecorderState::start(session, start_segment)`, and
  emits `recording_starting` *synchronously*), then the writer task drives `recording_started` -> `segment_opened{start_segment}`
  -> on each roll `segment_closed{old}` + `clip_finalized(meta(old))` + `segment_opened{new}`; on stop,
  drive `Input::StopCommand` (emits `recording_stopping`) then finalize + `recording_stopped`. So iOS
  (commit 4) builds the full event taxonomy against the mock without hardware, and the synchronous
  command-phase events land on the stream the instant the POST is accepted (commit 2's integration test
  pins that ordering). Add `clips::clip_meta(rec_dir, seq)` (stat + etag, no `DurationCache` needed for
  mock text segments).
- **`CameraBackend`** holds an `Arc<EventHub>`; `supervise`/`parse_stderr` drive `apply()` through
  the hub instead of writing a `watch<Status>`. `command_and_wait` predicates directly on the lean
  `LiveStatus.phase`: `start_recording` awaits `phase == Recording`, `stop_recording` awaits
  `phase == Idle`, and `phase == Error` (alongside the existing `camera_state` Restarting/Offline
  check) resolves the wait as a command failure -- not the current `status.recording` bool, which
  `recording_starting` would flip true at `Starting`. The 3s `COMMAND_TIMEOUT` and the camera-offline
  guard are mechanically unchanged. `parse_stderr` maps the session-echoing *lifecycle* events to
  session/floor-guarded `RecorderEvent`s, but the session-less child `error` event to
  `Input::Fail { detail }` (not a `RecorderEvent`); the supervisor drives the *same* `Input::Fail` on
  child exit / spawn failure / the offline transition (the failure sources `supervise` already owns,
  now wired to the recorder as well as `camera_state` -- on the **offline** transition it drives
  `Input::Fail` *alongside* the existing camera-supervision input, so `recorder_failed` and
  `camera_state_changed` each come from the input that carries their data). On the child's
  `recording_stopped` the adapter (using its last-`segment_opened{id}` cursor for the open segment)
  builds `ClipMeta(last)` and drives the combined finalize-then-stop input (above); on each rollover's
  `segment_closed{old}` + `segment_opened{new}` it builds `ClipMeta(old)` and drives the combined
  `[clip_finalized(old), segment_opened(new)]` input -- so the floor advances atomically with the
  finalize and the real path emits `clip_finalized(old/last)` exactly as the mock does.

### `/v1/status`, clips exclusion, health re-point

- `events.rs#fn status`: takes the pure `state.backend.snapshot()` (FSM-owned, no I/O), enriches
  `current_segment.dur_ms` from the captured id via the same out-of-lock `spawn_blocking` +
  `DurationCache` step the `/v1/events` snapshot frame uses, then `Json(enriched)` -- same `Snapshot`
  type the stream emits. The old dir-scan to *find* the open segment is deleted (the id is FSM-owned);
  only the best-effort duration read on that one known path remains.
- `clips.rs`: `read_finished_clips` / `serve_clip` take an explicit exclusion floor
  `unpullable_from: Option<SegmentId>` (sourced from `Backend::unpullable_from()`, which returns the
  recorder's `unpullable_floor`) -- **not** the raw `current_segment`. `Some(f)` -> finished = files
  with `seq < f` (the open segment, and any transient newer file the watcher has not yet acknowledged,
  are excluded); `serve_clip` 404s any `id >= f`. `None` (clean Idle only) -> list **all**. The floor is
  `Some(start_segment)` from the moment `start` is accepted and advances to each `SegmentOpened{id}`, so
  during `Starting` / `Recording{None}` the *reserved* `start_segment` is the cutoff even though
  `current_segment` is still `None`. This closes the start-of-recording race a raw-`current_segment` rule
  leaves open: ffmpeg can create `seg_{start_segment}.ts` on disk *before* the ~250 ms watcher emits
  `segment_opened`, and a `None`-means-list-all rule would briefly list and serve that **partial open
  file** -- contradicting "never serves a partial open file." Pre-existing clips (all `< start_segment`)
  stay fully visible throughout `Starting`. **`Error` preserves the floor at the last-opened id, not
  `start_segment`:** after a roll (43 finalized then 44 open) a crash keeps the floor at 44, so the
  unclean partial 44 stays excluded while the already-finalized 43 stays listable and pullable --
  deriving the Error floor from `start_segment` (43) would wrongly hide the finalized 43. (A later
  `start` reserves a higher floor; the crash-truncated partial -- legitimate pre-crash footage under the
  crash-safe `.ts` design -- then lists normally.) `open_segment` as the live authority is deleted; the
  scan survives only for start-index allocation and finished enumeration.
- `health.rs`: `recording = snapshot.recorder.phase.is_active()`.

### Camera child protocol (commit 3 -- atomic both-sides; recorder plan Stage 3)

Neither half is green without the other (an old session-less child cannot drive the new parser),
so `camera.py` + the Rust `parse_stderr`/`command_and_wait`/start-command land in one commit.

- `camera.py`: `start_recording` drops `next_segment_index`, takes Rust-allocated
  `start_segment_index` (-> ffmpeg `-segment_start_number`) + `session_id`; emits
  `segment_opened`/`segment_closed` (+ session echo). Real driver runs a **session-scoped
  directory watcher** whose detection is a dependency-free pure helper
  `detect_segment_events(baseline, prev_max, names) -> [events]` (filters `seq < baseline`,
  emits closed{prev}+opened{new} on each new max) -- baseline floor guarantees a pre-existing
  file is never reported, unit-testable with no Picamera2. Fake driver emits events directly +
  `--fake-segment-secs` to exercise rollover. ffmpeg's `-f segment` pipeline (crash-safe path)
  is untouched -- the watcher reads the dir, it does not drive rollover (tradeoff: sub-second
  detection latency, far tighter and safer than today's global-max guess).
- Rust `camera/mod.rs`: `parse_stderr` maps the session-echoing *lifecycle* events into
  session/floor-guarded `RecorderEvent`s and the session-less `error` event into `Input::Fail { detail }`;
  the supervisor drives the same `Input::Fail` on child exit / spawn failure / offline (the offline
  transition also drives the camera-supervision input that emits `camera_state_changed`). On
  `recording_stopped` the adapter builds `ClipMeta(last)` (from its last-`segment_opened{id}` cursor)
  for the open segment and drives the combined `[clip_finalized(last), recording_stopped]` input (the
  watcher never closes the final segment); each rollover's `segment_closed{old}` + `segment_opened{new}`
  likewise drives a combined `[clip_finalized(old), segment_opened(new)]` input so the floor advances in
  the same `apply`. The
  backend scans `rec_dir` for `start_segment` (`max_seq+1`), drives `Input::StartCommand { start_segment }`,
  and sends `session_id`+`start_segment_index` to the child; `command_and_wait` uses phase-reached
  predicates. (During commit 2 the camera backend compiles against the new `Snapshot` via a
  **phase-only interim mapping** of the old session-less events so its integration tests stay green;
  commit 3 swaps in the full protocol.)

---

## iOS app (commit 4)

### Mirror types -- `DanCam/Networking/Events/CameraEvent.swift`

`CameraEvent` enum decoding the internally-tagged sum keyed on `type`, with an
`unknown(type: String)` sink for forward-compat (the `default:` arm of the *string* switch).
Reuse the existing leaf types (`CameraState`, `Storage`, `TempC`, `Mem`, `Clip`). `World` and
its nested `Recorder { phase, sessionId, currentSegment: { id, durMs? }?, detail? }` mirror the
`Snapshot`; **`World` replaces the old `StatusResponse`** (the flat `recording`/`currentSegmentId`/
`currentSegmentDurMs` fields are gone, replaced by the nested `recorder`). `JSONDecoder` uses
`.convertFromSnakeCase` (matching the existing status/clips decoders); the only explicit
`CodingKeys` is `CameraEvent`'s one-key `type`. The exhaustiveness guarantee lives on the
**fold switch** over `CameraEvent` (no `default`): adding a Swift *case* without handling it there is a
compile error. An *unmirrored* Rust wire variant does **not** trip that -- by the forward-compat design
it decodes to `.unknown(type:)` (the `default:` arm of the *string* discriminator) and folds to a
no-op, no compile error. What keeps an unmirrored variant from slipping by unnoticed is the
**golden-corpus decode test** (`assert none of contract/events/*.json decode to .unknown`): a new
fixture with no Swift case fails it, forcing the case to be added -- which then re-arms the fold-switch
exhaustiveness check. Wire-level coverage is the corpus test; compile-level exhaustiveness is the fold
switch -- two guards at two layers, not one compile-time guard over the wire.

### SSE client + parser -- `DanCam/Networking/Events/`

- `SSEEventParser` (pure value type, sibling of `MultipartMJPEGParser`): `mutating func append(_ Data) -> [Data]`,
  W3C `text/event-stream` framing (split on `\n`/`\r\n`/`\r`, accumulate `data:` lines, dispatch on
  blank line, ignore comments/`event:`/`id:`... or surface `id:` if we keep `seq`). Decodes nothing;
  unit-tested on bytes -> payloads (partial frames, comments, CRLF, multi-line data).
- `EventsClient` (closure-struct, sibling of `PreviewClient`): `connect: () -> AsyncThrowingStream<CameraEvent, Error>`
  over a pinned `NWByteStream`, mirroring `PreviewClient.produceFrames`: `HTTPRequestEncoder.get("v1/events", Accept: text/event-stream)`,
  **no `Connection: close`** (long-lived), validate `2xx` + `text/event-stream`, `HTTPBodyDecoder`
  (already handles unbounded `.chunked`/`.closeDelimited`) -> `SSEEventParser` -> JSON-decode ->
  `yield`. Add `events: EventsClient` and `heartbeatTimeout: @Sendable () async throws -> Void`
  (sibling of `statusFetchTimeout`) to `AppDependencies`.

### The fold + the `Link` state machine -- `DanCam/Features/Connection/Link.swift`

Replace the `ConnectionFeature.State` flag-cluster (`connectivity` enum + `consecutiveFailures: Int`
+ `lastStatus: StatusResponse?`) with one sum type unifying "connected" and "the data":

```swift
enum Link: Equatable { case connecting; case online(World); case offline(last: World?) }
```

The pure fold (the test keel, exhaustive switch, no `default`):

```swift
extension World {
    static func folding(_ world: World, _ event: CameraEvent) -> World  // mutates exactly one slice
}
```

`snapshot` -> `.online(world)` from any state; deltas while `.online` -> folded `.online`; deltas
while `.connecting`/`.offline` -> unchanged (a delta is meaningless without a base World).
`heartbeat`/`clip_finalized`/`unknown` -> World no-op (heartbeat re-arm is an effect, not a fold;
clips folds clip_finalized separately). `ConnectionCoordination` retargets `Connectivity` ->
`Link`, preserving the tested semantics: `presentation(for:)` over connecting/online/offline, and
`shouldResumeLiveWork` true only on the `offline -> online` recovery edge (not a fresh
`connecting -> online`).

### Live REC row from the recorder snapshot only (the bug fix's app half)

`HomeViewController#HomeRow.compose` becomes recorder-driven: **a live row exists iff
`world.recorder.currentSegment != nil`** -- the local `recordingState.showsLiveSegment` gate is
removed from the row path. `LiveSegment` keys its anchor reseed on `(sessionId, id)` so a new
session reseeds; live elapsed is a **local count-up** anchored at `segment_opened` (or snapshot),
seeded by `currentSegment.durMs` for a mid-segment join; authoritative finished duration arrives
via `clip_finalized`. The Record button / preview `recPill` keep a *local* optimistic derivation
(renamed e.g. `isRecordControlEngaged`) -- that is legitimately optimistic UI, distinct from the
authoritative row.

### Recording optimistic overlay + clips fold; deletions

- `RecordingFeature`: stays an enum; replace `statusObserved(recording:)` with
  `recorderPhaseObserved(RecorderPhase)` dispatched **only when `world.recorder.phase` actually changes**
  (not on every fold -- a no-op heartbeat fold leaves the phase untouched and must not fire it), and
  reconciled **asymmetrically** against the optimistic overlay, preserving today's
  `case .starting, .stopping: break` guard (`RecordingFeature.swift#reduce`, test
  `statusObservedIgnoredWhileStarting`): while optimistic `.starting`, accept only an authoritative
  `.recording`/`.error` (ignore a stale `.idle`); while `.stopping`, accept only `.idle`/`.error` (ignore
  `.recording`). So `recording_starting`/`recording_stopping` move even a *non-commanding* client's overlay
  to `.starting`/`.stopping`, and `recording_started`/`recording_stopped`/`recorder_failed` confirm or
  correct it (reconciling even if a local POST ack is lost), but a heartbeat folded between a Record tap
  and the authoritative `recording_starting` (world phase still `.idle`) can never bounce the button
  `.starting -> .idle -> .starting`. Projecting the full phase, not a bare `recording: bool`, is what keeps
  the brief command-phases visible everywhere. Start/stop POST acks stay the fast path.
- `ClipsFeature`: state holds a **persistent `[Clip]` across loads and folds** -- the current
  `idle|loading|loaded([Clip])|failed` enum (where `.loading` drops the list, leaving a fold nowhere to
  land) becomes `{ clips: [Clip], status: idle|loading|failed }`, an impossible-state removal in its own
  right. `.clipFinalized(Clip)` inserts + dedups by id (newest-first) **regardless of `status`**.
  `.load` is a one-shot (seed history on connect, paginate); on success it **merges** the response into
  the existing list (union by id, newest-first) **instead of replacing it**, so a clip already folded via
  `clip_finalized` survives a *stale* `clipsResponse` sampled before the event but delivered after it
  (the F2 race); `.load` failure keeps the existing clips and only sets `status = .failed`. (Forward-note:
  this union-by-id never *removes*, which is correct while clips are append-only; when storage-eviction
  lands, an authoritative `/v1/clips` that omits an evicted clip would be silently resurrected by a stale
  folded copy, so at that point narrow the merge to `response union folded-clips-newer-than-the-response-window`
  -- an authoritative omission must win. Zero impact today; no eviction exists.) Delete
  `pollID`/`pollInterval`/`schedulePoll` (the 10s loop).
- `AppFeature`: new `State { link, recording, clips, streamReconnectAttempt }` and `Action`
  (`.event(CameraEvent)`, `.streamStarted/Stopped`, `.streamFailed`, `.streamReconnect`,
  `.heartbeatTimedOut`, `.recording`, `.clips`, `.recordTapped`, `.manualRefresh`). The events
  stream is one `.run(id: streamID, cancelInFlight:)` effect (mirrors `PreviewFeature.connectEffect`);
  `armHeartbeat` is a `.run(id: heartbeatID, cancelInFlight:)` armed at **stream-start** (on
  `.streamStarted`) **and** re-armed on every event (the equality-gated `Store.send` runs the effect even
  when a heartbeat folds to a no-op World). Arming at stream-start -- not only on the first event -- is
  load-bearing: the first event *is* the snapshot, and `NWByteStream`'s `connectTimeout` disarms once the
  connection reaches `.ready` (TCP/TLS), with the post-`.ready` receive loop unbounded
  (`NWByteStream.swift#receive`; ADR 09's Consequences concede this gap for long-lived streams). So a
  connection that is *ready but silent* -- e.g. the snapshot frame stalled behind the handler's
  best-effort `dur_ms` `spawn_blocking` -- would otherwise sit in `.connecting` forever with no timer
  running (the SSE-era recurrence of `ConnectionFeatureTests#hungFetchFlipsToDisconnected`, whose
  whole-fetch `statusFetchTimeout` this plan deletes). The `heartbeatTimeout` is **3 missed 2s heartbeats
  (~6s)**, reconciling to ADR 02's "missed heartbeats (~3 x 2 s)"; `.heartbeatTimedOut`/`.streamFailed`
  -> `link.wentOffline()` + backoff reconnect. **Deleted:** the
  entire `ConnectionFeature.swift`, the `lastStatus`-diff coupling in `AppFeature.reduce`
  (recording bridge + segment-rollover -> clips-refresh), `pendingManualRefresh`, the
  three-strike debounce, and the recorder plan's `revision` guard (never built -- SSE ordering).
- `SceneDelegate`: `.connection(.start/.stop)` -> `.streamStarted/.streamStopped` on
  connect/foreground/background. View controllers: `\.connection.connectivity` -> `\.link`;
  `\.connection.lastStatus` -> `\.link` (derive `link.world`); `HealthTelemetry.rows(for:)` takes
  `World?`. Preview + Health stay standalone stores (unchanged seam; Health just reads `\.link`).

---

## Testing (maximally testable, both sides)

The two pure keels carry most of the weight; integration tests cover the wiring.

**Rust -- pure FSM (`recorder.rs`, `world.rs` `#[cfg(test)]`, no tokio):**
- Every recorder transition; **session guard drops a stale-session event**; **floor guard drops
  `SegmentOpened`/`SegmentClosed` with `id < start_segment`** (a seeded pre-existing id never
  becomes current); `current_segment` is `None` in `Starting`/`Recording{None}`, `Some` only after
  `SegmentOpened`; rollover advances it; stop clears it. **`fail(detail)` from an active phase -> `Error`
  with `current_segment` cleared but `unpullable_floor` *preserved*; `fail` when `Idle`/`Error` is a
  no-op; and `fail` is accepted irrespective of session** (it is control-driven and bypasses the session
  guard) -- the regression test that a camera death is never dropped by a session mismatch.
- **Out-of-order watcher race (carried from the superseded recorder plan):** a `SegmentOpened{id}`
  applied in `Starting` promotes to `Recording{current:Some(id)}`, **and a subsequent `RecordingStarted`
  in `Recording` is a no-op that preserves `current_segment`** (never resets it to `None`).
- **Command transitions emit:** an accepted `start` -- driven with a literal `Input::StartCommand {
  start_segment }`, so the FSM test needs no `rec_dir` (the structural proof the scan lives in the
  adapter) -- yields exactly `[recording_starting]` (phase `Starting`, `session = prev+1`, floor
  seeded from the passed `start_segment`); an accepted `stop` yields exactly `[recording_stopping]`
  (phase `Stopping`); an idempotent-no-op command yields `[]`.
- **`unpullable_from` projection:** `None` only at clean Idle; `Some(start_segment)` in
  `Starting`/`Recording{None}`; `Some(current)` once a segment is open; advances on each rollover;
  **after a roll-then-`fail` it stays at the last-opened id (44), never reverting to `start_segment`
  (43)** -- so an already-finalized earlier segment is never hidden by the Error floor.
- `apply`: camera-leaves-Running while an active recording phase -> the supervisor drives **two**
  session-less inputs -- the camera-supervision input (`CameraState::Offline`, emitting
  `camera_state_changed`) and `Input::Fail { detail }` -> `recorder.fail` on the live session
  (bypassing the session guard, emitting `recorder_failed`) -> `Error` phase, `current_segment` clears
  **but `unpullable_floor` is preserved** (the unclean partial stays excluded from clips); each event
  is attributed to the input that carries its data, and neither path emits `recording_stopped` -> Idle
  or `clip_finalized` (the interrupted segment is an unclean partial). **A child-`error` failure with
  the camera still `Running` drives only `Input::Fail` -> only `recorder_failed`, no
  `camera_state_changed`** -- the decomposition's payoff (a single Fail input emitting both would be
  un-implementable, since `Input::Fail` has no `CameraState` to put on the wire). A camera state change
  while idle emits only `camera_state_changed`; telemetry emits `storage_changed`/`temp_changed`/`mem_changed`
  only on change (mem on a quantized view, so per-sample jitter does not spam a delta); `Tick`
  always emits exactly one `Heartbeat`, never mutates.
- `Snapshot` projection: `recording`/`is_active` true in Recording **and** Stopping; uptime from boot.

**Rust -- golden corpus + serde (`events.rs`):** exhaustive-match test (`fn canonical(&Event) -> &str`,
no `_` arm -> a new variant fails to compile until it has a fixture) asserting serialize == fixture
(field-order-independent via `serde_json::Value`) and fixture deserializes back to the value.

**Rust -- `GET /v1/events` integration (`tests/events.rs`, in-process `tower::oneshot`, read the
streamed body incrementally):** snapshot-first; **an already-connected stream receives `recording_starting`
as the *first* frame after `POST /v1/recording/start` -- before the writer's `recording_started`/
`segment_opened` -- and `recording_stopping` as the first frame after `POST /v1/recording/stop`, before
`recording_stopped`** (pins that the HTTP command path drives the command `Input` through the hub
synchronously; a route relying only on the child writer would still emit the later confirmation events,
so asserting the *leading* command-phase frame is what catches the omission); a `heartbeat` after a
`MockBackend.tick()` (deterministic); `clip_finalized` + `segment_opened` on a mock rollover,
**and `serve_clip(old) -> 200` immediately after that rollover's `clip_finalized(old)` is observed on
the stream -- no intervening 404, pinning that the floor advances `old -> new` atomically with the
finalize (the rollover-instant pullability a two-input split would briefly break)**;
`x-dancam-proto`/`x-dancam-boot-id` on the response head.

**Rust -- exactly-once atomicity (`event_hub.rs`):** hammer `hub.drive(...)` from one task while the
main task repeatedly `connect()`s; assert `fold(snapshot + drained rx) == final World projection`
and no event id is both in-snapshot and redelivered. The `connect()` snapshot here is the **pure**
projection (`dur_ms` unset -- it is handler-enriched post-lock), so the proof is over in-memory state
only and duration I/O never participates. Plus a lag -> stream-terminates test.

**Rust -- the bug + the open-file race, structurally (`tests/status.rs`/`tests/clips.rs`, settable
`StubBackend`):** with `seg_00042.ts` on disk and `recorder = Starting{start_segment:43, current:None}`,
`/v1/status.recorder.current_segment` is `null` **and `/v1/clips` still lists 42**; **with `seg_00043.ts`
*also* already on disk (ffmpeg opened the file before the watcher acknowledged it) but `recorder` still
`Starting{start_segment:43, current:None}`, `/v1/clips` lists 42 and *excludes 43*, and `serve_clip(43)`
-> 404** -- the floor-based `unpullable_from` keeps the partial open file unservable even before
`segment_opened`; with `Recording{current:Some(43)}` + 42,43 present, status reports 43 (never 42), clips
lists 42 / excludes 43, `serve_clip(43)`->404, `serve_clip(42)`->200. **And the roll-then-crash
regression: with the recorder in `Error`, `current_segment = None`, `unpullable_from() = Some(44)` (44
was the last open segment; 43 was finalized before the crash), and `seg_00043.ts`+`seg_00044.ts` on disk,
`/v1/clips` lists 43 and *excludes 44*; `serve_clip(44)`->404, `serve_clip(43)`->200** -- the Error floor
sits at the last-opened 44, so the unclean partial is hidden while the already-finalized clip stays
pullable.

**Rust -- fake-camera lifecycle (`tests/camera_process.rs`, commit 3):** child honors a Rust-passed
`start_segment_index` (5 -> `seg_00005.ts`), emits `segment_opened`/`segment_closed`, rolls under
`--fake-segment-secs`; the supervisor's recorder snapshot tracks `current_segment` from the events.
**A clean `stop` finalizes the *last* open segment and it is immediately listed by `/v1/clips` and
pullable (`serve_clip` -> 200, not 404)** -- the real-path proof that `recording_stopped` drives
`clip_finalized(last)` (the watcher never closes the final segment, so mock-first coverage structurally
cannot catch a regression here). **And, reusing the existing `--fake-crash-after` flag, a crash
mid-recording drives the supervisor's `Input::Fail` so the recorder snapshot becomes `Error` with
`current_segment == None`** (alongside the `camera_state` Restarting/Offline that
`camera_process.rs#supervisor_marks_child_restarting_after_crash` already pins) -- the wiring proof the
pure `apply` test cannot give, since `apply` constructs the failure directly.

**Python -- watcher baseline floor (`camera.py --self-test`, no Picamera2):** `detect_segment_events`
with `seg_00042.ts` present and `baseline=43` emits `opened{43}` then `closed{43}+opened{44}` and
**never reports 42** -- a regression to global-max detection fails here.

**Swift -- pure fold + Link (`LinkTests.swift`, pure):** each event mutates the right World slice;
`snapshot` -> `.online`; delta while `.connecting`/`.offline` unchanged; `wentOffline` transitions;
`unknown` is a no-op. **Recorder ordering, mirroring the Rust FSM:** `recording_starting` -> phase
`.starting`; a `segment_opened` folded while `.starting` -> `.recording` + `currentSegment` set (the
out-of-order race), and a subsequent `recording_started` preserves `currentSegment`;
`recording_stopping` -> `.stopping`; `recording_stopped` -> `.idle` with `currentSegment` cleared.

**Swift -- live row (`HomeRowTests.swift`):** live row appears **iff `recorder.currentSegment != nil`**;
the **regression case** -- `recorder = idle/current:nil` (or a prior session) while local state would
be `.starting`/`.recording` -- yields **no live row** (compose cannot see local state); `(sessionId,id)`
change reseeds the anchor; same `(session,id)` carries forward / clamps monotonically.

**Swift -- AppFeature via `TestStore`:** snapshot seeds `.online` + recording projection + clips load;
`recording_started`/`recording_stopped` reconcile optimistic `.starting`/`.stopping`; **a heartbeat
folded while the overlay is optimistic `.starting` and `world.recorder.phase` is still `.idle` leaves the
overlay `.starting`** (phase-change-driven + asymmetric projection -- no `.starting -> .idle -> .starting`
bounce; the SSE-era replacement for `statusObservedIgnoredWhileStarting`); `clip_finalized`
prepends + dedups; **a `clip_finalized` arriving *before* a stale one-shot `clipsResponse` survives --
the later load merges (union by id, newest-first) instead of replacing, so the finalized clip is never
lost** (the F2 ordering regression); **`recording_starting`/`recording_stopping` drive
`world.recorder.phase` (and the recording overlay) to `.starting`/`.stopping` on a *non-commanding*
client -- no local Record tap -- proving the app folds every accepted transition**; `segment_opened`
updates the live segment without clips churn; **`mem_changed`/`storage_changed`/`temp_changed` each fold
their telemetry slice so the Health panel keeps ticking (no frozen `mem` row)**; `heartbeat` re-arms
liveness with no state change; **a stream that starts but delivers no snapshot within `heartbeatTimeout`
-> `link.wentOffline()` + reconnect** (the started-but-silent window -- the SSE-era replacement for
`hungFetchFlipsToDisconnected`, since `connectTimeout` only covers reaching `.ready`); `heartbeat`-gap
and `streamFailed` go offline + reconnect; `streamStopped` cancels both effects with no further actions. Plus `SSEEventParser`/`EventsClient`
tests (mirror `MultipartMJPEGParserTests`/`PreviewClientTests`, needs an `SSEWireBuilder`), and the
golden-corpus decode test (data-driven over `contract/events/*.json`, assert none decode to `unknown`,
plus per-variant value assertions and an explicit unknown-type-ignored test).

**Deleted tests:** `ConnectionFeatureTests` (consecutiveFailures walk, `hungFetchFlipsToDisconnected`)
and `RecordingFeatureTests#statusObservedIgnoredWhileStarting` -- their product-critical guarantees are
**re-expressed, not dropped**: the hung-handshake-> offline guarantee becomes the stream-start-armed
heartbeat-timeout test (a started-but-silent stream goes offline + reconnects), and the
optimistic-no-bounce guarantee becomes the phase-change-driven asymmetric overlay test (a heartbeat
folded while `.starting` does not knock the button to `.idle`); plus the stream-failed / stream-stopped
tests. Also deleted: the `AppFeatureTests` segment-rollover-diff and `pendingManualRefresh` tests.

Gates: `just raspi-test` + `just raspi-check` (fmt + clippy `-D warnings`), `just app-test`, `just adr-check`.

---

## Commit stack (short stack; ADRs in lockstep)

1. **`feat: /v1/events wire contract + golden corpus`** -- `contract/events/*.json` (the canonical
   variant fixtures, one per `Event` variant incl. `recording_starting`/`recording_stopping`/`mem_changed`)
   + a one-page contract spec. The language-neutral keel both sides assert against.
2. **`feat(raspi): recorder FSM + event hub + GET /v1/events (mock-driven)`** -- `recorder.rs`/`world.rs`/
   `event_hub.rs`/`events.rs`, delete `status.rs`, `Backend::snapshot`+`connect`, EventHub atomicity,
   SSE handler, `/v1/status` re-point, clips exclusion by the recorder floor (`unpullable_from`), `MockBackend` drives the
   full event taxonomy, FSM + corpus + SSE integration + atomicity tests. Camera backend on the
   phase-only interim mapping. **Lands raspi ADR 10 + the ADR 02 note.**
3. **`feat(raspi): camera child lifecycle protocol (session + segment events)`** -- atomic both-sides
   `camera.py` + `parse_stderr`/`command_and_wait`/start-command; `detect_segment_events` watcher;
   fake `--fake-segment-secs`; camera_process + self-test. Real rollover events now flow. **Lands the ADR 07 note.**
4. **`feat(app): fold events into state machines; recorder-driven live row; drop polls`** -- `CameraEvent`/
   `World`/`Link`, `EventsClient`/`SSEEventParser`, pure fold, recorder-driven row (bug fix),
   optimistic overlay, clips fold, delete `ConnectionFeature`/diff-coupling/`pendingManualRefresh`/
   3-strike, corpus decode + all rewrites. **Lands app ADR 10.**
5. **`docs: cross-cutting sweep`** -- root AGENTS.md cross-cutting principle update, roadmap codename +
   note, ADR 04/06/09 supersede/refine notes, `just adr-check`. (The new ADRs + ADR 02/07 notes already
   landed in lockstep above; this is only the cross-cutting docs that span all commits.)

Commits 3 and 4 are independent given mock-first (iOS needs only commit 2's mock event path), but the
3->4 order ships real hardware before the app depends on it.

## ADRs & docs

- **`raspi/docs/design/10-2026-06-29-recorder-fsm-and-events-sse.md` (new, Accepted)** -- the unified
  decision: the Pi-owned recorder state machine (phases + session + floor/session guards, no revision
  -- carry the full transition table from the superseded recorder plan into this ADR before deleting it),
  the **supervisor-driven session-less `fail`** path (child error / exit / spawn failure / offline ->
  `Input::Fail` -> `Error`, current cleared, floor preserved -- it bypasses the session guard because no
  failure source carries a session), Rust-owned id/session allocation (the adapter scans `rec_dir` for the
  start index and passes it into the pure FSM via `StartCommand`; the FSM owns the monotonic session
  counter), the child lifecycle protocol + session-scoped-watcher fallback (ffmpeg-owns-rollover tradeoff),
  the **atomic-finalize rule** at both rollover and stop (the adapter drives one combined input --
  `[clip_finalized(old), segment_opened(new)]` at rollover, `[clip_finalized(last), recording_stopped]`
  at stop -- so the clips floor advances in the *same* `apply` that finalizes, closing the transient
  `serve_clip(old)` 404 window; the closing id is the adapter's last-`segment_opened` cursor, since the
  watcher never closes the final segment), the `Event` sum type,
  snapshot-first + delta + heartbeat semantics, seq-as-SSE-id with **`at_ms`/`t_ms` monotonic-since-boot**
  (display/ordering only, never evidence-grade -- the Pi has no RTC, `moss` owns wall-clock), the
  snapshot/subscribe exactly-once invariant (the under-lock snapshot is pure in-memory;
  `current_segment.dur_ms` is enriched post-lock in the handlers, kept out of the proof), lag->reconnect,
  and clips exclusion by the recorder floor (`unpullable_from` = the FSM's `unpullable_floor`, which covers
  the start-of-recording open-file race and is preserved across `Error` so a post-rollover crash never
  hides an already-finalized clip -- not just the steady-state current segment). Relates to ADR 02/03/07.
  Realizes/refines ADR 02's Events plane.
- **`app/docs/design/10-2026-06-29-event-folded-state-machines.md` (new, Accepted)** -- the app-side
  companion (mirrors ADR 02's raspi-canonical + app-companion split): the `CameraEvent` mirror, the
  pure fold, the `Link` enum, recorder-driven live row, heartbeat-gap liveness (~6s = 3 missed 2s beats,
  armed at stream-start so a ready-but-silent stream still goes offline), the phase-change-driven
  asymmetric recording overlay (no optimistic bounce), retiring the polls + three-strike debounce +
  diff-coupling, unknown-event tolerance.
- **ADR 02 note (append, dated):** `/v1/events` realized as snapshot-first + deltas + heartbeat;
  `/v1/status` is now a one-shot of the `Snapshot` type; `/v1/clips` live-head freshness moves to
  `clip_finalized`; `Status` replaced by the nested `recorder` shape (supersedes the prior 2026-06-29
  flat-fields note); start/stop stay bare acks (no read-your-writes). **Reconcile the event taxonomy
  shift:** the realized v1 event set is recording-lifecycle (`recording_starting`/`recording_started`,
  `segment_opened`, `clip_finalized`, `recording_stopping`/`recording_stopped`, `recorder_failed`) + raw
  telemetry **deltas** (`storage_changed`/`temp_changed`/`mem_changed`) + `camera_state_changed` +
  `heartbeat` -- this **replaces** ADR 02's original *threshold-alert* events `storage_full`/`temp_warning`
  with raw-state deltas, keeps `recording_stopped`, and **defers** `incident_saved`/`incident_resolved`/
  `time_synced` (additive later under "clients ignore unknown event types"). Client-side alerting
  (storage-full, temp-warning) now derives from the raw deltas, or is deferred with the incident/time
  layers (and the CarPlay-ADR / offline-alerting language that referenced the alert form reads against the
  deltas accordingly). Also: event `at_ms`/`t_ms` are **monotonic-since-boot** (display/ordering only,
  never evidence-grade) since the Pi has no RTC and `moss` still owns wall-clock provenance; `seq` (the SSE
  `id:`) is the authoritative ordering. Append-only.
- **ADR 07 note (append, dated):** the stdio contract gains `session_id` + `start_segment_index` and
  `segment_opened`/`segment_closed` (session echo); rollover synthesized by a session-scoped watcher. The
  `error` event stays **session-less** (a failure signal mapped Rust-side to the control `fail`, not a
  session-scoped lifecycle event); the **last** segment gets no `segment_closed` -- `recording_stopped` is
  its finalize signal, with `ClipMeta(last)` built Rust-side. (Test scaffolding: the fake driver adds
  `--fake-segment-secs`; the existing `--fake-crash-after` flag is reused, not added.)
- **ADR 04 / 06 / 09 (refine/supersede notes):** connection truth moves from ADR 04's three-strike
  debounce over the 1.5s `/v1/status` poll (interval owned by ADR 06, restated in 09) to
  **heartbeat-presence**; the new off-network detection latency is **~6s (3 missed 2s heartbeats)**, a
  deliberate, recorded number that replaces ADR 09's `3 x (connectTimeout + pollInterval)` "roughly 10
  seconds" and reconciles to ADR 02's "missed heartbeats (~3 x 2 s)". The `AppFeature` diff-coupling is
  replaced by the fold.
- **root `AGENTS.md`:** update the app<->Pi cross-cutting principle -- the events plane is realized as
  snapshot+delta+heartbeat (single source of truth); liveness = heartbeat.
- **`docs/roadmap.md`:** add a swoop entry for this migration (suggested codename **`pulse`** -- the
  heartbeat/liveness motif; rename at will) and update the `fern` "live recording row" deepening note to
  point at the recorder state machine as the source of truth.

## Verification (end to end, no hardware)

1. `just raspi-test` + `just raspi-check` -- FSM, status, clips, events-SSE, atomicity, and (commit 3)
   fake-camera lifecycle suites green.
2. `just raspi-mock` on `127.0.0.1:8080` (writable `DANCAM_REC_DIR`, short `DANCAM_MOCK_SEGMENT_SECS`),
   seeded with a couple of `seg_*.ts`. Run the app in the simulator against it
   (`DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080`), and confirm:
   - the connection strip rides on heartbeats (kill the mock -> strip flips offline after the heartbeat
     gap; restart -> reconnects and re-snapshots);
   - tap Record: the previous last clip **stays** in Recent clips during the start window (no vanish, no
     `REC` masquerade); the live row appears only when the new segment is genuinely open, showing the
     **new** id from `00:00`;
   - at rollover the finished segment settles into the list (via `clip_finalized`) and a fresh live row
     starts; Stop removes the live row and the final segment appears.
3. `curl -N http://127.0.0.1:8080/v1/events` shows `id:`/`data:` frames: snapshot first, then deltas,
   then 2s heartbeats. `curl http://127.0.0.1:8080/v1/status` returns the same `Snapshot` JSON.
4. `just app-test` -- fold, Link, live-row, parser, corpus-decode suites green. `just adr-check` -- ADR 10
   (both sides) + appended notes validate.

## Risks / open points

- **Contract shape is the long pole.** Internal-vs-adjacent tagging and the JSON-`type`-vs-SSE-`event:`
  discriminator change both decoders. (The `seq`-in-`id:`-vs-`Frame`-envelope question is **settled** --
  bare-`Event` body + `id:` line, since the hand-rolled `SSEEventParser` reads `id:` directly, no
  envelope.) Commit 1 locks the corpus; the decode tests on both sides are the guard. Resolve before
  commit 2/4 type bodies.
- **Real-camera rollover detection latency** is bounded by the watcher poll (~250 ms); a just-closed
  segment is briefly excluded from `/v1/clips` and reappears within a poll -- tighter and safer than
  today's stale-row window. The same poll gap exists at the *start* of recording (ffmpeg can create
  `seg_{start_segment}.ts` before the watcher emits `segment_opened`), but `unpullable_floor` sits at the
  reserved `start_segment` from the instant `start` is accepted, so a partial open file is **never**
  listed or served in that pre-`segment_opened` window; as segments roll the floor advances with them,
  and on `Error` it stays at the last-opened id so the unclean partial stays excluded while the
  already-finalized clips remain visible. inotify is a later optimization.
- **`current_segment.dur_ms` in the snapshot** is best-effort read-time I/O for the mid-join offset,
  done in the async `/v1/events` + `/v1/status` handlers **outside the hub lock** (from the
  FSM-captured segment id) -- never in the pure `World::snapshot` and never under the
  `std::sync::Mutex`, so duration I/O can neither block the hub nor enter the exactly-once proof. Live
  ticking is a local count-up; authoritative finished duration is `clip_finalized`. No periodic dur
  streaming (Pi has no RTC; `moss` still owns time provenance).
- **Heartbeat through the World lock** gives one strictly-monotonic `seq` across deltas + heartbeats at
  one lock/2s -- negligible; the cheaper retreat (separate atomic heartbeat seq) is noted but not chosen.
- **`std::sync::Mutex` poisoning** propagates as `.expect("... poisoned")` (matches `DurationCache`); a
  panic in the total, pure `apply` would poison the hub -- acceptable given the FSM unit tests + clippy.

## Commit progress

- [x] 1. /v1/events wire contract + golden corpus
- [ ] 2. recorder FSM + event hub + GET /v1/events (mock-driven)
- [ ] 3. camera child lifecycle protocol (session + segment events)
- [ ] 4. fold events into state machines; recorder-driven live row; drop polls
- [ ] 5. cross-cutting sweep
