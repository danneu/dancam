# Plan: switch preview frame fan-out from broadcast(8) to watch (latest-frame-wins)

## Context

The live MJPEG preview (`GET /v1/preview/live.mjpeg`) fans frames out from the
camera child process to HTTP clients through a `tokio::sync::broadcast` channel of
capacity 8. A consumer that falls behind (slow 2.4 GHz Wi-Fi, descheduled task)
keeps up to 8 retained frames; when it resumes, it drains that backlog in a burst
*before* reaching the live edge -- "catch-up."

For a live preview this backlog is the wrong behavior. Every buffered frame is
stale by the time it's delivered, and because the wire format is
`multipart/x-mixed-replace` each one is instantly overwritten on screen by the
next. So catch-up spends scarce Wi-Fi bandwidth replaying frames that exist only to
be replaced, and it *adds* latency right after a hiccup. What we want is the
opposite: after any stall, jump straight to the newest frame and forget the gap.

`tokio::sync::watch` is the honest primitive for this -- a single conflating
"latest value" slot. Switching to it makes a lagging client always resume on the
freshest frame (no backlog, no burst), lowers time-to-first-frame for a new viewer
(`watch` hands a new subscriber the current frame immediately; `broadcast::subscribe`
only delivers frames sent *after* subscribe), and removes the `Lagged` error path
and the capacity constant. Producer isolation is preserved by *how* we consume, not
by a blanket claim: a `watch` write (`send_replace`) takes a brief write lock that
contends only with an outstanding read borrow, and our `WatchStream` consumer clones
the frame and drops the borrow within a single `poll` -- it never holds a borrow
across the socket-write await. So a slow HTTP client can't stall `send_replace` or
other viewers, and the camera producer stays unaffected by consumer speed.

Decision rationale and the trade-off (a healthy client can theoretically skip a
single frame under scheduler load -- unobservable at the 10 fps preview default,
and the condition to revisit is higher preview fps on the contended Pi Zero 2 W)
were settled in discussion; this plan implements that decision.

## Scope

Localized to the preview frame channel in the Rust service. The `Backend` trait,
the `FrameStream` type alias, and the `preview::live_mjpeg` handler are all
unchanged -- the swap lives entirely inside the two backend implementations.

## Changes

### 1. `raspi/service/src/camera/mod.rs` (real `CameraBackend`)

- **Imports:** drop `broadcast` from `use tokio::sync::{...}` (keep `mpsc`,
  `oneshot`, `watch` -- `watch` is already imported for status). Change
  `use tokio_stream::{wrappers::BroadcastStream, StreamExt}` to use `WatchStream`.
- **Remove** the `FRAME_CAPACITY` const (only the frame channel used it;
  `COMMAND_CAPACITY` stays).
- **Field type:** `CameraBackend.frames_tx: broadcast::Sender<Bytes>` ->
  `watch::Sender<Option<Bytes>>`.
- **Channel creation** in `CameraProcess::spawn`:
  `let (frames_tx, _) = broadcast::channel(FRAME_CAPACITY);` ->
  `let (frames_tx, _) = watch::channel::<Option<Bytes>>(None);`
  (annotate the type; `None` alone is ambiguous). The discarded receiver is fine --
  `send_replace` below stores regardless of receivers.
- **Thread the new type** through the function signatures that carry the sender:
  `supervise`, `run_child`, and `drain_stdout` -- each `frames_tx: broadcast::Sender<Bytes>`
  becomes `watch::Sender<Option<Bytes>>`.
- **Producer** in `drain_stdout`:
  `let _ = frames_tx.send(Bytes::from(frame));` ->
  `frames_tx.send_replace(Some(Bytes::from(frame)));`
  Use `send_replace` (not `send`): `send` returns `Err` and **does not store** when
  there are no receivers, so the slot would go stale whenever no preview client is
  connected. `send_replace` always stores the latest, keeping a reconnecting client's
  first frame fresh (the camera emits the lores preview continuously regardless of
  clients). The returned previous value is ignored.
- **Clear the slot on child downtime (lifecycle):** in `supervise`, pair a
  `frames_tx.send_replace(None)` with each transition to the non-running state -- the
  `ChildOutcome::Exited` and `ChildOutcome::Shutdown` arms after `run_child` returns,
  and the `spawn_child` error arm (alongside the existing `Status::restarting()` /
  `Status::offline()` sends). `watch` retains its last value indefinitely, so without
  this the slot keeps a dead child's final frame across the backoff/restart window and
  would serve it to a client that connects mid-restart *as if it were live*. `None` is
  the explicit "no live frame" state: a client connecting during downtime gets `None`
  (filtered out -> waits) until the new child produces a frame, instead of a frozen
  stale one. This must live in `supervise`, **not** at the tail of `drain_stdout`:
  `run_child` calls `stdout_task.abort()` on child exit, so code after the read loop in
  `drain_stdout` is not guaranteed to run, whereas `supervise` sequences the lifecycle
  deterministically and clears *before* the backoff sleep (closing the
  serve-stale-during-restart window). Bonus: a future `/v1/preview/snapshot` then
  naturally reports "no frame available" during downtime rather than a stale frame.
- **Consumer** in `CameraBackend::preview_frames`:
  `Box::pin(BroadcastStream::new(self.frames_tx.subscribe()).filter_map(|result| result.ok()))`
  -> `Box::pin(WatchStream::new(self.frames_tx.subscribe()).filter_map(|frame| frame))`.
  `WatchStream::new` yields the current value on first poll (instant first frame, or
  `None` at boot before any frame), then on each change; `filter_map(|frame| frame)`
  unwraps `Option<Bytes>` -> `Bytes`, dropping the pre-first-frame `None`.

### 2. `raspi/service/src/backend.rs` (`MockBackend`)

Mirror the same edits:
- **Imports:** drop `broadcast` from `use tokio::sync::{broadcast, watch}` ->
  `use tokio::sync::watch`. Change `wrappers::BroadcastStream` -> `wrappers::WatchStream`
  (keep `Stream`, `StreamExt`).
- **Field type:** `MockBackend.frames_tx: broadcast::Sender<Bytes>` ->
  `watch::Sender<Option<Bytes>>`.
- **Channel creation** in `MockBackend::new`: `broadcast::channel(8)` ->
  `watch::channel::<Option<Bytes>>(None)`.
- **Producer** in `spawn_mock_frames`:
  `let _ = frames_tx.send(Bytes::from_static(frame));` ->
  `frames_tx.send_replace(Some(Bytes::from_static(frame)));`
- **Consumer** in `MockBackend::preview_frames`: same `WatchStream` form as above.

### 3. `raspi/service/tests/camera_process.rs` (test rename + cached-frame regression test)

- Rename `supervisor_confirms_start_stop_and_records_with_stalled_subscriber` (and
  its `_stalled_subscriber` local) to drop "stalled" -- e.g.
  `..._with_idle_preview_subscriber` / `_preview_subscriber`. "Stalled" (lagging past
  the buffer) is a broadcast concept that no longer exists; the test's real purpose
  -- a live preview subscriber that isn't being consumed must not disrupt recording --
  still holds and the body is otherwise unchanged. Cosmetic but keeps the name honest.
- No other test changes. `spawn_stdout_drain` uses its own local `mpsc` channel +
  `TestJpegSplitter` (it never touches the production channel), and the
  `tests/preview.rs` `StubBackend` provides `preview_frames` via `tokio_stream::iter`
  at the trait level -- both are independent of the channel impl.
- **New regression test -- cached latest frame on connect (guards the `watch` +
  `send_replace` contract).** The existing tests would pass on either `broadcast` or
  `watch`; none pin the new behavior. Make it a *controlled* discriminator, not a lucky
  one, by exploiting two facts about the fake camera (`raspi/camera/camera.py#_preview_loop`):
  it emits its **first** preview frame at `frame_count == 0` (~coincident with
  `Running`), and the next only one full interval later; and every fake frame is the
  same `FAKE_JPEG` bytes, so the discriminator must be timing, not content. Spawn
  `CameraProcess` with `--fake --preview-fps 0.2` (frames ~5 s apart), await
  `wait_for_camera_state(&backend, CameraState::Running)`, sleep ~1 s **with no preview
  subscriber** (long enough that the immediate first frame has been produced and stored,
  far short of the ~5 s gap to the next tick), then call `backend.preview_frames()` and
  assert `tokio::time::timeout(Duration::from_millis(400), frames.next()).await`
  resolves to `Some(bytes)` with `bytes.starts_with(&[0xff, 0xd8])`. The probe attaches
  ~1 s in, ~4 s before the next live tick: a `broadcast` impl never replays
  pre-subscribe frames, so it would deliver nothing for ~4 s and blow the 400 ms
  deadline, while `watch` + `send_replace` returns the cached frame at once. Passing
  therefore proves both (a) no-subscriber production is retained (`send_replace`, not
  `send`) and (b) a new subscriber gets the cached latest immediately (`WatchStream::new`).
  The ~4 s dead-zone margin dwarfs scheduler jitter, so it isn't load-flaky. Needs
  `use tokio_stream::StreamExt` for `.next()`; gate on `python3_available()` and clean
  up the rec dir like the sibling tests.
- **New regression test -- slot cleared on child downtime (guards the clear-on-restart
  lifecycle).** Without this, an impl could drop the `ChildOutcome::Exited`
  `send_replace(None)` and still pass everything above, silently reintroducing the
  stale-frame-during-restart bug. Model it on
  `supervisor_marks_child_restarting_after_crash`: spawn with `--fake --fake-crash-after 4`
  (`--fake-crash-after` counts sensor ticks; the child emits its tick-0 preview frame --
  so the slot is `Some` -- then crashes, exiting non-zero -> `ChildOutcome::Exited`),
  await `wait_for_camera_state(Running)`, read one frame to confirm the slot was
  populated, then `wait_for_camera_state(Restarting)` (the `Exited` arm has now run and
  cleared the slot to `None`). During the backoff window attach a **fresh** subscriber
  -- `let mut probe = backend.preview_frames();` -- and assert
  `tokio::time::timeout(Duration::from_millis(150), probe.next()).await.is_err()`. With
  the clear, the slot is `None`, so the probe pends until the next child produces a
  frame (>= the 250 ms backoff + Python startup + ready + first frame, ~1 s+ away),
  well past the 150 ms deadline; without the clear, `WatchStream::new` hands the probe
  the stale pre-crash frame at ~0 ms and `is_err()` fails. The 150 ms window sits
  comfortably inside the post-`Restarting` dead zone, so it isn't racy. Shut down via
  `control.shutdown().await` and clean up the rec dir.

### 4. `raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md` (record the decision)

The preview fan-out mechanics aren't currently documented (the ADR only notes that
live preview is "fanned out from the child process"). Append a short **dated note**
to the preview section -- matching the ADR's existing `Note (date):` style (e.g. the
`fox`-swoop validation note) -- rather than a new ADR. This decision only makes sense
in the context of the MJPEG-over-2.4-GHz choice ADR 02 already owns, so it belongs
here, not in a satellite file. Capture three things (the what alone invites a future
reader to "fix" the deliberate frame-dropping):

- **What:** preview fan-out is latest-frame-wins (conflating), not buffered -- a
  consumer that falls behind the live edge resumes on the newest frame; intermediate
  frames are dropped, never replayed. Implemented with a `tokio` `watch` slot, not a
  `broadcast` ring.
- **Why:** over the congested 2.4 GHz link a replayed backlog is pure waste -- under
  `multipart/x-mixed-replace` each stale frame is immediately overwritten by the next,
  costing bandwidth and adding latency after a stall.
- **Flip condition:** revisit if preview fps rises materially above the ~10 fps
  default -- on the contended Pi Zero 2 W a higher rate could make even a healthy
  consumer skip frames, at which point a small bounded buffer may be worth
  reintroducing.

## Reuse / existing facts

- `JpegSplitter::push(&mut self, &[u8]) -> Vec<Vec<u8>>` (`raspi/service/src/jpeg.rs#push`);
  each frame is a `Vec<u8>` wrapped via `Bytes::from(frame)` today -- unchanged.
- `tokio_stream::wrappers::WatchStream` is already available: `Cargo.toml` enables
  `tokio-stream`'s `sync` feature (gates both `BroadcastStream` and `WatchStream`),
  and `tokio`'s `sync` feature is on. **No dependency changes.**
- `watch::Sender::subscribe()` and `send_replace` are both in the pinned `tokio = "1"`.
- `FrameStream = Pin<Box<dyn Stream<Item = Bytes> + Send>>` and the `Backend::preview_frames`
  signature (`raspi/service/src/backend.rs`) are unchanged -- the swap is internal to
  each backend.

## Testing / verification

- `just raspi-build` -- compiles clean (catches the threaded signature/type changes).
- `just raspi-test` (`cargo test --manifest-path raspi/service/Cargo.toml`) -- the
  preview multipart/ordering tests, the renamed idle-subscriber recording test, the two
  new tests (cached-latest-frame on connect, slot-cleared-on-downtime), and the
  camera-process/restart tests all pass. The camera-child tests self-skip when `python3`
  is unavailable; run where `python3` exists to exercise them (both new tests require
  `python3`).
- Optional clippy pass on the crate to confirm the dropped imports / removed const
  leave no warnings.
- Manual smoke (mock backend, no hardware): `just raspi-mock`, then
  `curl -N http://127.0.0.1:8080/v1/preview/live.mjpeg` -- confirm multipart headers
  and a steady stream of JPEG parts (the mock pushes a frame every 100 ms). Open a
  second concurrent `curl -N` and confirm both receive frames independently.

### Tests intentionally not added

Beyond the two regression tests above, no separate "slow consumer skips
intermediate frames" conflation test. A faithful one is timing- and
scheduler-dependent (force a consumer to fall behind, then assert specific frames were
dropped), which would be flaky, and a deterministic version would mostly be testing
`tokio`'s `watch` rather than our code. The conflation contract is adequately anchored
by the cached-frame test plus the trait-level multipart + ordering tests and the
idle-subscriber recording smoke test. This matches the "behavioral,
structure-insensitive" test bar.

## Risk / rollback

Low. The change is isolated to the two backend implementations (the `supervise`
lifecycle clear lives within `camera/mod.rs`), plus a test rename, two new regression
tests, and a dated ADR note; the public trait and HTTP handler are untouched, so the
blast radius is the preview/camera path only. The broadcast version was validated on
real hardware in the `fox` swoop; if any real-hardware re-validation of preview
smoothness
is wanted before relying on this, run the manual smoke against a deployed
`DANCAM_BACKEND=camera` service. Rollback is a straight revert of the source edits.

## Implementation notes

- In `camera/mod.rs#supervise`, the `send_replace(None)` is placed *before* the
  paired `status_tx.send(...)` in the `Exited` and error arms, so the slot is already
  `None` the instant `Restarting` becomes observable. The `slot-cleared-on-downtime`
  test relies on this ordering: it observes `Restarting`, then asserts a fresh
  subscriber gets nothing.
- The `slot-cleared-on-downtime` test's confirmation read uses a generous
  `Duration::from_secs(2)` timeout (the plan left it unspecified). The fake child
  crashes ~0.1 s after `ready`, so a tight deadline could race the crash+clear; a
  generous one lands on either the first child's cached frame or the next child's
  frame -- both prove the producer ran. The discriminating assertion stays the 150 ms
  empty-probe during the restart window.
- Both new tests pass `--rec-dir <temp>` (beyond the plan's illustrative flag list),
  matching the sibling tests: the fake driver's `start()` calls `ensure_rec_dir`, which
  would fail on the default `/home/<user>/rec` on the dev Mac and keep the child from
  reaching `ready`.
