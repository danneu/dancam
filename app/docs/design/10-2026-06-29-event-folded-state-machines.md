# ADR: event-folded app state machines

- **Status:** Accepted
- **Date:** 2026-06-29
- **Owner:** app
- **Related:** `app/docs/design/02-2026-06-22-app-pi-transport-and-api.md`;
  `app/docs/design/03-2026-06-24-app-ui-architecture.md`;
  `app/docs/design/06-2026-06-26-domain-root-store-and-scoped-observation.md`;
  `raspi/docs/design/10-2026-06-29-recorder-fsm-and-events-sse.md`

## Context

The app originally treated the Pi connection as a 1.5s `/v1/status` poll plus a
three-failure debounce. Root state kept the connection status, recording overlay, and
clips list in separate features, then coupled them with diffs over flat status fields:
recording boolean changes drove the record button, current-segment changes refreshed
clips, and the live row guessed from local recording state plus `current_segment_id`.

That shape was good enough for the first mock-Pi slice, but it had two structural
problems:

- The app could briefly show the last finished clip as the live `REC` row because the
  row path trusted local recording optimism before the Pi had opened a new segment.
- Poll responses could arrive out of order with clip finalization, forcing ad hoc
  refresh and replacement rules.

The Pi now owns a recorder state machine and exposes an ordered `/v1/events`
text/event-stream: snapshot first, then deltas, then heartbeats. The app should mirror
that model directly instead of preserving the poll-era flag cluster.

## Decision

Mirror the Pi event contract in `CameraEvent` and decode unknown event types into an
explicit `.unknown(type:)` case. The golden event corpus must decode to concrete cases;
future unmirrored wire variants remain safe no-ops until the app adds a typed case.

Represent connection and world data with one sum type:

```swift
enum Link: Equatable {
    case connecting
    case online(World)
    case offline(last: World?)
}
```

`World.folding(_:_:)` is the pure state keel. A snapshot replaces the world; deltas
fold only while online; deltas received while connecting or offline are ignored because
they have no base snapshot. `heartbeat`, `clip_finalized`, and unknown events do not
mutate `World`; heartbeat is liveness, and clips are folded by `ClipsFeature`.

Root app state owns one long-lived `EventsClient` stream effect. `streamStarted` starts
the SSE effect and arms a heartbeat timeout immediately, before the first snapshot, so
a ready-but-silent stream cannot leave the app stuck in `connecting`. Every event
re-arms the timeout. `heartbeatTimedOut` and stream failure move `Link` offline,
cancel the live stream as needed, and schedule a reconnect. The heartbeat timeout is
6 seconds: three missed 2 second Pi heartbeats.

The record control remains locally optimistic, but it observes authoritative
`RecorderPhase` changes rather than a polled boolean. The overlay is asymmetric:
optimistic `.starting` ignores stale `.idle` and accepts `.recording` or `.error`;
optimistic `.stopping` ignores stale `.recording` and accepts `.idle` or `.error`.
Command-phase events (`recording_starting`, `recording_stopping`) also move a
non-commanding client to `.starting` or `.stopping`.

The home live row is authoritative: it exists only when
`world.recorder.currentSegment != nil`. It is keyed by `(session, segment id)`, so a
new session reseeds the local elapsed-time anchor even if segment ids repeat. Finished
duration comes from `clip_finalized`; live elapsed is a local count-up seeded by the
snapshot or open event duration when present.

`ClipsFeature` now keeps persistent list state plus load status. `clip_finalized`
inserts or updates by id, newest-first, regardless of load status. `/v1/clips` remains
a one-shot history load and manual refresh source; successful loads merge by id instead
of replacing, so a stale response cannot erase a clip already folded from the stream.

Delete the poll-era connection reducer, three-strike debounce, `lastStatus` diff
coupling, 10s clips poll, and pending manual-refresh flag.

## Consequences

Easy:

- App state is a pure fold over the ordered Pi event stream.
- The live row can no longer appear without a Pi-owned current segment.
- Rollover and stop clips appear from `clip_finalized` without a clips poll.
- Telemetry panels keep updating from raw `storage_changed`, `temp_changed`, and
  `mem_changed` events.
- Unknown event types are forward-compatible while the corpus still catches missing
  typed mirrors for known variants.

Hard or risky:

- The app now depends on one long-lived SSE stream for connection truth, so the stream
  effect and heartbeat timeout must be cancellation-correct.
- `/v1/clips` merge-by-id never removes clips. That is correct before eviction exists;
  storage eviction will need an explicit authoritative-removal rule.
- `offline(last:)` intentionally retains the last world projection for screens that can
  display stale-but-useful detail while the strip says "Not connected."

## Alternatives considered

- **Keep `/v1/status` polling as a fallback.** Rejected. Dual truth would preserve the
  same ordering bugs this migration removes.
- **Use `URLSession` EventSource-style APIs.** Rejected. The app transport must stay on
  the hand-rolled `NWConnection` path so Pi traffic can be pinned to Wi-Fi.
- **Drive the live row from local recording optimism until the first segment opens.**
  Rejected. That is the bug: optimism is valid for controls, not evidence-like segment
  rows.
- **Replace clips on every `/v1/clips` success.** Rejected. A stale one-shot response can
  arrive after a `clip_finalized` event; union-by-id preserves the ordered stream fact.
