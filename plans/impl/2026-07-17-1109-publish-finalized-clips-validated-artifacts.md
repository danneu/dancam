# Publish clip finalization from validated artifact facts

## Problem and evidence

Rust validates each reported real-camera finalization against the durable artifact,
but discards the resolved artifact and performs another fallible directory lookup to
publish the clip. That redundant read can fail the recorder after the first read has
already established every required durable fact. Wall time is nullable enrichment,
and the mock may also lack duration.

The app separately protects an event-created clip row from list responses for an
entire coverage epoch. A list requested after the event therefore cannot act as the
authoritative catalog by replacing or removing that row.

The completed transactional PyAV implementation and hardware campaign are the
baseline. They establish the artifact transaction, child acknowledgement behavior,
failure handling, rollover and stop durability, recovery, power-cut behavior, and
production-media performance. The recorded acceptance evidence is
`docs/research/3-first-segment-delay-and-shutdown-timeout.md#11-committed-transactional-pyav-acceptance----2026-07-16`.

## Decision

- Real-camera finalization publication uses the artifact facts returned by durable
  validation. It does not perform a second catalog lookup.
- Validation retains the existing acceptance boundary: the finalized artifact is
  nonempty, matches the reported session and segment, carries durable duration, and
  agrees with the child's duration report.
- The published clip row takes identity, recording, bytes, duration, and ETag from
  that accepted artifact. Unavailable wall time remains `start_ms: null` with
  `time_approximate: true` and does not fail finalization.
- The mock publishes a valid `clip_finalized` after successful writer durability;
  facts it does not own remain null.
- App protection for event-created rows is scoped to list requests already in flight
  when the event arrives. A response requested after the event is authoritative.

## Invariants

- **I1 - Durable acceptance:** Durable validation remains the only acceptance
  boundary for real-camera `segment_finalized`. Rejected artifacts are not
  acknowledged and cannot produce a clean rollover or stop. Existing transactional
  writer and lifecycle failures retain their failure behavior.
- **I2 - Accepted publication:** Every accepted real-camera finalization produces
  exactly one `clip_finalized` from the artifact view accepted by validation before
  recorder advancement and child acknowledgement. The event precedes the paired
  `segment_opened` or `recording_stopped` event; unrelated events may interleave.
- **I3 - Artifact agreement:** The published row agrees with that durable artifact
  on segment id, recording identity, positive bytes, duration, and ETag. Missing or
  unusable clock enrichment affects only `start_ms` and `time_approximate`.
- **I4 - Mock durability:** A successfully made-durable mock segment publishes
  `clip_finalized` with unavailable facts left null. Mock writer failures remain
  recorder failures.
- **I5 - Catalog tolerance:** An otherwise resolvable bare or durationless stamped
  file remains listable and pullable with `dur_ms: null`, without a listing-time scan
  or rename. A catalog read failure makes `/v1/clips` return 503 rather than a partial
  catalog.
- **I6 - Shared clip authority:** `clip_finalized` is the ordered publication of an
  accepted artifact, `/v1/clips` remains the authoritative complete catalog, and
  event and list rows agree on shared durable facts.
- **I7 - Request-scoped app protection:** An event row survives a list response that
  was already in flight when the event arrived. A response requested after the event
  may replace or tombstone the row. An event received with no request in flight
  creates no lasting guard.
- **I8 - Existing app authority:** Request-scoped protection preserves positive and
  negative interval authority, removal tombstones, pending deletion, browsing,
  recovery, and incident coverage without changing their frontiers or scheduling.

## Proof obligations

- **PO1 (I1):** Behavioral tests prove that accepted and rejected real-camera
  finalizations preserve the established durability, acknowledgement, recorder
  phase, and failure boundaries.
- **PO2 (I2):** Behavioral tests prove exactly-once accepted publication and its
  ordering before paired rollover or stop lifecycle events and child acknowledgement
  without requiring stream adjacency.
- **PO3 (I3):** Behavioral tests prove that publication uses the accepted artifact's
  durable facts and that unavailable clock enrichment cannot block lifecycle
  completion.
- **PO4 (I4):** Behavioral tests prove mock publication after durability, nullable
  mock enrichment, and fatal handling of mock writer failures.
- **PO5 (I5):** HTTP and storage tests prove durationless catalog tolerance,
  pullability without mutation, and fail-closed catalog reads.
- **PO6 (I6):** Contract tests prove agreement between event and list representations
  of the same durable clip.
- **PO7 (I7):** Reducer tests prove the authority boundary for responses begun before
  and after an event, including the no-request case.
- **PO8 (I8):** Reducer tests prove that the new protection scope composes with the
  existing clip authority, deletion, browsing, recovery, and incident behaviors.

## Documentation

The Pi recording and app clip design pages describe the resulting behavior in the
present tense and append dated decision rationale for the single accepted artifact
view and request-scoped event protection.

## Non-goals

- **NG1:** Change the PyAV muxer, artifact transaction, child lifecycle fields,
  acknowledgement retry protocol, sequence reservation, worker drain, periodic
  sync, owner retirement, or owner-death reconciliation.
- **NG2:** Weaken real-camera validation, make writer failures best-effort, or change
  the existing nullable wire contract.
- **NG3:** Add close-boundary catalog reconciliation, another clip-list scheduling
  goal, or a retry path for intentionally omitted finalization events.

## Rejected ideas

- **RI1:** Alternate finalizers, filesystem watchers, listing-time scans, and another
  child-facts performance experiment remain rejected because the landed PyAV
  transaction and its acceptance evidence already settle those directions.

## Implementation discretion

- **D1:** Internal Pi types, factoring, and test seams are implementation choices as
  long as one accepted artifact view discharges I1-I3 without adding a production
  capability.
- **D2:** The app's bookkeeping mechanism is an implementation choice as long as it
  discharges I7-I8.

## Commit plan

1. `fix(raspi): publish finalized clips from validated artifacts`
   - Include the Pi implementation, behavioral and contract tests, and Pi recording
     design documentation.
2. `fix(app): scope finalized clip protection to in-flight requests`
   - Include the app implementation, reducer tests, and app clip design
     documentation.

## Commit progress

- [x] 1. fix(raspi): publish finalized clips from validated artifacts
- [x] 2. fix(app): scope finalized clip protection to in-flight requests

## Implementation notes

- App protection lives on `ClipsFeature.State.Request` as the IDs finalized after
  that request was issued. Request settlement or retirement therefore removes the
  protection without a separate pruning lifecycle.
