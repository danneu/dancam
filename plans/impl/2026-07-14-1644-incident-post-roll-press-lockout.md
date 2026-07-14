# Incident button: post-roll lockout and single presentation state machine

## Context

Field testing (2026-07-14) surfaced a duplicate-incident bug: pressing "Save
Incident" disables the button and shows "Saving...", but after the fixed 3 s
press cooldown the button re-enables while its title still reads "Saving..."
-- enablement comes from `IncidentsFeature.State#canPress` (cooldown +
in-flight create) while the title comes from `pendingIncidentCount > 0` (true
for the whole pending lifetime). Dan read the enabled "Saving..." button as a
stuck disabled state, tapped again, and minted a duplicate incident.

Two defects:

1. **Presentation contradiction.** `IncidentButtonPresentation` computes
   `isEnabled` and `isShowingFeedback` from independent predicates that can
   disagree; an enabled control labeled "Saving..." invites the duplicate tap.
2. **Wrong lockout window.** The 3 s cooldown is unrelated to the incident's
   15 s post-roll (+2 s slack). A second press inside the post-roll window
   duplicates footage already being captured.

Decided product behavior (a recorded pivot from the implemented plan's "press
cooldown, not a lockout" call; all four choices confirmed with Dan):

- Press -> button disabled with a live countdown ("Saving... 12s") until the
  post-roll window closes. A press creates an in-memory monotonic deadline at
  `continuousNow + pressLockoutSpan` (~17 s); `pressedAtMs` remains the durable
  wall-clock fact used to reconstruct the remaining monotonic duration once
  after relaunch. This **fully replaces** the 3 s cooldown --
  `isPressFeedbackVisible` / `.cooldownFinished` are deleted.
- After the deadline the button returns to enabled "Save Incident" even while
  segment pulls continue; the Incidents tab badge
  (`App/AppShellViewController.swift`, `pendingIncidentCount`) is the sole
  Home-side signal for in-flight transfers. No extra status line.
- Countdown is **view-driven**: presentation carries the deadline; the button
  ticks itself with a 1 s Timer (mirroring `Views/LiveRecordingStatusView.swift`).
  No reducer timer or wake-up effect: the view flips itself at expiry and the
  reducer independently re-checks the same runtime monotonic deadline on tap.
- Coverage-gap-free: the ~17 s lockout is shorter than the 30 s pre-roll
  (+2 s slack), so the earliest re-press's pre-roll always reaches past the
  prior incident's window end. No footage can fall between incidents.
- Robust by construction: runtime lockout and create-in-flight gating are
  scoped to the validated current `RecordingID`, and the deadline uses
  `ContinuousClock`, so another recording session and in-process wall-clock
  changes cannot disable or prematurely re-enable the button. On launch, the
  reducer reconstructs the monotonic deadline once from a matching persisted
  record whose fixed wall-clock window is active at that moment. Capture stays
  `.unavailable` until the incident store has loaded, so a cold-launch
  recording snapshot cannot arm the button before a just-pressed record is
  read back from disk.
- Bookkeeping: record the new decision in app ADR 27 and point the historical
  implementation plan at it; ADR 26 remains the accepted phone-ownership ADR.

## Design

### Presentation enum (replaces the two-bool struct)

`app/DanCam/DanCam/Features/Home/IncidentButton.swift#IncidentButtonPresentation`:

```swift
nonisolated enum IncidentButtonPresentation: Equatable, Sendable {
    case unavailable  // offline / not recording / no anchor / store not loaded
    // enabled iff the runtime deadline has passed AND createInFlight == false
    case armed(lockoutDeadline: ContinuousClock.Instant?, createInFlight: Bool)

    static func from(
        _ state: AppFeature.State,
        now: ContinuousClock.Instant
    ) -> Self {
        guard let recordingID = state.incidents.captureRecordingID(
            world: state.link.onlineWorld
        )
        else { return .unavailable }
        return .armed(
            lockoutDeadline: state.incidents.activeLockout(
                for: recordingID,
                now: now
            ),
            createInFlight: state.incidents.pendingRecords[recordingID] != nil
        )
    }
}
```

The `.armed` payload mirrors `canPress` exactly -- `lockoutDeadline` covers the
`activeLockout(for:now:) == nil` term and `createInFlight` covers the
`pendingRecords[recordingID] == nil` term -- so "button enabled" and
"`canPress` true" are the same predicate by construction; there is no state in
which an enabled button rejects its own tap. `activeLockout` takes the already
validated current `RecordingID` and returns a deadline only when the stored
runtime lockout has that same identity and `now < deadline`. Both timed lockout
and create-in-flight gating are therefore scoped to the current recording: a
recent or suspended create from session 7 cannot lock session 8.

`createInFlight` matters only in the rare case where the current recording's
`incidentStore.create` stays suspended past the ~17 s window: the runtime
deadline keeps the button disabled for the first ~17 s, and `createInFlight`
holds it disabled ("Saving...", no countdown) until that recording's
`createResponded` resolves. Creates for other `RecordingID` values continue
independently and do not affect this presentation. A persisted incident whose
transfer is still pending does NOT set `createInFlight` and re-enables normally
(transfers never lock).

`unavailable` is checked first, so it wins over the countdown on link drop.
`HomeViewController`'s observe closure samples
`dependencies.continuousNow()` per state change; the selector runs only when
state changes, never per second, so `observe`'s dedupe does not churn -- the
per-second re-render stays the view's job. The payload needs only the monotonic
deadline: `ContinuousClock` cannot rewind, so once the view observes an expired
deadline it cannot later become active again. The reducer and view use the same
deadline and clock domain, eliminating the rewind/correction disagreement in
the wall-clock design.

### IncidentButton rendering + tick timer

`apply(_ presentation:, now: ContinuousClock.Instant)` -- HomeViewController
passes `dependencies.continuousNow()`. The button stores the presentation, calls
`render(now:)`, then `updateTickTimer()`:

- `.unavailable` -> disabled, "Save Incident", triangle icon, a11y label
  "Save incident", `accessibilityValue = nil`.
- `.armed(deadline, _)` with `deadline.map { now < $0 } == true` -> disabled, title
  `"Saving... \(remaining)s"` where
  `remaining` is the positive `now.duration(to: deadline)` rounded up to whole
  seconds,
  spinner icon (lockout-active wins regardless of `createInFlight`, so the
  countdown shows during the normal press). Accessibility: **static** label
  "Saving incident" + `accessibilityValue = "N seconds remaining"` (ticking
  count in the value, not the label, so VoiceOver does not re-announce every
  second).
- `.armed(deadline, createInFlight: true)` with `now >= deadline` or no deadline ->
  disabled, "Saving..." (no countdown), spinner icon, a11y label "Saving
  incident", `accessibilityValue = nil`. This is the suspended-create edge: the
  window has expired but the create has not resolved, so the button stays
  disabled rather than flip to an inert enabled control.
- `.armed(nil, createInFlight: false)`, or `.armed(deadline, createInFlight:
  false)` with `now >= deadline` -> enabled, "Save Incident", triangle icon,
  a11y label "Save incident", `accessibilityValue = nil`.

Every non-countdown branch clears `accessibilityValue` explicitly so a button
that ticked down and then re-enabled (or dropped to `.unavailable`) does not
leave stale "N seconds remaining" VoiceOver output.

Timer lifecycle mirrors `Views/LiveRecordingStatusView.swift`: a repeating 1 s
timer running only while the presentation is `.armed` with `now < deadline`;
`override didMoveToWindow` re-renders and re-evaluates the timer; `isolated
deinit` stops it. The button receives the same injected `continuousNow` closure
used by `HomeViewController` so production and deterministic tests stay in one
clock domain. Unlike the mirrored view,
construct the timer explicitly and add it to `RunLoop.main` in `.common` mode
(`RunLoop.main.add(timer, forMode: .common)`) so a scroll/tracking run-loop
cannot pause the countdown and strand the button disabled past expiry -- the
button's re-enable is behavioral, not cosmetic. Each tick renders with
`continuousNow()` and re-evaluates; the tick that first sees `now >= deadline`
stops the timer and re-runs `render(now:)`, which enables the button only when
`createInFlight == false`.
If a create is still in flight, the window-inactive render lands on the
disabled "Saving..." branch and the button waits for the next presentation
(delivered by `createResponded`) rather than self-enabling on time alone. Test
hooks: `tickForTesting(now:)`, `isTickTimerRunningForTesting` (same naming as
LiveRecordingStatusView).

The old contradiction becomes unrepresentable: every enabled render is the
`.armed(_, createInFlight: false)` window-inactive branch, whose title is
always "Save Incident" -- exactly the states where `canPress` is true.

### State changes (`Features/Incidents/IncidentsFeature.swift#State`)

- Replace singleton `pendingRecord` with
  `pendingRecords: [RecordingID: IncidentRecord]`. The post-roll guard permits
  at most one create per recording, while the dictionary allows an old
  recording's suspended filesystem create to coexist with a press in a newly
  validated session. `pendingIncidentCount` includes every dictionary value.
- Add a small runtime-only lockout value
  `(recordingID: RecordingID, deadline: ContinuousClock.Instant)`, plus a
  `lockoutResolvedRecordingID: RecordingID?` marker. The marker distinguishes
  "this recording was checked and had no active persisted window" from "the
  store/current recording is not ready yet". It is not persisted.
- New `func captureRecordingID(world: World?) -> RecordingID?` -- the existing
  world/bootTag/anchor guard block extracted from `canPress`, AND
  `hasLoadedStore == true`; it returns the validated identity rather than a
  Bool. Until the incident store finishes loading, the button stays
  `.unavailable` rather than armed. This closes the cold-launch race:
  `.streamStarted`/`.foregrounded` fire together (`App/SceneDelegate.swift`),
  so a `.worldObserved` recording snapshot can establish the anchor before the
  async `.storeLoaded` arrives while a just-pressed record still sits unread on
  disk. If `.storeLoaded(nil)` fails, `hasLoadedStore` stays false and capture
  remains unavailable until a later foreground reload succeeds.
- New `resolveLockoutIfNeeded(world:wallNow:continuousNow:)`, called after
  anchor updates and successful store loads. Once both the store and a
  validated current recording exist, and that `RecordingID` has not already
  been resolved, filter `pendingRecords.values + incidents` to that identity.
  For each matching record, compute the fixed wall-clock window
  `[pressedAt, pressedAt + IncidentRecord.pressLockoutSpan)`, keep only windows
  containing the single sampled `wallNow`, and take the greatest remaining
  duration. Store `continuousNow + remaining` as the runtime deadline (or nil
  if none), then mark that identity resolved. Do not revisit wall time for the
  same recording: later clock rewinds/corrections cannot reactivate or cancel
  the deadline. A genuinely new `RecordingID` gets its own one-time resolution;
  transient disconnects retain the existing resolution and deadline.
- `pressLockoutSpan` is a fixed code constant (the default `postMs + slackMs`,
  ~17 s), NOT read from persisted per-record duration fields. This keeps
  reconstruction bounded and overflow-free even when duration fields are
  corrupt; the persisted durations continue to drive the footage pull window.
  A future/corrupt `pressedAtMs` and a long-past record fail the wall-window
  membership check at reconstruction and produce no runtime deadline.
- New `func activeLockout(for recordingID: RecordingID, now:
  ContinuousClock.Instant) -> ContinuousClock.Instant?` returns the runtime
  deadline only when its identity matches and `now < deadline`. Changed
  `canPress(world:now:)` obtains the validated `RecordingID`, then requires
  `pendingRecords[recordingID] == nil` and no matching active runtime lockout.
  The explicit current-identity lookup covers a create suspended past its
  deadline without allowing another recording's create to block the press.
- `.pressTapped` samples `continuousNow` once for its guard, mark-age math, and
  new runtime deadline; it samples `wallNow` only for persisted `pressedAtMs`.
  Store the new record under its `RecordingID`. Each `createResponded` looks up
  that identity, verifies the incident id, and removes only that entry; success
  appends the record even if recording has since moved on, so concurrent
  cross-session responses are both retained. On persistence failure, clear the
  runtime deadline only if it still belongs to the failed record's
  `RecordingID`, so the user can retry immediately without an old response
  clearing the current session's lockout; on success, retain it through expiry.

### Deletions

- `State.isPressFeedbackVisible`, `Action.cooldownFinished`, `cooldownID`,
  and the 3 s sleep effect inside `.createResponded(success: true)` (the
  auth/nudge/reconcile effect stays).
- `Features/App/AppFeature.swift`: the `isPressFeedbackVisible` field in the
  debug log summary (replace with the lockout deadline or drop) and the
  `.cooldownFinished` case in the action-label mapping.
- Tests: the `IncidentSleepGate` actor in IncidentsFeatureTests.swift (only
  existed to gate the 3 s sleep).

## File-by-file changes

1. `app/DanCam/DanCam/Features/Incidents/IncidentsFeature.swift` -- state
   changes + deletions above.
2. `app/DanCam/DanCam/Features/Incidents/IncidentRecord.swift` -- add the
   `static let pressLockoutSpan: TimeInterval` constant (default `postMs +
   slackMs` = 17 s), co-located with the pre/post/slack defaults so the span
   and the initializer defaults share one source.
3. `app/DanCam/DanCam/Features/App/AppFeature.swift` -- log summary + label map.
4. `app/DanCam/DanCam/Features/Home/IncidentButton.swift` -- enum
   presentation carrying the monotonic deadline, `apply(_:now:)`,
   `render(now:)`, injected `continuousNow`, tick timer + hooks,
   `didMoveToWindow`, `isolated deinit`.
5. `app/DanCam/DanCam/Features/Home/HomeViewController.swift` -- the observe
   selector samples `dependencies.continuousNow()` (instead of the bare
   `IncidentButtonPresentation.from` reference), the apply passes the same
   monotonic clock into `apply(_:now:)`, and the initial placeholder apply in
   `configureViews` becomes `.unavailable`.
6. `app/DanCam/DanCamTests/Features/Incidents/IncidentsFeatureTests.swift`
   and `app/DanCam/DanCamTests/Features/Home/HomeViewControllerTests.swift`
   -- test plan below. Extend `makeControllerAndStore` to feed deterministic
   `continuousNow` and `wallNow` closures into `AppDependencies`; the button
   receives the dependency's monotonic closure through the controller.
7. `app/docs/design/27-2026-07-14-incident-post-roll-press-lockout.md` -- new
   ADR for the post-roll lockout and hybrid persisted-wall/runtime-monotonic
   clock model; relate it to ADR 26 and supersede the historical plan's
   cooldown choice.
8. `app/AGENTS.md` -- add ADR 27 to the current decision index.
9. `plans/impl/2026-07-14-1333-nova-phone-owned-incidents.md` -- addendum
   line under the superseded cooldown bullet pointing at ADR 27.

## Test plan

Update existing:

- `enablementRequiresOnlineRecordingAnchorAndNoCooldown` -> rename to
  `...AndLockoutClear`; replace the `isPressFeedbackVisible` step with: seed
  a matching runtime lockout with a future monotonic deadline -> `canPress`
  false; continuous `now` past the deadline -> true; a pending record keyed to
  the current `RecordingID` -> false; a pending record keyed to another
  `RecordingID` -> still true.
- `persistedRecordPrecedesAuthNudgeAndReconcile` -- drop the sleep gate, the
  feedback-flag assertions, and the `.cooldownFinished` receive.
- `rolloverRaceKeepsPreviousSegmentWithAgePastItsDuration` -- same drops.
- `incidentButtonFollowsCaptureEnablementAndFeedback` -- with fixed
  `continuousNow` threaded into both store and controller, after
  `.pressTapped` assert disabled AND title == "Saving... 17s".
- `incidentButtonSavingFeedbackFollowsPendingLifecycleAfterCooldown` ->
  rewrite as presentation-mapping tests: matching runtime deadline after `now`
  -> `.armed` active countdown; a persisted incident with `.pending` transfer
  status but no active runtime deadline and no create in flight ->
  `.armed(nil, createInFlight: false)` renders enabled "Save Incident"
  (transfers do not lock); world absent with an active deadline ->
  `.unavailable` (link drop wins).

New:

- **Invariant test:** apply, in this order, to a single reused button at a
  fixed now -- the active-countdown state FIRST (which sets
  `accessibilityValue`), then `.armed(nil, createInFlight: false)`, then an
  expired deadline (`now >= deadline`, `createInFlight: false`), then
  `.armed(nil, createInFlight: true)` (suspended create), then `.unavailable`.
  Assert after every state that `isEnabled` implies title == "Save Incident",
  and that `accessibilityValue == nil` after each non-countdown state (the
  active-first ordering is what lets a stale "N seconds remaining" left behind
  on re-enable/unavailable actually surface).
- **Reducer guard:** TestStore with mutable `continuousNow` box (same pattern
  as the existing `InstantSequence`). Incident pressed at C; now = C+16 s ->
  `.pressTapped` is a no-op; now = C+17.1 s -> press accepted and
  `pendingRecords[currentRecordingID]` is set.
- **Recording identity isolation:** loaded state is recording session 8 with a
  matching anchor and contains an incident pressed 5 s ago in session 7.
  Resolve at launch -> no runtime deadline for session 8, `canPress` true, and
  `.pressTapped` creates a session-8 record. This is the regression for an old
  session otherwise swallowing a new incident mark.
- **Cross-session suspended creates:** suspend `incidentStore.create` for a
  session-7 press, transition folded world + anchor to valid session 8, and
  assert the session-8 presentation is enabled and `.pressTapped` starts a
  second create while session 7 remains in `pendingRecords`. Resolve both
  creates in either order and assert both dictionary entries are removed and
  both incident records are retained. This is the regression for global
  create-in-flight gating and stale-response loss.
- **Store-load race (cold launch):** with `hasLoadedStore == false`, deliver
  `.worldObserved` carrying a recording snapshot so the anchor establishes
  before any `.storeLoaded` -> `captureRecordingID` nil and presentation
  `.unavailable` (button disabled), NOT armed-enabled; then `.storeLoaded`
  with a matching record pressed ~5 s ago -> one-time reconstruction produces
  `continuousNow + 12 s`, and the button locks with the remaining countdown.
  Drive the store load through a suspendable stub so the snapshot is observed
  strictly before the load resolves.
- **Store-load failure recovery:** drive
  `.foregrounded -> .storeLoaded(nil) -> .foregrounded -> .storeLoaded(success)`.
  Assert capture stays `.unavailable` after failure, the second foreground
  retries the store, and successful load plus a valid recording anchor moves
  capture to armed. This covers the only recovery path introduced by
  `hasLoadedStore`.
- **Bounded reconstruction under bad persisted clocks:** (a) matching record
  pressed at wall T, reconstruction wallNow = T - 1 day -> no runtime deadline;
  (b) matching record with corrupt far-future `pressedAtMs` -> no runtime
  deadline. Mark the current `RecordingID` resolved in both cases so later wall
  corrections do not reactivate the window.
- **Corrupt duration fields do not trap or over-lock:** record with
  `postMs == UInt64.max`, `slackMs == 1`, pressed 5 s before reconstruction ->
  reconstruction does not trap and produces only the fixed ~12 s remaining
  monotonic duration. `canPress` is false before that deadline and true after
  it. (This is the case a per-record duration conversion could leave locked
  for ~585 million years; the constant span forecloses it.)
- **Latest matching reconstruction wins:** load two active records for the
  current `RecordingID` in both input orders, including the earlier-expiring
  record first. Assert one-time reconstruction always chooses the greatest
  remaining duration/later monotonic deadline rather than the first element,
  then assert `canPress` stays false until that later deadline expires.
- **Suspended create outlives its window:** TestStore with a suspendable
  `incidentStore.create` stub. `.pressTapped` at C -> the current identity's
  `pendingRecords` entry is set, button disabled "Saving... 17s"; advance
  `continuousNow` to C+18 s and re-derive presentation (and tick the button) ->
  button STILL disabled showing "Saving..." (no countdown),
  `createInFlight == true`, and `canPress` false (so a tap is a no-op); resolve
  the stub via `createResponded(success:)` -> button re-enables "Save
  Incident". Guards the plan's core invariant that no enabled render ever
  rejects its own tap.
- **Persistence failure restores immediate retry:** fail the current
  recording's create before its 17 s deadline. Assert the matching
  `pendingRecords` entry and runtime deadline are cleared, `canPress` becomes
  true, the existing calm alert remains, and a re-derived button presentation
  is enabled with title "Save Incident". Also keep a different recording's
  pending entry in state and assert the failed response does not remove it.
- **In-process wall-clock rewind and correction:** press at wall T / monotonic
  C, then change only wall time to T - 1 day and back to T+5 s while advancing
  monotonic time to C+5 s. The runtime deadline remains C+17 s; presentation
  stays disabled, the timer stays running, and the reducer rejects the tap.
  Also jump wall time forward past T+17 s while monotonic time remains inside
  the span and assert the same result. This proves wall-clock changes cannot
  create either the rewind/correction presentation split or the prior
  forward-jump duplicate path.
- **View timer:** controller with an active monotonic deadline ->
  tick timer running; `tickForTesting(now: past deadline)` -> enabled + timer
  stopped; detach from window -> timer stopped.
- **Relaunch mid-window:** seed loaded state (`hasLoadedStore == true`) with a
  matching record pressed ~5 s before fixed `wallNow`, then run one-time
  resolution at fixed `continuousNow` -> button disabled with "Saving... 12s";
  reducer twin asserts `canPress` false. Repeat the same-record resolution
  after changing wall time and assert the runtime deadline is unchanged.
- **Pure `activeLockout(for:now:)` test:** matching identity with `now` before
  the runtime deadline returns it; `now >= deadline`, nil runtime state, and a
  different `RecordingID` all return nil.

## Edge cases (audited, no extra work needed)

- Link drop mid-countdown: presentation flips to `.unavailable` via the
  observer; on relink the countdown resumes if time remains.
- Backgrounding: runloop timers suspend; on resume the repeating timer fires
  promptly and re-renders within ~1 s. Failure mode is a briefly-late
  enable, never an early one.
- Persistence failure: `createResponded(success: false)` clears
  only the failed identity's `pendingRecords` entry and clears the runtime
  deadline only when it belongs to that identity; no record joined `incidents`,
  so the current-session button re-enables alongside the existing calm alert
  (user can retry). A late response from an old session cannot clear current
  state.
- In-process wall-clock changes: no effect. Presentation and reducer both use
  the runtime monotonic deadline, which only advances toward expiry.
- Relaunch wall-clock reconstruction (accepted risk): the app samples wall time
  once when the loaded store and current `RecordingID` first meet. If the wall
  clock is already wrong at that exact point, relaunch recovery can omit a
  lockout and admit a deletable duplicate; it cannot strand the button or make
  presentation disagree with the reducer, and later corrections do not
  reactivate the resolved recording.

## Documentation decisions

Create `app/docs/design/27-2026-07-14-incident-post-roll-press-lockout.md`:

- **Context:** the implemented 3 s cooldown re-enabled an independently
  "Saving..." button and admitted duplicate overlapping incidents during the
  post-roll window.
- **Decision:** replace cooldown feedback with a reducer-authoritative,
  `RecordingID`-scoped post-roll lockout and one presentation enum. New presses
  use a `ContinuousClock` deadline; relaunch reconstructs its remaining duration
  once from the matching persisted record's fixed wall-clock window. The view
  and reducer consume the same runtime deadline, and in-flight creates are
  keyed by recording identity so an old session cannot gate a new one. Store
  load is required before capture can arm.
- **Consequences:** in-process wall changes cannot end or reactivate lockout;
  relaunch recovery survives process death but depends on wall time being sane
  at its one reconstruction sample; new recording sessions are not blocked by
  old-session incidents; transfers may continue after the button re-enables.
- **Alternatives:** 3 s cooldown, continuously evaluated wall-clock window, and
  reducer-owned countdown timer.

ADR 26 remains Accepted and unchanged: its Decision establishes phone-owned
incident capture but does not contain the cooldown choice. ADR 27 relates to
ADR 26 and explicitly supersedes the cooldown choice recorded in the historical
implementation plan. This preserves append-only ADR history without falsely
superseding ADR 26's still-current phone-ownership decision.

Plan record (`plans/impl/2026-07-14-1333-nova-phone-owned-incidents.md`):
plans are historical record -- do not rewrite the "Press cooldown, not a
lockout" bullet; append one indented line under it:
"Amended 2026-07-14: superseded by the post-roll press lockout in app ADR 27."

## Verification

- `just app-test` -- full app unit suite.
- Manual against the mock Pi (`just raspi-mock-clips`, or `raspi-mock-lan`
  for a device): start recording, then
  1. Tap Save Incident -> disabled, counts "Saving... 17s" down, re-enables
     as "Save Incident" while the Incidents tab badge persists until the
     pulls finish.
  2. Hammer the button during the countdown -> exactly one new incident row.
  3. Kill the mock mid-countdown -> button goes plain disabled
     "Save Incident"; restart the mock -> countdown resumes if time remains.
  4. Background mid-countdown, foreground after ~20 s -> enabled within ~1 s.
  5. Force-quit and relaunch within 17 s of a press -> button comes back
     locked with the remaining countdown.

## Commit

One commit: `fix(app): incident press lockout spans the post-roll window`
(reducer + button + docs + tests are one coherent behavior change).
