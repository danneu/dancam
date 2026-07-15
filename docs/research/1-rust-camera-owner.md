# Research: Rust camera owner (replacing the Picamera2 subprocess)

- **Date:** 2026-07-15
- **Status:** research notes, no decision taken. The all-Rust camera owner is
  already an Icebox item (`docs/roadmap.md#Icebox`) and the
  [Pi recording design](../design/pi/recording.md) names it a possible response
  if the current child fails its hardware gates. This doc captures the
  investigation of what it buys, what is hard, how much work each hard part is,
  and a concrete scaffolding proposal -- thorough enough to resume the topic cold.
- **Related:** [Pi recording](../design/pi/recording.md),
  [Pi service runtime](../design/pi/service.md)
- **Origin:** started as a question about toggling live preview from the app
  ("can the user turn the preview feed on/off while recording?"), which led to
  tracing the preview pipeline, which led to "what would a Rust rewrite of the
  camera owner buy us?" The preview findings are recorded first because they
  stand alone and one of them (on-demand preview encoder control) becomes cheap
  under a Rust owner.

## 1. Finding: preview is pull-based; a Live Preview toggle is app-side only

Question: can the app expose a "Live Preview" switch on Home that turns the
preview feed on/off while the camera keeps recording?

Answer: yes, and it needs no Pi changes at all.

- The Pi serves preview as an MJPEG HTTP stream
  (`raspi/service/src/preview.rs#fn live_mjpeg`). Frames only cross Wi-Fi while
  a client holds that HTTP connection open. With zero subscribers the fan-out
  watch channel drops frames on the floor and nothing is transmitted.
- Recording is a separate encoder on a separate stream: H264 on `main`
  (1920x1080), MJPEG preview on `lores` (640x480), both configured in
  `raspi/camera/camera.py#class RealCameraDriver`. Opening/closing a preview
  connection never touches the recording path (consistent with the transport
  ADR's "never on the recording path").
- The app already has the machinery: `PreviewFeature` models
  `startTapped`/`stopTapped` actions, a `phase` state
  (idle/connecting/streaming/stopped/failed), and reconnect backoff.
  `HomeViewController` embeds `PreviewViewController` and drives it via
  `onAppear`/`onDisappear`.

Implementation sketch for the toggle (not built as of this writing):

1. Wire the switch to `startTapped`/`stopTapped` (or a dedicated
   `.toggled(Bool)` action).
2. Gate the auto-connect paths (`onAppear`, `reconnectIfNeeded`) on the switch
   state so a user who toggled preview off does not get surprise reconnects.
3. Placeholder or collapse the preview area when off.
4. Optionally persist the preference across launches.

## 2. Finding: the lores encode chain runs even with zero consumers

Traced the full chain; every stage runs unconditionally whether anyone is
watching or not:

1. Sensor + ISP produce the 640x480 lores stream continuously (fixed part of
   the dual-stream video configuration).
2. `camera.py#class RealCameraDriver` starts the MJPEG preview encoder in
   `start()` and never stops it. It encodes at `preview_fps` (default 10);
   `compute_skip` drops the other sensor frames before encode.
3. `camera.py#class StdoutWriter` writes every JPEG to stdout, always
   (frame queue is maxsize=1, drop-oldest).
4. `raspi/service/src/camera/mod.rs#async fn drain_stdout` reads every frame
   and `send_replace`s it into the watch channel, always.
5. Only the last hop (HTTP fan-out) is gated on subscribers.

Cost assessment: near-free in practice.

- picamera2's `MJPEGEncoder` is the hardware encoder (V4L2 M2M on the
  VideoCore block); the software path is `JpegEncoder`, which we do not use.
  The encode barely touches the ARM cores.
- Volume is small: 640x480 JPEG at 10 fps is a few hundred KB/s of
  buffer-shuffling through a pipe. While recording, the H264 encoder is
  simultaneously doing 1080p30 at 10 Mbps -- preview encode is noise next to it.
- The only state where preview encode is the dominant work is
  camera-on-but-not-recording, and even there the baseline (sensor streaming +
  ISP) exists the moment `picam2.start()` is called.

Verdict: do NOT build Pi-side gating under picamera2. True zero-consumer
shutdown would need subscriber-count tracking in Rust plus a
start/stop-preview stdin command plus reconnect latency in the app -- not worth
the moving parts. The Live Preview switch gets the savings that matter (Wi-Fi
bandwidth, phone-side decode) purely client-side. Under a Rust camera owner
this control becomes an ordinary code path (see section 3, win 4), so revisit
then if it ever matters.

## 3. What a Rust camera owner would improve (and what it would not)

Framing constraints from the recording design that still hold:

- Keep the subprocess boundary even after a rewrite: a libcamera crash must
  not take down the control API. The win is replacing the Python child with a
  Rust child, not merging camera code into the service.
- The stdio contract was deliberately shaped so the swap does not touch the
  app or the HTTP routes.
- Image quality does NOT change: AE/AWB/ALSC and the IMX708 tuning live in
  libcamera's IPA layer, which stays regardless. Picamera2 is a convenience
  wrapper, not the image pipeline. Encode quality also unchanged (same
  hardware codec). Wi-Fi unchanged. Thermals barely change (sensor heat
  dominates).

Wins, ranked by value:

1. **Own the recording path end to end (biggest win).** Today the chain is
   Rust service -> Python child -> ffmpeg grandchild, and ffmpeg's segment
   muxer owns rollover. That is why the session-scoped directory watcher
   exists (synthesizes `segment_opened`/`segment_closed`, filters against a
   baseline, cannot emit a final `segment_closed` -- see the recording design's
   2026-06-30 Decision-log entry). A Rust owner ingests H264 NALs straight from
   the V4L2 encoder and does its own muxing: keyframe-aligned segment cuts we control, an explicit
   fsync policy per the recording design instead of whatever ffmpeg
   does, real segment lifecycle events instead of inferred ones, one fewer
   process to supervise. A whole class of watcher complexity gets deleted.
2. **Boot-to-recording latency.** CPython + numpy + picamera2 imports take
   multiple seconds on a Zero 2 W. A dashcam gets power when the car starts;
   every one of those seconds is unrecorded driving, every drive. A static
   Rust binary gets the sensor streaming in tens of milliseconds plus camera
   init.
3. **RAM headroom on the 512 MB board.** The recording design already calls RSS
   "a gate, not an assumption." The Python stack plus ffmpeg plausibly costs
   80-150 MB RSS; a Rust owner passing dmabuf handles costs a few MB. This is
   the difference between never-swaps and maybe-swaps, and swap on SD hurts
   latency and the card.
4. **Dynamic camera control becomes cheap.** Start/stop the lores encoder on
   demand, change preview fps or recording bitrate at runtime, per-request
   controls -- ordinary code paths behind the same stdio protocol instead of
   crossing the Picamera2 event loop. The stdio protocol itself can become
   shared serde types (protocol violations become compile errors).
5. **Smaller, cleaner car image.** No CPython/numpy/picamera2/ffmpeg baked
   into the read-only image as pinned inert files; one binary. Less to pin,
   less to rot, faster boot.
6. **Steadier frame pacing.** No GIL/GC jitter between encoder callback and
   preview pipe; fewer dropped preview frames under load. Modest.

Timing recommendation: the recording design's sequencing is right. Picamera2 is doing its
job as the fast path to validate concurrency on real hardware. Triggers for
building the Rust owner: the read-only car-image pass, the RAM gate failing on
hardware, or boot-to-recording latency proving unacceptable in the car. Do it
as one coherent replacement (camera + encode + mux in the Rust child) rather
than incrementally piping H264 out of the Python child -- "recording bytes stay
inside the camera owner" is a property worth keeping.

## 4. The hard parts: what picamera2 does that we would have to rebuild

Grounded in the pinned clone at `references/picamera2/` (refresh with
`just fetch-references`). The hard parts are the two places picamera2 quietly
does systems-level work between libcamera and the hardware codec -- not the
camera control itself.

### 4.1 V4L2 stateful M2M encoder driver -- the genuinely hard one

`references/picamera2/picamera2/encoders/v4l2_encoder.py` (~330 lines) is a
hand-rolled ioctl wrapper around `/dev/video11` (bcm2835-codec). There is no
mature Rust crate for stateful memory-to-memory encoding with multiplanar
DMABUF import (the `v4l` crate covers cameras/capture). We would rewrite this
in unsafe Rust: `S_FMT` on both queues, DMABUF import on the OUTPUT side,
MMAP buffers on the CAPTURE side, the poll/dequeue/requeue loop, keyframe
flags, forced-keyframe controls.

The kernel driver behind `/dev/video11` is pinned for reading:
`references/linux/drivers/staging/vc04_services/bcm2835-codec/bcm2835-v4l2-codec.c`
(~113 KB, self-contained), alongside the `bcm2835-unicam` CSI-2 receiver under
`references/linux/drivers/media/platform/bcm2835/`. Both are sparse-fetched from
the Raspberry Pi kernel fork at tag `stable_20260609` (commit `c8c74941`), which
is kernel 6.18.34 -- exactly the Pi's running `uname -r` (`6.18.34+rpt-rpi-v8`),
confirmed 2026-07-15 via `just references-pi-version`. This is the authoritative
ioctl contract (formats, controls, buffer semantics) to bindgen against.

The file is short but encodes years of quirk knowledge that we would
otherwise rediscover on hardware:

- `_check_for_picture`: at low bitrates the codec emits buffers containing
  only SPS/PPS and no picture; these must be detected by scanning H264 start
  codes and suppressed or the output corrupts.
- The drain workaround in `thread_poll`: after stopping, the codec sometimes
  never returns the last queued frames. Upstream comment: "I've only ever
  seen this on a Pi Zero" -- exactly our board. They give up after ~400 ms of
  no poll events and drop the queued frames.
- The header-on-first-frame interaction: encoding is skipped until an output
  handle is attached because the H264 header only arrives with the first
  frame.

### 4.2 Zero-copy buffer lifetime across the dual-encoder fan-out

One completed libcamera request feeds two consumers at once: the H264 encoder
DMAs from the `main` buffer while the MJPEG encoder works on `lores`. Each
holds the dmabuf asynchronously until its hardware encode finishes. picamera2
manages this with manual refcounting
(`references/picamera2/picamera2/request.py#class CompletedRequest`,
`acquire`/`release`); the request recycles back to libcamera exactly when the
last consumer releases.

In Rust this is an ownership-design problem the borrow checker cannot model
for us: raw dmabuf fds crossing threads into a kernel queue, buffers owned by
C++ libcamera. Recycle too early and the sensor DMA-writes into a buffer the
encoder is still reading -- silent torn/sheared frames, not a crash. Hold too
long and `buffer_count=4` starves the camera. Failure modes are intermittent,
load-dependent, invisible in logs.

Key design (bought correctness-by-construction): `CompletedRequest` as an
`Arc` whose `Drop` requeues the request to libcamera; the encoder's in-flight
queue holds a clone until DQBUF returns that buffer (mirrors picamera2's
`buf_frame` queue). Done that way, "recycled while an encoder still holds the
dmabuf" is unrepresentable -- which matters because DMA tearing is nearly
impossible to assert on hardware.

### 4.3 Configuration generation

`references/picamera2/picamera2/picamera2.py#def align_stream` and friends
(`check_camera_config`, `_update_stream_config`) encode platform-specific
rules: stride alignment (32 vs 64 by VC4/PiSP platform, doubled/halved for
YUV420's UV planes), colour-space coupling between streams, sensor mode
selection. Wrong choices fail as opaque EINVAL from configure or green-sheared
video from stride mismatch.

Mitigation: we do not need the general generator. dancam has exactly one
config (main 1920x1080 YUV420 + lores 640x480 YUV420, 30 fps, manual focus at
infinity per the recording design). Hardcode it, call libcamera `validate()`, read back the
adjusted strides instead of computing them, fail loudly at startup if
validation adjusted anything unexpected. Failure mode is immediate and
visible, not latent.

### 4.4 libcamera bindings

Source to read is pinned: `references/libcamera/` tracks the Raspberry Pi
**fork** (not upstream linuxtv) at tag `v0.7.1+rpt20260609`, matching the Pi's
installed `libcamera0.7` apt package (`0.7.1+rpt20260609-1`, confirmed
2026-07-15 via `just references-pi-version`). The dancam-relevant trees are
`src/libcamera/pipeline/rpi/{vc4,pisp}` (stream config generation) and
`src/ipa/rpi/` (AE/AWB/tuning we keep). `just fetch-references` seeds it.

libcamera is C++ with no stable API/ABI; the `libcamera` Rust crate lags
upstream with coverage gaps. Completion callbacks arrive on libcamera's
threads and must cross into our loop safely. Expect to pin and possibly
vendor/patch bindings (the `references/` + `scripts/fetch-references.sh`
pinning discipline already fits). The work is an audit, then either days of
glue or weeks of `-sys` forking -- discovery risk, not construction work.

Audit checklist for the bindings spike: camera acquire; dual-stream video
configuration; controls we need (`FrameDurationLimits`, `AfMode`,
`LensPosition`); request completion callbacks that are `Send`-able out of
libcamera's thread; per-plane dmabuf fds; `SensorTimestamp` and
`SensorTemperature` metadata.

### What we do NOT need from picamera2

`picamera2.py` is ~2,800 lines but most is API surface dancam never touches:
preview windows, still capture, autofocus cycles (we run fixed infinity
focus), runtime reconfiguration, the job system. Our pipeline is: configure
once at startup, loop requests forever, fan each out to two encoders. A
purpose-built crate is maybe a fifth of the surface.

## 5. Effort estimates (correctness vs proving)

| # | Part | Code | Testing | Estimate |
|---|------|------|---------|----------|
| 4.1 | M2M encoder wrapper | ~1-2k lines; bindgen the ioctl structs from `videodev2.h` (kills ABI-layout bugs as a category) | Three tiers (see section 6); hardware soak is the long pole | ~1 week code + open-ended hw-validation tail; 2-3 weeks elapsed |
| 4.2 | Request fan-out | 300-500 lines; the design is the deliverable | Almost entirely unit-level with fake consumers: every request recycled exactly once, never early, nasty shutdown orderings; hardware contribution is just the shared soak | A few days. Cheapest despite being conceptually scariest |
| 4.3 | Configuration | Hardcode one config + validate() readback | Startup assertions + one on-Pi golden test pinning validated stride/format values + one-time eyeball of real frames | 1-2 days |
| 4.4 | libcamera bindings | Audit first; glue if coverage is there, vendor+patch if not | FFI glue barely unit-tests; on-Pi smoke suite re-run after every libcamera/OS bump (permanent small maintenance tax) | Days if covered, weeks if forking. Spike the audit first (~1 day) to collapse the variance |

Total ordering: encoder wrapper >> bindings (variance) > fan-out > config.
Riding along, not free: a Rust muxer to replace ffmpeg (its own chunk, with
the recording design's power-cut test burden regardless of who writes it), and
a Rust fake driver replacing `camera.py`'s fake so the mock-Pi track stays
unblocked off-hardware.

Sequencing that falls out: (1) spike the bindings audit (cheapest way to kill
the biggest unknown), (2) build the M2M wrapper standalone against
`/dev/video11` with the trait-mocked unit layer, (3) fan-out design, (4)
config absorbed into bring-up.

## 6. Scaffolding proposal

### Workspace layout

Make `raspi/` a Cargo workspace with three members:

```
raspi/
  Cargo.toml              <- workspace root
  service/                <- existing axum service, unchanged
  protocol/               <- NEW: shared stdio-contract types (serde structs for
                             stdin commands + stderr events), used by both sides
  camera-owner/           <- NEW: the camera crate (bin: dancam-camera)
    Cargo.toml
    build.rs              <- only if regenerating v4l2 bindings
    src/
      main.rs             <- stdio wiring: stdin commands, stderr events, stdout frames
      pipeline.rs         <- request fan-out: CompletedRequest (Arc + Drop = requeue)
      camera/
        mod.rs            <- Camera trait: completed-request stream + controls
        libcamera.rs      <- real impl, behind `feature = "libcamera"`
        fake.rs           <- fake driver: pattern frames, deterministic segment/crash hooks
      encode/
        m2m/
          state.rs        <- stateful M2M queue state machine, generic over VideoDevice
          device.rs       <- VideoDevice trait (ioctl seam) + RealDevice + FakeDevice
          sys.rs          <- checked-in bindgen output from videodev2.h
        h264.rs           <- bitrate/iperiod controls, SPS/PPS-only picture check
        mjpeg.rs
      mux/                <- segmenter + muxer + fsync policy
    tests/                <- tier-1 host tests (fake device, fake camera)
    tests_hw/             <- tier-2/3 tests, compiled always, runtime-gated by env
```

Two load-bearing moves:

- **`protocol` crate:** supervisor and camera owner share the same serde
  types, so the stdio contract cannot drift. The service's existing
  `raspi/service/tests/camera_process.rs` becomes a parity gate run against
  BOTH `camera.py` and `dancam-camera` during the transition; delete the
  Python at cutover.
- **Fake driver moves into `dancam-camera --fake`,** replacing `camera.py`'s
  fake driver, so the mock-Pi track keeps working off-hardware with zero
  service changes.

### The two trait seams that make it testable

- **`VideoDevice` (ioctl seam):** `s_fmt`, `reqbufs`, `qbuf`, `dqbuf`,
  `streamon/streamoff`, `poll`. `RealDevice` is the only unsafe code;
  `FakeDevice` simulates queue semantics including the quirk modes (emit an
  SPS/PPS-only capture buffer; refuse to return the last frames on drain).
  Every piece of ported picamera2 folklore becomes a named deterministic
  regression test instead of a comment.
- **`Camera` (libcamera seam):** yields completed requests (buffers +
  metadata). The fake produces stamped test-pattern frames with controllable
  timing, so the fan-out/pipeline layer is fully host-testable.

Keep the M2M state machine codec-agnostic (H264 vs MJPEG vs FWHT is format
IDs + controls) -- that is what makes tier 2 possible.

### Three test tiers

**Tier 1 -- host (`just raspi-camera-test`), Mac, every commit.**
Plain `cargo test`, default features, no libcamera link. Covers: M2M state
machine vs `FakeDevice` (buffer accounting, drain, quirks); fan-out property
tests (every request recycled exactly once, never early, shutdown orderings:
encoder stops with frames in flight, camera stops while encoder holds
buffers); muxer golden tests (canned NAL stream in, byte-exact segments out);
crash-safety simulation (spawn muxer as a child process, kill -9 mid-write,
re-read and assert every synced fragment survives -- most of the power-cut
confidence, bought on the Mac); protocol round-trips.

**Tier 2 -- Linux VM (`just raspi-camera-test-vm`), on demand.**
The kernel's `vicodec` module is a virtual stateful M2M codec speaking the
same API as `/dev/video11`. Needs a real VM with modprobe (Lima with an
Ubuntu guest on the M1; Docker Desktop will not do):
`apt install linux-modules-extra-$(uname -r)` then
`modprobe vicodec multiplanar=1`. The real `RealDevice` + state machine run
against a real kernel: real ioctl structs, real poll semantics, real DQBUF
edges. vicodec encodes FWHT, not H264 -- which is exactly why the state
machine stays codec-agnostic. Tests self-skip when `DANCAM_VM_TESTS=1` /
the device is absent (no feature-flag matrix). Optional: modprobe `vimc` for
a libcamera-rs binding smoke test.

**Tier 3 -- real Pi (`just raspi-camera-test-pi`), before merging anything
touching the encode path.** Cross-compile test binaries
(`cargo zigbuild --tests`, binary paths from `--message-format=json`), scp,
run over SSH -- same pattern as `raspi/deploy.sh`. Hits real `/dev/video11` and
real libcamera: encode a generated pattern, assert NAL structure and keyframe
cadence with a small Rust H264 parser (do not shell out to ffprobe; the point
is removing ffmpeg), sustained 30 fps, metadata on every request. Plus a
`--soak` flag on the binary: run the full dual-encode pipeline for N minutes,
print RSS/fps/buffer stats, fail on drift (`just raspi-camera-soak`). Real
power-cut testing remains a manual rig; tier-1 kill-9 tests are its cheap
daily proxy.

### Cross-compiling against libcamera (the one new scaffolding problem)

The service is static musl; that is impossible for the camera owner because
libcamera is a C++ shared library. So `camera-owner` targets
`aarch64-unknown-linux-gnu` and links against a sysroot synced from the Pi:

- `just raspi-sysroot` rsyncs `/usr/include`, `/usr/lib/aarch64-linux-gnu`,
  `/lib` into `raspi/sysroot/` (git-ignored, same discipline as
  `references/`).
- zigbuild handles glibc targeting; linker config points at the sysroot.
- Refresh the sysroot whenever the Pi's OS/libcamera bumps -- this doubles as
  the binding-drift alarm (build breaks loudly instead of the camera failing
  quietly).
- Gate all libcamera code behind the `libcamera` feature so Mac-side
  `cargo test` and rust-analyzer never need the sysroot.

### v4l2 bindings hygiene

Do not run bindgen on every build: generate `encode/m2m/sys.rs` from
`videodev2.h` once via a just task and check it in (V4L2 UAPI is stable;
keeps host builds hermetic; matches the repo's pinning culture).

### Order of construction

1. Workspace + `protocol` crate (parity gate live from day one).
2. `encode/m2m/` with `FakeDevice` tests (tier 1).
3. vicodec VM lane (tier 2).
4. Sysroot + `libcamera` feature + bindings glue.
5. On-Pi tests (tier 3), then soak.

Each tier catches its bug class before the next, more expensive tier exists.

## 7. Open questions / next steps

- **Bindings audit spike** (~1 day): read `libcamera-rs` against the checklist
  in section 4.4 on the pinned libcamera version the Pi actually runs. This
  collapses the largest variance in the whole estimate; do it before anything
  else.
- **Muxer format decision** (fMP4 vs continuing MPEG-TS) is not settled here;
  it interacts with the recording design, `ts_duration`, the app's
  progressive-fmp4 playback ADR (`app/docs/design/08-2026-06-27-progressive-fmp4-clip-playback.md`),
  and segment fact stamping. Needs its own design pass.
- **Design record at commit time:** landing the Rust owner must update the
  [recording page](../design/pi/recording.md) body and append the rationale to its
  Decision log. The existing design already requires keeping the process boundary
  across a rewrite.
- **Trigger discipline:** do not start this for its own sake. Triggers per
  section 3: read-only car-image pass, RAM gate failing on hardware, or
  boot-to-recording latency proving unacceptable in the car.
- **Preview toggle** (section 1) is independent and can be built any time as
  a small app-side change.
