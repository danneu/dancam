# Plan: degrade on DTS discontinuity instead of failing the clip (33-bit wrap pivot)

## Context

Review finding #7 (consolidating `video-review.xegWVJ/02-ts-h264-demux.md#B-02`,
`.../05-pi-clip-serving.md#E-04`, `.../06-test-coverage.md#F-06`) flagged that a 33-bit
PTS/DTS wrap is unhandled across the pipeline. Investigation (`/verify-issue`) found the
finding mechanically off but pointing at real work:

- The wrap is **structurally unreachable within a clip today**: `recording_ffmpeg_output`
  in `raspi/camera/camera.py` uses `setts=pts=N*DURATION:dts=N*DURATION` (forces PTS==DTS,
  monotonic) plus `-reset_timestamps 1` with `-segment_time 30`, and `serve_clip`
  (`raspi/service/src/clips.rs`) maps one clip to one ~30s `seg_NNNNN.ts`. So per-clip DTS
  starts near 0, strictly increases, and never approaches 2^33. The wrap only matters if
  the encoder contract changes or footage is produced out-of-contract.
- The actually-**reachable** trigger for the same code paths is **corruption** (a bit flip
  in a PES PTS/DTS field, the crash-safe threat model / lane B-01), which can make DTS step
  backward.
- The real defect is that a backward/equal DTS is treated as a fatal, whole-clip error.
  Three throw sites (`H264AccessUnitAssembler.assemble` batch, and
  `StreamingH264AccessUnitAssembler.push` / `.flushDeferredPacket`) raise
  `ClipRemuxError.invalidH264`. This is the **last un-softened instance** of the
  "one anomaly fails the whole clip" pattern that the just-landed tolerant-finalizer work
  (`plans/impl/2026-06-30-1242-tolerant-finalizer-demux.md`, recorded under
  `app/docs/design/08-2026-06-27-progressive-fmp4-clip-playback.md`) has been dismantling.
- The batch path additionally **pre-sorts by DTS**, so a pure wrap is not even caught --
  it is silently reordered into a clip with one ~26.5h-duration sample (worse than a clean
  failure).
- Pi-side, `ts_duration` returns a garbage multi-hour duration for a wrap on small segments
  (the realistic ~1MB segment already returns `None` via the head/tail path).

**Intended outcome.** A DTS discontinuity -- corruption *or* a 33-bit wrap -- degrades to
"plays up to the discontinuity" uniformly across the durable and progressive paths, with no
crash, no whole-clip failure, and no silent 26.5h-gap clip. The wrap needs **no special
2^33 arithmetic**: it becomes one trigger of a generic "drop the non-strictly-increasing
access unit" policy shared by both assemblers. The Pi reports `None` (unknown) rather than a
bogus duration. The per-clip timestamp contract that makes all this correct gets written
down for the first time.

This is one coherent change (one "why": make the timestamp pipeline degrade on discontinuity
instead of failing). The sibling SPS/PPS-gating divergence (the other half of B-02) is a
separate root cause and is deferred as the immediate next change (see Out of scope).

## Hard constraint that shapes the design

Both the finalizer (`ClipRemuxerEngine`) and the progressive path (`FMP4Segmenter`) feed
**AVAssetWriter**, which rejects any sample whose DTS is not strictly greater than the
previous one (`input.append` returns false -> throw). The progressive writer rebases only
the *first* sample, so the timeline cannot be re-zeroed mid-stream. Therefore the only safe
degradation is to **drop** the offending access unit (never clamp, never emit it); keeping
the last good `held` unit guarantees the emitted DTS stays strictly increasing. This is
exactly the streaming path's existing `held`-based shape.

## Design -- app (`app/DanCam/DanCam/Media/Remux/H264AccessUnitAssembler.swift`)

Unify both assemblers on one policy: **emit `held`, advance on a strictly-increasing DTS,
drop any access unit that does not strictly advance it.** Skipping recovers from isolated
corruption / duplicate DTS; a sustained reset (wrap) drops everything after the break, i.e.
truncates at the discontinuity (the finalizer still produces a durable MP4 up to the cut;
the progressive playlist finalizes up to the cut on pull completion).

1. **Shared primitive.** Add a `static func` on the `H264AccessUnitAssembler` enum (callable
   from both, like the existing shared `splitAnnexB` / `avccSampleData` / `isSliceNAL`):
   ```swift
   /// Strictly-increasing DTS is the per-clip assembler contract (see the timestamp
   /// invariant in raspi ADR 01). Returns the positive tick gap, or nil when `next` does
   /// not strictly advance `previous` (duplicate DTS, backward corruption, or a 33-bit
   /// wrap) -- callers drop the offending access unit.
   static func strictlyIncreasingGap(after previous: Int64, to next: Int64) -> Int64? {
       let gap = next - previous
       return gap > 0 ? gap : nil
   }
   ```

2. **Batch `assemble`:**
   - **Remove the defensive DTS sort** (`let sortedPackets = packets.sorted(by:)`); iterate
     `packets` in decode order. For a valid stream decode order *is* DTS order, so this is a
     no-op on clean input (the fixture parity test proves it); on a wrap it makes the
     backward step visible instead of reordering it into a 26.5h-gap clip.
   - Replace the throwing emit loop (the `guard duration > 0 else { throw
     ClipRemuxError.invalidH264("Access-unit DTS values are not strictly increasing.") }`
     block) with a `held`-based loop that uses `strictlyIncreasingGap`: on a gap, emit the
     held unit with that duration and advance; otherwise drop the unit and `log` once
     (local `var didLogDiscontinuity = false` -- `assemble` is one call). Emit the final
     `held` with `inferredFrameDuration(from:)` (already computed). Give the batch
     `PendingAccessUnit` a small `accessUnit(durationTicks:)` helper mirroring the streaming
     one, or inline the `H264AccessUnit` construction.
   - Keep the genuine `throws` cases (`"Missing SPS/PPS parameter sets."`,
     `"No H.264 access units found."`) -- a thrown error is still correct for "no usable
     video at all." The existing non-empty `pendingUnits` guard already guarantees the
     held-based loop emits >= 1 access unit, so no new empty guard is needed.

3. **Streaming `push` / `flushDeferredPacket`:**
   - `push`: replace `guard duration > 0 else { throw ... }` with
     `guard let duration = H264AccessUnitAssembler.strictlyIncreasingGap(after: held.dtsTicks,
     to: pending.dtsTicks) else { logDTSDiscontinuityOnce(); return }`. Dropping `pending`
     (without touching `held` / `recentDurations` / `sps` / `pps`) keeps the stream
     monotonic.
   - `flushDeferredPacket`: replace `guard packetDuration > 0 else { throw ... }` with the
     existing `nextDTS == nil` fallback -- use `inferredFrameDuration()` for `unitDuration`
     rather than throwing; per-unit ordering is still enforced by `push`.
   - Add a `didLogDTSDiscontinuity` flag + `logDTSDiscontinuityOnce()` mirroring the existing
     `didLogMultiAccessUnitPES` / `logMultiAccessUnitPESIfNeeded` pattern.
   - These were the assembler's only throws, so `push`, `flushDeferredPacket`, the private
     `append(_:into:)`, and the public `append(_:)` / `finish()` all become **non-throwing**.
     Drop `throws`/`try` accordingly, then sweep *every* remaining `try` on a
     `StreamingH264AccessUnitAssembler.append(_:)` / `.finish()` call -- production and tests:
       - Production: `ProgressiveSegmenter.consume`
         (`app/DanCam/DanCam/Media/Stream/ProgressiveSegmenter.swift`) -- drop `try`; its
         surrounding `do/catch` stays for the still-throwing demuxer.
       - Tests: the kept streaming-assembler methods in `H264AccessUnitAssemblerTests`
         (`skipsPESWithoutAnnexBStartCode`, `streamingAssemblerMatchesBatchAssemblerOnFixture`,
         `streamingAssemblerBecomesReadyOnlyAfterBothParameterSets`,
         `streamingAssemblerSubdividesMultiAccessUnitPESWhenNextDTSArrives`) and -- easy to miss,
         since it lives in another file -- `FMP4SegmenterTests.streamingFixtureClip`. Those
         functions keep `throws` (they still call the throwing `TSDemuxer.demuxH264PESPackets` /
         batch `assemble` / `#require`); only the assembler `try` is removed. A stray `try`
         left behind is a "no calls to throwing functions occur within 'try'" *warning*, not an
         error (`SWIFT_TREAT_WARNINGS_AS_ERRORS` is unset in `project.pbxproj`) -- but the sweep
         is part of this change, not optional cleanup.

No change to `ClipRemuxerEngine`, `FMP4Segmenter`, `ProgressiveSegmenter.fail`, or the viewer:
once the assemblers never emit a non-monotonic sample and never throw on DTS, the existing
machinery just works (finalizer writes the truncated-but-valid MP4; progressive keeps playing).

## Design -- Pi (`raspi/service/src/ts_duration.rs`)

Duration is best-effort metadata off the recording path. Make `duration_ms_from_span` reject
an implausible span instead of returning a confidently-wrong multi-hour value:

```rust
const MAX_PLAUSIBLE_SEGMENT_MS: u64 = 10 * 60 * 1000; // segment_time is 30s; 10 min is unambiguous headroom
// ... after computing `ms`:
if ms > MAX_PLAUSIBLE_SEGMENT_MS { return None; }
```

This catches a 33-bit wrap (~26.5h span) and any in-segment discontinuity that inflates the
span, on every code path, without order-preservation or wrap arithmetic, and without tripping
on the B-frame-reordered fixture (30s << cap). It makes the small-segment whole-file path
consistent with the large-segment head/tail path, which already returns `None` when
`tail.max < head.min`. (Large-file mid-segment discontinuity remains invisible to head/tail
windowing -- accepted residual for best-effort metadata.)

## Design -- docs (append-only notes, per house style; use `path#anchor`, not line numbers)

1. **`raspi/docs/design/01-2026-06-22-crash-safe-recording.md`** -- the authoritative new home
   for the **per-clip timestamp contract** (currently documented nowhere). Append a dated
   note: `recording_ffmpeg_output`'s `setts` forces PTS==DTS in coded order; `reset_timestamps`
   + `segment_time` + one-segment-per-clip make each clip start near 0, strictly increase, and
   never wrap the 33-bit field; consumers (`H264AccessUnitAssembler`, `ts_duration`) rely on
   this; a violation means corruption or an out-of-contract producer and is handled by
   graceful degradation (drop the unit / report unknown duration), never a crash. Record that
   the contract is regression-guarded, not merely documented: `raspi/camera/camera.py#run_self_test`
   asserts the exact ffmpeg arg vector (`setts=pts=N*DURATION:dts=N*DURATION`, `-segment_time 30`,
   `-reset_timestamps 1`), so silently dropping any of these fails the self-test.
2. **`app/docs/design/08-2026-06-27-progressive-fmp4-clip-playback.md`** -- append a dated note
   continuing the 2026-06-30 tolerant lineage: both assemblers now drop non-increasing-DTS
   access units (was: throw `invalidH264`); the batch path no longer pre-sorts by DTS; a wrap
   is one trigger of the generic discontinuity policy (no 2^33 arithmetic); durable and
   progressive output stay consistent. Cross-reference raspi ADR 01.
3. **`raspi/docs/design/03-2026-06-23-storage-ring-buffer-incident-lock.md`** -- append a note
   by the `dur_ms` / `ts_duration` pointer: an implausible PTS span (wrap or in-segment
   discontinuity) now yields `None` rather than a garbage duration. Cross-reference raspi ADR 01.

## Tests

**Swift -- `app/DanCam/DanCamTests/Media/Remux/H264AccessUnitAssemblerTests.swift`**
(reuse the local `annexB` / `nal` / `avcc` / `assertAccessUnits` helpers; build packets via
`H264PESPacket(payload:ptsTicks:dtsTicks:)`):

- **Rewrite** `streamingAssemblerRejectsOutOfOrderDTS` -> `streamingAssemblerDropsOutOfOrderDTS`:
  feed an isolated backward glitch -- `P0` (AUD+SPS+PPS+IDR, dts 0), `P1` (AUD+slice, dts 3000),
  `P_bad` (AUD+slice, dts 1000), `P2` (AUD+slice, dts 6000). Assert no throw (the call is now
  non-throwing), exactly 3 access units (`P_bad` dropped), strictly increasing DTS,
  `isKeyFrame == [true, false, false]`.
- **Add** `batchAssemblerDropsOutOfOrderDTS`: same packets through `assemble`; assert the same
  3 access units, no throw. Pins sort removal + batch drop.
- **Add** `assemblersTruncateAndAgreeAtDTSWrap`: wrap packets in decode order -- `P0`
  (SPS/PPS+IDR, dts `(1 << 33) - 6000`), `P1` (dts `(1 << 33) - 3000`), `P2` (dts 0),
  `P3` (dts 3000), with `ptsTicks == dtsTicks`. Feed both `assemble` and the streaming
  assembler; assert each path yields exactly the 2 pre-wrap access units (`P2`/`P3` dropped),
  no throw. Compare the two paths with the existing
  `assertAccessUnits(_:match:finalDurationToleranceTicks:)` helper (tolerance `3_000`), **not**
  raw `==`: the final unit's duration is computed by different code in each path -- batch
  `inferredFrameDuration(from:)` (median over pending diffs) vs. streaming
  `inferredFrameDuration()` (median over recorded gaps) -- and `streamingAssemblerMatchesBatch...`
  already tolerates exactly that last-sample divergence. They coincide for this uniform
  3000-tick input, so `==` would pass today, but the tolerance helper keeps the test from
  re-introducing the brittleness that helper exists to avoid (exact equality still holds on the
  pre-final unit). Pins: sort removal, wrap-as-discontinuity, cross-path parity, and
  "no 2^33 arithmetic."
- **Keep** `streamingAssemblerMatchesBatchAssemblerOnFixture` -- the clean-input parity guard;
  it must still pass after the sort removal (regression proof that decode order == DTS order
  on real footage).

**Rust -- `raspi/service/src/ts_duration.rs`** (`mod tests`; reuse `pts_buffer` / `encode_pts`,
which mask to 33 bits, and `TempFile`):

- **Add** `duration_is_none_for_wrapping_pts_span`: `pts_buffer(&[(1 << 33) - 3000, 0, 3000])`;
  assert `segment_duration_ms(...) == None` (the cap rejects the ~26.5h span).
- Confirm `parses_real_transport_stream_fixture` still asserts ~30_000 ms (well under the cap).

## Out of scope (state for reviewers)

- **SPS/PPS-gating divergence (B-02 other half)** -- batch keeps slices that arrive before
  SPS+PPS are latched while streaming drops them (`video-review.xegWVJ/02-ts-h264-demux.md#B-02`).
  Different root cause (parameter-set readiness, not DTS) with its own design question
  (drop pre-SPS/PPS slices vs. drop everything before the first IDR, interacting with
  edit-lists). The immediate next change; not bundled here.
- **Per-packet TS tolerance (B-01)** -- the `TSDemuxer` throws on malformed-but-aligned
  packets (`...#B-01`). Same "intolerant throw" family, different layer; its own change.
- **No 33-bit wrap reconstruction arithmetic** -- declined. The wrap is config-unreachable and
  is handled as a generic discontinuity; adding +2^33 math anywhere would be the "just-in-case"
  hardening AGENTS.md forbids.
- **Option B "clean-stop progressive at discontinuity"** (flush + finalize the playlist without
  `fail()`) -- deferred. The skip policy degrades safely (truncate + finalizer swap). Revisit
  only if a sustained-reset case ever becomes reachable.
- **Multi-segment DTS continuity (B-04)** -- already deferred by the tolerant-finalizer plan.

## Verification

- `just app-test` -- full Swift suite. New tests pass; existing fixture/parity/remux tests
  (`streamingAssemblerMatchesBatchAssemblerOnFixture`,
  `liveRemuxesTransportStreamFixtureToPlayableMP4`, the truncation tests) are the regression
  guard that clean-clip output is unchanged. Single test:
  `just app-test` with `-only-testing:DanCamTests/H264AccessUnitAssemblerTests/<method>`.
- `just raspi-test` -- Rust suite, including the new wrap test and the unchanged
  `parses_real_transport_stream_fixture`.
- `just raspi-check` -- fmt + clippy gate for the Pi change.
- `just adr-check` -- keep ADR doc structure green (appends only, no new files).
- Optional: `just app-build` to confirm the signature change (non-throwing streaming
  assembler) compiles with the updated `ProgressiveSegmenter` call site.

## Implementation notes

- The plan's explicit `try`-sweep list omitted `TSDemuxerTests.streamingAccessUnits`,
  a private helper in another test file that calls the now-non-throwing streaming
  `append`/`finish`. Handled it under the plan's own "sweep *every* remaining `try`
  ... production and tests" directive: dropped the two assembler `try`s but kept the
  helper `throws` (mirroring the plan's chosen pattern for the other test helpers) so
  its two `try` callers don't cascade. Also refreshed that helper's caller doc comment
  on `assertStreamingStaysMonotonic`, which described the assembler as one that "throws
  'DTS not strictly increasing' today" -- now false after this change.
- Gave the batch `H264AccessUnitAssembler` enum its own `private static let logger`
  (same subsystem/category as the streaming struct's) for the one-shot discontinuity
  `notice`, since the enum had no logger before.

## Follow Up

- `PreviewClientTests.realHyperChunkedFixtureDecodesMockFrameSequence` is flaky under
  a full `just app-test` run (it failed once there) but passes in isolation --
  a pre-existing timing/concurrency sensitivity in the MJPEG preview client, unrelated
  to this change.
