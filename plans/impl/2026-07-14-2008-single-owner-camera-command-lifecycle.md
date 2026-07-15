# Plan: single-owner camera command lifecycle

## Context

Planning the recording-command error taxonomy (sibling plan:
`plans/wip/raspi-readiness-and-gc-observability.md`) surfaced three real bugs in
how camera commands are owned today. They make any timeout error code a lie --
a 504 can resolve while the command is still executing -- so they must be fixed
before that taxonomy ships. But they are a concurrency-ownership redesign, not
observability work, so they live in this plan. The sibling plan's taxonomy
commit requires this plan landed first; everything else there is independent.

The three bugs, each verified against current code (see anchors):

1. **Failed commands strand the recorder in a transitional phase.**
   `start_recording` drives the recorder to `Starting` on the request path (via
   `reserve_start_segment`'s commit closure) *before* the command is admitted to
   the queue; `stop_recording` drives `Stopping` the same way. A command that
   then fails admission -- or expires before any actor reconciles it -- leaves
   the recorder stuck. Because `RecorderState::start` only leaves `Idle` or
   `Error`, the *next* start no-ops against the stuck `Starting` and returns a
   false `Ok` without dispatching anything.
2. **Two owners race one deadline.** The requester runs `COMMAND_TIMEOUT` in
   `command_and_wait` while the supervisor executes the command. The requester
   can resolve the HTTP response as a timeout before the supervisor has torn the
   child down and reconciled the recorder, so a start can still execute after
   the 504.
3. **The queue is unserviced when no child exists.** `commands_rx` is polled
   only inside `run_child`; during spawn failure and backoff, `supervise` merely
   sleeps or waits for shutdown, so an admitted command waits forever if respawn
   keeps failing.

## Guarantees (the contract)

These invariants are what the implementation must deliver and what the
behavioral tests pin. The mechanism sketch in the next section is one shape
that satisfies them -- if implementation finds a better shape, take it, as long
as these hold.

1. **No recorder transition before handoff.** A command that fails admission
   (closed queue, or a saturated queue past the bounded admission wait) leaves
   the recorder untouched -- no `Starting`/`Stopping` strand, nothing to
   reconcile.
2. **One execution owner, one clock.** After handoff, the always-running
   supervisor owns the command through its single terminal ack, including
   expiry at one absolute deadline. The requester bounds only admission and
   then awaits the ack with no clock of its own -- so it cannot resolve the
   HTTP response mid-cleanup.
3. **Admitted commands expire even with no child.** The queue is serviced in
   every supervisor state (child running, spawn failure, backoff). A command
   whose deadline passes while no child is up is acked `Timeout` without
   dispatch and without any transition.
4. **Any failed command terminalizes cleanly -- nothing executes after its
   error.** The supervisor is the sole applier of decoded child events to the
   hub, so command success and failure cannot race an independent recorder
   mutator. Before acking *any* post-handoff terminal outcome, it applies all
   child events already delivered to its event stream and performs one final
   session-specific target check. A delivered target event wins and returns
   `Ok`, with the same child event stream continuing for later segment,
   rollover, and stop events. Otherwise a selected failure (child-write error,
   child exit, recorder failure, supervisor shutdown, or timeout) tears the
   child down wherever bytes may have reached it, retires that child's event
   stream, and drives the recorder to `Error` (a recoverable start state) if and
   only if the supervisor had already driven this command's transition. A
   failure before any transition leaves the recorder in its prior phase. Thus
   no late child event can flip the recorder after the response, select
   scheduling cannot produce a failure ack with the success phase, and the next
   command dispatches cleanly instead of no-oping against a stranded
   `Starting`/`Stopping`. The error *variant* is unchanged (a write failure
   still maps to `CameraOffline`, a deadline to `Timeout`); what is now uniform
   is supervisor-owned terminal arbitration followed by reconcile-and-teardown
   before any failure ack.
5. **Blocked storage work cannot wedge supervision.** The durable start-segment
   allocation stays on the request path but runs through
   `tokio::task::spawn_blocking`, so the synchronous storage mutation mutex and
   any stalled SD-card fs work occupy a blocking-pool thread, never an async
   worker. A start-handoff gate admits only one request to the allocation path
   at a time, so a contended mutex or stalled card stalls one blocking-pool task
   and its requesting task while `supervise` (and every other async task) keeps
   running.
6. **Start reservations reach execution in allocation order.** One async
   start-handoff gate is held from before the blocking allocation begins through
   successful queue reservation and intent handoff. A higher start segment can
   therefore never reach the supervisor before a lower segment that is still
   between allocation and handoff; recorder sessions never move backward and a
   retry cannot reopen and truncate a segment created by a later reservation.

Error mapping is unchanged by this plan: failures still surface as the existing
`BackendError::CameraOffline`/`Timeout`/`Channel`/`Storage` variants. The
sibling plan splits these into stable string codes and the JSON envelope.

## Design shape (sketch, not contract)

- `struct Command` becomes a start/stop intent -- carrying the pre-resolved
  start segment (start only), one absolute deadline (`Instant`), and the ack
  sender -- rather than a pre-resolved `ChildCommand`.
- Request path (`start_recording`/`stop_recording`): cheap camera/phase
  preflight (idempotent `Recording`/`Idle` early-returns; non-running camera ->
  `CameraOffline`); for start, acquire the async start-handoff gate before
  launching a witness-only durable allocation through
  `tokio::task::spawn_blocking`, then retain the gate through bounded queue
  reservation and intent handoff (guarantees 5 and 6); a bounded admission
  reservation on the `mpsc` queue under a distinct 250 ms
  `ADMISSION_TIMEOUT` (strictly shorter than `COMMAND_TIMEOUT`); then -- only once
  admission succeeds -- stamp the absolute execution deadline
  (`Instant::now() + COMMAND_TIMEOUT`) immediately before the intent handoff, so
  allocation and admission waits never eat into the execution budget; then await
  the single ack with no clock of its own. Admission and execution are two
  separate budgets: the requester owns the fixed 250 ms `ADMISSION_TIMEOUT`,
  the supervisor owns the longer execution deadline once it is stamped. Keeping
  admission shorter than execution is part of the admission contract: a full
  queue can time out admission before its oldest admitted command reaches its
  execution deadline and frees capacity. Admission failure maps closed queue ->
  `Channel` and a saturated queue past `ADMISSION_TIMEOUT` -> `Timeout`, both
  against an untouched recorder.
  - The witness-only allocation promotes the existing `allocate_start_segment`
    (today `#[cfg(test)]`) to the production call: it writes the mount witness
    and raises the persisted `high_water_seq` without touching recorder state.
    `reserve_start_segment`'s coupling of that reservation to a recorder-
    transition commit closure is dropped; the transition relocates to the
    supervisor. Crash-safety ordering holds -- the durable witness is still
    written before the recorder floor is committed (allocation precedes the
    supervisor's transition). The old storage-lock coupling also serialized
    allocation with transition delivery; the start-handoff gate preserves that
    load-bearing order while allowing the recorder transition itself to move to
    the supervisor.
- `supervise` services the queue in all states, treating the child as an
  optional execution resource, and owns the execution deadline alone after
  handoff. If no child exists, it retains each admitted intent while continuing
  to service its absolute deadline; expiry in this state acks `Timeout` without
  dispatch or recorder transition. Once a child is available, the supervisor
  rechecks the deadline and then re-evaluates the intent against the *current*
  recorder phase immediately before dispatch by driving the FSM transition
  (`Input::StartCommand` with the carried segment, or `Input::StopCommand`). If
  the deadline has elapsed, it acks `Timeout` with no transition. If the
  transition is a no-op -- start when the recorder is not `Idle`/`Error`, or stop
  when not `Starting`/`Recording`, e.g. a duplicate intent whose sibling already
  won the race -- it acks `Ok` immediately, dispatches nothing to the child, and
  does *not* reconcile to `Error`, so a duplicate never disturbs a healthy
  in-flight or active session. When the transition yields a session, it derives
  the `ChildCommand`, writes it under the remaining budget, and watches the
  recorder reach its target phase through the hub. The stderr parser does not
  independently mutate the hub: it decodes stderr into a per-child event stream
  consumed by the supervisor, which owns recorder/hub application and the
  rollover bookkeeping currently held by `parse_stderr`. The supervisor keeps
  consuming and applying this stream across successful commands. When success
  or a failure branch becomes selectable, it first applies events already
  delivered to that stream, then makes one final session-specific target-state
  check against the recorder. If the matching target event was delivered
  (`Recording` for start, `Idle` for stop), it acks `Ok` and continues consuming
  the stream; otherwise it tears down/reaps the child where required, closes or
  ignores only that retired child's remaining events, reconciles the still-
  active transition to `Error`, and only then acks the selected mapped failure.
  This same arbitration applies to deadline, child exit, child-reported recorder
  failure, and supervisor shutdown, so select scheduling cannot turn a promised
  failure terminal state into `Idle` or hide a just-confirmed success.
- Start/stop preflight checks camera lifecycle only. Start must continue to
  dispatch from `RecorderPhase::Error`, because `RecorderState::start`
  deliberately treats error as recoverable.

## Verified code anchors

- `raspi/service/src/camera/mod.rs#CameraBackend::start_recording` drives
  `Input::StartCommand` through `reserve_start_segment`'s commit closure before
  the command is enqueued; `#stop_recording` drives `Input::StopCommand` the
  same way.
- `raspi/service/src/camera/mod.rs#CameraBackend::command_and_wait` runs
  `COMMAND_TIMEOUT` on the request path while `#run_child` executes the command
  -- the dual-owner race.
- `raspi/service/src/camera/mod.rs#supervise` hands `commands_rx` to
  `#run_child` and does not poll it during spawn failure or the backoff
  `tokio::select!`. `run_child` writes a queued command unconditionally (no
  deadline check), and an unbounded `write_all`/`flush` on a child that stopped
  reading stdin wedges the whole select loop.
- `raspi/service/src/camera/mod.rs#parse_stderr` directly drives recorder and
  camera inputs into the hub from an independently spawned task. Routing its
  decoded events back through `supervise` makes the supervisor the sole hub
  mutator for child lifecycle and recorder events while preserving continuous
  event processing for a healthy child.
- `raspi/service/src/recorder.rs#RecorderState::start` accepts only `Idle` and
  `Error`; a stuck `Starting` makes a later start return `None` -- the
  false-`Ok` path. `#fail` moves any active phase
  (`Starting`/`Recording`/`Stopping`) to `Error` and no-ops otherwise, so the
  supervisor can drive it unconditionally on timeout without clobbering an
  already-terminal success.
- `raspi/service/src/storage.rs#reserve_start_segment` couples the witness-only
  reservation and the commit closure under the storage mutation mutex;
  `#allocate_start_segment` (today `#[cfg(test)]`) is the witness-only half.
  The module doc's crash-safety ordering requires witness-before-recorder-
  floor, not atomicity.
- `raspi/service/src/backend.rs#BackendError` has exactly `CameraOffline`,
  `Timeout`, `Channel`, and `Storage` -- sufficient for this plan.

## Commit -- `feat(raspi): single-owner camera command lifecycle`

One commit: the redesign is one coherent ownership change, and splitting it
would leave an intermediate state with two command owners.

- Add an accepted raspi ADR (next sequence) recording the command-ownership
  decision: the admission/execution split (a fixed 250 ms
  `ADMISSION_TIMEOUT`, strictly shorter than `COMMAND_TIMEOUT`, vs. a single
  execution deadline stamped at handoff), the supervisor as single execution
  owner, ordered start reservation-to-handoff under one async gate, child
  availability before recorder transition, decoded child events routed through
  the supervisor as sole hub mutator, continuous event consumption across
  successful commands, the uniform
  terminalize-and-reconcile-before-ack rule for every post-handoff failure (not
  only expiry), dispatch-time idempotence for duplicate intents, and the
  rejected alternative (requester-owned execution deadline).
- Implement to the guarantees above.
- Existing successful start/stop tests remain green; the two-cycle integration
  test pins that a successful command leaves event consumption active for the
  next stop/start cycle.

Behavioral tests -- each pins a guarantee through public behavior, not
internals:

- **Cleanup precedes the error.** Once `start_recording` returns `Timeout` from
  a post-transition expiry, the recorder is already `Error` and the child
  already reaped -- assert the state, not merely the returned error.
- **Admission before transition.** A command that cannot be admitted leaves the
  recorder phase unchanged with nothing dispatched. Cover both a closed queue
  (-> `Channel`) and a saturated queue whose bounded `ADMISSION_TIMEOUT` expires
  (-> `Timeout`) -- hold the queue full past the fixed 250 ms admission budget;
  this deterministically precedes the oldest admitted command's longer
  execution deadline, so expiry cannot free capacity first.
- **No owner gap while no child exists.** An admitted command followed by
  permanent respawn failure (spawn keeps erroring, `run_child` never runs)
  still expires: `start_recording` returns `Timeout` within the deadline rather
  than hanging, nothing was dispatched, and the recorder keeps its prior phase.
  This is the case the current design hangs forever on.
- **No late command.** A command whose deadline elapsed while queued (e.g.
  during backoff) is never written to the child; nothing executes; the recorder
  keeps its prior phase (`Idle`) -- no transition was driven, so nothing is
  failed to `Error`.
- **Child teardown on write stall.** A child that stops reading stdin makes the
  bounded write exceed the deadline; the supervisor tears that child down and,
  having already driven the transition, reconciles the recorder to `Error`.
- **Early write failure reconciles rather than strands.** After the supervisor
  drives the transition, the *first* child write fails (mapped `CameraOffline`)
  while the child is still alive -- no child exit fires. Assert the recorder is
  reconciled to `Error` (not left `Starting`/`Stopping`), the child is torn
  down, and a subsequent `start_recording` dispatches cleanly and succeeds
  instead of false-`Ok`-ing against a stranded phase. This is the non-timeout
  failure the old design leaves stuck.
- **Concurrent duplicates are idempotent.** Two starts admitted before either
  reaches `Recording`: once the first drives the recording, the second's
  dequeue finds a no-op transition, acks `Ok` without a second dispatch, and
  leaves the healthy `Recording` session untouched -- never reconciled to
  `Error`, never torn down. Cover the analogous two-concurrent-stops case
  against a single active session.
- **No orphaned start.** A fully written command whose target transition never
  confirms resolves to `Timeout`; the child is torn down so a late
  `RecordingStarted` from the abandoned child cannot flip the recorder to
  `Recording` after the response, and the recorder is reconciled to `Error`.
- **No orphaned stop.** The stop-path mirror of the above: a stop dispatched
  from `Recording` whose target `Idle` never confirms resolves to `Timeout`
  only after the child is torn down and the recorder reconciled to `Error`
  (not left `Stopping`); a subsequent `start_recording` then genuinely
  dispatches from `Error` and succeeds. Pins the stop failure path so a
  stop-side strand cannot pass the suite while start ownership is correct.
- **Blocked allocation cannot wedge supervision.** A witness-only allocation
  parked in `spawn_blocking` on the held storage mutation mutex (e.g. an
  in-progress GC delete) stalls only the requesting task: *while it is blocked*,
  the supervisor is observed to service an independent event to completion (a
  child exit/shutdown or a second command that resolves), proving no async
  worker is wedged. A second start does not launch another blocking allocation
  while the first owns the start-handoff gate. The blocked start neither
  dispatches nor mutates recorder state until allocation completes (or returns
  `Storage` if it fails).
- **Start handoff preserves allocation order.** Force a lower-segment start to
  pause after its allocation but before queue handoff, then launch a concurrent
  start. Prove the second request cannot allocate or dispatch until the first
  hands off. Fail the first after dispatch and let the second retry succeed;
  assert the child observes increasing start segments/sessions, the lower
  segment is never dispatched after the higher one, and no later segment is
  reopened or truncated.
- **Stop/deadline terminal arbitration.** Hold a stop at the deadline boundary
  and deliver its matching `RecordingStopped` while the deadline branch is
  selectable. After applying events already delivered to the supervisor, assert
  the final target check deterministically returns `Ok` with `Idle` if the
  matching event was delivered; otherwise it returns `Timeout` only after
  teardown and reconciliation to `Error`. Repeat the forced ordering so select
  scheduling cannot produce `Timeout` with `Idle`.
- **Every in-flight terminal failure is uniform.** In a parameterized lifecycle
  test, trigger child exit, a child-reported recorder failure, and supervisor
  shutdown after dispatch but before target confirmation. For each branch,
  assert the expected existing error variant is returned only after the
  recorder reaches its terminal phase and the child is reaped, then perform a
  real successful retry (using a replacement supervisor after the shutdown
  case) to prove no ack was dropped and no transition or child was stranded.
- **Recovery with a successful retry.** After each expiry path, a fresh child
  spawns and a subsequent `start_recording` dispatches cleanly and succeeds --
  proving the supervisor is never wedged and the next command is a real
  dispatch, not a false `Ok` against a stuck phase.
- **Start from `RecorderPhase::Error` recovers.** Preflight checks camera
  lifecycle only, so a start dispatched from recorder error still reaches
  `RecorderState::start` and can succeed.

Verification: `just raspi-test`, `just raspi-build`, `just adr-check`.

## Acceptance

A request that returns *any* command error -- timeout or camera-offline --
leaves no start or stop executing afterward and no wedged `Starting`/`Stopping`
phase: the recorder is either the untouched prior phase (failure before any
transition) or a recoverable `Error` (failure after the supervisor drove the
transition), and the next command dispatches cleanly. Concurrent duplicate
intents never disturb a healthy session. An admitted command expires at its
deadline even when respawn keeps failing and no child ever runs. A blocked
storage allocation never stalls supervision or consumes more than one blocking
task, and allocated start segments reach the supervisor in increasing order. A
target event at the same boundary as a terminal failure is arbitrated only
after the supervisor applies already-delivered child events, so the returned
result and recorder phase cannot depend on select scheduling. Successful
commands leave their healthy child's event stream active for later segment,
rollover, and stop events.

## Out of scope

- Stable string error codes, the JSON error envelope, `Retry-After`, and
  structured rejection logging -- sibling plan
  `plans/wip/raspi-readiness-and-gc-observability.md`, whose taxonomy commit
  requires this plan landed first.
- `/v1/live` / `/v1/ready`, GC diagnostics, and deploy changes -- same sibling
  plan.
- Any change to recorder FSM semantics, the child protocol, or crash-safe
  recording ordering.
