# Plan: Honest offline presentation for the live recording row

## Context

While recording with the app open, pulling power on the Pi transitions the app to
"Not connected" (strip + preview handle it), but the live recording row in Recent
clips ("seg_00024.ts REC 01:47") keeps counting up forever, the REC pill stays lit,
and the record button still offers "Stop" against an unreachable host.

Root cause: `Link` (`app/DanCam/DanCam/Features/Connection/Link.swift`) correctly
distinguishes `.online(World)` from `.offline(last: World?)`, but `Link.world`
erases that distinction, and Home's recorder observation
(`store.observe(\.link.world?.recorder)` in
`app/DanCam/DanCam/Features/Home/HomeViewController.swift#viewDidLoad`) drinks from
the erased view. The live row's elapsed time is a purely local extrapolation
(`LiveSegment` anchor + 1 Hz timer) that nothing gates on link phase. Similarly,
nothing folds the offline transition into `RecordingFeature.State`, so it stays
`.recording`.

The fix makes staleness a first-class, typed fact so present-tense UI cannot be
derived from last-known data without explicitly handling it. Principle (new ADR 18,
extending ADR 10 and ADR 17): heartbeat is connection truth, therefore present-tense
UI claims require heartbeat-fresh (`.online`) state; stale state must be typed as
stale, not erased.

Honest degradation in the ambiguous case: the app cannot distinguish "Wi-Fi blip,
Pi still recording" from "Pi lost power". The frozen row renders exactly what the
app knows -- "when I last heard from the camera, this segment was at ~1:47" -- and
reconciles automatically on reconnect (thaw / finalize / new-session replace).

## Steps

Steps 1-3 are one logical unit (reducer truth) and must land as one commit --
dispatching the offline fold without the step 3 `previousPhase` fix would strand
recording at `.unknown` after reconnect. Step 4 (view side) is a second commit.
ADR (step 5) rides with commit 1.

### Step 1 -- `RecorderTruth` on `Link`

`app/DanCam/DanCam/Features/Connection/Link.swift`: add a top-level
`nonisolated enum RecorderTruth: Equatable, Sendable` next to `Link`, plus a
computed `Link.recorderTruth` (pattern precedent: `Link.world`, `Link.onlineWorld`):

```swift
enum RecorderTruth: Equatable, Sendable {
    case live(RecorderSnapshot)       // link .online
    case lastKnown(RecorderSnapshot)  // link .offline(last: some)
    case unknown                      // .connecting or .offline(last: nil)
}
```

Named `.unknown` (not `.none`) to avoid Optional-promotion ambiguity and to mirror
`RecordingFeature.State.unknown`. Lives on `Link` (domain-derived, not view state)
so Health or a future CarPlay surface can reuse it.

Tests (`DanCamTests/Features/Connection/LinkTests.swift`): all four derivations --
`.online -> .live`, `.offline(last: world) -> .lastKnown`,
`.offline(last: nil) -> .unknown`, `.connecting -> .unknown`.

### Step 2 -- `RecordingFeature.Action.linkWentOffline`

`app/DanCam/DanCam/Features/Recording/RecordingFeature.swift`:

- Hoist the two inline `"recording"` effect-id literals (`startTapped` and
  `stopTapped` in `RecordingFeature.swift`) into
  `private static let commandID = "recording"` (mirrors `AppFeature.streamID`
  style); the new `.cancel(id: commandID)` below becomes the third use. Leave the
  unrelated `"recording"` in `AppFeature.State#logPhase` alone -- it is a log
  string, not an effect id.
- New action case `.linkWentOffline`: sets `state = .unknown` unconditionally and
  returns `.cancel(id: commandID)` to kill any in-flight start/stop request.
  Race-safety is already guaranteed by the architecture: `Store` is `@MainActor`,
  `cancelTask` runs synchronously inside the reducing `send`, and effect bodies
  guard `Task.isCancelled` before every send -- a late `.recordingResponse` either
  fully reduces before the offline action or is dropped; no interleaving lands a
  stale response after the reset. `.cancel` with no in-flight task is a no-op.
- `Effect.map` preserves ids, so the cancel survives `.map(Action.recording)` in
  `AppFeature.reduceRecording`; the store-global id "recording" collides with
  nothing ("events-stream", "events-heartbeat", "events-reconnect", "time-sync").
- Add the new case to the exhaustive `RecordingFeature.Action.logLabel` switch
  (private extension in `app/DanCam/DanCam/Features/App/AppFeature.swift`).

Tests (`DanCamTests/Features/Recording/RecordingFeatureTests.swift`): the plain
state transitions only -- `.linkWentOffline` from
`.recording`/`.starting`/`.stopping` -> `.unknown`. The **in-flight cancellation**
regression test moves to the AppFeature level (step 3): there the effect runs
`.map(Action.recording)`-wrapped and dispatched through the merged
`.heartbeatTimedOut` effects exactly as it does in production, so it fails if
`Effect.map` ever stops preserving ids and lets a stale `.recordingResponse` land
after the reset. A RecordingFeature-level cancellation test would exercise the
effect unmapped and un-merged and could not catch that regression, so it is not
worth writing at both levels.

Deterministic drain (test support): `TestStore.cancelTask`
(`DanCamTests/Support/TestStore.swift#cancelTask`) removes the task handle
immediately, so `finishEffects()` has nothing to await for a canceled effect --
asserting right after gate release would race the effect's post-await send path
and pass vacuously. Extend `TestStore`: `cancelTask` retains the canceled task in
a `canceledTasks` array, and a new `finishCanceledEffects()` awaits and clears
them. The step 3 in-flight cancellation test calls `finishCanceledEffects()`
after releasing the gate, before `expectNoReceivedActions()`. Keep it separate
from `finishEffects()` (opt-in) so existing tests whose canceled effects await
non-cancellation-honoring gates (e.g. `SleepGate` in
`AppFeatureTests.swift#reconnectStreamIfOfflineCancelsPendingBackoff`) don't
hang.

No record-button or REC-pill work needed: `RecordButtonStyle.from(.unknown)`
already renders a disabled "Record", and
`HomeViewController#renderRecording` already hides the pill for `.unknown`.

### Step 3 -- AppFeature: dispatch the fold + reconnect re-derivation fix

`app/DanCam/DanCam/Features/App/AppFeature.swift`:

- `.streamFailed` and `.heartbeatTimedOut` (the two `wentOffline()` sites) append
  `reduceRecording(state:action:.linkWentOffline:dependencies:)` to their merged
  effects.
- **Critical companion fix** in `case .event`: both the pre-fold `previousPhase`
  read and the post-fold phase read must switch from `state.link.world?` to
  `state.link.onlineWorld?`. Today `previousPhase` reads the offline last-known
  world; after an offline reset to `.unknown`, a reconnect snapshot with the SAME
  phase (still `.recording`) would compare equal, never fire
  `.recorderPhaseObserved`, and strand recording at `.unknown` (disabled button)
  forever. With `onlineWorld`: deltas while online unchanged, deltas while
  offline/connecting no-op (fold already guards on `.online`), and the
  first snapshot after offline sees `previousPhase == nil` and re-derives.

Tests (`DanCamTests/Features/App/AppFeatureTests.swift`):

- Update `TimeSyncDisconnect.applyExpectedState` (test helper enum at
  `AppFeatureTests.swift#TimeSyncDisconnect`) to set `recording = .unknown` for
  both disconnect variants, and the second-snapshot closure in
  `disconnectCancelsPendingTimeSyncRetryAndReconnectStartsOneFreshAttempt` to
  expect `recording = .idle` (re-derivation now fires). All other existing tests
  start from the `state()` default `.unknown` and survive unchanged.
- New test `offlineThenSamePhaseSnapshotRederivesRecording`: seed
  `.online(world(phase: .recording))` + `recording: .recording`, send
  `.heartbeatTimedOut` (expect `.offline(last:)` + `recording .unknown`), then
  `.event(.snapshot(sameWorld))` (expect `recording .recording`). Cover
  `.streamFailed` too (parameterize like `TimeSyncDisconnect` if convenient).
- New test `offlineCancelsInFlightRecordingCommand` (the relocated in-flight
  cancellation regression -- exercises the mapped + merged cancel path and the
  reducer reset in one behavioral test). Seed `.online(world)` +
  `recording: .recording`, `sleep: longSleep` (so the `.heartbeatTimedOut`
  reconnect backoff can't fire `.streamReconnect` and trip
  `expectNoReceivedActions()`). Send `.recordTapped` (routes to `.stopTapped` ->
  `recording .stopping`) with a gated `RecordingClient.stop` (`AsyncSignal`,
  in-flight when the offline lands). Send `.heartbeatTimedOut` (expect
  `.offline(last:)` + `recording .unknown`). Release the gate, call
  `finishCanceledEffects()`, then `expectNoReceivedActions()` and assert
  `recording == .unknown` -- proves the stale `.recordingResponse` never lands
  after the reset even though the cancel travels through `.map(Action.recording)`.
  This is the only test that fails if `Effect.map` ever stops preserving ids.

### Step 4 -- Frozen live row

`app/DanCam/DanCam/Features/Home/HomeViewController.swift` (the `LiveSegment`,
`HomeRow`, and `LiveClipCell` types live at the top/bottom of this file):

- **`LiveSegment`**: replace `seedDurMs`/`anchor` stored properties with a nested
  `enum Elapsed: Equatable, Sendable { case ticking(seedDurMs: UInt64?, anchor:
  ContinuousClock.Instant); case frozen(durMs: UInt64) }`. `elapsedDurMs(at:)`
  switches over it (frozen returns its value); add `var isTicking: Bool`.
- **`HomeRow.compose`** signature becomes
  `compose(clips:recorder:RecorderTruth, previousLive:LiveSegment?, now:)`.
  Rules:
  - `.unknown`, or no `currentSegment` -> no live row.
  - `.live` + segment: existing ticking/seed/max logic. Thaw: a *frozen*
    previousLive with matching identity re-seeds
    `.ticking(seedDurMs: max(durMs ?? 0, frozenValue), anchor: now)`. Careful:
    the existing keep-previous branch (same identity, `durMs == nil`) is correct
    only for a *ticking* previous; a frozen previous with nil `durMs` must still
    thaw to `.ticking(seedDurMs: frozenValue, anchor: now)`. (Snapshot contract
    carries `current_segment.dur_ms` -- verified in `contract/events/snapshot.json`
    -- so the max-seed path has wire support.)
  - `.lastKnown` + segment: frozen row. Matching previousLive -> freeze at
    `previousLive.elapsedDurMs(at: now)` (one line -- frozen previous returns its
    own value, so freeze-once and stay-frozen collapse). No matching previousLive
    -> freeze at `currentSegment.durMs ?? 0`.
  - Identity (`HomeRowID.live(session:id:)`) unchanged, so freeze/thaw is a
    reconfigure-in-place, never a delete/insert flash. `HomeRowDiff` and the
    diffable cell provider need no changes -- the `Elapsed` change flows through
    `HomeRow` equality into `reconfiguredIDs`.
- **Observation**: replace `recorderObservation = store.observe(\.link.world?.recorder)`
  with `store.observe(select: { $0.link.recorderTruth })`; VC field becomes
  `private var recorderTruth: RecorderTruth = .unknown`. No extra link hook in
  `renderRows`: the offline transition changes the selected value, which recomposes
  and reconfigures. `viewWillAppear` while already offline needs nothing
  (observations persist across disappear; timer logic below finds no ticking row).
- **Timer**: `updateLiveTickTimer` runs iff
  `rows.contains { $0.liveSegment?.isTicking == true }`; `updateVisibleLiveElapsed`
  guards `segment.isTicking`.
- **`LiveClipCell.configure`**: cells are reused, so set the badge in BOTH
  branches every time. Ticking: existing red REC treatment. Frozen:
  `recBadge.configure(caption: "REC", dotColor: .systemGray, backgroundStyle:
  .tinted(UIColor.systemGray.withAlphaComponent(0.14)))` (StatusPillView's existing
  API suffices), elapsed text `Formatters.approximateDuration(frozenMs)`,
  accessibility label "seg_00024.ts, last known recording, ~01:47".
- **`app/DanCam/DanCam/Support/Formatters.swift`**: add
  `approximateDuration(_ durMs: UInt64) -> String` = `"~" + minutesSeconds` (the
  private helper `Formatters#minutesSeconds` already exists; "~" is ASCII).

Tests:
- `DanCamTests/Features/Home/HomeRowTests.swift`: migrate the five existing tests
  to wrap recorder in `.live(...)`; add: freeze-from-ticking at elapsed-at-now;
  frozen stays frozen across repeated `.lastKnown` composes; freeze with no
  previousLive at `durMs ?? 0`; thaw-with-durMs seeds `max(durMs, frozen)` anchor
  now; thaw-without-durMs seeds frozen value anchor now; `.unknown` and
  `.lastKnown`-without-segment produce no live row.
- `DanCamTests/Support/FormattersTests.swift`: `approximateDuration`.
- **Required** VC end-to-end (`HomeViewControllerTests.swift`, existing
  `makeControllerAndStore` harness + `*ForTesting` hook pattern) -- the pure
  compose/formatter tests cannot catch a visible cell left ticking, red, or
  unreconfigured. Access control: `LiveClipCell` is currently `private`, which
  an internal hook cannot return and the test target cannot name -- make it
  internal (drop `private`; precedent: `ClipThumbnailCell` is internal and
  returned by `HomeViewController#clipThumbnailCellForTesting`, and this file
  already holds the internal test-consumed types `LiveSegment`/`HomeRow`).
  Testing accessors read real presentation, never a parallel flag:
  `LiveClipCell#elapsedTextForTesting` (`elapsedLabel.text`),
  `LiveClipCell#recBadgeForTesting` (returns `recBadge`), and a new
  `StatusPillView#dotColorForTesting` (`dotView.isHidden ? nil :
  dotView.backgroundColor` -- the actual rendered dot, so a cell left red
  fails the assertion regardless of which configure branch ran). Hooks on
  `HomeViewController`: `liveClipCellForTesting() -> LiveClipCell?` (resolves
  the `.live` row's index path via `dataSource`, like
  `clipThumbnailCellForTesting`), `isLiveTickTimerRunningForTesting`,
  `isRecPillVisibleForTesting` (new: `!recPill.isHidden`, since `renderRecording`
  hiding the preview REC pill for `.unknown` has no test today), and
  `tickLiveElapsedForTesting()` (invokes the same path the 1 Hz timer calls,
  so the test never sleeps). Determinism prerequisite -- park the reconnect
  backoff: give `makeControllerAndStore` a parked `sleep`
  (`sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }`), mirroring the
  harness's existing inert `heartbeatTimeout: { throw CancellationError() }`.
  Otherwise the harness runs the real `sleep` default with `EventsClient.noop`,
  so Act 2's `.heartbeatTimedOut` schedules `scheduleReconnect(attempt: 1)` (a
  1 s delay), which fires `.streamReconnect` -- no offline guard, unlike
  `.reconnectStreamIfOffline`, so it restarts the stream unconditionally; the
  noop stream finishes instantly -> `.streamFailed` -> `wentOffline()`. Nothing
  cancels `events-reconnect` on `.event` (only `.streamStarted`/`.streamStopped`
  do), so the reconnect scheduled before Act 3's snapshot still fires after it
  and re-freezes the row, hides the pill, and disables the button, then cycles
  every 1-4 s -- putting a hard ~1 s wall-clock deadline on the span from Act 2's
  send through Act 3's final assertion (each `waitUntil` can legitimately burn up
  to 2 s on a loaded CI simulator, so the test as specified is a flake bomb). A
  parked `sleep` never elapses the backoff, `.streamReconnect` never fires, and
  the three acts have no deadline; applied harness-wide it also quiets the
  perpetual 1 s reconnect churn in every offline-touching VC test. (This is a
  test-harness artifact, not an app bug: in production `.online` is only reached
  via a live stream, so no reconnect ever dangles past a snapshot -- the test
  creates the impossible state by injecting `.event` directly.) The test runs
  three acts against one held cell reference so it covers freeze *and* thaw (a
  cell left gray/frozen after
  reconnect is exactly as invisible to compose tests as one left ticking) and
  so its negative assertions can't pass vacuously:
  - **Act 1 (online, before freeze):** seed an online recording world with a
    current segment, `waitUntil` (the file's existing helper,
    `HomeViewControllerTests.swift#waitUntil`) the live cell is present, hold the
    reference, and assert the ticking baseline is real -- dot `.systemRed`,
    ticking (non-`~`) elapsed text, `isLiveTickTimerRunningForTesting == true`
    (so Act 2's "timer stopped" assertion is non-vacuous),
    `isRecPillVisibleForTesting == true`, and `recordButtonForTesting` offers a
    Stop (enabled).
  - **Act 2 (freeze on `.heartbeatTimedOut`):** send `.heartbeatTimedOut`;
    `waitUntil` the held cell shows the frozen presentation (dot `.systemGray`,
    `~`-prefixed elapsed text) -- `renderRows` applies the diffable snapshot with
    `animatingDifferences: canAnimateTableUpdates`, so the reconfigure is not
    guaranteed to have landed when `store.send` returns; only then assert
    `liveClipCellForTesting()` is the SAME instance as the held reference (`===`,
    matching the existing `#expect(updatedImageA === originalA)` style -- proves
    the freeze is a reconfigure-in-place, not a delete/insert), the "last known
    recording" accessibility label, `isLiveTickTimerRunningForTesting == false`,
    `tickLiveElapsedForTesting()` leaving the elapsed label unchanged, and the
    other two reported symptoms gone at the view level:
    `isRecPillVisibleForTesting == false` and
    `recordButtonForTesting.isEnabled == false`.
  - **Act 3 (thaw on reconnect snapshot):** send
    `.event(.snapshot(sameRecordingWorld))`; `waitUntil` the held cell shows the
    red dot and non-`~` elapsed text again; then assert it is still the SAME
    instance (`===`, proves thaw is also reconfigure-in-place, not a
    delete/insert flash), `isLiveTickTimerRunningForTesting == true`,
    `isRecPillVisibleForTesting == true`, and `recordButtonForTesting` offers a
    Stop again -- this drives step 3's `onlineWorld` re-derivation end-to-end at
    the view level and guards the symmetric "cell left frozen / badge not reset in
    the ticking branch" failure that nothing else catches.

### Step 5 -- ADR 18

`app/docs/design/18-2026-07-08-heartbeat-fresh-present-tense.md` (17 is current
max). House shape (see ADR 17 for the template): Title / Status Accepted / Context
/ Decision / Consequences / Alternatives considered. Related: ADR 10 (heartbeat as
connection truth), ADR 17 (derived view-state), ADR 06. Decision: present-tense UI
claims require heartbeat-fresh state; stale state is typed
(`RecorderTruth.lastKnown`, `LiveSegment.Elapsed.frozen`,
`RecordingFeature.State.unknown`), never erased. Alternatives: remove the live row
when offline (discards true information, flaps on 2.4 GHz blips); keep ticking with
a stale label (extends an unverifiable present-tense claim). Record the scope cuts
below under Consequences. Validate with `just adr-check`.

## Scope cuts (deliberate, documented in ADR 18)

- `HomeStatusPills.from($0.link.world)`: stale temp/camera-offline/time pills
  persist while offline. Static claims (no count-up) under the "Not connected"
  strip; ADR 10 blesses last-known detail. Follow-up candidate:
  `HomeStatusPills.from(Link)`.
- `HealthTelemetry.rows(for: $0.link.world)`: debug screen; last-known telemetry is
  desirable there and its own `/v1/health` fetch already reports unreachability.
- `.streamStopped` (backgrounding) does not take the link offline: after
  foregrounding, a brief stale-`.online` window exists until the next snapshot or
  heartbeat timeout. Pre-existing, short, self-correcting.
- Preview, connection strip, ClipsFeature (past-tense rows): already honest or out
  of scope.

## Verification

- `just app-test` (LinkTests, RecordingFeatureTests, AppFeatureTests, HomeRowTests,
  FormattersTests, HomeViewControllerTests), `just app-lint`,
  `just adr-check`.
- Manual against the mock Pi (`just raspi-mock`, app run with
  `DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080` per `app/AGENTS.md#Build / run`;
  mock boots already-recording with 5 s segment rolls, 2 s heartbeats):
  - **Stream-failure path (the reported bug):** Ctrl-C the mock. Expect: strip
    "Not connected", live row goes gray `~mm:ss` and stops counting, REC pill
    hides, record button disabled.
  - **Heartbeat + reconnect path:** `kill -STOP $(pgrep -f target/debug/dancam)`
    (stream stays open, heartbeats stop) -> same UI after ~6 s. Then `kill -CONT`:
    app reconnects, snapshot arrives with same session and phase `.recording` --
    exercises the step 3 regression: row thaws re-seeded from snapshot `dur_ms`,
    REC pill returns, button offers "Stop".
  - **Restart path:** rerun `just raspi-mock` after Ctrl-C: new session in
    snapshot replaces the frozen row with a fresh ticking row; clips reload.
  - Watch `just app-logs` for `action=heartbeatTimedOut ... recording=recording ->
    unknown` and `action=event.snapshot ... recording=unknown -> recording`.

## Commit progress

- [x] 1. Add heartbeat-fresh recorder truth and offline folds
- [ ] 2. Freeze and thaw the Home live recording row
