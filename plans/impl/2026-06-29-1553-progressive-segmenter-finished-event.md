# Plan: add a `.finished` event to `ProgressiveSegmenter`

## Context

`ProgressivePlaybackIntegrationTests.livePullThroughProgressiveSegmenterProducesPlayableItem`
fails deterministically (reproduced 5/5) on its two `progressiveDuration` assertions:

```
Expectation failed: (progressiveDuration -> CMTime(value: 0, timescale: 0, flags: rawValue 17)).isNumeric -> false
Expectation failed: (progressiveDuration.seconds -> nan) > (0 -> 0.0)
```

Root cause: the progressive path serves an HLS `EXT-X-PLAYLIST-TYPE:EVENT` playlist from
`LoopbackMediaServer`. A finite, "numeric" duration only exists once the playlist is finalized
with `#EXT-X-ENDLIST`, which happens at the very end of segmentation
(`ProgressiveSegmenterPipeline.finishInput` -> `FMP4Segmenter.finishWriting` -> `sink.finish()`
-> `LoopbackMediaServer.finishOnQueue`). The test only synchronizes on `.firstPlayableReady`
(emitted right after segment 0) and `item.status`, neither of which waits for finalization. The
injected pull transport delivers all bytes near-instantly while segmentation/finalization is slow
background work, so the duration is always read while the playlist is still an unfinished live
playlist. AVFoundation reports such a playlist's duration as `kCMTimeIndefinite` (flags
`Indefinite|Valid` = rawValue 17), so `.isNumeric` is false and `.seconds` is NaN.

This is a pre-existing test-synchronization gap, not a regression: the entire progressive path
(`ProgressiveSegmenter`, `LoopbackMediaServer`, `FMP4Segmenter`, the test) is byte-identical to
when the test was introduced (`af27234`). It is also a real product-observability gap: the live
segmenter's `AsyncThrowingStream` emits no terminal event on the success path (the stream is only
finished on cancel/fail), so a consumer cannot learn that segmentation completed.

Intended outcome: give the segmenter a first-class "I have finished segmenting and the playlist is
finalized" signal (`ProgressiveSegmenterEvent.finished`), emitted at the point where
`#EXT-X-ENDLIST` is guaranteed published, and have the integration test wait for it before reading
the progressive duration.

## Approach

Add a `.finished` case to `ProgressiveSegmenterEvent` and emit it from
`ProgressiveSegmenterPipeline.finishInput()` at the one race-free point: immediately after
`server?.checkForFailure()` returns successfully. That `checkForFailure()` call does
`queue.sync` onto the server's serial queue, which drains the already-enqueued media-segment
appends and the `finishOnQueue` block (all FIFO on the same serial queue) -- so by the time it
returns, the server has reached its terminal state: if any media segment was written,
`state.finished == true` and the playlist route has been republished with `#EXT-X-ENDLIST`.
The emit is still driven purely from the pipeline (no `LoopbackMediaServer` callback), but it is
gated on a small synchronous server-side predicate that reads that terminal state -- see the
finalization guard below.

Key constraint -- **do not finish the continuation when emitting `.finished`.** The segmenter
stream's lifetime is load-bearing: finishing it triggers `onTermination` -> `pipeline.cancel()`
-> `server.shutdown()`, which deletes the work dir and stops serving the playlist. The player
(production) and the duration read (test) both need the loopback server alive after `.finished`.
Teardown stays owned by the consumer (VC dealloc / test `defer`), exactly as today. `.finished` is
an in-band, mid-stream event that leaves the stream open.

`.finished` carries no payload: the playlist URL is stable and was already delivered via
`.firstPlayableReady`. It means exactly "a finalized (`#EXT-X-ENDLIST`) playlist is being served,"
so it must be gated on the server's actual finalized-playlist state -- **not** on
`segmenter != nil`. The segmenter is created the instant SPS+PPS latch (`#consume`), before any
access unit is produced; but `LoopbackMediaServer.publishPlaylistRoute` only writes a playlist
route once a media segment has set `state.targetDuration`. So an SPS/PPS-only input (no access
units, no media segment) would have `segmenter != nil` yet `finishOnQueue` republishes nothing --
no playlist route, no ENDLIST -- and `segmenter != nil` would emit a misleading "finished." Gate
instead on `state.finished && state.targetDuration != nil`, queried through the server queue after
`checkForFailure()` (the predicate the loopback server uses to decide whether an ENDLIST playlist
exists at all). The degenerate no-content paths (no SPS/PPS, or SPS/PPS with zero access units)
then correctly emit nothing.

## Changes

### 1a. Production: expose a finalized-playlist predicate
`app/DanCam/DanCam/Media/Stream/LoopbackMediaServer.swift`

- Add a synchronous query that reports whether an `#EXT-X-ENDLIST` playlist is actually being
  served, reading the terminal state through the server's serial queue exactly like
  `#func checkForFailure`:

  ```swift
  func hasFinalizedPlaylist() -> Bool {
      performOnQueueSync {
          state.finished && state.targetDuration != nil
      }
  }
  ```

  Why this exact predicate: `state.targetDuration` is set only in `#func appendMediaSegmentOnQueue`
  (i.e. at least one media segment exists), and `#func publishPlaylistRoute` writes the playlist
  route only when `targetDuration != nil`; `#func finishOnQueue` sets `state.finished` and
  republishes with `#EXT-X-ENDLIST`. So `finished && targetDuration != nil` is true iff a finalized
  playlist with ENDLIST is being served -- the same condition `publishPlaylistRoute` gates on, plus
  finalization. (No new callback; this mirrors the existing pull-style `checkForFailure` query.)
- **Required test** (this predicate carries the fix -- the switch away from `segmenter != nil` --
  so its negative contract must be pinned directly, not only via the integration happy path). Add a
  case to `LoopbackMediaServerTests`
  (`app/DanCam/DanCamTests/Media/Stream/LoopbackMediaServerTests.swift#struct LoopbackMediaServerTests`)
  using the suite's existing API (`appendInitializationSegment`, `appendMediaSegment(_:duration:)`,
  `finish()`, `server.shutdown()` in `defer`). `hasFinalizedPlaylist()` is itself a
  `performOnQueueSync` barrier that drains the FIFO queue, so the four observations are
  deterministic without extra synchronization:
  - false on a fresh server (`finished == false`, `targetDuration == nil`);
  - false after `appendInitializationSegment(...)` + `finish()` with no media segment (finished but
    `targetDuration == nil` -> no ENDLIST playlist route -- the exact case `segmenter != nil` got
    wrong);
  - false after `appendMediaSegment(...)` but before `finish()` (`targetDuration` set, not finished);
  - true only after `appendMediaSegment(...)` + `finish()`.

### 1b. Production: define and emit the event
`app/DanCam/DanCam/Media/Stream/ProgressiveSegmenter.swift`

- `ProgressiveSegmenterEvent` (`#ProgressiveSegmenterEvent`): add `case finished`. Enum stays
  `Equatable, Sendable` (no payload, synthesis unaffected). Pin the gated contract as a doc comment
  on the case itself, so the meaning travels with the definition rather than living only in this
  plan and one call-site comment:

  ```swift
  /// Emitted once a finalized `#EXT-X-ENDLIST` playlist is being served, i.e. the whole clip is
  /// segmented and the loopback server now reports a finite duration. Intentionally NOT emitted
  /// for inputs that produced no media segment (no SPS/PPS, or SPS/PPS with zero access units):
  /// there is no finalized playlist, so a consumer waiting on `.finished` must not treat its
  /// absence as a hang on such inputs.
  case finished
  ```
- `ProgressiveSegmenterPipeline.finishInput()` (`#func finishInput`): after the existing
  `try server?.checkForFailure()` succeeds, emit the terminal event only if the server actually
  finalized a playlist:

  ```swift
  try segmenter?.finishWriting()
  try server?.checkForFailure()
  if server?.hasFinalizedPlaylist() == true {
      continuation?.yield(.finished)
  }
  ```

  `checkForFailure()` already drained the serial queue, so `hasFinalizedPlaylist()` observes the
  terminal state without an extra wait. Do **not** call `continuation?.finish()` here. The
  `didFinishInput` guard already makes this emit at-most-once; the `fail()` path (which finishes
  throwing) is unchanged, so a failed finish never emits `.finished`. An SPS/PPS-only or no-content
  input leaves `hasFinalizedPlaylist()` false and emits nothing.
- `ProgressiveSegmenter.noop` stays unchanged (it models "no progressive behavior" and emits no
  events; ClipViewer tests rely on that).

### 2. Production: handle the new case (the one exhaustive switch)
`app/DanCam/DanCam/Features/ClipViewer/ClipViewerViewController.swift`

- `#handleSegmenterEvent` is the only exhaustive `switch` over `ProgressiveSegmenterEvent`; adding
  the case forces an arm here. Handle it as a documented no-op:

  ```swift
  case .finished:
      // A finalized #EXT-X-ENDLIST progressive playlist is now being served.
      // The scrubbable swap is owned by the pull-completion finalizer
      // (handlePullCompleted -> startFinalizer), so there is nothing to do here today.
      break
  ```

  (Lead the comment with the finalized-playlist contract, not "segmentation is complete" -- the
  latter also holds for the no-content path where `.finished` never fires, so it would misdescribe
  the case.)

  Rationale: the transition to a seekable item is pull-driven (`#runFinalizer` ->
  `.readyScrubbable` + `stopProgressivePipeline()`), not segmenter-driven. `.finished` is recorded
  here as an explicit, in-band terminal rather than relying on the stream silently ending. The
  `#startSegmenter` drain loop (`for try await event in events`) is otherwise unchanged and still
  runs until VC teardown cancels `segmenterTask`.

### 3. Test: wait for `.finished` before reading the progressive duration
`app/DanCam/DanCamTests/Media/ProgressivePlaybackIntegrationTests.swift`

- Add an `AsyncSignal` (already in the test target,
  `app/DanCam/DanCamTests/Support/AsyncStreamHelpers.swift#AsyncSignal` -- buffered one-shot, so
  signal-before-wait is safe) to surface finalization to the test body, e.g.
  `let segmenterFinished = AsyncSignal()`.
- Extend `#drainSegmenterEvents` to take the signal and switch over the event instead of a single
  `if case`, signaling on `.finished`:

  ```swift
  for try await event in events {
      switch event {
      case .firstPlayableReady(let url):
          firstPlayableContinuation.yield(url)
      case .finished:
          segmenterFinished.signal()
      case .opened:
          break
      }
  }
  ```

  (Pass `segmenterFinished` into the helper alongside `firstPlayableContinuation`.)
- Reorder so the remux block runs first, then assert the two representations of the same clip
  agree. Today the progressive duration is read (test lines `let progressiveAsset = AVURLAsset(url:
  playlistURL)` ... `load(.duration)`) before the remux block (`completedPull` -> `ClipRemuxer.live
  .remux` -> `remuxedAsset` -> `remuxedDuration`). Move the remux block up to just after
  `#expect(item.status == .readyToPlay)` so `remuxedDuration` is in scope, keeping its existing
  clip-length sanity check `#expect(abs(remuxedDuration.seconds - 30.0) < 0.5)`. The remux path does
  not depend on segmenter finalization, so it can run before the `.finished` barrier.
- Then insert `await segmenterFinished.wait()` before `let progressiveAsset = AVURLAsset(url:
  playlistURL)`. This is the barrier that guarantees `#EXT-X-ENDLIST` is present before the duration
  load. The surrounding `.timeLimit(.minutes(1))` bounds the wait if the event never arrives.
- Strengthen the now-deterministic progressive assertions to check the real invariant -- that the
  progressive playlist and the remuxed file, two representations of the same fixture, report the
  same duration -- rather than re-hardcoding `30.0`:

  ```swift
  #expect(progressiveDuration.isNumeric)
  #expect(abs(progressiveDuration.seconds - remuxedDuration.seconds) < 0.5)
  ```

  Why compare against `remuxedDuration`, not a second `30.0`: the progressive EXTINF sum and the
  remux `moov` duration measure the same frames, so they agree to a few ms; the 0.5s tolerance is a
  comfortable margin on that single comparison. (Justifying a hard `~30.0` bound on the progressive
  side instead would have to chain two different baselines -- `FMP4SegmenterTests`' "sum within 0.5
  of the fixture tick-duration" and the remux block's "within 0.5 of 30.0" -- which only bounds
  progressive to ~1.0 of 30.0, not the 0.5 asserted.) The `remuxedDuration ~= 30.0` check stays as
  the separate clip-length oracle, so the pair pins both "the clip is ~30s" and "progressive ==
  remux". Do **not** weaken the agreement check to `progressiveDuration.seconds > 0`: a
  nonzero-but-short duration would mean `.finished` fired before full segmentation (or AVFoundation
  read a stale playlist) -- a real bug to investigate, not a tolerance to relax.

## Out of scope / non-goals

- No new `LoopbackMediaServer` finalization *callback* or push notification. Change 1a adds one
  synchronous `hasFinalizedPlaylist()` query (the same pull-style shape as `checkForFailure`); the
  emit stays pipeline-driven. The server does not learn about, or call back into, the segmenter.
- No change to the production scrubbable-swap flow (still pull-completion-driven).
- No ADR: this refines an existing seam (`02-...-app-pi-transport-and-api` / the progressive fMP4
  ADR) rather than making a new architectural decision. No README/Pi-provisioning impact.
- A dedicated `ProgressiveSegmenterTests` unit suite is not required; the integration test now
  covers `.finished` end-to-end. (Optional future nicety, not part of this change.)

## Verification

1. `just app-test` -- full suite green. Targeted: `ProgressivePlaybackIntegrationTests` passes.
   Run it several times to confirm the fix is deterministic, not luck:
   ```
   xcodebuild -project app/DanCam/DanCam.xcodeproj -scheme DanCam \
     -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' build-for-testing
   for i in 1 2 3 4 5; do xcodebuild ... \
     -only-testing:DanCamTests/ProgressivePlaybackIntegrationTests test-without-building; done
   ```
   Expect: `progressiveDuration.isNumeric == true`, `progressiveDuration.seconds ~= 30`.
2. The new required `LoopbackMediaServerTests` case (Change 1a) passes -- it pins the predicate's
   negative contract (false before `finish()`, false for init-only `finish()`, false for media
   before `finish()`, true only after media + `finish()`), which the integration happy path does
   not exercise. `LoopbackMediaServer` otherwise gains only the additive `hasFinalizedPlaylist()`
   query, so the existing `LoopbackMediaServerTests` / `FMP4SegmenterTests` behavior is unchanged.
3. Confirm no other test regressed -- especially `ClipViewerViewControllerTests` (exercises the
   updated `#handleSegmenterEvent` switch via fake segmenters).
4. Sanity: the `.finished` arm in `#handleSegmenterEvent` is a no-op, so production playback
   behavior (progressive play while pulling, then swap to remuxed scrubbable item on pull
   completion) is unchanged -- the loopback server still lives until VC teardown.
