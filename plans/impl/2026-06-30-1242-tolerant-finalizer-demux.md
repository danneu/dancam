# Plan: make the finalizer demux tolerant of power-cut-truncated TS

## Context

dancam records crash-safe MPEG-TS on the Pi precisely so a power cut (ignition
off mid-write) "costs at most the final partial segment, and that segment is
usually still playable up to the cut" (`raspi/docs/design/01-2026-06-22-crash-safe-recording.md`).
The iPhone app has two MPEG-TS -> H.264 demux paths that diverge on exactly that
condition:

- The live/progressive path (`Media/Stream/ProgressiveSegmenter.swift`) uses
  `IncrementalTSDemuxer`, which resyncs past bad sync bytes and drops the sub-188
  residual tail -- tolerant.
- The finalizer (`Media/Remux/ClipRemuxerEngine.swift` -> `TSDemuxer.demuxH264` ->
  `TSDemuxer.demuxH264PESPackets`) uses the strict whole-file parser, which throws
  on any non-188-aligned length and on the first non-`0x47` sync byte, with no
  resync.

The finalizer is the **sole producer of the durable front-`moov` MP4** that backs
scrubbing, cache, and export (`app/docs/design/08-2026-06-27-progressive-fmp4-clip-playback.md`).
A power-cut-truncated final segment is almost never a multiple of 188, so the
finalizer throws on the very clip the recording format exists to survive.
`ClipViewerViewController#handleFinalizerFailure` forks on the finalize source
(`FinalizeSource`): only a `.progressiveSwap` finalize whose progressive item is
still current (`currentItemIsProgressive`) degrades to `.progressiveOnly`
(playable, but no scrub/export/cache); every other case -- a `.fallback`
finalize, or a `.progressiveSwap` whose progressive item is already gone --
sets the `.failed(message:)` state the viewer renders as "Clip failed"
(`Features/ClipViewer/ClipViewerViewController.swift#handleFinalizerFailure`).

This was raised as an S1 by two independent review lanes (`video-review.pyECTN/02-ts-h264-demux.md#B-01`,
`.../03-fmp4-finalize-remux.md#C-01`). The intended outcome: the finalizer
produces a valid, scrubbable, exportable MP4 that plays up to the cut for
truncated (and mid-stream-corrupt) segments, with no regression for clean clips.

**Where this sits in the build.** This hardens machinery already landed under
swoop `lime` (Watch recorded clips, in progress; `docs/roadmap.md`) -- the
pull -> finalize-remux -> play path and its viewer -- and is orthogonal to
`lime`'s still-open on-device clip-store and poster steps, which it neither
needs nor changes. The surrounding app and Pi have since moved to the
event-folded model: swoop `pulse` is complete, so the Pi now owns a recorder
FSM and serves an ordered `/v1/events` SSE stream
(`raspi/docs/design/10-2026-06-30-recorder-fsm-and-events-sse.md`) and the app
folds snapshot-first events into one `Link`/`World` state
(`app/docs/design/10-2026-06-29-event-folded-state-machines.md`). That
migration reshaped connection, recorder, and clip-list state but does **not**
touch the MPEG-TS -> H.264 -> MP4 remux pipeline this plan changes: as of the
current `master` (`4a80c30`), the strict `demuxH264PESPackets` alignment guard,
the tolerant `IncrementalTSDemuxer`, and `H264AccessUnitAssembler.splitAnnexB`'s
throw all still read exactly as described above.

## Scope decision

**Unify the demux *implementation*, keep the finalizer an independent pass.**

- The strict whole-file parser is deleted; `demuxH264PESPackets` becomes a thin
  wrapper over the one tolerant `IncrementalTSDemuxer`. After this there is a
  single demux implementation.
- We deliberately keep the finalizer as a separate post-pull pass (it parses the
  TS a second time). ADR 08 made that independence a robustness property -- the
  safety-critical durable MP4 must not depend on the newer progressive pipeline,
  and the double-parse cost is trivial (one cheap CPU pass per clip view). ADR
  08's deferred "single parse feeding both" alternative stays deferred; pursuing
  it would couple the durable artifact to the live path and force buffering all
  access units in RAM for the whole pull, for no real benefit here.

**Make the whole finalize pipeline fail-soft, not just the demux layer.** Once
the demuxer tolerates corruption, the next-innermost layer
(`H264AccessUnitAssembler.splitAnnexB`) becomes the new "one malformed packet
fails the whole clip" hazard -- the same intolerance, one layer down.
Corruption resilience is a first-class dancam principle, so we soften that layer
in the same change.

## Key design decision: emit the truncated trailing frame as-is (do not drop)

Both demuxers flush the in-flight final PES at `finish()`, so a power-cut tail
yields a final access unit whose last NAL may be cut mid-bitstream. We emit it
unchanged. This is correct and safe, verified against the assembler + writer:

- AVAssetWriter muxes raw length-prefixed bytes; it does not decode/validate
  slice payloads. `avccSampleData` length-prefixes the short final NAL at its
  actual byte count and `sampleSize` matches, so the result is a structurally
  valid MP4 whose last frame may glitch on decode -- i.e. "plays up to the cut."
- No finalizer break is possible from truncation: the last unit's duration is
  always positive (`inferredFrameDuration`, never zero); truncation removes tail
  frames without reordering/inventing DTS, so the "DTS strictly increasing" guard
  cannot newly fire; SPS/PPS live in the head GOP and are never at risk; the
  slice-presence guard (`guard sampleNALs.contains(where: isSliceNAL)`) drops a
  degenerate final group rather than emitting an empty sample.
- A blanket "drop the trailing unit" is rejected: there is **no reliable in-band
  truncation signal** (PES_packet_length is 0/unbounded for video; "no following
  PUSI" is true for clean clips too), so dropping would silently discard the last
  good frame of **every** clean clip.

## Implementation steps

1. **`Media/Remux/TSDemuxer.swift` -- collapse `demuxH264PESPackets` onto the
   tolerant path.** Delete the `data.count % packetSize == 0` alignment guard and
   the strict `stride`/`processPacket`/`finish` loop. Replace with:
   ```swift
   var demuxer = IncrementalTSDemuxer()
   var packets = try demuxer.append(data)
   packets.append(contentsOf: demuxer.finish())
   guard packets.isEmpty == false else {
       throw ClipRemuxError.invalidTransportStream("No H.264 PES packets found.")
   }
   return packets
   ```
   Keep the existing "No H.264 PES packets found." guard (genuinely empty/non-TS
   input still fails clearly). Add a comment explaining the tolerant contract
   (drops sub-188 residual tail, emits truncated final PES as-is, writer muxes it
   into an MP4 that plays up to the cut) and noting the one transient full-file
   copy into `residual`. Leave `demuxH264`, the batch assembler, and
   `ClipRemuxerEngine` untouched. `TransportStreamH264Parser.processPacket`'s
   sync-byte `guard` is now only reached at validated `0x47` offsets, so it
   becomes an internal invariant -- no change needed.

2. **`Media/Remux/H264AccessUnitAssembler.swift` -- make `splitAnnexB`
   fail-soft.** Change `splitAnnexB` to return `[]` instead of throwing
   `invalidH264("Missing Annex B start code.")`, and drop `throws` from its
   signature. Both call sites already absorb an empty result (batch `assemble`
   has `guard nalUnits.isEmpty == false else { continue }`; streaming
   `StreamingH264AccessUnitAssembler.append` no-ops via its parameter-set / empty
   guards), so just drop `try` at those two call sites and at the one direct test
   call in `H264AccessUnitAssemblerTests.parsesAnnexBStartCodesAndNALTypes`. The
   new `H264AccessUnitAssemblerTests.skipsPESWithoutAnnexBStartCode` test (see
   Tests) pins this fail-soft contract behaviorally through both assemblers.

3. **`app/docs/design/08-2026-06-27-progressive-fmp4-clip-playback.md` -- record
   the change.** Append a dated note to `## Consequences` (append-only ADR
   convention): the demux stage is now unified on the tolerant
   `IncrementalTSDemuxer`; the finalizer tolerates power-cut truncation and
   mid-stream garbage; the trailing access unit is emitted as-is (a blanket drop
   was rejected -- regresses clean clips, no in-band truncation signal); the
   "single parse feeding both" alternative remains deferred and is now partially
   realized for the demux stage only (assemble/write stages stay independent by
   design).

## Tests

Swift Testing, fixture `MediaFixtureURLs.seg00000TS()`
(`app/DanCam/DanCamTests/Media/MediaFixtureURLs.swift`; `seg_00000.ts`, exactly
5387 x 188 = 1,012,756 bytes, ~30s, >800 access units). Test homes, verified
against `master`: `TSDemuxerTests` and `H264AccessUnitAssemblerTests` under
`app/DanCam/DanCamTests/Media/Remux/`, `ClipRemuxerTests` under
`app/DanCam/DanCamTests/Media/`. New `ClipRemuxerTests` methods live in the
existing struct and reuse its private helpers (`assertFastStartLayout`,
`assertSyncSamples`, `durationSeconds`, `remuxOutputs`).

- **Rewrite `TSDemuxerTests.rejectsUnalignedTransportStream`** -> rename
  `rejectsTransportStreamWithNoH264Packets`; the strict-alignment message is
  gone, so assert `.invalidTransportStream("No H.264 PES packets found.")` for
  `Data([0x47, 0x00])`.
- **Reframe `TSDemuxerTests.incrementalDemuxerMatchesWholeFilePESPacketsAcrossChunkSizes`**
  -> rename `demuxedPESPacketsAreInvariantToChunkBoundaries`; add `data.count` to
  the chunk-size list so "one-shot == chunked" is explicit. (It now proves
  chunk-boundary invariance of the single implementation; resync/PSI-split
  coverage stays in the sibling incremental tests.)
- **New `TSDemuxerTests.toleratesUnalignedTruncatedTransportStream`**
  (deterministic, AVFoundation-free): `let full = demuxH264PESPackets(data)`;
  `cut = data.count - 750` (`#require(cut % 188 != 0)`);
  `floor = (cut / 188) * 188`; `let truncated = demuxH264PESPackets(prefix(cut))`.
  Assert:
  - `truncated == demuxH264PESPackets(prefix(floor))` -- the sub-188 residual
    tail is dropped, so the output equals flooring to the last whole packet.
    This is the structure-insensitive core: residual tolerance regardless of
    fixture internals.
  - `truncated.count == full.count` -- this cut drops no whole PES. Verified
    against the committed fixture: the final PES begins at TS packet 5381 and
    spans 6 packets to EOF; `cut = n - 750` floors to 5383 packets, lopping only
    the 4 trailing *continuation* packets of that final PES (never its PUSI), so
    the PES count stays 900.
  - `truncated.last!.payload.count < full.last!.payload.count` -- the final PES
    is emitted as-is but genuinely shorter (it lost those 4 continuation
    packets), proving the truncation reached real payload and the assertion is
    not vacuous.

  Together this encodes "drop the sub-188 tail, keep every whole packet, emit the
  shortened final PES rather than throwing," and the `== full.count` /
  `< payload.count` pair pins the plan's "emit trailing frame as-is, do not drop"
  decision at the demux layer. (`H264PESPacket` is `Equatable` with an accessible
  `payload`, as the sibling equivalence tests already rely on.) Note: the earlier
  `count < full.count` draft was wrong -- dropping 4 continuation packets leaves
  the PES count unchanged, so it would have failed against the correct tolerant
  implementation or pushed toward dropping the final PES, contradicting the
  emit-as-is decision.
- **New `ClipRemuxerTests.liveRemuxesTruncatedTransportStreamToPlayableMP4`**
  (end-to-end): write `prefix(cut)` with `cut = data.count - 17_000`
  (`#require(cut % 188 != 0)`, ~1s dropped) to a temp `.ts`; `ClipRemuxer.live.remux`
  (clipID `91_002`); assert `bytes > 0`, `assertFastStartLayout`,
  `assertSyncSamples`, decode at `.zero` and `CMTime(seconds: 10, ...)` (never
  near the truncated tail), and a loose duration band (`> 25.0 && < 30.5`).
  `defer` cleanup of the temp `.ts` and `clip-91002-*` outputs.
- **New `ClipRemuxerTests.liveRemuxesTransportStreamWithMidStreamGarbageToPlayableMP4`**
  (rides-along, locks in a second instance of the root cause): splice ~7 garbage
  bytes at packet #31 (as `incrementalDemuxerResyncsAfterInjectedGarbage` does),
  write to a temp `.ts`, remux (clipID `91_003`), assert a playable faststart MP4
  with sync samples. `defer` cleanup.
- **New `H264AccessUnitAssemblerTests.skipsPESWithoutAnnexBStartCode`** -- the
  direct behavioral guard for step 2's fail-soft change. Required because neither
  truncation test exercises it: a power-cut tail still *begins* with a start code
  (the cut is at the end), and `incrementalDemuxerResyncsAfterInjectedGarbage`
  recovers to byte-identical PES output (`actual == expected`), so no malformed
  PES ever reaches `splitAnnexB`'s new empty-return branch in those tests. Build
  three hand-rolled packets with strictly increasing DTS (`0`, `3_000`, `6_000`)
  using the existing `annexB`/`nal` helpers:
  `P1 = annexB([nal(9,..), nal(7,..), nal(8,..), nal(5,..)])` (SPS/PPS + IDR),
  `P_bad = H264PESPacket(payload: Data([0xde, 0xad, 0xbe, 0xef]), ...)` (no start
  code -> `splitAnnexB` returns `[]`), `P2 = annexB([nal(9,..), nal(1,..)])`
  (non-IDR). Feed `[P1, P_bad, P2]`:
  - Batch: `H264AccessUnitAssembler.assemble(packets:timescale:)` must not throw
    and must yield exactly the two valid access units
    (`isKeyFrame == [true, false]`, `nalTypes == [[9, 7, 8, 5], [9, 1]]`); the
    malformed PES is skipped via the existing
    `guard nalUnits.isEmpty == false else { continue }`, not fatal.
  - Streaming: feed `[P1]`, `[P_bad]`, `[P2]` then `finish()`; assert no throw,
    `didBecomeReady` fires exactly once, and the same two access units accumulate
    -- the bad PES leaves `held` untouched (its `makePendingUnits` returns `[]`)
    rather than resetting state or throwing.

  This is the guard for the plan's "one malformed packet does not fail the whole
  clip" claim: it throws today (`splitAnnexB` still throws on `P_bad`) and passes
  after step 2, and reverting step 2 makes it -- and only it -- fail.
- **Leave `ClipRemuxerTests.liveRemuxFailureRemovesStaleAndPartialOutputs`
  unchanged** -- its `catch ClipRemuxError.invalidTransportStream` is a case-only
  pattern, so the now-"No H.264 PES packets found." throw still matches and the
  stale/partial-cleanup assertion still holds.

## Verification

- Run the full app suite: `just app-test` (xcodebuild, scheme `DanCam`,
  iOS Simulator). All existing fixture tests (`demuxesBundledTransportStreamFixture`,
  the streaming-vs-batch assembler equivalence test, `liveRemuxesTransportStreamFixtureToPlayableMP4`)
  must still pass -- they are the regression guard that clean-clip output is
  unchanged.
- Confirm the new failing-today behaviors now pass:
  `toleratesUnalignedTruncatedTransportStream` and
  `liveRemuxesTruncatedTransportStreamToPlayableMP4` (both throw at the strict
  alignment/sync guard before this change), and
  `skipsPESWithoutAnnexBStartCode` (throws at `splitAnnexB` before step 2).
- Single-test runs use the same command with
  `-only-testing:DanCamTests/<Suite>/<method>`.

## Out of scope (state for reviewers)

- "Single parse feeding both" (sharing one parse across the progressive +
  finalizer passes) -- deferred per ADR 08; this fix unifies only the demux
  stage.
- Multi-segment DTS continuity (`reset_timestamps` reset across stitched
  segments) -- lane B-04, a separate concern.
- Any attempt to detect/trim/repair the truncated final frame -- no reliable
  signal (see key design decision).
- Pi-side keyframe-interval / sub-GOP slicing -- ADR 08's separate lever.
- Removing the one transient full-file copy -- negligible on a phone; revisit
  only if profiling demands.
