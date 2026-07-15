# Research: fMP4 vs MPEG-TS container overhead, measured on the real Pi

- **Date:** 2026-07-15
- **Status:** research notes, no decision taken. Input for a future design decision on
  migrating recording segments from MPEG-TS to fragmented MP4 (fMP4); this doc
  is the real-number groundwork, not the decision.
- **Related:** the [Pi recording design](../design/pi/recording.md), the
  [transport boundary](../design/boundary/transport.md),
  `raspi/camera/camera.py#def recording_ffmpeg_output`
- **Origin:** the fMP4 migration pitch claimed ~1% container overhead for fMP4
  vs "~5-15%" for TS, plus native AVFoundation playback with no remux. Before
  writing a superseding ADR we wanted measured numbers from the actual
  hardware, plus proof that segmented fMP4 stitches back together seamlessly.

## Methodology

All measurements ran on the dancam Pi (Zero 2 W, IMX708) with the `dancam`
service stopped (it owns the camera exclusively; the recorder was idle each
time, so no session was interrupted).

Remux-same-stream design: capture one raw H.264 elementary stream with
`rpicam-vid` at production encoder settings, then remux that identical stream
into both containers with `-c copy`. Container overhead is the question, and
identical input bits isolate it exactly -- two separate camera recordings
would confound overhead with scene content. Production `/data/rec` segments
are included only as a real-world cross-check.

Production settings matched (from `raspi/camera/camera.py#def start_recording`
and `#def recording_ffmpeg_output`): 1920x1080 YUV420 at 30 fps, H.264 at
10 Mbps, 1 s GOP, inline SPS/PPS. Capture:

```
rpicam-vid --width 1920 --height 1080 --framerate 30 --bitrate 10000000 \
  --intra 30 --inline --frames 900 -t 0 -n -o src.h264
```

Muxing:

```
# TS, production args
ffmpeg -r 30 -i src.h264 -c copy \
  -bsf:v setts=pts=N*DURATION:dts=N*DURATION -f mpegts out.ts

# fMP4, the flags a migration would use
ffmpeg -r 30 -i src.h264 -c copy \
  -movflags +empty_moov+default_base_moof+frag_keyframe -f mp4 out.mp4
```

Work area was `/data/tmp-fmp4test/` (deleted afterwards), not `/tmp`: Pi
`/tmp` is RAM-backed tmpfs on a 512 MB board and ~150 MB of test files there
would squeeze memory.

## 1. Finding: fMP4 overhead is ~0.02%; TS is ~2.8% (not 5-15%)

The 900-frame run, same elementary stream both ways:

| File            | Bytes      | ffprobe bitrate | Duration | Overhead vs raw |
|-----------------|------------|-----------------|----------|-----------------|
| raw .h264       | 37,497,147 | --              | --       | baseline        |
| .ts             | 38,541,880 | 10.28 Mbps      | 30.000 s | +2.79%          |
| fMP4 .mp4       | 37,505,499 | 10.00 Mbps      | 30.000 s | +0.022%         |

Real production segments from `/data/rec` as the cross-check (session 511):

| Segment   | Bytes      | ffprobe bitrate | Duration |
|-----------|------------|-----------------|----------|
| seg_00518 | 38,560,680 | 10.28 Mbps      | 30.000 s |
| seg_00519 | 38,552,972 | 10.28 Mbps      | 30.000 s |
| seg_00520 | 38,534,360 | 10.28 Mbps      | 30.000 s |

The test .ts matches production segments to within 0.05% in size and bitrate,
so the test pipeline reproduces production muxing almost exactly and the fMP4
number is trustworthy.

Two corrections to the migration pitch's framing:

- **TS overhead at our bitrate is ~2.8%, not 5-15%.** TS overhead scales
  inversely with bitrate (fixed 188-byte packetization tax); the 5-15% figure
  describes low-bitrate streams. Any ADR should cite 2.8%.
- **The win is still real:** fMP4 adds ~8 KB per 30 s segment where TS adds
  ~1 MB. That is ~1.04 MB saved per segment (2.7%), roughly 3 GB per day of
  continuous recording -- or equivalently 2.7% more retained footage in the
  same ring budget. The stronger argument remains playback: QuickTime /
  AVFoundation opens the fMP4 natively and refuses the .ts (verified on the
  Mac with these exact files).

An earlier run with the same method produced overheads of 2.78% / 0.023% --
the numbers are stable across captures.

## 2. Finding: segmented fMP4 stitches back bit-exactly (seamless)

Concern: does slicing a recording into fMP4 segments lose seamlessness when
the app stitches a pulled window back together?

Test: split the same 900-frame stream into 3x10 s fMP4 segments the way
production would (`-f segment -segment_time 10 -reset_timestamps 1
-segment_format mp4 -segment_format_options
movflags=+empty_moov+default_base_moof+frag_keyframe`), re-join with ffmpeg's
concat demuxer, compare against muxing the whole stream as one fMP4.

- **No frames lost or duplicated at boundaries:** each part is exactly 300
  packets / 10.000 s; the stitched file is exactly 900 / 30.000 s.
- **Bit-identical video:** the H.264 elementary stream extracted from the
  stitched file has the same md5 as the one extracted from the whole-stream
  fMP4. (Both extractions differ from the original .h264 only because MP4
  normalizes the repeated inline SPS/PPS; comparing the two extractions is
  the right test.)
- **Frame-exact timestamps across seams:** at both boundaries the pts step is
  exactly one frame duration (512 ticks at the mp4 timescale), same as every
  other frame.

Why this holds in production -- two invariants the pipeline already has:

- **One continuous encode, sliced downstream.** The camera never restarts
  between segments; ffmpeg's segment muxer routes every packet into exactly
  one file, cutting only at keyframes (the 1 s GOP gives a cut point every 30
  frames). True today for TS, carries over unchanged to fMP4.
- **Synthetic exact timestamps** (`setts=pts=N*DURATION`). Every segment is
  exactly 900 frames of exactly 1/30 s, so back-to-back insertion is
  frame-exact by construction, with no rounding drift over a long pull.

App-side note: gapless playback of multiple fMP4 files on iOS wants
`AVMutableComposition` (or pre-concatenation into one file), not
`AVQueuePlayer`, which can micro-stutter at item transitions. The files
themselves contain everything needed for seamless reconstruction.

## 3. Finding: segment "duration" is nominal, not wall-clock

All durations in this pipeline are synthetic frame-count math: `setts` stamps
frame N at N/30 s, so ffprobe duration is `frame_count / 30` regardless of
real elapsed time. Production's exact 30.000 s segments mean "900 frames",
nothing more. Corollary: if the sensor ever delivered under 30 fps, a "30 s"
segment would span more than 30 s of wall time and nothing in the container
would show it.

Related capture gotcha discovered along the way: `rpicam-vid -t 30000`
produced only 825 frames because the `-t` window includes ~2.2 s of camera
startup (sensor init, AE settle) before frames flow. `--frames 900 -t 0`
took 32.2 s wall and delivered exactly 900 frames at a sustained true 30 fps
-- so there is no production frame-rate concern, but per-second frame
delivery is startup-gated, which matters for anything that equates capture
wall time with footage duration. The production pipeline pays this startup
cost once per session (the first segment of a session may be short in
frames), not per segment.

## Sample files

A viewable set of the test outputs (whole fMP4, 3 parts, stitched fMP4, the
same stream as .ts, and the raw .h264) was copied to the dev Mac at
`~/Downloads/dancam-fmp4-test/`. Not checked in; regenerate with the
methodology above if needed.
