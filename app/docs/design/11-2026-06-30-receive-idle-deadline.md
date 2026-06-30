# ADR: receive-idle deadline

- **Status:** Accepted
- **Date:** 2026-06-30
- **Owner:** app
- **Related:** `app/docs/design/02-2026-06-22-app-pi-transport-and-api.md`;
  `app/docs/design/09-2026-06-29-connection-liveness-timeouts.md`;
  `app/docs/design/10-2026-06-29-event-folded-state-machines.md`;
  root `AGENTS.md` (cross-cutting app<->Pi local API principle)

## Context

ADR 09 bounded only the `NWByteStream` connect phase. After a connection is ready,
the app's shared HTTP transport re-arms `NWConnection.receive` with no receive-idle
deadline. On the Pi's 2.4 GHz link, a realistic failure is a silent post-connect
stall: the AP stops forwarding, the phone drifts out of range, or the Pi stops
producing bytes without sending FIN/RST. The socket can stay `.ready`, no receive
completion arrives, and the app-side `AsyncThrowingStream` never finishes.

That defeats the existing recovery paths because they key off a byte stream ending:
clip pull retries and resumes after a thrown transport error or premature EOF,
preview reconnects after its byte stream throws, and one-shot request/response
clients surface `.transport` only after the transport returns. Health, status, clips,
and recording had no post-connect receive bound at all.

The `/v1/events` stream now has an app-layer heartbeat timeout from ADR 10: three
missed 2 second Pi heartbeats, about 6 seconds. That policy cancels and reconnects
the events effect when no event arrives, but it covers only the events consumer. The
transport still needs a socket-level receive backstop for every real `NWByteStream`
client, without making the events stream less tolerant than its heartbeat policy.

## Decision

Add a rearmed-per-chunk receive-idle deadline inside `NWByteStream`. The timer is
armed when the receive loop starts, cancelled on each receive completion, and rearmed
only when the stream should continue. If no bytes, EOF, or transport error arrive
before the deadline, `NWByteStream` cancels the underlying `NWConnection` and finishes
the stream with `NWByteStreamError.receiveIdleTimedOut`.

The receive deadline uses the same serial Network queue as connection start, the
connect deadline, and `connection.receive` callbacks. A queue-affined resolution
object owns the idle work item and terminal state so only one terminal result can win:
data callbacks stop immediately after a terminal timeout, and timeout work items no-op
after the stream has already finished or been terminated by the consumer.

Expose the timeout as app configuration:

- `DANCAM_RECEIVE_IDLE_TIMEOUT_MS` overrides the receive-idle deadline.
- The default is 8 seconds.
- Invalid, empty, zero, negative, or sub-heartbeat overrides fall back to 8 seconds.
- The override must be strictly greater than the shared heartbeat timeout constant,
  so `receiveIdleTimeout > heartbeatTimeout` is enforced in code rather than left as
  prose.

Thread the configured value into every real `NWByteStream` client: health, status,
events, clips, clip pull, preview, and recording. Keep the injected `openByteStream`
test seams transport-agnostic; they do not take transport timeout values.

Leave the send phase unbounded. App request bodies are tiny GET headers or `{}` POST
bodies, and Network's `.contentProcessed` completion resolves when the bytes are
accepted locally for sending. A silent peer cannot realistically strand these sends,
so a send deadline would add policy and teardown surface without solving the observed
stall.

## Consequences

Easy:

- A silent post-connect receive stall becomes a bounded, retryable transport error
  instead of an infinite wait.
- Clip pull, preview, and events ride their existing retry/reconnect paths.
- Health, status, clips, and recording gain their first post-connect receive bound.
- The events heartbeat remains the liveness authority in normal operation because the
  8 second transport default is above the 6 second heartbeat timeout. If the transport
  backstop ever fires, it funnels to the same offline-and-reconnect outcome as stream
  failure.
- The receive-idle behavior has a dedicated loopback `NWListener` test harness,
  including guards for slow-but-valid transfers and slow consumers.

Hard or risky:

- These are the app suite's first wall-clock transport-deadline assertions. The tests
  use loopback and generous timing margins, but scheduler load can still affect them
  more than pure reducer or parser tests.
- The receive-resolution object relies on queue affinity that Swift cannot express in
  the type system, so it uses the same `@unchecked Sendable` style as the connect
  resolution and lifecycle wrappers.
- A false-positive receive idle timeout would burn one of clip pull's fixed retry
  attempts. The default intentionally favors "finite instead of forever" over an
  aggressive short cutoff.

## Alternatives considered

- **Transport-agnostic `withIdleTimeout` stream wrapper.** Rejected. Because
  `NWByteStream` is self-driving and unbounded-buffered, a downstream wrapper would
  often still observe socket cadence. The concrete losses are elsewhere: it cannot
  cancel the underlying `NWConnection` directly, its timer is live only while a
  consumer awaits `next()`, and it adds a second async teardown structure.
- **Send-phase deadline.** Rejected. Request bodies are tiny and `.contentProcessed`
  is local-buffer acceptance, so this does not address the silent receive-stall
  failure mode.
- **Derive receive idle from the connect timeout.** Rejected. Connect and receive idle
  are different failure modes: one measures time-to-ready, the other measures
  zero-byte inactivity after readiness and resets on every chunk.
- **Default below the heartbeat timeout.** Rejected. That would let transport idle
  preempt the events stream's deliberate 6 second heartbeat policy during tolerable
  congestion.
- **Separate events-only or per-client idle values.** Rejected for now. One 8 second
  receive-idle value serves one-shot control requests, preview, clip pull, and the
  heartbeat-paced event stream.
- **Whole-request timeout in `HTTPRequestResponse.roundTrip`.** Rejected as in ADR 09.
  The failure is socket receive inactivity, and the shared transport can reclaim the
  real connection directly.
