# Research: fMP4 crash recovery vs MPEG-TS, web deep dive

- **Date:** 2026-07-15
- **Status:** research complete, no migration decision taken. The desk truncation,
  real-iPhone, exact-Pi mux-flush, and three real-power-cut spikes are complete. The
  measured torn-tail behavior fails the migration pass bar, so the format decision
  does not reopen.
- **Related:** the [Pi recording design](../design/pi/recording.md)
  (power-loss defense and the decision-log entry deferring fMP4), the
  [fMP4 container measurement](2-fmp4-container-measurement.md) (measured
  overhead and playback groundwork), `raspi/camera/camera.py#def recording_ffmpeg_output`
- **Origin:** the migration pitch's remaining open question. Measurement notes
  already established the overhead win (~0.02% vs ~2.8%) and native
  AVFoundation playback. What was not established: whether a partially
  written fMP4 survives abrupt power loss as well as a truncated MPEG-TS
  file does. This doc is a multi-source web research pass on exactly that.
- **Method:** deep-research harness -- 5 parallel search angles, 17 sources
  fetched, 25 extracted claims each adversarially verified by a 3-voter
  panel (2/3 refutations kill a claim). Votes below are written
  `supporting-refuting`; only claims that survived are presented as
  findings. Point-in-time web evidence, not local measurement.

## 1. Finding: fMP4's crash-resilience design is genuine

Movie fragments were introduced into ISO/IEC 14496-12 specifically to improve
recording of long-running sequences; HTTP streaming reuse came later. The GPAC
wiki states this directly, corroborated by patent filings that describe movie
fragments as a way "to avoid losing data if a recording application crashes"
(3-0, <https://github.com/gpac/gpac/wiki/Fragmentation,-segmentation,-splitting-and-interleaving>).

The layout is repeating moof+mdat pairs after an initial ftyp+moov (3-0,
Apple WWDC 2020 session 10011). Everything up to the last complete pair
remains readable after an interrupted write; OBS Studio's Hybrid MP4 blog
post states "if the writing of the file is interrupted (e.g. due to a power
failure), everything up to the last fragment will still be readable" (3-0,
<https://obsproject.com/blog/obs-studio-hybrid-mp4>).

Apple's own AVAssetWriter fragmented-movie mode exists for this reason: "even
if writing is unexpectedly interrupted by a crash or something, data that is
partially written is still accessible and playable" (3-0,
<https://developer.apple.com/videos/play/wwdc2020/10011/>).

Fragment interval is an ordinary configurable muxer parameter (MP4Box
`-frag`, ffmpeg `-frag_duration`/`frag_keyframe`), so ~1 s fragments are
in-spec, and with the production 1 s GOP `frag_keyframe` yields ~1 s
fragments naturally (3-0, GPAC wiki).

## 2. Finding: plain MP4 is as bad as the recording page says

Multiple independently confirmed claims reinforce the existing exclusion of
moov-at-end MP4 from the hot path:

- A truncated plain MP4 loses the entire moov (codec parameters, sample
  index); no standard player opens it even though the mdat media bytes are
  intact (3-0, untrunc author's page,
  <https://vcg.isti.cnr.it/~ponchio/untrunc.php>).
- ffmpeg reports "moov atom not found"; VLC, HandBrake, GPAC, YAMB and
  dedicated recovery tools all failed on a real battery-death camera file
  (2-1, <https://github.com/ponchio/untrunc/issues/294>).
- Recovery requires a matched known-good reference file and specialist
  reconstruction of stsz/stco from raw NAL patterns -- best-effort, not a
  playback path (3-0, untrunc documentation).

## 3. Finding: three caveats surfaced; local measurement already retires two

Cross-reading against the [container measurement](2-fmp4-container-measurement.md)
leaves only the first caveat below live. The other two are kept with their
evidence because the refutations are dancam-specific, not general.

**The Apple crash-safety evidence is AVAssetWriter-specific.** The verifier
panel explicitly flagged that the WWDC claim covers AVAssetWriter's own
fragmented output and "should not be stretched" to ffmpeg-authored fMP4 read
by generic parsers. No confirmed source demonstrated that AVPlayer plays a
truncated ffmpeg-produced fMP4 -- one with a torn final fragment -- without a
repair or trim step. Notably, when writing finishes successfully,
AVAssetWriter defragments the file into a regular MP4 as its last step (3-0,
WWDC 10011): even Apple treats fragmented-on-disk as a crash-safe
intermediate state, not the deliverable.

**ffmpeg fMP4 muxing on Raspberry Pi had documented sharp edges -- already
retired by local measurement.** A Pi forums thread (verified against an
archive.org capture) shows fragmented MP4 output needed an rpi-ffmpeg patch
to pass SPS/PPS header bytes as extradata; after the patch, output was
playable with `-movflags frag_keyframe+default_base_moof`, while
`empty_moov` remained broken in that build (2-1,
<https://forums.raspberrypi.com/viewtopic.php?t=332970>). A related claim --
`h264_v4l2m2m` producing fMP4 with empty SPS/PPS arrays and an AVC NALU
length size of 0 -- was killed 1-2 (uncertain, same failure family;
<https://github.com/raspberrypi/linux/issues/4995>). Both incidents involve
ffmpeg's internal encoder path, not stream copy. The
[container measurement](2-fmp4-container-measurement.md) already did what
dancam would actually do -- stream-copied the real inline-header elementary
stream into fMP4 with `+empty_moov+default_base_moof+frag_keyframe` on the
Pi itself -- and the output played in QuickTime and probed cleanly, which
requires populated avcC extradata in the initial moov. This concern is
retired for the stream-copy toolchain.

**Fully fragmented MP4 has real player-compatibility costs -- narrow for
dancam's consumers.** OBS documented degraded seeking, missing duration in
file browsers, and some players treating the file as a livestream (3-0, OBS
Hybrid MP4 blog). OBS's own resolution was a hybrid mode that rewrites a
trailing moov on clean close -- engineering effort spent specifically to
escape these costs. But the failing consumers were Windows Media
Player-class readers of long fully-fragmented files. The
[container measurement](2-fmp4-container-measurement.md) shows dancam's
actual consumers behave: ffprobe reads exact duration and bitrate from the
fMP4, AVFoundation/QuickTime opens it natively, and segments stitch back
bit-exactly. For 30 s segments consumed by AVFoundation, this caveat is
close to moot; it matters only if the files ever reach other players
unrewritten.

## 4. Finding: real-world precedent is mixed

- Frigate (NVR) records 60 s MP4 segments via ffmpeg stream copy
  (`-c:v copy`, `-segment_format mp4`) (3-0,
  <https://docs.frigate.video/configuration/record/>). Note the shape:
  closed-per-minute plain MP4 files, i.e. Frigate accepts losing the
  in-flight minute on a crash.
- Dashcam vendors lean toward TS: VIOFO's A119 V3 manual states "TS format
  is better to avoid file corruption," verified against the manual scan
  itself, not just forum paraphrase (3-0,
  <https://dashcamtalk.com/forum/threads/mp4-or-ts-format-files.48631/>).

## 5. Refuted claims worth remembering

The adversarial pass killed several claims that commonly circulate:

- "Each fMP4 fragment is independently decodable" (1-2). Fragments need the
  initialization moov; they are not self-contained the way inline-SPS/PPS TS
  segments are. A recovered tail is only as good as the flushed file head.
- "TS provides better recovery than MP4 if the dashcam fails abruptly" (0-3
  as stated). Overgeneralized forum wisdom; the honest comparison is
  TS-vs-fMP4 recovery granularity, not TS-vs-plain-MP4.
- "iOS AVPlayer, browsers, and ffmpeg all correctly handle seeking in
  ffmpeg-authored fMP4" (0-3). Not established; seeking behavior without
  sidx/mfra varies by player.

## 6. Assessment: recovery granularity is roughly a wash

The dancam-specific reading of the evidence:

- Today, the watcher runs `fdatasync` on the open TS segment about every
  2 s, and any byte-prefix of a TS file decodes to the last complete PES
  packet. The power-cut loss window is the sync cadence, byte-granular.
- With 1 s fragments and a per-fragment sync, fMP4 recovers to the last
  complete moof+mdat pair. A torn partial fragment is discarded entirely,
  and some parsers choke on the dangling bytes rather than gracefully
  stopping. The loss window is comparable; the granularity is coarser
  (fragment vs byte) and the failure mode at the cut is less forgiving.

fMP4 is therefore not a recovery upgrade; at best it matches the current
design. The migration case rests on the measured overhead and playback wins
from the [container measurement notes](2-fmp4-container-measurement.md),
weighed against an unproven truncated-tail story on this exact toolchain.

## 7. Recommended next step: truncation and power-cut spike, not migration

The recording page's decision log defers fMP4 until "measured playback and
power-cut benefits" exist. Playback, overhead, and on-Pi muxing are now
measured; the power-cut half is not. The decision hangs on a single open
question: what consumers do with a torn fMP4 tail. Before any superseding
decision:

1. Truncate Pi-muxed fMP4 output (per the measurement notes' methodology) at
   adversarial byte offsets -- mid-moof, mid-mdat, exactly at a fragment
   boundary -- and record what ffprobe, an ffmpeg `-c copy` remux, and
   AVPlayer/AVFoundation on a real iPhone each do with the torn tail. The
   pass bar is playback (or trivial remux) up to the last complete fragment,
   never a rejected file.
2. Confirm how ffmpeg's mp4 muxer buffers and flushes at fragment
   boundaries, so the per-fragment recovery story composes with the existing
   ~2 s `fdatasync` cadence rather than silently trailing it.
3. Repeat as real hard power cuts on the Pi across fragment writes, matching
   the existing power-loss validation obligations, since page-cache and FTL
   behavior are exactly what desk truncation cannot simulate.

If the spike shows AVPlayer cleanly consumes truncated ffmpeg fMP4 and the
on-Pi muxing is solid, the format decision reopens with the evidence the
decision log requires. Until then, MPEG-TS stays the hot container.

## 8. Local spike: torn tails fail the consumer pass bar

The 30 s `whole.mp4` retained from the Pi measurement was the input. It contains an
initial 774-byte `ftyp`+`moov`, 30 one-second `moof`+`mdat` pairs, and a trailing
`mfra`. Each `moof` is 224 bytes. The spike truncated that exact Pi-authored file at
early, middle, and late instances of each cut class:

| Cut class | Complete fragments | ffprobe | ffmpeg `-c copy` remux |
|-----------|--------------------|---------|-------------------------|
| Exact boundary | 1, 15, 29 | Exit 0; 30/450/870 packets; exact 1/15/29 s | Exit 0; clean 1/15/29 s outputs |
| Mid-`moof` | 1, 15, 29 | Exit 1: `error reading header`, invalid data | Exit 183; no output |
| Mid-`mdat` | 1, 15, 29 | Exit 0 with corrupt-packet/partial-file warnings | Exit 0 with warnings; outputs were 1.500/15.533/29.500 s |

The mid-`mdat` remux does not simply discard the incomplete fragment. It preserves
the complete fragments plus whatever complete packets precede the torn access unit,
then finishes a normal MP4. That is a useful recovery path, but the mid-`moof`
result is a whole-file rejection by both ffprobe and the same ffmpeg remux.

The real-device check ran on Pelucho, an iPhone 13 mini on iOS 26.5.2. Three early
cuts were sufficient to distinguish the Apple parser from ffmpeg. For each file it
loaded `AVURLAsset`, created an `AVPlayerItem`, waited for `readyToPlay`, prerolled
`AVPlayer`, and decoded frames through an `AVAssetReaderTrackOutput`:

| Cut | AVPlayer / asset metadata | AVFoundation frame decode |
|-----|---------------------------|---------------------------|
| Exact boundary after fragment 1 | Accepted; playable; 1.0 s; preroll succeeded | 30 frames through PTS 0.9667 s; reader completed |
| Mid-`moof` for fragment 2 | Accepted; playable; 1.0 s; preroll succeeded | 30 frames through PTS 0.9667 s; reader completed |
| Mid-`mdat` for fragment 2 | Accepted; playable; advertised 2.0 s; preroll succeeded | Failed after 11 frames at PTS 0.3333 s with AVFoundation `-11880`, `Invalid sample cursor` |

The Apple parser is more forgiving than ffmpeg for a torn `moof`, but less useful
than the ffmpeg remux for the sampled torn `mdat`: it accepts the asset and then
fails before decoding even the first complete 30-frame fragment. AVPlayer readiness
is therefore not playback proof for a torn file.

The migration's pass bar was playback or trivial remux through the last complete
fragment, never a rejected file. It fails independently in two places: ffmpeg
rejects a mid-`moof` tail, and AVFoundation's decoded path loses good footage on the
sampled mid-`mdat` tail. A box-aware tail trimmer could convert both to exact-boundary
files before either consumer sees them, but that is a new recovery component, not
the direct-playback migration being evaluated.

## 9. Local spike: fragment completion needs explicit AVIO flushing

The mux growth trace was repeated on the actual Pi with ffmpeg
`7.1.5-0+deb13u1+rpt1`, using the retained Pi-captured `src.h264`, the production
timestamp bitstream filter, and the candidate fMP4 flags. A second trace changed
only `-flush_packets 1`. File size was sampled every 50 ms.

With ffmpeg's default `flush_packets=-1`, visible sizes advanced as follows:

```text
28
1,048,604
2,359,324
3,670,044
4,980,764
6,029,340
7,493,086  (clean close)
```

Those intermediate sizes are not fragment boundaries. They are the 28-byte `ftyp`
plus multiples of 262,144 bytes, usually in the middle of an `mdat`. The final file's
first boundaries are 1,256,580, 2,511,422, 3,752,170, and 5,001,178 bytes.

With `-flush_packets 1`, every visible update was an exact complete boundary:

```text
774          (ftyp + empty moov)
1,256,580    (fragment 1 complete)
2,511,422    (fragment 2 complete)
3,752,170    (fragment 3 complete)
5,001,178    (fragment 4 complete)
6,259,041    (fragment 5 complete)
7,493,086    (fragment 6 + clean trailer)
```

The ffmpeg 7.1 and 8.1 source matches the measurement. The MP4 muxer accumulates
the open fragment's media in a dynamic `mdat_buf`. The next video keyframe triggers
`mov_auto_flush_fragment`, which writes the prior fragment's `moof` and `mdat` to the
outer AVIO context. For regular files, the file protocol sets both its packet and
default flush threshold to 262,144 bytes. The muxer's default flush markers may
therefore leave the final sub-256 KiB tail in userspace until the next fragment is
written. At a one-second GOP that makes a completed fragment silently trail kernel
visibility by nearly another fragment interval.

`fdatasync` cannot flush bytes still buffered inside ffmpeg. Any fMP4 candidate must
therefore add `-flush_packets 1`; the existing 2 s watcher can then sync whole
completed fragments already visible to the kernel. The flag does not issue an
`fdatasync` itself. With one-second fragments, the remaining expected recovery bound
is the roughly 2 s sync cadence plus the currently open fragment, rather than that
bound plus an unobservable AVIO tail.

## 10. Hardware spike: real hard cuts

The real-power leg remains scientifically useful even though the consumer pass bar
has already failed. The prepared Pi runner uses the retained source stream, the
corrected `-flush_packets 1` candidate, and a separate 2 s file `fdatasync` plus
directory `fsync` loop matching the production watcher. Each run writes under
`/data/tmp-fmp4-crash-spike/`, never the recording ring.

Run repeated unsignaled cuts while the file is growing, then after each reboot:

1. record the surviving byte count and top-level box boundary;
2. run the same ffprobe, `-c copy`, and decoded-consumer matrix;
3. check ext4 mount/recovery, the previous-boot journal, and unrelated retained test
   files; and
4. distinguish an empty/missing file, a page-cache prefix, and any wider FTL or
   filesystem damage.

Manual cuts cannot reliably target a 224-byte `moof` write that lasts milliseconds.
They instead sample the real page-cache, filesystem, card-controller, and open-
fragment states that desk truncation omits. The adversarial byte-offset matrix above
continues to own deterministic box-level coverage.

### Hard cut 1: a real torn `mdat` also loses complete footage

The first run was unplugged after three observed sync-loop passes. The durable-byte
observations before the cut were 3,752,170, 6,259,041, and 8,747,845 bytes. After
reboot, the untouched file was 13,754,368 bytes: 11 complete `moof`+`mdat` pairs
ended at byte 13,750,898, followed by a complete 224-byte `moof` and 3,246 bytes of
its `mdat`. The card retained about 5 MB beyond the last observed `fdatasync`; that
is useful evidence that the sync cadence bounds guaranteed recovery, not necessarily
all recovery. The sync loop's redirected log itself recovered empty despite its
lines having been observed over SSH before the cut, another concrete example of why
console observation and post-crash file contents are different evidence.

ffprobe accepted the recovered file with corrupt-packet and invalid-NAL warnings. It
reported 331 packets and the fragment metadata advertised 12.0 s. An ffmpeg
`-c copy` remux also exited successfully with warnings and produced 331 packets over
11.033 s; decoding that remux exited successfully but reported an H.264 error at the
torn tail.

Pelucho accepted the untouched recovered file as playable, advertised 12.0 s, and
prerolled successfully. `AVAssetReader` decoded only 297 frames through PTS 9.8667 s,
then failed with AVFoundation `-11880`, `Invalid sample cursor`. The 11 complete
fragments contained 330 frames through PTS 10.9667 s, so the Apple decoded path lost
33 frames, about 1.1 s, that were already inside complete fragments. This reproduces
the desk mid-`mdat` failure mode on a file created by actual power loss.

The Pi remounted `/data` read-write, the recorder service returned active, and the
kernel reported no MMC or I/O errors. The persistent journal detected and replaced
uncleanly closed journal files, as expected after unplugging. The retained source and
the two earlier mux-growth artifacts were unchanged.

### Hard cut 2: nothing from the newly created file was durable

The second run targeted the interval shortly after process startup and before the
first 2 s sync-loop pass. After reboot there was no `powercut-02.mp4`, ffmpeg log, or
sync log directory entry. The runner deliberately executes `sync` before creating
those files, while its first file `fdatasync` and directory `fsync` occur only after
the 2 s delay. Losing all newly created entries is therefore consistent with cutting
before any post-creation durability barrier.

Because nothing from the run survived, post-boot evidence cannot establish exactly
how many bytes ffmpeg had produced before the cut, and there was no file to submit
to the consumer matrix. This result is not specific to fMP4 parsing: any newly
created segment can disappear if power fails before its directory entry and data
reach a durability barrier. It does show that the recovery bound needs an explicit
startup case; a periodic cadence does not protect the interval before its first
pass.

The Pi again mounted `/data` read-write and returned the recorder service to active.
The kernel reported no MMC or I/O faults, while the persistent journals reported the
expected unclean close. Every pre-existing file in the isolated test directory,
including the first cut and the retained source and mux-growth artifacts, remained
present at its prior size.

### Hard cut 3: an exact fragment boundary recovers cleanly

The third run targeted steady-state recording after allowing time for multiple sync
passes. The recovered file was exactly 2,511,422 bytes, the previously measured
boundary after fragment 2. It contained 60 packets over 2.0 s. ffprobe produced no
warnings, the `-c copy` remux completed without warnings and retained all 60 packets
over 2.0 s, and a full decode of the remux completed without warnings.

This is the positive recovery case: when the durable prefix ends at a complete
fragment boundary, neither inspection, trivial repair, nor decode loses good media.
The physical-iPhone exact-boundary result in section 8 already covers the same box
shape and decoded all frames; this third file was not separately rerun on the phone.

The Pi again mounted `/data` read-write and returned the recorder service to active.
There were no MMC or I/O faults, the persistent journals reported the expected
unclean close, and every pre-existing isolated-test artifact remained present at its
prior size. As in the first run, the sync log recovered empty, so the exact number of
completed pre-cut sync calls is not available as post-boot evidence.

## 11. Outcome

All three open questions are resolved:

1. Exact-boundary tails work, but torn tails do not meet the consumer pass bar.
   ffmpeg rejects a mid-`moof`; AVFoundation can accept a mid-`mdat` yet fail before
   the end of already complete fragments. A real torn-`mdat` power cut reproduced
   that AVFoundation loss.
2. ffmpeg requires `-flush_packets 1` for each completed fragment to become visible
   to the kernel at its boundary. With that flag, the existing roughly 2 s
   `fdatasync` cadence composes with one-second fragments; without it, userspace AVIO
   buffering silently trails the durability cadence.
3. Three real cuts produced the expected range of storage outcomes: a torn `mdat`,
   no surviving newly created file before the first barrier, and a clean exact-
   boundary prefix. All three reboots left ext4, the service, and unrelated retained
   files healthy.

The measured overhead and native-playback benefits of fMP4 remain real, but direct
playback of its power-torn tail is not reliable enough for the stated migration bar.
MPEG-TS therefore remains the hot recording container. Reopening fMP4 would require
a deliberate, box-aware recovery step that trims the tail to its last complete
fragment before ffmpeg or AVFoundation sees it.
