# Plan: Refactor pull-to-refresh (Home + Debug)

## Context

Pull-to-refresh on the app today is confusing and unpolished:

- **Home** only lets you pull-to-refresh from inside the clips list. The whole top
  region (live preview, status pills, record button, "Recent clips" header) lives in a
  fixed, non-scrolling `UIStackView`, so a pull-down over the preview does nothing. The
  gesture people instinctively reach for at the top of the screen is dead.
- The Home refresh spinner is **theater**: `refreshPulled` calls `store.send(.manualRefresh)`
  and then `refreshControl.endRefreshing()` synchronously on the same run-loop turn, so the
  spinner stops instantly and never reflects the real `/v1/clips` fetch. It also
  unconditionally tears down and rebuilds the live preview (`previewViewController.reconnect()`),
  causing a visible "Connecting" flash even when the preview was streaming fine. Refresh
  failures are invisible -- Home observes only `\.clips.clips`, never `\.clips.status`.
- **Debug** exposes a manual "Reload" button instead of the conventional pull-to-refresh.

Goal: make pull-to-refresh feel like a conventional, polished iOS app. Refresh should be
reachable from anywhere on Home, honest (spinner tracks real completion), and an
**idempotent re-sync** -- reload the on-screen content, and reconnect live connections
only if they've actually dropped -- never a destructive reset. Replace Debug's Reload
button with pull-to-refresh.

### Decisions locked with the user
- **Home becomes a single scroll surface**; the live preview scrolls with the content
  (Option A). Reachable-from-anywhere pull-to-refresh is native, no custom gesture code.
- **Record/Stop button moves to a pinned bottom toolbar** (removed from its current spot).
- **Refresh semantics = idempotent re-sync**: always reload the on-screen content;
  reconnect the preview and the `/v1/events` SSE stream only if they are currently dropped.
  Reuse the app's existing recovery paths rather than a new "reset" path.
- **Spinner tracks the primary content fetch** (clips on Home, health on Debug). Preview /
  stream reconnects proceed in the background, surfaced by their own existing UI (preview
  status pill, `ConnectionStatusStripView`).

The app is UIKit on a bespoke TEA architecture (pure static reducers + `@MainActor Store` +
`Effect` closures; DI via `AppDependencies` struct-of-closures). Tests are Swift Testing +
a custom TCA-style `DanCamTests/Support/TestStore.swift`.

---

## Part 1 -- Home: single scroll surface + pinned record toolbar

All in `Features/Home/HomeViewController.swift` unless noted. Chosen approach: **hoist the
fixed top region into `clipsTableView.tableHeaderView`** and keep the existing
`UITableViewDiffableDataSource` / prefetch / pagination / live-tick / empty-state machinery
untouched. Rejected the `UICollectionView` compositional-layout rewrite: the app has zero
collection-view precedent and it would force reimplementing four pieces of working,
unit-tested machinery for no required benefit (no sticky header, no grid).

### 1a. Move the top region into a scrolling table header
- Add `headerContainer = UIView()` and `headerStack = UIStackView()` (vertical, spacing 12).
  `headerStack` arranges `[previewViewController.view, statusPillsStack, clipsHeaderLabel]`
  (the record button leaves this stack -- see 1c).
- In `configureViews`: delete the old outer `stack` and the `recordButtonRow` container +
  its constraints; delete the `clipsTableView.heightAnchor >= 160` constraint (the table
  now fills the screen). Pin `headerStack` to `headerContainer.layoutMarginsGuide` (to keep
  the preview's side inset aligned with `ClipThumbnailCell` content margins); give
  `headerContainer` a top layout margin (12) to replace the old `stack.topAnchor` inset.
- Keep unchanged and travelling with the preview into the header: the `recPill` "REC"
  overlay constraints and the preview aspect constraint (`height == width * 0.75`).
- Pin `clipsTableView`: top to `view.safeAreaLayoutGuide.topAnchor`, leading/trailing to
  `view` edges (full width; cells own their margins), bottom to `view.bottomAnchor` (full
  view bottom, not safe-area bottom -- see 1d). Set `clipsTableView.tableHeaderView = headerContainer`.
- Set `clipsTableView.alwaysBounceVertical = true` (where the refresh control is attached).
  **Required**: with the preview/header present but zero clips (first run / empty), the table
  content can be shorter than the viewport, and `alwaysBounceVertical` defaults off -- without
  it the surface won't bounce and pull-to-refresh is unreachable, defeating the core goal.
- **Preserve the child-VC lifecycle**: `addChild(previewViewController)` still runs before
  `configureViews()` and `previewViewController.didMove(toParent:)` after it, in `viewDidLoad`.
  Containment is independent of where the view sits, so hosting the preview inside the header
  is fine.

### 1b. Size the table header explicitly (`tableHeaderView` ignores Auto Layout for its own height)
Add `sizeHeaderToFit()`:
- Set `header.frame.size.width = clipsTableView.bounds.width` first (so the `0.75*width`
  preview and the wrapping "Recent clips" label resolve against real width), then measure
  with `systemLayoutSizeFitting(width, .fittingSizeLevel)`.
- Only re-assign `tableHeaderView` when `abs(currentHeight - fittingHeight) > 0.5` -- this
  guard is the loop-breaker (re-seating schedules another layout pass; on the next pass the
  height already matches, so it no-ops).

Call it from an overridden `viewDidLayoutSubviews()` (covers first layout, width change,
rotation). **Gate the actual `systemLayoutSizeFitting` measurement** so it does not re-run on every
layout pass: keep `lastFittedWidth` and a `needsHeaderRefit` flag, and early-return unless the
fitting width changed **or** `needsHeaderRefit` is set. For Dynamic Type, register with the modern
trait API in `viewDidLoad`
(`registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { vc, _ in vc.needsHeaderRefit = true; vc.view.setNeedsLayout() }`,
mirroring `Views/ConnectionStatusStripView.swift`); clear the flag and store `lastFittedWidth` after
each measure. This preserves the Dynamic-Type re-fit at constant width (flag path) while avoiding a
per-frame `systemLayoutSizeFitting`: a streaming preview sets `imageView.image` continuously, and if
each set dirties layout and drives `viewDidLayoutSubviews`, an always-measure design would re-run the
fit every frame on a windshield-hot phone (the thermals cross-cutting principle). The `> 0.5` re-seat
guard already prevents a visual loop, but not the wasted measurement -- the width/flag gate removes it.
(Confirm in the simulator with a temporary counter in `sizeHeaderToFit` that it does not fire per
frame; the gate makes it robust either way.) Avoid the "self-sizing header" trick (pinning header
width to the table); it is janky mid-scroll and during refresh.

### 1c. Move Record/Stop to a pinned bottom toolbar
- The nav stack already gives us a toolbar for free: `window -> AppShellViewController ->
  UINavigationController (Home is root)`. `ConnectionStatusStripView` sits at the top of the
  shell, so a bottom toolbar cannot collide with it.
- Reuse the existing `RecordButton` view as-is: `UIBarButtonItem(customView: recordButton)`,
  centered with flexible-space bar items on each side. `renderRecording(_:)`, `recordTapped`,
  `RecordButton.apply(_:)`, and `RecordButtonStyle.from(_:)` all stay **unchanged** -- the
  button just lives in the toolbar now.
- Set `toolbarItems` in `viewDidLoad`. Show the toolbar in Home's `viewWillAppear`:
  `navigationController?.setToolbarHidden(false, animated: animated)`.
- Verify the ~46pt button height inside a ~44pt toolbar; if the capsule clips, add
  `recordButton.heightAnchor.constraint(equalToConstant: 44)`.

### 1d. Hide the toolbar on pushed screens
Each pushed screen hides the shared toolbar in its own `viewWillAppear` (robust against
push, pop, and cancelled interactive swipe-back). Add
`navigationController?.setToolbarHidden(true, animated: animated)` to:
- `Features/Health/HealthViewController.swift` (new `viewWillAppear` override)
- `Features/ClipViewer/ClipViewerViewController.swift` (new `viewWillAppear` override)

`HomeRowDiff.swift#HomeSection` stays `.main` -- the preview/pills/header are a table header,
not a table section. No change there.

---

## Part 2 -- Idempotent refresh + honest spinner

### 2a. Reducer: gated, idempotent re-sync (`Features/App/AppFeature.swift`)
Key reuse: `.streamStarted` **already** does exactly "cancel the pending reconnect backoff
timer (`.cancel(id: reconnectID)`), start a fresh stream + heartbeat, and preserve the
offline->online recovery edge." So the idempotent SSE reconnect is a reuse, not new code.

- Add action `.reconnectStreamIfOffline`:
  ```
  case .reconnectStreamIfOffline:
      if case .offline = state.link {
          return reduce(state: &state, action: .streamStarted, dependencies: dependencies)
      }
      return .none
  ```
  Gate on `.offline` only: `.online` is healthy (leave it), `.connecting` is already trying
  (leave it), `.offline` is dropped-and-waiting-for-backoff (reconnect now, short-circuit the
  backoff). Reusing `.streamStarted` guarantees the pending `reconnectID` timer is cancelled,
  so there is no double-connect.
- Change `.manualRefresh` to merge the clips refresh with the gated stream reconnect:
  ```
  case .manualRefresh:
      return .merge([
          ClipsFeature.reduce(state: &state.clips, action: .refresh, dependencies: dependencies).map(Action.clips),
          reduce(state: &state, action: .reconnectStreamIfOffline, dependencies: dependencies),
      ])
  ```

### 2b. Reducer: non-destructive preview reconnect (`Features/Preview/PreviewFeature.swift`)
`.reconnectNow` is unconditional/destructive (bumps `streamGeneration`, flips to `.connecting`,
flashes the "Connecting" pill). Add a health-gated variant:
```
case .reconnectIfNeeded:
    switch state.phase {
    case .streaming, .connecting:
        return .none                      // already live or actively connecting -> no flicker
    case .idle, .stopped, .failed:
        state.phase = .connecting
        state.reconnectAttempt = 0
        state.streamGeneration += 1
        return connectEffect(dependencies: dependencies)
    }
```
Expose `PreviewViewController.reconnectIfNeeded()` that sends `.reconnectIfNeeded` (mirrors
the existing `reconnect()` -> `.reconnectNow`). This independently nudges the preview if it
died even while SSE is healthy (they are separate connections).

### 2c. Home spinner tracks the clips fetch (`Features/Home/HomeViewController.swift`)
- Add `private var isManualRefreshing = false`.
- Observe `\.clips.status` (currently unobserved). The handler is idempotent, so it does not
  depend on observation dedupe:
  ```
  func handleClipsStatus(_ status: ClipsFeature.State.Status) {
      switch status {
      case .loading: break
      case .idle, .failed:
          if isManualRefreshing { refreshControl.endRefreshing(); isManualRefreshing = false }
      }
      clipsStatus = status
      updateClipsPresentation()   // see 2e
  }
  ```
- Rewrite `refreshPulled`: set `isManualRefreshing = true`, `store.send(.manualRefresh)`,
  `previewViewController.reconnectIfNeeded()` -- and **remove** the synchronous
  `refreshControl.endRefreshing()`. The spinner now ends when `clips.status` leaves `.loading`.
- Race note: a background `.snapshot`-driven `.load` can already have `status == .loading`
  when the user pulls. `.refresh` uses `cancelInFlight: true`, so it restarts the fetch; the
  eventual `-> .idle/.failed` transition still fires and ends the spinner. The `isManualRefreshing`
  flag keeps background loads from being mistaken for a user pull.
- **End the spinner on disappear (stranded-spinner guard)**: `viewWillDisappear` already sends
  `.clips(.onDisappear)`, which cancels the in-flight fetch **without** emitting a terminal
  `.clipsResponse` (`fetchEffect`'s cancellation path returns `nil` and sends nothing), so
  `clips.status` stays `.loading`. Home only re-issues `.load` on an SSE snapshot, not on
  `viewWillAppear` -- so a mid-pull push (tap a clip) or background on a slow 2.4 GHz link would
  bring the user back to a spinner stuck forever. In `viewWillDisappear`, right after the existing
  `.onDisappear` send, also call `refreshControl.endRefreshing()` and set `isManualRefreshing = false`.
  This restores spinner honesty: the refresh was cancelled, so the spinner stops. (Debug is immune --
  its VC + store are recreated per visit.)

### 2d. Debug spinner tracks the health fetch (`Features/Health/HealthViewController.swift`)
- Add `private var isManualRefreshing = false`. In `render(_ state:)`, when
  `isManualRefreshing && state != .loading`, call `refreshControl.endRefreshing()` and clear
  the flag.

### 2e. Surface refresh failures on Home (currently silent)
`ClipsFeature.reduce` on `.clipsResponse(.failure)` sets `status = .failed(msg)` but keeps the
existing `clips` (returns `.none`), so a failed refresh **with stale clips must still show a
signal** -- it cannot rely on the empty state. Two independent surfaces, both driven from
`updateClipsPresentation()` (called by `renderRows` and `handleClipsStatus`):

- **Inline failure banner, independent of row count**: whenever `clipsStatus == .failed(msg)`,
  show a small inline failure view carrying the message (a compact label, styled like the
  existing pills). Host it as a **VC-owned view pinned above the toolbar** -- a `clipsFailureBanner`
  added directly to `view` (not the scroll view), `translatesAutoresizingMaskIntoConstraints = false`,
  pinned leading/trailing to `view.layoutMarginsGuide` and bottom to `view.safeAreaLayoutGuide.bottomAnchor`
  (just above the record toolbar). Its height is intrinsic -- Auto Layout self-sizes it from the
  label, so there is **no** manual frame-sizing. Toggle `clipsFailureBanner.isHidden` in
  `updateClipsPresentation()`; set the label text to `msg`; hide it when status leaves `.failed`.
  **Drive the bottom inset from the layout pass, not inline**: `updateClipsPresentation()` only
  toggles `isHidden`/text (which invalidates the banner's intrinsic size and schedules a layout
  pass); the already-overridden `viewDidLayoutSubviews()` (see 1b's `sizeHeaderToFit`) then sets
  `clipsTableView.contentInset.bottom` (and `verticalScrollIndicatorInsets.bottom`) to
  `clipsFailureBanner.isHidden ? 0 : clipsFailureBanner.bounds.height`, where the banner's bounds
  are resolved, so the last clip can scroll clear of it. Reading the height inside
  `updateClipsPresentation()` would return 0 on the first `.failed` (the banner is unhidden but not
  yet laid out), leaving the last clip under the banner until the next presentation call -- keying
  the inset off `viewDidLayoutSubviews` eliminates that first-failure glitch.
  **Why not `tableFooterView`**: `tableFooterView` ignores Auto Layout for its own height (the same
  gotcha 1b documents for the header), so a footer-hosted banner would render at 0pt -- invisible --
  and would need a *second* manual `sizeFooterToFit()` path parallel to the header's. A VC-owned
  pinned banner self-sizes, is always visible (not scrolled-away below a long list -- right for an
  error), and stands up no new frame-sizing code. It also makes the 2e regression test meaningful:
  a 0pt footer would keep a presence+text seam green while showing nothing, whereas the banner seam
  is visibility-gated (see the failure-presentation test).
- **Empty-state background** (`emptyClipsBackgroundView`, set on `clipsTableView.backgroundView`):
  show "No clips yet" only when rows are empty **and** status is not `.failed` (a failed empty
  refresh shows the inline failure banner instead, not the neutral "No clips yet"). Non-empty or
  failed -> `backgroundView = nil`. This moves the existing `backgroundView = newRows.isEmpty ? ... : nil`
  assignment (today inside `renderRows`) into `updateClipsPresentation()` so both surfaces are
  driven from one place.

The common failure (camera offline) is *also* surfaced by the top `ConnectionStatusStripView`
and the "Camera offline" pill; the inline banner additionally covers a transient `/v1/clips`
failure while the SSE link is still healthy. No transient/toast infra is introduced -- a
dedicated toast stays out of scope. The empty-state background is centered in the full table
bounds (behind the tall preview header); if it reads visually too high, verify in the simulator
and, if needed, inset it below the header -- decide by looking.

---

## Part 3 -- Debug: replace Reload button with pull-to-refresh

`Features/Health/HealthViewController.swift`:
- Delete `reloadButton`, its target `reloadTapped`, and the `reloadButton.isEnabled = state != .loading`
  line in `render`.
- Attach a `UIRefreshControl` to the existing `scrollView` and set
  `scrollView.alwaysBounceVertical = true` (**required** -- the Debug content is short and
  won't bounce/pull otherwise).
- Pull handler: `isManualRefreshing = true`; `store.send(.reload)` (local health store) and
  `appStore.send(.reconnectStreamIfOffline)` (so a Debug pull also revives the SSE-driven
  telemetry when the stream is down, consistent with Home). Spinner ends via 2d.
- The now single-item horizontal `buttonStack` collapses: drop the wrapper and add
  `exportLogsButton` directly to the outer stack.
- Note (accepted): `render` clears the dual-purpose `errorLabel` on every state change, so a
  pull clears a lingering "Log export failed" message. This matches today's Reload behavior.
- Note: telemetry rows come from the shared appStore's `link.world`, not the local health
  store -- health fields refresh via `.reload`; telemetry revives via the stream reconnect.

---

## Files to modify

- `Features/Home/HomeViewController.swift` -- scroll-surface restructure (1a-1b), toolbar
  (1c), spinner + failure surfacing (2c, 2e).
- `Features/App/AppFeature.swift` -- `.reconnectStreamIfOffline`, idempotent `.manualRefresh` (2a).
- `Features/Preview/PreviewFeature.swift` -- `.reconnectIfNeeded` (2b).
- `Features/Preview/PreviewViewController.swift` -- expose `reconnectIfNeeded()` (2b).
- `Features/Health/HealthViewController.swift` -- pull-to-refresh, remove Reload, hide
  toolbar (1d, 2d, Part 3).
- `Features/ClipViewer/ClipViewerViewController.swift` -- hide toolbar on appear (1d).
- Reference only, unchanged: `Views/RecordButton.swift`, `Features/Home/HomeRowDiff.swift`.

## Tests (Swift Testing + `DanCamTests/Support/TestStore.swift`)

Behavioral, structure-insensitive reducer tests are the high-value coverage here. Use the
existing controllable-time helpers (`AsyncSignal`/`Gate`, and inject `dependencies.sleep`) that
`ClipsFeatureTests`/`HealthFeatureTests` already use for ordering/cancellation.

- **AppFeature** (extend the existing `DanCamTests/Features/App/AppFeatureTests.swift`):
  `.manualRefresh` while `.online` triggers the clips refresh but does **not** restart the stream.
  Mind `ClipsClient.noop`: it **succeeds immediately** (returns an empty `ClipsResponse`), so
  `.manualRefresh` enqueues `.clips(.clipsResponse(.success(...)))` -- a bare
  `expectNoReceivedActions()` would trip on that clips response, not on any stream action, and
  dropping the assertion to keep only `finishEffects()` would silently stop proving the stream is
  untouched. So `receive(.clips(.clipsResponse(.success(...))))` first, **then** assert no
  `.streamReconnect`/`.event` (the stream plane) -- or inject a *parked* clips client
  (`fetch` awaits `AsyncThrowingStream`-style forever / a blocked signal) so `expectNoReceivedActions()`
  cleanly isolates the stream plane. (Same noop-semantics rigor the cancellation tests apply to
  `EventsClient.noop`.)
  `.manualRefresh` while `.offline` triggers clips refresh **and** a stream (re)connect (mock
  emits a snapshot -> `receive(.event(.snapshot(...)))` -> link `.online`).
- **AppFeature reconnect cancellation (no duplicate connect)**: drive `.offline` with a *pending*
  backoff -- send `.streamFailed` so `scheduleReconnect` (id `events-reconnect`) is in flight on a
  blocked `dependencies.sleep`. Inject a **parked** events client (`connect` returns
  `AsyncThrowingStream { _ in }` -- never yields, never finishes) rather than `EventsClient.noop`:
  `noop` calls `continuation.finish()` immediately, so the fresh stream that `.streamStarted` opens
  would run to completion and send its own `.streamFailed`, scheduling an *unrelated* reconnect and
  making a bare `expectNoReceivedActions()` fail (or race) for the wrong reason. With a parked stream
  the new connect blocks, so the only thing that could ever produce a `.streamReconnect` is the old
  backoff timer. Then send `.reconnectStreamIfOffline` (which reuses `.streamStarted` and
  `.cancel(id: events-reconnect)`), release the old sleep, send `.streamStopped` to tear down the
  parked connect + heartbeat, `finishEffects()`, and only then assert **no** `.streamReconnect` was
  received. This proves the pending timer is cancelled, not just that a new connect starts.
- **`.reconnectStreamIfOffline` gating**: `.none` (no effects, no state change) when
  `.online`/`.connecting`; starts the stream when `.offline`.
- **PreviewFeature** (extend the existing `DanCamTests/Features/Preview/PreviewFeatureTests.swift`):
  `.reconnectIfNeeded` is a no-op (`.none`, no state change) when
  phase is `.streaming`/`.connecting`; when `.idle`/`.stopped`/`.failed` it sets `.connecting`,
  bumps `streamGeneration`, and connects (mock -> `receive(.frameReceived(...))`).
- **PreviewFeature reconnect cancellation (no duplicate connect)**: put phase `.failed` with a
  *pending* `scheduleReconnect` on a blocked `dependencies.sleep` (both `scheduleReconnect` and
  `connectEffect` share effect id `preview`, so the new connect must cancel the old sleep). Inject a
  **parked** preview client (`connect` returns `AsyncThrowingStream { _ in }`) rather than
  `PreviewClient.noop`: `noop` finishes immediately, so the fresh `connectEffect` would send
  `.streamFinished` and schedule an *unrelated* reconnect, defeating the assertion. With a parked
  stream the new connect blocks, isolating the test to the old sleep. Send `.reconnectIfNeeded`,
  release the old sleep, send `.stopTapped` to tear down the parked connect, `finishEffects()`, and
  only then assert **no** `.reconnect` was received.
- **ClipsFeature**: `.refresh` behaves like `.load` is already covered transitively; add an
  explicit `.refresh` case only if cheap.
- **Home VC spinner (lighter)**: expose an internal seam (e.g. `var isRefreshingForTesting: Bool
  { refreshControl.isRefreshing }`, matching existing `HealthViewController` test hooks) and
  assert `refreshPulled` leaves the spinner running (does not end synchronously) and that a
  simulated `.idle`/`.failed` status ends it. Do not build UI-automation tests -- there is no
  maintained precedent.
- **Home VC spinner ends on disappear (2c stranded-spinner guard)**: reuse the same
  `isRefreshingForTesting` seam. Invoke `refreshPulled` so the spinner is active, then call
  `viewWillDisappear(false)` and assert `isRefreshingForTesting == false` (add a small
  `isManualRefreshingForTesting` seam if we also want to assert the flag cleared directly). This is
  the dedicated regression test for the `viewWillDisappear` end-spinner guard: the guard is
  behavioral and revertible, so without its own case reverting the two guard lines leaves every
  other test green while the spinner strands again -- the manual sim step (verification #3) is not
  enough on its own. Its two sibling spinner behaviors (does-not-end-synchronously, ends-on-terminal-status)
  are already covered above, so this closes the last spinner-honesty gap.
- **Home VC failure presentation (2e regression)**: `ClipsFeatureTests` already proves the reducer
  preserves existing clips on refresh failure; add a Home VC test that the *view* surfaces it. Via a
  **visibility-gated** seam (return the message only when the banner is actually shown, e.g.
  `var clipsFailureMessageForTesting: String? { clipsFailureBanner.isHidden ? nil : label.text }`,
  plus `var isShowingEmptyStateForTesting: Bool { clipsTableView.backgroundView != nil }`), drive
  `handleClipsStatus(.failed("msg"))` and assert: (a) with rows present, the failure message is
  visible (proves failure surfaces with stale clips, not just when empty); (b) with zero rows and
  `.failed`, the failure banner shows and the empty state does **not** ("No clips yet" suppressed);
  (c) when status returns to `.idle`, the banner clears. Gating the seam on `isHidden` (not mere
  existence) is what makes this catch a silently-invisible banner -- the exact failure mode the
  VC-owned pinned banner design in 2e eliminates. Reducer-only tests cannot catch any of this.
- **Debug VC pull-to-refresh** (`HealthViewControllerTests`, using the same `@MainActor struct` +
  `loadViewIfNeeded()` + internal-seam pattern already in that file): inject a test appStore and a
  local health store, invoke the pull handler via a seam, and assert (a) the health store enters
  `.loading` and the spinner is active, (b) the spinner ends when health reaches `.loaded`/`.failed`,
  and (c) with the appStore `.offline`, the pull drives `.reconnectStreamIfOffline` (observe the
  appStore's resulting effect/state change). Guards the button->pull-to-refresh wiring against
  regression.

## Verification (end-to-end, not just tests)

1. `just app-test` -- unit suite (`DanCamTests`) green, including the new reducer tests.
2. `just app-build` / `just app-lint` -- compiles clean, no new warnings.
3. Run in the simulator (`/run`) against the mock Pi and confirm by observation:
   - Pull-to-refresh triggers from **anywhere** on Home, including a pull over the live preview,
     **and with zero clips** (short content -- confirms `alwaysBounceVertical` works, not just a
     content-taller-than-viewport bounce).
   - The spinner **stays until the clips fetch completes**, then stops (no instant flash).
   - Pull to refresh, then immediately tap a clip (or background the app) mid-fetch; on return to
     Home the spinner is **not** stuck spinning (confirms the `viewWillDisappear` end-spinner guard).
   - With a healthy preview, a pull does **not** flash the preview to "Connecting"
     (idempotent). Kill the preview/stream, pull, and confirm it reconnects.
   - Record/Stop is a centered button in a **bottom toolbar**, reflects record state, and the
     toolbar is **hidden** on the Debug and Clip-viewer screens (including cancelled swipe-back).
   - Header height is correct across rotation and a couple of Dynamic Type sizes; last clip
     clears the toolbar; empty state shows "No clips yet"; a failed refresh with **no** clips
     shows the inline failure message; and a failed refresh **with stale clips still visible**
     shows the inline failure status (does not look like a successful refresh). On that first
     stale-clips failure, scroll to the bottom and confirm the **last clip clears the failure
     banner** (proves the `viewDidLayoutSubviews`-driven inset resolved a non-zero banner height,
     not 0).
   - Debug screen: no Reload button; pull-to-refresh works (content is short -- confirm
     `alwaysBounceVertical`), spinner tracks the health fetch, "Export logs" still works.

## Risks / edge cases

- **Header sizing loop/jank / per-frame cost** -- mitigated by the `> 0.5` re-seat guard (no visual
  loop) and the width/`needsHeaderRefit` measurement gate (no per-frame `systemLayoutSizeFitting`
  during preview streaming); the flag path still covers Dynamic Type. (See 1b.)
- **Toolbar customView clip** (~46pt in ~44pt) -- verify; add a 44pt height constraint if needed.
- **Empty-state background position** behind the tall header -- the failure banner is a VC-owned
  pinned view (no positioning concern); only the "No clips yet" background is table-bounds-centered.
  Accept, or inset below the header -- decide by looking. (See 2e.)
- **Spinner scope** -- intentionally tracks clips/health only; preview + stream reconnects are
  background recovery surfaced by their own UI, so the spinner never waits on slow backoff.
- **VoiceOver order** -- Record now reads last (toolbar group) instead of between pills and the
  clips header; standard and acceptable.
- **Preview pull is a no-op while phase is a stale `.streaming`** -- `.reconnectIfNeeded` skips
  `.streaming`/`.connecting` by design (the locked "reconnect only if currently dropped" semantics).
  If a preview connection stalls without a clean error, the phase holds `.streaming` (last frame)
  until the transport `receiveIdleTimeout` flips it to `.failed`; a pull inside that window does not
  revive the frozen image. Accept -- the idle deadline bounds the stall, and pulling again after it
  trips reconnects.
- **Keep `resumeLiveWork()` on the unconditional `reconnect()`** (do **not** "improve" it to
  `reconnectIfNeeded()`). It is called from `SceneDelegate.sceneWillEnterForeground` (and
  `AppShellViewController`) on foreground resume, where the preview phase is frequently a stale
  `.streaming` (last frame, held after backgrounding) -- `reconnectIfNeeded()` would skip that and
  leave a dead preview. The unconditional reconnect is correct there; the plan's scoping is right,
  and this is the concrete reason to hold the line rather than merely "out of scope."
