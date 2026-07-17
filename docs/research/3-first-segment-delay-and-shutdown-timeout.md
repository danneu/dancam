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

## 10. Direct per-segment PyAV qualification -- 2026-07-16

Direct per-segment PyAV is the first qualifying muxer candidate. The later explicit
libav helper, FFmpeg CLI/source-trace, and other native-muxer ladder entries were not
attempted because selection stops at the first candidate that passes every gate.

The real Pi ran Python 3.13.5, PyAV 14.2.0, Picamera2 0.3.36, and Debian/Raspberry Pi
FFmpeg `7.1.5-0+deb13u1+rpt1`. The throwaway owner retained the deployed Picamera2
capture, preview, and hardware H.264 encoder shape, but replaced `FfmpegOutput` and
the segment muxer with one ordinary PyAV MPEG-TS output container at a time. It
assigned the configured 30 fps timeline explicitly and closed the old container
before opening the next one. No product file changed.

The Rust service was stopped and idle for every candidate measurement. The harness
waited for the owner `ready` event before sending `start_recording`; no `/v1/clips`
request ran concurrently. Start receipt and durable publication used the same
Pi-kernel `CLOCK_BOOTTIME` clock. Publication followed PyAV packet mux, forced packet
flush, file `fdatasync`, and recording-directory `fsync`. At that exact point the
harness copied only the reported durable byte count and independently decoded one
complete frame from that prefix.

Two setup corrections preceded the qualifying campaign:

- The first launch never entered a measurement window. Picamera2 rejected the
  wrapper with `Must pass Output` before encoder start because the throwaway class
  did not yet inherit Picamera2's required `Output` base. It created no media.
- The first complete campaign lazily imported PyAV and the H.264 encoder class after
  start receipt. Its five cold results were 1694.969, 2290.656, 1742.922, 1427.596,
  and 1825.275 ms, so that prototype shape failed the gate; its five already-loaded
  second sessions were 97.439-109.249 ms. Moving candidate initialization before
  `ready` made the readiness claim honest, without changing Picamera2, Rust, HTTP,
  or any qualification gate. The complete campaign was then rerun from scratch.

The qualifying campaign produced these candidate-local publication latencies:

| Trial | Cold first session (ms) | Warm second session (ms) |
| ---: | ---: | ---: |
| 1 | 437.510 | 101.763 |
| 2 | 364.773 | 142.554 |
| 3 | 358.373 | 94.739 |
| 4 | 360.648 | 106.566 |
| 5 | 360.405 | 90.008 |

Every result is below 1 second. The cold median was 360.648 ms and the warm median
was 101.763 ms. The ten synced publication prefixes were 18,236-23,876 bytes; every
one independently demuxed and decoded a complete frame with no FFmpeg error.

The media and lifecycle gates also passed:

- The 35-second run closed its first segment at exactly 900 packets and
  30.000 seconds. Its next segment contained 142 packets before stop.
- Across all 11 ordinary campaign segments, the first PTS and DTS were zero,
  `PTS == DTS` for every packet, DTS was strictly increasing, and every adjacent
  delta was exactly 3000 ticks at the MPEG-TS 90 kHz time base. Every segment began
  with a keyframe carrying SPS, PPS, and IDR NAL units and decoded in full without
  error.
- Each of five second sessions created a distinct file. The SHA-256 digest of the
  first session's first segment remained unchanged after the second session.
- All ten normal stops reported the PyAV container and underlying file released,
  with no child process. Every owner then shut down with exit status 0, and no
  throwaway owner or FFmpeg process remained.
- Malformed JSON before start emitted an explicit parse error, created no segment,
  and did not resemble a recording. Synthetic open, write, mux, sync, and close
  failures each emitted their named error and terminated the owner nonzero: open
  and close exited 1; write, mux, and sync exited 70 from the encoder callback.

The 35-second recording-load run reached 107,708 KiB owner RSS, 47.236 C SoC, and
47.0 C sensor temperature. The maximum across all five qualifying trials was
111,728 KiB RSS. `vcgencmd get_throttled` remained `0x0`, the kernel journal showed
no OOM kill or throttling event, and the exact 900-packet/30-second first segment
showed no dropped recording frame. This was the investigation sanity run, not the
successor's matched room-temperature and thermal-equilibrium soak campaign.

Before each direct campaign the deployed owner hash matched the repository's
`raspi/camera/camera.py`. After each campaign systemd restarted that committed owner,
the throwaway processes were absent, and `/v1/status.recording_readiness.ready`
returned true. The qualifying result selects direct per-segment PyAV for the
successor implementation; only that committed implementation can provide the later
end-to-end latency and durability-campaign evidence.

## 11. Committed transactional PyAV acceptance -- 2026-07-16

The implementation campaign replaced the FFmpeg input and segment muxers with the
transactional PyAV owner selected above. The final deployed revision was `203569f`;
its history includes transactional recording (`61ff5ca`), callback-isolated muxing
(`2dcb164`), synced-prefix attestation (`f34cd75`), recovered-clip floor release
(`a422a5d`), and dormant lifecycle fault injection (`6092ac1`). The Pi still ran
Python 3.13.5, PyAV 14.2.0, Picamera2 0.3.36, and FFmpeg 7.1.5.

### Binding publication latency

An external Mac client measured each complete start POST. The service returns 200
only after accepting `segment_opened`, so the HTTP duration includes request transit,
the durable publication transaction, Rust validation and publication, and response
transit. Cold trials restarted the owner and waited for recording readiness. Warm
trials stopped the first session and started a second session in the same owner.

| Trial | Unloaded cold (ms) | Unloaded warm (ms) | Loaded cold (ms) | Loaded warm (ms) |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 324.104 | 186.143 | 353.189 | 198.078 |
| 2 | 223.850 | 181.245 | 311.365 | 202.484 |
| 3 | 185.940 | 162.365 | 210.931 | 198.718 |
| 4 | 299.608 | 142.518 | 207.344 | 199.415 |
| 5 | 178.281 | 182.504 | 200.441 | 191.629 |

The four medians were 223.850, 181.245, 210.931, and 198.718 ms respectively.
Every trial remained below the binding 1 second gate. The loaded profile kept an
MJPEG preview client, periodic `/v1/clips` listings, and validator-bound ranged clip
reads active. At each of the 20 publication points, the harness copied exactly the
reported 12,784-13,348 durable bytes and independently decoded a complete frame from
that prefix.

### Loaded media and operational smoke

A separate 35-second loaded session returned start success in 233.037 ms and stop
success in 228.311 ms. Its first segment contained exactly 900 packets and reported
30.000 seconds. A second session left the first segment's SHA-256 digest
`4e48b8f6cc32a652ebd8097c2037b30b915def8ad6d3b6f8b74d315a185b070a`
unchanged. All 23 segments created by the final latency and loaded-media campaign
decoded without error. Every segment began at PTS/DTS zero, kept `PTS == DTS`,
increased DTS strictly, and used an exact 3000-tick packet delta.

Over 35.94 seconds, preview delivered 361 frames at 10.016 fps. Median, p95, and
maximum inter-frame intervals were 100.145, 114.923, and 147.302 ms. The 35 resource
samples observed:

- camera-owner RSS at most 108,404 KiB and service RSS at most 8,300 KiB;
- sensor temperature at most 39.0 C and SoC temperature at most 42.0 C;
- zero swap use and at least 184,549,376 available bytes;
- mean normalized total CPU 139.49 percent and maximum 164 percent.

This is a short loaded regression check, not the matched room and warm-equilibrium
soak required by PO7.

Stopping the systemd unit during recording with live SSE and MJPEG clients plus one
unread MJPEG response completed in 2.125 seconds. The unread socket later drained
525,357 buffered bytes and reached EOF. The unit reported `success`, exit status 0,
and inactive/dead; no camera owner remained. The last clip decoded, no hidden
transaction artifact remained, and restart returned recording readiness.

Sixteen concurrent start requests and sixteen concurrent stop requests all returned
200 while applying one lifecycle. Ten more stops were sent only after status exposed
`starting`; every start and stop returned 200 and every trial ended idle with no
current segment.

### Transaction and recovery faults

The deterministic fault selector ran against committed revision `6092ac1`. Initial
open, write, mux, and publication-sync faults returned start 500, left no phantom
clip, and replaced the owner. A second-sync fault after publication recovered and
listed segment 214 with its exact 14,100-byte synced prefix preserved and decodable.
Final-stop close and finalize faults returned stop 500 and recovered segments 215 and
216 with exact 14,288-byte prefixes. Rollover close and finalize faults recovered
segments 217 and 218 after each had reached 900 packets. Every survivor retained its
captured prefix byte-for-byte, decoded, became listable after reconciliation, and
left no hidden artifact. The selector was then removed from the service environment
and the ordinary unit restarted recording-ready.

Separate process-death and storage-failure cases exercised recovery without the
selector:

- killing an owner while segment 200 was uncommitted removed the pending artifact;
  the replacement became ready and allocated segment 201 rather than reusing 200;
- killing an owner with published segment 202 preserved and decoded its exact
  16,168-byte prefix, finalized and listed it, and allowed a replacement owner;
- killing the Rust service during segment 204 preserved and decoded its exact
  15,416-byte prefix; startup reconciled and listed it before readiness;
- making the recording directory unwritable with pending segment 206 blocked
  cleanup and readiness; restoring permissions let the same service reconcile,
  become ready, and allocate segment 207;
- making finalization fail for segment 209 returned stop 500 and blocked readiness;
  restoring permissions immediately reconciled and listed the segment with its exact
  14,664-byte prefix preserved and decodable.

The finalization-failure case found one implementation bug: child error correctly
cleared public current state while preserving the pull floor, but successful
reconciliation did not release that floor, so the recovered clip remained hidden.
Revision `a422a5d` added an explicit post-publication reconciliation transition that
releases the dead owner's exclusions. The real-Pi case then passed without a service
restart.

The local protocol suite additionally proves lost acknowledgement retry,
wrong-session and wrong-sequence rejection, duplicate accepted-event acknowledgement,
deadline retirement, failed-start queued-stop resolution, corrupt reservation
failure, and sequence-ceiling failure. The final suite passed 215 unit tests and 106
integration tests; formatting and Clippy with warnings denied also passed. The PyAV
self-test, provisioning lint, mdBook build, and link checker passed.

### Abrupt power cut: uncommitted state, inconclusive trial

The first PO6 cut froze both the Rust service and camera owner immediately after
segment 269 appeared as a zero-byte uncommitted artifact, then removed power for at
least 10 seconds. The durable witness had already reserved 269. After power was
restored, the board booted, mounted the root and recording filesystems, started the
service, and initialized the camera. The recording transaction itself recovered as
designed: the uncommitted artifact and every hidden transaction path were absent,
the witness remained 269, and a later recording allocated 270, finalized, listed,
and decoded without error.

The trial could not prove the first-boot recovery outcome. On that first post-cut
boot the kernel wrote
the Wi-Fi firmware into the BCM43430 over SDIO, read it back, and found a mismatch at
offset 415,744. `brcmfmac` then reported `dongle image file download failed`, and
the SDIO host reported that `mmc1` never released its inhibit bits. No `wlan0` device
was created; NetworkManager completed startup with loopback only, so Avahi had no LAN
interface on which to advertise `dancam.local`. The service and camera continued
locally, but the Pi remained unreachable until a second power cycle. That second
boot could itself have removed the pending artifact, so the later clean directory
cannot discharge the required first-boot observation.

The second boot loaded the same firmware successfully, created `wlan0`, and regained
its prior `192.168.1.160` lease. The installed `firmware-brcm80211` package verified
without a changed file, and the exact firmware image remained readable. The failed
boot logged no undervoltage, recording-card I/O, or ext4 error; the next boot reported
`get_throttled=0x0`. This was the only firmware-RAM verification failure in the 16
retained boots. The evidence therefore identifies a transient Wi-Fi-chip/SDIO
firmware-transfer failure, not persistent firmware-file or recording-filesystem
corruption, but it does not identify whether power sequencing, the SDIO controller,
or the radio caused that one transfer to fail.

### Controlled power-cut campaign

The repeated campaign added a temporary boot-local observer on the persistent
partition. For the committed-open and uncommitted cuts it captured the target
artifact and witness before the service listened, the first successful status and
clip responses, the transition to recording ready, mount state, and kernel Wi-Fi
signals. Evidence for those recovery-ordering claims therefore did not depend on
mDNS or remote access. Each cut removed power for at least 10 seconds.

The three distinct on-disk states passed:

- **Committed-open:** Segment 273 had completed start publication and both processes
  were frozen with a 6,768-byte `.open.ts` artifact. Its independently decodable
  synced prefix had SHA-256
  `9e4c7d7b0b7733591389412c2d3c7781878ff4e4e7b11186c8bd928c1f49d95c`.
  On the first boot the observer saw committed-open before HTTP. The first clip
  response then listed finalized segment 273 while status was still
  `camera_starting` and recording not ready; readiness followed 8.42 seconds later.
  The recovered clip was exactly the same 6,768 bytes, matched the prefix hash,
  decoded all three packets, retained the exact 3000-tick timeline, and left no
  hidden artifact.
- **Uncommitted:** Segment 274 was durably reserved, both processes were frozen with
  one zero-byte `.pending` artifact, and no committed-open or finalized form existed.
  On the first boot the observer saw pending before HTTP, then saw it absent at the
  first status response and at readiness. It never appeared in either clip listing;
  the witness remained 274. A recovery recording allocated segment 275 rather than
  reusing 274, finalized, listed, and decoded without error.
- **Finalized:** Segment 276 was durably stopped and listed before the cut. Its
  4,368,932 bytes had SHA-256
  `a9d5cf1ca09ffcca843b5ea33a821e9b7d005401f9ec2e2716d91b9cb182184d`
  and decoded in full. The temporary observer unexpectedly left no artifact for this
  cut, so this state has no pre-HTTP ordering evidence. Direct verification on the
  first restored boot found segment 276 listed with exactly the same size and full
  hash, and it decoded after restore. A later recording allocated playable segment
  277 and left segment 276 byte-identical. Finalized footage needs survival evidence,
  not the committed-open recovery-before-readiness ordering proved by segment 273.

All three first boots mounted root, `/persist`, and `/data` normally, preserved the
sequence witness, returned recording readiness, initialized Wi-Fi normally, and left
no hidden transaction artifact. The earlier Wi-Fi firmware-transfer anomaly did not
recur. This campaign discharges PO6 for uncommitted, committed-open including a
previously published current segment, and finalized artifact states.

### Bench resource soaks

Two committed-stack runs recorded continuously for 30 minutes each with resource
samples no more than 10 seconds apart. The unloaded run had no external HTTP
consumers. The supported-load run kept one Mac MJPEG client open while completing
5,088 clip listings and 5,088 validator-bound 256 KiB ranged reads without an error.
Both runs kept the same camera-owner and service PIDs, stayed in recording phase,
reported `get_throttled=0x0` throughout, stopped cleanly, and left no hidden
transaction artifact. The service journal had no OOM, filesystem, recording I/O,
panic, or segmentation-fault signal.

| Measure | Unloaded | Supported load |
| --- | ---: | ---: |
| Samples | 294 | 291 |
| Segments | 61 | 61 |
| First 10 min median combined RSS | 41,888 KiB | 45,956 KiB |
| Last 10 min median combined RSS | 43,694 KiB | 58,440 KiB |
| Median RSS growth | 1,806 KiB (4.31%) | 12,484 KiB (27.17%) |
| Peak camera-owner RSS | 47,700 KiB | 37,028 KiB |
| Peak service RSS | 5,540 KiB | 24,024 KiB |
| Minimum available memory | 192 MiB | 176 MiB |
| First / last 10 min median swap | 32 / 32 MiB | 32 / 32 MiB |
| Peak swap | 32 MiB | 48 MiB |
| Mean normalized total CPU | 55.97% | 76.29% |
| Maximum normalized total CPU | 253% | 175% |
| Maximum SoC / sensor reading | 51 / 50 C | 53 / 49 C |

The loaded service RSS rise was visible rather than described as flat, but its
12.19 MiB first-to-last median delta remained below the 16 MiB absolute drift gate.
Available memory never approached the 128 MiB floor, and swap had no median growth.
The much lower camera RSS in the long samples than the earlier short smoke is
consistent with resident-page reclamation: after a later service restart it began
near 98 MiB again and fell under pressure without an owner restart.

Segments 284-344 and 345-405 were contiguous. In each run, all 60 full segments had
exactly 900 packets, zero-based equal PTS/DTS, and exact 3000-tick deltas; the last
partial segments had 100 and 197 packets respectively. The beginning, middle, and
end segments from each run decoded in full.

Over 30 minutes the loaded Mac preview received 18,104 frames at 10.003 fps. Median
and p95 intervals were 99.953 and 114.012 ms. Its 302.411 ms maximum exceeded 2x the
configured interval but remained below 4x, triggering a focused simultaneous
loopback and Wi-Fi diagnostic rather than being discarded. During that 10-minute
recording workload:

- loopback delivered 6,102 frames at 10.005 fps with 105.172 ms p95, 141.240 ms
  maximum, and zero intervals above 200 ms;
- Wi-Fi delivered 6,103 frames at 10.005 fps with 112.868 ms p95, 187.582 ms maximum,
  and zero intervals above 200 ms while 1,717 more listing and ranged-read pairs all
  succeeded.

The original outlier did not reproduce at either observer and therefore does not
identify persistent mux, service, or link contention. The campaign accepts PO7's
bench resource and operational gates while preserving the outlier in the evidence.
It makes no enclosure or hot-ambient thermal claim.

### Deferred qualification

PO8 accepts the committed provisioning declaration, lint, current-image check mode,
runtime imports, regressions, and documentation without requiring a destructive
fresh-image cycle for this recording-path migration. Two converges from a newly
flashed image remain explicitly unclaimed and move to the next car-image
qualification.

Enclosure and hot-ambient thermal qualification is likewise unclaimed until an
enclosure exists; Icebox swoop `kiln` preserves the matched former-FFmpeg and PyAV
campaign. Neither deferral changes the accepted transactional recording behavior.
