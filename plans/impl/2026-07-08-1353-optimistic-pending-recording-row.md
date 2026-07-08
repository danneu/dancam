# Plan: Optimistic pending row in Recent clips on Record tap

## Context

Tapping Record flips `RecordingFeature.State` to `.starting` instantly (button shows
disabled "Starting"), but the live REC row in the Recent clips list only appears
~5 seconds later, when the Pi's `segment_opened` SSE event sets
`World.recorder.currentSegment` -- that is the only thing `HomeRow.compose` keys the
live row on. The user watches an unchanged list for the whole start window.

Fix: insert an optimistic "pending" row at index 0 the moment a start is underway.
It looks identical to the live REC row (same `LiveClipCell`: red REC badge, static
"00:00") except the title reads "Starting..." instead of `seg_NNNNN.ts`. When
`segment_opened` arrives it is replaced by the real live row.

Decisions taken with Dan:
- Pending row looks identical to the live row (no dimmed/tentative variant).
- On failed start it silently disappears (matches today's quiet failure surface:
  button flips back to "Record").
- Purely derived state -- no new stored state, no watchdog timer. The row is a pure
  function of `(RecordingFeature.State, RecorderTruth)` -- online/offline is already
  encoded in `RecorderTruth` (`.live` == online), so there is no separate link-online
  input. Every
  realistic path is bounded: HTTP failure resolves via transport timeouts (<= ~10s),
  connection loss trips the 6s heartbeat and the row hides while offline, and
  Pi-reported failures (`recorder_failed`) clear it immediately. In the exotic
  Pi-wedge case (claims recording, never opens a segment, heartbeats flowing) a
  persistent "Starting..." row is the honest display and Stop still works.

## The pending condition

The row is derived from `(RecordingFeature.State, RecorderTruth)`. `RecorderTruth`
(`app/DanCam/DanCam/Features/Connection/Link.swift#RecorderTruth`) is the online/offline
gate: `.live(RecorderSnapshot)` == online, `.lastKnown(RecorderSnapshot)` == offline
with a last world, `.unknown` == connecting / offline-with-nothing. Only `.live` can
show a pending row -- `.lastKnown` and `.unknown` suppress it, which is exactly the
old "hide the unconfirmed row while offline" gate, now for free.

Show the pending row iff:

```
case .live(let snapshot) = recorderTruth        // online gate (both arms live under this)
  && snapshot.currentSegment == nil             // no real live row yet
  && (recording is .starting or .recording      // command arm
      || snapshot.phase is .starting or .recording)  // world arm
```

Both arms live under the `.live` + nil-segment guard: with `.lastKnown` / `.unknown`
the guard fails and no pending row is derived regardless of the command state (so a
command that momentarily reads `.starting`/`.recording` while offline cannot leak a
pending row -- and in practice `.linkWentOffline` resets the command to `.unknown`
anyway).

Why both arms:
- Command `.starting` covers the instant-on-tap window (world still `.idle`). At tap
  time the link is online, so `recorderTruth` is `.live(snapshot)` with a nil segment
  and phase `.idle` -- the guard passes and the command arm fires.
- Command `.recording` covers HTTP-200-landing-before-`recording_starting`-folds
  ordering (no flicker between the two).
- World `.starting` / `.recording`-with-nil-segment covers the authoritative gap
  (`recording_starting`/`recording_started` fold before `segment_opened`) after the
  command state reconciles, plus the non-optimistic case where the app connects and
  the snapshot shows a start already in flight. This deliberately changes one
  existing behavior: `.live` + phase `.recording` + nil segment used to render no row;
  it now renders a pending row (more honest).

Pending and the frozen stale live row are mutually exclusive. When `.lastKnown`
carries a `currentSegment`, `compose` seeds a `.frozen` live row (commit `686ea8b`)
and returns before the pending check; when `.lastKnown` has a nil segment, no live row
is seeded and the pending check is skipped because the guard requires `.live`. So a
frozen live row (offline) and a pending row (online, unconfirmed) can never appear
together -- they are keyed to disjoint `RecorderTruth` cases.

Verified flicker-free: `AppFeature.reduce` folds the event and reconciles
`recorderPhaseObserved` synchronously in the same reduce pass, so e.g.
`recording_stopped` lands world `.idle` + command `.idle` atomically before
observers fire.

## Changes

### 1. `app/DanCam/DanCam/Features/App/AppFeature.swift#reduce` -- snapshot always reconciles

Separable robustness fix (own commit); narrower than the original plan framed it.

The original motivating bug -- command stuck at `.recording` after an *offline*
window -- is already closed on `master`. `previousPhase` now reads
`state.link.onlineWorld?.recorder.phase` (`AppFeature.swift#reduce`, `.event` case),
and `onlineWorld` returns nil while offline. So on any reconnect snapshot the
pre-fold `previousPhase` is `nil`, and `nil != phase` already forces
`recorderPhaseObserved` even when the reported phase equals the pre-drop phase. This
is covered by the existing `AppFeatureTests#offlineThenSamePhaseSnapshotRederivesRecording`.

The residual gap is an *online* re-snapshot with an unchanged phase. `SceneDelegate`'s
`sceneWillEnterForeground` sends `.streamStarted` unconditionally, and `.streamStopped`
(sent on background) does not change `state.link`; so if the app was backgrounded while
`.online`, the link stays `.online(world)`, the reopened stream folds its first
snapshot with `onlineWorld` non-nil, and `previousPhase` is the pre-background online
phase. If the command drifted meanwhile (e.g. a backgrounded HTTP-200 moved the command
to `.recording`) but that phase is byte-identical across the foreground boundary, the
`phase != previousPhase` guard skips reconciliation and the command stays drifted --
a lingering "Starting..." pending row (and stuck "Stop" button) with no watchdog to
clear it. Narrow, but the pending row is exactly what makes it visible.

Fix in the `.event` case: dispatch `recorderPhaseObserved` when the event is a
snapshot, even if the phase is unchanged. The `.snapshot` branch already exists (it
resets `streamReconnectAttempt` and loads clips), so hoist the flag there:

```swift
let previousPhase = state.link.onlineWorld?.recorder.phase
var isSnapshot = false
...
state.link.fold(event)

if case .snapshot = event {
    isSnapshot = true
    state.streamReconnectAttempt = 0
    // ...existing clip-load + time-sync effects...
}
...
if let phase = state.link.onlineWorld?.recorder.phase,
   isSnapshot || phase != previousPhase {
    effects.append(reduceRecording(state: &state, action: .recorderPhaseObserved(phase), ...))
}
```

Re-projection semantics (broader than an "idempotent except `.error`" note would
suggest): for the `.unknown / .idle / .recording / .failed` command states,
`RecordingFeature.reduce`'s `.recorderPhaseObserved` maps the observed phase 1:1 onto
the command, so forcing a reconcile on every snapshot intentionally re-projects a
*drifted* command from the authoritative Pi phase -- not merely `.error` ->
`.failed("Recorder failed")`. Concretely, a command stuck at `.failed("HTTP 503")` (a
client-side start failure) is cleared to `.idle` by an unchanged online `.idle`
snapshot. That is the desired behavior: the Pi is the source of truth, an idle
snapshot means the failed start left the recorder idle, and the user should be free to
retry -- a stale client-side error must not outlive the authoritative world. The one
deliberately protected transition is `.starting` + observed `.idle`, which
`RecordingFeature.reduce` keeps as `.starting`, so an in-flight start is never cleared
by a stale pre-start snapshot.

### 2. `app/DanCam/DanCam/Features/Home/HomeRowDiff.swift#HomeRowID` -- new identity

Add `case pending` (no associated value). `HomeRowDiff.reconfiguredIDs` needs no
change: `.pending` never differs from itself, and pending -> live is a delete+insert
at index 0, same as today's segment-rollover transition.

### 3. `app/DanCam/DanCam/Features/Home/HomeViewController.swift#HomeRow` -- case + compose

- Add `case pending` to `HomeRow`; add a `.pending` arm to `id` mapping it to
  `HomeRowID.pending`. `liveSegment` / `finishedIdentity` already return nil via
  `if case` patterns, so `.pending` falls through them unchanged.
- New pure helper next to `compose`. Both arms live under a single `.live` +
  nil-segment guard, so `.lastKnown` / `.unknown` return false without an explicit
  online flag:

```swift
static func shouldShowPendingRow(
    recording: RecordingFeature.State,
    recorder: RecorderTruth
) -> Bool {
    guard case .live(let snapshot) = recorder,
          snapshot.currentSegment == nil else { return false }
    let commandWantsRecording = recording == .starting || recording == .recording
    let worldStartGap = snapshot.phase == .starting || snapshot.phase == .recording
    return commandWantsRecording || worldStartGap
}
```

- `compose` gains a `recording: RecordingFeature.State` parameter (no default --
  force every call site to decide). It keeps the current `recorder: RecorderTruth`
  parameter; there is no `isLinkOnline` parameter (online-ness is in `RecorderTruth`).
  `compose` already resolves `recorder` through a `switch` into an optional
  `live: LiveSegment?`, then `guard let live else { return rows }`. Re-target the
  `.pending` insertion to that final `guard let live else` path:

```swift
guard let live else {
    if shouldShowPendingRow(recording: recording, recorder: recorder) {
        rows.insert(.pending, at: 0)
    }
    return rows
}
rows.insert(.live(live), at: 0)   // existing
return rows
```

  This keeps pending and live mutually exclusive by construction: `shouldShowPendingRow`
  only returns true for `.live` + nil segment, and every `.live` + non-nil-segment path
  produces a non-nil `live` and returns before the pending check.

### 4. `HomeViewController` wiring

The recorder observation is already `store.observe(select: { $0.link.recorderTruth })`
and stores `recorderTruth: RecorderTruth`, and `renderRows()` already runs off it and
already passes `recorder: recorderTruth` into `compose`. So the only new inputs the
pending row needs are the command `recording` state (already stored as
`recordingState`) and a re-render when it changes. No new stored input, no combined
selector, no `HomeRecorderContext` struct.

- Recording observation (already stores `recordingState` and calls
  `renderRecording`): add `self?.renderRows()` so a command-state change re-derives
  the pending row.
- `renderRows(now:)`: add `recording: recordingState` to the `HomeRow.compose(...)`
  call. `recorder: recorderTruth` and `previousLive` handling stay as-is.
- Cell provider in `configureClipsTable`: `case .pending` dequeues the existing
  "liveClip" `LiveClipCell` and calls `configurePending()`.
- `didSelectRowAt`: fold `.pending` into the `.live` early return (`case .live, .pending:`).
  Swipe-delete, pagination, prefetch, and thumbnail paths all pattern-match `.finished` /
  `finishedIdentity`, so `.pending` is excluded without edits (compiler-checked via
  exhaustive switches where present).
- Timer: no change needed -- `updateLiveTickTimer` gates on `liveSegment?.isTicking`,
  which is nil for `.pending`, so the pending row never starts the 1s tick.
  `updateClipsPresentation` also needs no change (pending row makes
  `rows.isEmpty == false`, hiding the placeholder, same as the live row).
- Test hooks in the existing `...ForTesting` block:
  `isShowingPendingRowForTesting` (`dataSource.indexPath(for: .pending) != nil`) and
  `pendingCellForTesting`. `isLiveTickTimerRunningForTesting` already exists.

### 5. `LiveClipCell` (private, bottom of HomeViewController.swift)

`configurePending()` must reset every field the per-segment `configure(segment:now:)`
sets, because the "liveClip" reuse pool can hand back a cell last used for a *frozen*
offline live row, and that path tints `recBadge` gray (`.systemGray`) instead of red.
The pending row must "look identical to the live REC row", so it has to force the red
badge back explicitly -- the same red/tinted treatment as `configure`'s `.ticking`
arm. Labels and a11y alone are not enough.

```swift
func configurePending() {
    titleLabel.text = "Starting..."                     // ASCII ellipsis, matches "Loading health..."
    elapsedLabel.text = Formatters.countUpDuration(0)   // "00:00", same path as live
    recBadge.configure(                                 // force red; a reused frozen cell left it gray
        caption: "REC",
        dotColor: .systemRed,
        backgroundStyle: .tinted(UIColor.systemRed.withAlphaComponent(0.14))
    )
    accessibilityLabel = "Starting recording"           // matches RecordButtonStyle .starting a11y
}
```

## Tests (Swift Testing; run with `just app-test`)

Every `HomeRowTests` compose call site already passes a `RecorderTruth`
(`.live(...)` / `.lastKnown(...)` / `.unknown`); the only new argument is
`recording: RecordingFeature.State`. Existing seeding tests are unaffected by pending
(their `RecorderTruth` has a `currentSegment`, so the `.live`+nil-segment guard fails)
-- pass `recording: .idle` at those sites.

One existing expectation flips by design:
`HomeRowTests#composeShowsLiveRowOnlyWhenRecorderTruthHasCurrentSegment` has a
`.live(recorder(currentSegment: nil))` block that expects `[.finished(clip)]`. The
test helper `recorder(...)` defaults `phase: .recording`, so under the new condition
that input is `.live` + nil segment + phase `.recording` -> it now yields
`[.pending, .finished(clip)]`. Rewrite that block. Its `.unknown` block and its
`.lastKnown(recorder(currentSegment: nil))` block both still assert `[.finished(clip)]`
(both suppress pending), so keep them.

`app/DanCam/DanCamTests/Features/Home/HomeRowTests.swift` (pure compose; express all
inputs as `RecorderTruth`, using the existing `recorder(phase:currentSegment:)` helper
to set an explicit phase):
- `composeShowsPendingRowWhileCommandStartsBeforeWorldReacts` -- `recording: .starting`,
  `.live(recorder(phase: .idle, currentSegment: nil))` -> `[.pending, .finished]`.
- `composeShowsPendingRowWhenStartSucceedsBeforeEventsFold` -- `recording: .recording`,
  `.live(recorder(phase: .idle, currentSegment: nil))` -> pending first.
- `composeShowsPendingRowForWorldStartGapWithoutLocalCommand` -- `recording: .idle` +
  `.live(recorder(phase: .starting, currentSegment: nil))`, and command `.unknown` +
  `.live(recorder(phase: .recording, currentSegment: nil))` -> pending. (Command
  `.unknown` is `RecordingFeature.State.unknown`, distinct from `RecorderTruth.unknown`.)
- `composeHidesPendingRowWhenOffline` -- `recording: .starting` +
  `.lastKnown(recorder(phase: .recording, currentSegment: nil))` -> no pending; same
  command + `.unknown` -> no pending; and `.lastKnown` with a set `currentSegment`
  still yields a `.frozen` `.live` row (offline live row ungated).
- `composeHidesPendingRowOnFailedStart` -- `recording: .failed("...")` +
  `.live(recorder(phase: .idle, currentSegment: nil))`, and + `.live(recorder(phase:
  .error, currentSegment: nil))` -> no pending.
- `composeHidesPendingRowDuringStopFlow` -- `recording: .stopping` +
  `.live(recorder(phase: .stopping, currentSegment: nil))`, and `recording: .idle` +
  `.live(recorder(phase: .idle, currentSegment: nil))` -> no pending.
- `composeNeverShowsPendingAndLiveTogether` -- `recording: .starting` +
  `.live(recorder(phase: .recording, currentSegment: RecorderSegment(id: 7, durMs: ...)))`
  -> first row `.live`, no `.pending` anywhere.
- (Dropped: the old `composeShowsPendingRowFromCommandEvenWithoutWorld` case --
  "recorder nil + online" is now unrepresentable, since `.live` always carries a
  `RecorderSnapshot`. The command-only, world-not-yet-reacted case it covered is
  `.live(recorder(phase: .idle, currentSegment: nil))` + `recording: .starting`,
  already tested by `composeShowsPendingRowWhileCommandStartsBeforeWorldReacts`.)

`app/DanCam/DanCamTests/Features/Home/HomeRowDiffTests.swift`:
- `pendingRowHasDistinctStableIdentity` -- ids distinct;
  `reconfiguredIDs(old: [.pending], new: [.pending]) == []`.
- `pendingToLiveTransitionIsInsertRemoveNotReconfigure`.

`app/DanCam/DanCamTests/Features/App/AppFeatureTests.swift`:
- `onlineResnapshotReconcilesStaleRecordingWhenPhaseUnchanged` -- exercises the
  *online* re-snapshot path (the offline path is already covered by the existing
  `offlineThenSamePhaseSnapshotRederivesRecording`). Seed
  `state(link: .online(world(phase: .idle)), recording: .recording)` -- command
  drifted while the online world reads `.idle`. Send
  `.event(.snapshot(world(phase: .idle)))` (link stays online, phase byte-identical).
  Without the `isSnapshot` fix, `previousPhase == .idle == phase` -> no reconcile ->
  `recording` stuck `.recording`; with the fix -> `recording == .idle`. This is the
  test that actually guards Change #1 (the `.offline(last:)` framing would pass on
  `master` unchanged, since `onlineWorld` is nil offline).
- `onlineResnapshotClearsStaleFailedCommandFromIdlePhase` -- guards the re-projection
  semantics from Change #1. Seed `state(link: .online(world(phase: .idle)),
  recording: .failed("HTTP 503"))` (a drifted client-side failure over an idle world),
  send `.event(.snapshot(world(phase: .idle)))` (phase byte-identical). Without the
  `isSnapshot` fix the stale `.failed(...)` command survives; with it, reconcile
  re-projects the command to `.idle` (`RecordingFeature.reduce` maps observed `.idle`
  -> `.idle` for `.failed`), clearing the stale error.

`app/DanCam/DanCamTests/Features/Home/HomeViewControllerTests.swift` (thread a
recording client into `makeControllerAndStore`'s `AppDependencies`). Seed the
enabled-online start path explicitly: `makeControllerAndStore` defaults to
`world: nil` + `recording: .unknown`, which is offline (`recorderTruth` never `.live`,
so the `.live` guard can never pass) and a disabled Record button -- a pending row
could not appear regardless of the code under test. Every pending-row controller test
must pass `world: CameraSamples.world(phase: .idle, currentSegment: nil)` (sets
`state.link = .online(world)` -> `.live` with a nil segment) and `recording: .idle`
before sending `.recordTapped`.
- `tappingRecordShowsPendingRowImmediatelyWithoutTickTimer` -- parked start client
  (sleeps), `.recordTapped` -> pending shown, a11y label "Starting recording", REC
  badge red (`pendingCellForTesting.recBadgeForTesting.dotColorForTesting` matches
  `.systemRed` via the existing `colorMatches` helper -- an end-to-end smoke of the
  wired path only, NOT the reset guard: a freshly dequeued cell starts red from
  `configureViews`, so this passes even if `configurePending()` omits the reset. The
  deterministic guard is the direct-cell test below), tick timer not running.
- `segmentOpenedReplacesPendingWithLiveRow` -- then `segment_opened` -> pending
  gone, live present, never both.
- `failedStartRemovesPendingRowSilently` -- start client throws -> pending
  disappears, no live row, no failure banner in the list.
- `recorderFailedEventClearsPendingViaProjection` -- the end-to-end guard that the
  Pi's *own* failure event clears the optimistic row, distinct from the local-throw
  path above and from the pure-`HomeRow` `composeHidesPendingRowOnFailedStart` (neither
  drives a real event through `AppFeature.reduce`, so a regression in the event
  projection would go uncaught). Show pending, then
  `store.send(.event(.recorderFailed(session: 7, detail: "sensor lost", atMs: 1)))`.
  Assert pending hidden (`isShowingPendingRowForTesting == false`), no live row, and
  the Record button back to its retryable state (`recordButtonForTesting.isEnabled ==
  true` -- `RecordButtonStyle` maps `.failed` to the same enabled "Record" as `.idle`).
  This guards the whole chain: `recorderFailed` folds world phase to `.error` with a
  nil segment, which forces `.recorderPhaseObserved(.error)` -> `RecordingFeature`
  command `.failed`, failing both the command arm and the world arm.
- `heartbeatTimeoutHidesPendingRow` -- pending shown, `.heartbeatTimedOut` ->
  hidden. (Double-suppressed: `.linkWentOffline` resets the command to `.unknown` and
  the link flips to `.offline` -> `recorderTruth` becomes `.lastKnown` / `.unknown`,
  either of which fails the `.live` guard.)
- `configurePendingResetsGrayFrozenBadgeToRed` -- the deterministic guard for the
  Change #5 badge reset, a direct `LiveClipCell` unit test with no table or store
  (`LiveClipCell` is internal, reachable via `@testable import DanCam`). Instantiate a
  cell, `configure(segment:now:)` it with a *frozen* `LiveSegment`
  (`LiveSegment(sessionId:id:elapsed: .frozen(durMs:))`) and assert
  `recBadgeForTesting.dotColorForTesting` matches `.systemGray`; then call
  `configurePending()` and assert the badge is back to `.systemRed` and
  `elapsedTextForTesting == "00:00"`. This exercises the reused-frozen-cell transition
  the wired `tappingRecord...` smoke cannot -- a red-only cell would fail the gray
  precondition, and a missing reset would fail the red postcondition.

## Verification

1. `just app-test`, then `just app-build`.
2. Mock Pi: `just raspi-mock`, run the app in the simulator with
   `DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080`. Note the mock opens the
   segment almost immediately, so the pending row is only a brief flash -- verify
   clean replacement (no duplicate row, no reorder glitch). Failure path: Ctrl-C
   the mock, tap Record within ~6s -> pending appears, then silently disappears.
3. Real Pi (the real ~5s window): tap Record -> "Starting..." row appears
   instantly, persists through the start window, becomes `seg_NNNNN.ts` live row on
   `segment_opened`. Mid-window, toggle iPhone Wi-Fi off -> row hides when the 6s
   heartbeat marks offline; Wi-Fi back on -> reconnect snapshot resolves truth.

## Notes / risks

- The `AppFeature` snapshot-reconcile change (Change #1) is the only non-Home edit; it
  closes the residual *online* re-snapshot reconciliation gap the pending row would
  otherwise expose (a lingering "Starting..." row / stuck "Stop" button after a
  foreground-while-online race). The original *offline*-window motivation is already
  closed on `master` by the `onlineWorld` refactor. Should be its own commit; it is
  separable from the Home changes.
- Pending -> live is a diffable delete+insert crossfade at index 0 (same cell
  class, near-identical visuals) -- consistent with segment rollover today.
- Title uses "Starting..." (button says bare "Starting"); trivially adjustable.

## Commit progress

- [x] 1. snapshot reprojects recording state on online re-snapshot
- [ ] 2. show optimistic pending row in Recent clips
