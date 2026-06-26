# ADR: app shell status strip

- **Status:** Superseded by 06-2026-06-26-domain-root-store-and-scoped-observation.md
- **Date:** 2026-06-26
- **Owner:** app
- **Related:** root `AGENTS.md`; `app/AGENTS.md`;
  `app/docs/design/02-2026-06-22-app-pi-transport-and-api.md`;
  `app/docs/design/03-2026-06-24-app-ui-architecture.md`;
  `app/docs/design/04-2026-06-26-connection-monitor-and-indicator.md`

## Context

ADR 04 established one scene-scoped `ConnectionFeature` store as the app's shared
connection truth, but it surfaced that truth as a navigation-bar pill owned by a
`UINavigationControllerDelegate`. The coordinator reused one custom bar item and
re-parented it across navigation transitions.

That shape worked for the first home screen, but it made connectivity compete with
screen-owned navigation buttons and tied whole-app status to navigation chrome. More
status surfaces are coming: recording state, time verification, storage warnings, and
clip pull state. Those should not crowd every title and right-bar button.

The app needs a stable place for app-wide status that is independent of the navigation
stack while keeping ADR 04's monitor, debounce, retained status, and recovery behavior.

## Decision

Keep the app-scoped `ConnectionFeature` monitor from ADR 04:

- It remains the sole `GET /v1/status` reader for the scene.
- The Pi answering `/v1/status` remains the connection truth.
- Disconnects remain fail-slow: three consecutive failed status polls are required
  before the app shows "Not connected".
- Recovery remains recover-fast: one successful status poll immediately returns to
  "Connected".
- The last successful status response remains retained so screen facts can stay visible
  while the link rides out misses.
- Visible-screen recovery still routes through `ConnectionResumable` on foreground and
  on the `disconnected -> connected` edge.

Replace the navigation-bar indicator with an `AppShellViewController` root container.
The shell embeds the existing `UINavigationController` and owns a persistent
connection status strip above it. The strip is full width, fixed, noninteractive, and
visible on every screen because it is outside the navigation stack.

The first strip version is connection-only. It shows exactly one of:

- `Connecting`
- `Connected`
- `Not connected`

Use a neutral `.systemBackground` band with a bottom separator. Center a
`StatusPillView` inside the band. The pill tint carries the connection state:

- Connecting: secondary-label dot, material pill.
- Connected: green dot, material pill.
- Not connected: red dot, red-tinted pill.

Move reconnect-edge detection into pure `ConnectionCoordination` with a
`shouldResumeLiveWork(from:to:)` predicate. Only `disconnected -> connected` resumes
visible live work. First-contact `connecting -> connected` is not a resume; each screen
handles its own initial appearance.

## Consequences

Easy:

- Connectivity is global chrome, not a right-bar item attached to whichever screen is
  visible.
- Pushed screens get the strip automatically with no per-screen decoration.
- Home's right-bar slot belongs to Home again.
- Future app-wide status has a stable container instead of fighting nav titles and
  buttons.
- The reconnect-resume policy is pure and testable.

Hard or risky:

- The shell claims permanent top chrome on every screen. That costs roughly a pill's
  height plus padding above the nav bar, which the old nav-bar pill did not cost. This
  is most visible on Home, where preview height matters.
- The root view controller is no longer the navigation controller, so the shell must
  forward status-bar and home-indicator queries to the embedded nav controller.
- The shell is now responsible for monitor observation and visible-screen resume
  routing, so that behavior needs focused tests.

Mitigations:

- Keep the strip compact and connection-only for this pass.
- Use standard child-view-controller containment and safe-area constraints.
- Keep presentation mapping and resume-edge detection in `ConnectionCoordination`.
- Unit-test the shell's reconnect resume routing with a real `Store` and a spy top
  view controller.

## Alternatives considered

- **Keep the nav-bar pill from ADR 04.** Rejected: it requires custom bar-item
  re-parenting and competes with screen-owned controls.
- **Float the strip as a window overlay.** Rejected: safe-area, rotation, and
  navigation transition behavior are more fragile than a real root container.
- **Full-screen disconnected takeover.** Rejected again: it destroys context during
  normal car Wi-Fi churn. Ambient status plus in-place recovery remains the product
  shape.
