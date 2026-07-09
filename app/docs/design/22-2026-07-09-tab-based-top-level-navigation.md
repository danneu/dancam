# ADR: tab-based top-level navigation

- **Status:** Accepted
- **Date:** 2026-07-09
- **Owner:** app
- **Related:** `05-2026-06-26-app-shell-status-strip.md`;
  `06-2026-06-26-domain-root-store-and-scoped-observation.md`;
  `21-2026-07-09-status-strip-recording-pill.md`

## Context

The app has one top-level surface today: `HomeViewController` in a single
`UINavigationController`. Settings and control are an app responsibility, but Settings
is a peer of Home rather than a destination within Home's navigation stack.

ADR 06 retained the shell introduced by ADR 05 as the owner of global app chrome. ADR
21 defines that chrome as the current connection and recording dual-pill status strip.
Adding a peer surface must preserve the strip above every screen and keep the scene's
composition in `SceneDelegate`.

## Decision

Embed a `UITabBarController` in `AppShellViewController` below the global status strip.
Give Home and Settings separate `UINavigationController` instances so each tab owns an
independent navigation stack. `SceneDelegate` remains the composition root: it builds
the root view controllers and navigation controllers, assigns each navigation
controller's tab bar item, and passes both tabs into the shell.

The shell is the delegate of the tab controller and every tab's navigation controller,
and logs tab selections and navigation transitions under the `nav` category. The
shell's visible `topViewController` is the selected tab's top view controller.
Reconnect recovery routes only to that visible screen, preserving the existing policy
while making it tab-aware.

Keep Home eagerly loaded because scene startup begins its live work. Load the Settings
placeholder lazily on first selection because it has no live work. Use the classic
`viewControllers` and `UITabBarItem` APIs.

## Consequences

Easy:

- The status strip remains visible above every tab.
- Home and Settings keep independent navigation stacks across tab switches.
- Reconnect recovery reaches only the visible tab's screen, as it did with the single
  navigation stack.
- `SceneDelegate` retains explicit ownership of app composition.

Hard or risky:

- Bottom-anchored Home UI now shares space with the tab bar.
- Every future tab navigation controller must be passed through the shell initializer
  so delegate logging remains complete.

Mitigations:

- Home's clips failure banner pins to `view.safeAreaLayoutGuide.bottomAnchor`, and its
  clips table uses UIKit's automatic content inset adjustment, so both stay above the
  tab bar.
- Shell tests cover selected-tab reconnect routing and preservation of a pushed screen
  across tab switches.

## Alternatives considered

- **Use the iOS 18+ `UITab` API.** Rejected for now. Its lazy view controller provider
  conflicts with the shell's eager delegate wiring and Home's eager startup loading,
  while its iPad sidebar adaptivity does not benefit this iPhone-only app.
- **Own tabs outside the shell.** Rejected. The strip is global chrome and must remain
  above all peer surfaces.
