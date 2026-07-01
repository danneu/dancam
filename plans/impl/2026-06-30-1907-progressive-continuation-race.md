# Fix: data race on `ProgressiveSegmenterPipeline.continuation`

## Context

`LoopbackMediaServer` invokes its `onFirstPlayableReady` callback **synchronously on its
own serial queue** (`appendMediaSegment` -> `queue.async { appendMediaSegmentOnQueue }`
-> `signalFirstPlayableIfReady` -> `onFirstPlayableReady`). In the live progressive
pipeline that callback closure reads `self?.continuation` -- a plain `var` on
`ProgressiveSegmenterPipeline`, which is `@unchecked Sendable` with **no lock**. Every
other access to that `continuation` (`startIfNeeded` yields `.opened`, `finishInput`
yields `.finished`, `cancel`/`fail` do `continuation?.finish()` then `continuation = nil`)
runs on the pipeline's *separate* demux `DispatchQueue`
(`com.danneu.dancam.progressive-segmenter.<id>`).

So the server-queue read races the demux-queue writes. Reading the property copies the
`Optional<Continuation>` (an ARC retain of its internal class storage) while `cancel()`/
`fail()` overwrite it with `nil` (an ARC release). Concurrent retain/release plus a torn
store of the same reference is a **data race / undefined behavior** -- ThreadSanitizer
will flag it; worst case is over-release / use-after-free or a torn optional load.

**Realistic trigger:** the viewer is dismissed, or the pull emits `.restarted`/truncation,
or the progressive player fails *at the same instant* the first GOP's first media segment
publishes. The stream's `onTermination` runs `queue.async { pipeline.cancel() }`, nil-ing
`continuation` on the demux queue while the server queue is loading it to `yield`.

This violates ADR 08
(`app/docs/design/08-2026-06-27-progressive-fmp4-clip-playback.md`): "All loopback server
state is confined to one serial domain ... it copies segment data and hands it to the
server's serial domain before publication." This is the *reverse* hop -- the server's
serial domain reaching back into pipeline-owned, queue-confined mutable state. The fix
restores that invariant; it is a bug fix that **conforms to** ADR 08, so no new/superseding
ADR is required.

Cross-validated: two independent review runs flagged this identically
(`video-review.xegWVJ/04-loopback-hls-playback.md`#D-01 and
`video-review.pyECTN/04-loopback-hls-playback.md`#LANE-D-01), same property, same ADR.

**Intended outcome:** every access to `ProgressiveSegmenterPipeline.continuation` happens
on the demux queue again; the server callback can no longer touch cross-domain mutable
state; the threading contract that caused the bug is documented so it cannot recur.

## Root cause (one line)

The first-playable callback closure captured `self` (`@unchecked Sendable`, so the
compiler could not see the violation) and dereferenced a queue-confined `var` from a
foreign serial queue.

## The fix (ideal shape)

Capture the continuation **by value** into the server callback, so the closure holds its
own stable, thread-safe handle and never reads the pipeline's mutable `var` across domains.
This eliminates the race by construction (no added synchronization), drops the now-unneeded
`[weak self]`, and makes the closure *legitimately* `@Sendable` instead of relying on the
`@unchecked` escape hatch. It is also strictly less machinery than the alternatives and
matches the discipline `ProgressiveSegmenter.noop` already uses (its continuation is a
captured value, not a reached-through property).

This is sound because `AsyncThrowingStream.Continuation` is `Sendable` with a thread-safe
`yield`, and the continuation object is stable for the pipeline's whole life (only swapped
to `nil` on teardown). The capture removes the data race outright, independent of timing.
A *late* callback that races teardown is then only a logical-ordering question, and it is
harmless either way: if it yields after `finish()`, `yield` returns `.terminated` and the
value is dropped; if it yields *before* termination, the event is delivered but the
consumer ignores it -- `ClipViewerViewController.segmenterTask` runs
`try Task.checkCancellation()` before dispatching each event, and `handleFirstPlayable`
gates on `progressiveEligibleProgress()`, which returns `nil` once the viewer has swapped
or fallen back (ADR 08's late-`firstPlayableReady` suppression). So `yield`-drop is *not*
the whole guarantee -- it covers only the post-`finish()` case.

### Change 1 -- `app/DanCam/DanCam/Media/Stream/ProgressiveSegmenter.swift`

In `ProgressiveSegmenterPipeline.startIfNeeded` (the `LoopbackMediaServer { [weak self] ... }`
closure), capture the continuation by value:

```swift
private func startIfNeeded() throws {
    guard fileHandle == nil else { return }

    // The server invokes this callback on its OWN serial queue. Capture the
    // continuation by value (it is Sendable and stable for the pipeline's life)
    // so the callback never reads this pipeline's demux-queue-confined
    // `continuation` across serial domains. A yield that races teardown is harmless:
    // dropped (`.terminated`) after finish(), else ignored by the consumer's state gate.
    let server = try LoopbackMediaServer { [continuation = self.continuation] url in
        continuation?.yield(.firstPlayableReady(url: url))
    }
    self.server = server
    continuation?.yield(.opened(workDirectory: server.workDirectory))   // demux queue, unchanged
    fileHandle = try FileHandle(forReadingFrom: sourceURL)
}
```

The capture-list form `[continuation = self.continuation]` binds a local copy and removes
all `self` capture from the closure; the subsequent `.opened` yield still uses the property
on the demux queue (unchanged).

Ownership note (the graph is *not* cycle-free -- don't claim it is): the stream storage owns
the `onTermination` closure, which captures `pipeline` strongly (so does `feederTask`), and
the pipeline owns both `continuation` and `server`. After this change the server's callback
also holds the continuation storage by value, adding a
`pipeline -> server -> continuation storage -> onTermination -> pipeline` strong path. That
is resolved by the same teardown that already breaks the pre-existing
`pipeline -> continuation storage -> onTermination -> pipeline` cycle: `cancel`/`fail` nil
**both** `server` and `continuation` (dropping both pipeline edges into the storage) and
call `finish()`, and the terminal stream clears `onTermination` (dropping the storage's edge
back to the pipeline). So the fix adds an edge but introduces no new leak.

### Change 2 -- `ProgressiveSegmenter.swift`, document the confinement invariant

Add a doc comment on the property so the invariant is discoverable at the field:

```swift
/// Confined to the segmenter's serial demux `DispatchQueue`; never read or written from
/// another domain (e.g. the loopback server's callback queue -- capture this Sendable
/// continuation by value instead of reaching through the property).
private var continuation: AsyncThrowingStream<ProgressiveSegmenterEvent, Error>.Continuation?
```

### Change 3 -- `app/DanCam/DanCam/Media/Stream/LoopbackMediaServer.swift`, document the callback's threading contract

Document the contract that, when violated, produced this bug -- on the `onFirstPlayableReady`
init parameter (what every caller reads):

```swift
/// - Parameter onFirstPlayableReady: invoked **at most once**, on the server's internal
///   serial queue, when the init segment and first media segment are both available
///   (the EVENT playlist becomes first playable). It runs in the server's isolation
///   domain, not the caller's: the closure may capture only `Sendable`/immutable or
///   internally synchronized handles by value (e.g. an `AsyncStream.Continuation`).
///   Capturing a reference whose mutable state is confined to another serial domain still
///   races, even by value -- to deliver into such state, hop to its owner domain instead.
```

(Accurate, and *at most once* is the precise contract: `signalFirstPlayableIfReady` guards
on `state.didSignalFirstPlayable` so it fires no more than once, and *also* early-returns
while `state.mediaSegments.isEmpty`, so an input that never yields a media segment -- no
SPS/PPS, or SPS/PPS with zero access units -- never fires it at all. The guard establishes
*not more than once*, not *always once* -- the same "no finalized output is possible" case
the `ProgressiveSegmenterEvent.finished` doc already calls out. A caller must not block
waiting for a guaranteed call.)

## Files to modify

- `app/DanCam/DanCam/Media/Stream/ProgressiveSegmenter.swift` -- the callback capture in
  `startIfNeeded` (the fix) + a doc comment on the `continuation` property.
- `app/DanCam/DanCam/Media/Stream/LoopbackMediaServer.swift` -- doc comment on the
  `onFirstPlayableReady` init parameter.

No other production call site exists: `grep` confirms `ProgressiveSegmenter.swift` is the
only place that passes `onFirstPlayableReady`; every other `LoopbackMediaServer(...)` uses
the default no-op. The test call site (`LoopbackMediaServerTests.swift`) already captures a
`Sendable` `ReadyURLRecorder`, so it is safe and unchanged.

## Considered and deliberately excluded

- **Queue hop** (`queue.async { self.continuation?.yield(...) }`): correct, but adds an
  async dispatch per signal, keeps a `[weak self]` capture, and reorders the signal behind
  already-queued demux work. Heavier than capture-by-value for no benefit.
- **Lock the continuation** (an `OSAllocatedUnfairLock`, like `FMP4Segmenter` does for its
  state): introduces a second synchronization mechanism into a class that otherwise relies
  on pure serial-queue confinement -- wrong altitude for a single field.
- **Remove the callback; have the pipeline poll the server for first-playable**: the server
  is the authority on when init + first segment both exist (gated by `AVAssetWriter`'s async
  IDR-boundary flush). Polling via `performOnQueueSync` after each append is messier and
  still crosses queues. The callback is the right design; only its capture was wrong.
- **Enable ThreadSanitizer on the test scheme**: would help catch this *class* of bug, but
  it is a broader infra change, would not deterministically catch *this* race without a test
  that forces teardown at the first-segment instant, and can surface unrelated latent races
  / slow the suite. Optional follow-up, not part of this fix.
- **Harden `deinit -> cancel()` (also cross-queue in theory)**: examined -- it is a no-op in
  practice. The stream's `onTermination` strongly retains the pipeline, so real teardown
  always runs via `queue.async { cancel() }` on the demux queue *before* the pipeline can
  deallocate; `deinit`'s `cancel()` therefore always hits the `guard isCancelled == false`
  early-return. Not a live bug; left as-is.
- **New regression test**: the race is not deterministically reproducible without injected
  synchronization, and the fix is correct-by-inspection (no cross-queue mutable access
  remains). Existing coverage already guards delivery (below). Not worth bespoke test
  machinery.

## Verification

1. Build + run the app test suite: `just app-test`
   (xcodebuild, iPhone 17 / iOS 26.5 simulator, `-only-testing:DanCamTests`).
2. Confirm the first-playable path stays green, attributing precisely what each test
   guards -- the changed closure lives in `ProgressiveSegmenter.live`, so *only* a test
   that drives `.live` actually executes it:
   - `ProgressivePlaybackIntegrationTests.livePullThroughProgressiveSegmenterProducesPlayableItem`
     -- the **sole end-to-end guard on the changed closure**: it drives
     `ProgressiveSegmenter.live` and consumes `.firstPlayableReady`. This is the one test
     that runs the edited `startIfNeeded` capture; it must stay green.
   - `LoopbackMediaServerTests.servesGrowingEventPlaylistWithFrozenTargetDuration` -- guards
     the *server callback contract* (fires with the playlist URL), asserting
     `readyURLs.snapshot() == [server.mediaPlaylistURL]` via a `Sendable` recorder. It
     exercises the server, not the pipeline closure.
   - `ClipViewerViewControllerTests.postSwapFirstPlayableReadyDoesNotReplaceDurableMP4` --
     backs the *consumer-side* late-event-suppression half of the safety argument: a late
     `firstPlayableReady` arriving after the durable-MP4 swap is ignored. Note these viewer
     tests inject *mock* segmenters (`playingSegmenter`, `postSwapFirstPlayableSegmenter`,
     `.noop`, ...), so they do **not** run the changed `.live` `startIfNeeded` closure --
     they guard the consumer, not the fix site.
3. Inspection check: `grep -n "continuation" ProgressiveSegmenter.swift` and confirm every
   access to `ProgressiveSegmenterPipeline.continuation` is on the demux queue -- the former
   sole offender (the server callback closure) now uses a captured value.
4. Optional local cleanliness check (not CI, and **not** a validation of this fix): run
   `ProgressivePlaybackIntegrationTests` once with ThreadSanitizer enabled in the scheme.
   Be clear what it does and does not show: that test drains to completion, so `cancel()`
   runs at normal end-of-stream -- long after `firstPlayableReady` has fired and been
   consumed -- and never produces the callback-concurrent-with-`cancel()` interleaving that
   triggers this race (consistent with the "Enable ThreadSanitizer" exclusion bullet above).
   A green run therefore confirms general first-playable-path cleanliness only, not that
   this race is fixed; no reader should mistake it for validation of the fix.
