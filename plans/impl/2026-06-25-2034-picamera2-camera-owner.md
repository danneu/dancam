# Plan: `jet` -- Picamera2 migration for concurrent preview + recording control

## Context

The `jet` roadmap swoop is "recording control + live status." Its headline risk: can a
low-res MJPEG preview run **concurrently** with 1080p30 H.264 recording on the Pi Zero 2 W,
so the user can always see what the camera sees -- even while recording?

Today's camera backend (`RpicamBackend`) spawns a fresh `rpicam-vid --codec mjpeg` process
**per HTTP preview request**. That cannot deliver concurrent preview-while-recording for two
structural reasons: (1) `rpicam-vid` has a single output and cannot emit a recording stream
and a preview stream at once; (2) libcamera allows only **one** process to own the camera, so
you cannot run a second `rpicam-vid` to record alongside the preview one.

The fix is the architecture we settled on in prior discussion: a **single long-lived camera
owner process** that has the ISP emit two concurrent streams -- a `main` 1080p stream encoded
to H.264 and written to disk as crash-safe `.ts` segments, and a near-free `lores` 640x480
stream JPEG-encoded for preview. Picamera2 is the supported library that can do this; we adopt
it now (Python), behind a deliberately language-agnostic process boundary, so a future all-Rust
camera binary can replace it unchanged (tracked as a later deepening pass / icebox item, not
built here).

This plan delivers the migration end-to-end (Pi camera process + Rust service + iPhone app),
at a **lean** status surface: recording start/stop and concurrent preview. SSE `/v1/events`,
storage/thermal readouts, and `/v1/capabilities` are deliberately deferred to a follow-up.

## Scope

**In scope (this plan):**
- New Picamera2 camera-owner process (`camera.py`): concurrent `main`(H.264 -> `.ts`) + `lores`(MJPEG preview).
- Rust service: long-lived supervised camera child, preview fan-out to N clients, `POST /v1/recording/start|stop` with minimal mutation hardening (Host allowlist + preflight-forcing headers), real `recording` flag on `/v1/health`.
- iPhone app: Record / Stop-Recording control + a recording indicator on the live-preview screen; preview keeps streaming during recording.
- Provisioning + deploy for the Python process; README runbook.
- Docs: new **ADR 07** (Picamera2 camera-owner + the process contract), supersede-note on ADR 05, notes on ADR 02 / ADR 01, roadmap + `raspi/AGENTS.md` updates.
- On-hardware spike validation of concurrent preview-while-recording (the `jet` gate).

**Deferred to a follow-up (out of scope here):**
- SSE `GET /v1/events` (heartbeat + recording/storage/temp events).
- `GET /v1/capabilities` with `preview.concurrent`, and `GET /v1/status`.
- Storage-free and SoC/sensor-temperature monitor.
- The *remainder* of ADR 02's HTTP hardening: `Origin`/`Sec-Fetch-Site` checks, the reserved `Authorization` bearer token, pinned-cert TLS. (The minimal anti-rebinding/CSRF subset the new mutating endpoints require -- Host allowlist + preflight-forcing `Content-Type`/`Idempotency-Key` -- is now **in scope**, see Rust service refactor; this plan ships the first state-changing endpoints, so that subset cannot wait.)
- The all-Rust camera-owner binary (deepening pass / icebox).
- Full crash-safe storage hardening (ring buffer, journaled `/data` partition, read-only root, power-loss validation -- ADR 01/03, swoop `vine`). `jet` only gets the recording **format** right (`.ts`, segmented, inline headers).

## The process contract (the load-bearing black-box boundary)

The camera process is a black box the Rust service supervises over three stdio channels. This
contract is what a future Rust camera binary will reimplement, so it is fixed and explicit:

- **stdout** -- continuous raw MJPEG: complete JPEGs (SOI `FFD8` .. EOI `FFD9`) concatenated, the
  `lores` preview. stdout carries **only** JPEG bytes. The Rust parent always drains it.
- **stdin** -- newline-delimited JSON commands from Rust: `{"cmd":"start_recording"}`,
  `{"cmd":"stop_recording"}`, `{"cmd":"shutdown"}`.
- **stderr** -- newline-delimited JSON events: `{"event":"ready"}`, `{"event":"recording_started"}`,
  `{"event":"recording_stopped"}`, `{"event":"error","detail":"..."}`. Plain-text logs may also go
  to stderr; the parent treats non-JSON lines as logs.
- The process writes `.ts` segments to a configured directory **itself**; the Rust parent never
  handles recording bytes (keeps the heavy path off the service; "SD is the source of truth").

**Central invariant:** the recording encoder/output is fully independent of stdout. If the
parent stalls draining preview, the preview frame is dropped -- recording is never blocked. The
Rust drain loop must read+broadcast unconditionally and must never gate on subscriber count.

## Pi side -- the Picamera2 camera process

New file: `raspi/camera/camera.py` (single self-contained module; mirrors how the Rust binary
lives under `raspi/service/`). Deployed to `/usr/local/lib/dancam/camera.py`.

- **Camera config:** one `Picamera2` instance, `create_video_configuration(main={"size":(1920,1080),"format":"YUV420"}, lores={"size":(640,480),"format":"YUV420"}, controls={"FrameRate":30}, buffer_count=4, queue=False)`. One sensor clock at 30 fps; both streams ride it.
- **Camera + encoder lifecycle (exact API -- `picam2.stop_recording()` is BANNED in the command path):** configure **once** with `create_video_configuration`, then `picam2.start()` **once**; the camera and the lores preview encoder run for the whole process life. Preview starts with `picam2.start_encoder(preview_encoder, PreviewQueueOutput(), name="lores")` and is never stopped until `shutdown`. Recording toggles a *second*, independent encoder via `start_encoder(h264, FfmpegOutput(...), name="main")` / `stop_encoder(h264)` (see below). Do **not** map the `stop_recording` command to `Picamera2.stop_recording()`: that method calls `picam2.stop()` + `stop_encoder()` with no args, tearing down the camera and **all** encoders (picamera2.py:2538) -- it would kill the always-on preview. Only the `shutdown` command stops the camera (`stop_encoder()` all, then `picam2.stop()`). `start_encoder(name=...)` / `stop_encoder(<specific encoder>)` (picamera2.py:2434/2479) are the selective, per-stream calls that make concurrent preview + toggled recording possible. **At startup, before emitting `ready`,** `camera.py` creates `DANCAM_REC_DIR` (`pathlib.Path(rec_dir).mkdir(parents=True, exist_ok=True)`) and **fails fast** -- emit `{"event":"error",...}` and exit non-zero -- if the directory is missing-and-uncreatable or not writable, so a fresh Pi never reaches `start_recording` with no target directory (`deploy.sh` installs only the binary + unit; nothing else creates the dir).
- **Preview fps cap (pre-encode, not via the queue):** a single pure function `compute_skip(sensor_fps, preview_fps) = max(1, math.ceil(sensor_fps / preview_fps))` -- **shared by the real and `--fake` drivers** and pinned by a deterministic `--self-test` (see Verification), so the load-bearing formula is verified by exact assertion, not a flaky wall-clock measurement -- sets the preview JPEG encoder's `frame_skip_count`; it emits 1 of every N frames, so emitted fps = `sensor_fps / N`, always **<= the requested cap**. E.g. a 30 fps sensor at `--preview-fps 10` -> `3` -> exactly 10 fps; at the non-divisor `--preview-fps 12` -> `ceil(2.5) == 3` -> 10 fps (staying under the cap; plain `round()` would give `2` -> 15 fps, *over* the cap). `ceil` + `max(1, ...)` also guards `--preview-fps >= sensor_fps`, which would otherwise floor/round to `0` and break the `% frame_skip_count` modulo (default `frame_skip_count` is `1` = encode every frame). `camera.py` rejects a non-positive `--preview-fps` at startup (emit `error`, exit non-zero). (Picamera2's pre-encode gate, encoder.py:266-271.) This caps preview at ADR 02's ~10 fps budget **before** JPEG encoding, so the software-`JpegEncoder` fallback only encodes the frames it emits (the thermal win). It must **not** rely on the stdout queue to throttle: the Rust parent drains stdout unconditionally, so the queue rarely fills and an un-gated encoder would happily emit ~30 fps -- blowing the preview budget and tripling the software-JPEG heat.
- **Preview (always-on, torn-frame-safe):** the lores JPEG encoder feeds a `PreviewQueueOutput` (subclass of `Output`) whose `outputframe` **enqueues** each complete (already fps-gated) JPEG into a bounded queue (`maxsize=1`) and **drops** the frame (never blocks) when full -- this is purely **backpressure protection** for a momentarily slow pipe, not the fps cap. A dedicated **stdout writer thread** pops frames and does a **blocking, whole-frame** `sys.stdout.buffer.write(jpeg)` + `flush()`. This is deliberate: a non-blocking fd `write()` can *short-write* a large JPEG, splicing a half-frame into the byte stream and corrupting every following frame -- so JPEGs are never written straight to a non-blocking fd 1. The blocking writer can never tear a frame; the encoder/camera threads never block on it (they only enqueue-or-drop); recording rides a separate `FfmpegOutput` and is wholly unaffected by a slow pipe. `BrokenPipeError` in the writer thread -> request `shutdown`.
  - **Encoder choice (spike-decided, one-line swap):** start with hardware `MJPEGEncoder` (the separate VideoCore JPEG block, not the H.264 session -- preview cost ~free; hardware MJPEG needs the VC4 platform, which the Zero 2 W is -- a Pi 5 / PISP would not be). If the on-hardware spike shows preview choppiness like the **same-hardware user anecdote in picamera2 issue #1085** (a closed how-to thread -- an unconfirmed aside, *to be settled by the spike*, not an established `bcm2835-codec` defect), flip the single line to software `JpegEncoder` (compresses via `simplejpeg`, a libjpeg-turbo wrapper; multithreaded, <15% of one core at VGA@10fps). stdout bytes are identical either way.
- **Recording (toggled):** the `start_recording` command adds an independent `H264Encoder(bitrate=10_000_000, repeat=True, iperiod=30)` on `main` via `start_encoder(h264, FfmpegOutput(...), name="main")`; the `stop_recording` command removes just that encoder via `stop_encoder(h264)` (flushes/closes the current `.ts`; preview keeps running). `repeat=True` gives inline SPS/PPS at every IDR (ADR 01's `--inline`); `iperiod=30` is in **frames**, so at 30 fps it is a 1 s GOP (a keyframe every second), **not** one keyframe per 30 s segment -- and the frequent keyframes are deliberate: they give truncation tolerance and let ffmpeg's `-segment_time` split cleanly, since the segment muxer cuts on keyframe boundaries (so each ~30 s segment still opens on an IDR). Do **not** "correct" this to `iperiod=900`: that would coarsen the split points and worsen truncation tolerance. No re-encode (stream-copy mux -- `FfmpegOutput` hardcodes `-c:v copy`, ffmpegoutput.py:77).
  - **Segment numbering must not overwrite prior footage.** `FfmpegOutput` launches ffmpeg with `-y` (overwrite-without-asking, ffmpegoutput.py:68) and ffmpeg's segment muxer restarts its counter at `0` unless told otherwise -- so a second `start_recording` after a stop/restart would re-open `seg_00000.ts` and destroy source-of-truth footage. Before each `FfmpegOutput` launch, scan `DANCAM_REC_DIR` for the highest existing `seg_NNNNN.ts` and pass `-segment_start_number <highest+1>` in the ffmpeg options: `-f segment -segment_time 30 -segment_format mpegts -reset_timestamps 1 -segment_start_number <next> .../seg_%05d.ts` (`audio=False`). These are all **output/muxer** options carried in `FfmpegOutput`'s `output_filename` string (ffmpegoutput.py:94) -- the only injectable surface, since `FfmpegOutput` fixes the input args and `-c:v copy` -- so the segment options take effect, but input-side options could not be injected this way (no attempt to do so). Counter naming (`seg_%05d.ts`, monotonically **continued** across sessions) is the v1 scheme -- the Pi has no RTC; wall-clock naming and ring-buffer reclamation are ADR 03's job.
  - Fallback if runtime encoder add/remove proves flaky on Trixie's Picamera2: keep H264 attached for the session and swap its `Output` null<->Ffmpeg (wastes encode/heat while "stopped"; spike can validate the primary path first). The same `-segment_start_number` continuation applies on every Ffmpeg (re)attach.
- **Async structure:** Picamera2 supplies the camera thread + per-encoder output threads. We add a **stdin reader** (blocking `readline()` in a thread -> command queue), a **stdout writer thread** (drains the bounded preview queue with blocking whole-frame writes, above), and the main thread dispatches commands + emits stderr events under one lock. stdout is JPEG-only; one JSON object per stderr line, flushed.
- **Events emitted (lean set):** `ready` (after configure + camera start + preview confirmed), `recording_started`, `recording_stopped`, `error`. (`segment_closed`, sensor-temp `stats` deferred with the temp surface.)
- **Pi-only (real driver) -- with a hardware-free `--fake` mode for tests:** Picamera2 cannot run on the Mac dev host, so the real camera path runs only on a real-Pi `DANCAM_BACKEND=camera` deploy; Mac dev keeps `MockBackend`. **But** Picamera2 is **lazy-imported only inside the real driver**, and `camera.py --fake` selects a `FakeCameraDriver` that generates canned JPEGs at the **sensor** rate (default 30 fps, `--fake-sensor-fps`) and runs them through the **same `compute_skip` gate** as the real driver -- so the fake actually exercises the `frame_skip_count` cap (emitting sensor/N), instead of pre-capping at `--preview-fps` and never running the gate. Recording is a no-op that still creates/continues `seg_%05d.ts` placeholder files via the same start-number logic. `--fake` runs hardware-free on the Mac and is what the Rust contract test drives (see Verification), so the load-bearing stdio contract -- command parsing, event names, stdout JPEG purity, the writer-thread queue, start/stop idempotence, no-overwrite numbering -- is covered by automated tests, not just manual on-Pi runs.

## Pi side -- Rust service refactor

The service moves from "spawn a camera process per preview request" to "supervise one long-lived
camera child and fan its preview out to N HTTP clients." Files under `raspi/service/src/`.

- **`backend.rs` -- widen the `Backend` trait** (the only seam the HTTP layer knows; `AppState`
  keeps `backend: Arc<dyn Backend>` unchanged in shape):
  - Delete `recording() -> bool`.
  - `fn preview_frames(&self) -> FrameStream` -- now **subscribes to the running fan-out** instead of spawning.
  - `async fn start_recording(&self) -> Result<(), BackendError>` and `async fn stop_recording(...)`.
  - `fn status(&self) -> Status` -- cheap snapshot clone.
  - Add `async-trait = "0.1"` (small, standard) for the dyn-used async methods; `status()`/`preview_frames()` stay sync.
  - `enum BackendError { CameraOffline, Timeout, Channel }` with `impl IntoResponse` (503/504/500), hand-rolled (no `thiserror`).
- **`status.rs` (new):** `struct Status { recording: bool, camera_state: CameraState }` and
  `enum CameraState { Starting, Running, Restarting, Offline }` (serde-derived). Lean: no
  storage/temps fields yet. A separate `#[derive(Deserialize)] enum ChildEvent` parses the
  child's stderr (`ready`, `recording_started`, `recording_stopped`, `error`) -- kept distinct
  from any outbound vocabulary so the wire-in contract evolves independently.
- **`camera/mod.rs` (new) -- the supervisor:**
  - `CameraProcess::spawn(cfg) -> (CameraHandle, SupervisorControl)`, spawned once in `main` when `DANCAM_BACKEND=camera`.
  - `CameraHandle { frames_tx: broadcast::Sender<Bytes>, status_rx: watch::Receiver<Status>, commands_tx: mpsc::Sender<Command> }`, wrapped by `CameraBackend` (impl `Backend`).
  - Per child generation: spawn the Python child (`kill_on_drop(true)`, stdin/stdout/stderr piped), a **drain_stdout** task (fresh `JpegSplitter` per child -- reuse `src/jpeg.rs` unchanged -- read -> `frames_tx.send`, ignore "no receivers" error), a **parse_stderr** task (`BufReader.lines()` -> `ChildEvent` -> status patch; non-JSON -> `tracing` log), and the supervisor holding stdin.
  - `tokio::select!` on `commands_rx` (write `{"cmd":...}\n` + flush to stdin) vs `child.wait()` (unexpected exit -> publish `Restarting`, backoff, restart) vs shutdown (write `{"cmd":"shutdown"}`, `wait` with timeout, else `kill`).
  - **Backoff:** 250ms base, x2, cap 10s, reset after a healthy run (>30s). Status while down: `camera_state=Restarting`, `recording=false`; `start_recording` returns `CameraOffline` (503). No auto-resume of recording in `jet` (surface offline; app re-issues start).
  - **Preview fan-out = `broadcast<Bytes>`** (not `watch`): per-client cursors give every healthy client every frame in order; a slow phone gets `Lagged` and we `filter_map(.ok())` to skip -- producer never blocks. Capacity ~8 frames. `Bytes` clones are refcount bumps. Zero clients: `send` errors are ignored, frames dropped, child never backpressured.
  - **start/stop are transition-confirmed:** subscribe to `status_rx` **before** sending the command, await the child's `recording_started`/`recording_stopped` status transition with a ~3s timeout (-> `Timeout`/504). Idempotent for free (already-recording satisfies the predicate immediately) -- matches ADR 02.
- **Endpoints (`lib.rs` routes; both backends implement them):**
  - `POST /v1/recording/start`, `POST /v1/recording/stop` (new `recording.rs` handlers; `start_recording().await?` -> 200; reject the request without `Content-Type: application/json` + a non-empty `Idempotency-Key` -- see mutation hardening below).
  - `GET /v1/health` (`health.rs`): `recording` now reads `state.backend.status().recording`.
  - Preview handler (`preview.rs`) unchanged -- it already maps a `FrameStream` to `multipart/x-mixed-replace`.
- **Minimal mutation hardening (required: this plan adds the first *mutating* endpoints).** ADR 02 (Auth/trust, lines 351-365) requires browser-origin defenses on every mutating endpoint; until now the API was GET-only (health, preview) with no state to change, so none shipped. `POST /v1/recording/*` are the first state-changers, so the minimal subset lands **here**, not in the deferred follow-up:
  - A `host_allowlist` middleware (sibling of the existing `proto_headers` layer in `lib.rs`, applied to the whole router) **parses and normalizes** the `Host` header into host + optional port (strip an IPv6 bracket, split off `:port`), then rejects with `421 Misdirected Request` unless the host is allowlisted **and**, when a port is present, it equals the configured service port (`8080`); a bare host with no port is also accepted. A **missing** `Host` header also rejects `421` (the secure default -- every real HTTP/1.1 client always sends one: the app's `HTTPRequestEncoder`, `curl`, the browser; only the in-process `tower::oneshot` tests omit it, so **commit #2 updates the existing host-less integration tests** (`health.rs`, `preview.rs`) to send an allowlisted `Host`, keeping the "each commit compiles + tests green" guarantee). The allowlist is the AP gateway (`10.42.0.1`), the mDNS name (`dancam.local`), and **always loopback** (`127.0.0.1`/`localhost`): the **Pi** allowlist is a deliberate **superset** of ADR 02's `{gateway, mDNS}` that always includes loopback, so `deploy.sh`'s health check `curl http://localhost:8080/v1/health` (deploy.sh:49) and ad-hoc on-Pi curl debugging are never `421`'d -- and loopback is safe to allow because it is **not** a DNS-rebinding vector (a remote page cannot make the victim's browser send `Host: localhost`). This normalization is load-bearing: the app's `HTTPRequestEncoder` emits `Host: 10.42.0.1:8080` (it appends the port whenever it isn't the scheme default, HTTPRequestEncoder.swift:56-60) and the deploy check sends `Host: localhost:8080`, so a raw bare-string compare would `421` all real app/curl/deploy traffic. This is ADR 02's primary anti-DNS-rebinding defense -- cheap, global, and it also covers the existing GET routes. Allowlist hosts + service port come from config/env: the mock and the Pi both allow loopback; the Pi adds the gateway + mDNS name.
  - The two `POST /v1/recording/*` handlers require `Content-Type: application/json` **and** a non-empty `Idempotency-Key` header; reject otherwise (`415` / `400`). Both are CORS-preflight-forcing headers a cross-origin browser page cannot send. We require the *header* for that preflight-forcing property only; full idempotency-key replay/dedup **storage is not built here** -- start/stop are already idempotent via the transition-confirmed design.
  - Still deferred: `Origin`/`Sec-Fetch-Site` refinements, the reserved `Authorization` token, pinned-cert TLS. (Never emitting `Access-Control-Allow-*` is already the default -- we add no CORS headers.)
- **`main.rs`:** `camera` arm spawns the supervisor and keeps `SupervisorControl` for graceful
  shutdown (stop `axum::serve` first, then signal + `wait`/`kill` the child). Remove `RpicamBackend`.
- **`MockBackend`:** implement the widened trait -- hold a `watch<Status>` + the existing 100ms JPEG
  cycler over a `broadcast`, flip recording state on start/stop. Keeps the app's mock track fully
  exercisable on the Mac (start/stop + indicator + preview) with no hardware.
- **`Cargo.toml`:** add `async-trait`; move `serde_json` to `[dependencies]`; `tokio-stream` `features=["sync"]` for `BroadcastStream`.

Reused unchanged: `JpegSplitter` (`src/jpeg.rs`), the preview multipart handler (`src/preview.rs`),
the `StubBackend`/`oneshot` test pattern.

## Provisioning + deploy

- **apt (README runbook, real Pi, over home Wi-Fi):** `sudo apt install -y --no-install-recommends python3-picamera2 ffmpeg`. `python3-picamera2` is the supported (apt, not pip) install -- pulls libcamera, `python3-libcamera`, numpy, `python3-simplejpeg`. `--no-install-recommends` skips the desktop GUI stack. Verify: `python3 -c "from picamera2 import Picamera2; print('ok')"` (IMX708 overlay from README section 4 must already be enabled).
- **`raspi/deploy.sh`:** alongside the existing binary + unit rsync, `rsync raspi/camera/camera.py "$HOST:/tmp/dancam-camera.py"`, then in the install block `sudo install -d /usr/local/lib/dancam` and `sudo install -m 0755 /tmp/dancam-camera.py /usr/local/lib/dancam/camera.py`. (apt install stays in the README, not deploy.sh -- deploy is the fast artifact loop.)
- **`raspi/dancam.service`:** add `Environment=DANCAM_REC_DIR=/home/dan/rec` (dev image; car image later points at the journaled `/data/rec`). `User=dan` is already in the `video` group -- no unit permission change. `camera.py` creates `DANCAM_REC_DIR` itself at startup (`parents=True, exist_ok=True`), so neither the unit nor `deploy.sh` needs a `mkdir`/`StateDirectory`. The Rust service spawns `python3 /usr/local/lib/dancam/camera.py --rec-dir "$DANCAM_REC_DIR" --preview-fps 10` (script path + args from `CameraConfig::from_env()`).
- **`README.md`:** new step after section 4 ("Install the camera process dependencies": apt line + verify); section 8 notes deploy now ships `camera.py`, that `DANCAM_BACKEND=camera` spawns it as the single libcamera owner (replacing the old `rpicam-vid` preview path), and `DANCAM_REC_DIR`; plus the standalone smoke-test/spike harness. Note Picamera2 is Pi-only. **Also document the systemd-context device check:** the spike runs standalone as the interactive `dan`, but the deployed path is `User=dan` under systemd with **no login session**, where device/group access can differ. Verify `dan`'s groups cover **both** `/dev/video11` (bcm2835-codec, used by hardware `MJPEGEncoder`) and `/dev/dma_heap/*` (libcamera buffers), and confirm the camera opens **when spawned by the unit** -- i.e. the deployed service emits `ready` in `journalctl -u dancam` after `DANCAM_BACKEND=camera` -- not only over an interactive SSH shell.

## App side -- recording control on the live-preview screen

The recording control lives on the **viewfinder** (`PreviewViewController`) so the migration's
payoff -- preview that keeps streaming while recording -- is demonstrated on one screen. Pattern
mirrors the existing `HealthFeature`/`PreviewFeature` TEA slices exactly.

- **New `RecordingClient`** (`app/.../Networking/RecordingClient.swift`): `start`/`stop` issuing
  `POST /v1/recording/start|stop`. It mirrors `HealthClient`'s structure -- a
  `live(baseURL:pinning:openByteStream:)` seam over `NWByteStream.open(..., pinning:)` -- but
  routes through a **new `HTTPRequestResponse.post(url:body:extraHeaders:openByteStream:)`** that
  mirrors today's `HTTPRequestResponse.get` (which `HealthClient` uses): it injects
  `Connection: close` and runs the **same** head-parse / body-decode round-trip loop, so the POST
  response gets definite framing exactly the way GET does (without `Connection: close` the read
  would depend on the server always emitting a definite `Content-Length`). Same `InterfacePinning`
  handling (Wi-Fi-pinned for the real Pi, disabled for localhost mock).
- **`HTTPRequestEncoder.post(url:body:extraHeaders:)`** mirrors `get()`'s hand-built wire format
  (request line, `Host`, headers, blank line) but **appends the body** and **emits an explicit
  `Content-Length: body.count`** -- since `NWByteStream` writes raw HTTP bytes over a bare
  `NWConnection` (NWByteStream.swift:34), an HTTP/1.1 request with a body but no `Content-Length`
  is framed as zero-length and the body bytes dangle in the connection. Each POST carries
  `Content-Type: application/json`, the JSON body (`{}`, 2 bytes) with its `Content-Length: 2`, the
  gateway `Host` (already set by the pinned base URL), and an `Idempotency-Key` from an
  **injectable provider** (`makeIdempotencyKey: @Sendable () -> String`, defaulting to
  `UUID().uuidString` in `.live`) -- the seam exists so the wire-format test can supply a **fixed**
  key and assert **exact** bytes (a fresh random UUID would make an exact-bytes assertion
  impossible). This satisfies the Pi's mutation hardening above. (`post()`'s `extraHeaders` is the
  seam for `Content-Type`/`Idempotency-Key`.)
- **New `RecordingFeature`** (`app/.../Features/Recording/RecordingFeature.swift`): TEA reducer.
  - `State: { unknown, idle, starting, recording, stopping, failed(String) }`.
  - `Action: { onAppear, startTapped, stopTapped, recordingResponse(Result<...>), healthResponse(Result<HealthResponse,...>) }`.
  - `onAppear` seeds state from `HealthClient.fetch().recording` (lean: no SSE -- seed on appear and refresh after each action). `startTapped`/`stopTapped` call `RecordingClient`, then confirm via the response and a health refresh.
- **`AppDependencies`:** add `var recording: RecordingClient`, initialized in both `init`s (live + the explicit-deps test init) from `AppConfiguration`.
- **`PreviewViewController`:** add a Record / Stop-Recording button and a "REC" indicator (red dot) overlaid on the preview; host a second `Store` for `RecordingFeature` (the VC already coordinates preview state; HealthVC already shows a passive "Recording: yes/no" label from health, which now reflects reality). The live `PreviewClient` stream is untouched and keeps rendering during recording -- `PreviewDecodeState.beginNewStream()` already handles restarts.
- **App UX depends on the spike passing:** always-on preview-during-recording is correct only if the on-hardware spike confirms concurrency. If it fails, the follow-up adds `/v1/capabilities.preview.concurrent` + an app fallback (pause preview while recording). Flagged as the one cross-cutting risk.

Files to create: `RecordingClient.swift`, `RecordingFeature.swift`, and their test files. Modify:
`HTTPRequestEncoder.swift` (add `post`), `HTTPRequestResponse.swift` (add a `post` round-trip
helper mirroring `get`, with `Connection: close`), `AppDependencies.swift`, `PreviewViewController.swift`.

## Docs (land with the pivot, not trailing it)

- **New `raspi/docs/design/07-2026-06-25-picamera2-camera-owner.md`** (next free seq = 07; `just adr-check` after): Accepted. Decision = single libcamera-owner Picamera2 **subprocess** emitting concurrent `main`(H.264 `.ts`) + `lores`(MJPEG), supervised by the Rust service over the stdout/stdin/stderr contract above; records the future all-Rust camera binary as the deepening-pass end state and **why it stays a supervised subprocess** (fault isolation: a camera-stack crash must not take down the control API). Alternatives: rpicam-vid (can't dual-stream / one-owner), in-process libcamera FFI (loses crash isolation).
  - **Consequences must reconcile ADR 05's explicit rejection of Python+Picamera2.** ADR 05 (Alternatives) rejected Python *as the service language* for read-only root + higher RAM/GC on 512 MB, and foresaw Picamera2 **only as a throwaway bring-up tool** -- the camera was to be consumed as `rpicam-vid`, a binary already on the OS, precisely to keep the Python camera ecosystem out of the image. ADR 07 ships CPython+picamera2+numpy as the *production camera subprocess*, so its Consequences must name the tension it reopens: (a) the **read-only-root** cost -- on the car image (swoop `vine`) the whole Python stack must be baked in as inert files, not pip-installed at runtime; (b) the **RAM** cost of that stack on a 512 MB board during concurrent encode (quantified by the spike's memory measurement); and (c) the resulting **car-image ordering constraint** -- either the all-Rust camera binary lands before the read-only car image, or the Python stack is deliberately baked in. ADR 05's *service language* (Rust) and *subprocess boundary* still stand; only the subprocess's contents change (`rpicam-vid` -> Python+Picamera2 -> future Rust). Recording this now (per the project's "write the pivot down in the same change" rule) keeps it from being rediscovered at `vine`.
- **ADR 05** (`05-...-service-language-rust.md`): append a dated note marking the "camera via `rpicam-vid` subprocess" specifics **partly superseded by ADR 07** -- the subprocess boundary (ADR 05's actual decision) stands; only the subprocess binary changes (`rpicam-vid` -> Picamera2 -> future Rust). Append-only.
- **ADR 02** (`02-...-app-pi-transport-and-api.md`): append a dated note resolving **spike 1** -- concurrent preview-while-recording adopted via the dual-stream owner; the `preview.concurrent` capability flag + `/v1/events` + `/v1/status` remain for the deferred follow-up; record the hardware-spike result here once measured. Also note that the Auth/trust section's **minimal mutation hardening** (Host allowlist + preflight-forcing `Content-Type`/`Idempotency-Key`) is now implemented for the new `POST /v1/recording/*`, with `Origin`/`Sec-Fetch` checks, the bearer token, and TLS still deferred.
- **ADR 01** (`01-...-crash-safe-recording.md`): append a dated note -- recording now produced by Picamera2 `H264Encoder` + `FfmpegOutput` segment muxer; the `.ts`/segment/inline-header **format decision is unchanged** (implementation is orthogonal to format).
- **`raspi/AGENTS.md`:** update the "Capture/encode" bullet (`rpicam-vid` -> Picamera2 single-owner subprocess); note the new env (`DANCAM_REC_DIR`).
- **`docs/roadmap.md`:** annotate `jet` (lean enabler: recording control + concurrent preview shipped; SSE `/v1/events`, storage/temps, `/v1/capabilities` deferred to a follow-up); add the all-Rust camera-owner binary under "Later / deepening passes."

## On-hardware spike -- the `jet` gate

Run on a real Zero 2 W + IMX708 (recently available per the `fox` validation). Standalone via
the smoke harness, not through the service.

- **Setup:** start `camera.py --rec-dir /home/dan/rec --preview-fps 10` with stdin from a fifo,
  stdout to a byte/JPEG counter (`/dev/null` + count SOI markers), stderr to a log; run **two**
  `start_recording` / soak / `stop_recording` cycles (to exercise segment-number continuation),
  then `shutdown`.
- **Measure:** every `.ts` plays clean (`ffmpeg -v error -i seg.ts -f null -`); frames/segment ~= 30 x segment_time (`ffprobe -count_frames`); **the second cycle's segments continue the counter and overwrite none of the first cycle's** (second session's first segment index `>` first session's last); all 4 cores (`mpstat -P ALL 2`); **memory headroom** (`free -m`, the camera process's RSS, and swap-in activity under sustained record+preview -- the single biggest delta from the validated `fox` `rpicam-vid` path is adding a CPython+numpy+picamera2 process to a 512 MB board, so an OOM-kill or SD-card swap thrashing that also degrades record-write throughput is a real failure mode the gate must not pass over); SoC temp (`vcgencmd measure_temp`); sensor temp vs the 50 C limit (libcamera `SensorTemperature` metadata -- only the owner can read it; surface it on stderr for this test); delivered preview fps/smoothness.
- **Duration:** >=30 min room-temp for integrity/CPU/fps; a longer warm soak for the thermal verdict (the cabin, not the desk, is the real environment).
- **PASS:** every segment clean at ~30 fps, no significant drops/PTS gaps; preview holds ~10 fps; cores keep headroom; **comfortable free RAM with no sustained swap-in** (swap thrashing or an OOM-kill is a FAIL even if CPU/temps look fine); SoC < ~70 C and sensor < ~50 C at target ambient -> ship hardware `MJPEGEncoder`.
- **FAIL A (preview choppy, recording clean):** flip the one line to software `JpegEncoder`, re-run; if it passes, ship that.
- **FAIL B (software JPEG also drops record frames / overheats):** concurrency untenable -> the follow-up advertises `preview.concurrent=false` and falls back to preview-only-when-stopped (ADR 02 allows it; still covers parked positioning/night aiming).

## Validation log

### 2026-06-25 desk soak: simulator preview + real Pi recording

Result: **pass for the desk/service-level `jet` gate**. The simulator app was on
Live Preview against the real Pi while recording was active. The agent polled the Pi
for roughly 30 minutes, then stopped recording through `POST /v1/recording/stop`
and validated the files.

- Window: about `20:41:36` to `21:11:36` Pi local time.
- Health: `/v1/health.recording` stayed `true` during the soak and returned `false`
  after the stop call.
- Segment output: recording wrote `seg_00003.ts` through `seg_00067.ts`; numbering
  continued from earlier test clips and did not reset or overwrite.
- `ffprobe`: 65 soak segments passed. `seg_00003.ts` through `seg_00066.ts`
  reported `30.000000` seconds; `seg_00067.ts` reported `2.366667` seconds, the
  expected short final segment after stop.
- `ffmpeg -v error -i <segment> -c copy -f null -`: 65 segments checked, `NOISY 0`.
- Logs: `journalctl -u dancam` for the soak window had no warning-priority entries
  and no `timestamp`, `error`, `warn`, `failed`, `oom`, `kill`, or `corrupt` hits.
- SoC temperature: sampled range was roughly `49.9 C` to `55.8 C`; after stop it
  dropped back to `51.5 C`.
- Memory: available memory stayed roughly `171-180 MB` during the run. Swap stayed
  around `79-80 MB`; sampled `vmstat` windows showed no active swap churn.
- Processes: `python3 camera.py` held around `27 MB` RSS early and about `27-28 MB`
  during recording samples; `ffmpeg` was about `47 MB` RSS while recording.

Caveats before closing the full hardware gate:

- This was a desk soak, not a warm-cabin soak.
- The app path was the iOS simulator against the real Pi, not a physical iPhone on
  the `dancam-dev` AP.
- Sensor temperature was not surfaced yet; only SoC temperature was measured.
- Preview smoothness was visually implied by the app staying on preview, but the
  run did not record a delivered preview fps counter.

## Verification

Each item is tagged **[agent]** (the implementing agent runs it, no hardware / no eyes-on)
or **[Dan]** (a human-checkpoint handoff -- see "Human checkpoints" below).

- **[agent] Rust (`just raspi-test`):** `Status`/`ChildEvent` serde; supervisor start/stop round-trip + restart/backoff.
  - **`camera.py --fake` contract test (no hardware) -- closes the no-hardware-contract-test gap by testing the *real* Python child, not just the supervisor.** An integration test spawns `python3 <camera.py> --fake` (selected via `DANCAM_CAMERA_CMD` so the supervisor points at it) and drives the actual stdio contract: points `--rec-dir` at a **missing** temp directory and asserts `camera.py` **creates** it at startup (F3); asserts the `ready` event fires; `start_recording`/`stop_recording` yield `recording_started`/`recording_stopped`; **duplicate** start and duplicate stop are idempotent (no `error`, state stable); `shutdown` exits cleanly; stdout yields only complete JPEGs (SOI/EOI, nothing non-JPEG interleaved); the emitted stdout frame rate respects the configured cap as a **loose sanity bound** (well under the 30 fps source -- not an exact equality, since wall-clock fps is timing-sensitive); the **exact** cap mapping is pinned separately and deterministically by `python3 <camera.py> --self-test`, which the harness invokes and asserts exits `0` -- it checks `compute_skip` on the edge cases (`(30, 12) -> 3`; `(30, 10) -> 3`; a divisor `(30, 15) -> 2`; and `preview_fps >= sensor_fps -> 1`), so the load-bearing formula is verified by exact assertion, not a flaky measurement; and across **two** start/stop cycles the fake's `seg_*.ts` files are **not overwritten** (numbering continues). The test **skips** (does not fail) if `python3` is unavailable, so non-Mac CI stays green; on Dan's Mac it runs every `just raspi-test`. The same `--fake` child (with a `--fake-crash-after <n>` knob) backs the supervisor restart/backoff test, so one fake serves both -- no separate Rust fake binary needed.
  - Endpoint/route tests stay against `MockBackend` via `tower::ServiceExt::oneshot`; add tests that `POST /v1/recording/*` **without** `Content-Type: application/json` + `Idempotency-Key` is rejected (`415`/`400`). For the host allowlist, assert the **allow path** -- `Host: 10.42.0.1:8080`, `dancam.local:8080`, `localhost:8080`, and a bare `10.42.0.1` all pass -- and the **reject path** -- a disallowed host, and an allowlisted host on the **wrong port** (e.g. `10.42.0.1:9999`), both get `421`. Update `StubBackend`/`MockBackend` to the widened trait. Behavioral assertions: POST start -> command reaches child -> `status().recording == true`; multiple preview subscribers each receive frames while recording. **Drain-invariant regression test (the plan's self-described single most important line):** drive the `--fake` child through the supervisor with **zero** preview subscribers and assert `start_recording` still confirms and the fake's `seg_*.ts` still appear/grow; then repeat with a deliberately **stalled** subscriber attached (subscribed but never polled, so it `Lagged`s) and assert recording still confirms and segments still grow -- proving `drain_stdout` never gates on subscriber count and a slow client cannot wedge the producer. This test fails if anyone "optimizes" the drain to skip when there are no receivers.
- **[agent] App (`just app-test`, Swift Testing):** `RecordingClient` builds the correct `POST` and decodes the response (mirror `HealthClientTests`), with an **exact wire-format assertion** on the emitted bytes -- request line, `Host`, `Content-Type: application/json`, a **fixed `Idempotency-Key`** (supplied via the injected `makeIdempotencyKey` seam so the bytes are deterministic), `Content-Length: 2`, blank line, then the `{}` body -- so a body-framing or header regression is caught; `RecordingFeature` reducer via `TestStore` (`startTapped` -> `.starting` -> `recordingResponse(.success)` -> `.recording`, and failure path). No app changes to the preview decode path, so its existing tests still pass.
- **[Dan] Mock end-to-end (Mac):** `just raspi-run` (mock) + app scheme `DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080`; tap Record/Stop, watch the indicator toggle and `/v1/health.recording` flip, confirm preview keeps rendering. (The agent can compile the app and run `just app-test`, but cannot drive Xcode or see the screen -- so the visual confirmation is Dan's.)
- **[Dan] Real-Pi end-to-end:** `just raspi-deploy`; run the spike harness (above) for the gate; then app over the `dancam-dev` AP -- start recording, confirm preview keeps streaming, stop, confirm `.ts` segments on disk play back; **start/stop a second time and confirm the new segments do not overwrite the first session's** (segment numbering continued).

## Human checkpoints (where the implementor hands off to Dan)

Most of this plan is **agent-autonomous** and validated against the mock with no hardware:
commits 1-5 (all code) plus every automated check (`just raspi-test`, `just app-test`,
`just adr-check`) run on the Mac with no Pi and no eyes-on a screen. (`nix flake check`
only evaluates `devShells.default` -- the cross-build toolchain -- it runs no tests, so it
is not in this list.) The
steps below are the ones the implementing agent **cannot** do -- they need Dan at a keyboard
with hardware, or eyes on the iPhone/app. The implementor must **stop and hand off** at each,
report what to run, and wait -- not plow past them or claim them done.

- **[HAND TO DAN -- one-time, any time before HD2 (the spike)] apt provisioning.** `sudo apt install --no-install-recommends python3-picamera2 ffmpeg` on the Pi over home Wi-Fi, then the `python3 -c "from picamera2 import Picamera2; print('ok')"` verify (Provisioning section). Independent of the code, but the spike (HD2) is the **first real-Pi run** -- it starts the *real* `camera.py` (imports Picamera2, shells out to ffmpeg), both of which come only from this apt -- so provisioning must precede **HD2**, not just HD3.
- **[HAND TO DAN -- HD1, after commit 5] Mock end-to-end on the Mac.** Run the app in Xcode against the mock, tap Record/Stop, *watch* the REC indicator toggle, `/v1/health.recording` flip, and the preview keep rendering (Verification -> Mock end-to-end). Cheap, no Pi -- the first time a human confirms the control + indicator actually behave on screen.
- **[HAND TO DAN -- HD2, THE GATE] On-hardware spike.** Deploy + run the smoke harness on a real Zero 2 W + IMX708, soak room-temp and warm, read **PASS / FAIL A / FAIL B** (On-hardware spike section). This is the only thing that decides hardware `MJPEGEncoder` vs software `JpegEncoder` **and** whether always-on preview-during-recording is real. See the gate note below.
- **[HAND TO DAN -- HD3, after the spike passes] Real-Pi end-to-end.** App over the `dancam-dev` AP: start/stop recording twice, confirm preview holds during recording, segments play back, and the second session does not overwrite the first (Verification -> Real-Pi end-to-end). This is the swoop's "it works in the real loop" confirmation.

**The spike (HD2) gates the app UX (commit 5).** Commit 5 ships always-on
preview-during-recording as the product behavior, which is **correct only if the spike confirms
concurrency**. Mock-first sequencing means the agent may *write* commit 5 against the mock
before the spike runs -- but commit 5 is **not "done" until Dan reports the spike result**:
- **PASS** -> always-on UX stands; ship hardware `MJPEGEncoder`.
- **FAIL A** (preview choppy, recording clean) -> UX stands; flip the one encoder line to software `JpegEncoder` and Dan re-runs the spike.
- **FAIL B** (concurrency untenable) -> commit 5's always-on UX is **wrong**; the follow-up must revise it (`/v1/capabilities.preview.concurrent=false` + pause-preview-while-recording fallback).

So the implementor does not close out `jet` or treat the headline "preview during recording"
claim as validated until Dan has run HD2 and reported PASS (or FAIL A). The gate is a hard
pause on a human/hardware result, not an automated check the agent can satisfy itself.

## Suggested commit sequencing (mock-first; each compiles + tests green)

All five commits are **agent-codeable against the mock with no hardware**; the human
checkpoints (HD1-HD3, plus the one-time apt provisioning that must precede the spike HD2 -- see
"Human checkpoints" above) are where Dan takes over, and the spike (HD2) is the gate that
decides whether commit 5's always-on UX stands or must be revised. Do not treat commit 5 as
final until Dan reports the spike result.

1. `refactor(raspi): widen Backend trait for recording control + status` -- new trait, `status.rs`, `BackendError`, rewrite `MockBackend`, update `StubBackend` + tests, `health` uses `status().recording`. Camera path uses a thin placeholder so it builds with no supervisor yet.
2. `feat(raspi): recording control endpoints + mutation hardening` -- `recording.rs`, routes, `BackendError: IntoResponse`, the `host_allowlist` middleware (loopback always allowlisted; absent-`Host` -> `421`), and the `Content-Type` + `Idempotency-Key` requirement on the POSTs. Updates the existing host-less integration tests (`health.rs`, `preview.rs`) to send an allowlisted `Host` so they stay green under the global allowlist. Fully testable vs `MockBackend` (reject-without-headers + bad-`Host`/wrong-port `421` + absent-`Host` `421` tests).
3. `feat(raspi): picamera2 camera process + provisioning` -- `raspi/camera/camera.py` (real driver + `--fake` driver with lazy Picamera2 import, startup rec-dir creation + fail-fast, shared `compute_skip` preview-fps cap + `--self-test`, `--fake-sensor-fps` source through the gate, segment-start-number continuation, bounded preview queue + stdout writer thread), `deploy.sh` ship-it, `dancam.service` `DANCAM_REC_DIR`, **README provisioning** (apt + verify + smoke harness + systemd device/group check). No Rust compile change.
4. `feat(raspi): supervised camera owner` -- `camera/mod.rs` (supervisor, broadcast fan-out, backoff, graceful shutdown), `CameraBackend`, wire `main`, remove `RpicamBackend` + placeholder, deps, the `camera.py --fake` contract test (incl. `--self-test` invocation) + supervisor restart/backoff test + the **drain-invariant regression test** (recording confirms with zero / stalled subscribers). **Lands the pivot docs in this same change:** ADR 07 (with the ADR 05 read-only-root/RAM reconciliation in its Consequences), ADR 05/02/01 notes, `raspi/AGENTS.md`, `docs/roadmap.md` (per the project's "write the pivot down in the same change" rule). `just adr-check`.
5. `feat(app): recording start/stop on the preview screen` -- `RecordingClient` (POSTs with `Content-Type: application/json` + injectable `Idempotency-Key`), `RecordingFeature`, `HTTPRequestEncoder.post`, `HTTPRequestResponse.post` (round-trip helper with `Connection: close`), `AppDependencies.recording`, `PreviewViewController` controls + REC indicator, app tests (incl. the exact-bytes wire-format test with a fixed key).

(Steps 3/4 may merge if you prefer one atomic pivot commit; the rule that matters is the ADRs
must not trail the code pivot.)

## Risks / edge cases

- **Drain invariant (the big one):** `drain_stdout` must read + `broadcast::send` unconditionally and ignore the no-receivers error; never gate on subscriber count, or the child's recording loop stalls on pipe backpressure. Single most important line to get right.
- **Whole-frame stdout writes + flush:** the stdout writer thread must write each JPEG **whole** (blocking) and `flush()` per frame, and stderr JSON must be line-buffered. Writing JPEGs straight to a non-blocking fd risks a short-write that tears a frame and corrupts the stream; a fully-buffered child makes preview bursty and events laggy. The bounded queue + dedicated writer thread is the design that satisfies this without ever blocking the encoder. Contract obligation.
- **Segment overwrite (footage loss):** ffmpeg runs with `-y` and a default start-number of 0, so a re-started recording overwrites `seg_00000.ts` unless we pass `-segment_start_number <highest+1>` computed by scanning `DANCAM_REC_DIR` first. The `--fake` contract test and the spike both assert two cycles do not collide.
- **Splitter reset per child:** fresh `JpegSplitter` each generation, or a torn frame at a crash boundary corrupts the next stream's first frame.
- **Start/stop race / lost wakeup:** subscribe to the status `watch` before sending; `borrow_and_update` + `changed()` under a timeout; commands while `Restarting`/`Offline` return `CameraOffline` rather than queueing into a dead child.
- **Graceful shutdown ordering:** stop serving, signal supervisor, send `shutdown`, `wait` with a hard timeout, else `kill`; `kill_on_drop(true)` backstops a supervisor panic (no orphan).
- **Concurrency gate:** the whole "preview during recording" claim (Pi service fan-out is trivially N-client; the app shows it always-on) rides on the on-hardware spike. Keep it honest -- if the spike fails, the deferred `preview.concurrent=false` + app fallback is the contingency, and the app's always-on UX must be revisited.
- **Durability scope:** ffmpeg's segment muxer does not `fsync` on close; just-closed segments ride the page cache until ADR 01's mount/card layers land. Acceptable for `jet` because `.ts` truncation-tolerance bounds loss to one segment; do not claim full crash-safety here.
- **Python stack vs the read-only car image (forward risk, recorded in ADR 07):** `jet` runs on the writable dev image, where shipping CPython+picamera2+numpy is fine. The car image (swoop `vine`) mounts root read-only, so the whole Python stack must be baked in as inert files (or the all-Rust camera binary must land first). Not a `jet` blocker; flagged so it is solved at `vine`, not rediscovered there.
- **systemd device access (deploy risk):** the spike validates the camera over an interactive SSH shell, but the deployed service runs `User=dan` under systemd with no login session, where access to `/dev/video11` and `/dev/dma_heap/*` can differ. Confirm group coverage of both devices and a successful camera open (a `ready` event) under the unit before trusting the deployed path -- not only the interactive spike.

## Follow Up

- Run the mock end-to-end check from the plan: start the mock Pi with `just raspi-run`, run the app with `DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080`, and visually confirm Record / Stop Recording toggles the REC indicator while preview keeps rendering.
- Before the hardware spike, install and verify Pi camera dependencies with the README Picamera2 command: `sudo apt install -y --no-install-recommends python3-picamera2 ffmpeg`; `python3 -c "from picamera2 import Picamera2; print('ok')"`.
- Run the real Zero 2 W + IMX708 spike from README.md to decide whether hardware MJPEG preview passes, needs software `JpegEncoder`, or requires the preview-while-recording fallback.
- After the spike passes, run the real-Pi app end-to-end over `dancam-dev` and confirm two recording sessions create non-overwriting `.ts` segments.
