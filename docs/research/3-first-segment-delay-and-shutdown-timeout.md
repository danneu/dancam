# Investigation: delayed first recording segment + 90-second shutdown timeout

Date: 2026-07-15. Investigated on the real Pi (read-only) after deploying the
readiness/GC observability plan
(`plans/impl/2026-07-15-0911-raspi-readiness-and-gc-observability.md`).
Diagnosis only; no fix implemented yet.

Later the same day, a controlled Mac matrix and real-Pi implementation spike tested
the proposed bounded-probe fix. It preserved media correctness and reduced the
uncontended delay substantially, but it did not pass the accepted sub-second
first-file gate. Section 6 records the full results and corrects the initial probe
model so the experiment is not repeated.

## 1. Executive conclusion

Both anomalies are real, both **predate the readiness/GC plan** (they reproduce
on boot -1 under the pre-plan build), and they are **two independent defects
plus one amplifier**:

1. **First-segment delay** has an intrinsic floor of **~4.5-5 s**:
   `recording_started` (and the HTTP 200) fires the moment
   `Picamera2.start_encoder` returns, but the first `.ts` file is created only
   after FFmpeg finishes *probing* its input. picamera2's `FfmpegOutput` spawns
   `ffmpeg ... -i - -c:v copy -f segment ...` with **no input format,
   framerate, or probesize hints**, so FFmpeg must analyze the raw H.264 pipe
   (defaults: ~5 s analyzeduration / 5 MB probesize at 10 Mbps) before it opens
   any output file. The observed 13.4 s is that floor **inflated ~8.5 s by
   concurrent cold `/v1/clips` duration scans** competing for CPU and SD I/O.
2. **Slow `/v1/clips`** is the in-memory `DurationCache` going cold on every
   service restart: each uncached 100-clip page reads ~75 MB off the SD card
   (256 KB head + 512 KB tail per segment) -> ~6 s per page; warm pages take
   8-15 ms. This is a defect in its own right and the amplifier for anomaly 1.
3. **The 90 s shutdown timeout is deterministic, not a fluke -- 5 of 5 stops
   since 10:27 hit it.** `raspi/service/src/main.rs#fn main` runs
   `axum::serve(...).with_graceful_shutdown(...)`, which waits for *all
   in-flight connections* to finish, and only shuts the camera supervisor down
   **after** `serve` returns. The phone's SSE `/v1/events` and MJPEG preview
   streams never finish, so `serve` never returns. Separately, the unit's
   default `KillMode=control-group` means systemd's SIGTERM also kills the
   Python camera child directly; the supervisor -- never told to shut down --
   treats that as a crash and **respawns the camera child during shutdown**
   (the "fresh libcamera init" in the journal).

Operational note: the service was being manually cycled during the
investigation (stops at 10:47, 10:57, 11:05, 11:10 -- each timing out at
90 s). It was last started at 11:12:46 and was running at last check. All
investigation access was read-only.

## 2. Exact timeline (all times CDT)

### Recording start (session 511, boot `ffec6dedbed7`; boot epoch ~1784119953.51)

| Time | mono (s) | Event |
|---|---|---|
| 10:32:13.589 | 9580.08 | req 14 `GET /v1/clips` (page 1, **warm**) received |
| 10:32:13.590 | 9580.08 | req 15 `POST /v1/recording/start` received |
| 10:32:13.603 | | req 14 done, **14 ms** |
| 10:32:13.639 | | req 16 `GET /v1/clips` (deeper page, **cold**) received |
| 10:32:13.783 | 9580.27 | req 15 -> 200 (192 ms). Child had acked `recording_started`; FFmpeg already spawned |
| 10:32:19.836 | | req 16 done, **6197 ms** (~75 MB SD reads + PTS scanning) |
| 10:32:19.899 | | req 17 `GET /v1/clips` (next cold page) received |
| 10:32:26.511 | | req 17 done, **6611 ms** |
| 10:32:26.962 | 9593.45 | **seg_00510 created/stamped** -- 450 ms after the last cold scan ended; **13.37 s** after the start request |
| ~10:32:27 | | watcher (250 ms poll) emits `segment_opened` -> supervisor drives hub -> SSE -> app row goes live |

The app was never the bottleneck:
`app/DanCam/DanCam/Features/Recording/LiveRecordingStatus.swift#shouldShowPending`
faithfully renders server truth, and the server's `current_segment` stays nil
until the file exists -- because no footage file existed.

### Historical baseline (boot -1, pre-plan build; journal monotonic timestamps + stamped filenames)

| Session | Start (mono) | First seg (mono) | Delay | Concurrent `/v1/clips` |
|---|---|---|---|---|
| 194 | 662.4 s | 667.5 s | **5.1 s** | none |
| 447 | 11229.6 s | 11233.9 s | **4.3 s** | warm only (8-15 ms) |
| 510 | 18296.3 s | 18306.1 s | **9.8 s** | one cold request (req 85) received 6 ms before the start, **handler aborted, headless `spawn_blocking` scan kept running** |
| 511 | 9580.1 s | 9593.5 s | **13.4 s** | two cold pages spanning the entire gap |

Monotonic relationship: no cold scan -> ~4.5-5 s; one -> ~10 s; two -> ~13.4 s.

### Shutdown (10:27:33 instance; identically at 10:47, 10:57, 11:05, 11:10)

| Time | Event |
|---|---|
| 09:46:27-32 | phone opens `/v1/preview/live.mjpeg` + `/v1/events` (long-lived, still open at stop) |
| 10:27:33 | systemd `Stopping`; SIGTERM to **whole cgroup**; Rust logs `shutdown signal received`; Python child dies from its own SIGTERM |
| ~10:27:34 | supervisor (still in its normal loop -- the shutdown oneshot is only sent after `axum::serve` returns) sees `ChildSignal::Exited`, schedules respawn |
| 10:27:38 | respawned child's libcamera init logs (pid 2164) |
| 10:29:03 | `stop-sigterm timed out` -> SIGKILL to dancam, both python3 processes, tokio workers. Pid 2164 alive at kill = supervisor never received shutdown = `serve` never returned |

The 10:50-10:58 instance (pid 2868) is decisive for the mechanism: its *only*
long-lived connection was one MJPEG preview stream (request 1), and it still
hung the full 90 s -- an open streaming response alone is sufficient.

## 3. Root causes and confidence

1. **13 s gap = FFmpeg input-analysis floor (~5 s) + SD/CPU contention from cold
   clip scans (~8.5 s).** Location: entirely between `start_encoder` returning
   and FFmpeg writing its first output file -- after command admission, before
   the watcher/SSE/app, which together add well under 1 s. Floor:
   **high** confidence after the section 6 instrumentation located the delay
   between FFmpeg receiving its first keyframe and opening the output. The
   original attribution to the fps-estimation window specifically was wrong:
   `-framerate 30 -fpsprobesize 0` did not remove the residual wait. Contention
   contribution: **medium-high** (four natural experiments
   with a monotonic dose-response and 450 ms alignment; no controlled A/B --
   see section 5).
2. **Slow `/v1/clips` = cold in-memory `DurationCache`.** **High** confidence:
   request 6 (first list after restart) took 5598 ms; request 8 over the same
   data took 13 ms; the arithmetic (100 clips x 768 KB per
   `raspi/service/src/ts_duration.rs`) matches. It *contributes to* anomaly 1,
   and is also why the delay showed up now: the deploy had just wiped the
   cache and ~500 segments were on disk.
3. **Shutdown timeout = graceful shutdown waits forever on SSE/MJPEG streams;
   supervisor shutdown is sequenced after `serve` returns**
   (`raspi/service/src/main.rs#fn main`). **High** confidence: 5/5
   deterministic 90 s timeouts; open stream present in every case; the
   respawned child surviving to SIGKILL proves the supervisor's shutdown
   oneshot was never sent. **Camera init during shutdown** = default
   `KillMode=control-group` SIGTERMs the child; the unaware supervisor
   respawns it per its crash/backoff logic
   (`raspi/service/src/camera/mod.rs#fn supervise`). **High** confidence
   (direct code + journal).
4. **Regression status: none of these are regressions from the readiness
   plan.** Boot -1 (pre-plan build) shows the same delays, and the 10:27:33
   hang was stopping the *pre-plan* binary. They are longstanding design gaps
   newly made visible by real-Pi usage with a large segment ring and
   app-connected deploys.

## 4. Evidence highlights and ruled-out alternatives

Ruled out:

- **App rendering / SSE delivery** -- server truth (`current_segment` nil)
  matched what the app showed; SSE application happens on the supervisor task,
  which was idle.
- **Rust-side lock/blocking-pool coupling between `/v1/clips` and the start
  path** -- the start handoff mutex and segment allocation completed within
  the 192 ms HTTP window; clip listing shares no lock with the camera command
  path; the segment watcher lives in the Python process. Remaining coupling is
  OS-level CPU/SD only.
- **Typed command errors, GC malfunction, storage refusal** -- logs healthy
  throughout.
- **Sensor at 50 C** -- no observed thermal throttling or camera errors; the
  delay is fully accounted for otherwise. Keep as an environmental watch item
  only.

Open question (minor): at 10:30:10 a cold page request (req 9) was
client-aborted; its blocking scan should have warmed pages that were
nonetheless cold again at 10:32:13 (req 16). Not resolvable from logs --
request logging omits query strings, so page identity is unprovable. One
suspect worth checking during the fix: `DurationCache::forget` bumps a
*global* generation that discards **all** in-flight inserts, so any deletion
landing mid-scan throws the whole scan's work away.

## 5. Why no controlled with/without-clips comparison was run

A controlled reproduction requires starting/stopping real recording (live
hardware state, footage) while the service was being actively cycled, with the
sensor at its 50 C documented limit. Instead the four natural experiments
above vary exactly the independent variable (concurrent cold clip scans)
against fixed hardware/code and show a clean dose-response. If stronger proof
is wanted later, the safe protocol is: (a) restart service, immediately start
recording with *no* app clip browsing -> expect ~5 s; (b) restart service,
start recording while `curl`ing two cold `/v1/clips` pages -> expect ~10-13 s;
timestamped via journal + stamped filenames, no code changes needed.

## 6. Follow-up: bounded-probe implementation experiment

The proposed fix was exercised as a throwaway spike on 2026-07-15. Nothing from the
spike was committed, and the Pi was restored to the committed camera owner afterward.
The Pi ended idle with `recording_readiness.ready == true`.

### Mac real-time matrix

The source was a real-time 1920x1080 30 fps libx264 stream, not the previously
misleading as-fast-as-possible pipe. Each required variant ran three times:

| ID | FFmpeg input arguments | First file (ms) | Warning |
|---|---|---|---|
| A | `-f h264 -r 30 -probesize 32` | 1280, 1276, 1285 | not enough frames to estimate rate |
| B | `-f h264 -framerate 30` | 2644, 2660, 2640 | none |
| C | `-f h264 -framerate 30 -fpsprobesize 0` | 2644, 2666, 2654 | none |
| D | C plus `-probesize 32` | 1281, 1272, 1272 | not enough frames to estimate rate |
| E | C plus `-avioflags direct` | 2645, 2653, 2651 | none |

Variant C was the plan's primary hypothesis. Its result disproves the claim that a
demuxer-declared rate plus `-fpsprobesize 0` is sufficient to make stream discovery
exit after the first parsed frame. D behaved exactly like the old bounded-probe
control A. The Mac absolute floor includes libx264 startup buffering, so it selects
relative candidates but does not predict the hardware encoder's absolute latency.

One additional D-derived candidate, `-analyzeduration 1`, produced a first file at
1328 ms and the same warning. FFmpeg's `-find_stream_info` CLI option does not expose
a usable `-no_find_stream_info` inverse; attempting that spelling fails argument
parsing, so it is not a bypass.

### Real-Pi results

Variant D was implemented through the planned pure command builder and lazy
`FfmpegOutput.start()` override, then deployed without concurrent cold clip scans.
The live process had the intended input arguments:

```text
-f h264 -framerate 30 -fpsprobesize 0 -probesize 32
-thread_queue_size 64 -i - -c:v copy
```

Product-path measurements still missed the gate:

- HTTP start response: 181 ms;
- `current_segment` visible through `/v1/status`: 1265 ms in the first service run;
- instrumented repeat: 1401 ms to `current_segment`;
- direct warm camera-owner run: 1344 ms to the first file.

The instrumented repeat separated the stages:

```text
output start                 22 ms
start_encoder returned       82 ms
first output frame          137 ms (keyframe, timestamp 0)
FFmpeg rate warning       ~1018 ms
current_segment visible    1401 ms
```

The first H.264 keyframe therefore still reaches FFmpeg quickly. FFmpeg waits about
880 ms after that frame before warning and opening output, and the 250 ms segment
watcher cadence accounts for part of the remaining state-visibility delay. Setting
`-fpsprobesize 1` instead of zero made `current_segment` slower at 2102 ms. Adding
`-analyzeduration 1` made it 2042 ms. Those variants are rejected, not unexplored
follow-ups.

A direct-run cold result of 4181 ms is invalid as a product latency measurement: the
test sent `start_recording` before the newly launched camera owner emitted `ready`, so
it included Picamera2 initialization. Future direct probes must wait for `ready`
before starting their clock.

### Robustness results

The bounded-probe media remained correct despite FFmpeg's warning:

- the first full segment was exactly 30.000000 seconds by `ffprobe`;
- all 899 packet-to-packet PTS deltas were exactly 3000 ticks;
- `/v1/clips` independently reported `dur_ms: 30000`;
- session 2 started at segment 2 without overwriting session 1;
- SSE exposed the same current segment as `/v1/status` once the file existed.

Local validation also passed the camera self-test, all 204 Rust unit tests, 21 camera
process tests, the remaining integration suites, `just raspi-check`, provisioning
lint, and the mdBook link check. These results prove the candidate did not corrupt
the media contract; they do not make its latency acceptable.

### Corrected conclusion

Explicit raw-H.264 format and a 32-byte probe cap reduce the stock 4.5-5 second floor,
but the tested FFmpeg 7/8 CLI flags do not eliminate its residual stream-analysis
wait. The accepted gate was first file under 1 second, with about 300 ms as the
target. No valid Pi run passed it, so the implementation plan was stopped before
staging or commit.

Do not repeat variants A-E, `-analyzeduration 1`, or `-fpsprobesize 1`. The next
investigation should read the exact FFmpeg 7 stream-info path against the captured
raw H.264 shape and determine how to supply or bypass the remaining codec discovery.
If the CLI cannot do that robustly, evaluate a muxing path with explicit input caps
instead of weakening the gate or emitting `segment_opened` before a real media file
exists.

## 7. Recommended next work (in priority order)

**A. Fix shutdown (separate defect, highest operational pain -- every deploy
eats 90 s and SIGKILLs a recording camera).**

- Make streaming responses shutdown-aware: share a shutdown `watch` token; SSE
  and MJPEG preview streams terminate when it fires, letting axum's graceful
  shutdown complete naturally. Signal the camera supervisor concurrently with
  (not after) the HTTP drain so the child gets a clean `shutdown` command and
  `retire_child(graceful)` runs.
- Gate respawn on shutdown state so a child that dies during shutdown is never
  respawned.
- Defense-in-depth in `raspi/dancam.service` (owning artifact per repo
  convention): a modest `TimeoutStopSec`, and consider `KillMode=mixed` so
  only the Rust supervisor gets systemd's SIGTERM and remains the child's
  single owner (consistent with the single-owner lifecycle in
  `raspi/docs/design/23-2026-07-14-single-owner-camera-command-lifecycle.md`).
- **Behavioral tests:** integration test that opens an SSE and a preview
  connection, sends the shutdown signal, and asserts the serve future resolves
  within a small bound and both streams ended; supervisor test asserting that
  after shutdown is signaled, a child exit does not trigger a respawn and the
  child receives exactly one `shutdown` command.

**B. Cut the first-segment floor (~5 s -> sub-second).**

- Do not implement the rejected `-framerate`/`-fpsprobesize`/`-probesize` plan.
  Trace FFmpeg 7's remaining stream-info wait with the real repeated-SPS/PPS H.264
  input, then either supply the missing codec facts before analysis or select a
  muxing path that accepts explicit input caps. The command-builder and small
  `FfmpegOutput.start()` override remain a sound mechanical shape only if a new
  winning FFmpeg argument set is proven.
- **Behavioral tests:** camera-owner self-test asserting the constructed
  muxer contract; real-Pi measurement of start->first-file under 1 second as
  the acceptance check; retain the 30-second duration, 3000-tick PTS, session
  numbering, status, and SSE gates from section 6.
- Do **not** paper over the gap in the app; "Starting..." until footage exists
  is honest.

**C. Kill the cold-cache cliff in `/v1/clips`.**

- Warm the `DurationCache` in a low-intensity background task at startup (or
  persist durations keyed by `(seq, bytes)` across restarts -- durations of
  finalized segments are immutable). This removes both the 6 s user-facing
  latency and the contention amplifier at record start.
- While there: reconsider `forget`'s global generation bump (per-id
  invalidation suffices) so one deletion cannot discard a whole in-flight
  scan.
- **Behavioral tests:** after warmup completes, a full listing computes zero
  durations from disk (observable via the cache); a deletion mid-scan
  invalidates only that id.

**D. Minimal instrumentation (bounded, decision-grade):** include
`cursor`/`limit` and duration-cache hit/miss counts in the `/v1/clips` request
span, and surface `recording_started`/`segment_opened` (with session) as INFO
log lines. This would have collapsed most of this investigation into one
journal read.

## 8. Safe immediate workarounds

- **Deploys/stops:** disconnect the phone app (or at least leave the
  preview/live screen) before `systemctl stop`/deploy -- with no open streams,
  shutdown should complete promptly. This avoids SIGKILLing an actively
  recording camera.
- **Record-start latency:** after a deploy, let the clip list finish loading
  (or pre-warm with a few `curl /v1/clips` page fetches) before pressing
  Record; starts against a warm cache run at the ~5 s floor.

## 9. Shutdown fix verification -- 2026-07-16

The deterministic 90 second shutdown defect is fixed in the service and unit
artifacts. The Rust suite proves that cancellation ends SSE and MJPEG streams,
finite HTTP work drains, an unread connection cannot outlive the server deadline,
an active camera recording finalizes before supervisor success with no respawn, and
an active mock recording flushes and finalizes before its tasks join. The unit now
uses `KillMode=mixed` and `TimeoutStopSec=10`.

Real-Pi acceptance passed on 2026-07-16 with recording active, SSE and MJPEG clients
connected, and a third MJPEG socket deliberately left unread across the stop. The
client later drained 466,995 already-buffered bytes and reached connection close.
`systemctl stop dancam` completed in 3.50 seconds, below the 6 second gate; systemd
reported `Result=success`, `ExecMainStatus=0`, `ActiveState=inactive`, and
`SubState=dead`. The journal showed no camera/libcamera initialization between the
shutdown signal and deactivation. The last nonempty segment passed `ffmpeg -v error
-i <segment> -f null -`, and the service restarted recording-ready after the check.
