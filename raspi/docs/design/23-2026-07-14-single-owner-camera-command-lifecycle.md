# ADR: Single-owner camera command lifecycle

- **Status:** Accepted
- **Date:** 2026-07-14
- **Owner:** raspi
- **Related:** `07-2026-06-25-picamera2-camera-owner.md` (child protocol and
  supervision); `10-2026-06-30-recorder-fsm-and-events-sse.md` (recorder
  transitions); [Pi storage](../../../docs/design/pi/storage.md)
  (durable start-segment allocation)

## Context

Recording commands previously had two execution owners. The request task drove the
recorder transition, enqueued a child command, and ran the command timeout while the
camera supervisor wrote the command and independently applied child events. A queue
admission failure could therefore strand `Starting` or `Stopping`, and a requester
could return `Timeout` while the child command was still executing. The supervisor
also stopped polling commands during spawn failure and backoff, so admitted work could
wait forever when no child existed.

Start-segment allocation is synchronous filesystem work protected by the storage
mutation mutex. Running it directly on an async worker could wedge supervision during
slow SD-card I/O. Separating allocation from the old recorder-transition closure also
requires an explicit ordering rule so concurrent starts cannot hand higher segment
reservations to the supervisor first.

## Decision

Split command admission from execution ownership.

The request path owns only bounded admission. Queue reservation has a fixed 250 ms
`ADMISSION_TIMEOUT`, strictly shorter than the 3 second execution
`COMMAND_TIMEOUT`. Closed admission returns `Channel`; admission saturation returns
`Timeout`. Neither case mutates recorder state. After reserving capacity, the request
stamps one absolute execution deadline immediately before handing the intent to the
queue, then awaits one terminal acknowledgement without another clock.

Start requests perform witness-only durable segment allocation through
`spawn_blocking`. One async start-handoff gate is held from before allocation through
successful queue handoff, then released before acknowledgement. This limits blocked
allocation to one blocking-pool task and preserves allocation-to-handoff order. The
storage coordinator no longer accepts a recorder-transition closure; the witness is
persisted and returned independently.

The always-running supervisor is the sole execution owner after handoff. It polls the
command queue, deadlines, shutdown, respawn backoff, child exit, and decoded child
events in every lifecycle state. An intent that expires without a ready child is
acknowledged `Timeout` without dispatch or recorder transition. With a ready child,
the supervisor rechecks the deadline and drives the recorder FSM immediately before
dispatch. A dispatch-time no-op is an idempotent success: duplicate starts or stops
write nothing and do not disturb the healthy session.

The stderr reader only decodes events into a per-child stream. The supervisor applies
those events to the hub and retains the stream after successful commands so rollover,
stop, telemetry, and later command events continue to flow. Command writes and target
confirmation share the intent's remaining absolute deadline.

Before choosing any post-transition failure, the supervisor applies every child event
already delivered to that stream and performs one final session-specific target
check. A delivered target wins as success. Otherwise write failure, child exit,
child-reported failure, shutdown, or timeout retires that child, reconciles the active
recorder transition to recoverable `Error`, and only then sends the existing mapped
error acknowledgement. Retired event streams are never applied again, so no abandoned
child can mutate recorder state after the response.

## Consequences

- A returned command error is terminal: no command remains executing and no recorder
  transition remains stranded.
- Admission failure and no-child expiry leave recorder state untouched; failure after
  transition leaves a recoverable `Error`.
- Concurrent duplicate intents are harmless and do not cause duplicate child writes.
- Spawn failure and backoff no longer create an ownership gap for admitted commands.
- Slow start allocation consumes a blocking-pool thread rather than an async worker,
  with at most one such start allocation in flight.
- Successful commands keep their child's event stream active for subsequent lifecycle
  events.
- Failure acknowledgement can occur after the absolute execution deadline because
  teardown and reconciliation are intentionally completed first.

## Alternatives considered

- **Requester-owned execution timeout.** Rejected because the requester can return
  before the supervisor has stopped the child or reconciled recorder state.
- **Drive recorder transitions before queue admission.** Rejected because admission
  failure can strand a transitional phase without an execution owner.
- **Keep stderr as an independent hub mutator.** Rejected because select scheduling can
  race a failure acknowledgement against a delivered success event or allow late
  events from an abandoned child.
- **Hold the storage mutex across recorder transition delivery.** Rejected because it
  couples synchronous storage ownership to async command execution; the async
  start-handoff gate preserves the required start ordering directly.
