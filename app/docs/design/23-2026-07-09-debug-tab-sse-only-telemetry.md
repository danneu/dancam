# ADR: Debug tab with SSE-only telemetry

- **Status:** Accepted
- **Date:** 2026-07-09
- **Owner:** app
- **Related:** `10-2026-06-29-event-folded-state-machines.md`;
  `14-2026-07-01-structured-logging-and-export.md`;
  `18-2026-07-08-heartbeat-fresh-present-tense.md`;
  `22-2026-07-09-tab-based-top-level-navigation.md`

**Note (2026-07-10): Current + max temperatures.** `temp_c.soc` and
`temp_c.sensor` are now nested `{current, max}` readings (see raspi ADR 02's
2026-07-10 note for the wire shape and the max-since-service-start semantics).
The Debug SoC and camera rows render `current (max ...)` with the current and
max parts independently tinted, so a past-hot peak stays visible after current
recovers. The SoC row gains its own warn/critical thresholds (70/80 C); the
camera row keeps 50/55. Home's temperature pill stays sensor-only and
current-only -- it never reflects `max`, so it clears when the sensor cools.

**Note (2026-07-10, supersedes the render detail above): separate current/max
rows.** The Debug SoC and camera temperatures now render as two plain single-fact
value rows each (`SoC temp` / `SoC max` / `Camera temp` / `Camera max`) instead
of a combined `current (max ...)` value -- the combined string was too wide to
sit beside the "Camera temp" label and wrapped inconsistently with the narrower
SoC row. Max rows are always present, showing `"--"` when unknown, and each row
keeps its own warn/critical tint (SoC 70/80 C, camera 50/55 C). The thresholds
and Home's sensor-only current-only pill are unchanged.

## Context

Debug predated the tab-based shell and was pushed from a Home navigation-bar button.
Its content straddled two sources of truth: a one-shot `/v1/health` request supplied
basic system fields, while the root app store supplied storage, temperature, and memory
telemetry folded from `/v1/events`.

The SSE snapshot already carries the useful health fields: boot ID, uptime, recorder
phase, and time-sync state. The health response's raw timestamp becomes stale as soon as
it renders. Keeping the request creates duplicated truth and a fetch-on-appearance
lifecycle inside a screen that should remain live as a peer tab.

Snapshot uptime has a related freshness problem. A healthy long-lived connection would
continue to show connect-time uptime without a staleness warning even though every SSE
heartbeat already carries milliseconds since Pi boot.

## Decision

Make Debug the middle top-level tab between Home and Settings, with its own navigation
controller below the shell-owned status strip. Remove Home's Debug navigation-bar
button.

Render Debug solely from `AppFeature.State.link`. Use a pure `DebugScreen` projection to
produce render-ready sections and semantic rows, then display those rows in an
inset-grouped collection view. Storage, RAM, and swap use progress gauges; storage stays
neutral because loop recording is expected to consume most of the card, while RAM and
swap use named pressure thresholds. Camera sensor temperature uses the existing warning
thresholds. An offline last-known world receives an explicit staleness banner, and a
missing world or missing telemetry field renders placeholders instead of present-tense
claims.

Delete the app-side `/v1/health` feature, client, response model, and dependency. The Pi
keeps `/v1/health` as an operations and curl surface; its API contract is unchanged.

Fold each online `.heartbeat(tMs:)` into `World.uptimeS` as `tMs / 1_000`, changing no
other world field. This narrows ADR 10's earlier heartbeat rule from "does not mutate
World" to "advances only uptime." Snapshot events remain authoritative and replace the
whole world, including uptime. A controller-local uptime timer is unnecessary because
the wire already carries elapsed time since boot. Home's local live-recording count-up is
a separate recording-duration clock and remains unchanged.

Keep the current log-export format and outcome tracking. Export failures become an
inline critical row supplied to the same pure projection as controller-local input, so
both live telemetry and export outcomes use one diffable render path. Pull-to-refresh
becomes a manual SSE reconnect request when offline and ends immediately.

## Consequences

Easy:

- Debug has one live data source and no fetch-on-appearance staleness.
- Heartbeat-fresh uptime satisfies the present-tense rule while the connection is live.
- Stable semantic row identifiers let telemetry values update in place without losing
  list identity.
- Debug is discoverable as a peer product surface and no longer consumes Home chrome.

Hard or risky:

- Heartbeats now change `World`, so observers of the whole link can receive updates on
  every heartbeat. ADR 06's scoped selectors still prevent callbacks whose selected
  values did not change, and Debug's rendered uptime changes only at its displayed
  precision.
- The Debug controller must reconfigure stable diffable items whenever projected row
  content changes; applying snapshots only for structural changes would freeze live
  values.

## Alternatives considered

- **Keep both `/v1/health` and SSE.** Rejected. It preserves duplicated truth and adds a
  stale request/response lifecycle to a persistent live tab.
- **Refetch health in `viewWillAppear`.** Rejected. It refreshes only at navigation
  boundaries and still duplicates fields already carried by the stream.
- **Keep Debug behind Home's navigation-bar button.** Rejected. Debug is a peer surface,
  and the button competes with Home's feature-specific chrome.
- **Leave uptime frozen at the snapshot.** Rejected. A healthy connection would show a
  stale present-tense value without the ADR 18 banner.
- **Run a controller-local uptime timer.** Rejected. Heartbeat `t_ms` already provides
  the device's elapsed-since-boot clock, so a second clock would add drift and lifecycle
  complexity.
