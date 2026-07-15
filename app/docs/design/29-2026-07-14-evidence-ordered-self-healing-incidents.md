# ADR: Evidence-ordered, self-healing incidents

- **Status:** Accepted
- **Date:** 2026-07-14
- **Owner:** app
- **Related:** app ADR 26
  (`app/docs/design/26-2026-07-14-phone-owned-incidents.md`, superseded only
  where it treats saved and partial as permanently terminal); app ADR 10
  (`app/docs/design/10-2026-06-29-event-folded-state-machines.md`, ordered
  snapshot and recorder lifecycle folding)

## Context

An incident was marked while its segment was still open. Recording stop moved the
recorder into `stopping`, but the current clips head naturally omitted that open
segment. The app interpreted `stopping` plus list absence as proof that the segment
was gone, persisted a partial incident, and stopped reconciling it. The Pi finalized
the segment normally a few seconds later.

The failure was not a missing retry. It combined negative evidence from different
moments, treated a finalizing recorder as stopped, and made an inferred conclusion
irreversible even when later positive evidence contradicted it.

## Decision

Incident reconciliation follows an explicit evidence order.

Positive same-recording clip metadata is usable whenever observed. Negative absence
is usable only when a successful clips head and page chain from the current SSE
snapshot epoch covers the sequence. Clips retained from an older load remain useful
positive witnesses, but never prove absence. A retryable page failure invalidates
negative coverage until the heartbeat-driven head retry rebuilds the chain.

`stopping` is an active, finalizing state for the same `RecordingID`. It disables new
marks but does not prove that the open segment disappeared. Session end becomes
authoritative only at `recording_stopped`, `recorder_failed`, or a lifecycle event
for a different recording. Recorder lifecycle transitions are all forwarded to the
incident reconciler, preserving event-stream order.

Incident status is derived from segment facts and is not persisted:

- unresolved or wanted segments mean `pending`;
- all segments settled with any lost segment mean `partial`;
- all segments settled with no lost segment mean `saved`.

Lost segments persist their evidence class. Covered gaps and post-session absence
are `inferred_absence`; `clip_removed` and a resolved-etag pull returning 404 are
`confirmed_missing`. Legacy lost segments without etag or duration decode as inferred
absence; legacy lost segments with resolved metadata decode as confirmed missing.
The old persisted `status` key is ignored.

A positive same-recording clip witness may reopen `inferred_absence` or `clipped` to
`wanted`; it never reopens `confirmed_missing`. Reconciliation scans every readable
incident, including currently saved and partial records. A complete local final
artifact remains the strongest fact and is reconciled to pulled before network work.

Every record transition uses one ordered effect: durably write the record, update the
local notification for the derived-status transition, then publish the record back to
the reducer and resume reconciliation. Terminal-to-pending schedules the nudge;
pending-to-terminal cancels it. Store load idempotently cancels nudges for records
that are already terminal.

## Consequences

- A stale or pre-finalization list cannot turn an open segment into a permanent loss.
- Later positive evidence automatically repairs inferred absence and clipped edges,
  including legacy partial incidents already on the phone.
- Confirmed deletion and resolved-etag 404 remain terminal and do not retry in a loop.
- The Pi API, event contract, incident UI, and manual controls do not change.
- Incident diagnostics distinguish inferred loss, confirmed loss, corrective
  reopening, pull completion, terminal state, and waits for fresh negative coverage.

## Alternatives considered

- **Retry every partial incident.** Rejected because it loops confirmed losses and
  leaves the underlying evidence-ordering bug intact.
- **Treat every list response as current absence evidence.** Rejected because an SSE
  snapshot and an older or partially loaded cursor chain describe different moments.
- **Add a Pi incident or finalize endpoint.** Rejected because the ordered existing
  lifecycle and clip surfaces contain enough evidence, and incidents remain
  phone-owned.
- **Persist status alongside facts.** Rejected because duplicated conclusions can
  drift from segment evidence and prevent correction.
