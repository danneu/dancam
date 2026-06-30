# ADR: connection monitor and indicator

- **Status:** Superseded by 05-2026-06-26-app-shell-status-strip.md
- **Date:** 2026-06-26
- **Owner:** app
- **Related:** root `AGENTS.md`; `app/AGENTS.md`;
  `app/docs/design/02-2026-06-22-app-pi-transport-and-api.md`;
  `app/docs/design/03-2026-06-24-app-ui-architecture.md`

> **Note (2026-06-30):** ADR 10 supersedes this ADR's connection-truth mechanism.
> The app no longer owns a scene-scoped `ConnectionFeature`, `/v1/status` poll, or
> three-strike debounce. Connection truth is now `Link`, folded from
> snapshot-first `/v1/events`; liveness is heartbeat presence, with offline detected
> after about 6 seconds of missed 2 second heartbeats. The shell and root-store
> decisions that superseded this ADR are refined in ADR 06 and ADR 10.

## Context

The home dashboard originally inferred connectivity from screen-local polls. Home,
Recording, and Debug each read `GET /v1/status` independently, and those readers lived
only as long as their screens. A single missed home poll immediately rendered a
"Can't reach camera" pill even on a congested 2.4 GHz link, while the rest of the app
could still look connected because stale preview frames and clip rows remained on
screen.

That shape also made recovery screen-local. Foregrounding the app after Wi-Fi dropped
did not trigger a shared re-probe, and the preview stream did not reschedule itself
after `streamFailed` or `streamFinished`.

The app needs one durable connection truth for the scene, not one liveness guess per
view controller.

## Decision

Use one app-scoped `ConnectionFeature` store per scene as the sole `GET /v1/status`
reader. `SceneDelegate` creates it, starts it on cold launch and foreground, stops it
on background, and injects it into screens that need status facts.

Connection truth is the Pi answering `/v1/status` over the local API. Do not use
`NWPathMonitor` as the source of truth: being on some Wi-Fi, or having any network
path, does not mean the Pi AP is reachable.

Surface connectivity as an always-visible navigation-bar pill owned by a
`UINavigationControllerDelegate` coordinator. The pill is ambient status, not a
full-screen takeover; screens keep their current state while the link drops and
recovers.

Debounce disconnects asymmetrically:

- Three consecutive failed status polls are required before showing "Not connected".
- One successful status poll immediately returns to "Connected".
- The last successful status response is retained so dashboard facts can remain
  visible while the app rides out misses.

Route recovery through a tiny `ConnectionResumable` protocol. The nav coordinator
calls the top view controller on the `disconnected -> connected` edge, and
`SceneDelegate` calls it on foreground. Home uses that hook to refresh clips and nudge
preview reconnect. Future pushed screens can opt in without changing the monitor.

Preview self-heal is independent of monitor connectivity. The preview reducer
reschedules a reconnect with bounded backoff after stream failure or finish, and
accepts an immediate reconnect nudge from `ConnectionResumable`.

## Consequences

Easy:

- There is one status reader and one debounced connection state for the whole scene.
- The connection indicator automatically appears on pushed view controllers.
- Home and Debug reuse retained status facts instead of owning their own polls.
- Recovery is explicit and local to the visible screen.

Hard or risky:

- The nav coordinator owns a reusable custom bar item and must re-parent it cleanly on
  navigation transitions.
- The monitor is now scene lifetime state, so lifecycle start/stop behavior matters.
- Preview backoff shares an effect cancellation ID with the live stream; cancellation
  tests must cover immediate reconnect so old sleeps cannot enqueue stale reconnects.

Mitigations:

- Keep `ConnectionFeature` pure and unit-tested with the existing `TestStore`.
- Keep reconnect edge detection in pure `ConnectionCoordination`.
- Keep pull-to-refresh spinner lifetime behind a pure `RefreshGate` so UIKit observer
  timing does not decide behavior.

## Alternatives considered

- **`NWPathMonitor` connectivity.** Rejected: network path availability is not the
  product signal. The Pi answering the local API is the useful truth.
- **Parallel heartbeat beside the existing screen readers.** Rejected: it would keep
  conflicting status readers and make dashboard facts race between stores.
- **Debounced full-screen disconnected takeover.** Rejected: it destroys user context
  during normal car Wi-Fi churn. Ambient status plus in-place recovery matches the
  product workflow better.
