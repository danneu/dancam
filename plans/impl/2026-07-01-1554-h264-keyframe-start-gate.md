# Fix head-truncated H.264 remux: gate durable MP4 output at the first keyframe

## Context

The durable cached MP4 is now the **sole** clip playback/export artifact (ADR
`app/docs/design/13-2026-07-01-durable-clip-cache.md`, commit `c2fa3c6`). The only
surviving path is `TSDemuxer.demuxH264` -> `H264AccessUnitAssembler.assemble` ->
`ClipRemuxerEngine` (the progressive/streaming assembler was deleted in `c2fa3c6`).

`H264AccessUnitAssembler.assemble` emits every slice-bearing access unit in stream
order, gated only on "SPS/PPS exist somewhere" and "at least one access unit." There
is **no gate requiring output to begin at an IDR keyframe**. For a head-truncated clip
-- abrupt power loss / corruption that costs the opening GOP, after which the tolerant
demuxer resyncs mid-stream -- the finalized MP4 begins with a non-keyframe P-slice that
`ClipRemuxerEngine` faithfully tags `NotSync` / `DependsOnOthers`. That leading sample
references a frame that is not in the file: it is undecodable, and the app now treats
this MP4 as the only playback/export artifact.

Two confirmed failure shapes (both verified by trace against current code):

- **Late parameter sets:** packet 0 `[AUD, non-IDR(1)]`, packet 1 `[AUD, SPS, PPS,
  IDR]`. Output starts with the non-IDR.
- **Early parameter sets:** packet 0 `[AUD, SPS, PPS, non-IDR(1)]`, packet 1 `[AUD,
  IDR]`. SPS/PPS are present, yet output still starts with the non-IDR -- proving a
  "drop only before SPS/PPS" gate would be too weak.

The project already treats "remux output starts at a sync sample" as a first-class
invariant: `ClipRemuxerTests#assertSyncSamples` asserts the first decode-order sample
is full-sync. But every fixture starts cleanly at an IDR, so the invariant is never
exercised against head truncation. This change closes that gap in the same style as the
existing tail-truncation / mid-stream-garbage / sync-aligned-bit-flip resilience tests,
all of which prove their fix on the finalized MP4 through real AVFoundation.

Desired outcome: the durable MP4 always begins at a decodable sync sample, or the
remux fails cleanly when the salvaged stream contains no keyframe at all.

## The fix (root cause -- one pure function)

`H264AccessUnitAssembler.assemble` in
`app/DanCam/DanCam/Media/Remux/H264AccessUnitAssembler.swift`.

After the existing SPS/PPS-presence and non-empty guards, add a **keyframe-start gate**:
drop every pending access unit before the first `isKeyFrame == true`, then run the
existing DTS drop-and-log loop over the remainder. Throw when no keyframe exists.

```swift
guard let firstKeyFrameIndex = pendingUnits.firstIndex(where: \.isKeyFrame) else {
    throw ClipRemuxError.invalidH264("No H.264 keyframe found.")
}
if firstKeyFrameIndex > 0 {
    logger.notice("Dropped \(firstKeyFrameIndex) leading access unit(s) before the first keyframe (head-truncated clip).")
}
let decodableUnits = Array(pendingUnits[firstKeyFrameIndex...])
```

Then feed `decodableUnits` (in place of `pendingUnits`) to `inferredFrameDuration(from:)`,
`reserveCapacity`, and the `for pending in ...` DTS loop. Nothing else in the loop changes.

Why this shape:

- **Gate on first keyframe, not first SPS/PPS.** SPS/PPS are latched *globally* earlier
  in `assemble`, so they survive the prefix drop and still resolve the surviving IDR's
  format description. The early-parameter-sets scenario proves gating on SPS/PPS presence
  alone is insufficient.
- **Throw on zero keyframes.** A keyframe-less salvage cannot produce any decodable
  frame -- there is nothing to degrade to -- so failing is correct and consistent with
  the existing terminal `invalidH264` throws. (Keep the existing empty-units guard so
  "no access units" and "no keyframe" stay distinct diagnostics.)
- **Behavior-preserving for clean clips.** When the first access unit is already an IDR
  (every current fixture and every existing assembler/demuxer test), the gate drops
  nothing.
- **Log the prefix drop, don't drop silently.** The assembler already emits a one-shot
  `logger.notice` when it drops an out-of-DTS-order unit (the `didLogDiscontinuity` path),
  and `IncrementalTSDemuxer` logs resync / skipped-packet notices; a head-truncated clip
  losing its opening GOP is exactly the field diagnostic worth surfacing when investigating a
  power-loss recording. Match that style with one `notice` carrying the dropped-unit count,
  gated on `firstKeyFrameIndex > 0` (shown above). Log output is not meaningfully testable, so
  no test is demanded -- consistent with the existing untested DTS-drop notice.

The DTS strict-increase drop-and-log policy (`strictlyIncreasingGap`, the
`didLogDiscontinuity` notice) and the tolerant demuxer (`TSDemuxer` /
`IncrementalTSDemuxer`) are **untouched** -- this is purely an assembler-output gate.

## Testability seam (behavior-preserving)

`ClipRemuxerEngine.remuxSynchronously` in
`app/DanCam/DanCam/Media/Remux/ClipRemuxerEngine.swift` fuses demux + write in a
`private` function, so the AVAssetWriter path can only be exercised through full `.ts`
fixtures. Split it:

- Extract the writer half into an internal
  `static func write(clip: DemuxedH264Clip, to outputURL: URL) throws -> ClipRemuxResult`
  (target cleanup at entry, writer setup, sample loop, finish, and result assembly).
- `remuxSynchronously` keeps its existing pre-demux `Task.checkCancellation()` and
  `try? removeItem(at: outputURL)` exactly where they are today, then demuxes via
  `TSDemuxer.demuxH264(from: sourceURL)`, then calls `write(clip:to:)`.

Behavior-preservation caveat -- do **not** move the stale-output removal wholesale into
`write`. Today `remuxSynchronously` clears the output *before* demuxing, so a demux failure
still leaves the directory clean; if `write` owned the only cleanup, a demux throw would
skip it and strand stale output. Keep the pre-demux removal in `remuxSynchronously`, and
*also* have `write` clear its own target at entry (so a direct `write`-only test starts from
a clean path). The existing `liveRemuxFailureRemovesStaleAndPartialOutputs` would not catch a
regression here: `ClipRemuxer.live.prepareOutputURL` already sweeps every `clip-<id>-*.mp4`
at entry and the `.live` catch removes `outputURL` again, so the seam's own cleanup is masked
end-to-end -- another reason to get the boundary right by construction.

Pure extraction, no behavior change. Decouples demux from write (SRP) and lets the
end-to-end test push a head-truncated clip built from fixture-derived PES through the
**real** writer without synthesizing `.ts` bytes (the repo has no Swift TS-synthesis
tooling; head-cutting the committed fixture at the byte level is fragile because it strips
the leading PAT/PMT).

## Tests (TDD: each fails RED before the keyframe gate, GREEN after)

The `write(clip:to:)` seam lands first as behavior-preserving scaffolding, then tests 1-4
go RED against seam-present/gate-absent code, then the gate turns them GREEN. See
**Verification** for the exact sequence and why the seam must precede the RED run.

**A. Assembler unit tests** in
`app/DanCam/DanCamTests/Media/Remux/H264AccessUnitAssemblerTests.swift`, using the
existing private `annexB` / `nal` / `avcc` helpers:

1. `dropsLeadingNonKeyframeWhenParameterSetsArriveLate` -- packets `[AUD, non-IDR(1)]@0`,
   `[AUD, SPS, PPS, IDR]@3000`. Expect `accessUnits.count == 1`, `first.isKeyFrame == true`,
   `nalTypes == [[9, 7, 8, 5]]`. (Pre-fix: 2 units, first non-key.)
2. `dropsLeadingNonKeyframeEvenWhenParameterSetsAlreadyLatched` -- packets
   `[AUD, SPS, PPS, non-IDR(1)]@0`, `[AUD, IDR]@3000`. Expect `count == 1`,
   `first.isKeyFrame == true`, `nalTypes == [[9, 5]]`, **and** `clip.sps` / `clip.pps`
   still equal the sets from the dropped packet 0 (proves the global latch survives the
   drop, and that a "drop before SPS/PPS" gate would miss this).
3. `throwsWhenClipHasNoKeyframe` -- SPS/PPS present, only non-IDR slices. Expect a thrown
   `ClipRemuxError.invalidH264`. Assert via `#expect(throws:)` and **case-match** the
   `.invalidH264` case rather than string-matching the message (structure-insensitive).
   (Pre-fix: returns non-sync units, does not throw.)

**B. End-to-end artifact test** in `app/DanCam/DanCamTests/Media/ClipRemuxerTests.swift`:

4. `remuxedMP4FromHeadTruncatedClipStartsAtSyncSample` -- build the head-truncated packet
   list from **real fixture PES** (not hand-built bytes): demux `seg_00000.ts` with
   `TSDemuxer.demuxH264PESPackets(from:)` and take a small contiguous slice that begins a
   few frames before a recurring keyframe and ends a few frames after it, so the slice
   starts with a genuine non-IDR P-frame yet carries a later valid SPS/PPS/IDR.
   The fixture comment (`MediaFixtureURLs.swift#TSFixtureLayout`) guarantees SPS/PPS recur at
   PES 0/250/500/750 but names an IDR only at PES#0, so the keyframe at PES 250 is a fixture
   premise the test must **verify, not assume** -- take e.g. `allPES[248...253]` and add two
   raw-NAL `#require` guards (no `assemble` call, both invariant across the fix):
   - **Starts head-truncated:** `splitAccessUnitGroups(splitAnnexB(allPES[248].payload))`, and
     `#require` its first slice NAL (via `isSliceNAL`) is type 1 (non-IDR), not 5.
   - **Contains a keyframe:** `#require` some PES in `allPES[249...253]` carries a type-5 slice
     NAL (`splitAnnexB(pes.payload).contains { $0.type == 5 }`). This self-documents the
     precondition and converts the unverified "keyframe recurs at 250" fixture claim into an
     in-test check; without it, a regenerated fixture with a different GOP shape would fail deep
     inside `assemble` with `invalidH264("No H.264 keyframe found.")` instead of a clear
     precondition violation.

   A guard that instead `#require`d `assemble(...).accessUnits.first` be non-key would pass
   pre-fix but **fail after the gate** (the gated `assemble` now returns a keyframe first), so
   the committed test could never reach GREEN. Then call `H264AccessUnitAssembler.assemble`,
   `ClipRemuxerEngine.write(clip:to: tmpMP4URL)`, open the result via `AVURLAsset`, and assert
   the first decode-order sample is full-sync -- the RED->GREEN flip lives entirely in that
   MP4 sample-cursor assertion. Assert **only** sample-sync metadata (via the sample cursor)
   -- do not run `AVAssetImageGenerator`, so the pre-fix RED case does not depend on decoding a
   reference-less P-slice. (Pre-fix: first sample tagged `NotSync` -> RED.)

   **Why fixture-derived, not synthetic:** `ClipRemuxerEngine.write` first builds a
   CoreMedia format description from `clip.sps` / `clip.pps` via
   `H264CoreMediaSamples.makeFormatDescription`
   (`CMVideoFormatDescriptionCreateFromH264ParameterSets`), which parses real H.264
   parameter sets and throws on the tiny fake SPS/PPS the assembler unit tests use -- the
   writer would fail at format-description creation, before any sample-sync assertion runs.
   Real fixture PES carry valid parameter sets, so the writer reaches the sample loop.

Extract a focused `assertFirstSampleIsSyncSample(on:)` from the existing
`ClipRemuxerTests#assertSyncSamples` (which hard-codes `sampleCount > 800`, tuned to the
900-frame fixture and unusable on a small synthetic clip), and have `assertSyncSamples`
reuse it for its own first-sample check.

**Regression guard (no new test needed):** every existing assembler test and every
`ClipRemuxerTests` fixture starts at an IDR, so they must stay green -- a positive check
that the gate is behavior-preserving for clean input.

## Files

- `app/DanCam/DanCam/Media/Remux/H264AccessUnitAssembler.swift` -- keyframe-start gate in
  `assemble`.
- `app/DanCam/DanCam/Media/Remux/ClipRemuxerEngine.swift` -- extract `write(clip:to:)`.
- `app/DanCam/DanCamTests/Media/Remux/H264AccessUnitAssemblerTests.swift` -- tests 1-3.
- `app/DanCam/DanCamTests/Media/ClipRemuxerTests.swift` -- test 4 + `assertFirstSampleIsSyncSample`.

## Verification

TDD sequence -- the `write(clip:to:)` seam is behavior-preserving scaffolding and must land
**first**, because test 4 references it; otherwise the first "RED" would be a compile error,
not a behavioral failure:

1. **Extract the seam.** Split `remuxSynchronously` into demux + `write(clip:to:)` with no
   behavior change. Run the full media suite and confirm the existing `ClipRemuxerTests`
   (and all others) stay **green** -- this proves the extraction is inert.
2. **Add the failing tests.** Add assembler tests 1-3 and artifact test 4 against code that
   has the seam but **not** the keyframe gate. Confirm each fails **RED with a behavioral
   failure** (not a compile error): tests 1/2 return a leading non-keyframe, test 3 does
   not throw, test 4's finalized MP4 has a `NotSync` first sample.
3. **Apply the gate.** Add the keyframe-start gate to `assemble`. Re-run: tests 1-4 turn
   **GREEN**, and the full media suite -- `H264AccessUnitAssemblerTests`, `TSDemuxerTests`,
   `ClipRemuxerTests` -- stays green (behavior-preserving for clean input).

- **Run:** use the app test task from `just --list` (Swift Testing under Xcode; e.g.
  `xcodebuild test` for the DanCam scheme if no `just` task fits).
- No manual/device step required: test 4 proves the finalized MP4 begins at a sync sample
  through real AVFoundation.

## Non-goals / notes

- No ADR change required: the fix realizes the sync-start invariant already implicit in
  `assertSyncSamples` and the degrade-don't-fail philosophy (commit `fbaaea4`). Optionally
  add a one-line consequence note to ADR 13; no new or superseding ADR is needed.
- Do not touch the tolerant demuxer or the DTS drop-and-log policy.

## Follow Up

- Investigate flaky `PreviewClientTests.realHyperChunkedFixtureDecodesMockFrameSequence`; `just app-test` passed once after this change but failed twice on 2026-07-01 while the focused remux suites passed.
