# ADR: connection-liveness timeouts

- **Status:** Accepted
- **Date:** 2026-06-29
- **Owner:** app
- **Related:** `app/docs/design/02-2026-06-22-app-pi-transport-and-api.md`;
  `app/docs/design/06-2026-06-26-domain-root-store-and-scoped-observation.md`;
  root `AGENTS.md` (cross-cutting app<->Pi local API principle)

> **Note (2026-06-30):** ADR 10 supersedes this ADR's status-monitor liveness layer.
> The `NWByteStream` connect-phase deadline still applies to the SSE, preview, control,
> and clip clients, but `/v1/status` polling, the whole-status-fetch timeout, and the
> three-strike debounce no longer define connection truth. The app starts one
> long-lived `/v1/events` stream, arms a heartbeat timeout at stream start, and moves
> offline on stream failure or about 6 seconds without an event (3 missed 2 second Pi
> heartbeats). That deliberate number replaces the earlier
> `3 x (connectTimeout + pollInterval)` rough 10 second estimate and reconciles the
> app policy with ADR 02's missed-heartbeat contract.

## Context

The app's global connection strip is driven by whether `GET /v1/status` succeeds.
There is deliberately no `NWPathMonitor` reachability signal in the product state:
the Pi answering `/v1/status` is the connection truth carried forward by the monitor
ADRs.

That made a missing timeout visible. The app's HTTP transport uses `NWConnection`
pinned to Wi-Fi. When the phone leaves the Pi AP, the connection can sit in
`.waiting` because there is no satisfiable path. The existing transport ignored
`.waiting` and had no connect deadline, so the status fetch could hang forever.
Because the effect never received a failure, the strip could keep showing its last
successful value, including "Connected".

A second variant is possible after TCP connects: the Pi can accept a connection and
then go silent. That is not a connect failure, but the status monitor still needs a
product-level bound so the global strip cannot stay stale.

## Decision

Bound connection liveness at two layers:

- Add a configured connect-phase deadline to `NWByteStream.open`. The deadline covers
  time-to-`.ready` for every real client that routes through the shared transport:
  health, status, clips, clip pull, preview, and recording. `.waiting` remains
  non-terminal so a transient Wi-Fi blip can still recover before the deadline.
- Add a whole-fetch timeout around the connection monitor's status fetch. This races
  `StatusClient.fetch` against an injected timeout closure and emits
  `StatusError.timedOut` when the timeout wins. On `.stop`, cancellation propagates to
  both racing children and emits no failure.

Use `DANCAM_CONNECT_TIMEOUT_MS` to override the transport connect deadline. Invalid,
empty, zero, or negative values fall back to the default. The default connect timeout
is 2 seconds. The monitor timeout is derived as `connectTimeout + 1s`, giving the tiny
status response slack while preserving the invariant that the monitor timeout is always
longer than the configured connect deadline.

Keep the existing fail-slow connection policy: three consecutive status failures are
required before the app shows "Not connected", and one success recovers immediately.
With the default 2s connect deadline and the existing 1500ms poll interval,
off-network detection is about `3 x (connectTimeout + pollInterval)`, roughly 10
seconds. That latency is acceptable for an ambient status strip on a congested 2.4 GHz
link.

This ADR refines ADR 02's hand-rolled HTTP transport mechanics and ADR 06's live
connection monitor policy. It supersedes neither: the wire contract, Wi-Fi pinning,
`/v1/status` source of truth, and three-strike debounce all remain.

## Consequences

Easy:

- The global connection strip can no longer silently stay "Connected" because a status
  fetch is stuck in connect or post-connect silence.
- Preview, clip-pull, recording, health, and clips fail fast on unsatisfied connect
  attempts and then use their existing retry or error funnels.
- The monitor timeout scales with the connect-timeout override, so a valid long
  connect deadline is not clipped by a shorter fixed monitor deadline.
- Tests can cover the product-critical behavior at the reducer seam without adding a
  one-off `NWConnection` integration harness.

Hard or risky:

- A real off-network strip transition still waits for the existing three-strike
  debounce, so it is bounded but not immediate.
- `NWByteStream` still has no dedicated unit-test harness. The connect deadline is
  covered by app build plus manual preview/status checks until the transport test
  seam is worth building.
- Long-lived preview and clip-pull receive loops remain intentionally unbounded after
  connect. A TCP-alive-but-silent Pi can still stall those transfers; adding a
  receive-idle deadline needs its own policy so slow but valid 2.4 GHz transfers are
  not killed incorrectly.

## Alternatives considered

- **Use `NWPathMonitor` or reachability as the connection truth.** Rejected again.
  The app cares whether the Pi API is answering on the local link, not whether iOS
  thinks a path is available. ADR 04 already rejected reachability as product truth.
- **Fail immediately on `.waiting`.** Rejected. `.waiting` can be transient during
  Wi-Fi churn; the deadline provides a bounded recovery window without making the
  first waiting state terminal.
- **Put a whole-request timeout in `HTTPRequestResponse.roundTrip`.** Rejected for
  this pass. The monitor is the product-critical signal, and testing it at the
  reducer/dependency seam avoids introducing a general injected clock or timing policy
  before a second caller needs it.
- **Switch to `URLSession` request timeouts.** Rejected. ADR 02 chose the hand-rolled
  `NWConnection` client so Pi traffic can be pinned to Wi-Fi and prohibited from using
  cellular.
