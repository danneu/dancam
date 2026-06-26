# Plan: Swoop `opal` (app slice) -- Ambient connection indicator + self-healing dashboard

## Context

Opening the app shows a stale, "connected-looking" dashboard. After backgrounding
(drive off, Wi-Fi drops, reopen) `HomeViewController` still holds the last preview
frame and last clips list with only a small failure pill layered over them; on a cold
launch while off the Pi's AP you get scattered failure pills but the full dashboard
chrome. Two root causes:

1. **No app-wide connection truth, and no distinct disconnected presentation.**
   Connectivity is implicit and per-store. The only signal is Home's "Can't reach
   camera" pill (`HomeViewController.swift#renderStatus`), which flips on the *first*
   missed poll (no debounce -- `StatusFeature.swift#reduce` reaches `.failed` on one
   failure), is scoped to Home, and is gone the moment any page is pushed. There are
   three independent `/v1/status` readers today -- `StatusFeature` (Home's 1.5s poll),
   `RecordingFeature.statusEffect` (one-shot on appear + after start/stop), and
   `HealthViewController`'s own poll -- each dying with its screen.

2. **The live preview never self-heals, and nothing recovers on foreground.**
   `PreviewFeature.swift#reduce` returns `.none` on `.streamFailed`/`.streamFinished`
   -- it does *not* reschedule a reconnect the way `StatusFeature.swift#schedulePoll`
   does. So once the MJPEG stream drops (link blip or app suspension) preview is dead
   until a fresh `viewWillAppear`. `SceneDelegate.swift` has no foreground hook and
   there is no pull-to-refresh.

This slice is the **app-side UX of roadmap swoop `opal`** ("Connection robustness:
offline detection via missed heartbeats -> alert; back-off reconnect"), minus the
`NEHotspotConfiguration` radio auto-rejoin (stays in `opal` proper). It introduces a
single **app-scoped connection monitor** (the lone `/v1/status` reader), an
**always-visible nav-bar connection pill** on every screen, **preview self-heal with
back-off**, **auto-recovery** on reconnect and on foreground, and **pull-to-refresh**.
Per the root `AGENTS.md` "Optimize for the ideal solution" stance, the three status
readers are collapsed into one (delete-and-replace, not layered around) rather than
adding a parallel heartbeat.

Decided constraints (settled with Dan, not relitigated):
- Connected-truth is an HTTP `/v1/status` poll that hits the Pi, **not** `NWPathMonitor`
  (being on some Wi-Fi != the Pi answering; the AP has no internet).
- **No** full-screen takeover. Connection is an **ambient nav-bar pill**; every screen
  rides out drops **in place** without navigating away or tearing down user state
  (e.g. viewing a clip on a pushed page, dropping, rejoining, foregrounding, and still
  watching).
- Flip the pill to "Not connected" only after **3 consecutive failed polls** (debounce
  the congested 2.4 GHz link); recover to "Connected" on the **first** success.
- Indicator presentation: **always-visible pill** (dot + label) on the right of the
  nav bar, coexisting with the title and the Debug button.

Outcome: launch -> "Connecting" then "Connected"; lose the link -> "Not connected"
after ~4.5s while the dashboard keeps its last frame and clip list; regain it (or
foreground) -> preview, status, and clips resume on their own. The pill is live on
pushed pages too, so the future clip viewer (`lime`) inherits it for free.

---

## Scope

In:
- App-scoped `ConnectionFeature` store = the single `/v1/status` poll, debounced
  connectivity, retained last-known status.
- Always-visible nav-bar connection pill installed globally via a nav-controller
  delegate coordinator, reusing `StatusPillView`.
- Collapse the three `/v1/status` readers into the monitor: delete `StatusFeature`;
  reseed `RecordingFeature` from the monitor; repoint `HealthViewController` at it.
- `PreviewFeature` self-heal: back-off reconnect after `.streamFailed`/`.streamFinished`,
  plus a `.reconnectNow` nudge.
- Scene foreground/background handling; auto-recovery routed to the top VC via a
  `ConnectionResumable` protocol (so pushed pages, incl. future `lime`, recover with
  zero new plumbing).
- Pull-to-refresh on Home's clips table; graceful clips (stop blanking on a failed
  poll); drop the un-debounced "Can't reach camera" pill.

Out (Deferred): `NEHotspotConfiguration` persistent auto-rejoin and Wi-Fi back-off
reconnect (`opal` proper); resumable clip pull across drops; the clip viewer VC
itself (`lime`); making the Debug/Health screen resumable.

---

## Architecture decision

A single `@MainActor` `Store<ConnectionFeature.State, ConnectionFeature.Action,
AppDependencies>` is created and retained by `SceneDelegate` for the scene's lifetime
and polls `/v1/status` continuously while the app is active, regardless of the top
screen. It is the **only** caller of `dependencies.status.fetch()`.

- The **nav-bar pill** is owned by a `UINavigationControllerDelegate` coordinator that
  observes the monitor and re-decorates each top VC on `didShow` -- so it renders on
  Home and every pushed page with no per-VC code.
- **Home** observes the monitor for dashboard facts (temp warning, camera-offline
  pill) and to seed recording state; it no longer owns a status poll.
- **Recovery** (preview reconnect + clips refresh) is routed to whatever VC is on top
  via `ConnectionResumable.resumeLiveWork()`, triggered by (a) scene foreground and
  (b) the monitor's `disconnected -> connected` edge. The clip viewer will conform
  later (or no-op, since it plays local bytes) and inherit recovery automatically.
- **Preview** self-heals on its own back-off timer (covers preview-only failures where
  `/v1/status` still answers, e.g. a camera-subprocess restart) **and** accepts the
  `.reconnectNow` nudge for instant recovery on a whole-link return. It is *not* gated
  on monitor connectivity (that would break independent self-heal).

The Xcode project uses `PBXFileSystemSynchronizedRootGroup` (no per-file `.pbxproj`
entries), so added/removed `.swift` files need no project-file edits; confirm at impl
time as `fern` did.

---

## App implementation (`app/DanCam/DanCam/`)

### 1. New: `Features/Connection/ConnectionFeature.swift`

The app-scoped monitor. Reuses `StatusFeature`'s single-cancellable-id,
self-rescheduling shape (`StatusFeature.swift#fetchEffect`, `#schedulePoll`) and adds
debounced connectivity + retained last status.

```swift
enum ConnectionFeature {
    struct State: Equatable {
        var connectivity: Connectivity = .connecting
        var consecutiveFailures: Int = 0
        var lastStatus: StatusResponse?        // last SUCCESS -- facts survive drops
    }
    enum Connectivity: Equatable { case connecting, connected, disconnected }
    enum Action: Equatable {
        case start                              // launch / foreground
        case stop                               // background
        case poll
        case statusResponse(Result<StatusResponse, StatusError>)
    }
    static let failureThreshold = 3
    private static let pollID = "connection-poll"
    private static let pollInterval = Duration.milliseconds(1500)
}
```

Reducer:
- `.start`: `consecutiveFailures = 0`; **leave `connectivity` unchanged** (no
  "Connecting" flash on every foreground once we have ever connected). Return the
  immediate fetch effect under `pollID` (`cancelInFlight: true`).
- `.poll`: return the fetch effect under `pollID`.
- `.statusResponse(.success(r))`: `lastStatus = r`, `consecutiveFailures = 0`,
  `connectivity = .connected` (recover-fast: one success flips). Return `schedulePoll`.
- `.statusResponse(.failure)`: `consecutiveFailures += 1`; **keep `lastStatus`**
  (graceful -- facts stay, just stale); if `consecutiveFailures >= failureThreshold`
  set `connectivity = .disconnected`, else leave it (ride out the miss). Return
  `schedulePoll` -- a failure must keep probing so we detect recovery.
- `.stop`: `.cancel(id: pollID)` (stops the poll and the failure accrual while
  suspended).

`fetchEffect`/`schedulePoll` are copied in shape from `StatusFeature` (same
`CancellationError` / `URLError.cancelled` guards; the inter-poll sleep uses the
existing injectable `dependencies.sleep`). Debounce is asymmetric -- **fail-slow (N=3),
recover-fast (1)** -- and the counter resets on any success and on `.start`. Initial
`connectivity` is `.connecting`; it leaves that only on the first success (->
connected) or the 3rd failure (-> disconnected).

### 2. New: `Features/Connection/ConnectionCoordination.swift`

Pure helpers (mirrors `HomeCoordination.swift`):

```swift
nonisolated enum ConnectionCoordination {
    static func didReconnect(from p: ConnectionFeature.Connectivity,
                             to n: ConnectionFeature.Connectivity) -> Bool {
        n == .connected && p != .connected
    }
    static func caption(for c: ConnectionFeature.Connectivity) -> String { ... }
    // .connecting -> "Connecting", .connected -> "Connected", .disconnected -> "Not connected"
}
```

`didReconnect` is `true` only on `* -> .connected` (incl. `connecting -> connected`
on first contact); the coordinator gates the *resume* poke on the
`disconnected -> connected` edge specifically (initial connect is handled by the
screen's own appear). Dot color (green / secondary / red) is chosen inline in the
coordinator (UIKit, not unit-tested).

### 3. New: `App/ConnectionResumable.swift`

```swift
@MainActor protocol ConnectionResumable { func resumeLiveWork() }
```

### 4. New: `App/ConnectionIndicatorCoordinator.swift`

An `NSObject & UINavigationControllerDelegate` that owns the shared monitor store, a
single `StatusPillView`, and its `StoreObservation`:
- `attach(to:)`: keep a weak nav ref, set itself as `delegate`, decorate the current
  `topViewController` immediately (the root set via `init(rootViewController:)` does
  not get a `didShow`).
- `navigationController(_:didShow:animated:)`: move the one pill bar item onto the
  shown VC -- strip it from the previously decorated VC (the pill view has one
  superview) and append it to the shown VC's `rightBarButtonItems`, preserving Home's
  Debug item (`HomeViewController.swift#viewDidLoad`). Auto-decorates every future
  pushed VC, incl. `lime`'s clip page.
- Observe the store: set the pill via `ConnectionCoordination.caption(for:)` + dot
  color; on each change, if `didReconnect(from: previous, to: new)` **and** previous
  was `.disconnected`, call
  `(nav?.topViewController as? ConnectionResumable)?.resumeLiveWork()`.

**Mechanism:** a trailing `UIBarButtonItem(customView: StatusPillView)`. Rejected:
`titleView` (clobbers each screen's title), `prompt` (reflows the bar, reads as a
transient banner), a full-width band (consumes vertical space on every screen).
`StatusPillView` already gives dot + caption + material styling + accessibility.

### 5. `App/SceneDelegate.swift` (modify)

- Add stored `connectionStore` and `indicatorCoordinator` (scene lifetime).
- `scene(_:willConnectTo:)`: build `connectionStore` with `.live`; build
  `HomeViewController(dependencies: .live, monitor: connectionStore)`; wrap in the nav
  controller; `indicatorCoordinator = ConnectionIndicatorCoordinator(store:
  connectionStore)` then `attach(to: navigationController)`; `connectionStore.send(.start)`
  (the heartbeat must start at cold launch -- `willEnterForeground` is not called then).
- `sceneWillEnterForeground(_:)`: `connectionStore.send(.start)` (immediate re-probe)
  **and** `(nav.topViewController as? ConnectionResumable)?.resumeLiveWork()` (re-kick
  the visible screen, since `viewWillAppear` does not fire on foreground). On a pushed
  page this pokes that page, not Home -- Home underneath is untouched.
- `sceneDidEnterBackground(_:)`: `connectionStore.send(.stop)`.

`SceneDelegate` owns the monitor lifecycle exclusively; screens never start/stop it.

### 6. `Features/Home/HomeViewController.swift` (modify -- largest change)

- New `init(dependencies:monitor:)`. **Remove** `statusStore` + `statusObservation`;
  add a `monitor` reference + `connectionObservation`; keep `recordingStore`,
  `clipsStore`, the embedded `previewViewController`. Conform to `ConnectionResumable`.
- `connectionObservation = monitor.observe { ... }` renders from `state.lastStatus`:
  reuse `renderTempWarning(sensor:)` and `renderCameraError(response:)`
  (`HomeViewController.swift#renderTempWarning`, `#renderCameraError`) fed from
  `lastStatus`; when `lastStatus.recording` changes, send
  `recordingStore.send(.statusObserved(recording:))`. The connected-edge resume is
  owned by the coordinator, not here.
- `resumeLiveWork()` = `clipsStore.send(.refresh)` + `previewViewController.reconnect()`.
- `viewWillAppear`: send only `clipsStore.send(.onAppear)` (preview rides child-VC
  containment; recording seeds from the monitor; the monitor is app-scoped and already
  running). `viewWillDisappear`: `clipsStore.send(.onDisappear)`.
- **Pull-to-refresh:** attach a `UIRefreshControl` to `clipsTableView` (already the
  only scroll view -- avoids wrapping the aspect-constrained stack in an outer scroll
  view). `.valueChanged` -> `resumeLiveWork()` + `monitor.send(.poll)`, **then**
  `refreshGate.begin()`. Ending the spinner is gated by a small pure `RefreshGate`
  (added to `HomeCoordination.swift`, see below), **not** by "end when the next clips
  state lands in `renderClips`". That naive rule is wrong: `Store.send` notifies
  observers after *every* action (`Store.swift#send` always calls `notifyObservers`),
  and `.refresh` from a `.loaded` state does not change `ClipsFeature.State`
  (`ClipsFeature.swift#reduce` only moves to `.loading` when `.idle`), so the
  synchronous re-render from `clipsStore.send(.refresh)` would end the spinner
  instantly, before the network refresh returns. The gate closes that hole: `begin()`
  is called *after* the synchronous send (so that unchanged re-render is observed while
  the gate is disarmed and ignored), and `renderClips` calls `refreshGate.handle(state)`,
  which ends refreshing only on the first subsequent `.loaded`/`.failed` (the real
  network result) and re-arms only on the next `begin()`.

  `RefreshGate` (pure, `nonisolated`, in `Features/Home/HomeCoordination.swift`
  alongside `shouldRefreshClips`):

  ```swift
  nonisolated struct RefreshGate {
      private var awaiting = false
      mutating func begin() { awaiting = true }
      mutating func handle(_ state: ClipsFeature.State) -> Bool {
          guard awaiting else { return false }
          switch state {
          case .loaded, .failed: awaiting = false; return true   // network result -> end
          case .idle, .loading:  return false
          }
      }
  }
  ```

  `HomeViewController` owns one `RefreshGate` value; the `UIRefreshControl` wiring
  (the `begin()`-after-send ordering and `endRefreshing()`) stays UIKit plumbing, but
  the gate's decision logic is pure and unit-tested.
- **Graceful clips:** in `renderClips` (`HomeViewController.swift#renderClips`), on
  `.failed` keep the existing `clips` (drop `clips = []`); only `.loaded` replaces the
  array. The list rides out a dropped poll in place.
- **Drop the un-debounced error pill:** remove the `.failed -> "Can't reach camera"`
  branch in `renderStatus`; the nav pill now owns connectivity messaging. Keep the
  `camera_state == .offline` pill (a distinct Pi-reported fact) and the temp-warning
  pill. On a failed status poll Home simply hides its status pills.
- Pass `monitor` when pushing Health in `debugTapped`.

### 7. `Features/Preview/PreviewFeature.swift` (modify -- self-heal + back-off)

Convert `State` to a struct so the back-off attempt persists (pure reducer ->
backoff must live in state):

```swift
enum PreviewFeature {
    struct State: Equatable {
        enum Phase: Equatable { case idle, connecting, streaming(PreviewFrame), stopped, failed(String) }
        var phase: Phase = .idle
        var reconnectAttempt: Int = 0
    }
    enum Action: Equatable {
        case onAppear, startTapped, onDisappear, stopTapped
        case reconnectNow                       // external nudge (resumeLiveWork)
        case reconnect                          // internal: backoff timer fired
        case frameReceived(PreviewFrame), streamFinished, streamFailed(PreviewError)
    }
    private static let streamID = "preview"
    private static let baseBackoff = Duration.seconds(1)
    private static let maxBackoff  = Duration.seconds(8)
}
```

- `.onAppear`, `.startTapped`, `.reconnectNow`: `phase = .connecting`,
  `reconnectAttempt = 0`, run the existing connect effect under `streamID`
  (`cancelInFlight: true`) -- `.reconnectNow` thereby cancels a pending backoff sleep
  and reconnects immediately.
- `.reconnect`: `phase = .connecting`, run the connect effect under `streamID`.
- `.frameReceived(frame)`: `phase = .streaming(frame)`, `reconnectAttempt = 0`
  (a healthy stream resets backoff). `.none`.
- `.streamFinished`: `phase = .stopped`, `reconnectAttempt += 1`, return
  `scheduleReconnect`.
- `.streamFailed(error)`: `phase = .failed(error.displayMessage)` (keeps the "Preview
  offline" pill + last frame), `reconnectAttempt += 1`, return `scheduleReconnect`.
- `.onDisappear`, `.stopTapped`: `phase = .stopped`, `.cancel(id: streamID)` (tears
  down the stream **or** the pending backoff -- same single-id discipline as status).

`scheduleReconnect` mirrors `StatusFeature.schedulePoll` under the same `streamID`:
`await dependencies.sleep(backoff(reconnectAttempt))` then a cancellation-guarded
`send(.reconnect)`, where `backoff(n) = min(baseBackoff * 2^(n-1), maxBackoff)`. This
is the bug fix: the failure/finish branches reschedule instead of returning `.none`.

### 8. `Features/Preview/PreviewViewController.swift` (modify)

- `render` switches on `state.phase` instead of `state` (`PreviewViewController.swift#render`);
  content otherwise unchanged (the `.failed` "Preview offline" pill still shows while a
  reconnect is pending).
- Add `func reconnect() { store.send(.reconnectNow) }` for the parent to call on
  foreground / recovery.

### 9. `Features/Recording/RecordingFeature.swift` (modify -- drop its status reader)

- Remove `statusEffect` and `refreshStatus` and all `dependencies.status.fetch()`
  calls. Replace `.statusResponse(Result<StatusResponse, StatusError>)` with
  `.statusObserved(recording: Bool)` (driven by Home from the monitor).
- `.onAppear`: no longer fetches (drop the case; Home stops sending it -- recording is
  seeded by the first monitor success).
- `.startTapped` / `.stopTapped`: keep the optimistic `RecordingClient` mutation +
  `.recordingResponse`, **drop the trailing `refreshStatus`** (the monitor reconciles
  within 1.5s).
- `.statusObserved(isRecording)`: reconcile only when not mid-mutation --
  `.starting`/`.stopping` -> `.none` (don't clobber optimistic in-flight); otherwise
  `state = isRecording ? .recording : .idle`.

### 10. Delete `Features/Status/StatusFeature.swift` + repoint Health

- `Features/Health/HealthViewController.swift`: remove its `statusStore` +
  `statusObservation` + `onAppear`/`onDisappear`; inject `monitor`; observe it; render
  telemetry from `monitor.state.lastStatus`.
- `Features/Health/HealthTelemetry.swift`: change `rows(for state: StatusFeature.State)`
  to `rows(for status: StatusResponse?)` (placeholder rows when `nil`; otherwise the
  same body).
- Delete `Features/Status/StatusFeature.swift`.

---

## Tests (Swift Testing + `TestStore`, behavioral / structure-insensitive only)

Follow the bounded-`receive` + immediate-`sleep`-stub pattern of `StatusFeatureTests`
/ `ClipsFeatureTests`; size fetch queues exactly to the asserted receives (never
`finishEffects()` on a self-rescheduling poll -- the loop never ends).

`DanCamTests/Features/Connection/ConnectionFeatureTests.swift` (new):
- `successFlipsToConnectedAndSchedulesPoll`: `.start` (state unchanged) ->
  `receive(.statusResponse(.success(r)))` -> `.connected`, `lastStatus == r`,
  `failures == 0` -> `receive(.poll)`.
- `staysConnectedUntilThirdFailure` (debounce): from connected, feed 3 failures;
  assert still `.connected` after failures 1 and 2, `.disconnected` only after 3,
  receiving `.poll` between each.
- `singleSuccessResetsCounterAndRecovers`: drive to `.disconnected`, then one success
  -> `.connected`, `failures == 0`.
- `lastStatusRetainedAcrossFailures` (graceful): success sets `lastStatus`; a later
  failure keeps it non-nil and `connectivity` unchanged below threshold.
- `stopCancelsPollAndSendsNoFurtherActions`: `.start`, await a hanging fetch via an
  `AsyncSignal` stub (as in `StatusFeatureTests.onDisappearCancelsInFlightFetch`),
  `.stop`, `finishEffects`, `expectNoReceivedActions`.

`DanCamTests/Features/Connection/ConnectionCoordinationTests.swift` (new): table-drive
`didReconnect` -- `true` for `connecting->connected` and `disconnected->connected`;
`false` for `connected->connected`, `connected->disconnected`,
`disconnected->disconnected`, `connecting->disconnected`. Assert `caption(for:)`
returns the three expected strings.

`DanCamTests/Features/Preview/PreviewFeatureTests.swift` (modify):
- Migrate the 5 existing tests to the struct state (`$0.phase = .connecting`, etc.);
  `onDisappear`/`stopTapped` cancel still yields no further actions.
- `streamFailureSchedulesReconnect` (the fix): `.onAppear` -> `.connecting` ->
  `receive(.streamFailed(.http(503)))` -> `phase .failed`, `reconnectAttempt == 1`,
  schedules `.reconnect` -> with immediate `sleep` `receive(.reconnect)` ->
  `.connecting` -> queue a frame -> `receive(.frameReceived)` -> `.streaming`,
  `reconnectAttempt == 0`.
- `streamFinishedSchedulesReconnect`: same from `.streamFinished`.
- `reconnectNowCancelsPendingBackoff` (the regression guard): create a **genuinely
  pending** backoff before cancelling it, so the assertion is not vacuous. Use a
  *suspending* `sleep` stub -- it signals it has started, then blocks until released
  (the `AsyncSignal` hang pattern from `StatusFeatureTests.onDisappearCancelsInFlightFetch`)
  -- and a non-yielding preview connect stub (`AsyncThrowingStream { _ in }`). Drive a
  real `.streamFailed(.http(503))` so the reducer schedules an actual backoff
  (`phase .failed`, `reconnectAttempt 1`); await the started-signal so the backoff is
  suspended in `sleep` (its `send(.reconnect)` has *not* fired). Then `send(.reconnectNow)`
  (assert `.connecting`, `reconnectAttempt 0`) -- its `cancelInFlight` under `streamID`
  must cancel that suspended backoff task. Release the sleep (the cancelled task resumes,
  hits the `Task.isCancelled` guard in `scheduleReconnect`, and returns without sending),
  then `send(.stopTapped)` to cancel the new connect, `finishEffects`,
  `expectNoReceivedActions`. With cancellation working, no `.reconnect` is ever enqueued;
  a regression that fails to cancel the old backoff would enqueue `.reconnect` after the
  release and fail the test. (The prior wording hand-set `phase .failed` /
  `reconnectAttempt 2` with no in-flight backoff and an immediate `sleep`, so the
  "no stray `.reconnect`" assertion passed even if nothing was cancelled.)

`DanCamTests/Features/Recording/RecordingFeatureTests.swift` (modify):
- `onAppearSeedsRecordingStateFromHealth` -> `statusObservedSeedsRecordingState`:
  `.statusObserved(recording: true)` -> `.recording`.
- `startTapped*` / `stopTapped*`: drop the trailing `receive(.statusResponse(...))`;
  assert the optimistic transition only.
- New `statusObservedIgnoredWhileStarting`: from `.starting`,
  `.statusObserved(recording: false)` stays `.starting`.
- `recordingFailureMapsToFailedState`, `cancellationSendsNoAction*` unaffected.

`DanCamTests/Features/Home/HomeCoordinationTests.swift` (modify): add `RefreshGate`
coverage (behavioral, the bug this prevents). Assert `handle(.loaded([]))` returns
`false` when `begin()` was never called (no spurious end before a refresh starts);
after `begin()`, `handle(.loading)` returns `false` and the subsequent `handle(.loaded)`
returns `true` (ends only on the network result, not on intermediate states); after
`begin()`, `handle(.failed("x"))` returns `true`; and once a result has ended the gate
it stays disarmed (a following `handle(.loaded)` returns `false`) until the next
`begin()`. Existing `shouldRefreshClips` cases unchanged.

`DanCamTests/Features/Health/HealthTelemetryTests.swift` (modify): pass
`StatusResponse?` instead of `StatusFeature.State` (loaded sample -> real rows; `nil`
-> placeholder rows).

Delete `DanCamTests/Features/Status/StatusFeatureTests.swift`.

Not unit-tested (UIKit render, consistent with `fern` not testing `renderClips`): the
nav-pill install/re-parent, `SceneDelegate` lifecycle, the `UIRefreshControl` wiring
itself (the `RefreshGate` *logic* is unit-tested above; only the control plumbing is
not), the clip-retention change, and the dropped error pill -- covered by manual
verification.

---

## Commit slices (Conventional Commits; each independently green)

Stage explicit paths only -- the working tree has unrelated dirty files
(`DanCam.xcscheme`, `docs/roadmap.md`, `plans/wip/`). Never `git add .`.

1. `fix(app): auto-reconnect live preview after stream drop` -- `PreviewFeature`
   struct state + back-off reschedule + `.reconnect`/`.reconnectNow`,
   `PreviewViewController` render/`reconnect()`, updated `PreviewFeatureTests`. The
   standalone bug fix.
2. `feat(app): add connection monitor poll + coordination` -- `ConnectionFeature`,
   `ConnectionCoordination`, `ConnectionResumable`, + both new test files. Pure, not
   yet wired.
3. `feat(app): show global connection pill in nav bar` -- `ConnectionIndicatorCoordinator`,
   `SceneDelegate` (monitor + delegate + `start`/`stop`/foreground resume), Home
   conforms to `ConnectionResumable` and observes the monitor, drops its `statusStore`,
   reseeds `RecordingFeature` via `.statusObserved`; `RecordingFeature` change +
   updated `RecordingFeatureTests`; Health repoint + `HealthTelemetry` signature +
   `HealthTelemetryTests`. The cohesive "flip the switch" slice.
4. `feat(app): pull-to-refresh and in-place disconnect on home` -- `UIRefreshControl`
   on the clips table, stop blanking clips on `.failed`, remove the un-debounced
   "Can't reach camera" pill.
5. `chore(app): remove unused StatusFeature poll` -- delete
   `Features/Status/StatusFeature.swift` + `StatusFeatureTests.swift` (all references
   removed in slice 3).
6. `docs(app): add connection-monitor ADR; record opal app slice` -- add app ADR
   `app/docs/design/04-2026-06-26-connection-monitor-and-indicator.md` (Status:
   Accepted) capturing the durable decisions this slice settles: connection state is an
   **app-scoped `/v1/status` monitor** (the single reader, replacing the three per-screen
   readers), surfaced as an **ambient nav-bar pill with no full-screen takeover**, with
   **asymmetric debounce** (fail-slow N=3 / recover-fast 1) and **`ConnectionResumable`**
   recovery driven by foreground + the `disconnected -> connected` edge; Alternatives
   considered: `NWPathMonitor` connectivity, a parallel heartbeat alongside the existing
   readers, and a debounced full-screen takeover. List it under "Current" in
   `app/AGENTS.md` (`app/AGENTS.md#Design decisions (ADRs)`). Then note in
   `docs/roadmap.md` that the app-side connection robustness landed (persistent
   indicator, missed-heartbeat offline detection, auto-recovery) while `opal` stays
   unchecked pending `NEHotspotConfiguration` auto-rejoin + resumable pulls. Folds in
   the existing uncommitted `docs/roadmap.md` edit -- stage that path explicitly.

This planning doc commits separately as `docs: plan opal app connection UX`.

This slice adds one app ADR (`04-2026-06-26-connection-monitor-and-indicator.md`,
seq = highest app ADR + 1) per the `AGENTS.md` ADR convention -- the connection model
is a durable architecture decision, not just a plan detail, so it is recorded rather
than left optional. `just adr-check` validates the new ADR's seq/date. No existing ADR
is superseded: these decisions are additive (a new feature within the existing TEA core
and transport), not a reversal of ADR 02 or 03.

---

## Verification

- `just app-test` green.
- Manual against the mock Pi (`just raspi-mock`,
  `DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080`):
  - Launch -> pill reads "Connecting" then "Connected" (no fake-connected on an
    unreachable cold launch).
  - Kill the mock -> after ~3 missed polls (~4.5s) the pill flips to "Not connected",
    the clip list **stays** (not blanked), preview shows "Preview offline" but **keeps
    its last frame**.
  - Restart the mock -> pill returns to "Connected"; preview reconnects on its own;
    status/clips resume.
  - Pull down the clip list -> immediate refresh + status re-probe + preview reconnect.
  - Push Debug mid-disconnect -> the pill is present and live on Debug too (proves
    app-scoped + global install; the same path serves `lime`'s clip page later).
- Foreground test: background while streaming, foreground -> preview reconnects and
  the monitor re-probes immediately.
- Real-Pi smoke: walk out of AP range and back with the app foregrounded; confirm the
  disconnect -> reconnect edge drives recovery without any navigation or teardown;
  repeat while on a pushed page.

---

## Explicitly deferred

- **`NEHotspotConfiguration` auto-rejoin, Wi-Fi exponential back-off, resumable pull
  across drops** -- the rest of swoop `opal`. This slice uses a fixed 1.5s heartbeat +
  preview back-off only.
- **The clip viewer VC and resumable ranged pull** -- swoop `lime`. It conforms to
  `ConnectionResumable` and inherits the pill + recovery with no connectivity changes.
- **Making the Debug/Health screen resumable** -- it shows the pill but is not
  re-kicked on recovery.
