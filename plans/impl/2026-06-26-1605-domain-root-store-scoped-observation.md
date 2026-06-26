# Plan: domain-organized root app store + reactive Store dedup

## Context

The app uses a hand-rolled TEA store (`app/DanCam/DanCam/Architecture/Store.swift#Store`)
with closure observers and an `Effect` type. It works, but two problems pushed
domain logic up into the view layer:

1. **No change detection.** `Store.send` calls `notifyObservers()` on every action,
   so observers re-render on every 1.5s connection poll even when nothing changed,
   and `HomeViewController.renderClips` calls `reloadData()` unconditionally. To
   compensate, the VC hand-rolls diffing (`observedRecording`, the `previous`
   capture in `renderRecording`, `RefreshGate`).

2. **Cross-domain glue lives in the view controller.** `HomeViewController`
   bridges connection -> recording (`renderConnection` sends
   `recordingStore.send(.statusObserved(...))`) and recording -> clips
   (`renderRecording` sends `clipsStore.send(.refresh)`). State is also split into
   per-screen stores owned by the VC.

We discussed and rejected a per-screen `HomeFeature`: scoping state to a *page*
couples the domain model to presentation, so reorganizing the UI (tab bar, CarPlay
surface) would force state restructuring. The agreed direction is the opposite:
**one top-level, domain-organized app store; pages are read-only projections.**

Intended outcome: a single `AppFeature` store models the coupled domain
(connection + recording + clips). All cross-domain rules live in its reducer. View
controllers (and later CarPlay) hold the store and observe only the slices they
render, woken only when that slice actually changes. View controllers stop owning
domain state and stop coordinating features.

Scope decision (settled): fold **connection + recording + clips** into the root now
(that is where all the coupling is). Leave **preview** and **health** as their own
stores:
- **Preview** carries `.streaming(PreviewFrame)` JPEG frames through its state at
  stream rate (`app/DanCam/DanCam/Features/Preview/PreviewFeature.swift`); routing
  that through the root reducer + notify fan-out is a real performance mistake.
  Frame decoding is already view-local (`PreviewDecodeState`). This is a domain
  boundary, not a page boundary.
- **Health** has zero cross-domain coupling (nothing reads it) and overlaps with
  connection telemetry; whether it should merge *into connection* is a separate
  decision we should not pre-bake.

The shared `Effect`/observe machinery still lands globally, so preview and health
get deduplicated observation now and can fold into the root trivially later if
coupling appears.

## Guardrail: domain state vs view state

The root store holds **domain / interaction state only** (e.g. `recording ==
.recording`, `pendingManualRefresh`, `connection.lastStatus`). **View state stays
in the VC** (record-button animation, table scroll position, whether the refresh
spinner is literally spinning). Keeping this line clean is what makes page
reorganization never touch the store.

---

## Change 1: Store core (`Architecture/Store.swift`, `Architecture/Effect.swift`)

### 1a. `Effect.merge` + `Effect.map`

Composing sub-reducers requires lifting a child effect into the parent action space
and running more than one effect from a single reduce.

- Add case to `Effect<Action>`: `case merge([Effect<Action>])`.
- Add `func map<T>(_ transform: @escaping (Action) -> T) -> Effect<T>` that rewrites
  `.run`'s `send` to `send(transform(action))`, passes `.none`/`.cancel(id:)`
  through, and maps `.merge` recursively.
- Handle `.merge` in `Store.execute` (`Store.swift#execute`) and in
  `TestStore.execute` (`DanCamTests/Support/TestStore.swift`) by executing each
  child effect. Effect ids (`"recording"`, `"clips-poll"`, `"connection-poll"`) now
  share one global task registry, so they must stay globally unique -- they already
  are; keep them domain-prefixed.

### 1b. Equality-gated notification

- Constrain the class: `final class Store<State: Equatable, Action, Dependencies>`.
  All five store-backed states (`ConnectionFeature.State`, `RecordingFeature.State`,
  `ClipsFeature.State`, `HealthFeature.State`, `PreviewFeature.State`) already
  conform; `TestStore` already requires it; `StoreTests` uses `Int`/`[String]`.
- In `send`: capture `let old = state` before `reduce`, and call
  `notifyObservers()` only when `state != old`. **Always execute the effect**
  regardless (a no-op-state action like `.poll`/`.cancel` must still run its effect).

### 1c. Scoped, deduplicated keypath observe

Add alongside `Store.observe`:

```swift
@discardableResult
func observe<Value: Equatable>(
    _ keyPath: KeyPath<State, Value>,
    _ observer: @escaping (Value) -> Void
) -> StoreObservation
```

Fires immediately with the current slice, then only when that slice changes
(internal `last` value dedup). Layered on the base `observe`. This is the
"reactivity" win: derived, change-only streams without a framework.

**Re-entrancy:** update the internal `last` value **before** invoking the observer, not
after. An observer can re-enter the store -- the shell's `resumeLiveWork` runs during
`notifyObservers` on the `disconnected -> connected` edge and calls
`appStore.send(.clips(.refresh))` -- and if `last` is still stale when that nested notify
re-invokes this wrapper, an unchanged slice would re-fire and the resume could run twice.
Setting `last` first makes a same-value re-entrant notify a no-op. Relatedly, have
`notifyObservers` iterate a snapshot (`for observer in Array(observers.values)`) now that
re-entrant sends are a supported pattern, so a render that registers/cancels an
observation cannot mutate the collection mid-iteration.

---

## Change 2: `AppFeature` root reducer (new `Features/App/AppFeature.swift`)

Domain root composing the three coupled sub-reducers. Sub-reducers
(`RecordingFeature.reduce`, `ClipsFeature.reduce`, `ConnectionFeature.reduce`) are
unchanged and keep their own files.

```swift
enum AppFeature {
    struct State: Equatable {
        var connection = ConnectionFeature.State()
        var recording: RecordingFeature.State = .unknown
        var clips: ClipsFeature.State = .idle
        var pendingManualRefresh = false   // interaction state (replaces RefreshGate)
    }
    enum Action: Equatable {   // Equatable required by TestStore; synthesizes -- every
                               // child Action and its payloads already conform.
        case connection(ConnectionFeature.Action)
        case recording(RecordingFeature.Action)
        case clips(ClipsFeature.Action)
        case recordTapped     // convenience: routes to start/stop by current state
        case manualRefresh    // pull-to-refresh: clips refresh + connection poll
    }
    static func reduce(state:inout State, action:Action, deps:AppDependencies) -> Effect<Action>
}
```

Reducer behavior. **Composition rule:** to run a child action as part of a parent
reduce, call the child reducer synchronously on its sub-state and lift the returned
effect -- `ChildFeature.reduce(&state.child, childAction, deps).map(Action.child)` --
then `.merge([...])` those `Effect` values. `.merge` takes `[Effect<Action>]`; never
pass a parent `Action` (e.g. `.clips(.refresh)`) to it -- an `Action` is not an
`Effect`, so that does not compile. Running the child reducer in-line (rather than
re-`send`ing the action asynchronously) also keeps reducer ordering deterministic and
the cross-domain rules in one synchronous pass.

- `.recording(a)` -> run via `reduceRecording` helper (below).
- `.clips(a)` -> `ClipsFeature.reduce(&state.clips, a, deps).map(Action.clips)`; if
  `a` is `.clipsResponse` -- **either `.success` or `.failure`** (match `if case
  .clipsResponse = a` without binding the `Result`) -- set
  `state.pendingManualRefresh = false`. The spinner must clear on the next clips data
  regardless of outcome, matching the old `RefreshGate` which ended on both `.loaded`
  and `.failed`.
- `.connection(a)` -> capture `before = state.connection.lastStatus?.recording`, run
  `ConnectionFeature.reduce(...).map(Action.connection)`; if
  `state.connection.lastStatus?.recording` changed, also run
  `reduceRecording(&state, .statusObserved(recording: now), deps)` and `.merge` both
  effects. (Replaces the VC's `observedRecording` bridge.)
- `.recordTapped` -> switch on `state.recording`: `.recording` -> stop, `.unknown/
  .idle/.failed` -> start, `.starting/.stopping` -> `.none`. (Moves the VC's
  `recordTapped` switch into the reducer.)
- `.manualRefresh` -> set `state.pendingManualRefresh = true`, then per the composition
  rule `.merge([ClipsFeature.reduce(&state.clips, .refresh, deps).map(Action.clips),
  ConnectionFeature.reduce(&state.connection, .poll, deps).map(Action.connection)])`.

`reduceRecording(&state, a, deps)` private helper: capture `previous =
state.recording`, run `RecordingFeature.reduce(&state.recording, a, deps).map(Action.recording)`,
and if `shouldRefreshClips(previous, state.recording)`, also run
`ClipsFeature.reduce(&state.clips, .refresh, deps).map(Action.clips)` and `.merge` the
two effects (composition rule above). (Replaces the VC's recording -> clips bridge.)

Fold `shouldRefreshClips` (currently
`app/DanCam/DanCam/Features/Home/HomeCoordination.swift#HomeCoordination`) into
`AppFeature` as a private helper -- it is a cross-domain rule, not a screen concern.
**Delete** `HomeCoordination` and `RefreshGate` (the latter fully replaced by
`pendingManualRefresh`).

Add a typealias for readability:
`typealias AppStore = Store<AppFeature.State, AppFeature.Action, AppDependencies>`.

---

## Change 3: Rewire consumers (pages become projections)

The standalone `connectionStore`/`recordingStore`/`clipsStore` are deleted; one
`AppStore` is created in `SceneDelegate` and injected everywhere.

- **`App/SceneDelegate.swift`**: create the single `AppStore` (initial
  `AppFeature.State()`, `AppFeature.reduce`) and inject it into both `HomeViewController`
  and `AppShellViewController` (the existing root shell -- `window.rootViewController`).
  Lifecycle sends become `.connection(.start)` on launch + foreground and
  `.connection(.stop)` on background; the foreground
  `(shell.topViewController as? ConnectionResumable)?.resumeLiveWork()` hook is unchanged.

- **`Features/Home/HomeViewController.swift`**: hold `AppStore` instead of three
  stores. Replace observers with scoped observes:
  - `store.observe(\.recording) { renderRecording }`
  - `store.observe(\.clips) { renderClips }`
  - `store.observe(\.connection.lastStatus) { renderConnectionPills }` (temp/camera
    pills; re-renders only when status changes)
  - `store.observe(\.pendingManualRefresh) { if !$0 { refreshControl.endRefreshing() } }`
  Sends become nested: `.recordTapped`, `.manualRefresh`, `.clips(.onAppear/.onDisappear)`.
  Delete `observedRecording`, the `previous`-diff in `renderRecording`, `refreshGate`,
  and the `recordingStore`/`clipsStore` properties. `resumeLiveWork()` sends
  `.clips(.refresh)` and calls `previewViewController.reconnect()` (preview stays its
  own store, owned by Home VC as a child). `recordTapped` just sends `.recordTapped`.
  `refreshPulled` sends `.manualRefresh` **and** also calls
  `previewViewController.reconnect()` -- preview is a separate VC-owned store, so the pull
  keeps force-retrying the preview stream exactly as `resumeLiveWork()` does today.
  (`.manualRefresh` covers only clips + connection; the root reducer does not own preview,
  so the VC must nudge it -- otherwise pull-to-refresh during a preview outage silently
  loses today's stream retry.)

- **`Features/Health/HealthViewController.swift`**: take `AppStore` in place of the
  `monitor` param; render telemetry via `store.observe(\.connection.lastStatus)`.
  Its own `HealthFeature` store is unchanged (stays independent).

- **`App/AppShellViewController.swift`** (the current root shell; the old
  `ConnectionIndicatorCoordinator` no longer exists): take the `AppStore` in place of
  the standalone `ConnectionFeature` monitor. Replace the unscoped `monitor.observe` with
  a scoped `store.observe(\.connection.connectivity)` so the strip wakes only on
  connectivity changes, not on every 1.5s `lastStatus` poll; `render` then takes the
  `Connectivity` slice instead of the whole `ConnectionFeature.State`. The shell's recovery
  logic is unchanged and already correct: retain `previousConnectivity`, configure the
  strip via `ConnectionCoordination.presentation(for:)`, and fire `resumeLiveWork()` on
  the embedded nav's top view controller only when
  `ConnectionCoordination.shouldResumeLiveWork(from:to:)` is true (that predicate is
  exactly `previous == .disconnected && next == .connected`, so first-contact
  `connecting -> connected` is correctly not a resume). `ConnectionCoordination`
  (`presentation` + `shouldResumeLiveWork`) is unchanged.

- **`Features/Preview/PreviewFeature.swift` + `PreviewViewController.swift`**: stays its
  own store, but make a new stream observable so the equality gate (Change 1b) cannot
  swallow a reconnect. Today `render`'s `.connecting` branch resets decode generation as
  a side effect (`decodeState.beginNewStream()`), but `.onAppear/.startTapped/.reconnectNow`
  set `phase = .connecting` + `reconnectAttempt = 0`, so a `.reconnectNow` while already
  `.connecting` leaves `PreviewFeature.State` byte-identical -- the gate skips the notify
  and stale frames never get dropped. Fix: add `var streamGeneration = 0` to
  `PreviewFeature.State` (monotonic; separate from `reconnectAttempt`, which resets to 0
  and drives backoff) and increment it on every connect/reconnect start (`.onAppear`,
  `.startTapped`, `.reconnectNow`, `.reconnect`). In the VC, drive the decode reset off
  that signal -- observe `\.streamGeneration` (scoped) and call
  `decodeState.beginNewStream()` on each change -- and remove the `beginNewStream()` call
  from the `.connecting` render branch so `render` itself is idempotent.

`ConnectionResumable` (`App/ConnectionResumable.swift`) is unchanged; Home VC still
conforms.

---

## Change 4: Tests

Run with `just app-test`.

**`DanCamTests/Architecture/StoreTests.swift`** -- add:
- equality gate: an action that does not change state does **not** notify observers;
  one that does still does (existing tests already mutate every send, so they pass). The
  companion invariant -- a no-op-state action still **runs its effect** -- is already
  pinned by `cancelStopsInFlightEffectAction` (`.cancel` mutates nothing, yet must still
  cancel the in-flight task), so 1b must gate only `notifyObservers`, never `execute`.
- scoped `observe(_:keyPath)`: fires immediately, then only on slice change; an
  unrelated slice change does not fire it. Also assert the re-entrancy guard: an observer
  that re-enters the store with a `send` leaving its slice unchanged is not re-fired
  (the `last`-before-invoke rule above).
- `.merge`: both child effects run; `Effect.map` lifts a child action.
- **mapped cancellation preserved** -- run against the real `Store`, `Signal`/`Gate` style
  like `cancelStopsInFlightEffectAction` (the production `Store` has no `finishEffects` --
  that is a `TestStore` method): start a long-running `.run(id:)` effect lifted through
  `Effect.map` (signal on entry, block on a `Gate`), send a mapped `.cancel(id:)`, open the
  gate, and assert the post-gate `send` never lands (state unchanged). Guards the
  regression where `Effect.map` drops `.cancel` and leaks the task.

**New `DanCamTests/Features/App/AppFeatureTests.swift`** (drive `AppFeature.reduce`
through `TestStore`, matching existing feature-test style with the queue actors):
- `.recordTapped` routing by current `recording` state.
- recording transition to `.idle` triggers a clips refresh (receive
  `.clips(.clipsResponse(...))`).
- `.connection(.statusResponse(...))` whose `lastStatus.recording` flips syncs
  recording (and refreshes clips on a stop).
- **no spurious refresh on record-start (asymmetry guard)**: from `recording == .idle`,
  `clips == .loaded([...])`, a `.connection(.statusResponse(.success(recording: true)))`
  drives `recording -> .recording` but leaves `clips` unchanged and emits **no**
  `.clips(.clipsResponse(...))`. Pins the `shouldRefreshClips` asymmetry (only
  `.recording/.stopping -> .idle` refreshes) that `HomeCoordinationTests` currently
  guards on the negative side; without it, a regression returning `true` for `-> .recording`
  would fetch clips on every record-start / connect-to-recording and still pass every
  other listed test.
- **initial status seeding**: from `AppFeature.State()` (recording `.unknown`,
  `connection.lastStatus == nil`), the first successful
  `.connection(.statusResponse(.success(...)))` seeds `recording` from `.unknown`
  (nil -> Bool counts as a flip). Guards a reducer that only handles non-nil-to-nil
  flips and would leave the record button stuck in `.unknown`.
- `pendingManualRefresh` set by `.manualRefresh`, cleared on
  `.clips(.clipsResponse(.success(...)))`.
- **manual refresh clears on failure**: `.manualRefresh` then
  `.clips(.clipsResponse(.failure(...)))` also clears `pendingManualRefresh` (so the
  spinner does not hang on a failed refresh).
- **mapped cancel reaches the child**: `.clips(.onAppear)` starts the clips poll in
  the root store, then `.clips(.onDisappear)` (which maps to `.cancel(id:
  "clips-poll")`) stops it -- `finishEffects` and assert no further `.clips(...)`
  action is received. Confirms cancellation survives `Effect.map` end to end through
  `AppFeature.Action`.

**`DanCamTests/Features/Preview/PreviewFeatureTests.swift`** -- update + add:
- existing cases that send connect/reconnect actions (`.onAppear`, `.startTapped`,
  `.reconnectNow`, `.reconnect`) must account for the new `streamGeneration` increment in
  their expected state.
- **reconnect while connecting still changes state**: from `.connecting`
  (`streamGeneration == 1` after `.onAppear`), `.reconnectNow` keeps `phase == .connecting`
  but bumps `streamGeneration` to 2, so the state is observably different and the equality
  gate notifies. Guards the dropped decode-reset regression.

**`DanCamTests/App/AppShellViewControllerTests.swift`** -- update: construct the shell
with an `AppStore` instead of a standalone `ConnectionFeature` store, and drive
connectivity through `.connection(.statusResponse(...))` (or whatever seam sets
`\.connection.connectivity`). Keep the existing assertions -- strip presentation per
connectivity, and `resumeLiveWork()` firing on the spy top view controller only on
`disconnected -> connected`. `ConnectionCoordinationTests` stays as-is
(`ConnectionCoordination` unchanged).

**Migrate/delete:** `DanCamTests/Features/Home/HomeCoordinationTests.swift` --
the `shouldRefreshClips` cases move into `AppFeatureTests` as behavioral assertions;
delete the `RefreshGate` tests (type removed). Existing `RecordingFeatureTests`,
`ClipsFeatureTests`, `ConnectionFeatureTests`, and `HealthFeatureTests` stay as-is
(sub-reducers unchanged).

---

## Change 5: Update the ADR record

This plan changes accepted decisions in the **active** app shell/connection ADR,
`app/docs/design/05-2026-06-26-app-shell-status-strip.md` (ADR 04 is already
`Superseded by 05`, so do **not** touch ADR 04). ADR 05's Decision keeps "the app-scoped
`ConnectionFeature` monitor ... the sole `GET /v1/status` reader" and makes the shell
"responsible for monitor observation." This plan folds that monitor into the `connection`
sub-state of the single `AppStore` and rewires `AppShellViewController` to take the
`AppStore`. It also deletes `RefreshGate` (a mitigation carried down the ADR 04 lineage)
in favor of `pendingManualRefresh`. Per root `AGENTS.md` ("update the record in the same
change"; append-only ADR history), write a new app ADR:

- `app/docs/design/06-YYYY-MM-DD-domain-root-store-and-scoped-observation.md` (date = the
  day it is written; `{seq}` = 06, next after 05).
- Records the decision: one domain-organized root `AppFeature` store (connection +
  recording + clips) with all cross-domain rules in the root reducer; pages (and the
  shell) are read-only projections via scoped, equality-gated `observe`; preview and
  health stay separate stores (reasons per Context). Status: Accepted.
- Mark ADR 05 `Superseded by 06-...`. **Carry forward** ADR 05's surviving decisions so
  the active record stays self-contained: the `AppShellViewController` persistent status
  strip, the connection-only strip presentation (`ConnectionCoordination.presentation`),
  and the fail-slow/recover-fast debounce + `shouldResumeLiveWork` resume-edge policy all
  remain -- only the strip's data source changes (it now reads the `AppStore`'s
  `\.connection.connectivity`).
- ADR 03 (`app-ui-architecture`) is **extended, not superseded**: its bespoke-TEA /
  UIKit / zero-deps framework choice still holds, and it already frames its `Effect`/`send`
  sketches as "illustrative ... not a frozen API." ADR 06 notes the additive core changes
  (`Effect.merge`, `Effect.map`, equality-gated `send`, scoped keypath `observe`) and links
  back to ADR 03.
- Run `just adr-check` (validates the `{seq}` sequence and naming).

---

## Verification

1. `just app-test` -- all suites green, including new Store + AppFeature tests.
2. Build and run in the simulator (`just` app run task / Xcode). Manual smoke with
   the mock-Pi path:
   - Connection pill reflects connect/disconnect; reconnect triggers a clips refresh
     (verify it does **not** re-render every 1.5s poll -- e.g. log in `renderClips`).
   - Tap record: button + REC pill update; on stop, clips list refreshes once.
   - External recording change (status flips `recording`) updates the record button
     without a tap.
   - Pull-to-refresh: spinner ends when clips data returns, including when the
     returned list is identical (the `pendingManualRefresh` path, which the old
     `RefreshGate` + equality gate would have hung on).
   - Debug screen telemetry still updates each poll.
   - Preview reconnect: trigger a reconnect while preview is mid-connect (quick
     background/foreground, or the shell's `disconnected -> connected` recovery edge); the
     live image resumes and stale frames from the prior stream don't flash (the
     `streamGeneration` decode reset).
3. `just adr-check` -- passes with ADR 05 marked superseded and ADR 06 added.

## Notes / risks

- **Equality-gate is a core behavior change**: unscoped `observe` no longer fires on
  no-op-state actions. Audited consumers (app shell strip, health telemetry) are
  idempotent renders; the shell observes `\.connection.connectivity` (which changes only
  on real transitions) and health telemetry reads `\.connection.lastStatus` (which
  changes every poll), so both still update as before. **Preview was the exception** -- its `.connecting` render reset decode
  generation as a side effect, so a no-op `.reconnectNow` would have been swallowed;
  Change 3 fixes that by making a new stream observable via
  `PreviewFeature.State.streamGeneration`.
- **Re-entrant resume**: with one store, the shell's scoped-connectivity observer fires
  during `notifyObservers` on the `disconnected -> connected` edge and calls
  `resumeLiveWork() -> appStore.send(.clips(.refresh))` -- a re-entrant send on the same
  store mid-notify (today it hits a *different* store, so this is new). It is bounded and
  safe: the equality gate suppresses the nested notify when `clips` is already `.loaded`,
  and allows at most one extra notify level when `clips == .idle`; the scoped-observe
  `last`-before-invoke rule (Change 1c) keeps the connectivity observer from re-firing
  inside that nested notify.
- **Global effect-id namespace**: one task registry now. Current ids are unique;
  keep new effect ids domain-prefixed.
- **Not a one-way door**: folding preview/health into the root later is cheap once
  this machinery exists.
