# ADR: domain root store and scoped observation

- **Status:** Accepted
- **Date:** 2026-06-26
- **Owner:** app
- **Related:** root `AGENTS.md`; `app/AGENTS.md`;
  `app/docs/design/02-2026-06-22-app-pi-transport-and-api.md`;
  `app/docs/design/03-2026-06-24-app-ui-architecture.md`;
  `app/docs/design/05-2026-06-26-app-shell-status-strip.md`

> **Note (2026-06-29):** ADR 09 refines the carried-forward connection monitor by
> bounding whole status fetches and adding `StatusError.timedOut`. `/v1/status`
> remains the connection truth, and the three-strike debounce stays unchanged.

## Context

The first UIKit screens used the bespoke TEA core from ADR 03, but they owned
separate connection, recording, and clips stores in `HomeViewController`. That made the
screen a coordinator for domain rules:

- Connection status seeded recording state.
- Recording-stop transitions refreshed clips.
- Pull-to-refresh tracked a local refresh gate so the spinner could end when clips
  returned.

That coupling is not a home-screen concern. It is domain behavior that future surfaces,
including CarPlay, need without depending on the current navigation layout.

The store core also notified every observer after every action, even when state did not
change. A 1.5s status poll could wake screens that had nothing new to render, so view
controllers started carrying ad hoc diffing to protect themselves.

Preview and health are different boundaries. Preview moves JPEG frames through state at
stream rate and performs local decode gating; routing those frames through a root store
would create avoidable fan-out. Health has no current cross-domain consumers and partly
overlaps connection telemetry, so folding it into connection is a separate decision.

## Decision

Use one scene-scoped, domain-organized `AppFeature` store for the coupled app domains:
connection, recording, and clips. Its reducer composes the existing child reducers
synchronously and owns the cross-domain rules:

- Connection status changes seed or update recording state.
- Recording transitions from recording/stopping to idle refresh clips.
- The record button action routes to start or stop based on recording state.
- Manual refresh starts clips refresh and a connection poll, and stores
  `pendingManualRefresh` until the next clips success or failure.

View controllers and the app shell hold the `AppStore` and observe read-only slices.
They do not own domain stores and do not bridge one domain into another.

Extend the TEA core from ADR 03 with:

- `Effect.merge` for running multiple effects from one reducer pass.
- `Effect.map` for lifting child reducer effects into parent action space while
  preserving cancellation IDs.
- Equality-gated `Store.send`, which executes every effect but notifies observers only
  when state changes.
- Scoped keypath observation that fires immediately and then only when the observed
  `Equatable` slice changes.

Scoped observation updates its cached value before calling the observer, and store
notification iterates a snapshot of observers. Re-entrant sends are supported, including
the shell's reconnect recovery path that can call back into the same store while a
connectivity notification is in flight.

Keep preview as a separate store. Add a `streamGeneration` signal so every
connect/reconnect attempt changes state even if the preview phase stays `.connecting`;
the preview view uses that signal to reset decode state instead of relying on render
side effects.

Keep health as a separate store. The debug screen reads telemetry from the root store's
`connection.lastStatus` slice and keeps health reloads independent.

Carry forward the active shell decisions from ADR 05:

- `AppShellViewController` remains the persistent root container above the navigation
  stack.
- The shell owns the fixed connection status strip.
- Strip presentation stays connection-only through
  `ConnectionCoordination.presentation(for:)`.
- Disconnects remain fail-slow and recover-fast because connection truth still comes
  from `ConnectionFeature`.
- Visible live work resumes only on the `disconnected -> connected` edge through
  `ConnectionCoordination.shouldResumeLiveWork(from:to:)`.

The strip's data source changes from a standalone `ConnectionFeature` store to the
root store's `connection.connectivity` slice.

## Consequences

Easy:

- Domain coupling lives in one reducer and is testable without UIKit.
- Home becomes a projection over recording, clips, connection status, and manual-refresh
  interaction state.
- App shell rendering wakes only on connectivity transitions, not on every status poll.
- Health telemetry still updates on each distinct status response.
- Future screens and CarPlay can use the same app state without a home-specific
  coordination layer.

Hard or risky:

- The root store shares one effect ID namespace across connection, recording, and clips.
  Current IDs are domain-prefixed and must stay that way.
- Equality-gated observation is a core behavior change. Any effect that needs a render
  must make the relevant state change explicit.
- Re-entrant sends are now an intentional runtime behavior, so observer notification
  ordering is part of the store contract.
- Preview remains outside the root by design, so Home still nudges preview reconnects
  on pull-to-refresh and resume.

Mitigations:

- Store tests cover equality gating, scoped observation, re-entrancy, merge/map, and
  mapped cancellation.
- AppFeature tests cover record-button routing, connection-to-recording sync,
  recording-to-clips refresh, manual refresh success/failure, initial status seeding,
  and child cancellation through mapped effects.
- Preview tests cover reconnect while already connecting so decode reset cannot be
  swallowed by equality gating.
- App shell tests continue to cover first contact and reconnect-edge resume behavior.

## Alternatives considered

- **Keep per-screen stores and scoped observation only.** Rejected: it would reduce
  render churn but leave cross-domain rules in `HomeViewController`.
- **Create a `HomeFeature` root.** Rejected: page-scoped state would bind domain
  coupling to the current screen shape and make later tab or CarPlay changes more
  expensive.
- **Fold preview and health into the root now.** Rejected: preview has stream-rate frame
  state and health has no current cross-domain consumers. Both can move later if real
  coupling appears.
- **Notify observers for every action and rely on view-local diffing.** Rejected: it
  spreads reactivity policy across controllers and keeps poll-driven wakeups as the
  default.
