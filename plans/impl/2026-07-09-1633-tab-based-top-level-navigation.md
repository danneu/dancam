# Plan: Tab bar with Home + stubbed Settings

## Context

The app currently has a single top-level surface: `HomeViewController` inside one
`UINavigationController`, embedded in `AppShellViewController` (which owns the global
status strip -- shell per ADR 06, current dual-pill strip per ADR 21). Settings/control is a planned app responsibility
(`app/AGENTS.md` "Settings / control"), and it is a peer surface, not something to push
onto Home's stack. This change introduces tab-based top-level navigation: a
`UITabBarController` with two tabs -- **Home** and **Settings** ("Settings" being the
iOS-conventional name for a config screen). The Settings screen itself is a deliberate
TODO placeholder per request; the tab bar structure is the durable feature being built.

Notes on choices already settled:

- **Classic `viewControllers` + `UITabBarItem` API, not iOS 18+ `UITab`.** The app is
  iPhone-only, so `UITab`'s main win (iPad sidebar adaptivity) is moot, and its lazy
  view-controller-provider model fights the shell's eager delegate wiring and
  SceneDelegate's eager `loadViewIfNeeded()` of Home. Recorded as an alternative in the
  ADR.
- **The status strip stays global, above the tabs.** The tab controller drops into the
  exact layout slot the nav controller occupies today (`strip.bottomAnchor` to
  `view.bottomAnchor`), so the strip spans all tabs and the tab bar sits at the bottom.
- **SceneDelegate stays the composition root** (assembles content, passes it in); the
  shell owns container chrome (strip + tab container).

## Changes

### 1. New stub: `app/DanCam/DanCam/Features/Settings/SettingsViewController.swift`

Modeled on `HealthViewController`'s shape; conventional init, no behavior yet:

```swift
import UIKit

final class SettingsViewController: UIViewController {
    private let dependencies: AppDependencies
    private let store: AppStore

    init(dependencies: AppDependencies, store: AppStore) {
        self.dependencies = dependencies
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsViewController is programmatic.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = .systemBackground

        // TODO: Real Settings screen (recording controls, resolution, retention, time sync).
        let placeholderLabel = UILabel()
        placeholderLabel.text = "Settings coming soon"
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])
    }
}
```

Keep `dependencies`/`store` stored: the init shape is the durable per-screen contract.
No pbxproj edit needed (file-system-synchronized groups).

### 2. Rework `app/DanCam/DanCam/App/AppShellViewController.swift`

Replace the single embedded nav controller with an owned `UITabBarController`. This is
the **only** structural change: the shell's strip machinery from ADR 21 stays intact --
`strip = StatusStripView()`, the `StripCoordination.project` observation, `render(_
projection:)`, `previousLinkPhase`, and the `stripForTesting` hook are all preserved
unchanged. Only the embedded container (nav -> tab controller) and the resume-routing
target move.

- `private let embeddedNavigationController` -> `private let embeddedTabBarController: UITabBarController`.
- New init; shell wires itself as delegate of the tab controller and every tab's nav
  controller (nav logging keeps working on both stacks):

  ```swift
  init(tabs: [UINavigationController], store: AppStore) {
      embeddedTabBarController = UITabBarController()
      embeddedTabBarController.setViewControllers(tabs, animated: false)
      self.store = store
      super.init(nibName: nil, bundle: nil)
      embeddedTabBarController.delegate = self
      for tab in tabs { tab.delegate = self }
  }
  ```

- `topViewController` (used by `SceneDelegate.sceneWillEnterForeground` and by
  reconnect-resume) becomes the selected tab's top VC:

  ```swift
  var topViewController: UIViewController? {
      (embeddedTabBarController.selectedViewController as? UINavigationController)?.topViewController
  }
  ```

- `childForStatusBarStyle` / `childForStatusBarHidden` / `childForHomeIndicatorAutoHidden`
  return `embeddedTabBarController` (it forwards to its selected VC, equivalent to today).
- `viewDidLoad`/`configureViews`: same containment lifecycle and the same four
  constraints, with `embeddedTabBarController.view` in the nav controller's place
  (keep `translatesAutoresizingMaskIntoConstraints = false`).
- `render(_ projection: StripCoordination.Projection)`: keep the strip rendering
  (`strip.configure(connection: projection.connection, recording: projection.recording)`),
  the `previousLinkPhase` tracking, and the `StripCoordination.shouldResumeLiveWork(from:to:)`
  gate verbatim (ADR 21 behavior). The **only** change is that the resume call routes
  through the `topViewController` computed property instead of
  `embeddedNavigationController.topViewController` -- same policy as today (only the
  visible tab's screen resumes).
- Existing `UINavigationControllerDelegate` extension stays verbatim.
- New `UITabBarControllerDelegate` extension logging tab switches under the same
  `nav` category:

  ```swift
  extension AppShellViewController: UITabBarControllerDelegate {
      func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
          let screen = (viewController as? UINavigationController)?.topViewController ?? viewController
          Log.nav.notice("tab=\(viewController.tabBarItem.title ?? "?", privacy: .public) screen=\(String(describing: type(of: screen)), privacy: .public)")
      }
  }
  ```

- Small testing hook, following the repo's existing `ForTesting` convention:

  ```swift
  func selectTabForTesting(_ index: Int) {
      embeddedTabBarController.selectedIndex = index
  }
  ```

### 3. Update `app/DanCam/DanCam/App/SceneDelegate.swift`

```swift
let homeViewController = HomeViewController(dependencies: dependencies, store: appStore)
let homeNavigationController = UINavigationController(rootViewController: homeViewController)
homeNavigationController.tabBarItem = UITabBarItem(title: "Home", image: UIImage(systemName: "house"), tag: 0)

let settingsViewController = SettingsViewController(dependencies: dependencies, store: appStore)
let settingsNavigationController = UINavigationController(rootViewController: settingsViewController)
settingsNavigationController.tabBarItem = UITabBarItem(title: "Settings", image: UIImage(systemName: "gearshape"), tag: 1)

let shell = AppShellViewController(
    tabs: [homeNavigationController, settingsNavigationController],
    store: appStore
)
```

`window.rootViewController = shell`, `homeViewController.loadViewIfNeeded()`, and
`appStore.send(.streamStarted)` as today. `tabBarItem` must be set on each **nav
controller** (a nav controller does not inherit its root VC's item). Plain "house" /
"gearshape" symbols -- UIKit applies the `.fill` variant on selection automatically.
Home stays eagerly loaded; Settings loads lazily on first selection (it has no live
work). `sceneWillEnterForeground` / `sceneDidEnterBackground` unchanged.

### 4. Tests: `app/DanCam/DanCamTests/App/AppShellViewControllerTests.swift`

- Mechanical: every existing test that constructs an `AppShellViewController` (the five
  strip recording-pill tests and the two reconnect tests) switches to the `tabs:`
  initializer, e.g. `AppShellViewController(tabs: [UINavigationController(rootViewController: spy)], store: store)`.
  Keep all current assertions intact -- the strip-pill assertions
  (`stripForTesting.connectionPillForTesting` / `recordingPillForTesting`) and the
  reconnect-edge assertions are both structure-insensitive and must stay. The
  `stripRecordingPillReleasesWidthWhenHidden` test builds a bare `StatusStripView` via
  `laidOutStrip`, not a shell, so it is untouched.
- New behavioral test: resume targets the **selected** tab. Build the shell with two
  `ResumeSpy`-rooted nav controllers, call `shell.loadViewIfNeeded()` (the store
  observation attaches in `viewDidLoad`, so this must precede any store send),
  `selectTabForTesting(1)`, drive `.streamFailed` then `.event(.snapshot(world))`,
  expect the first spy's `resumeCount == 0` and the second's `== 1`, then
  `store.send(.streamStopped)` after the assertions to cancel the reconnect work
  `.streamFailed` schedules -- matching the ordering the two existing tests already use.
- New behavioral test: each tab's navigation stack survives a tab switch (the core
  promise of per-tab stacks, otherwise only manually verified). Build the shell with a
  Home nav controller and a Settings nav controller, `shell.loadViewIfNeeded()`, push a
  fresh `UIViewController` onto the Home nav controller (`animated: false`), then
  `selectTabForTesting(1)` and `selectTabForTesting(0)`, and assert
  `shell.topViewController === pushed` -- Home is back on the pushed screen, not reset
  to its root. No store actions are driven, so no `.streamStopped` cleanup is needed.
- No SettingsViewController tests: it is a placeholder with no behavior; tests come
  with the real screen.

### 5. ADR + index

- New `app/docs/design/22-2026-07-09-tab-based-top-level-navigation.md` (Accepted).
  Seq 22 because ADR 21 is already taken by `21-2026-07-09-status-strip-recording-pill.md`.
  Context: single nav stack today; Settings is the first peer top-level surface;
  ADR 06 retained the shell that owns global chrome (originating in ADR 05), and ADR 21
  defines its current connection + recording dual-pill status strip. Decision: `UITabBarController`
  embedded in the shell below the global status strip; one `UINavigationController`
  per tab; shell is delegate of the tab controller and all tab nav controllers for
  `nav`-category logging; reconnect-resume routes to the selected tab's top VC;
  SceneDelegate remains the composition root and assigns tab bar items. Consequences:
  strip visible above every tab; per-tab stacks persist across switches; resume only
  reaches the visible tab (same policy as today); bottom-anchored UI follows the
  raised safe area (verified: `clipsFailureBanner` pins to
  `view.safeAreaLayoutGuide.bottomAnchor`; `clipsTableView` auto-insets).
  Alternatives: iOS 18+ `UITab` API (rejected for now: lazy provider model vs eager
  wiring, no iPad adaptivity need); tabs owned outside the shell (rejected: strip
  must stay global).
- Update the ADR list in `app/AGENTS.md`, which currently stops at ADR 20: add the
  one-line ADR 22 entry for this decision, and backfill the missing ADR 21 line
  (`21-2026-07-09-status-strip-recording-pill.md` -- the connection + recording dual-pill
  status strip) that shipped without an index entry. Match the existing style.

## Files touched

- `app/DanCam/DanCam/Features/Settings/SettingsViewController.swift` (new)
- `app/DanCam/DanCam/App/AppShellViewController.swift`
- `app/DanCam/DanCam/App/SceneDelegate.swift`
- `app/DanCam/DanCamTests/App/AppShellViewControllerTests.swift`
- `app/docs/design/22-2026-07-09-tab-based-top-level-navigation.md` (new)
- `app/AGENTS.md` (ADR index: new ADR 22 line + backfilled ADR 21 line)

## Verification

1. `just app-build` -- compiles.
2. `just app-test` -- all suites pass, including updated + new shell tests.
3. `just adr-check` -- ADR 22's filename, per-side sequence, and seq/date order validate
   (neither `app-build` nor `app-test` checks this).
4. Manual (Xcode, iOS simulator, optionally against the mock Pi): tab bar shows
   Home/Settings with house/gearshape symbols; connection strip visible on both tabs;
   Settings shows centered "Settings coming soon"; push Debug (Health) from Home,
   switch to Settings and back -- Home's stack still shows Debug; Home's failure
   banner and table content sit above the tab bar; Console shows `nav` category
   `tab=...` notices on switches and `screen=...` on pushes.
