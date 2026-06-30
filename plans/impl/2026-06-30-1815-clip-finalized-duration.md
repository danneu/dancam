# Fix: recorded clip shows size but no duration after stop

## Context

On the app home screen, immediately after you record and stop, the just-finished
clip row renders only `seg_00001.ts <size>` -- the `MM:SS` duration is missing. It
only appears later, after a reconnect/snapshot or pull-to-refresh.

Root cause is entirely **Pi-side**, in the event stream:

- The app is correct end to end. `Clip.durMs` is decoded (`.convertFromSnakeCase`
  maps `dur_ms`), folded by `ClipsFeature`, and rendered by
  `Formatters.clipMetadata` (`app/.../Support/Formatters.swift#clipMetadata`), which
  drops the duration segment only when `durMs == nil`. **No app changes are needed.**
- When recording stops (or a segment rolls), the home row is fed by the
  `clip_finalized` SSE event the app folds into state
  (`app/.../Features/Clips/ClipsFeature.swift#reduce`, `.clipFinalized`). That event
  arrives with `dur_ms: null`.
- The Pi builds that event via `clip_meta(rec_dir, seq, None)` -- it passes `None`
  for the TS-duration cache, so `dur_ms` is never computed
  (`raspi/service/src/clips.rs#clip_meta`).
- `GET /v1/clips` *does* compute `dur_ms` (it passes the real cache in
  `raspi/service/src/clips.rs#read_finished_clips`), which is why duration reappears
  only after a later list reload. ADR 10 already intends the finalize event to be the
  live source of finished-clip state; the runtime just isn't honoring it for `dur_ms`.

A hard consistency constraint falls out: the `clip_finalized` event's `dur_ms` must
equal `/v1/clips`'s `dur_ms` for the same segment, or the value would flicker on
refresh. Consistency comes from both paths deriving `dur_ms` from the **same segment
file** (its PTS span), read after the final flush -- so they agree by construction even
though they compute at different times. Sharing one cache instance (Part 1) is *not* what
makes them agree; two separate file-backed caches would yield the identical value. We
share it only so `/v1/clips` reuses the value the finalize path already computed instead
of re-scanning the file. The failure mode this rules out is a *fabricated* event duration
(e.g. a wall-clock value on the event while `/v1/clips` reads the file) -- which is
exactly why Part 2 makes the mock emit real TS rather than synthesizing a number.

Scope (confirmed with Dan): fix the root cause **and** make the dev mock observable.
The default mock (`just raspi-mock`) writes fake non-TS bytes, so its segments have no
parseable duration; the core fix alone would leave the simulator duration-less. So we
also make the mock emit valid TS so a record->stop in the simulator shows a realistic
duration (e.g. `00:04`) with no hardware.

The same core fix also flips the **real** camera finalize path
(`raspi/service/src/camera/mod.rs#parse_stderr`). To keep that path honest under test --
and because the Python camera fake (`camera.py --fake`) likewise writes non-TS bytes --
the fake is made duration-bearing as well and the existing camera integration test is
extended to witness it (Part 3 + Tests).

## Part 1 -- Core fix: share one `DurationCache` so `clip_finalized` carries `dur_ms`

Today `AppState` creates its own cache (`raspi/service/src/lib.rs#AppState`,
`clip_durations`) and only the HTTP `/v1/clips` handler uses it. Invert ownership so
the **backend owns the cache** and the finalize path and `/v1/clips` share one
instance. This keeps `AppState::new`'s signature unchanged (so the ~10 test call sites
don't churn) and respects ADR 10's rule that the hub lock is never held across
filesystem duration work -- both finalize sites already call `clip_meta(...)` *before*
`hub.drive_now(...)`.

- **`raspi/service/src/ts_duration.rs`**: make `DurationCache` `pub` (inherent methods
  can stay `pub(crate)` -- the public `Default` impl is the external constructor the
  integration-test stubs use, so no inherent method needs to go `pub`; see Tests). It is
  already interior-mutable (`Mutex<HashMap>`, `duration_ms(&self, ..)`), so it shares
  cleanly behind `Arc` with no `&mut`.
- **`raspi/service/src/lib.rs`**: `pub use ts_duration::DurationCache;` (re-export so
  the public `Backend` trait can name it). In `AppState::new`, replace
  `clip_durations: Arc::new(DurationCache::new())` with
  `let clip_durations = backend.clip_durations();` (read it from the backend, before
  `backend` is moved into `Arc::new(backend)`).
- **`raspi/service/src/backend.rs#Backend`**: add `fn clip_durations(&self) ->
  Arc<DurationCache>;` (required, no default -- a default would hand back a fresh
  instance, silently splitting the finalize path and `/v1/clips` onto separate caches that
  each re-scan the file; the values would still agree, but it reintroduces the redundant
  list-time recompute Part 1 exists to remove). **Five** types implement `Backend`: the two real
  impls below, plus three integration-test `StubBackend`s in
  `tests/{clips,status,preview}.rs` -- all five must gain the method, or `just raspi-test`
  fails to compile (see Tests for the stub impls).
  - `MockBackend`: store an `Arc<DurationCache>` (created in `with_recorder`), return
    it from `clip_durations()`, and thread it through `MockRecorder::new` into
    `run_mock_recording_writer`. Change both `clip_meta(rec_dir.as_ref(), seq, None)`
    (roll + stop) to `Some(cache.as_ref())`.
- **`raspi/service/src/camera/mod.rs#CameraBackend`**: store an `Arc<DurationCache>`
  created in `CameraProcess::spawn`; return it from `clip_durations()`; thread it
  `supervise(...)` -> `run_child(...)` -> `parse_stderr(...)`. Change both
  `clip_meta(rec_dir.as_ref(), id, None)` (rollover + recording-stopped) to
  `Some(clip_durations.as_ref())`.

`clip_meta` already takes `Option<&DurationCache>`
(`raspi/service/src/clips.rs#clip_meta`) -- the only change at the call sites is
passing `Some(..)` instead of `None`. Result: for real TS segments, the
`clip_finalized` event and `/v1/clips` report the same PTS-derived `dur_ms`.

## Part 2 -- Mock fidelity: emit valid TS so mock durations are real and consistent

Mock segments are fabricated bytes (`MOCK_RECORDING_CHUNK = b"dancam mock segment
bytes\n"`), which `segment_duration_ms` can't parse -> `None`. Fabricating a
wall-clock `dur_ms` only on the event is **not** acceptable: `/v1/clips` would still
read `None` from the file, so the duration would vanish on refresh. The consistent fix
is to make the mock files real transport streams whose PTS span tracks the elapsed
recording time, so both paths derive the same real duration from the file.

- **`raspi/service/src/ts_duration.rs`**: add `pub(crate) fn ts_pts_packet(pts: u64)
  -> [u8; PACKET_SIZE]` (plus the small `encode_pts` it needs), promoting the exact
  packet layout that currently lives in this module's `#[cfg(test)]` helpers
  (`pts_packet`/`encode_pts`). Reuse it from the existing tests to de-dup. Add a unit
  test asserting `scan_pts_bounds(&[ts_pts_packet(a), ts_pts_packet(b)])` recovers the
  span (round-trip).
- **`raspi/service/src/backend.rs#run_mock_recording_writer`**: derive PTS from a
  **writer-lifetime packet counter**, not wall-clock. Keep a `u64` index that increments
  on every packet write and emit `ts_pts_packet(index * 9000)` (9000 ticks = the 100 ms
  tick interval at 90 kHz). Write one packet immediately after opening each segment (the
  initial open and every rollover open), then one per 100 ms `interval.tick()`, replacing
  `MOCK_RECORDING_CHUNK` (now removed). Two properties fall out, both load-bearing for the
  `events.rs` `dur_ms > 0` assertion:
  - **Distinct PTS regardless of scheduling.** `tokio::time::interval` defaults to
    `MissedTickBehavior::Burst`: under a scheduler stall the missed ticks fire
    back-to-back, so a wall-clock `elapsed() * 90` would hand several packets the *same*
    PTS, collapse to one distinct value in `scan_pts_bounds`, and yield `dur_ms: None`. A
    monotonic counter makes every packet's PTS strictly increasing by construction, so any
    segment with >= 2 packets has a positive span deterministically.
  - **>= 2 packets in every rolled segment.** The open-time packet plus the immediate
    first `interval.tick()` (it fires at elapsed ~0 and so cannot roll) guarantee each
    segment holds two packets before any rollover can fire -- closing the residual
    single-packet edge a counter alone would leave (an early >= `roll_interval` stall could
    otherwise roll a segment holding only its first tick's packet -> one PTS -> `None`).
  - **Durations stay realistic.** Under Burst the tick *count* tracks elapsed boundaries,
    so per file `max - min` ~= the segment's real span (a ~4 s final segment -> ~40 ticks
    -> `00:04`); the duration just no longer depends on the *values* `elapsed()` returns.
  - A ~5 s segment yields ~50 PTS packets (~9 KB); files stay small (the user's
    "3.6 MB" was illustrative -- realistic sizing is out of scope).
  - Edge: a final segment stopped before its first tick holds only its open packet (one
    PTS) and yields `dur_ms: None` -- the same benign edge the real backend has, and not a
    segment any test asserts a duration on. Acceptable.

Note: these minimal packets carry PTS but no PAT/PMT or real video, so mock clips
remain non-playable in the app's remux/playback path -- unchanged from today, just now
duration-bearing. Out of scope here.

## Part 3 -- Camera fake fidelity: `camera.py --fake` emits valid TS too

Part 1 flips the real `CameraBackend` finalize path
(`raspi/service/src/camera/mod.rs#parse_stderr`, both the rollover and recording-stopped
`clip_meta(.., None)` calls) to `Some(..)`. That path already has integration coverage in
`raspi/service/tests/camera_process.rs`, which spawns `python3 camera.py --fake`. But the
fake writes non-TS bytes -- `b"fake segment\n"` at segment open/rollover and `b"tick\n"`
per recording-loop tick in `FakeCameraDriver` -- so a camera-backed `clip_finalized` would
still carry `dur_ms: null`, and a regression on the camera path would pass unnoticed.
`/v1/clips` cannot witness this: it computes duration independently from the file, so it
stays non-null even if the finalize **event** path regresses. Only an assertion on the
emitted `clip_finalized` event closes the gap -- which requires the fake to emit real TS.

The fake's per-segment duration has no product value -- the simulator runs the Rust
`MockBackend` (`just raspi-mock`), never `camera.py`; the camera-path test needs only a
deterministic non-null `dur_ms` it can match against `/v1/clips`. So the fake does *not*
mirror the Rust mock's counter/realism. It writes a small, fixed set of TS packets with
**segment-local** PTS at each segment open and drops the per-tick append:

- **`raspi/camera/camera.py`**: add a module-level `ts_pts_packet(pts: int) -> bytes`
  that builds the same 188-byte TS+PES+PTS packet as the Rust helper (sync `0x47`, PUSI
  set, adaptation-field-control `01`, a video PES with a 5-byte PTS) -- a direct port of
  `encode_pts`/`pts_packet` from `ts_duration.rs`. Where the fake currently writes
  `b"fake segment\n"` (the initial `start_recording` open and the rollover open in
  `_recording_loop`), write a fixed three-packet segment instead --
  `ts_pts_packet(0) + ts_pts_packet(9000) + ts_pts_packet(18000)` -- so every finalized
  fake segment carries a fixed, non-null ~300 ms duration that `/v1/clips` recomputes
  identically. **Drop the per-tick `b"tick\n"` append** (the `segment.open("ab")` write at
  the bottom of `_recording_loop`): it existed only to grow the file, which now serves no
  purpose. The loop still runs on its `time.sleep(0.1)` cadence to drive the
  `--fake-segment-secs` rollover check; only the byte-append goes away.
- This is deliberately *not* the Rust mock's approach (counter-derived PTS, one packet per
  tick). The mock needs duration to track real recording time (the confirmed "show `00:04`
  in the simulator" requirement); the camera fake needs only a fixed positive duration for
  one regression assertion. Fixed-PTS-at-open is simpler, fully deterministic, and -- unlike
  a `time.monotonic()`-derived PTS -- carries no risk of two same-instant writes (the open
  write and the first loop tick are not sleep-separated) collapsing to one PTS.
- Considered and rejected: a committed binary `.ts` fixture (the reviewer's pivot). It
  removes the ~10-line Python builder but adds an opaque, separately-generated artifact to
  a repo that prizes readable ASCII, and the bytes still have to come from *some* encoder.
  A tiny inline emitter is the cleaner trade.
- The lifecycle events (`segment_opened`/`segment_closed`, `recording_*`) and the segment
  file **names** the existing `camera_process.rs` tests assert on are unchanged; only byte
  **contents** change (no existing camera test asserts byte counts or file growth).
  `--self-test` (which only checks `compute_skip`) is unaffected.
- The 188-byte layout is still expressed in two places -- Rust
  `ts_duration.rs#ts_pts_packet` (the mock + its round-trip test) and this Python emitter.
  The child is a separate process, so some duplication is unavoidable; MPEG-TS framing is a
  frozen format, and the Python side is now a trivial fixed-PTS emitter, not a second clock.

## Tests

- **`raspi/service/tests/{clips,status,preview}.rs`** (compile surface): each defines a
  `StubBackend` implementing `Backend`, so each must implement the new required
  `clip_durations` -- `fn clip_durations(&self) -> Arc<DurationCache> {
  Arc::new(DurationCache::default()) }` (importing `dancam::DurationCache`, and `Arc` in
  `preview.rs` which doesn't yet). Returning a fresh cache is correct for these stubs:
  they never drive the finalize path, and `AppState::new` calls `clip_durations()`
  exactly once, so the handler reads a working (empty, compute-on-demand) cache -- which
  is what keeps the existing real-TS-fixture duration assertions
  (`clips_route_reports_duration_for_real_transport_stream`,
  `status_reports_fsm_owned_open_segment_metadata_while_recording`) green. Without these
  three impls `just raspi-test` does not compile.
- **`raspi/service/tests/events.rs`** (`rollover_clip_is_pullable_when_clip_finalized_is_observed`):
  it already pulls the `clip_finalized` frame via `wait_for_type(&mut reader,
  "clip_finalized", ..)` and reads `finalized_id`. Assert the event carries a real
  duration (`finalized.json["dur_ms"].as_u64()` is `Some(d)`, `d > 0`), then GET
  `/v1/clips`, find the clip whose `id == finalized_id`, and assert its `dur_ms` **equals
  the event's `dur_ms`**. What this actually guards: a *fabricated / non-file-derived*
  event duration -- if the event's `dur_ms` came from anything but the segment file it
  would diverge from `/v1/clips`'s file-derived value and fail (the Part 2 anti-pattern).
  It does not -- and cannot -- distinguish one shared cache from two separate file-backed
  caches; both yield equal values, which is precisely the point (see Context). Asserting on
  the *same* segment is what makes "would flicker on refresh" observable. Structure-
  insensitive: asserts only on wire JSON. (Target the rollover-finalized segment; per
  Part 2 the open-time packet plus the immediate first tick guarantee it holds >= 2
  distinct-PTS packets, so `dur_ms` is reliably non-null.)
- **`raspi/service/tests/mock_recording.rs`** (`writer_mock_surfaces_open_segment_rollover_and_stop`):
  after the rollover, assert the rolled clip in `/v1/clips` has a non-null `dur_ms`.
  A lighter independent guard on the list path (events.rs owns the strong same-segment
  equality). (The existing file-set-stability assertions still hold -- the test never
  checks byte counts.)
- **`raspi/service/tests/camera_process.rs`**
  (`supervisor_tracks_rollover_and_finalizes_last_segment_on_stop`): this already drives
  the python fake through a real rollover and stop over the HTTP app. Extend it to witness
  the **camera-backed** finalize event: subscribe to `/v1/events` (or `backend.connect()`)
  before issuing start, wait for the first `clip_finalized` -- the rollover-finalized start
  segment (seg 5), emitted mid-recording when seg 6 opens (the existing test's `rolled`
  variable is instead seg 6, the *stop* segment) -- assert its `dur_ms` is `Some(> 0)` and
  equal to the `/v1/clips` `dur_ms` for that same id. Because the fake now writes its fixed
  three-packet segment at *open* (Part 3), every finalized fake segment carries the same
  ~300 ms duration regardless of how long it stayed open, so this is deterministic and
  needs no timing slack. (Reuse a minimal SSE reader like the one in `events.rs`, or read
  the `clip_finalized` `SeqEvent` via `backend.connect()`.) This is the **only** assertion
  that covers the `camera/mod.rs` `None -> Some(..)` change -- `/v1/clips` alone cannot,
  since it computes duration independently of the event path. Gated on `python3_available()`
  like its siblings, so non-Mac CI stays green.
- **`raspi/service/tests/clips.rs`**: unchanged. Its `dur_ms == Null` assertion uses
  synthetic non-TS files written directly (not the mock writer), so it stays valid; the
  real-TS-fixture test (`dur_ms ~= 30000`) also stays valid.
- No app/Swift tests change. The contract fixture `contract/events/clip_finalized.json`
  already specifies `dur_ms: 30000` and the app corpus test already asserts
  `durMs: 30_000` -- the fix makes runtime match the contract the app already trusts.

## Docs

- **`raspi/docs/design/10-2026-06-30-recorder-fsm-and-events-sse.md`**: add a concise
  note that `clip_finalized.dur_ms` is computed at finalization from the segment **file**
  (its PTS span), outside the hub lock -- the same derivation `/v1/clips` uses, so the two
  agree by construction. The backend owns one `DurationCache` that both paths share, but
  frame that as avoiding a redundant re-scan at list time, **not** as what makes the values
  consistent (two separate file-backed caches would agree too -- see Context). Note that
  both dev fakes (the Rust `MockBackend` writer and the Python `camera.py --fake`) now write
  valid TS so their finalized clips carry a real duration. Also review the now-questionable
  "the real camera backend is temporarily
  phase-only against the old session-less child protocol" sentence against the camera
  finalize path this change exercises and covers (`parse_stderr` emits duration-bearing
  `clip_finalized`); update it if stale. This realizes/clarifies the existing decision
  (the finalize event as the live source of finished-clip state) rather than reversing it,
  so it's an amendment, not a new ADR. Verify the `dur_ms` note in
  `02-2026-06-22-app-pi-transport-and-api.md` still reads correctly alongside it.
- **README**: no change -- this touches no packages, `config.txt`, units, Avahi/NM, or
  deploy paths.

## Verification

1. `just raspi-test` -- Pi unit + integration suites: the new same-segment event/list
   `dur_ms` equality in `events.rs`, the list-path guard in `mock_recording.rs`, the
   camera-backed `clip_finalized` duration check in `camera_process.rs` (runs when
   `python3` is available), the three `StubBackend` `clip_durations` impls (compile
   surface), and the `ts_pts_packet` round-trip unit test.
2. `just raspi-check` -- `cargo fmt --check` + `clippy -D warnings`.
3. `just app-test` -- confirm the app suite stays green (no app changes expected).
4. End-to-end in the simulator (no hardware):
   - `just raspi-mock` (now writes real TS to `.mock-rec`).
   - Run the app in Xcode against `DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080`.
   - Record a few seconds, then Stop. The just-finished `seg_XXXXX.ts` row should show
     `MM:SS - <size>` (e.g. `00:04 - ...`) **immediately**, with no pull-to-refresh.
   - Pull-to-refresh and confirm the duration is unchanged (no flicker), proving
     event/`/v1/clips` consistency.

## Implementation notes

- Mock writer: factored a `write_mock_packet` helper plus a
  `MOCK_PTS_TICKS_PER_PACKET` const (`raspi/service/src/backend.rs`) so the three packet
  write sites (initial open, rollover open, per-tick) share one body and advance the
  lifetime counter identically, instead of inlining `ts_pts_packet(index * 9000)` three
  times.
- `encode_pts` in `ts_duration.rs` is a private module fn (not `pub(crate)`): only
  `ts_pts_packet` calls it, so it needs no wider visibility.
- The `camera_process.rs` regression reads the `clip_finalized` `SeqEvent` via
  `backend.connect()` (one of the two options the plan offered) rather than an SSE
  reader -- it avoids parsing wire JSON and never needs to name the unnameable
  `ClipMeta` type, binding it by pattern in `Event::ClipFinalized(meta)`.

## Follow Up

- App test `ClipViewerViewControllerTests.completedProgressivePullSwapsToDurableMP4PreservingPlaybackPosition`
  is flaky: it fails under the full parallel `just app-test` run but passes in isolation.
  Unrelated to this change (no `app/` files touched); worth de-flaking separately.
