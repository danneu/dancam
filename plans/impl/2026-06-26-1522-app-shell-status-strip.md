# Plan: App shell with persistent connection strip

## Context

Swoop `opal`'s app slice (commit `c75ed27`, ADR 04) surfaced connectivity as an
**ambient nav-bar pill** owned by `ConnectionIndicatorCoordinator`, a
`UINavigationControllerDelegate` that re-parents a single `UIBarButtonItem` across
every `didShow`. That shape has two structural weaknesses we now want to retire
before more screens land (`lime`'s clip viewer is next):

1. **The pill fights the nav bar.** It shares the right-bar-item slot with each
   screen's own controls (Home's Debug button today), and the coordinator has to
   strip-and-append one shared item on every push/pop. ADR 04 itself flags this as
   "hard or risky": *"The nav coordinator owns a reusable custom bar item and must
   re-parent it cleanly on navigation transitions."* Every new screen inherits that
   fragility.
2. **It is wedded to navigation chrome.** Connectivity is a whole-app fact, but its
   only home is the nav bar -- so it cannot grow (recording state, time-unverified,
   storage warnings are all coming) without crowding titles and buttons further.

The fix is a **root container** that owns app-wide chrome independent of the
navigation stack. `AppShellViewController` becomes the window root; it pins a fixed,
centered, noninteractive **connection status strip** below the system status area and
embeds the existing `UINavigationController` beneath it. The strip renders on every
screen for free (it is above the whole nav stack, not inside it), needs no
per-screen decoration, and gives connectivity -- and later, more status -- a stable
place to live.

The app-scoped `ConnectionFeature` monitor from ADR 04 is **unchanged and carried
forward**: it is still the sole `/v1/status` reader, still debounces disconnects
asymmetrically (fail-slow N=3, recover-fast 1), still retains last-known status, and
recovery still routes through `ConnectionResumable`. This pivot replaces only the
*indicator surface* (nav-bar pill -> shell strip) and moves the resume-edge ownership
from the deleted coordinator into the shell.

**First version is connection-only:** the strip shows exactly one of `Connecting`,
`Connected`, or `Not connected`. No other content this pass.

**Visual treatment (decided with Dan):** a neutral band on every state with a centered
pill that tints by state -- grey dot while connecting, green dot when connected, and a
red-tinted pill when disconnected. The pill reuses `StatusPillView`'s existing
`.material` / `.tinted(...)` styling exactly as Home's temp/error pills do
(`Features/Home/HomeViewController.swift#renderTempWarning` uses
`.tinted(UIColor.systemRed.withAlphaComponent(0.16))`), so the strip is noticeable
without a full-width red bar flashing on every congested-link blip. The band itself is
an opaque `.systemBackground` surface with a hairline separator -- not a second frosted
layer -- which both avoids a muddy blur-on-blur look and prevents a visible seam where
the band meets the nav bar's transparent scroll-edge appearance (see "Strip view").

Outcome: launch on any screen -> a strip reading "Connecting" then "Connected";
lose the link -> "Not connected" after the existing ~3-poll debounce, with the
screen's content untouched; regain it -> the strip flips back and the visible screen
resumes live work. Pushed screens (Debug now, `lime` later) get the strip with zero
new code.

---

## Scope

In:
- New `AppShellViewController` root container hosting a fixed
  `ConnectionStatusStripView` above an embedded `UINavigationController`; owns the
  monitor observation and the `disconnected -> connected` resume edge; forwards
  status-bar appearance to the nav stack; exposes the nav's `topViewController`.
- New `ConnectionStatusStripView` -- full-width neutral band, centered
  `StatusPillView`, noninteractive, dynamic-type aware, accessibility label = the
  visible connection caption.
- `SceneDelegate` rewired to build the shell and make it the window root; monitor
  start/stop/foreground lifecycle unchanged in behavior, foreground resume now asks
  the shell for the top VC.
- Pure `ConnectionCoordination` extended with a strip presentation mapping
  (caption + tone) and a precise reconnect-resume predicate.
- `ConnectionIndicatorCoordinator` deleted.
- ADR 05 added (supersedes ADR 04); `app/AGENTS.md` ADR list and `docs/roadmap.md`
  `opal` line updated in the same change.

Out (unchanged this pass):
- The `ConnectionFeature` monitor reducer, polling, debounce, and `lastStatus`
  retention (ADR 04, carried forward verbatim).
- Home's recording UI, preview `REC` badge, and page-local warning pills (temp /
  camera-offline) -- these stay exactly as they are; the strip replaces only the
  nav-bar connectivity pill, which Home never owned.
- Home's Debug chart button (it reclaims the right-bar slot the pill used to share).
- Preview self-heal / back-off, pull-to-refresh, `RefreshGate`, Health repoint --
  all from `opal`, untouched.
- Any Pi API, networking, store, or dependency change. No new state, no new wire
  traffic.

---

## Architecture decision

`AppShellViewController: UIViewController` is the window root. It uses standard
child-VC containment to embed the `UINavigationController` and lays the strip above
it:

- **Containment.** In `viewDidLoad`: `addChild(navigationController)`, add the nav
  controller's view then the strip as subviews, activate constraints, then
  `navigationController.didMove(toParent: self)`. (`addChild` must precede inserting the
  child's view; `didMove(toParent:)` must follow it -- the same idiom Home uses for its
  embedded preview VC.) The two views don't overlap, but add the strip last so it is
  unambiguously on top if a layout ever rounds to a 1px overlap.
- **Layout.** Strip top pinned to `view.topAnchor` (the band fills the status-bar /
  Dynamic-Island region), leading/trailing to `view`. The pill *inside* the strip is
  pinned to the strip's own `safeAreaLayoutGuide.topAnchor`, so safe-area insets
  propagate into the subview and the pill renders *below* the status bar while the band
  sits *behind* it -- no separate background view needed. Nav controller view top
  pinned to the strip's bottom, leading/trailing/bottom to `view`. Because the strip's
  bottom always lands at/below the shell's safe-area top, the embedded nav view's own
  `safeAreaInsets.top` resolves to 0, so its nav bar sits flush against the strip with
  no phantom status-bar gap and no `additionalSafeAreaInsets` tweak. Bottom/side insets
  still propagate, so Home's existing safe-area bottom pin is unaffected.
- **Status-bar appearance.** Because the shell -- not the nav controller -- is now
  root, iOS queries the shell. Override `childForStatusBarStyle` and
  `childForStatusBarHidden` to return the embedded `navigationController`: delegating to
  it reproduces today's behavior verbatim, since the nav controller was the window root
  until now and already owned this decision. (A `UINavigationController` does not forward
  `preferredStatusBarStyle` to its top VC by default -- it derives the style itself --
  but that is moot here: no screen sets a per-screen status-bar style today, and this
  change adds none.) Large titles / bar style are internal to the nav controller and
  need no forwarding. Forward `childForHomeIndicatorAutoHidden` too for parity --
  harmless and future-proof, though nothing hides the home indicator today.
- **Monitor + resume.** The shell owns one `StoreObservation` on the injected
  monitor. On each state change it (a) reconfigures the strip from the pure
  presentation mapping and (b) if `ConnectionCoordination.shouldResumeLiveWork(from:
  previous, to: next)` is true, calls
  `(navigationController.topViewController as? ConnectionResumable)?.resumeLiveWork()`.
  This is the same edge the deleted coordinator drove; the full
  "only `disconnected -> connected`" policy now lives in the pure layer instead of an
  inline `previous == .disconnected` guard.
- **Top-VC access.** Expose `var topViewController: UIViewController?` (returns
  `navigationController.topViewController`) so `SceneDelegate`'s foreground resume
  reaches the visible screen without reaching through `window.rootViewController`.

Rejected alternatives: keeping the nav controller as root and floating the strip as a
window/overlay subview (fragile under rotation and safe-area changes, and still not a
real container for future chrome); a full-screen disconnected takeover (rejected in
ADR 04 and still wrong -- destroys context on normal car Wi-Fi churn).

The Xcode project uses `PBXFileSystemSynchronizedRootGroup`, so adding
`AppShellViewController.swift` / `ConnectionStatusStripView.swift` and deleting
`ConnectionIndicatorCoordinator.swift` need no `.pbxproj` edits (confirm at impl time
as `fern`/`opal` did).

---

## Implementation (`app/DanCam/DanCam/`)

### 1. Extend the pure layer: `Features/Connection/ConnectionCoordination.swift`

Replace the two existing helpers with a strip presentation mapping plus a precise
resume predicate (the old `didReconnect` and standalone `caption(for:)` were only used
by the now-deleted coordinator, so this is a clean replace, not an addition layered on
top):

```swift
nonisolated enum ConnectionCoordination {
    enum Tone: Equatable { case neutral, positive, negative }

    struct StripPresentation: Equatable {
        let caption: String
        let tone: Tone
    }

    static func presentation(for connectivity: ConnectionFeature.Connectivity) -> StripPresentation {
        switch connectivity {
        case .connecting:   StripPresentation(caption: "Connecting", tone: .neutral)
        case .connected:    StripPresentation(caption: "Connected", tone: .positive)
        case .disconnected: StripPresentation(caption: "Not connected", tone: .negative)
        }
    }

    // Resume visible live work ONLY on the disconnected -> connected edge.
    // First-contact connecting -> connected is handled by each screen's own appear,
    // so it must NOT trigger a resume.
    static func shouldResumeLiveWork(
        from previous: ConnectionFeature.Connectivity,
        to next: ConnectionFeature.Connectivity
    ) -> Bool {
        previous == .disconnected && next == .connected
    }
}
```

`Tone` is presentation-semantic (not a mirror of `Connectivity`) so the strip maps
`Tone -> UIColor/BackgroundStyle` trivially and the mapping stays pure and testable.

### 2. New view: `Views/ConnectionStatusStripView.swift`

A `final class ConnectionStatusStripView: UIView` (lives next to `StatusPillView`,
which it reuses). Programmatic, no XIB, `@available(*, unavailable) required init?(coder:)`
per the project convention.

- **Band fill:** opaque `backgroundColor = .systemBackground` with a 1px (`1/scale`)
  `.separator` hairline pinned along the bottom edge. Opaque -- not a frosted
  `UIVisualEffectView` -- so it neither stacks blur-on-blur against a material pill nor
  leaves a seam against the nav bar's transparent scroll-edge appearance (which paints
  `.systemBackground`); status bar -> band -> nav bar reads as one continuous surface.
- **Centered, content-sized pill:** one `StatusPillView` child; `centerX` to the band,
  vertical pinned `pill.top == safeAreaLayoutGuide.topAnchor + 6` and
  `pill.bottom == bottomAnchor - 6` so the band's height = statusBarInset + padding +
  pillHeight and grows with dynamic type (the pill's caption label drives it; add a
  low-priority `heightAnchor >= 28` floor to avoid first-layout collapse). Clamp width
  with `pill.leading >= safeAreaLayoutGuide.leading + 16` and
  `pill.trailing <= safeAreaLayoutGuide.trailing - 16` so large type truncates inside
  the pill (its label is already `.byTruncatingTail`) rather than overflowing.
- **Noninteractive + accessible:** `isUserInteractionEnabled = false` on the band, no
  gestures. Do NOT set the band itself as an accessibility element -- leave the inner
  `StatusPillView` as the element (`isAccessibilityElement = true`, `accessibilityLabel`
  already tracks the caption). `isUserInteractionEnabled = false` stops hit-testing but
  does not remove the pill from VoiceOver, so the strip reads its connection caption as
  one non-actionable element.
- `func configure(_ presentation: ConnectionCoordination.StripPresentation)` maps tone
  to the pill's dot color + background, then calls `pill.configure(caption:dotColor:backgroundStyle:)`:
  - `.neutral`  -> dot `.secondaryLabel`, background `.material`
  - `.positive` -> dot `.systemGreen`, background `.material`
  - `.negative` -> dot `.systemRed`, background `.tinted(UIColor.systemRed.withAlphaComponent(0.16))`
  (Same `tinted(..0.16)` recipe Home already uses for its warning pills.)

### 3. New container: `App/AppShellViewController.swift`

`final class AppShellViewController: UIViewController` per the design in
"Architecture decision":

```swift
init(navigationController: UINavigationController,
     monitor: Store<ConnectionFeature.State, ConnectionFeature.Action, AppDependencies>)
```

- Stores the nav controller, the monitor, the `ConnectionStatusStripView`, a
  `StoreObservation?`, and `previousConnectivity: ConnectionFeature.Connectivity?`.
- `viewDidLoad`: containment + constraints (see Architecture decision); start the
  observation:
  ```swift
  observation = monitor.observe { [weak self] state in self?.render(state) }
  ```
  `Store.observe` fires the observer **synchronously on subscribe** with the current
  state (`.connecting` at launch) and no prior value -- so `previousConnectivity` stays
  `nil` on that first emission and the resume check below is skipped, exactly as the old
  coordinator's nil-guarded `currentConnectivity` did. Hold `observation` for the
  shell's (window) lifetime; `StoreObservation` does not auto-cancel.
- `render(_:)`: `strip.configure(ConnectionCoordination.presentation(for: state.connectivity))`;
  then `if let previous = previousConnectivity,
  ConnectionCoordination.shouldResumeLiveWork(from: previous, to: state.connectivity)`
  -> `(navigationController.topViewController as? ConnectionResumable)?.resumeLiveWork()`;
  set `previousConnectivity = state.connectivity`. A non-conforming top VC (Debug today)
  is a safe no-op, identical to today.
- `override var childForStatusBarStyle: UIViewController? { navigationController }`,
  same for `childForStatusBarHidden`, and `childForHomeIndicatorAutoHidden` for parity.
- `var topViewController: UIViewController? { navigationController.topViewController }`
  (used by `SceneDelegate`'s foreground resume).

### 4. `App/SceneDelegate.swift` (modify)

- Replace the `indicatorCoordinator` stored property with `private var shell:
  AppShellViewController?`.
- `scene(_:willConnectTo:)`: build `connectionStore`, `HomeViewController(dependencies:
  monitor:)`, and the `UINavigationController` exactly as today; then
  `let shell = AppShellViewController(navigationController: navigationController,
  monitor: connectionStore)`; `window.rootViewController = shell`. Order the loads so
  every observer is live before the first poll: `window.makeKeyAndVisible()` loads the
  shell's view (running `viewDidLoad` -> containment -> the shell's monitor
  observation), then `home.loadViewIfNeeded()` (kept verbatim from today, so Home's own
  `connectionObservation` is live), then `connectionStore.send(.start)` **after** both.
  Drop the coordinator creation and `attach(to:)`; the shell no longer sets
  `navigationController.delegate` at all (one fewer interaction -- verify the Debug
  back-swipe still works).
- `sceneWillEnterForeground(_:)`: `connectionStore?.send(.start)` and
  `(shell?.topViewController as? ConnectionResumable)?.resumeLiveWork()`.
- `sceneDidEnterBackground(_:)`: `connectionStore?.send(.stop)` (unchanged).
- Delete the private `topViewController()` helper that reached through
  `window.rootViewController as? UINavigationController`; the shell owns that now.

### 5. Delete `App/ConnectionIndicatorCoordinator.swift`

All references are in `SceneDelegate` (removed above). The pill view (`StatusPillView`)
stays -- it is still used by Home's pills and reused inside the strip.

### 6. `HomeViewController` -- no functional change

Home already conforms to `ConnectionResumable`, observes the monitor for its own
temp/camera-offline pills + recording seed (`renderConnection`), keeps its Debug
button, preview, REC badge, and clips table. None of that changes. The only thing
Home loses is the *nav-bar* connectivity pill, which it never owned -- the deleted
coordinator did. Verify after the rewire that Home's right-bar slot still shows only
the Debug button.

---

## ADR / docs (same change)

- **Add `app/docs/design/05-2026-06-26-app-shell-status-strip.md`** (Status:
  Accepted), shape per the root ADR convention (Title / Status / Context / Decision /
  Consequences / Alternatives considered). Because it supersedes ADR 04 -- which
  bundled the monitor *and* the indicator -- ADR 05 must be self-contained: restate
  the carried-forward decisions (app-scoped `/v1/status` monitor as the sole reader,
  asymmetric debounce, retained `lastStatus`, `ConnectionResumable` recovery) and then
  record the pivot: connectivity is surfaced by a **persistent shell-owned status
  strip in a root container**, not a nav-bar pill. Decision covers the neutral-band /
  tinted-pill treatment and the strip being connection-only for now. Consequences must
  record the cost honestly, not just the upside: the strip claims permanent top chrome
  (roughly a pill's height plus padding) above the nav bar on every screen -- vertical
  budget the nav-bar pill consumed zero of, and not free on the preview-dominant Home
  screen. That is the accepted tradeoff, paid down by retiring ADR 04's per-screen
  re-parenting fragility and by giving the coming status growth (recording state,
  time-unverified, storage warnings) a stable home instead of crowding titles and
  buttons. Alternatives considered: the nav-bar pill (ADR 04, reversed -- re-parenting
  fragility + nav-bar contention), a window-overlay strip (fragile under
  rotation/safe-area), and a full-screen takeover (still rejected).
- **Mark ADR 04 `Superseded by 05-2026-06-26-app-shell-status-strip.md`** (status line
  only; body untouched per append-only history).
- **`app/AGENTS.md`** "Design decisions (ADRs)" list: update the ADR 04 entry to note
  it is superseded, and add the ADR 05 entry.
- **`docs/roadmap.md`** `opal` swoop: change "persistent nav-bar indicator" to the
  persistent connection status strip so the roadmap matches the pivot (AGENTS.md: a
  pivot that isn't written down is the next trap). Stage that path explicitly.
- `just adr-check` validates the new seq/date (05 dated 2026-06-26 keeps the
  non-decreasing date order).

---

## Tests (Swift Testing)

Two layers get coverage: the pure presentation/predicate mapping, and the shell's
resume-routing behavior -- the responsibility this pivot migrates out of
`ConnectionIndicatorCoordinator`, so it must not regress silently. The strip's *visual*
rendering (tone -> color, band fill) and the shell's *layout / containment* stay
manual, consistent with the project not unit-testing view rendering, `SceneDelegate`,
or `renderClips`. The `ConnectionFeature` reducer is unchanged, so its tests need no
edits.

**`DanCamTests/Features/Connection/ConnectionCoordinationTests.swift` (rewrite):**
- `presentationMapsCaptionAndTone`: assert `presentation(for:)` returns
  `("Connecting", .neutral)`, `("Connected", .positive)`, `("Not connected", .negative)`
  for the three connectivity states (covers caption + tone in one table).
- `resumesLiveWorkOnlyFromDisconnected`: table-drive `shouldResumeLiveWork(from:to:)` --
  `true` only for `(.disconnected, .connected)`; `false` for `(.connecting, .connected)`
  (first-contact connect must NOT resume), `(.connected, .connected)`,
  `(.connected, .disconnected)`, `(.disconnected, .disconnected)`,
  `(.connecting, .disconnected)`.

This replaces the old `didReconnectOnlyWhenEnteringConnected` /
`captionsMatchConnectivityStates` tests, whose subjects no longer exist.

**`DanCamTests/App/AppShellViewControllerTests.swift` (new):** a `@MainActor` suite
asserting the shell routes recovery to the visible screen on the right edge -- the
behavior moved here from the deleted coordinator, and the one thing an implementation
could silently break while still passing the pure-predicate test above.
(`DanCamTests/App/` already exists -- `AppConfigurationTests.swift` lives there -- and
the test target uses the same synchronized-group setup, so a new file needs no
`.pbxproj` edit; confirm at impl time.)

A fake top VC records resume calls:

```swift
private final class ResumeSpy: UIViewController, ConnectionResumable {
    private(set) var resumeCount = 0
    func resumeLiveWork() { resumeCount += 1 }
}
```

Build a real `Store<ConnectionFeature.State, ConnectionFeature.Action, AppDependencies>`
whose `status.fetch` hangs (gated, never returns) with `sleep: { _ in }`, so the only
connectivity transitions are the ones the test drives and a scheduled `.poll` can never
sneak one in; root a `UINavigationController` at a `ResumeSpy`; construct the shell;
`shell.loadViewIfNeeded()` runs `viewDidLoad` and subscribes (initial synchronous
`.connecting` emission, `previousConnectivity` nil -> no resume). Drive connectivity by
sending `.statusResponse` results directly through the store -- the same action surface
`ConnectionFeatureTests` drives -- and assert against `spy.resumeCount`:

- `resumesTopVCOnReconnectEdge`: three `.statusResponse(.failure(...))` ->
  `.disconnected` (assert `resumeCount == 0` -- connect/disconnect transitions must not
  resume), then one `.statusResponse(.success(...))` -> `.connected`; assert
  `resumeCount == 1` (fired exactly once, on the recovery edge).
- `firstContactConnectDoesNotResume`: from the launch `.connecting`, one
  `.statusResponse(.success(...))` -> `.connected`; assert `resumeCount == 0` (the
  nil-previous guard -- first connect is the screen's own appear, not a resume).

If the production `Store` delivers observer callbacks asynchronously rather than
synchronously within `send`, add a main-actor hop (`await Task.yield()`) between drive
and assertion; the hung fetch keeps the result deterministic either way.

---

## Verification

1. `just app-test` green (the two rewritten coordination tests, the new
   `AppShellViewControllerTests`, and the untouched `ConnectionFeature` suite).
2. `just app-build` green (clean compile after the file add/delete; confirms the
   `PBXFileSystemSynchronizedRootGroup` assumption).
3. `just adr-check` green (ADR 05 seq/date; ADR 04 superseded line still valid format).
4. Manual against the mock Pi (`just raspi-mock`,
   `DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080`):
   - Launch -> strip reads "Connecting" then "Connected"; the band sits directly below
     the status bar, above the nav bar; Home's title + Debug button render normally
     below it; preview/clips/record controls unaffected.
   - Kill the mock -> after the existing ~3-poll debounce the strip flips to
     "Not connected" with the red-tinted pill; Home keeps its last frame and clip list
     (no blanking -- that behavior is `opal`'s and unchanged).
   - Restart the mock -> strip returns to "Connected"; the `disconnected -> connected`
     edge fires `resumeLiveWork()` so preview reconnects and clips refresh.
   - Push Debug mid-disconnect -> the strip is present and live above the Debug screen
     too (proves the root-container global install; same path will serve `lime`'s clip
     viewer for free).
   - Background while streaming, foreground -> monitor re-probes and the visible
     screen resumes (via `SceneDelegate` foreground hook through `shell.topViewController`).
   - Rotate the device on Home and on Debug -> the strip stays pinned below the status
     area and the nav stack lays out correctly (sanity-check the containment +
     safe-area assumption).
   - VoiceOver: focus the strip -> it reads the current connection caption as one
     element and is not an actionable control.
5. Real-Pi smoke (carried from `opal`): walk out of AP range and back with the app
   foregrounded; confirm the disconnect -> reconnect edge drives recovery with no
   navigation or teardown; repeat on a pushed page.

---

## Commit slices (Conventional Commits; each independently green)

Stage explicit paths only -- the working tree has unrelated dirty files
(`DanCam.xcscheme`, `plans/wip/`). Never `git add .`.

1. `feat(app): replace nav-bar pill with app-shell connection strip` -- the whole code
   pivot in one green commit: rewrite `ConnectionCoordination` (`presentation(for:)` +
   `shouldResumeLiveWork`, dropping `caption(for:)` / `didReconnect`), add
   `ConnectionStatusStripView` and `AppShellViewController`, rewire `SceneDelegate`,
   delete `ConnectionIndicatorCoordinator`, rewrite `ConnectionCoordinationTests`, and
   add `AppShellViewControllerTests`. These cannot split cleanly: the coordinator is the
   sole caller of the dropped pure helpers, so a "pure refactor first" commit would
   leave the still-present coordinator referencing deleted symbols and fail to compile.
   Per AGENTS.md (no compatibility shims) we delete-and-replace rather than keep the old
   helpers alive for one intermediate commit.
2. `docs(app): record app-shell status strip ADR; supersede ADR 04` -- add ADR 05,
   mark ADR 04 superseded, update `app/AGENTS.md` ADR list and the `docs/roadmap.md`
   `opal` line.

This planning doc commits separately as `docs: plan app-shell status strip`.

---

## Risks / confirm at implementation time

- **Nav-bar seam, visually.** The mechanism is understood (opaque band + no
  `additionalSafeAreaInsets`; nav view's top safe-area inset resolves to 0). Still
  eyeball the status-bar -> band -> nav-bar boundary on Home (table scrolled to top, so
  the nav bar is in its transparent scroll-edge state) and on the pushed Debug screen
  to confirm the hairline reads as one continuous surface and there is no phantom gap.
- **Interactive pop gesture / transitions.** The strip sits above the nav stack, never
  overlaps `nav.view`, and doesn't intercept touches (`isUserInteractionEnabled =
  false`); the shell also no longer sets the nav delegate. So swipe-back and push/pop
  animations should be unaffected -- verify the Debug back-swipe once in the simulator.
- **Rotation.** All constraints are against `safeAreaLayoutGuide`, so landscape (top
  inset -> ~0, side insets appear) reflows automatically; no `viewWillTransition`
  override. Sanity-check on Home and Debug.

## Implementation notes

- Named the shell's stored child nav controller `embeddedNavigationController` because
  `UIViewController` already exposes a `navigationController` property.
