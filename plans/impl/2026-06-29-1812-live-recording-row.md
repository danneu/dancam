# Live "now recording" row in Recent clips

## Context

While the dashcam records, the app shows nothing for the footage being captured
*right now* -- the Recent clips list only contains finished segments, and the open
segment is deliberately hidden by the Pi (filtered from `/v1/clips`, 404'd by
`serve_clip`). We want the clip currently being recorded to appear at the top of
Recent clips with a red "REC" badge and a live `MM:SS` count-up, and -- as ffmpeg
rolls the segment over every ~30 s -- a fresh live row should take its place while
the just-finished segment settles into the list as a normal static clip.

The blocker today: the Pi reports only `recording: true`. There is no current-segment
id and no segment-start time, so a count-up has no source of truth. We are
implementing the already-specified-but-deferred `current_segment_id` field from the
transport ADR, plus a live duration, both sourced from machinery that already exists
(`raspi/service/src/clips.rs#max_clip_seq`, `raspi/service/src/ts_duration.rs#DurationCache`).
The open segment stays unlisted and unpullable -- we surface it as *status metadata*,
not a clips entry, so the settled listing rules in ADR 02/03 are preserved.

## Approach (decided)

`/v1/status` gains two fields describing the open segment while recording. The app
composes a synthetic "live" row at the top of Recent clips from those fields, ticks
its count-up at 1 Hz between status polls, and uses the segment-id change as the
crisp rollover signal that promotes the finished segment into the list.

Data flow:

```
ffmpeg writes seg_000NN.ts  ->  /v1/status { recording, current_segment_id: NN,
                                             current_segment_dur_ms: D }
   (1.5s poll, ConnectionFeature)  ->  lastStatus  ->  HomeViewController
   live row: seg_000NN.ts | REC | MM:SS  (seed = D, +1Hz local tick)
   when current_segment_id NN -> NN+1: refresh clips so NN appears finished;
                                        live row re-seeds to NN+1 at ~0:00
```

## Pi service (Rust)

**1. Expose the open segment on `/v1/status`** -- `raspi/service/src/status.rs#StatusResponse`
and `#status`.

- Add two fields to `StatusResponse`: `current_segment_id: Option<u32>` and
  `current_segment_dur_ms: Option<u64>`. Both `None` unless `backend_status.recording`.
- In `status(...)`, when recording, find the open segment and compute its current
  duration, reusing existing code:
  - `raspi/service/src/clips.rs#max_clip_seq` already finds the open segment's `seq` while
    recording. Add a sibling `pub(crate) fn open_segment(rec_dir) -> Option<(u32, PathBuf, u64)>`
    that returns the open seq plus its path and byte length from **one** scan, and make it
    the single source of truth for "which seq is open": point `serve_clip`'s 404 guard at it
    too -- `open_segment(&state.rec_dir).map(|(seq, _, _)| seq) == Some(id)` -- replacing its
    standalone `max_clip_seq` call (clips.rs#serve_clip), so the open-seq definition lives in
    one place (`max_clip_seq` folds into `open_segment`, or stays a thin
    `open_segment(..).map(|(s, _, _)| s)` wrapper to preserve its unit test). `#status`
    consumes the full tuple.
  - `current_segment_dur_ms = state.clip_durations.duration_ms(seq, &path, bytes)`
    (`raspi/service/src/ts_duration.rs#DurationCache::duration_ms`). The cache already
    re-derives when byte count grows, so each poll reflects the segment's current PTS
    span -- i.e. seconds recorded so far. `state.clip_durations` is the same shared
    cache `list_clips` clones.
- Wrap the dir scan + duration read in `tokio::task::spawn_blocking`, mirroring
  `clips.rs#list_clips`, so the 1.5 s liveness poll never blocks the async runtime on
  disk I/O. `current_segment_id` is just the `seq` (cheap); the windowed TS read is the
  part to keep off the runtime thread.

**2. Make the mock exercise recording** -- `raspi/service/src/backend.rs#MockBackend`.

Today `MockBackend::start_recording` only flips a boolean and writes no files, so the
new fields would stay `None` and the live row would never show against the default
backend. Extend the mock so `start_recording` spawns a task that materializes a growing
`seg_000NN.ts` under `rec_dir` and rolls to the next index on a **roll interval passed in
at construction** (and `stop_recording` cancels it). `main.rs` reads `DANCAM_MOCK_SEGMENT_SECS`
(defaulting short for dev so rollover is observable without a 30 s wait) and passes it to
the constructor; tests pass a small interval directly rather than routing through the env
var (env is process-global and racy across parallel tests -- see Tests). This is the
harness that lets the whole feature -- live row, count-up, rollover -- be driven
end-to-end with no hardware.

- **Add a distinct writer constructor; leave `new()`/`default()` alone.** The mock has no
  path today, and *every* current caller uses the zero-arg `MockBackend::new()` --
  `main.rs`, `tests/status.rs`, `tests/recording.rs`, `tests/health.rs` (nothing calls
  `default()`). So do **not** give `new()` a `rec_dir` parameter -- it would break those
  three test call sites. Keep `new()`/`default()` as the zero-arg **no-op writer** (flip the
  boolean, write nothing -- today's behavior), and add a distinctly named writer constructor
  that takes the rec dir and roll interval, e.g. `MockBackend::recording_to(rec_dir, interval)`
  (or a `.with_writer(rec_dir, interval)` builder). Thread `rec_dir` (+ the
  `DANCAM_MOCK_SEGMENT_SECS`-derived interval) through **only** `main.rs`'s
  `Ok("mock") | Err(_)` arm; the three `new()` test sites stay untouched, and the rollover
  test constructs via `recording_to` with a small interval.

- **Point the `raspi-mock` recipe at a writable scratch rec dir.** `raspi-mock`
  (`cargo run`, no env) falls back to `DEFAULT_REC_DIR` (`/home/<user>/rec`,
  `raspi/service/src/lib.rs#DEFAULT_REC_DIR`) -- a Linux path absent on the Mac dev box, so
  the new writer would have nowhere to write and the live row would never appear under
  `just raspi-mock`. Update `raspi-mock` to set `DANCAM_REC_DIR` to a gitignored scratch
  dir (e.g. `DANCAM_REC_DIR=.mock-rec`, resolving to `raspi/service/.mock-rec` since the
  recipe `cd`s there) plus a short `DANCAM_MOCK_SEGMENT_SECS`, and have the mock writer
  `create_dir_all` its target so a fresh checkout's first run can't silently no-op (closing
  the "missing/unwritable path -> no open segment" gap). Add the scratch dir to
  `.gitignore`. Keep `raspi-mock`'s default `127.0.0.1:8080` bind -- that is the address
  the app's strict HTTP client accepts. Leave `raspi-mock-clips` pointed at `assets/clips`
  for browsing the committed finished fixture, but do not drive live recording against it
  -- the writer continues from `max_clip_seq + 1` and would scatter untracked
  `seg_000NN.ts` into the fixture dir.
- **Do not use `raspi-mock-lan` to verify the app.** It binds `0.0.0.0:9000`, but
  `HostPolicy` (`raspi/service/src/lib.rs#HostPolicy`) only accepts allowlisted hosts on
  port `8080`, and the app's `HTTPRequestEncoder.hostHeader`
  (`app/DanCam/DanCam/Networking/HTTP/HTTPRequestEncoder.swift`) emits `Host: 127.0.0.1:9000`
  for a `:9000` URL -- so the service answers `421 Misdirected Request` before the live-row
  path is reached. App verification runs against `raspi-mock` on `127.0.0.1:8080` (see
  Verification). LAN-device verification from a physical iPhone is out of scope here: it
  would also need the Mac's LAN IP allowlisted on `8080`, a `HostPolicy` change this plan
  does not make.

- Note: mock bytes are not real TS, so `DurationCache::duration_ms` returns `None` for
  them -> `current_segment_dur_ms` is `None`. The app's count-up falls back to a local
  anchor in that case (see App step 2), so the mock still demonstrates the feature. (If
  we want a real seeded duration from the mock, have it append packets from the committed
  `raspi/service/assets/clips/seg_00000.ts` fixture instead of arbitrary bytes -- optional.)

## App (Swift / UIKit)

**1. Decode the new fields** -- `app/DanCam/DanCam/Networking/StatusResponse.swift#StatusResponse`.
Add `var currentSegmentId: Int? = nil` and `var currentSegmentDurMs: UInt64? = nil`. The
`= nil` defaults are load-bearing: `StatusResponse`'s synthesized memberwise initializer is
used by ~6 sites (`StatusClient.noop`, the three `StatusResponse.sample` helpers in
`AppFeatureTests`/`ConnectionFeatureTests`/`AppShellViewControllerTests`, and
`HealthTelemetryTests`'s two direct constructions), all of which keep compiling only if the
new fields default -- the prior "only the decode test changes" claim understated this. Decoding
is unaffected: `StatusClient.live` uses `JSONDecoder` with `.convertFromSnakeCase`, and
synthesized `Decodable` maps an absent key to `nil` via `decodeIfPresent`. `Int?` matches
`Clip.id` for filename formatting and comparison.

**2. Model and compose the rows** -- `app/DanCam/DanCam/Features/Home/HomeViewController.swift`.

- Introduce a row type, e.g. `enum HomeRow { case live(LiveSegment); case finished(Clip) }`,
  where `LiveSegment` carries `id: Int`, `seedDurMs: UInt64?`, and the monotonic anchor
  timestamp captured when that seed was observed.
- Extract the composition into a **pure, testable function that takes the previous live
  segment as input**, so the count-up's anchor is stable across polls instead of being
  recreated each time, e.g.
  `HomeRow.compose(clips:recording:currentSegmentId:currentSegmentDurMs:previousLive:now:)`.
  A live row is prepended only when `recording` and `currentSegmentId != nil`. The VC
  already observes `\.clips`, `\.recording`, and `\.connection.lastStatus`; feed all
  three plus the previously-composed live segment into the composer and store the
  resulting `[HomeRow]` in place of the current `clips: [Clip]`.
- `LiveSegment` carries `id: Int`, `seedDurMs: UInt64?`, and a monotonic `anchor`
  (`ContinuousClock.Instant` / `CACurrentMediaTime`). Displayed elapsed =
  `(seedDurMs ?? 0) + (now - anchor)`. The composer sets these per case -- and the
  previous-live input is **load-bearing**, because the same status can be re-polled every
  1.5 s with no new duration:
  - **New segment** (no previous live row, or `previousLive.id != currentSegmentId`, i.e.
    a rollover): fresh `anchor = now`; `seedDurMs = currentSegmentDurMs` (or `nil` ->
    counts from `0:00`).
  - **Same segment, no new Pi duration** (`currentSegmentDurMs == nil` -- the mock path,
    or a just-born segment the Pi can't yet measure): **carry `previousLive.anchor` and
    `previousLive.seedDurMs` forward unchanged -- do *not* reset.** This is the fix for
    the count-up snapping back toward `0:00` on every poll when the Pi reports no
    duration.
  - **Same segment, new Pi duration** (`currentSegmentDurMs != nil`): re-seed
    (`seedDurMs = currentSegmentDurMs`, `anchor = now`) so the count stays honest and
    self-correcting; clamp so displayed elapsed never decreases within a segment id (the
    Pi's PTS span can briefly lag wall-clock).

**3. Render the live row** -- new `LiveClipCell: UITableViewCell` subclass.
`UIListContentConfiguration` can't host the badge, so finished rows keep
`UIListContentConfiguration.subtitleCell()` (unchanged: filename + `Formatters.clipMetadata`)
and the live row uses `LiveClipCell`, which lays out: primary `seg_000NN.ts`, the
count-up `MM:SS`, and a `app/DanCam/DanCam/Views/StatusPillView.swift#StatusPillView`
configured as the existing red-dot "REC" badge (reuse the same component the preview's
`recPill` uses). Register a second reuse id; pick the cell per `HomeRow` case in
`cellForRowAt`.

**4. The 1 Hz tick** -- a `Timer` owned by the VC. Start it when a live row is present,
invalidate it when not and in `viewWillDisappear` (mirror the existing
`onAppear`/`onDisappear` clips lifecycle). Each tick updates only the visible live cell's
elapsed label via `clipsTableView.cellForRow(at:)` -- never `reloadData()` -- so there is
no per-second table churn. (`renderClips`/status changes still rebuild rows and reload as
today.)

**5. Count-up formatter** -- `app/DanCam/DanCam/Support/Formatters.swift`. Add a count-up
helper that **floors** seconds (a running stopwatch shows `0:00` during the first second),
distinct from `clipDuration` which rounds to nearest for finished clips. Same zero-padded
`MM:SS` shape.

**6. Guard the live row from playback** -- `HomeViewController#tableView(_:didSelectRowAt:)`.
`serve_clip` 404s the open segment, so the live row must not push `ClipViewerViewController`.
Give `LiveClipCell` `selectionStyle = .none` and ignore the `.live` case on selection;
keep finished-row tapping unchanged. The guard is enforced structurally (composer gating +
`selectionStyle = .none`); a focused "tap row 0 with a live row present pushes nothing" test
is a reasonable optional follow-up but is deferred -- there is no `HomeViewController` test
harness today and such a test would be UIKit-structure-sensitive.

**7. Prompt the rollover refresh** -- `app/DanCam/DanCam/Features/App/AppFeature.swift#reduce`,
`.connection` case. **Restructure, don't nest.** Today the case early-returns
`connectionEffect` via `guard recording-changed else { return connectionEffect }`, so on a
rollover (where `recording` stays `true`) that guard's `else` fires -- anything appended "in
parallel" *inside* the post-guard `.merge` would be dead code, and the finished segment would
surface only via the 10 s clips poll. Instead: capture `previousSegmentId =
state.connection.lastStatus?.currentSegmentId` *before* `ConnectionFeature.reduce`, accumulate
effects in an array seeded with `connectionEffect`, and append the two refreshes
**independently**:
- the existing recording-change branch (append `reduceRecording(.statusObserved(recording:))`
  when `recording` changed) -- unchanged behavior, just lifted out of the early return;
- a new branch: when the new `currentSegmentId` is non-nil and differs from `previousSegmentId`,
  append `ClipsFeature.reduce(&state.clips, .refresh).map(Action.clips)`.
Return `.merge(effects)` (or `connectionEffect` alone when nothing else was appended). This
makes the just-finished segment appear in `/v1/clips` within a poll instead of up to 10 s, so
the previous live row settles into a static finished row promptly. The recording->idle refresh
in `shouldRefreshClips` still owns the stop transition (non-nil -> nil segment id), so gating
the new branch on a non-nil current id avoids a redundant double refresh; `.refresh` is
idempotent regardless (poll effect uses `cancelInFlight`).

## Docs

- **ADR 02** (`raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md`): add a dated
  note (the file already carries dated notes) recording that `/v1/status` now carries
  `current_segment_id` and `current_segment_dur_ms`. Be precise about provenance:
  `current_segment_id` **realizes a field already in the accepted contract** but intentionally
  deferred (per the 2026-06-26 note's deferred list); `current_segment_dur_ms` is a **new
  additive field** that never appeared in the accepted `/v1/status` contract -- introduce it as
  additive (non-breaking). State the rationale: the count-up is anchored on the open segment's
  TS-PTS elapsed (reusing the duration primitive) rather than a wall-clock `since`, because the
  Pi has no RTC and time provenance is owned by the `moss` swoop; and the open segment remains
  unlisted/unpullable -- it is exposed as status metadata only, so ADR 03's listing rule is
  unchanged.
- **Roadmap** (`docs/roadmap.md`): note this live-recording row as a `fern` deepening (the
  home-dashboard swoop that owns the Recent clips list).
- **README:** no change to Pi provisioning/onboard state. Document the new dev-harness
  knobs the `raspi-mock` recipe now sets -- `DANCAM_MOCK_SEGMENT_SECS` and the writable
  `DANCAM_REC_DIR` scratch dir -- alongside the other `DANCAM_*` mock knobs (Justfile mock
  recipes / README smoke-test block), and note the gitignored `.mock-rec` scratch dir.

## Reuse (don't rebuild)

- `raspi/service/src/clips.rs#max_clip_seq` -- the existing open-seq scan to extend into
  `open_segment` (one helper, shared by `#status` and `serve_clip`).
- `raspi/service/src/ts_duration.rs#DurationCache::duration_ms` + `AppState.clip_durations`
  -- open-segment live duration.
- `app/DanCam/DanCam/Views/StatusPillView.swift#StatusPillView` -- the "REC" badge.
- `app/DanCam/DanCam/Support/Formatters.swift#clipDuration` -- shape to mirror for the
  count-up formatter.
- `AppFeature.reduce`'s existing `recording` diff -- pattern to copy for the
  `currentSegmentId` rollover refresh.

## Tests

Behavioral and structure-insensitive only:

- **Rust status** (`raspi/service/tests/status.rs`, extend `status_returns_dashboard_wire_contract`):
  `tests/status.rs` has no `StubBackend` today (it imports only `MockBackend`; `tests/clips.rs`
  and `tests/preview.rs` each declare their own `StubBackend`). Add a local `StubBackend { recording }`
  mirroring `tests/clips.rs#StubBackend` (or factor a shared test-support module) and build state
  like `tests/clips.rs#state` (`AppState::new(.., StubBackend { recording }).with_rec_dir(rec_dir)`).
  With `recording: true` and a `TempRecDir` containing the real fixture
  `assets/clips/seg_00000.ts`, assert `/v1/status` returns `current_segment_id: 0` and a
  `current_segment_dur_ms` ~= 30000 (the fixture's known span, per
  `tests/clips.rs#clips_route_reports_duration_for_real_transport_stream`) -- a stub + real
  fixture is required here precisely because the mock writer's fake bytes yield `dur_ms = null`.
  With `recording: false`, assert both fields are `null`.
- **Row composition** (app unit test next to `app/DanCam/DanCamTests/...`): the pure
  `HomeRow.compose(...)`, covering the anchoring rules that are easy to get wrong --
  - live row present only while recording with a known segment id; absent when idle;
    finished rows pass through unchanged;
  - **same id + `currentSegmentDurMs == nil` preserves the prior `anchor`/`seedDurMs`**
    (no reset toward `0:00`);
  - **id change reseeds** with a fresh anchor;
  - **same id + non-nil `currentSegmentDurMs` reseeds** to the Pi value and never ticks
    backward.
- **App status decode** (`app/DanCam/DanCamTests/Networking/StatusClientTests.swift`,
  extend `liveClientBuildsRequestAndDecodesStatusResponse`): add `current_segment_id` and
  `current_segment_dur_ms` to the JSON payload and assert they decode onto the expected
  `StatusResponse`. With the `= nil` defaults (App step 1) this is a deliberate value-assertion,
  not a forced compile fix -- it guards the snake-case/type contract (absent key -> nil, present
  key -> value) that the value-injected composition tests can't catch.
- **Count-up formatter** (`app/DanCam/DanCamTests/Support/FormattersTests.swift`): floors
  seconds, zero-pads `MM:SS`, handles 0 and minute rollover.
- **Rollover refresh** (`AppFeature` reducer test): drive two consecutive statuses with
  `recording: true` **held constant** while `currentSegmentId` advances, and assert the clips
  poll is refreshed; an unchanged `currentSegmentId` emits no refresh. Holding `recording`
  constant is essential -- a test that also flips `recording` would pass via the recording
  branch and mask the dead-code regression App step 7 fixes.
- **Mock recording + rollover (Rust)** (`raspi/service/src/backend.rs` unit test, or
  `raspi/service/tests/`): construct the writer mock via `recording_to(rec_dir, interval)` with
  a **small interval passed directly** (not via `DANCAM_MOCK_SEGMENT_SECS` -- env is
  process-global and racy under parallel tests), start recording against a temp `rec_dir`, and
  assert an open segment is surfaced (an in-progress `seg_000NN.ts` is written and `/v1/status`
  reports a `current_segment_id`). Then **poll until** `/v1/status.current_segment_id`
  **advances** (e.g. 0 -> 1) under a **generous timeout** well above the interval (await the
  observation, don't fixed-sleep-then-assert, so a loaded CI box can't race it), and assert the
  just-finished previous segment now appears in `/v1/clips` **while still recording**
  (`read_finished_clips` lists every seq below `max_seq`, mirroring
  `clips.rs#read_finished_clips_excludes_newest_segment_while_recording`); then `stop_recording`
  and assert the writer task is cancelled (segment count stops growing and the new status fields
  clear). This guards against a writer that grows one `seg_000NN.ts` forever --
  `current_segment_id` never changing -- which would never exercise the rollover-refresh path.

## Verification (end-to-end, no hardware)

1. Run the extended mock for the simulator: `just raspi-mock` on `http://127.0.0.1:8080`
   (confirm recipe names with `just --list`). The recipe sets a writable scratch
   `DANCAM_REC_DIR` (so the writer has somewhere to write -- not the nonexistent
   `/home/<user>/rec`) and a short `DANCAM_MOCK_SEGMENT_SECS` (so rollover is quick), with no
   manual env. Use `8080`, not `raspi-mock-lan`'s `9000`: the app's `HostPolicy` only
   accepts allowlisted hosts on port `8080`, so a `:9000` `Host` header returns
   `421 Misdirected Request` before the live row is exercised.
2. Build/run the app in the simulator pointed at the mock; tap Record.
3. Confirm: a top row `seg_000NN.ts` with the red "REC" badge and a `MM:SS` count-up
   ticking each second; it is not tappable.
4. Wait one roll interval: the live row's segment finalizes into a normal static finished
   row (showing bytes; a real `MM:SS` duration appears only if the mock writes real TS
   fixture bytes -- fake mock bytes yield `dur_ms = null`, so a correct implementation
   shows bytes only here, no duration), and a fresh live row (`id+1`) starts counting from
   ~0:00.
5. Stop recording: the live row disappears; the final segment shows as a finished clip
   (existing recording->idle refresh).
6. Run unit tests via the Justfile (`just --list` for the Rust + app test tasks).

## Risks / edge cases

- **Rollover overshoot (bounded):** between ffmpeg's cut and the next status poll
  (<=1.5 s) the live counter can tick slightly past 0:30 before re-seeding to the new
  segment. Acceptable and far tighter than a clips-poll-only approach; eliminating it
  entirely would need a push signal (SSE), which is out of scope.
- **Status path I/O:** the open-segment TS read runs every 1.5 s; keep it in
  `spawn_blocking` and rely on the byte-keyed cache so it stays cheap.
- **Mock seed:** fake mock bytes yield `current_segment_dur_ms = null`; the app seeds
  from first observation of the segment id and **preserves that anchor across polls**
  (App step 2), so the mock still shows a steady count-up that resets only on a real
  id rollover.
