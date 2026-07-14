# ADR: Incident post-roll press lockout

- **Status:** Accepted
- **Date:** 2026-07-14
- **Owner:** app
- **Related:** app ADR 26
  (`app/docs/design/26-2026-07-14-phone-owned-incidents.md`, phone-owned
  incident lifecycle); historical nova implementation plan
  (`plans/impl/2026-07-14-1333-nova-phone-owned-incidents.md`, superseded
  press-cooldown choice)

## Context

The first incident-button implementation disabled the control for a fixed 3 s
cooldown but displayed "Saving..." for the full pending incident lifetime.
Those independent predicates could produce an enabled button still labeled
"Saving...". A second press during the 15 s post-roll window then created a
duplicate incident covering footage the first incident was already capturing.

The lockout must survive ordinary view updates, link state changes, and process
relaunch without making in-process wall-clock corrections part of button
enablement. It must also be scoped to one recording identity: a suspended write
from an earlier recording cannot prevent capture in the current recording.

## Decision

Replace the cooldown with a `RecordingID`-scoped lockout spanning the default
post-roll plus slack, currently 17 s. A press creates a runtime
`ContinuousClock` deadline. Both reducer acceptance and the button presentation
consume that same deadline, and the button renders from one presentation enum
whose enabled state and title cannot disagree.

The button owns a 1 s view timer for its countdown. Reducer state does not tick;
every tap independently samples the monotonic clock and applies the same guard.
After the deadline, incident segment transfers may continue and are represented
by the Incidents tab badge rather than keeping the Home button locked.

Persisted incident records retain the wall-clock press time as a durable fact.
After launch, once the incident store and a validated current recording first
meet, the reducer reconstructs any remaining fixed 17 s window exactly once as
a monotonic deadline. Persisted per-record duration fields do not determine the
lockout. Capture remains unavailable until the store load succeeds, closing the
race where a recording snapshot arrives before a just-created record is read
from disk.

Create-in-flight state is keyed by `RecordingID`. A create for the current
recording keeps the button disabled even if it outlives the deadline, while a
create from another recording does not gate capture. A failed create clears
only its matching pending entry and runtime lockout so the current recording can
retry immediately.

This decision supersedes only the 3 s press-cooldown choice in the historical
nova implementation plan. App ADR 26 remains accepted.

## Consequences

- In-process wall-clock rewinds and forward corrections cannot end, extend, or
  reactivate a lockout.
- Relaunch recovery survives process death but depends on wall time being sane
  at the single reconstruction sample. A bad sample can omit a duplicate guard,
  but it cannot strand the button or disagree with reducer acceptance.
- New recording sessions are not blocked by old-session incidents or suspended
  creates.
- A second press becomes available after the post-roll window even while the
  first incident continues pulling segments.
- The view timer is behavioral because it re-enables the control, so it runs in
  the main run loop's common mode and stops when detached or expired.

## Alternatives considered

- **Fixed 3 s cooldown.** Rejected because it expires during post-roll and lets
  the presentation title disagree with enablement.
- **Continuously evaluated wall-clock window.** Rejected because wall-clock
  changes could end or reactivate the lockout differently across reducer and
  view updates.
- **Reducer-owned countdown timer.** Rejected because per-second actions would
  churn application state without adding authority; the reducer only needs to
  validate the deadline when actions arrive.
