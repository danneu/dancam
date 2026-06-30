# Plan: receive-idle deadline in `NWByteStream` (kill the silent mid-pull hang)

## Context

The app's hand-rolled HTTP transport (`app/DanCam/DanCam/Networking/HTTP/NWByteStream.swift`)
bounds only the *connect* phase. ADR 09 added a connect deadline in `NWByteStream#start`,
but `NWByteStream#receive` re-arms `connection.receive` with no inactivity timer. On a
congested 2.4 GHz link the realistic failure is not a clean TCP reset: the AP silently
stops forwarding (or the phone drifts out of range), the socket stays `.ready`, no
FIN/RST is delivered, and `connection.receive` never calls back. The producer suspends
forever, so no `error` and no `isComplete` ever reach the `AsyncThrowingStream`.

Because every consumer's resume/retry machinery keys off the byte stream *finishing*
(`ClipPullClient#runAttempt` only yields `.retry` on a thrown error or premature EOF;
`PreviewClient#produceFrames` and the shared `HTTPRequestResponse#roundTrip` loop the
same way), the stall defeats the very resume loop that exists to survive drops. The clip
viewer sits on "...pulled" indefinitely; a silent Pi freezes preview; and
status/health/clips/recording have *no* post-connect bound at all. The one long-lived
consumer that already has a liveness bound is the `/v1/events` stream: it now carries
connection truth (ADR 10 retired the `/v1/status` poll, the three-strike debounce, and the
old `ConnectionFeature` status-fetch timeout), and `AppFeature` bounds it at the *app* layer
with a 6s heartbeat timeout -- 3 missed 2s Pi heartbeats -- so a silent events stream
reconnects rather than hanging. But that bound is event-level and app-layer, and covers only
events: `heartbeatTimedOut` cancels the stream effect, and that cancellation propagates down to
free the `NWConnection` (the byte stream's `onTermination` calls `lifecycle.cancel()`) -- so the
events transport *is* reclaimed, but only for events, only via the reducer, and only because that
one consumer is cancellable from app state. The other six clients have no app-layer liveness, so a
post-connect stall on any of them frees nothing. No client has a *transport*-level receive bound.

ADR 09 explicitly deferred this to "its own decision" -- "a rearmed-per-chunk idle timer
in `NWByteStream.receive`, tuned for the link." This plan is that decision.

**Intended outcome:** a post-connect *receive* stall deterministically surfaces as a thrown,
retryable error within a bounded window, so the existing resume/reconnect/`.transport`
paths fire instead of hanging -- without false-killing a slow-but-alive transfer.

## Approach

A per-chunk-rearmed idle deadline inside `NWByteStream`, applied to every client (it lives
in the one transport every live `NWByteStream` client routes through -- all seven of them),
surfaced as `NWByteStreamError.receiveIdleTimedOut`.

Why this shape (the ideal for this codebase, not the minimum patch):

- **Most correct + simplest.** The timer rearms inside the real `connection.receive`
  completion, which runs on the connection's serial queue, so it measures the literal wall-clock
  gap between socket reads -- the exact definition of "the socket went idle." Two properties fall
  out that a downstream wrapper cannot match: (a) on fire it calls `lifecycle.cancel()` directly
  on the `NWConnection`, freeing the real socket at once; and (b) it runs on the connection queue
  from the first receive arm, so it bounds idleness even when no consumer is currently awaiting
  the stream. It reuses the already-reviewed connect-deadline scaffolding in `start` (serial
  `nw-byte-stream` queue, idempotent resolution, `lifecycle.cancel()`) rather than introducing a
  parallel async structure.
- **Rejected: a transport-agnostic `withIdleTimeout` stream combinator.** Its appeal is
  unit-testability without sockets. It is less correct here -- but *not* for the naive reason
  that it "measures consumer pacing": because `open`'s stream is `.unbounded`-buffered and the
  producer self-drives (`receive` re-arms synchronously on the connection queue, independent of
  the consumer), a wrapper would in fact track socket cadence in the common case. The real costs
  are concrete -- it can only watch the gap between `next()` pulls on the already-buffered stream
  (a proxy, and live only while something is awaiting), it cannot cancel the underlying
  `NWConnection` directly (reclaiming the socket depends on cancellation propagating into an inner
  drain that is itself parked in a non-cancellable `connection.receive`), and it is a second async
  structure with its own teardown/cancellation-correctness burden. We test the socket-level design
  with an integration harness instead (below), including a slow-consumer false-kill guard. That guard
  pins the *behavioral* property (a slow consumer is never false-killed), not *which* design achieves
  it -- by the same "live only while awaiting" reasoning, a per-await combinator would pass it too --
  so the case against the combinator rests on the argument here, not on a discriminating test.
- **Universal, single shared chokepoint.** Because the bound lives in `NWByteStream`, all
  seven live `NWByteStream` clients (health, status, events, clips, clip-pull, preview,
  recording) gain it at once. For status/health/clips/recording it is their first post-connect
  bound (status is now a one-shot read with no whole-fetch timeout -- ADR 10 retired that
  layer); for preview/clip-pull it rides the existing backoff/resume; for events it is a
  *transport* backstop beneath the app's 6s heartbeat-timeout liveness policy -- the idle
  default is set *above* that timeout (section 2) so the heartbeat stays the events-liveness
  authority. The thrown error funnels gracefully through every consumer with no per-client logic
  change (verified: preview -> `PreviewError.connectionFailed` -> `PreviewFeature#scheduleReconnect`;
  clip pull -> `ClipPullClient#runAttempt`'s `catch` -> `.retry`; events ->
  `EventsError.connectionFailed` -> `AppFeature` `.streamFailed` -> offline + `scheduleReconnect`;
  request/response -> each client's `catch` -> `.transport`).

### 1. Transport: the idle deadline (`NWByteStream.swift`)

- Add `NWByteStreamError.receiveIdleTimedOut`.
- Add a **required** `receiveIdleTimeout: Duration` parameter to `NWByteStream.open` (no
  transport-level default constant -- single source of truth is `AppConfiguration`, mirroring
  how `connectTimeout` is handled).
- Hoist the serial `DispatchQueue` (today created inside `start`) up to `open` so the same
  queue drives `connection.start(queue:)`, the connect deadline, the `receive` callbacks, and
  the idle work item. Pass it (plus `lifecycle` and `receiveIdleTimeout`) into `receive`.
- In `receive(from:...)`, maintain a rearmable idle `DispatchWorkItem`:
  - Arm it when the receive loop starts (covers a connection that goes silent immediately
    after `send`, before any byte).
  - In the `connection.receive` completion handler (runs on the serial queue): cancel the
    pending idle item; on data/continue re-arm a fresh one before re-calling `receive`; on
    `error`/`isComplete` cancel and do not re-arm.
  - Idle item body: `lifecycle.cancel()` then
    `continuation.finish(throwing: NWByteStreamError.receiveIdleTimedOut)`.
  - Invariants (mirror `start`'s `NWConnectionStartResolution`): a single terminal resolution,
    guarded by a serial-queue `didFinish` flag (the queue is serial, so no lock); the idle item
    is a no-op once the stream has terminated; and -- the symmetric guard -- the
    `connection.receive` completion handler short-circuits the instant `didFinish` is set: no
    yield, no re-arm, no re-`receive`. That closes the race where a `data`/continue callback
    already enqueued on the serial queue runs just after the idle item has fired and cancelled the
    connection; without the short-circuit it would re-arm a fresh idle item and re-enter `receive`
    on an already-cancelling connection. It is benign either way (the fresh item no-ops on
    `didFinish`; the re-`receive` returns `ECANCELED` -> terminal no-op), but the invariant should
    be airtight -- it mirrors how `NWConnectionStartResolution.finish` nils `stateUpdateHandler` on
    resolution. `continuation.finish` is idempotent. Reuse the existing `dispatchInterval(for:)`
    Duration->`DispatchTimeInterval` helper.
- Leave the existing `onTermination { lifecycle.cancel() }` and connect-deadline logic intact.
- **Send phase stays unbounded, by design.** This fix bounds only the receive loop;
  `NWByteStream#send` gets no deadline. Every request body is tiny (GET headers; a `{}` POST), so
  `connection.send`'s `.contentProcessed` resolves when bytes hit the local kernel buffer, not on a
  peer ACK -- the "AP goes silent" failure mode cannot strand it in practice, and a send timer
  would be YAGNI. Called out so the "post-connect" bound is never read as covering send (scoped in
  the ADR too).

This is the seam most worth a careful concurrency pass -- run the change through the
`swift-concurrency-pro` skill before commit.

### 2. Config: thread the timeout (mirror `DANCAM_CONNECT_TIMEOUT_MS` exactly)

- `app/DanCam/DanCam/App/AppConfiguration.swift`: add
  `cameraAPIReceiveIdleTimeoutEnvironmentKey = "DANCAM_RECEIVE_IDLE_TIMEOUT_MS"`,
  `defaultCameraAPIReceiveIdleTimeout = .seconds(8)`, a stored
  `var cameraAPIReceiveIdleTimeout: Duration`, and a
  `configuredCameraAPIReceiveIdleTimeout(environment:)` reader. It reuses the existing
  `configuredDuration(fromMilliseconds:)` helper, then **enforces the floor**: an override is
  accepted only if it parses *and* is strictly greater than the heartbeat timeout; anything
  missing, invalid, or `<=` the heartbeat falls back to `defaultCameraAPIReceiveIdleTimeout` (8s).
  Wire it into `live(environment:...)`. **Standalone, not derived** from the connect timeout -- it
  is an independent failure mode (zero-bytes inactivity, reset on every chunk), so it does not ride
  the connect-timeout knob; its only coupling is the heartbeat *floor* below.
- **Make the floor real in code, not just prose.** Today `heartbeatTimeout` is a hardcoded
  `.seconds(6)` computed property. Promote that 6s to a single named static constant that the
  `heartbeatTimeout` property returns *and* the receive-idle reader checks against, so the floor
  tracks the heartbeat from one source of truth (a future heartbeat change moves the floor with it,
  no silent drift). The reader rejecting a sub-heartbeat override is what makes the documented
  invariant `receiveIdleTimeout > heartbeatTimeout` impossible to break via the one mechanism that
  can change the value -- the `DANCAM_RECEIVE_IDLE_TIMEOUT_MS` env knob.
- **Default 8s, deliberately above the 6s heartbeat timeout (the events interaction).**
  Connection truth is now the long-lived `/v1/events` stream, which `AppFeature` bounds at the
  app layer with a 6s heartbeat timeout -- 3 missed 2s Pi heartbeats (ADR 10). That 6s is a
  *deliberate* congestion-tolerance number for the 2.4 GHz link. A transport receive-idle set
  *below* it would make the events stream *less* tolerant than its own policy: a 5-6s congestion
  gap the heartbeat is designed to ride out would instead throw `receiveIdleTimedOut` ->
  `.streamFailed` and reconnect early. So the default sits *above* the heartbeat timeout (8s):
  for the events stream the 6s heartbeat policy always decides liveness first and the transport
  idle is a pure backstop (and `.streamFailed` and `.heartbeatTimedOut` funnel to the *identical*
  offline + `scheduleReconnect` outcome -- verified in `AppFeature` -- so a backstop fire changes
  nothing observable). No steady-state false-kill risk either: a healthy events stream carries a
  heartbeat every 2s, a 4x margin under 8s. 8s is still a fine silent-stall backstop for the other
  six clients -- the S1 fix is "finite instead of forever," and 8s vs 5s is immaterial for a rare
  hung socket. The invariant `receiveIdleTimeout > heartbeatTimeout` is an *enforced* floor, not a
  derivation: the two stay independent knobs (a valid override of 7s or 12s is used as-is), but the
  config reader rejects any override at or below the heartbeat and falls back to the 8s default, so
  the env knob cannot silently break the invariant. Record it here, in ADR 11, and in a one-line
  comment at the reader's floor check so a future change to either number is a conscious revisit.
- `app/DanCam/DanCam/App/AppDependencies.swift#init(configuration:)`: pass
  `receiveIdleTimeout: configuration.cameraAPIReceiveIdleTimeout` into each `.live(...)` client.
- Each client `.live(baseURL:pinning:connectTimeout:)` factory gains a `receiveIdleTimeout:
  Duration` argument forwarded into its `NWByteStream.open(...)` thunk. Repeat once per client
  across all seven: `HealthClient`, `StatusClient`, `EventsClient`, `ClipsClient`, `ClipPullClient`,
  `PreviewClient`, `RecordingClient`. (`EventsClient.live` has two overloads -- thread the new
  argument through the `connectTimeout:` convenience overload that builds the `NWByteStream.open`
  thunk; the `openByteStream:`-injecting test seam takes no transport timeouts and is unaffected.
  The other six follow the same convenience-overload shape.)

## Tests (Swift Testing; `just app-test`)

- **New `app/DanCam/DanCamTests/Networking/HTTP/NWByteStreamTests.swift`** -- the first
  transport-layer test, using a loopback `NWListener` on `127.0.0.1` (pinning `.disabled`).
  Two behavioral, structure-insensitive claims (assert outcomes, not internals):
  - `stalledReceiveSurfacesAsReceiveIdleTimeout`: listener accepts, sends a partial HTTP head
    (or a few bytes), then goes silent. Open with a short `receiveIdleTimeout`
    (e.g. `.milliseconds(200)`). Assert the stream throws
    `NWByteStreamError.receiveIdleTimedOut` within a generous bound (~1-2s). *This is the
    regression the finding describes -- a stall now surfaces instead of hanging.* The *must-fire*
    direction is jitter-robust (scheduling jitter only delays the fire), so a short window is safe.
  - `slowButValidTransferSurvives`: listener accepts, delivers chunks paced well under the idle
    window, and finishes. Assert all bytes arrive and the stream finishes cleanly with no throw.
    *This locks in the false-kill guard ADR 09 warns about -- the scariest part of the change*, and
    the stakes are real beyond the test: a too-tight idle bound that false-fires in production burns
    `ClipPullClient`'s hard `maxAttempts = 6` budget (A-02: never resets on progress), discarding a
    near-complete clip. Because it is a *must-NOT-fire* assertion, give it its own generous window
    (~1s) with chunks well under it (~50-100ms -- a 10-20x margin), opening `NWByteStream`
    independently from the stall test so the two windows need not share a value.
  - `slowConsumerDoesNotTripIdleTimer`: a slow-*consumer* false-kill guard -- the must-NOT-fire
    sibling of `slowButValidTransferSurvives`, isolating *consumer* pace (not sender pace) as the
    variable. Listener delivers chunks well under a short window (e.g. ~20-30ms chunks under a
    `receiveIdleTimeout` of `.milliseconds(250)` -- a ~10x margin) while the *consumer* deliberately
    sleeps longer than the window (e.g. ~400ms) between reads. Assert all bytes arrive and the stream
    finishes with no throw. It pins the behavioral guarantee that matters: a consumer slower than the
    idle bound is never false-killed, because the timer is reset by *socket* reads, not consumer
    demand. It deliberately does **not** try to pin *which implementation* achieves that -- a rejected
    per-await combinator would in fact *also* pass this test (its timer is live only while a consumer
    awaits `next()`, and since `open`'s stream is `.unbounded` + self-driving the bytes are already
    buffered, so each eventual `next()` resolves instantly and never sees a >window gap -- the same
    "live only while awaiting" reasoning the Approach bullet and ADR use). The genuine
    socket-vs-consumer discriminator -- the timer fires *even with no consumer awaiting* -- is a
    fiddlier, structure-sensitive assertion left unpinned on purpose, per the test-quality bar
    (behavioral, structure-insensitive only). The consumer pause exceeds the window so consumer
    slowness is genuinely exercised (a pause under the window would not test it at all), not to catch
    a refactor. Margins, as in `slowButValidTransferSurvives`: the *sender* cadence governs
    current-code flakiness (a sender `Task.sleep` overshooting the window would false-fire the timer,
    since the sender's socket writes keep the connection-queue timer alive), so ~10x under the window;
    the *consumer* pause only needs to clearly exceed the window (~400ms > 250ms). The window stays
    *small* (not widened to the survive test's ~1s) precisely because the consumer pause must exceed
    it -- a small window keeps that pause, and the test, fast. Kept separate from
    `slowButValidTransferSurvives`: the slow-sender guard wants a *large* window while this
    slow-consumer guard wants a *small* window the consumer pause can exceed, so no single shared
    window serves both, and each keeps one behavioral reason to fail.
  - Keep the harness focused on the new receive-idle behavior; do **not** add a connect-deadline
    test here. On loopback a non-accepting port returns connection-refused (RST -> `.failed`),
    not `connectTimedOut`; reliably parking in the connecting state needs a blackhole address
    that silently drops SYNs, which is not deterministic in a unit test. The connect deadline
    stays manually covered, as ADR 09 established.
  - These are the suite's first wall-clock-*deadline* assertions and the stall-capable loopback
    listener is net-new -- no existing harness fits, so the generous margins above are the
    load-bearing mitigation, not a borrowed precedent. (For the record: `AppFeatureTests` resolves
    its injected `heartbeatTimeout` via an `AsyncSignal` with zero elapsed time -- the suite's idiom
    for *avoiding* wall-clock waits; `PreviewClientTests.pacedByteStream` sleeps 1ms between chunks
    but asserts only on content; and `LoopbackMediaServer` is POSIX-socket + `URLSession` and always
    responds immediately, so none can accept-then-go-silent.)
- **`app/DanCam/DanCamTests/App/AppConfigurationTests.swift`**: add `cameraAPIReceiveIdleTimeout`
  cases mirroring the connect-timeout tests -- default (no env -> `8s`), valid override
  (`DANCAM_RECEIVE_IDLE_TIMEOUT_MS=12000` -> `12s`, distinct from the default so the override is
  genuinely exercised), invalid/zero/negative (`"abc"`,`"0"`,`"-1"` -> default `8s`). Plus the
  **floor** cases that make the `receiveIdleTimeout > heartbeatTimeout` invariant behavioral:
  below-heartbeat (`"5000"` -> default `8s`) and equal-heartbeat (`"6000"` -> default `8s`) both fall
  back, while just-above-heartbeat (`"7000"` -> `7s`) is accepted -- pinning the floor's boundary from
  both sides (a sub-heartbeat override is rejected; a just-valid one passes, so a blanket-reject
  regression is caught too). This is the one piece of net-new behavior the change adds (the floor
  lives only in config).
- **No new consumer tests needed.** A thrown idle error rides paths already covered: the
  `.retry`/resume tests in `ClipPullClientTests` (via `droppingByteStream`/`ScriptedResponder`),
  `PreviewClientTests.byteStreamFailureMapsToConnectionFailed`, and -- for the events stream --
  `EventsClientTests.mapsByteStreamFailure` (a byte-stream error maps to `EventsError`) plus
  `AppFeatureTests.streamFailureGoesOfflineAndSchedulesReconnect` (an events-stream throw goes
  offline and schedules a reconnect) already prove the downstream funnels -- the error's *source*
  is irrelevant to them.

## ADR + docs

- **New `app/docs/design/11-2026-06-30-receive-idle-deadline.md`**, Status **Accepted** (ADR 10
  `event-folded-state-machines` already holds the `10-` sequence, so this is `11-`). Related: ADR 09
  (the deferral) and ADR 10 (the heartbeat-timeout policy this must not undermine). One decision: a
  rearmed-per-chunk receive-idle deadline in `NWByteStream`, applied to all seven live
  `NWByteStream` clients, default 8s via `DANCAM_RECEIVE_IDLE_TIMEOUT_MS`, surfacing a stall as a
  retryable thrown error.
  - Context = the silent-stall hang above + ADR 09's explicit deferral.
  - Consequences = all seven live `NWByteStream` clients bounded on the post-connect *receive* path;
    preview/clip-pull ride existing backoff/resume; status/health/clips/recording gain their first
    post-connect receive bound; the events stream gets a *transport* backstop beneath its app-level
    6s heartbeat policy, with the default chosen above that timeout and the invariant
    `receiveIdleTimeout > heartbeatTimeout` *enforced* in the config reader (a sub-heartbeat env
    override falls back to the 8s default, off one shared heartbeat constant) so the heartbeat stays
    the events-liveness authority;
    the send phase stays intentionally unbounded (tiny bodies); first `NWByteStream` test harness
    built (covers the receive-idle behavior, including a slow-consumer false-kill guard; the connect
    deadline stays manually covered, per ADR 09).
  - Alternatives considered = transport-agnostic combinator (rejected: a downstream wrapper of the
    `.unbounded`, self-driving stream still tracks socket cadence, so the decisive losses are that
    it cannot cancel the `NWConnection` directly and its timer is live only while a consumer awaits
    `next()` -- not that it "measures consumer pacing"); send-phase deadline (rejected: YAGNI --
    tiny request bodies, so `.contentProcessed` resolves at kernel-queue time and a silent peer
    cannot strand `send`); derive from connect timeout (rejected: independent failure mode); a
    default *below* the 6s heartbeat timeout, accepting that the transport idle preempts the events
    heartbeat (rejected: it makes the events stream less congestion-tolerant than its deliberate
    app-level policy -- the reviewer offered this as a "state it deliberately" option, but the ideal
    is to preserve the heartbeat policy by setting the default above it); a separate, longer idle
    value just for `EventsClient` (rejected: YAGNI -- a single value above the heartbeat timeout
    serves all three traffic profiles, so events does not need its own knob); per-client idle values
    generally (rejected: YAGNI -- one value serves bulk pull, MJPEG preview, and the heartbeat-paced
    events stream); whole-request timeout in `HTTPRequestResponse#roundTrip` (already rejected by
    ADR 09; restate).
- **Refinement note on ADR 09** (`09-2026-06-29-connection-liveness-timeouts.md`): ADR 09 already
  carries a 2026-06-30 note that ADR 10 superseded its *status-monitor* liveness layer. Add a
  second, narrower forward pointer for the other deferral -- the receive-loop one in its "Hard or
  risky" consequences: `> **Note (2026-06-30):** the deferred post-connect receive-idle policy (the
  unbounded preview/clip-pull receive loops) is now decided in ADR 11.` Append-only-safe pointer,
  matching the repo's refinement-note practice; do not rewrite ADR 09's body.
- **`app/AGENTS.md` ADR index**: the index currently stops at ADR 09 -- ADR 10
  (`event-folded-state-machines`) landed without an index entry, so backfill that line *and* add
  the new ADR 11 (`receive-idle-deadline`) line, leaving the index complete through 11.
- Run `just adr-check`.
- **No README change** -- nothing here touches Pi provisioning or onboard state.

## Verification

- `just app-build` then `just app-test` green: new `NWByteStreamTests` and the added
  `AppConfigurationTests` cases pass; all existing suites still pass.
- `just adr-check` passes (validates the new ADR filename/sequence).
- Manual (exercises the real transport end-to-end, which the unit harness only approximates):
  - **Clip pull:** point the app at a host that accepts then goes silent mid-body and open a
    clip. Confirm the pull surfaces a retry within ~8s (the default idle bound) and the viewer
    leaves "...pulled" (eventually "Clip failed" after the attempt budget) instead of hanging forever.
  - **Preview:** same silent host, open live preview. Confirm it flips to "Connecting" and
    rides the reconnect backoff rather than freezing on the last frame.
  - **Events / heartbeat interaction:** point the app at a host that serves `/v1/events` (head +
    a few 2s heartbeats) then goes silent. Confirm the strip goes "Not connected" and reconnects
    via the ~6s heartbeat timeout -- *not* earlier via a transport `receiveIdleTimedOut` -- proving
    the 8s default sits above the heartbeat policy.
  - **Slow-but-valid:** confirm a normal (slow) clip pull over a real link still completes to
    "Ready" -- no false idle-timeout.

## Out of scope / deferred

These are sibling findings from the same review (Lane A) sharing the clip-pull path but with
distinct root causes -- track separately, do not fold in here:

- **A-02:** `ClipPullClient#producePull` retry budget is a hard count that never resets on
  forward progress (a flaky link discards a near-complete clip). Interacts with this fix
  (false-positive idle timeouts would burn the budget) but is its own policy decision.
- **A-03:** body appended with the exception-raising `FileHandle.write(_:)` -- a disk-full
  mid-pull traps the process; swap to `write(contentsOf:)`.
- Per-client idle values, and any general timeout utility -- only if a second need appears.
