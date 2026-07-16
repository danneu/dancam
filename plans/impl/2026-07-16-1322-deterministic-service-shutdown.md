# Plan: deterministic shutdown for `systemctl stop dancam`

Verified finding: every `systemctl stop dancam` with an app client connected
hangs the full 90 s systemd stop timeout and ends in SIGKILL. axum's graceful
shutdown waits on never-ending SSE/MJPEG responses; camera shutdown is sequenced
after the server returns; and cgroup-wide SIGTERM kills the Python child while
the unaware supervisor can respawn it. Full evidence:
`docs/research/3-first-segment-delay-and-shutdown-timeout.md`.

## 1. Design direction

Use one early-installed `tokio_util::sync::CancellationToken` to start a small,
owned teardown. Replace bare `axum::serve` with `axum-server`, built from the
existing `std::net::TcpListener` through `from_tcp` and controlled by an owned
`Handle`. On cancellation, concurrently:

- request bounded graceful server shutdown;
- gracefully retire the camera child;
- cancel and join heartbeat, telemetry, and GC; and
- cleanly stop and finalize the mock backend when it is active.

This makes the wall-clock stop the maximum of the independent shutdown branches,
not their sum. systemd remains the final safety net, not the normal owner of a
stalled HTTP connection.

### Signals, startup, and ownership

- Install and actively monitor SIGINT/SIGTERM synchronously, as a fallible step,
  before the camera child or any other backend side effect exists. Installation
  failure is a startup error with nothing to clean up.
- A signal cancels the shared token. Startup checks cancellation before creating
  later lifecycle resources; once a resource exists, its owner retains and joins
  it through the common teardown. Synchronous startup steps such as the boot
  scrub are not individually cancellable; a mid-step signal is honored at the
  next checkpoint, and systemd's stop timeout backstops a stalled step.
- A coordinator extracted from `main` owns the signal monitor, server future and
  handle, camera or mock control, and background worker handles. No long-lived
  service task is fire-and-forget.
- Signal cancellation is a clean exit only when every owned shutdown branch
  succeeds. Unexpected server, camera, or worker completion triggers the same
  cancellation and returns failure after cleanup. Preserve enough initiating and
  cleanup error context that camera retirement failure can never become success;
  do not build an exhaustive simultaneous-failure accumulator.

### Bounded server ownership

- Serve the existing Axum router through `axum_server::from_tcp` with an owned
  `Handle`. On token cancellation call `graceful_shutdown(Some(deadline))` and
  join the server future. Requests that finish during the grace window drain
  normally; the handle terminates every connection still present at the deadline.
- Do not add a universal response-body adapter. SSE, MJPEG, and clip pulls may
  end by connection close at the server deadline. SSE/MJPEG reconnect through
  their existing liveness behavior; a fixed-length clip pull keeps its received
  prefix and resumes with its existing validated `Range` + `If-Range` flow.
- The SSE and MJPEG handlers additionally end their streams when the token
  fires -- plain per-handler wiring, not a body adapter or process invariant --
  so a typical connected-app stop drains before the deadline instead of always
  consuming the full grace window. The deadline force-close remains the
  correctness bound.

### Strict camera retirement

The camera side remains deliberately strict because it owns footage correctness:

- Every outcome derived from token cancellation sends the child shutdown command
  and enters graceful retirement, including the mid-command shutdown path that
  currently force-kills. Non-shutdown child failure may retain forced retirement.
- Retirement succeeds only after the child accepts shutdown and exits cleanly,
  stderr reaches EOF, queued terminal events are applied in order, final metadata
  is published as `ClipFinalized`/`RecordingStopped`, the child is reaped, and both
  reader tasks are joined. Needing the forced-kill fallback is shutdown failure
  even if kill and reap succeed; child, protocol, reader, and cleanup errors cannot
  be overwritten merely because the process is gone.
- Preserve stderr's mixed protocol: event-looking records must parse as supported
  child events, while other lines remain nonfatal diagnostics. Keep a contract
  test coupling `camera.py`'s serializer to the Rust classifier.
- The enclosing supervisor join must outlast the legitimate child retirement
  worst case. The existing two 2 s child-grace phases can consume 4 s, so today's
  3 s enclosing join cannot remain. A blown enclosing deadline still explicitly
  kills and reaps the child and joins both readers before returning failure.
- The child process and reader handles remain owned outside the fallible
  supervisor state-machine future. Typed errors, timeouts, and panics while they
  are live converge on the same explicit retirement path; unwinding must not rely
  on `kill_on_drop` or make terminal-event draining unreachable.
- Cancellation structurally prevents respawn, including a due retry and a spawn
  already in flight. A child produced by an in-flight spawn is retired and never
  admitted to steady state.

### Background workers, blocking work, and mock

- Heartbeat, telemetry, and GC receive the token, stop scheduling new iterations
  on cancellation, finish any already-started operation, and are joined by their
  owner. Samples completing after cancellation are not published.
- Do not add a process-wide `spawn_blocking` registry or two-phase admission
  protocol. Camera and background owners await their durability-sensitive work;
  a request-scoped closure whose request is force-closed may finish without its
  result being globally collected, but Tokio still waits for started blocking
  tasks during runtime shutdown.
- The mock backend owns its producer/writer tasks. Cancellation stops them and
  joins them; an active recording flushes and syncs its segment and completes
  final metadata before mock shutdown succeeds.

## 2. Stop-latency contract

- Typical stop is < 3 s; real-Pi acceptance is < 6 s;
  `TimeoutStopSec=10` is the cgroup SIGKILL escalation deadline.
- Server, camera, worker, and mock shutdown begin concurrently. The bounded server
  grace is short enough to fit inside the real-Pi acceptance window. The camera
  join is strictly longer than legitimate child retirement and strictly shorter
  than the systemd deadline.
- Honest caveat: a started `spawn_blocking` operation cannot be aborted and Tokio
  runtime shutdown waits for it. A truly stalled filesystem or uninterruptible
  kernel operation can therefore reach systemd's final SIGKILL. A kill landing
  during storage mutation remains within the existing abrupt-power-loss contract.

## 3. systemd unit contract -- `raspi/dancam.service`

- Set `KillMode=mixed`: SIGTERM reaches the main process first so the supervisor
  owns ordered child shutdown; SIGKILL still covers the remaining cgroup at the
  timeout.
- Set `TimeoutStopSec=10`, beyond the internal server and camera deadlines but
  short enough for deploy/reboot operations to converge.
- Keep `Restart=on-failure`. A successful SIGTERM stop returns exit 0 and leaves
  the unit `inactive (dead)`; startup, server, camera, or cleanup failure returns
  nonzero. Note the contract in the unit comments. `raspi/deploy.sh` already
  reinstalls the unit and daemon-reloads.

## 4. Behavioral verification

Behavioral, structure-insensitive proofs; implementation may combine cases and
choose seams.

1. **The server owner bounds every connection.** After cancellation, a finite
   request may drain during the grace window, while SSE, MJPEG, a clip pull, and a
   client that stops reading cannot hold the server past its deadline. Responsive
   SSE/MJPEG clients observe EOF before the deadline; a stalled client is
   force-closed at it. The server future joins and affected sockets observe
   connection termination. Existing app tests continue to prove that an
   interrupted clip retains and resumes its prefix.
2. **Successful camera shutdown finalizes footage.** With an active recording,
   cancellation yields a present, nonempty, playable final segment and durable
   final metadata; terminal events precede supervisor success, both readers join,
   and no respawn occurs. Legitimate use of the full child-grace worst case is not
   truncated. The Python-to-Rust stderr contract is tested together.
3. **Camera failure paths retain ownership and fail honestly.** Shutdown-write,
   child-exit, terminal-event/protocol, reader, forced-kill, reap, and enclosing-
   deadline failures clean up the child and join readers without false success.
   An injected supervisor panic while recording is caught by the resource-owning
   boundary and follows the same retirement path.
4. **Lifecycle ownership is complete without a global blocking registry.** Signal,
   server failure, camera failure, and worker failure each cancel the token and
   join all created lifecycle resources. A failing signal installation invokes no
   backend factory. Heartbeat, telemetry, GC, and mock tasks stop and join; active
   mock recording is flushed, synced, and finalized. An already-started worker
   operation completes before that worker joins. A signal during startup creates
   no later lifecycle resources and cleans up the ones already created.
5. **The real Pi meets the acceptance contract** (point-in-time verification):
   deploy, open the app (SSE + preview), hold a client connection unread, and stop;
   assert < 6 s, graceful child shutdown with no camera/libcamera re-init,
   `inactive (dead)` rather than `failed`, a playable final segment, and connection
   termination by the bounded server owner rather than systemd SIGKILL.

Actual OS signal delivery and systemd semantics are covered by Pi verification,
not an in-crate substitute.

## 5. Explicitly not doing, and why

- **No universal response cancellation layer, shutdown 503, or frame-boundary EOF
  invariant:** the bounded server owner terminates residual connections, and all
  long-lived clients already recover from connection loss.
- **No process-wide blocking registry, admission protocol, or startup-wide
  cancellable filesystem conversion:** started blocking work remains unabortable
  and runtime-owned, so the registry cannot create a hard wall-clock bound. A
  force-closed request may not collect its blocking result; storage operations keep
  their existing self-contained durability contract.
- **No exhaustive multi-cause lifecycle accumulator:** any observed lifecycle or
  cleanup failure still produces nonzero exit, while camera retirement retains the
  error detail needed to prevent false success.
- **No `KillMode=process`:** `mixed` retains cgroup-wide SIGKILL for a truly wedged
  process or orphaned child.
- **No final goodbye SSE event, `ExecStop=`, or stop script:** connection loss is
  already the client liveness signal, and process-owned signal handling is the
  correct shutdown boundary.

## 6. Living-design updates

Update each owning page in the same behavior change and append dated decision-log
entries where the page requires them:

- `docs/design/pi/service.md` -- early signal ownership, shared cancellation,
  coordinator-owned lifecycle, `axum-server` handle, concurrent bounded teardown,
  and why the earlier universal-response/global-registry design was rejected.
  Also record why `axum-server` beat the no-dependency alternative of racing the
  drain against a deadline: raced connections die at process exit rather than the
  deadline, and the bound is untestable in-process.
- `docs/design/pi/recording.md` -- strict graceful retirement on cancellation,
  terminal event and reader completion, panic-safe outer ownership, join ordering,
  stderr protocol, no respawn, and mock finalization.
- `docs/design/boundary/transport.md` -- bounded server-owned connection shutdown;
  recoverable SSE/MJPEG disconnects and resumable clip interruption; no shutdown-
  specific 503 or frame-boundary guarantee.
- `docs/design/pi/telemetry.md` -- owned token-aware heartbeat, telemetry, and GC
  lifecycle, including suppression of post-cancellation publication.
- `docs/setup/pi-runbook.md` -- `KillMode=mixed`, `TimeoutStopSec=10`, the < 6 s Pi
  check, expected unit state, graceful camera evidence, unread-client coverage, and
  final-segment playability.
- `docs/research/3-first-segment-delay-and-shutdown-timeout.md` -- append the real-Pi
  verification result. It is already listed in `docs/SUMMARY.md`.

## 7. Sequencing constraints

Deliver coherent Conventional Commits; slicing is implementation's choice. Each
slice builds and passes the raspi suite and carries tests and living-design updates
for its behavior. Land the unit-file contract only after the clean process path
exists; record real-Pi verification last.

## Implementation discretion

Exact internal deadlines and constant names, coordinator/select choreography,
error types, worker-control API shape, test seams and case combination, and commit
slicing are implementation choices within the contracts above.

## Implementation notes

- The bounded server grace is 2 seconds and the camera supervisor join is 8
  seconds. Camera final-metadata collection has a 1 second async bound so a stalled
  blocking probe cannot strand child reap or reader joins; the started blocking task
  remains Tokio-owned under the plan's filesystem caveat.
- Real-Pi acceptance completed in 3.50 seconds with recording active, SSE and MJPEG
  connected, and a third MJPEG client unread across the stop. The unit exited 0 to
  `inactive (dead)`, the clients closed, no camera re-init occurred during teardown,
  and ffmpeg accepted the nonempty final segment.
