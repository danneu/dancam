# Plan: `lime` swoop spike (clip pull throughput + on-device playback)

## Context

The `lime` swoop ("Watch recorded clips" in `docs/roadmap.md`) is the chunky one --
the first time footage is watchable on the phone -- and the roadmap gates its build
behind a **spike**. The spike bundles two of the transport ADR's flagged spikes
(`raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md#Spikes flagged`):

- **Spike 2 -- 2.4 GHz throughput:** how long does a real ~38 MB `seg_*.ts` pull take
  over the `dancam-dev` AP, desk and in-car? A full 30 s segment is ~38 MB (10 Mbps CBR),
  so the pull -- not the UI -- is the weight, and the number decides the **gating**
  pull-UX question: is resume mandatory? (The companion "must preview be throttled during
  a pull?" question is **not gated by this spike**: in `lime`'s product surface a
  foreground pull never coexists with preview, because opening the viewer is exactly what
  stops the preview stream -- see the Measure matrix. It returns when concurrent/background
  pulls exist, at `opal` / the on-device-store step. An optional throwaway probe below can
  still capture the worst-case preview+pull AP-airtime number now while the rig is up.)
- **Spike 5a -- on-device playback:** does a pulled `.ts` actually play via a loopback
  (`127.0.0.1`) HLS playlist + AVPlayer on a real device, while joined to the
  no-internet `dancam-dev` AP?

The output is a measurement table + a go/no-go that sets the pull design before we
commit to the resumable-pull / on-device store / viewer build steps below it.

**Nothing here is throwaway** (per the repo's "ideal solution" stance): every code
piece is the first real `lime` build step. The Pi endpoint *is* the roadmap's "Pi
(plain serve)" step; the `ClipPullClient` struct-of-closures is the seam that grows
into the "App (riskiest): resumable ranged pull" step; the loopback server + viewer
are the "download-then-play" and "viewer" steps. The only deliberately throwaway parts
are the viewer's imperative orchestration and a small sample `.ts` fixture the mock
serves from its rec-dir, both easy to delete when `lime` proper lands.

Halves A (throughput) and B (playback) are **independent**: B is validated on the desk
by pointing the mock Pi's rec-dir at a sample segment and driving the **real** clip list
+ pull client over loopback (no real Pi/AP); A needs the real Pi + AP.

---

## Build

### A. Pi: `GET /v1/clips/{id}` plain-serve (`raspi/service/`)

The dumbest end-to-end that proves tap -> pull -> play: serve a finished segment's raw
`.ts` as a plain `200` (`application/mp2t`) with `Content-Length`; **no Range yet**
(the ranged/resumable pulse is pulled in later by the app's resume step). Never serve
the open segment, matching `GET /v1/clips`.

- **`Cargo.toml`** -- add `"fs"` to the `tokio` features list (currently absent;
  `tokio::fs::File` needs it) and add `tokio-util = { version = "0.7", features = ["io"] }`
  for `ReaderStream` (idiomatic axum file streaming -- avoids reading 38 MB into RAM).
- **`raspi/service/src/clips.rs`** -- add `serve_clip(State<AppState>, Path<u32>)`
  (alias the axum extractor, e.g. `Path as PathParam`, to avoid clobbering the existing
  `std::path::Path` import):
  - If `state.backend.status().recording` and `id == max_clip_seq(&rec_dir)`, return
    `404` -- the open segment is mid-write and never listed. Add a small
    `max_clip_seq(rec_dir) -> Option<u32>` helper reusing the existing
    `clips.rs#clip_seq` parser (same `seg_NNNNN.ts` -> `u32` rule as
    `clips.rs#read_finished_clips`).
  - Open `rec_dir/seg_{id:05}.ts`; on any open/metadata error return `404`.
  - Stream the body with `ReaderStream::new(file)` via `Body::from_stream`, headers
    `Content-Type: application/mp2t` and an explicit `Content-Length` from file metadata
    (so curl / the app get a progress bound rather than chunked-unknown).
  - Add a `ClipError::NotFound` enum with an `IntoResponse` returning
    `StatusCode::NOT_FOUND` (mirrors `recording.rs#RecordingRequestError`).
- **`raspi/service/src/lib.rs`** -- register
  `.route("/v1/clips/{id}", get(clips::serve_clip))` next to the existing `/v1/clips`
  route in `lib.rs#fn app` (axum 0.8 `{id}` syntax, matching the registered routes).
- **`raspi/service/tests/clips.rs`** -- three integration tests in the existing
  `oneshot` + `StubBackend` + `TempRecDir` style (remember the `Host: localhost:8080`
  header the host-allowlist middleware requires):
  1. `serve_clip` returns the exact bytes with `Content-Type: application/mp2t` and a
     correct `Content-Length`.
  2. While `recording`, the highest-seq (open) segment returns `404`; a lower finished
     id returns `200` -- the same exclusion the list makes.
  3. A missing id returns `404`.

### B. App: pull-timer harness (`app/DanCam/`) -- Half A client

New client mirroring `ClipsClient.swift#ClipsClient` / `PreviewClient.swift#PreviewClient`
(a `nonisolated struct` of `@Sendable` closures with `.live(baseURL:pinning:)`, a
`.live(...openByteStream:)` test seam, and `.noop`), so it stays unit-testable and
grows into the real resumable pull.

- **`Networking/Clips/ClipPullClient.swift`** (new) --
  `var pull: @Sendable (_ clipID: Int) -> AsyncThrowingStream<ClipPullEvent, Error>`
  where events are `.progress(bytesWritten, expected:)` / `.completed(ClipPullResult)`
  (`ClipPullResult` = `fileURL, bytes, elapsed, throughputMbps`). The stream shape (not
  a one-shot) is deliberate: the roadmap calls a silent 6-26 s spinner a "hang," so the
  viewer renders a live progress bar.
  - Body loop copied in **shape** from `PreviewClient.swift#produceFrames`, but built as a
    **finite** request: `HTTPRequestEncoder.get(url:, extraHeaders: [("Connection", "close")])`
    -> `NWByteStream.open(url:request:pinning:)` ->
    `HTTPResponseHeadParser` until `.complete(head, leftover)` -> validate `200...299` ->
    read `Content-Length` for the progress total -> `HTTPBodyDecoder(head:)` (reuse,
    content-length mode -- it already slices exactly `Content-Length` and flips
    `isComplete`) -> for each chunk, `decoder.append(chunk)` slices written to a
    `FileHandle` on `FileManager.default.temporaryDirectory`, yielding `.progress`.
  - **Reuse `HTTPBodyDecoder`; do NOT call `HTTPRequestResponse.get`** -- the latter
    accumulates the whole body into one in-memory `Data` and can't stream-to-disk or
    surface progress. The decoder already handles `Content-Length` and (later) a `206`
    body unchanged, so the resume step only adds a `Range:` request header + a
    `Content-Range` parse on top.
  - **Send `Connection: close`** -- the finite-request convention `HTTPRequestResponse.get`
    already follows (`HTTPRequestResponse.swift#get`), and the reason ClipPullClient copies
    `PreviewClient`'s body-loop *shape* but not its request header (`PreviewClient`'s
    infinite MJPEG stream deliberately omits `Connection: close`). Framing doesn't depend on
    it -- the pull is bounded by `Content-Length`, so `HTTPBodyDecoder` flips `isComplete`
    exactly at the body end regardless -- but it makes the Pi tear the socket down the moment
    the clip is served instead of parking a keep-alive connection that competes with preview
    + recording on the congested 2.4 GHz AP, and gives a belt-and-suspenders EOF.
  - Timing: capture `ContinuousClock.now` immediately before `NWByteStream.open` and at
    `isComplete`; `throughputMbps = bytes * 8 / 1e6 / seconds`.
  - **Cancellation/cleanup:** the producing task's `do/catch` (copied from
    `produceFrames`) treats `CancellationError` as terminal and, on cancel **or** error,
    closes the `FileHandle`, lets the `AsyncThrowingStream` terminate (its
    `onTermination` already `connection.cancel()`s the underlying `NWConnection`, see
    `NWByteStream.swift#open`), and deletes the partial temp file -- so a cancelled pull
    leaves no half-written `.ts` and no live transfer competing for the AP.
  - **Temp file naming:** write to a **unique-per-pull** path in `temporaryDirectory`
    (e.g. `clip-<id>-<token>.ts`, a fresh token each pull) and remove any prior file for
    that clip id before writing. On success the file is kept (the loopback server serves
    it; the on-device store is deferred), so a fixed/reused name across re-taps could serve
    stale or partially-overwritten bytes and read as a playback bug rather than a fixture
    issue. (The cancel/error path above already deletes the partial file.)
- **Timing surface (three sinks, on-screen mandatory):** introduce one shared
  `os.Logger`/`OSSignposter` (subsystem `com.danneu.dancam`, category `pull`) -- a
  signpost interval for Instruments (desk) and one structured `Logger.info` line for
  Console.app (USB-tethered). The **on-screen result label** in the viewer
  (`38.2 MB - 7.4 s - 41 Mbps`) is the only sink that works **in-car** with no Mac
  attached, so it is required.
- **Wiring:** add `var clipPull: ClipPullClient` to `App/AppDependencies.swift#AppDependencies`
  (`.noop` default; `.live(baseURL: configuration.cameraAPIBaseURL, pinning: configuration.cameraAPIInterfacePinning)`
  in `init(configuration:)`), alongside `clips`/`preview`.
- **Tap hook in `Features/Home/HomeViewController.swift`:** add `UITableViewDelegate`
  conformance, set `clipsTableView.delegate = self` in `configureClipsTable`, flip the
  row `selectionStyle` from `.none` to `.default` in `tableView(_:cellForRowAt:)`, and
  add `didSelectRowAt` that reads the tapped `Clip` from the local `clips` array (fed by
  `renderClips`) and pushes `ClipViewerViewController(dependencies:clip:)` via
  `navigationController?.pushViewController` -- same push mechanism as
  `HomeViewController#debugTapped`, but note `debugTapped` passes `(dependencies:store:)`
  while the viewer takes `(dependencies:clip:)`, so do **not** copy the `store:` argument.
- **TEA boundary (deliberate):** the spike keeps the **client** dependency-shaped and
  testable but lets the **viewer VC orchestrate imperatively** (`Task { for try await
  event in client.pull(id) { ... } }` driving a `UIProgressView`/label). A `PullFeature`
  reducer is premature now -- its real state machine work (Range/If-Range/ETag resume,
  retry/backoff, the on-device clip store) belongs to the later `lime` step, and a
  half-version would be rewritten. Minimal diff, nothing to unwind.

### C. App: loopback HLS + AVPlayer viewer (`app/DanCam/`) -- Half B

No AVFoundation, no `NWListener`, no loopback server exists yet -- all net-new, all real
`lime` code.

- **`Networking/Loopback/LoopbackHLSServer.swift`** (new) -- a non-`@MainActor`
  **`actor`** that owns the `NWListener`, the accepted `NWConnection`s, and the resolved
  base `URL`. The Network callbacks (`newConnectionHandler`, per-connection
  `stateUpdateHandler`/`receive`) run on a private serial `DispatchQueue`
  (`com.danneu.dancam.loopback`, passed as the Network callback queue) and hop back onto
  the actor with `Task { await self.<handler>(...) }`; request parsing and multi-MB
  file/range reads then run as actor work, **off the UI actor**. **Actor isolation -- not
  a bare serial-queue convention -- is what makes this strict-concurrency-safe:** an
  `actor` is `Sendable`, so capturing `self` inside the `@Sendable` listener/connection
  callbacks compiles cleanly under Swift 6, whereas a mutable `nonisolated final class`
  capturing `self` there is a Sendable violation (a serial queue is a runtime convention
  the compiler can't prove). `NWByteStream` gets away with a stateless `enum` + a per-call
  queue precisely because it owns no instance state; a server holding listener/connection
  state cannot, so it must be actor-shaped. It wraps `NWListener` bound to loopback:
  `NWParameters.tcp` with `requiredInterfaceType = .loopback`, `on: .any` (OS-assigned
  ephemeral port), reads the port at `.ready` and resolves `http://127.0.0.1:<port>/`
  (same `withCheckedThrowingContinuation` + `stateUpdateHandler` pattern as
  `NWByteStream.swift#start`, resolved inside the actor). `start() async throws -> URL`
  returns **only** the resolved base `URL` (Sendable) to the MainActor viewer; `stop()` is
  an `await`-ed actor method that cancels the listener. One request/response per
  connection, and **every response carries `Connection: close`** -- the server closes the
  socket after responding, so it must signal that, or AVPlayer (which assumes HTTP/1.1
  keep-alive) would try to reuse the just-closed socket for its next playlist/range request
  and eat a reset+retry that adds latency/noise to a timing spike. Routes:
  - `GET/HEAD /index.m3u8` -> `200 application/vnd.apple.mpegurl`, generated playlist.
  - `GET/HEAD /segment.ts` -> the pulled file **with full Range support** (see below).
  - else -> `404`.
  - **Critical:** AVPlayer issues its own HTTP requests for the media and **requires
    byte-range support** even though the Pi serves a plain `200`. The loopback server
    must implement Range itself: absent `Range` -> `200` + full body; present ->
    `206 Partial Content` + `Content-Range: bytes <s>-<e>/<total>` + sliced body
    (`FileHandle.seek`/`read` or `Data(contentsOf:options:.mappedIfSafe)`); unsatisfiable
    -> `416` with `Content-Range: bytes */<total>`. Advertising `206`s is how AVPlayer
    discovers it can scrub.
  - Held as a strong property on the viewer VC for the player's whole lifetime; the viewer
    tears it down by scheduling `Task { [server] in await server.stop() }` from
    `viewWillDisappear` (and as a `deinit` backstop) -- both are **synchronous** UIKit
    contexts, so the actor `stop()` is dispatched into a `Task`, never `await`-ed inline.
    Dealloc mid-playback stalls AVPlayer.
- **`Networking/Loopback/HLSPlaylist.swift`** (new) -- pure
  `singleSegmentVOD(segmentURI:targetDuration:durationSeconds:) -> String` emitting
  `#EXTM3U` / `#EXT-X-VERSION:3` / `#EXT-X-TARGETDURATION` (= `ceil(duration)`, must be
  >= `EXTINF`) / `#EXT-X-MEDIA-SEQUENCE:0` / `#EXT-X-PLAYLIST-TYPE:VOD` / `#EXTINF` /
  relative `segment.ts` / `#EXT-X-ENDLIST`. Use `Clip.durMs` when present, else 30 s.
- **`Networking/Loopback/HTTPRangeRequest.swift`** (new) -- pure helpers: parse the
  request line `(method, path)`, parse `Range: bytes=...` into a resolved `(start, end)`
  against total size (handle `bytes=0-1` probe, `bytes=0-`, `bytes=N-`, suffix
  `bytes=-N`), build `200`/`206`/`416` heads -- each with the right `Content-Length`,
  `Content-Type`, and `Connection: close` (per the server's close-after-respond rule
  above). Mirror `HTTPRequestEncoder.swift` framing.
- **`Features/ClipViewer/ClipViewerViewController.swift`** (new) -- container VC
  (`init(dependencies:clip:)`, programmatic like `HealthViewController`): show the pull
  `UIProgressView` -> on `.completed`, show the throughput label, `await server.start()`
  (await `.ready` so the port is bound **before** AVPlayer is built), then
  `AVPlayer(url: base.appending(path: "index.m3u8"))` in an `AVPlayerViewController`
  **embedded as a child** (so progress UI + server lifetime live in one VC already on the
  nav stack), `player.play()`. `import AVKit` is new.
  - **Lifetime/cancellation:** store the pull as `private var pullTask: Task<Void, Never>?`.
    `viewWillDisappear` and `deinit` are **synchronous** UIKit contexts (see
    `HomeViewController#viewWillDisappear`), so do the synchronous teardown inline --
    `pullTask?.cancel()`, `player.pause()` -- then schedule the actor cleanup as
    `Task { [server] in await server.stop() }` (capture `server` so the actor outlives the
    VC). A bare `await server.stop()` in those methods would **not compile** -- never write
    one. Backing out mid-pull must not leak a 38 MB transfer that
    retains the VC, updates dead UI, or skews the AP throughput numbers (the client's
    cleanup above tears down the connection and partial file on that cancel).
- **Unit tests (Swift Testing):** `HLSPlaylist` output and `HTTPRangeRequest`
  parse/build are pure -> direct `@Test`s. `ClipPullClient` via an injected byte stream
  (the `ClipsClientTests` / `AsyncStreamHelpers.byteStream` idiom): feed a content-length
  body as **several** chunks and assert ordered `.progress(bytesWritten, expected:)`
  events (monotonically increasing `bytesWritten`, correct `expected` total) **before**
  `.completed`, plus the final on-disk file bytes and `result.bytes` equal the full body
  -- this guards against regressing to a silent "only `.completed`" client that would
  bring back the spinner-as-hang. The same injected `openByteStream` seam **captures the
  request `Data`**; assert its framing -- request line `GET /v1/clips/<id> HTTP/1.1`, the
  `Host` header, and `Connection: close` -- so a wrong path or a dropped finite-request
  header is caught (the response-body assertions alone wouldn't be). The `NWListener`
  server + AVPlayer wiring is validated **on device** -- that is the spike.

### Mock parity / desk testing

Throughput timing over loopback is meaningless (says nothing about the 2.4 GHz AP), so
that half requires the real Pi + AP. But the **pull + playback chain** is proven on the
desk **mock-first, through the real clip list + pull client** -- not bypassed by an
app-bundled fixture (which could pass while `GET /v1/clips/{id}` + `ClipPullClient` +
tap-to-viewer is still broken).

- `serve_clip`/`list_clips` read straight from `rec_dir` regardless of backend, so the
  mock serves a clip with **zero mock-code changes**: drop a **real ~30 s** MPEG-TS
  segment at `raspi/service/assets/clips/seg_00000.ts` (mirrors the existing
  `assets/preview/` asset convention) and run the mock pointed at it:
  `DANCAM_REC_DIR=assets/clips just raspi-mock` (add a thin `raspi-mock-clips` recipe for
  discoverability). `MockBackend` defaults `recording = false`, so the segment lists and
  serves with no open-segment exclusion.
  - **Duration must be ~30 s, not trimmed to a few seconds.** `read_finished_clips`
    reports `dur_ms: null` (`clips.rs#read_finished_clips`), so `HLSPlaylist` always falls
    back to 30 s -- and real segments *are* 30 s (`camera.py`'s `-segment_time 30`). A
    2-3 s desk fixture played behind a 30 s `#EXTINF`/`#EXT-X-TARGETDURATION` would give a
    wrong scrubber timeline, so a "broken" seek/playback could be a fixture artifact rather
    than a real chain failure. A ~30 s fixture makes **desk == production**. To keep the
    repo small, re-encode a real `seg_*.ts` to low bitrate
    (`ffmpeg -t 30 -c:v libx264 -b:v 1.5M -f mpegts`, a few MB) rather than `-c copy`
    (which keeps the full ~38 MB) -- still a valid H.264/MPEG-TS the loopback + AVPlayer
    path exercises faithfully. Revisit once `dur_ms` reporting lands (the playlist would
    then honor the real duration and a shorter fixture would be fine).
  This realizes the roadmap's "Mock parity" item essentially for free, and keeps desk
  testing mock-first.
- Desk run: simulator app with `DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080` set in
  the scheme (pinning auto-disabled for localhost) -> the clip lists -> tap ->
  `ClipPullClient` pulls over loopback to a temp file -> loopback HLS server -> AVPlayer
  plays + scrubs. Exercises the **whole real chain** except the AP link itself.
- **Physical-device "mock" is not viable** and is not used: `raspi-mock-lan` binds
  `0.0.0.0:9000`, but `lib.rs#HostPolicy` only allows the fixed hosts + port `8080`, so a
  device hitting `http://<mac-ip>:9000` is rejected (`MISDIRECTED_REQUEST`). Reserve all
  physical-device validation for the real Pi over the AP (don't widen `HostPolicy` for the
  spike).

### Already cleared (no work)

- **ATS:** `app/DanCam/DanCam/Info.plist` already sets `NSAppTransportSecurity >
  NSAllowsLocalNetworking = true`, which lifts ATS for loopback -- AVPlayer's
  `http://127.0.0.1` HLS load is permitted with **no plist / build-setting change**.
- **Local Network privacy prompt:** loopback (`127.0.0.1`) is exempt (TN3179); a
  `.loopback`-bound `NWListener` advertises nothing on the LAN -> no prompt. (The
  `NSLocalNetworkUsageDescription` key is present anyway for the real-LAN preview path.)
- **MPEG-TS playback:** AVPlayer plays a single-segment VOD (`#EXT-X-ENDLIST`) over
  `video/mp2t` H.264 fine; the asset URL must be the `.m3u8` (cannot hand AVPlayer a raw
  `.ts`), and correct MIME types + path extensions are kept (handled in B).

---

## Measure (physical -- Dan runs these; this is the actual spike output)

Deploy the new Pi endpoint (`just raspi-deploy`), start recording and **leave it running**
(don't stop it -- ~40 s in, a finished ~38 MB `seg_*.ts` exists in `/home/<user>/rec` to pull,
while the camera keeps writing the open segment), flip the AP (`just raspi-ap [minutes]`,
auto-revert armed), join `dancam-dev` from the iPhone. Recording-during-pull is the point,
not a setup nicety -- see the matrix.

- **Spike 2 -- throughput matrix** (pull via the in-app viewer over the pinned
  `NWConnection`; read the on-screen `MB - s - Mbps` label):

  | location | live preview | Pi recording | capture per run |
  |---|---|---|---|
  | desk | off | on | time, throughput |
  | in-car (parked) | off | on | time, throughput |

  These are **preview-off by construction**: pushing `ClipViewerViewController` fires
  `HomeViewController.viewWillDisappear`, which UIKit forwards to the child
  `PreviewViewController` (`PreviewViewController#viewWillDisappear` sends `.onDisappear`,
  and `PreviewFeature.reduce` cancels the `"preview"` stream). So a viewer-driven pull
  *always* runs with preview already stopped -- a "preview on" row measured this way would
  silently record preview-off numbers. That matches `lime`'s product surface (a foreground
  pull never coexists with preview), so the preview-contention rows are **deferred** to
  `opal` / the on-device-store step where concurrent/background pulls exist.
  **Recording stays ON for every timed pull** (the `on` column). This is the always-on
  dashcam reality -- the Pi never stops recording to serve a clip ("SD is the source of
  truth... the Pi always records locally," root `AGENTS.md`) -- and it is the contended
  worst case the resume decision must reflect: continuous H.264 encode + SD writes are the
  *dominant* competing load on a Pi Zero 2 W during a pull (bigger than preview), so a
  recording-idle number would understate the real in-car worst case -- exactly where it
  matters most if the result lands near the resume threshold. Capture `recording=on`
  alongside `just pi-mem` and SoC temp in the per-run notes, so the headline number is
  reproducible later. Expectation ~6-26 s; stalls/drops or >>60 s make resume mandatory.
- **Optional (throwaway) preview+pull contention probe:** if Dan wants the worst-case
  AP-airtime number now, add a throwaway Home-side trigger (a debug button or row
  long-press) that runs the *same* timed `clipPull.pull(id)` **without navigating away**,
  rendering the `MB - s - Mbps` label as a Home HUD. Preview stays live and visible, so
  this measures true preview+pull contention and lets Dan watch preview stutter directly
  (the full-screen viewer can't). It does not gate this spike and is deleted with the rest
  of the throwaway scaffolding when `lime` proper lands.
- **Spike 5a -- playback:** confirm the pulled `.ts` plays in the embedded AVPlayer on
  device while joined to `dancam-dev`, with working scrub (proves the `206` path).
- A quick `curl -o /dev/null -w '%{time_total} %{speed_download}\n' http://10.42.0.1:8080/v1/clips/<id>`
  from the Mac on `dancam-dev` is a fine link baseline before the iPhone runs.

---

## Gate + write-back

When both halves are green, record the result into the `docs/roadmap.md` `lime` spike
bullet (the `fox` precedent: an inline `_spike confirmed: ..._` note with the measured
pull times + the resume decision). Record the measurement **conditions** with the number
-- preview off, **recording on** -- so the headline figure stays reproducible and isn't
later misread as a recording-idle best case. Append a note to ADR 02
(`raspi/docs/design/02-...`) if the design shifts -- e.g. resume goes from optional to
mandatory, or the iPhone-poster approach supersedes the Pi `/thumb` for the pulled case
(roadmap `lime` scope fence already flags this ADR-02 follow-up). If the optional
contention probe was run, record its number too -- but the preview-throttle-during-pull
decision itself stays deferred to `opal`, since no foreground preview+pull contention
exists in `lime`'s own product surface.

---

## Verification

- **Pi:** `just raspi-test` green (the three new `serve_clip` tests + existing suite);
  after deploy, the `curl` above returns `200`, `Content-Type: application/mp2t`, a
  correct `Content-Length`, and the open segment / a missing id return `404`.
- **App:** `just app-test` green (new `HLSPlaylist`, `HTTPRangeRequest`, `ClipPullClient`
  tests + existing suite); `just app-build` clean.
- **Desk (no Pi):** simulator app against `DANCAM_REC_DIR=assets/clips just raspi-mock`
  -> the clip lists, taps through to the viewer, pulls over loopback, and plays + scrubs
  through the loopback server + AVPlayer (validates the whole real list -> pull ->
  loopback -> Range/`206` -> playlist -> AVPlayer -> ATS chain, mock-first). **Sanity-check
  simulator playback of the fixture early**; the Simulator's AVPlayer can occasionally
  diverge from device on HW-decode/HLS paths, so if it misbehaves, treat the **on-device**
  gate (already the real Half-B spike) as authoritative rather than chasing a
  simulator-only artifact -- everything up to AVPlayer (list -> pull -> loopback ->
  Range/`206` -> playlist) is verified by the pure unit tests + the desk request flow
  regardless.
- **On device:** the throughput matrix is filled and a real pulled segment plays on the
  `dancam-dev` AP -- the spike's go/no-go.

---

## Critical files

New:
- `raspi/service/src/clips.rs` (edit -- `serve_clip` + `max_clip_seq` + `ClipError`)
- `app/DanCam/DanCam/Networking/Clips/ClipPullClient.swift`
- `app/DanCam/DanCam/Networking/Loopback/LoopbackHLSServer.swift`
- `app/DanCam/DanCam/Networking/Loopback/HLSPlaylist.swift`
- `app/DanCam/DanCam/Networking/Loopback/HTTPRangeRequest.swift`
- `app/DanCam/DanCam/Features/ClipViewer/ClipViewerViewController.swift`
- `raspi/service/assets/clips/seg_00000.ts` (real ~30 s low-bitrate segment the mock serves via `DANCAM_REC_DIR`; ~30 s so it matches the playlist's 30 s fallback; not bundled in the app)

Edit:
- `raspi/service/Cargo.toml` (tokio `fs` feature + `tokio-util`)
- `raspi/service/src/lib.rs` (route registration in `fn app`)
- `raspi/service/tests/clips.rs` (three `serve_clip` tests)
- `app/DanCam/DanCam/App/AppDependencies.swift` (wire `clipPull`)
- `app/DanCam/DanCam/Features/Home/HomeViewController.swift` (delegate + `didSelectRowAt`)
- `Justfile` (add a `raspi-mock-clips` recipe: `DANCAM_REC_DIR=assets/clips`)

Reused unchanged: `NWByteStream.swift`, `HTTPBodyDecoder.swift`, `HTTPResponseHeadParser.swift`,
`HTTPRequestEncoder.swift`, `ClipsClient.swift`/`PreviewClient.swift` (as templates).

The app target uses Xcode **file-system-synchronized groups** (`PBXFileSystemSynchronizedRootGroup`,
confirmed in `DanCam.xcodeproj/project.pbxproj`), so the new `.swift` files need **no
`project.pbxproj` edits** -- adding them on disk is enough. The `assets/clips/` fixture is on
the Rust side (read at runtime via `DANCAM_REC_DIR`), not an app bundle resource.

## Suggested build order

1. Pi endpoint (A) + tests -- standalone, unblocks real desk numbers immediately.
2. App pull client + minimal viewer showing progress + timing (Half A).
3. Loopback server + HLS playlist + Range helpers + AVPlayer in the viewer, validated on
   the desk **through the mock-served clip** (`DANCAM_REC_DIR=assets/clips just raspi-mock`)
   -- list -> tap -> pull -> play (Half B).
4. Hand to Dan for the in-car matrix + on-device playback; then write-back.

## Implementation notes

- `raspi/service/assets/clips/seg_00000.ts` was generated with `ffmpeg` as a 30 s H.264/MPEG-TS test source because the repo did not contain a captured Pi `seg_*.ts` to re-encode; it still exercises the mock rec-dir, clip pull, loopback HLS, and AVPlayer container path.
