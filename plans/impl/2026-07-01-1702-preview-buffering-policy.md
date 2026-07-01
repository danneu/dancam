# Fix flaky PreviewClientTests: separate lossless decode from lossy delivery

## Context

`PreviewClientTests.realHyperChunkedFixtureDecodesMockFrameSequence` is flaky under
full-suite load (`just app-test`): failed twice / passed once on 2026-07-01, with the
same signature in clean-master runs earlier that day. The keyframe-gate commit
(52e7846) is not the cause -- its AVAssetWriter-backed remux tests only add scheduler
load that widens an existing race.

Root cause: `PreviewClient.live` builds the frame stream with
`bufferingPolicy: .bufferingNewest(1)`
(`app/DanCam/DanCam/Networking/Preview/PreviewClient.swift#static func live`) -- a
deliberately lossy channel, and correctly so: the product consumer
(`PreviewFeature.swift#connectEffect`) forwards every frame across a MainActor hop,
so without the 1-slot buffer, stale JPEGs would queue unboundedly behind a busy main
thread. But the fixture test asserts lossless delivery of all 4 frames across that
channel, kept green only by `pacedByteStream`'s 1ms-per-KB sleeps giving the consumer
time to drain between yields. Under CPU starvation the consumer misses its ~10ms
window and the 1-slot buffer overwrites undelivered frames. Failure signature from
the 2026-07-01 xcresults confirms it: delivered sequences `[0, 3]` and `[0, 2, 3]` --
middles dropped, first and last always survive. Sequence numbers are assigned in the
producer before buffering, so decode produced 0..3 in order; the streaming parsers
(each separately unit-tested) are not at fault.

Two more tests are latently racy for the same reason: `emitsFramesWithExactBytesAndSequence`
and `deChunksFramesBeforeMultipartParsing` decode 2 frames from one synchronous chunk;
if the detached producer yields both before the consumer's first `next()` suspends,
frame 0 is silently dropped and the test fails.

Fix intent: decode correctness (lossless, what these tests assert) and delivery
policy (lossy, product behavior) are different concerns. Make the policy an explicit
argument at the composition seam so decode tests run lossless and deterministic,
and add the one behavioral test the policy itself deserves.

## Design

Make `bufferingPolicy` a required (no default) parameter of the injectable seam
overload of `PreviewClient.live`. The product overload passes `.bufferingNewest(1)`
explicitly; every test passes the policy it means. No new types, no forwarding
tasks, no test-only knobs with hidden defaults -- every caller states intent.

Rejected alternative: structurally splitting a lossless decode stream that `connect`
re-wraps with a lossy stream. That pays a permanent product-path cost (second stream,
forwarding task, two-task cancellation topology) purely so tests can grab the inner
stream.

## Changes

### 1. `app/DanCam/DanCam/Networking/Preview/PreviewClient.swift`

Seam overload (currently `live(baseURL:pinning:openByteStream:)`) gains the
parameter, placed before the trailing closure:

```swift
static func live(
    baseURL: URL,
    pinning: InterfacePinning,
    bufferingPolicy: AsyncThrowingStream<PreviewFrame, Error>.Continuation.BufferingPolicy,
    openByteStream: @escaping OpenByteStream
) -> PreviewClient
```

Body: thread it into `AsyncThrowingStream.makeStream(of:throwing:bufferingPolicy:)`.
`BufferingPolicy` is a Sendable stdlib enum; no `@Sendable`/`@escaping` needed and
nothing changes for the file's `nonisolated` conventions.

Product overload `live(baseURL:pinning:connectTimeout:receiveIdleTimeout:)` forwards
`.bufferingNewest(1)` explicitly, with a one-line comment stating the constraint the
code can't show, e.g.:

```swift
// Lossy by design: live preview wants the freshest frame; stale frames must not queue behind a slow consumer.
bufferingPolicy: .bufferingNewest(1),
```

`noop` is untouched.

### 2. `app/DanCam/DanCamTests/Networking/Preview/PreviewClientTests.swift`

Rule: decode-correctness tests pass `.unbounded`; only the new policy tests below
choose their policy as the thing under test.

- `client(chunks:)` helper: hard-code `bufferingPolicy: .unbounded` in its seam call
  (all its users are decode-correctness tests; do not parameterize).
- `realHyperChunkedFixtureDecodesMockFrameSequence`: replace the direct seam call +
  `pacedByteStream(fixture)` with the existing helper fed pre-sliced chunks, keeping
  the cross-chunk-boundary parsing coverage (the point of the hyper-chunked fixture)
  while removing all timing:

  ```swift
  let client = try client(chunks: slices(of: fixture, size: 1_024))
  ```

  New private helper in the suite (single call site; generalize into
  `AsyncStreamHelpers` only if a second caller appears):

  ```swift
  private func slices(of data: Data, size: Int) -> [Data] {
      stride(from: data.startIndex, to: data.endIndex, by: size).map { start in
          Data(data[start..<min(start + size, data.endIndex)])
      }
  }
  ```

- Delete `pacedByteStream` entirely.
- Add `bufferingPolicy: .unbounded` to the three remaining direct seam calls:
  `capturedRequestHasPreviewPathHostAndNoConnectionClose`,
  `byteStreamFailureMapsToConnectionFailed`, `cancelTearsDownByteStream`.
- New tests: deterministic slow-consumer coverage of BOTH policies through the seam.
  After this change nothing would otherwise exercise the lossy path, and a refactor
  that ignores the policy parameter would silently make the product path unbounded --
  or, ignoring it the other way, would revert the decode tests to scheduler-dependent
  flakes instead of failing deterministically. Deterministic because `produceFrames`
  handles each chunk synchronously: all frame yields for chunk N happen before it
  requests chunk N+1, and a pull-based `AsyncThrowingStream(unfolding:)` makes that
  request observable.

  Shared private suite helper -- a gated byte stream whose second pull signals and
  then finishes (returns nil):

  ```swift
  // unfold call 1: return the full 4-frame wire (built with MJPEGWireBuilder)
  // unfold call 2: await allFramesBuffered.signal(); return nil (finish)
  // track the call index in a Mutex<Bool> or tiny actor (closure is @Sendable)
  private func gatedByteStream(wire: Data, allFramesBuffered: AsyncSignal)
      -> AsyncThrowingStream<Data, Error>
  ```

  Finishing (rather than parking the second pull in a long sleep) keeps teardown
  trivial and, in the `.unbounded` sibling below, turns a policy regression into a
  clean assertion failure instead of a hang: buffered values are delivered to
  consumers before the terminal event, so `collect` always returns.

  ```swift
  @Test(.tags(.networking))
  func bufferingNewestDropsStaleFramesForSlowConsumer() async throws {
      let client = PreviewClient.live(baseURL: baseURL, pinning: .disabled,
                                      bufferingPolicy: .bufferingNewest(1)) { _, _ in gated }
      let stream = client.connect()
      await allFramesBuffered.wait()   // all 4 yields hit the 1-slot buffer; consumer not yet started
      let frames = try await collectToEnd(stream)
      #expect(frames == [PreviewFrame(sequence: 3, jpeg: f3)])  // newest survives; 0-2 dropped, nothing else
  }

  @Test(.tags(.networking))
  func unboundedBufferingDeliversAllFramesToSlowConsumer() async throws {
      // same barrier, bufferingPolicy: .unbounded
      await allFramesBuffered.wait()   // all 4 frames buffered before the first read
      let frames = try await collectToEnd(stream)
      #expect(frames.map(\.sequence) == [0, 1, 2, 3])
      #expect(frames.map(\.jpeg) == [f0, f1, f2, f3])
  }
  ```

  The signal fires strictly after all four yields (same producer task, sequential)
  and strictly before the consumer's first read -- no race by construction. Both
  tests drain to stream end (`collectToEnd`: the existing `collect` without a count,
  or `collect(stream, count: .max)`-style loop), so the newest-wins assertion also
  proves no extra frames leak through. Caveat to accept: this leans on the
  pull-timing of the byte-stream loop (yields before next chunk request), a stable
  property of the sequential `for try await` structure.

`MJPEGWireBuilder`, `AsyncStreamHelpers.swift`, and all fixture files: untouched.

### Ripple check (verified: none)

- `AppDependencies.swift` calls the 4-arg product overload; signature unchanged.
- `PreviewFeatureTests` construct `PreviewClient(connect:)` directly; unaffected.
- The seam overload's only call sites are in `PreviewClientTests.swift`.

Per-test audit under `.unbounded` + synchronous streams: the 1-frame and error-path
tests are policy-independent (`finish(throwing:)` is a termination event, not subject
to buffering); `cancelTearsDownByteStream`'s signal flow is policy-independent and
`AsyncSignal` latches against signal-before-wait. The two 2-frame tests stop being
latently racy. No semantic change anywhere else.

No ADR: no recorded decision changes (the transport ADR owns the wire contract, not
client-side buffering). No README impact.

## Verification

1. `just app-test` -- full suite green.
2. Targeted repeats of the previously flaky suite:
   `xcodebuild -project app/DanCam/DanCam.xcodeproj -scheme DanCam -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' -only-testing:DanCamTests/PreviewClientTests -test-iterations 20 -run-tests-until-failure test`
3. 3-5 consecutive `just app-test` full-suite runs (the trigger was parallel-suite
   CPU starvation). Pre-fix failure rate was ~2/3 per run, so 5 clean runs bound a
   surviving flake below ~0.5% -- and the timing dependence is removed by
   construction, not merely made less likely.

## Commit

One commit: `fix(app): make preview buffering policy explicit at the client seam`
(body: decode tests run lossless and deterministic; product path keeps
`.bufferingNewest(1)`; adds deterministic slow-consumer tests for both policies;
removes paced sleeps).
