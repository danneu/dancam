# Plan: make the TS depacketizer fail-soft on sync-aligned corruption

## Context

`IncrementalTSDemuxer.append` (in `app/DanCam/DanCam/Media/Remux/TSDemuxer.swift`)
calls `TransportStreamH264Parser.processPacket` with an un-caught `try`. Once the
depacketizer is sync-aligned (a packet starts with `0x47`), **any** per-packet
anomaly is a hard throw that unwinds out of `append` and aborts the entire clip:
- reserved adaptation-control (`adaptationControl == 0`),
- an `adaptation_field_length` that overruns the packet,
- a PSI section that spans more than one packet, a too-short PMT, a bad PSI pointer,
- a PES that is missing/short/truncated in its start code, header, or PTS.

The existing tolerance only covers two sibling cases: **alignment-breaking**
corruption (resync via `findResyncOffset`, reached only when
`residual[consumed] != 0x47`) and **sub-188 tail truncation** (residual drop +
emit the final partial PES). The remaining gap is **alignment-preserving**
corruption: a single bit flip that keeps 188-byte spacing but corrupts one header
field. That is squarely in the crash-safe ADR's threat model
(`raspi/docs/design/01-2026-06-22-crash-safe-recording.md`, Layer 3: "Power loss
mid program/erase can corrupt data that was already safely written").

**Why it matters / severity.** Both consumers share this one code path, so a
single corrupt packet kills both:
- finalized export: `demuxH264PESPackets` -> `TSDemuxer.demuxH264` ->
  `ClipRemuxerEngine.remux` throws; no MP4.
- progressive playback: `ProgressiveSegmenterPipeline.advance` catches and calls
  `fail(error)`, which tears the player down.

Because progressive also dies, the viewer's graceful degradation in
`ClipViewerViewController.handleFinalizerFailure` (which needs a live progressive
item, `source == .progressiveSwap && currentItemIsProgressive`) does **not**
apply -- the viewer falls to `state = .failed` ("Clip failed"). Net effect: total
clip loss (no playback, no scrub, no export), the exact opposite of the ADR's
"plays up to the cut" promise. This is strictly worse than the already-fixed
truncation case (commit `8363cc7`), where progressive stayed tolerant.

A tolerant TS decoder (ffmpeg / VideoToolbox) drops the bad packet and continues.
The demuxer is currently stricter than the truncation-tolerant format it parses.
This change closes that gap; it is the natural next increment of the tolerance
work already underway (`8363cc7` "tolerate truncated TS remux finalization", which
also made `H264AccessUnitAssembler.splitAnnexB` total -- returning `[]` instead of
throwing on a missing start code -- the same "return an outcome, don't abort" move
one layer up).

Two independent reviews flagged this same fail-hard-vs-fail-soft theme
(`video-review.xegWVJ/02-ts-h264-demux.md#B-01` and
`video-review.pyECTN/02-ts-h264-demux.md#B-06`). This plan dissolves both.

## Decisions (made, not options)

| Question | Decision | Why |
| --- | --- | --- |
| Control-flow model | `processPacket` becomes a **total function returning `PacketOutcome { .parsed \| .skipped(SkipReason) }`**, with private parse helpers using Swift 6 typed throws (`throws(SkipReason)`) converted to the outcome at one boundary. | Encodes "a per-packet anomaly can never abort a clip" in the type. Matches the precedent set by `splitAnnexB` going total in `8363cc7`. A blanket untyped `do/catch` in `append` would silently swallow any future genuinely-fatal throw as a skip. |
| `append` signature | **Drop `throws`** -- nothing reachable in it throws anymore. | Makes "append never aborts the clip" compiler-enforced. Ripple is two `try` deletions. |
| In-flight PES on skip | **Recovery-granularity policy** (table below): drop exactly the damaged frame, preserve complete neighbors (incl. SPS/PPS carriers). | A holed slice fed forward smears through P-frames to the next IDR; dropping a whole GOP or fusing two PESs are both worse than dropping one frame. |
| PES timestamp **value** corruption (the trust check) | **In scope: a PES-level DTS-monotonicity ordering check** (section 5) drops a PES whose coded DTS is non-monotonic vs the stream. | This is the real safety mechanism. A value-bit flip in a timestamp (33 of a timestamp's 40 bits are value bits) leaves `PTS_DTS_flags`, prefix nibbles, and marker bits all valid, so syntax checks cannot catch it; the bogus DTS then trips the streaming assembler's `StreamingH264AccessUnitAssembler.push` / `flushDeferredPacket` "DTS not strictly increasing" throw, failing the progressive player. Ordering is the only check that sees the corruption. |
| PES marker-bit/prefix validation | **In scope, but only as a cheap syntax gate** -- not the safety mechanism. | Rejects a structurally broken timestamp header early (wrong prefix nibble or marker bit) for free, but catches just the ~7/40 of timestamp-bit flips that land on a marker/prefix bit. The value-bit majority is covered by the ordering check above, so marker validation is belt-and-suspenders, not the closer. |
| Dropped-packet telemetry | **In scope, minimal** (count + one-shot `.notice` log). | Mirrors the existing `logResyncIfNeeded` / `didLogResync` pattern; the count is the field a future continuity-counter check reports through. |
| Continuity-counter tracking | **Deferred** (separate follow-up). | Distinct feature (new per-PID state); the `discardCurrentPES()` seam this plan adds is exactly what it will reuse. |
| Multi-packet PSI reassembly | **Deferred**; skip-and-wait is the policy. | dancam single-program PSI is single-packet by construction (all 302 PAT + 302 PMT packets in the fixture are single-packet) and PSI repeats frequently (a valid PMT every ~30 packets), so a skipped/corrupt PAT/PMT *table* re-latches on the next cycle. Caveat: video in the **pre-latch gap** (before `videoPID` is set) is dropped until the next good PMT. For the initial (latching) PMT @376 this is measured, not hypothetical: the next PMT is @6392 (pkt 34), so PES#0-2 are lost, and because this stream repeats SPS/PPS only every 250 PES (indices 0/250/500/750), the two consumers **diverge** -- the batch finalizer collects SPS/PPS globally and recovers a suffix from PES#3, but the *streaming* assembler needs an in-band carrier and cannot start until PES#250 (~8 s in). The table self-heals; the gap's video does not, and the streaming gap is the wider of the two. Not total loss for this fixture (SPS/PPS recur); it *would* be if they were single-shot -- and the deferred "retain last-good `videoPID`" follow-up does not rescue this case (no prior latch exists for the *initial* PMT). The initial-PMT test (Tests) pins the measured constants. |

## The change

All production code is in `app/DanCam/DanCam/Media/Remux/TSDemuxer.swift`.

### 1. Make the parser total

- Introduce `enum SkipReason: Error, Equatable` (one case per current throw:
  reserved adaptation control, adaptation-length missing/overrun, PSI
  pointer/section/PMT problems, PES start-code/header/PTS problems, plus a new
  `pesTimestampMarkerInvalid`) and `enum PacketOutcome: Equatable { case parsed; case skipped(SkipReason) }`.
- `processPacket(from:packetOffset:state:) -> PacketOutcome`: wrap a private
  `parse(...) throws(SkipReason)` and convert once (`do { try parse(...); return .parsed } catch { return .skipped(error) }`).
  Make `parsePAT`, `parsePMT`, `psiSection`, `parsePESStart`, `State.startPES`
  `throws(SkipReason)`; replace each `throw ClipRemuxError.invalidTransportStream(...)`
  inside the parser with the matching `SkipReason`.
- `ClipRemuxError.invalidTransportStream` survives only for the **one terminal
  case** -- `"No H.264 PES packets found."` raised in `demuxH264PESPackets` when the
  whole stream yields nothing usable.
- Delete the now-dead sync-byte guard and the `packetIndex` parameter/field (their
  only use was that message; `append`'s resync logic owns alignment). Keep an
  `assert(data[packetOffset] == 0x47)` to document the caller invariant.

### 2. Make `append` non-throwing + skip loop + telemetry

- `append` loses `throws`. Its loop body becomes a `switch` on the outcome:
  `.parsed` -> continue; `.skipped(reason)` -> `droppedPacketCount += 1` and
  `logDroppedPacketIfNeeded(reason)`. The cursor advance (`consumed += packetSize`, now
  the only one -- section 1 deletes `packetIndex`) stays **outside** any conditional so
  forward progress is unconditional (the infinite-loop defense).
- Add `private var droppedPacketCount = 0` and `private var didLogDroppedPacket = false`;
  `logDroppedPacketIfNeeded` logs once at `.notice` on the existing `ts-demux`
  `Logger`, mirroring `logResyncIfNeeded`.
- The `finish()` path (emit the trailing partial PES as-is for tail truncation) and
  the resync path are **untouched** -- this slots beside them.

### 3. Recovery-granularity policy (which frame is dropped)

The in-flight `currentPES` is the *previous* frame's payload, flushed lazily at the
next PUSI. The PID and PUSI bit are both computed before any per-packet anomaly, so
the parser can route precisely. Add one primitive, `State.discardCurrentPES()`
(`currentPES = nil`, sibling to `finishCurrentPES`).

| Skipped packet | Action on `currentPES` | Result |
| --- | --- | --- |
| Video-PID **continuation** (PUSI=0), adaptation-level anomaly | `discardCurrentPES()` | The in-flight frame is gap-corrupted; drop it cleanly (no holed slice reaches VideoToolbox). |
| Video-PID **PUSI** (PUSI=1), adaptation-level anomaly | `finishCurrentPES()` (flush) | The *previous* frame is complete and good (keep it, incl. SPS/PPS); only the new frame's start is lost. Orphaned continuations harmlessly no-op against `currentPES == nil`. |
| Video-PID **PES-header** anomaly (inside `parsePESStart`) | `finishCurrentPES()` in the parse-failure path | Section 5 reorders `startPES` to parse the candidate *before* touching `currentPES`. On a `parsePESStart` throw, the catch flushes the previous good frame and leaves `currentPES` nil -- same net result as today (previous frame kept, corrupt new frame not installed). |
| **PSI / other PID** anomaly | none | Unrelated to the in-flight video PES; leave it intact. |

Net: exactly one **PES** is dropped per corruption event -- one frame in the Pi's
normal one-access-unit-per-PES output; a multi-access-unit PES drops its few contained
frames (the streaming assembler's `deferredPacket` path proves multi-AU PES is a real,
supported case). With a trusted baseline the dropped PES is *normally* the damaged one
and its complete neighbors -- including the IDR/SPS/PPS carrier -- survive; the exception
is a *small* in-band downward DTS flip (section 5), where one-frame lookahead cannot tell
a spiked frame from a dipped one and the drop may fall on a good neighbor instead. Either
way it is exactly one PES, the emitted DTS stays monotonic, and it never aborts. This is
strictly better than unconditional discard (loses a good previous frame, can drop a whole
GOP of parameter sets) or never-discard (fuses two PESs / forwards a holed slice).

### 4. PES marker-bit / prefix validation (in `parsePESStart`) -- the cheap syntax gate

Before `decodeTimestamp`, validate the fixed `0010` (PTS-only) / `0011` (PTS) and
`0001` (DTS) prefix nibbles and the three interleaved marker bits; on mismatch throw
`SkipReason.pesTimestampMarkerInvalid` (-> skip the PES). These bits are mandated and
invariant in well-formed FFmpeg/Pi output, so this never fires on clean streams (no
false drops); it rejects a structurally broken timestamp header early and for free.

This is a *cheap syntax gate, not the safety mechanism*. Only ~7 of the 40 bits in a
5-byte timestamp are prefix/marker bits; a flip in any of the other 33 value bits
produces a syntactically valid header carrying a wrong number, which this check cannot
see. Closing the timestamp-value abort path is section 5's ordering check.

### 5. PES DTS-monotonicity ordering check (the trust check)

Marker validation cannot catch a value-bit flip in a timestamp: the header stays
well-formed and `decodeTimestamp` returns a wrong DTS. That bogus DTS then reaches the
assemblers. The streaming assembler (`StreamingH264AccessUnitAssembler.push` and
`flushDeferredPacket`) throws `"DTS not strictly increasing"` on the first
non-monotonic step, which `ProgressiveSegmenterPipeline` turns into `fail(error)` --
the exact total-clip-loss this plan exists to remove. (The batch
`H264AccessUnitAssembler.assemble` sorts by DTS first, so its exposure is narrower --
only a duplicate-DTS collision reaches its `duration > 0` throw -- but a bogus DTS
still scrambles frame order there.)

The fix makes **PES DTS ordering the trust check**, evaluated in the demuxer at the PES
boundary, where the corrupt value enters and at the granularity (one DTS per PES
header) at which it is coded. The lazy-flush model already gives a free one-frame
lookahead: `currentPES` is the previous, not-yet-emitted frame, so a candidate PES can
be vetted against it *before* either is emitted.

Mechanism, in `TransportStreamH264Parser.State`:

- Add `lastFinishedDTS: Int64?`, updated to the emitted DTS inside `finishCurrentPES`
  (the last *trusted*, already-output DTS).
- Reorder `startPES`: parse the candidate via `parsePESStart` **first** (into a local,
  not yet installed). On a `throws(SkipReason)` failure, flush the previous good frame
  (`finishCurrentPES`) and report the skip -- this is the section-3 PES-header row.
- On a successful parse, decide over `(lastFinishedDTS, currentPES?.dtsTicks,
  candidate.dtsTicks)` -- abbreviated `(lf, cur, cand)`, `lf` the trusted baseline.
  **The `discardCurrentPES()` branch requires a non-nil `lf`.** `lf` is nil across the
  start-of-stream window (nothing emitted yet, through both PES#0 and PES#1's boundary),
  and with no baseline there is no way to demote the held frame, so it must never be
  discarded there -- discarding it on a downward flip is the F1 total-clip-loss path
  (PES#0 is the SPS/PPS/IDR carrier). By the four `(lf, cur)` presence cases:
  - **`cur == nil`** (first PES, or resuming after a candidate drop): install `candidate`
    if `lf == nil` or `cand > lf`; else (`cand <= lf`) drop it (`currentPES` stays nil).
    Nothing is held, so nothing is ever discarded here.
  - **`cur != nil, lf == nil`** (held frame, no baseline yet -- the PES#0/PES#1 window):
    the held `cur` is the sole anchor. If `cand > cur`: `finishCurrentPES()` (emitting
    `cur` sets `lf`) then install `candidate`. Else (`cand <= cur`, non-monotonic):
    `finishCurrentPES()` (emit the held frame) and **drop the candidate** -- *never*
    `discardCurrentPES()`. This keeps a downward DTS flip on PES#1 from discarding PES#0;
    the corrupt second PES is dropped instead.
  - **`cur != nil, lf != nil`** (steady state, full 3-point rule):
    - **Monotonic** (`lf < cur < cand`): `finishCurrentPES()` then install. Normal path.
    - **Current is the spike** (violation, `cand > lf`): the held `cur` overshot;
      `discardCurrentPES()` (drop it unemitted, `lf` unchanged), install `candidate`.
      Catches a high-bit-up flip one frame after it appears -- still before the corrupt
      frame is ever emitted.
    - **Candidate is the dip** (violation, `cand <= lf`): the new frame dipped at/below
      the trusted baseline; `finishCurrentPES()` (the held previous frame is good) and
      **drop the candidate** (`currentPES` stays nil). Its continuations no-op against
      `currentPES == nil`.
- Pure ordering, no magic threshold: it fires on any DTS that is *out of order* -- any
  downward delta of at least one inter-frame gap (~3300 ticks at this fixture's ~27 fps).
  A high-bit flip is an obvious multi-thousand-second jump; a mid-bit flip (e.g. bit 12,
  ~45 ms) lands just one or more inter-frame gaps low -- still out of order, so still
  caught, but in the band where lookahead-of-one cannot distinguish a spiked `cur` from a
  dipped-but-still-above-`lf` `cand` and always blames `cur` (the bounded mis-attribution
  of section 3: still exactly one PES, still monotonic, never an abort). A flip in a low
  value bit stays monotonic and is left alone (a sub-millisecond wobble, harmless). This
  assumes the threat model's single, isolated corruption; two adjacent corrupt PES
  degrade to dropping one or two frames, never an abort.
- **Start-of-stream residual (documented, never an abort).** The `lf == nil` window can
  only ever *keep* the held frame, so the one case it cannot recover cleanly is the
  mirror of the case it fixes: a spike-*up* on the very first PES (`cur == PES#0`,
  corrupt-high DTS). That value becomes `lf` when PES#0 is emitted, and every later
  in-order PES then reads as a dip below it and is dropped until real DTS overtakes the
  spike -- degrading toward a first-frame-only decode. It still never aborts (the emitted
  DTS sequence stays monotonic) and PES#0's SPS/PPS are emitted, so parameter sets survive
  as long as they recur (this fixture repeats them every 250 PES; see the initial-PMT
  measurement in Tests). This is the oldest, single-flip-narrowest slice of the threat
  space; fully dissolving it is the escape hatch recorded under "No assembler change"
  below (two-frame lookahead would disambiguate spike-from-dip but adds state the
  never-abort guarantee does not need).
- Telemetry: an ordering drop increments the dropped counter and logs once at
  `.notice` ("Dropped a PES with non-monotonic DTS"), mirroring section 2.

The ordering drop is chunk-boundary invariant (it depends only on parsed PES DTS
values, which are already chunk-invariant), so it rides the same one-shot-vs-jittered
equivalence the existing tests assert.

**No assembler change.** Once the demuxer guarantees a monotonic PES DTS stream, both
assembler guards become quiescent on single-corruption input: the streaming assembler's
per-AU DTS (`packet.dts + index*unitDuration`, `unitDuration >= 1`) is monotonic within
and across PES, and the batch assembler's post-sort sequence has no duplicate to
collide. The guards stay as defense-in-depth; they are not modified. Relocating the trust check
*into* the assemblers was considered and kept as an **escape hatch**, not adopted now. It
is a larger, two-file change that must reconcile the batch-vs-streaming sort asymmetry
(the batch path sorts by DTS, so a value flip there mis-orders rather than aborts). But
it is **not** "no correctness gain," as an earlier draft asserted: in
`StreamingH264AccessUnitAssembler.append`, `latchParameterSets` runs *before* the `sps !=
nil, pps != nil` gate and the `push` DTS guard, so an assembler-level skip latches SPS/PPS
regardless of any DTS verdict -- structurally immune to the first-PES total-loss path
above. The demuxer home is chosen anyway because the baseline + one-frame lookahead that
disambiguates spike-from-dip lives naturally at the PES boundary (an assembler-level skip
faces the same first-held-AU ambiguity with no `lf` to resolve it), it is a single
in-scope file, and the residual it gives up is only the narrow first-PES window. If that
window ever proves to matter, moving the *trust check* (not merely the guard) into the
streaming assembler is the recorded next step, because it makes SPS/PPS survival
unconditional.

## Files

- `app/DanCam/DanCam/Media/Remux/TSDemuxer.swift` -- all of the above (the bulk).
- `app/DanCam/DanCam/Media/Remux/TSDemuxer.swift#demuxH264PESPackets` -- drop the
  `try` on `demuxer.append`; keep the terminal `"No H.264 PES packets found."` guard.
- `app/DanCam/DanCam/Media/Stream/ProgressiveSegmenter.swift` -- **verify no change**:
  `advance`/`finishInput` keep `try consume(packets: demuxer.append(...))` because
  `consume` still throws (assembler/segmenter/file I/O), and `demuxer.append` simply no
  longer contributes a throw. Genuine errors still reach `fail(error)`; only
  demux-originated per-packet throws stop doing so.
- `app/DanCam/DanCam/Media/Remux/H264AccessUnitAssembler.swift` -- **deliberately
  unchanged.** The streaming assembler's `push` / `flushDeferredPacket` and the batch
  `assemble` DTS guards stay exactly as they are; section 5 makes them quiescent by
  fixing the source upstream, and they remain as defense-in-depth. Verification confirms
  they still compile and never fire on the corrupted fixtures.
- `app/docs/design/08-2026-06-27-progressive-fmp4-clip-playback.md` -- append a dated
  note (see below).

## Tests

`app/DanCam/DanCamTests/Media/Remux/TSDemuxerTests.swift`. Add a shared driver that
copies the fixture (`MediaFixtureURLs.seg00000TS()`, 5387 x 188, aligned), applies a
byte-mutation closure, runs **both** one-shot `demuxH264PESPackets` and a jittered
incremental feed, and asserts they agree (the skip must stay chunk-boundary
invariant). Each case `#require`s its precondition (e.g. `data[off] == 0x47`,
current `adaptationControl == 1`) so it is self-validating against the real fixture.
Add helpers `assertDropsExactlyOnePES(_:from:at:)` and (only if a gap case is kept)
`assertGapsExactlyOnePES`. `H264PESPacket` and `ClipRemuxError` are already
`Equatable`.

Known fixture offsets (all verified against `seg_00000.ts`, 5387 packets): PES#0 PUSI
@564 (carries SPS/PPS; left intact by every *mid-stream* PES-corruption case below -- the
sole exception is the initial-PMT case, where PES#0 falls in the pre-latch gap and is
dropped); PES#1 PUSI @5452, continuation @5640; PAT @188; PMT @376 (next PMT @6392, pkt
34); SPS/PPS recur at PES 0/250/500/750; 900 video PES total.

| Case | Corruption | Expected |
| --- | --- | --- |
| Reserved AFC on continuation | clear `0x30` bits at the byte-3 of PES#1 continuation @5640 (AFC=0) | no throw; **drops PES#1** (`count == expected.count - 1`); PES#0 and PES#2.. byte-identical |
| Reserved AFC on PUSI | clear `0x30` bits at byte-3 of PES#1 PUSI @5452 (AFC=0) | no throw; **drops only PES#1**; **PES#0 preserved** (flush-not-discard) -- pins the granularity decision |
| Missing-PTS PES | set `PTS_DTS_flags = 00` in PES#1 header | no throw; drops PES#1; PES#0 preserved |
| Malformed PES markers (section 4 gate) | clear a PTS marker bit in PES#1 header (flags still valid) | no throw; drops PES#1. Without the syntax gate this would keep a garbage-PTS frame (count stays 900, not 899) -- the test discriminates the gate |
| Marker-valid DTS **value** flip up on PES#1 (section 5, steady state) | flip a high-order *value* bit (e.g. bit 30) up in PES#1's coded timestamp (PTS, or DTS if present), markers/prefix intact -- a spike *above* PES#0 (`cand > cur`, so `lf` latches at PES#0) | no throw; **drops exactly PES#1** (caught as "current is the spike" at the PES#2 boundary); PES#0 and PES#2.. byte-identical. The section-4 gate cannot see this -- only the ordering check fires. Without section 5 the bogus DTS survives and (via the streaming cross-check below) throws |
| Marker-valid DTS **value** flip *down* on PES#1 (section 5, `lf == nil` window -- the F1 path) | flip a high/mid *value* bit *down* in PES#1's coded DTS (markers/prefix intact) so `DTS_1 < DTS_0` while `lastFinishedDTS` is still nil | no throw; **PES#0 (SPS/PPS/IDR) survives** and output is non-empty; drops exactly PES#1 (`count == clean - 1`). This is the F1 total-loss path: without the `lf == nil` rule (no `discardCurrentPES` without a baseline) the natural reading discards PES#0 and the clip decodes empty ("Missing SPS/PPS") |
| Spike-*up* on the very first PES (section 5 residual floor) | flip a high *value* bit *up* in PES#0's coded DTS (markers intact) | no throw; **SPS/PPS present** in output; emitted DTS strictly monotonic. Asserts only the never-abort / SPS-survive floor -- deliberately **not** a frame count (this documented residual degrades toward first-frame-only; see section 5) |
| In-band downward DTS flip on PES#2 (section 5 mis-attribution) | flip a *mid* value bit (~one inter-frame gap, e.g. bit 12) *down* in PES#2's DTS, with PES#0/#1 already emitted (real baseline) | no throw; DTS-monotonic; drops **exactly one** PES. Pins the bounded-but-possibly-mis-attributed guarantee: lookahead-of-one may drop the good neighbor rather than PES#2, but never more than one and never an abort |
| Over-long adaptation field | set AFC=3 + `adaptation_field_length` past the packet on a PES#1 packet | no throw; PES#1 dropped/gapped per policy |
| Corrupt PMT after latch | corrupt a later PMT's `section_length` | no throw; `actual == expected` (videoPID already latched; redundant PMT skipped) |
| Corrupt **initial** PMT (before latch) | corrupt PMT @376's `section_length` (the latching PMT, before `videoPID` is set) | no throw. **Measured, frozen constants:** the next valid PMT re-latches at pkt 34 (@6392), so the demux output is exactly the clean decode minus the pre-latch gap PES#0-2 -- a contiguous suffix from PES#3 (`count == clean - 3`). SPS/PPS survive (this stream repeats them at PES 0/250/500/750). Cross-path: the batch/`assemble` clip recovers from PES#3, but `StreamingH264AccessUnitAssembler` cannot latch until the next *in-band* SPS/PPS carrier, PES#250 -- so its first AU is PES#250's (assert no throw, DTS-monotonic, first AU == PES#250; the streaming gap is ~250 PES wider than the batch gap). Pin these as documented constants; a future fixture with single-shot SPS/PPS in the gap would be total loss (assert-and-document, don't paper over) |

Plus an end-to-end ride-along in `app/DanCam/DanCamTests/Media/ClipRemuxerTests.swift`
(mirror the existing mid-stream-garbage MP4 test): AFC=0 on a PES#1 continuity packet,
write a temp `.ts`, `ClipRemuxer.live.remux`, assert non-empty output, fast-start
layout, single video track, sync samples, and decode at `.zero` and ~10s. This pins
the single-bit-flip-in-a-header case end-to-end.

**Cross-path streaming assertion (closes the finding's progressive-path gap).** The
marker-valid DTS-value cases (both the up and **down** flips on PES#1) must be proven on
the streaming path, not just the batch demux output: demux the DTS-value-corrupted
fixture, feed the resulting packets through a fresh `StreamingH264AccessUnitAssembler`
(`append` then `finish`), and assert neither throws and the emitted access units are
strictly DTS-monotonic with `count == clean - 1`. This is the unit that throws today; the
assertion proves the demuxer-level drop keeps the bogus DTS from ever reaching it -- the
down flip especially, since that is the F1 path (`ProgressiveSegmenter` would `fail`
without the `lf == nil` rule). Optionally also drive the case through
`ProgressiveSegmenter` end-to-end and assert the stream does not `fail(error)`. (The
first-PES spike-up residual floor is asserted separately -- no-abort / SPS-survive only,
no `count == clean - 1`, since it degrades by design.)

**Distinct from the existing resync test.** `incrementalDemuxerResyncsAfterInjectedGarbage`
*inserts* bytes (breaks alignment) and asserts *full equality* after `findResyncOffset`.
These new cases *flip bits in place* (alignment preserved, resync never consulted) and
assert a *localized bounded delta* (exactly one PES dropped -- except the documented
first-PES spike-up residual floor, which asserts only never-abort + SPS survival). Keep
both.

**Non-regression (must stay green):** `demuxesBundledTransportStreamFixture`,
`demuxedPESPacketsAreInvariantToChunkBoundaries`,
`incrementalDemuxerHandlesPSISectionsSplitAcrossChunkBoundaries`,
`toleratesUnalignedTruncatedTransportStream` (tail behavior unchanged -- this fix only
touches the mid-stream skip path, not `finish()`),
`rejectsTransportStreamWithNoH264Packets` (still throws the terminal error). No existing
test asserts on a deleted parser error string.

## ADR note

Append a dated entry to `## Consequences` of
`app/docs/design/08-2026-06-27-progressive-fmp4-clip-playback.md` (append-only, the
same place `8363cc7` recorded the truncation work): the demuxer is now fully fail-soft
per packet (skip-and-continue), the parser is total (`processPacket -> PacketOutcome`),
and recovery is PES-localized (exactly one PES dropped per corruption event -- normally
the damaged frame; a small in-band DTS flip may drop a good neighbor instead, still
exactly one, never an abort). Record that **PES DTS ordering is the trust check** that
closes the timestamp-value-corruption abort path, with PES marker/prefix validation
kept only as a cheap syntax gate; both assembler DTS guards are left unchanged as
defense-in-depth because the demuxer now guarantees a monotonic PES DTS stream. Record
one documented residual: a spike-up on the very first PES (before any baseline exists)
degrades toward first-frame-only but never aborts and preserves SPS/PPS -- relocating the
trust check into the streaming assembler, where `latchParameterSets` precedes the DTS
guard, is the recorded escape hatch that would make parameter-set survival unconditional.
Dropped-packet/-PES telemetry was added. Note that a pre-latch PAT/PMT corruption drops
video only until the next good table (the table self-heals; the gap's video does not):
measured on the fixture, a corrupt initial PMT @376 re-latches at the next PMT @6392, the
finalizer recovers a suffix from PES#3, and the streaming path recovers only at the next
in-band SPS/PPS carrier (PES#250) -- bounded, not total loss, because this stream repeats
SPS/PPS every 250 PES. Multi-packet-PSI reassembly and continuity-counter tracking remain
deferred -- the new `State.discardCurrentPES()` and `lastFinishedDTS` PES-lifecycle seams
are what a future continuity-counter check will reuse. No README change (app-only; no Pi
provisioning or onboard state touched).

## Verification

- `just app-test` (xcodebuild, DanCamTests, iPhone 17 / iOS 26.5). All new cases pass
  and the non-regression list stays green.
- Confirm the marker-valid DTS-value cases are green on **both** paths (batch
  `demuxH264PESPackets` output and the `StreamingH264AccessUnitAssembler` cross-path
  assertion; neither throws, AU sequence stays DTS-monotonic), including the **downward**
  flip on PES#1 (`lf == nil` window: PES#0/SPS/PPS survive, clip non-empty -- the F1
  path) and the first-PES spike-up **residual floor** (no abort, SPS/PPS present; no
  frame-count assertion).
- Confirm the initial-PMT case matches the measured constants: demux is a PES#3 suffix
  (`clean - 3`), and the streaming cross-path's first AU is PES#250's.
- Confirm the build surfaces no new `throws`/`try` warnings at the changed call sites
  (`demuxH264PESPackets`, the test helper), that `H264AccessUnitAssembler` compiles
  unchanged and its DTS guards never fire on the corrupted fixtures, and that
  `ProgressiveSegmenter` compiles unchanged.

## Implementation notes

- Section-5 value-corruption tests set an exact target DTS via a
  `writeTimestampValue` helper (which re-encodes the 33-bit value while preserving
  the prefix nibble and marker bits) rather than the plan's literal per-bit flips.
  A single-bit clear cannot land PES#2's DTS in the exact `(lastFinishedDTS, cur]`
  band the mis-attribution case needs (PES#2's set value bits don't include a
  ~one-inter-frame-gap bit), so explicit targets (8_000_000 spike, `pes0DTS - 3000`
  dip, 127_500 in-band) make every scenario deterministic while staying the same
  marker-valid-value class of corruption.
- Telemetry funnels every corruption drop through `processPacket -> .skipped`, so
  `IncrementalTSDemuxer.append` counts each dropped PES exactly once. The section-5
  "current is the spike" case installs the candidate *and* returns `.skipped`; this
  relies on inout-struct mutations persisting across a Swift `throw` (verified
  empirically), which is also what lets the typed-throws parse helpers apply
  recovery/flush before surfacing the skip at the single `processPacket` boundary.
- Fixture offsets/counts/DTS ticks are verified against `seg_00000.ts` and
  centralized in `TSFixtureLayout` (in `MediaFixtureURLs.swift`) so the TSDemuxer
  and ClipRemuxer suites share one source of truth.
