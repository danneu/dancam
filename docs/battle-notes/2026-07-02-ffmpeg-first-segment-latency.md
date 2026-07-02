# Battle Note: ffmpeg first-segment latency

- **Date:** 2026-07-02
- **Status:** Parked
- **Area:** raspi camera owner / recording pipeline
- **Question:** why does the first `seg_NNNNN.ts` file appear several seconds after
  recording starts?

## Short version

The slow first live row is not the app, not the segment watcher, and not Picamera2
encoder startup. The remaining delay is ffmpeg's raw H.264 input stream analysis:
even with `-f h264 -r 30`, ffmpeg still waits to read enough H.264 data from stdin
before it begins muxing and creates the first segment file.

The attempted fix should not be committed as-is. It changed the ffmpeg argv in the
right neighborhood, but the real Pi still created the first file after about 3.4s.

## Starting hypothesis

Home waits for the live row until `/v1/events` reports `segment_opened`. The real
camera child reports `segment_opened` only after `watch_segment_events` sees the first
bare `seg_NNNNN.ts` file and stamps it into the durable segment namespace.

The first hypothesis was: Picamera2's `FfmpegOutput` uses
`-use_wallclock_as_timestamps 1`, and ffmpeg waits on its default input analysis to
measure the frame rate before it opens the segment muxer. Since the camera config is
already 30 fps (`FrameRate: 30`, `iperiod=30`), declaring the input as CFR with
`-f h264 -r 30` looked like the clean fix.

## What we tried

A local experiment changed `raspi/camera/camera.py#recording_ffmpeg_output` into a
two-part shape:

- keep the existing output tail unchanged: `setts`, `segment_time 30`,
  `segment_format mpegts`, `reset_timestamps 1`, and `segment_start_number`
- add a pure ffmpeg command builder that starts ffmpeg as:
  `ffmpeg -loglevel warning -y -f h264 -r 30 -thread_queue_size 64 -i - -c:v copy ...`

Because Picamera2's `FfmpegOutput` hardcodes its input args, the experiment subclassed
`FfmpegOutput` in `RealCameraDriver.start_recording` and overrode only `start()` to
spawn the explicit command. `outputframe`, `stop`, broken-pipe handling, pacing, and
the output tail stayed inherited.

Self-test and Rust tests passed, and a non-real-time Mac ffmpeg spike was encouraging:

- first output file appeared in about 122 ms
- `ffprobe` reported `30.000000` s for `seg_00000.ts`
- packet PTS spacing was exactly 3000 ticks across 900 packets

That was misleading because the sample was fed as fast as the Mac could read it, not at
real camera speed.

## Pi evidence

The experiment was deployed to the Pi and the live ffmpeg process was inspected. The
command was correct:

```text
ffmpeg -loglevel warning -y -f h264 -r 30 -thread_queue_size 64 -i - -c:v copy ...
```

But the service-level smoke still missed the goal:

- `/v1/recording/start` returned in about 248 ms
- direct filesystem polling saw `seg_00038.ts` after about 3415 ms
- `/v1/status` saw `current_segment` after about 3498 ms

A direct camera timing probe then separated the stages:

```text
output_start_ms 3
start_encoder_return_ms 79
first_outputframe_ms 147 keyframe True bytes 22315 timestamp 0
first_keyframe_ms 147 bytes 22315 timestamp 0
first_file_ms 2902 file seg_00000.ts
```

That rules out Picamera2/V4L2 encoder startup as the slow part. The first encoded
H.264 keyframe reaches ffmpeg at about 147 ms; ffmpeg creates the segment file about
2.9s later.

## Reproduction

A better Mac reproduction fed raw H.264 to the second ffmpeg process in real time:

```text
ffmpeg -re -f lavfi -i testsrc=size=1920x1080:rate=30 -c:v libx264 -g 30 -f h264 - |
  ffmpeg -f h264 -r 30 -thread_queue_size 64 -i - -c:v copy ...
```

That reproduced the delay: first segment appeared after about 2949 ms.

Adding `-fflags nobuffer` did not materially help. Adding `-analyzeduration 0` alone
also did not help. Capping `-probesize` did:

- `-probesize 32`: about 1292 ms on the real-time Mac reproduction
- `-analyzeduration 0 -probesize 32`: about 1347 ms on the real-time Mac reproduction
- larger probesize caps like 2048 and 4096 produced similar roughly 1.3s results in the
  Mac reproduction

The Pi confirmation with `-probesize 32` showed:

```text
output_start_ms 2
start_encoder_return_ms 69
first_outputframe_ms 146 keyframe True bytes 22755
[h264] Stream #0: not enough frames to estimate rate; consider increasing probesize
first_file_ms 982 file seg_00000.ts
```

That nails the remaining delay: ffmpeg is waiting to read enough raw H.264 stream data
for input stream analysis before it starts writing the first segment. The declared
format/rate removes part of the ambiguity, but does not by itself cap the amount of
data ffmpeg reads before muxing.

## Current best explanation

Raw H.264 on stdin has no container metadata. ffmpeg still runs `avformat_find_stream_info`
enough to learn stream details from the elementary stream. On a live 30 fps feed, that
means waiting for enough SPS/PPS/frame data to satisfy the probe budget. Because the
Pi is feeding frames in real time, the default probe budget translates into seconds of
wall-clock delay.

The segment watcher is doing what it should: it cannot emit `segment_opened` until
ffmpeg creates a file. The app is also doing what it currently specifies: the live row
appears only after `current_segment` exists.

## Next move, if resumed

Do not revive the `-f h264 -r 30` change alone. A new plan should test and implement a
bounded-probe command, likely:

```text
ffmpeg -loglevel warning -y -f h264 -r 30 -probesize 32 -thread_queue_size 64 -i - ...
```

Open questions before committing that approach:

- What is the smallest robust `-probesize` on the real Pi camera stream across cold
  starts, warm starts, and scene complexity?
- Does the smaller probe ever fail to learn required H.264 dimensions/profile data, or
  does the repeated SPS/PPS from `H264Encoder(repeat=True)` make it reliable?
- Do 35s Pi recordings still cut at about 30s and report correct `ts_duration` values?
- Does ffmpeg's "not enough frames to estimate rate" warning matter if `-r 30` and
  `setts=pts=N*DURATION:dts=N*DURATION` are both present?

Required gate for any resumed fix:

- first file appears in under 1s on the Pi
- first full segment reports about 30s by `ffprobe` and `ts_duration`
- `/v1/status` and `/v1/events` expose `current_segment` quickly
- second recording session continues segment numbering without overwriting

## Operational caution

During this investigation the Pi was temporarily deployed with an experimental
`camera.py`. If the repo is parked without shipping a fix, redeploy the committed tree
before treating Pi behavior as representative.
