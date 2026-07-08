# ADR: heartbeat-fresh present-tense UI

- **Status:** Accepted
- **Date:** 2026-07-08
- **Owner:** app
- **Related:** `app/docs/design/06-2026-06-26-domain-root-store-and-scoped-observation.md`;
  `app/docs/design/10-2026-06-29-event-folded-state-machines.md`;
  `app/docs/design/17-2026-07-02-selector-observation-and-view-state.md`

## Context

ADR 10 made the `/v1/events` heartbeat the app's connection truth. `Link` correctly
distinguishes `.online(World)` from `.offline(last: World?)`, so the app can keep
last-known camera detail while also saying "Not connected."

Some Home UI still erased that distinction by reading `link.world`. That is fine for
static stale detail, but it is wrong for present-tense claims. The live recording row
derived a local elapsed-time count-up from the last recorder segment, so after the Pi
lost power the row could keep counting, the REC treatment could stay live, and the
record button could still offer "Stop" against an unreachable host.

The app cannot distinguish "Wi-Fi dropped but the Pi is still recording" from "the Pi
lost power" while the heartbeat is absent. It should render exactly what it knows,
not extrapolate a live fact from stale data.

## Decision

Present-tense UI claims require heartbeat-fresh state. Code that displays a live fact
must derive it from `.online` state or from another freshness-typed source; it must not
silently consume `Link.world` and ignore whether the world is stale.

Make recorder freshness explicit with a typed projection:

```swift
enum RecorderTruth: Equatable, Sendable {
    case live(RecorderSnapshot)
    case lastKnown(RecorderSnapshot)
    case unknown
}
```

`Link.recorderTruth` maps `.online` to `.live`, `.offline(last: some)` to
`.lastKnown`, and connecting or offline-without-world to `.unknown`. Home's live row
uses this projection so it can tick only while live and freeze while last-known.

When the stream fails or a heartbeat times out, `AppFeature` also folds the offline
fact into `RecordingFeature.State` by sending `.linkWentOffline`. That action resets
the control state to `.unknown` and cancels any in-flight recording command. The local
record button no longer advertises an active start or stop command when the camera is
unreachable.

Reconnection must re-derive present-tense recording state from the first fresh
snapshot, even if the Pi recorder phase did not change while offline. `AppFeature`
therefore compares recorder phases through `link.onlineWorld` before and after folding
events. Offline last-known worlds are not a valid previous live phase.

ADR 06, ADR 10, and ADR 17 remain Accepted. This ADR tightens their boundary:
selector-derived view state is encouraged, but present-tense projections must preserve
freshness instead of erasing it.

## Consequences

Easy:

- The connection strip, recording control, and live recording row now agree when the
  heartbeat is absent.
- A stale current segment can still be shown as useful last-known information, but it
  is frozen and visually muted instead of counted as live.
- Same-phase reconnect snapshots re-enable the record button and live row because the
  previous live phase is treated as absent while offline.
- In-flight start or stop requests cannot send a stale command response after the
  offline reset.

Hard or risky:

- `Link.world` remains available because static stale detail is still useful. New UI
  must choose deliberately between `world`, `onlineWorld`, and freshness-typed
  projections such as `recorderTruth`.
- The root store's effect IDs remain global. Recording command IDs must keep avoiding
  the stream, heartbeat, reconnect, and time-sync IDs.
- Frozen last-known rows require view code to reset reused cells in both frozen and
  live branches so a reconnect cannot leave stale muted presentation behind.

Scope cuts:

- `HomeStatusPills.from(link.world)` can continue showing stale temperature,
  camera-offline, and time-detail pills under the "Not connected" strip. Those are
  static last-known details, not local count-ups.
- `HealthTelemetry.rows(for: link.world)` can continue showing last-known debug
  telemetry. The health fetch itself still reports unreachability.
- `.streamStopped` for backgrounding does not move `Link` offline. A short stale-online
  foreground window remains possible until the next snapshot or heartbeat timeout.
- Preview, connection strip, and past-tense clip rows are already honest or outside
  this decision.

Mitigations:

- Link tests cover all `RecorderTruth` derivations.
- Recording reducer tests cover offline resets from active present-tense states.
- AppFeature tests cover offline folding, mapped cancellation of recording commands,
  and same-phase snapshot re-derivation after reconnect.
- Home row and controller tests cover frozen and thawed live-row presentation.

## Alternatives considered

- **Remove the live row when offline.** Rejected. It discards true last-known segment
  information and would flap on normal 2.4 GHz blips.
- **Keep ticking but label the row stale.** Rejected. A ticking duration is itself a
  present-tense claim, so the label would contradict the behavior.
- **Keep using `link.world` and add view-local offline flags.** Rejected. That repeats
  the erased-freshness bug at each call site and makes future surfaces such as CarPlay
  solve the same problem again.
