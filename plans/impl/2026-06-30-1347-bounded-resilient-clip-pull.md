# Plan: Bounded, resilient clip pull (progress-based retry budget)

## Context

The app's resumable clip pull (`ClipPullClient`) gives up too early on a flaky link,
contradicting the transport ADR's "resume is the normal case on this link"
(`app/docs/design/02-2026-06-22-app-pi-transport-and-api.md`). A companion silent-stall
hazard (review lane A, finding A-01) has since been closed at the transport layer by
ADR 11, so this plan now only has to make the clip-pull budget (finding A-02) account
correctly for the retry that fix produces.

1. **The retry budget counts total reconnects, not consecutive no-progress ones.**
   `ClipPullClient.swift#producePull` runs `var attempt = 0`, increments on every
   reconnect, and never resets when an attempt advances the byte offset; `maxAttempts = 6`.
   A clip that drops more than 5 times within one pull -- entirely plausible mid-drive on
   a congested link, *even when every reconnect made progress* -- throws
   `ClipPullError.transport`. The catch deletes the temp (`shouldKeepOutput == false`), and
   the sole consumer re-pulls from byte 0 (`ClipViewerViewController` builds a fresh VC;
   `prepareOutputURL` wipes any `clip-<id>-*.ts`). A near-complete file is discarded.

2. **The silent stall is now a bounded, retryable transport error -- the budget must
   count it.** The realistic 2.4 GHz failure is not a clean reset but the AP silently
   ceasing to forward / the phone drifting out of range: the socket stays `.ready`, no
   bytes arrive, no FIN/RST is delivered. That used to suspend `NWByteStream`'s receive
   loop forever. It no longer does: ADR 11
   (`app/docs/design/11-2026-06-30-receive-idle-deadline.md`) added a rearmed-per-chunk
   receive-idle deadline inside the shared `NWByteStream` transport -- armed when the
   receive loop starts (so it bounds even a stall *before the first byte*), cancelled on
   each receive completion, rearmed while the stream continues, and on expiry it cancels
   the `NWConnection` and finishes the stream with `NWByteStreamError.receiveIdleTimedOut`.
   That error reaches `ClipPullClient.runAttempt` as an ordinary mid-stream throw. So the
   stall is no longer a hang; it is just one more reconnect -- and the only remaining
   clip-pull work is defect #1's budget, which must count a stall-before-progress as a
   no-progress reconnect instead of burning one of a fixed total.

**Intended outcome:** a clip pull that gives up only after a bounded number of
*consecutive* reconnects that each failed to advance a byte -- never on a link that is
making forward progress -- and that correctly rides out the transport's now-bounded
silent-stall retry (ADR 11) as a no-progress reconnect. Each attempt is already
time-bounded by the transport's connect deadline (ADR 09) and receive-idle deadline
(ADR 11); the whole pull terminates in bounded time on a genuinely dead link and
otherwise runs to completion.

## Scope decision

This plan is **clip-pull retry policy on top of an already-bounded transport.** The
receive-idle deadline finding A-01 asked for is no longer clip-pull work: ADR 11
implemented it once inside `NWByteStream` for every plane (health, status, events, clips,
clip pull, preview, recording), and
`ClipPullClient.live(baseURL:pinning:connectTimeout:receiveIdleTimeout:)` already forwards
the configured `receiveIdleTimeout` (`AppDependencies` threads
`AppConfiguration.cameraAPIReceiveIdleTimeout` -- default 8 s, floored above the 6 s
heartbeat timeout) into `NWByteStream.open`. So the scope here is the policy the transport
cannot own: a progress-based retry budget, a contradictory-ranged-`200` guard that keeps
that budget honest, typed exhaustion, and a surfaced failure message.

**Out of scope (deliberate):**
- **The receive-idle deadline itself.** Implemented transport-wide in ADR 11; this plan
  *consumes* `NWByteStreamError.receiveIdleTimedOut` and adds no idle timer, injected idle
  seam, coordinator, or sentinel of its own. This is the recorded pivot away from this
  plan's earlier client-layer idle-wrapper design (and from finding A-01's "add it inside
  `NWByteStream`" framing): the deadline now lives once in the transport, and clip pull
  rides the retry it produces.
- **Cross-pull / cross-launch resume** (persist the validator + keep the partial `.ts` and
  resume on the next pull). With the budget fix, any pull that advances a byte within the
  transport idle window completes; the budget only fires when the link is genuinely dead,
  where failing is correct. Resuming across VC instances / app launches is persistent-state
  machinery touching the consumer and temp-file lifecycle -- a separate future ADR. This is
  why the finding's "keep the partial temp on exhaustion" clause is dropped: it is a no-op
  without that feature.

## Change 1 -- Progress-based retry budget (`ClipPullClient.swift#producePull`)

Replace the single `attempt` counter with two bounds:

- `consecutiveStalls` -- reconnects since the last attempt that wrote body bytes. Key it
  off an explicit progress signal from `runAttempt`, **not** a before/after `bytesWritten`
  comparison (see "Progress signal" below): on a `.retry(madeProgress:)`, set
  `consecutiveStalls = 0` when `madeProgress` is true, else `consecutiveStalls += 1`. Cap
  at a new `maxConsecutiveStalls` (keep the current "feel", ~6). This is the real give-up
  policy.
- `totalReconnects` -- a generous absolute ceiling (order of a few hundred) as a runaway
  guard for the pathological "1 byte per reconnect forever" case. Throw if either bound
  trips.

**Progress signal (do not infer from `bytesWritten`).** Change `AttemptOutcome.retry` to
`.retry(madeProgress: Bool)` and have `runAttempt` set it true iff it wrote at least one
decoded body byte during the attempt -- thread a wrote-bytes flag/count out of
`writeDecodedChunks`, covering every `.retry` site (connect/open failure reports `false`;
mid-stream drop, premature EOF, and the transport receive-idle timeout
(`NWByteStreamError.receiveIdleTimedOut`, ADR 11) report whatever was written this
attempt). A before/after `bytesWritten` comparison is wrong: an accepted `200`
validator-change restart truncates and rewrites from 0 (`prepareBodyDecoder`, status 200
with `usedRange == true`, sets `bytesWritten = 0`), so an attempt that legitimately wrote
a *smaller* new representation and then dropped ends with `bytesWritten` below the
pre-attempt snapshot and would be miscounted as a stall. Keying on
bytes-written-this-attempt is the right progress signal for a `206` resume or a mid-stream
drop. On its own it does **not** terminate a repeated-`200`-rewrite loop: each rewrite
writes body bytes, so `madeProgress` is true and `consecutiveStalls` resets. That loop is
instead cut off at its source by Change 1b (a same/missing-validator ranged `200` becomes
terminal `.malformedResponse`); the only residual 200-restart loop -- a server inventing a
genuinely new validator on every reconnect -- is backstopped by `maxTotalReconnects`.

Rename `maxAttempts` -> `maxConsecutiveStalls`; add `maxTotalReconnects`; update the
doc comment (the existing "Tune once the spike's pull-time numbers land" admits the count
is a placeholder). Carry the two exhaustion reasons as a *typed* value -- a dedicated
`ClipPullError.exhausted(ExhaustionReason)` case (`.consecutiveStalls` / `.totalReconnects`),
distinct from the generic `.transport(String)` wrapper that still carries arbitrary
transport errors -- so the cause that fired is structural, not parsed back out of a message
string. Change 3's `errorDescription` owns the user-facing copy for each reason; tests
assert the typed reason (structure-insensitive) rather than the message text.

Key the backoff off `consecutiveStalls` so a progressing link never accumulates long
backoff. **Make `backoffDuration` 0-safe** -- it currently computes `1 << (attempt - 1)`
with `attempt >= 1`; passing a 0 stall count would shift by -1 and trap. Guard the shift
(treat 0 stalls as the base, near-instant, since we just made progress).

Cleanup is unchanged: terminal failure still closes the handle and deletes the temp
(correct -- there is no cross-pull resume). The within-pull bytes are already preserved
across attempts via the persistent `bytesWritten`/`resumeETag` state; this change just
stops a progressing link from ever reaching the terminal path.

## Change 1b -- Reject a contradictory ranged `200` (`ClipPullClient.swift#prepareBodyDecoder`)

The `status == 200` / `usedRange == true` branch currently treats *any* `200` answer to an
`If-Range` resume as a legitimate validator-change restart: it truncates, rewrites from 0,
and updates `resumeETag` only *if* the response carries an `ETag`. It never checks that the
new validator actually differs from the one we just sent. A server that answers a ranged
request with `200` and the *same* (or a missing) `ETag` therefore drives an endless
truncate-rewrite-from-0 loop -- and because each pass writes body bytes, Change 1's progress
signal treats every pass as forward progress, so `consecutiveStalls` never accumulates and
only the far-larger `maxTotalReconnects` ceiling stops it.

Harden the branch: accept the `200` restart only when it carries an `ETag` that *differs*
from `resumeETag` (the value just sent in `If-Range`); otherwise throw
`ClipPullError.malformedResponse` (terminal). A `200` echoing the same validator is a
contract violation -- the server signalled "validator no longer matches" yet returned the
matching tag -- and a `200` with no validator is unresumable; both are server bugs, not
rideable drops, so failing fast with a clear message beats spinning to the ceiling. Compare
the wire `ETag` strings as sent (no normalization beyond what `httpEntityTag` already
applies). This is the surgical cure for the repeated-`200`-rewrite loop, which is why
Change 1's progress signal does not special-case it.

## Change 2 -- Account for the transport receive-idle retry (`ClipPullClient.swift#runAttempt`)

Finding A-01's silent-stall bound is delivered by ADR 11 inside the shared transport, so the
only clip-pull work is to ensure `runAttempt` rides out the retry it produces -- which the
existing catch ladder already does once Change 1's progress signal lands. Concretely:

- **The idle error arrives as an ordinary upstream throw.** `NWByteStream` arms its
  receive-idle deadline only after `open(...)` has connected, sent, and returned the stream,
  so a silent stall always surfaces *inside* `runAttempt`'s `for try await chunk in
  byteStream` loop (delivered via the stream's `continuation.finish(throwing:)`), never from
  the `openByteStream(...)` call itself. Even a stall before the first byte surfaces as a
  throw on the first `next()`.
- **The generic catch already rides it out.** `NWByteStreamError.receiveIdleTimedOut` is not
  a `ClipPullError`, so it falls past `runAttempt`'s `catch let error as ClipPullError` arm
  to the trailing generic `catch`, which Change 1 turns into
  `return .retry(madeProgress: wroteBodyBytesThisAttempt)` -- exactly the path a mid-stream
  transport drop takes. A stall after some body bytes resets `consecutiveStalls`; a stall
  before any body byte is a no-progress reconnect. The next attempt resumes from the last
  byte via `Range`/`If-Range`, and the transport already tore the stalled `NWConnection`
  down on expiry (`lifecycle.cancel()`), so nothing leaks.
- **Add nothing.** No clip-pull-specific idle timer, injected idle seam, coordinator, or
  sentinel error. Do **not** add a `catch let error as NWByteStreamError { throw error }`
  arm -- that would route the stall into the terminal path and invert the feature
  (immediate-fail instead of retry). The transport-agnostic `openByteStream` test seam stays
  unchanged (ADR 11 deliberately kept it timeout-free), and `ClipPullClient.live(...)`
  already forwards `receiveIdleTimeout` into `NWByteStream.open`, so production sockets are
  already bounded with no further wiring.

## Change 3 -- Surface the failure message (`ClipPullClient.swift#ClipPullError`)

`ClipPullError` is a bare `enum: Error, Equatable` with no `LocalizedError` conformance,
so `ClipViewerViewController.swift#runPull`'s `error.localizedDescription` bridges to a
generic NSError string ("...error 3.") and the descriptive `.transport(...)` /
`.malformedResponse(...)` payloads never reach the user's `resultLabel`. Add
`LocalizedError` with an `errorDescription` per case -- including a distinct string for each
`.exhausted` reason (`.consecutiveStalls` vs `.totalReconnects`) -- so the bounded-pull
failure message is actually shown. This is where the user-facing copy lives: the budget
throws the *typed* reason (Change 1) and `errorDescription` owns the wording, so tests
assert the typed reason and never pin copy. Small, self-contained, and clearly correct
regardless of the rest.

## Tests

Reuse `ClipPullClientTests.swift` infrastructure: `ScriptedResponder` (`.drop([Data])` /
`.finish([Data])` / `.throwOnOpen`, one step per attempt), `ok200`/`partial206` builders,
`progressValues`/`requireCompleted`/`pullError`, and the no-op `sleep` from `makeClient`.

- **Many progressing drops still complete.** Open with a `200` (partial body, then drop),
  then chain `206` resumes -- each delivering part of the tail then dropping so the file
  advances toward the whole-file length -- so the run of progressing drops comfortably exceeds
  `maxConsecutiveStalls` (e.g. a leading `200` drop + 8 `206` drops), then `.finish`; assert
  `.completed` with the whole file and the expected resume requests. The script *must* open
  with the `200`, not a `206`: attempt 1 is always a plain `GET` (nothing on disk,
  `makeRequest` with `bytesWritten == 0`), and `prepareBodyDecoder`'s `usedRange == false`
  branch throws terminal `ClipPullError.http(status)` for any non-`200`, so a leading `206`
  would fail immediately with `.http(206)` instead of exercising the budget -- this is the
  exact `200`-then-`206` shape of the existing `resumesFromLastByteAfterMidPullDrop`. The
  chained `206`s need a builder variant that *decouples* `Content-Length` (the promised tail,
  to the whole-file end) from the delivered body: `partial206` currently sets
  `Content-Length: \(body.count)`, so a short delivered body frames the decoder complete at
  that count and `runAttempt` throws `.malformedResponse` ("Body framed complete before
  whole-file length") instead of riding the drop out -- trivial to add since
  `MJPEGWireBuilder.response` already takes explicit headers. Note the shape differs from
  `restartsAndTracksTheNewValidatorWhenItChanges`, which chains *new-validator `200`s* (each
  truncates and rewrites from 0) -- that is the validator-restart variant, not genuine forward
  progress on one stable representation. This *cannot* pass under the current total-attempt
  budget -- it is the regression lock for Change 1.
- **Consecutive stalls exhaust the budget.** Script `maxConsecutiveStalls` no-progress
  reconnects (empty `.drop([])` or `.throwOnOpen`); assert
  `ClipPullError.exhausted(.consecutiveStalls)`. Add an `expectExhausted(_:reason:)` matcher
  (only `expectMalformed` exists today); this is the currently-untested give-up path.
- **Progress resets the stall counter.** Interleave no-progress and progressing drops so
  the total exceeds `maxConsecutiveStalls` but no run of consecutive no-progress drops
  does; assert completion.
- **Absolute ceiling stops a forever-progressing link.** Script `maxTotalReconnects + 1`
  one-byte-advancing drops, each a `200` carrying a *fresh* validator (the residual
  genuinely-new-validator-every-reconnect loop Change 1b deliberately leaves to this ceiling
  -- `ok200` already decouples `Content-Length` from the delivered body via `total`, so no
  new builder is needed here; generate the steps programmatically; no-op `sleep`). Every
  attempt writes a byte so `consecutiveStalls` never accumulates -- only the total ceiling
  can fire -- so assert `ClipPullError.exhausted(.totalReconnects)` (typed, so the test does
  not pin user copy and is distinct from the consecutive-stall reason). This is the
  regression lock for `maxTotalReconnects`; without it the runaway guard can be dropped or
  broken silently while every other test still passes. (If the chosen ceiling makes
  ~hundreds of scripted steps unwieldy, expose the two caps on the `live(...)` seam so the
  test can set a small value -- but keep production on constants.)
- **A contradictory ranged `200` fails fast as malformed.** Script an initial `200` (some
  bytes) -> drop -> a ranged `200` whose `ETag` equals the one the resume's `If-Range`
  carried; assert `ClipPullError.malformedResponse` is thrown on the *first* such response
  (not after the stall budget), and add a same-shape case for a ranged `200` carrying no
  `ETag`. This is the regression lock for Change 1b; without the guard both scripts loop on
  truncate-rewrite-from-0 until `maxTotalReconnects` while every other test still passes.
- **A transport receive-idle timeout rides out as a no-progress-aware retry.** The
  transport's wall-clock receive-idle behavior is owned and tested by `NWByteStreamTests`;
  here, prove only that `runAttempt` *routes* the resulting error correctly, through the
  existing injected `openByteStream` seam (no real timing). Add a `ScriptedResponder` step
  that finishes the byte stream by *throwing a given error* (today's `.drop` finishes with a
  generic transport error) and script two cases that pin the error to
  `NWByteStreamError.receiveIdleTimedOut`: (a) a `200` head plus some body bytes, then that
  throw -> assert the attempt is ridden out and a subsequent good attempt resumes from the
  last byte and completes (madeProgress true -- the stall reset the counter, like any
  progressing drop); (b) that throw before any body byte lands, repeated each reconnect ->
  assert `ClipPullError.exhausted(.consecutiveStalls)` (madeProgress false -- a no-progress
  reconnect, like an empty drop). This is the regression lock that the transport's idle error
  is treated as a rideable drop and never special-cased into the terminal `ClipPullError`
  arm: a stray `catch let error as NWByteStreamError { throw error }` in `runAttempt` would
  invert the feature while every existing drop test (which uses the generic error) still
  passes. Do **not** assert wall-clock idle timing in `ClipPullClientTests` --
  `NWByteStreamTests` owns that.
- **Consumer surfaces the message (required).** Add a `ClipViewerViewControllerTests.swift`
  case whose fake pull client finishes the stream throwing `ClipPullError.transport(...)`
  (no existing case drives a *thrown* pull to `.failed`); assert the `.failed` state and
  that `resultLabel.text` renders the **exact** `errorDescription` of that error (Change 3).
  Required, not optional: it is the regression lock for the `LocalizedError` conformance --
  without it, reverting the conformance leaves the generic NSError string in `resultLabel`
  and the suite still passes.

## ADR / record-keeping

Per AGENTS.md ("on every pivot, update the record in the same change"):
- Add an app-side ADR (`app/docs/design/12-2026-06-30-bounded-resilient-clip-pull.md`;
  `{seq}` is `12` -- ADR 11 took seq 11) recording the progress-based retry budget, the
  `maxTotalReconnects` ceiling, the contradictory-ranged-`200` validator guard that keeps
  the budget honest, the typed `ClipPullError.exhausted(...)`, and the `LocalizedError`
  conformance. Relate it to ADR 02 ("resume is the normal case") and to ADR 11: the silent
  stall is bounded by ADR 11's transport receive-idle deadline and reaches clip pull as a
  `NWByteStreamError.receiveIdleTimedOut` retry, which this budget counts as a no-progress
  reconnect. Record the pivot -- the receive-idle deadline moved into the shared transport
  in ADR 11 rather than a clip-pull-local wrapper -- and explicitly scope out cross-pull
  resume.
- No ADR 09 annotation here: ADR 11 already owns and records the receive-idle decision (and
  is related back to ADR 09), so this clip-pull-policy change does not re-touch ADR 09.

## Verification

- `just app-test` (full DanCamTests), or focused:
  `xcodebuild -project app/DanCam/DanCam.xcodeproj -scheme DanCam -destination
  'platform=iOS Simulator,OS=26.5,name=iPhone 17'
  -only-testing:DanCamTests/ClipPullClientTests test`.
- `just app-build` to confirm the simulator build.
- `just adr-check` to validate the new ADR's filename/sequence.
- Optional on-device sanity (no unit coverage for the real socket): run the mock Pi
  (`just raspi-mock` / `just raspi-mock-lan`), start a clip pull from the app, and force a
  mid-pull drop (kill or firewall-drop the mock) to watch the resume loop ride it out and,
  on a sustained outage, surface the bounded-pull failure message. A *silent* stall (hold
  the link open but stop forwarding bytes) is now bounded by the transport receive-idle
  deadline (ADR 11) and surfaces to clip pull as the same retryable drop.

## Critical files

- `app/DanCam/DanCam/Networking/Clips/ClipPullClient.swift` -- `producePull` (budget),
  `runAttempt` (progress signal + generic-catch rideout of
  `NWByteStreamError.receiveIdleTimedOut`), `prepareBodyDecoder` (ranged-`200` validator
  guard), `backoffDuration` (0-safe), `ClipPullError` (`.exhausted` + `LocalizedError`).
- `app/DanCam/DanCamTests/Networking/Clips/ClipPullClientTests.swift` -- new budget tests,
  an `expectExhausted(_:reason:)` matcher, a `Content-Length`-decoupled `206` builder
  variant for the progressing-drop tests, and a `ScriptedResponder` step that finishes the
  stream throwing a *given* error (for the receive-idle routing test).
- `app/DanCam/DanCam/Features/ClipViewer/ClipViewerViewController.swift` /
  `ClipViewerViewControllerTests.swift` -- thrown-pull-to-`.failed` message test; the VC
  itself already calls `error.localizedDescription` and is unchanged unless test access
  requires it.
- `app/docs/design/12-2026-06-30-bounded-resilient-clip-pull.md` -- new ADR.
- Existing ground truth, not edited: `app/DanCam/DanCam/Networking/HTTP/NWByteStream.swift`
  (the receive-idle deadline, ADR 11) and `AppConfiguration` / `AppDependencies` (the
  `receiveIdleTimeout` already threaded into `ClipPullClient.live(...)`).
