# Plan: Swoop `fox` -- Live preview on iPhone

## Context

`fox` is the first end-to-end "it works!" moment for dancam: open a screen on the
iPhone and see live video coming off the Pi camera. Today the system only proves a
health endpoint (swoop `pine` is done: AP up, iPhone gets health JSON, `rpicam`
captures a JPEG). `fox` adds the live preview plane on top of that proven base.

What we build:
- The Pi serves `GET /v1/preview/live.mjpeg` -- a `multipart/x-mixed-replace` MJPEG
  stream (~640x480 @ ~10fps) from the camera, never the H.264 encoder.
- The app opens a Wi-Fi-pinnable `NWConnection`, hand-rolls an HTTP/1.1 GET, parses
  the multipart stream into JPEG frames, and renders them on the iPhone screen.

This realizes the transport ADR's preview **wire contract and UX**
(`raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md`) -- MJPEG over
`multipart/x-mixed-replace`, rendered on the iPhone -- and runs the roadmap's flagged
spike: confirm `NWConnection` Wi-Fi pinning + no-internet-AP / captive-probe handling
behaves on a physical device joined to the Pi AP. It does **not** exercise the ADR's
lores-substream-concurrent-with-H.264-recording mechanism (there is no recording in
`fox`); that stays a `jet` risk (see Scoping facts and Phase 5).

Per the accepted app transport ADR, **every** Pi connection is a Wi-Fi-pinnable
`NWConnection` (because `URLSession` cannot pin to an interface), and control (health)
is request/response over that socket. So `fox` builds the hand-rolled
HTTP/1.1-over-`NWConnection` client as the **camera-API foundation** and routes
**both** the existing health fetch and the new preview through it -- not preview alone.
This keeps the pinning spike meaningful: the landing screen auto-fetches health, so an
unpinned `URLSession` request would otherwise pollute the device/AP test.

**Scoping facts (honor these):**
- `fox` has **no H.264 recording** -- preview need not run while recording, which
  sidesteps the headline preview-while-recording spike (deferred to `jet`). The Pi
  therefore runs a **temporary preview-only camera mode** (`rpicam-vid --codec mjpeg`
  on the main stream), **not** the ADR's libcamera lores substream running concurrently
  with the H.264 recording. Validating that lores / concurrent-preview path is
  explicitly **left unresolved for `jet`** -- Phase 5 records the deviation so `jet`
  does not inherit it hidden.
- **AP join is manual for `fox`** -- Dan joins `dancam-dev` via iOS Settings.
  `NEHotspotConfiguration` auto-join and `NWBrowser` Bonjour discovery are deferred to
  swoop `opal`. `fox` connects directly to the configured gateway
  (`http://10.42.0.1:8080`).
- **No auth/Host-allowlist hardening** in `fox` (later pass). The app still sends a
  correct `Host` header for forward-compatibility.

## Shape: two tracks, modular phases

The work splits into a **Mac-only part** (Phases 1-2: fully buildable and
unit-testable here, including driving the Simulator) and an **interactive hardware
part** (Phases 3-4: real camera on the Pi, then live preview on the physical iPhone
over the AP). The interactive phases have explicit PAUSE points where the implementor
stops and asks Dan to act on the Pi / iPhone / Xcode, then waits for his response.
Phase 5 closes out docs. If Dan wants to stop after the Mac-only phases and run the
hardware phases later, the split is clean.

## Shared wire contract (both sides agree)

Response head: `Content-Type: multipart/x-mixed-replace; boundary=dancamframe`,
`Cache-Control: no-store`, plus the existing `X-Dancam-Proto: 1` / `X-Dancam-Boot-Id`
middleware headers. The stream is unbounded, so there is no overall `Content-Length`;
serving it from `axum::body::Body::from_stream` makes hyper frame the HTTP/1.1 response
with **`Transfer-Encoding: chunked`** (the standard HTTP/1.1 framing for an
unknown-length body). The stream ends on client disconnect (the server never sends a
terminating `0`-chunk).

**Client obligation (raw-socket framing):** because the app reads the response off a
raw `NWConnection` -- not `URLSession`, which would de-chunk for us -- the client must
**strip the HTTP chunked transfer coding before multipart parsing**: the chunk-size
lines are interleaved at arbitrary offsets and are not aligned with the multipart parts,
so feeding raw wire bytes straight into the multipart parser corrupts it. A pure
`HTTPBodyDecoder` (Phase 2) owns this. Two things that look like they exercise the Swift
decoder against real hyper framing do **not**: the Rust `tests/preview.rs` below runs the
handler via `tower::oneshot`, which collects the body *above* the transfer layer (it
asserts the multipart envelope but never sees chunk framing); and the Phase 3 home-LAN
`curl`/Chrome check de-chunks internally (it proves the *Pi* emits valid chunked MJPEG,
not that the *Swift* `HTTPBodyDecoder` decodes hyper's output). The Swift decoder first
meets real hyper chunked framing in the **Phase 2 Simulator-against-`just raspi-run`** run
(a real `NWConnection` -> real socket -> hyper's HTTP/1.1 codec); Phase 2 pins that down
with an automated assertion by replaying a committed `curl --raw` wire fixture (per F1),
rather than leaning on the manual Simulator screenshot.

Each frame part:
```
--dancamframe\r\n
Content-Type: image/jpeg\r\n
Content-Length: <N>\r\n
\r\n
<N bytes of JPEG>\r\n
```
Per-part `Content-Length` is sent (most robust framing; lets the parser skip JPEG
bodies without scanning binary data for the boundary). The app parser must tolerate
its absence too (boundary-scan fallback). No closing `--dancamframe--` (unbounded
stream; the finite test stream simply ends).

---

## Phase 1 -- Pi + mock serve MJPEG (Mac-only, no Dan action)

Owner code: `raspi/service/`. Mirrors the existing flat service style (`lib.rs`
builds the Router; `proto_headers` middleware composes with a streaming body since it
only inserts headers after the handler returns).

**New files**
- `raspi/service/src/jpeg.rs` -- `JpegSplitter`: stateful struct splitting a
  concatenated-JPEG byte stream (rpicam stdout) into frames by scanning SOI
  (`FF D8`) -> EOI (`FF D9`). Pure; survives read boundaries. Pure-fn unit tested.
- `raspi/service/src/preview.rs` -- the handler `live_mjpeg(State<AppState>) ->
  Response` and `frame_part(&[u8]) -> Bytes` (the exact multipart envelope above). The
  handler sets `Content-Type: multipart/x-mixed-replace; boundary=dancamframe` and
  `Cache-Control: no-store` on the response head (the `X-Dancam-*` proto headers are
  added by middleware); body via
  `axum::body::Body::from_stream(frames.map(Ok::<_, Infallible>))`.
- `raspi/service/assets/preview/frame_00.jpg .. frame_11.jpg` -- ~12 committed
  test-pattern JPEGs, generated offline on the Mac:
  `ffmpeg -f lavfi -i testsrc=size=640x480:rate=10 -frames:v 12 -q:v 8
  raspi/service/assets/preview/frame_%02d.jpg`. `testsrc` animates per frame, so
  cycling them shows real motion -- this proves the app's multipart parser delivers a
  sequence of distinct frames. ~200-350 KB embedded; no JPEG-encoder dependency.

**Modified files**
- `raspi/service/src/backend.rs` -- extend the trait:
  ```rust
  pub type FrameStream = Pin<Box<dyn tokio_stream::Stream<Item = bytes::Bytes> + Send>>;
  pub trait Backend: Send + Sync + 'static {
      fn recording(&self) -> bool;
      fn preview_frames(&self) -> FrameStream;   // raw JPEG frames; dropping the stream tears down the source
  }
  ```
  - `MockBackend::preview_frames`: `tokio::time::interval(100ms)` task pushing
    `Bytes::from_static(MOCK_FRAMES[i % N])` into an `mpsc::channel(4)`; return
    `ReceiverStream`. `recording() -> false` stays.
  - Add `RpicamBackend` (real camera) -- implemented in Phase 3; for Phase 1 it can be
    a stub that returns an empty/ending stream, or land its body now and only exercise
    it in Phase 3.
- `raspi/service/src/lib.rs` -- `mod preview; mod jpeg;` and add the route
  `.route("/v1/preview/live.mjpeg", get(preview::live_mjpeg))` before `.layer(...)`.
- `raspi/service/src/main.rs` -- backend selection:
  ```rust
  let state = match env::var("DANCAM_BACKEND").as_deref() {
      Ok("camera")        => AppState::new(resolve_boot_id(), RpicamBackend),
      Ok("mock") | Err(_) => AppState::new(resolve_boot_id(), MockBackend),   // default = mock
      Ok(other)           => { tracing::error!(backend = other, "unknown DANCAM_BACKEND"); std::process::exit(1); }
  };
  ```
  Local `just raspi-run` stays mock; the Pi deploy sets `DANCAM_BACKEND=camera`.
- `raspi/service/Cargo.toml` -- add tokio features `process, io-util, time, sync`;
  add `tokio-stream = "0.1"` and `bytes = "1"` (both pure Rust -> cross-build
  unaffected; `bytes` is already transitive). No `image`, no `async-stream`, no cargo
  feature flag -> `deploy.sh` and build flags unchanged.

**Tests (Mac-only, `just raspi-test`)** -- mirror `tests/health.rs`
(`tower::ServiceExt::oneshot` + `http_body_util::BodyExt`):
- `tests/preview.rs`: inject a `StubBackend` whose `preview_frames` is
  `tokio_stream::iter(vec![f0, f1])` (finite, so the body terminates and `collect()`
  returns).
  - `live_mjpeg_streams_multipart_frames_in_order` -- assert `200`, `Content-Type ==
    multipart/x-mixed-replace; boundary=dancamframe`, and the body equals exactly
    `frame_part(f0) ++ frame_part(f1)` (proves boundary, per-part headers,
    Content-Length, CRLF, order).
  - `live_mjpeg_carries_proto_headers` -- `x-dancam-proto: 1` + `x-dancam-boot-id`
    **and `cache-control: no-store`** on the streamed response (per F3 -- the wire
    contract lists `Cache-Control: no-store` and the Phase 3 check loads the stream in a
    browser, so assert it here rather than leave it an untested contract clause).
- `jpeg.rs` `#[cfg(test)]`: `splits_single_frame`, `splits_two_frames_in_one_push`,
  `reassembles_frame_split_across_pushes`, `retains_partial_trailing_frame`,
  `skips_garbage_before_first_soi`, `empty_buffer_yields_none`. (A nested-marker /
  embedded-thumbnail test is added here **only if** Phase 3 upgrades the splitter for
  nested `FF D8`/`FF D9` -- see Phase 3 / F3.)
- Existing `tests/health.rs` still passes (proto-header coverage holds for the new route).

**Self-verify (agent, no Dan action):** `just raspi-run`, then
`curl -s -D - -o /dev/null --max-time 2 http://127.0.0.1:8080/v1/preview/live.mjpeg`
(expect the multipart head), and load the URL in Chrome MCP to screenshot the moving
test pattern.

---

## Phase 2 -- App preview client + UI (Mac-only, no Dan action)

Owner code: `app/DanCam/DanCam/`. Matches existing patterns exactly (TEA `Store`/
`Effect`; struct-of-closures dependency with an injectable seam like `HealthClient`;
`nonisolated` types; typed `Equatable` error enum with `displayMessage`). The Xcode
project uses `objectVersion = 77` synchronized groups, so **new files in the right
folders are auto-included -- no `project.pbxproj` edits.**

**New files -- camera-API HTTP/`NWConnection` core** (`Networking/HTTP/`). This is the
camera-API foundation: in `fox` it serves **both** health (request/response) and
preview (streaming); later swoops `jet`/`lime` add SSE/Range on it.
- `InterfacePinning.swift` -- `enum InterfacePinning { case disabled; case wifi }`
  (the pinning seam as a value).
- `HTTPRequestEncoder.swift` -- pure: builds `GET <path> HTTP/1.1` + `Host:
  <host[:port]>` (non-default port included, so `10.42.0.1:8080`) + extra headers +
  `CRLFCRLF`, returning the request as `Data`. **Each plane's client calls the encoder
  itself and hands the resulting bytes to the byte-stream opener** (see `NWByteStream`),
  so callers -- not the socket layer -- own their headers: health adds `Connection:
  close`, the preview stream does not, and `lime` can add `Range` later. Building the
  request in the caller (not inside `NWByteStream`, per F2) is also what lets tests
  capture the exact request bytes (see `HealthClientTests`).
- `ContentType.swift` -- pure: `mediaType(from:)` and `boundary(from:)` (quoted/
  unquoted, case-insensitive key, extra params).
- `HTTPResponseHead.swift` -- `HTTPResponseHead` value + `HTTPResponseHeadParser`
  with incremental `append(Data) -> .needsMoreData | .complete(head, leftoverBody:)`,
  tolerating header bytes split across reads, with a max-size guard.
- `HTTPBodyDecoder.swift` -- **pure, incremental HTTP/1.1 body framing** (the single
  body-delimiter of the camera-API core; this is the F1 fix). `init(head:)` picks the
  mode from the parsed response head: `.chunked` (when `Transfer-Encoding: chunked`),
  `.contentLength(n)`, or `.closeDelimited` (no length, no chunked -> body ends at EOF).
  `mutating append(Data) -> [Data]` (plus an `isComplete` signal for the bounded modes)
  yields **decoded** body bytes: in chunked mode it strips each chunk-size line (hex
  size + optional `;ext`, `CRLF`, data, `CRLF`), handles the terminating `0`-chunk and
  any trailers (though the unbounded preview normally ends by connection close, not a
  `0`-chunk -- the producer treats either as a clean end), and is straddle-safe (a
  chunk-size line or a data run split across `append` calls); the length / close modes
  pass bytes through and track completion. Both the preview producer and
  `HTTPRequestResponse` feed their post-head bytes through this, so chunked vs.
  `Content-Length` is decided in one place. Not coupled to `NWConnection`; synchronously
  unit-tested.
- `NWByteStream.swift` -- **the only `NWConnection`-touching file** (not unit-tested):
  `open(url:, request: Data, pinning:) async throws -> AsyncThrowingStream<Data, Error>`.
  It is a **dumb pinned socket and knows no HTTP** (per F2): derives the `NWEndpoint`
  host/port from `url`, builds `NWParameters.tcp`, applies `requiredInterfaceType =
  .wifi` + `prohibitedInterfaceTypes = [.cellular]` only when `.wifi`; awaits `.ready`;
  sends the **caller-provided `request` bytes** (built by `HTTPRequestEncoder`); yields
  receive chunks; `onTermination { connection.cancel() }`. Moving request construction
  out to the callers is what lets each plane set its own headers and lets tests capture
  the exact request bytes.
- `HTTPRequestResponse.swift` -- the single-shot request/response helper the **health**
  plane uses: build the request with `HTTPRequestEncoder` (GET + `Host` + `Connection:
  close`), open the pinned socket via the byte-stream seam **passing both the URL and the
  request bytes**, feed `HTTPResponseHeadParser` to the head, then drive
  `HTTPBodyDecoder(head:)` to completion (so a `Content-Length` body -- and, defensively,
  a chunked or close-delimited one -- all go through the same body-framing code as
  preview); returns `(HTTPResponseHead, Data)`. No keep-alive / warm-socket pooling yet
  (deferred to `jet`); `fox` opens a connection per health fetch. The byte-stream open --
  now `(URL, Data) -> AsyncThrowingStream<Data, Error>` -- is the injectable seam for
  tests, so a test can capture the exact request bytes (mirrors `PreviewClient`).

**New files -- preview** (`Networking/Preview/`, `Features/Preview/`):
- `MultipartMJPEGParser.swift` -- **the crown jewel.** Pure, synchronously testable:
  `init(boundary:)`, `mutating append(Data) throws -> [Data]` (0/1/many JPEG frames).
  State machine: seek `--boundary` (drop preamble, straddle-guard the tail); parse
  part headers case-insensitively; body delimited by `Content-Length` when present
  else scan to `CRLF--boundary`; emit fresh `Data` copies; compact the buffer;
  max-part guard throws `PreviewError.malformedResponse`. Not coupled to NWConnection.
- `PreviewClient.swift` -- the dependency + `PreviewFrame` + `PreviewError`:
  ```swift
  nonisolated struct PreviewFrame: Equatable, Sendable, CustomStringConvertible {
      var sequence: Int; var jpeg: Data
      var description: String { "PreviewFrame(seq: \(sequence), \(jpeg.count) bytes)" } // compact TEA log
  }
  nonisolated enum PreviewError: Error, Equatable { // .connectionFailed/.http/.notMultipart/.missingBoundary/.malformedResponse
      var displayMessage: String { ... } // mirrors HealthError
  }
  nonisolated struct PreviewClient {
      var connect: () -> AsyncThrowingStream<PreviewFrame, Error>
      static func live(baseURL:, pinning:, openByteStream: @Sendable (URL, Data) async throws -> AsyncThrowingStream<Data, Error> = { ... }) -> PreviewClient
      static let noop = PreviewClient { AsyncThrowingStream { $0.finish() } }
  }
  ```
  `live` bakes the URL (`baseURL + "v1/preview/live.mjpeg"`) like `HealthClient.live`
  bakes its URL; `connect()` is no-arg and returns an `AsyncThrowingStream<PreviewFrame,
  Error>(bufferingPolicy: .bufferingNewest(1))`. **Producer ownership (explicit, the
  teardown-correctness seam):** inside the stream's build closure, start one producer
  `Task.detached` (the off-main parse context; the localized `@Sendable` the
  UI-architecture ADR reserved for `fox`) and **set `continuation.onTermination = { _ in
  producerTask.cancel() }`**, so any consumer-side cancellation deterministically
  cancels the producer. The producer builds the GET via `HTTPRequestEncoder` (no
  `Connection: close` -- this is a long-lived stream), awaits `openByteStream(previewURL,
  requestData)`, then drives `HTTPResponseHeadParser` -> validate (2xx, multipart,
  boundary) -> `HTTPBodyDecoder` (strip chunked transfer coding, per F1) ->
  `MultipartMJPEGParser` -> `yield(PreviewFrame(sequence:jpeg:))`, and on clean end /
  error / cancellation calls `continuation.finish(throwing:)`. Cancelling the producer
  ends its `for try await chunk in byteStream` loop, which fires the **injected byte
  stream's** `onTermination` -> `connection.cancel()`. `openByteStream` is the injectable
  seam for tests (mirrors `HealthClient.live`'s transport seam) and is exactly where the
  cancellation test observes teardown.
- `PreviewFeature.swift` -- TEA:
  - State: `idle | connecting | streaming(PreviewFrame) | stopped | failed(String)`.
  - Action: `onAppear/startTapped | onDisappear/stopTapped | frameReceived | streamFinished | streamFailed(PreviewError)`.
  - `reduce`: start -> `.connecting` + `.run(id:"preview", cancelInFlight:true)` that
    `for try await frame in dependencies.preview.connect()` and sends
    `.frameReceived`, ending in `.streamFinished`, with the **exact cancellation
    handling from `HealthFeature.reduce`** (catch `CancellationError` / `URLError
    .cancelled` -> return, never overwrite newer state). `frameReceived` ->
    `.streaming(frame)`; `streamFinished` -> `.stopped`; `streamFailed` ->
    `.failed(displayMessage)`; stop/disappear -> `.stopped` + `.cancel(id:"preview")`.
- `PreviewViewController.swift` -- programmatic UIKit. Renders into a `UIImageView`
  (`.scaleAspectFit`, black bg). **Decode off the main thread** with a serial
  `decodeQueue` + a drop-to-latest coalescer (one decode in flight; newest pending
  frame wins) via `UIImage(data:)?.byPreparingForDisplay()`; ignore stale
  `sequence`. Shows connecting/stopped/failed states; start on appear, stop +
  `.cancel` on disappear.

**Modified files**
- `App/AppConfiguration.swift` -- add `cameraAPIInterfacePinning: InterfacePinning`
  (camera-API-wide, **not** preview-only) resolved via the existing env -> Info.plist
  chain (`DANCAM_PIN_WIFI` / `DANCAMPinWiFi`). **Absent an explicit override, the
  default is derived from the resolved base-URL host:** loopback (`127.0.0.1` /
  `localhost`) -> `.disabled`; any other host (the `10.42.0.1` AP gateway,
  `dancam.local`) -> `.wifi`. So the real AP/device path defaults to `.wifi` (faithful
  to the ADR). The loopback mock dev loop gets `.disabled` automatically **only once
  `DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080` is set at run time** -- per
  `app/AGENTS.md` this value is entered in the scheme environment when running against
  `just raspi-run`; it is **not** pre-committed in the shared `DanCam.xcscheme` (which has
  no `EnvironmentVariables`). Implementor trap (per F2): with **no** override the base URL
  stays the `10.42.0.1` default, which derives to `.wifi`, so a Simulator run that forgets
  the loopback override pins `.wifi` to the AP gateway and fails to connect. The explicit
  env override also covers the simulator-against-LAN-IP edge.
- `Networking/HealthClient.swift` -- **move off `URLSession` onto the pinned core.**
  `live(baseURL:, pinning:, openByteStream:)` uses `HTTPRequestResponse`, so the health
  fetch is Wi-Fi-pinnable like every Pi connection; the injectable seam becomes the
  `(URL, Data)` byte-stream closure (mirroring `PreviewClient`), replacing the old
  `URLRequest` transport closure. The `HealthClient(fetch:)` struct-of-closures shape and
  `HealthError` are unchanged, so `HealthFeature` / `HealthFeatureTests` are unaffected;
  only `HealthClient.live` and `HealthClientTests` (which exercise `.live`) are rewritten
  to inject bytes.
- `App/AppDependencies.swift` -- add `var preview: PreviewClient`; `init(health:,
  preview: PreviewClient = .noop)` (default keeps existing `AppDependencies(health:)`
  test call sites compiling); `init(configuration:)` wires **both**
  `health = .live(baseURL:, pinning: configuration.cameraAPIInterfacePinning)` and
  `preview = .live(baseURL:, pinning: configuration.cameraAPIInterfacePinning)`.
- `Features/Health/HealthViewController.swift` -- store `dependencies`, add a "Live
  preview" button that pushes `PreviewViewController(dependencies:)` (Health stays the
  landing screen; the nav controller already exists).

**Frame-flow design (no flooding, decode off-main):** two drop-to-latest latches.
Latch 1: the `PreviewClient` stream's `.bufferingNewest(1)` bounds the store action
rate to what the main actor drains; `PreviewFrame` carries raw JPEG `Data` (cheap,
`Equatable`, test-constructible), not a decoded image. Latch 2: the VC decodes off-main
with the coalescer above. Together: store sees "as fast as main drains," screen
updates "as fast as decode completes," both always freshest, no backlog.

**Teardown chain (correctness):** `.onDisappear`/`.stopTapped` -> `.cancel(id:"preview")`
-> effect Task cancelled -> frame `for await` ends -> PreviewFrame stream `onTermination`
-> **producer `Task` cancelled** (the explicit `onTermination` wiring above) ->
producer's `for await` over the byte stream ends -> byte-stream `onTermination` ->
`connection.cancel()`. Leaving the screen deterministically closes the Pi socket and (on
the real backend) lets the Pi tear down `rpicam-vid`; no spurious actions. This chain is
specified at the producer boundary and covered by the `PreviewClientTests` cancellation
test below. Route the concurrency-sensitive code through `swift-concurrency-pro` (per
`app/AGENTS.md`).

**Info.plist / permissions:** no new keys. `NSAllowsLocalNetworking` +
`NSLocalNetworkUsageDescription` (both present) cover it. ATS does not gate raw
`NWConnection` TCP, so cleartext to the Pi is fine. On device, Local Network privacy
(TCC) prompts on the first `NWConnection` to the Pi -- now the **launch health fetch**,
not preview -- so the prompt appears early; denial -> the request/stream throws ->
`.failed`.

**Tests (Mac-only, `just app-test`; Swift Testing + `TestStore`)** -- support helpers
`MJPEGWireBuilder` (build head + parts as bytes, with an option to wrap the body in HTTP
chunked framing for the `HTTPBodyDecoder` / `PreviewClient` de-chunk tests) and
`AsyncStreamHelpers` (canned `AsyncThrowingStream`s). Suites:
- `MultipartMJPEGParserTests` (most important): single CL frame; boundary-scanned
  frame without CL; multiple frames per chunk; frame split across chunks; boundary
  delimiter split across chunks; preamble ignored; case-insensitive part headers; a CL
  body that contains the boundary bytes is read whole; first boundary with/without
  leading CRLF; large frame byte-exact across many small appends; oversized
  unterminated part throws.
- `HTTPResponseHeadParserTests`, `ContentTypeTests`, `HTTPRequestEncoderTests` -- head
  split across reads, leftover body, case-insensitive lookup, boundary extraction,
  Host-port rule, malformed-status throw.
- `HTTPBodyDecoderTests` (the F1 fix): a chunked body whose chunk boundary **splits a
  multipart boundary**; a chunk boundary that **splits a JPEG body**; a chunk-size line
  split across `append` calls; many small chunks reassembling to a byte-exact body; a
  `;chunk-ext` on the size line and a trailing header after the `0`-chunk are both
  ignored; `Content-Length` identity mode passes bytes through and reports complete at
  `n`; close-delimited mode passes through until EOF.
- `PreviewClientTests` (through the `(URL, Data)` `openByteStream` seam): emits frames
  with exact bytes + sequence; head/leftover straddle; **frames delivered inside HTTP
  chunked framing are de-chunked correctly** (per F1 -- the seam yields chunk-framed wire
  bytes and the producer must still emit the right JPEG frames); **a committed
  real-hyper-wire fixture** (the `curl --raw` capture of `just raspi-run`'s chunked MJPEG
  over the deterministic mock frames, from the Phase 2 self-verify) replayed through the
  seam decodes to the expected mock frame sequence in cycle order -- the single automated
  check that the full head-parser -> `HTTPBodyDecoder` -> multipart pipeline handles *real*
  hyper output, not just synthesized chunks; it asserts on decoded frames (byte-exact
  against the committed `frame_NN.jpg`), not chunk offsets, so it survives hyper version
  bumps (per F1); the captured request
  `Data` is the preview `GET /v1/preview/live.mjpeg` line + `Host` with **no**
  `Connection: close`; `.http(503)` on non-2xx; `.notMultipart`;
  `.missingBoundary`; byte-stream failure -> `.connectionFailed`;
  **`cancelTearsDownByteStream`** -- inject a byte stream whose `onTermination` signals a
  `confirmation`, yields the head + one frame, then stays open; start a Task consuming
  `connect()`, await the first `PreviewFrame`, then `task.cancel()`; assert the injected
  byte stream's `onTermination` fires (proves consumer cancellation reaches the producer
  boundary and would close the socket -- no leaked `NWConnection` / `rpicam-vid`).
- `HealthClientTests` (rewritten for the pinned core): inject the `(URL, Data)`
  byte-stream seam (replacing the old `URLRequest` transport), **capture the request
  `Data`**, and assert the exact `GET /v1/health HTTP/1.1` request line + `Host` +
  `Connection: close` (now observable because the caller builds the request, per F2), and
  that the `Content-Length` body (driven through `HTTPBodyDecoder`) decodes to
  `HealthResponse`; non-2xx -> `.http`; cancellation rethrown unwrapped (as today).
- `PreviewFeatureTests` (via `TestStore`, stub `PreviewClient`): onAppear ->
  connecting; frame -> streaming; multiple -> latest; finished -> stopped; failure ->
  failed; stopTapped cancels (then `finishEffects` + `expectNoReceivedActions`);
  cancellation emits no failure action. Mirrors `HealthFeatureTests`.
- `AppConfigurationTests` additions: pinning **defaults to `.wifi` for a non-loopback
  base URL and `.disabled` for a loopback base URL**; an explicit env override forces
  `.disabled` / `.wifi`; Info.plist override; env wins over Info.plist.

**Self-verify (agent):** `just app-test`, `just app-build`. Then, with `just raspi-run`
up, capture the real-hyper-wire de-chunk fixture **once** (per F1):
`curl --raw -s --max-time 1 http://127.0.0.1:8080/v1/preview/live.mjpeg -o
<app-test-assets>/preview-wire-chunked.bin` -- `--raw` preserves hyper's chunked transfer
coding (plain `curl` would de-chunk it); commit the file as the asset the new
`PreviewClientTests` real-wire case replays. (Re-capture if hyper is upgraded: the
committed fixture freezes the chunking at capture time, while the live Simulator run below
stays the real-time check.) Then boot a Simulator and run the app with
`DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080` against `just raspi-run` -- this
override is **required** (per F2): it makes the base URL loopback so pinning auto-resolves
to `.disabled`; without it the `10.42.0.1` default derives `.wifi` and the Simulator run
fails to reach the loopback mock. Navigate to Live preview and screenshot the moving test
pattern.

> **PAUSE #1 (optional, light):** show Dan the Simulator screenshot of the mock
> preview and confirm it looks right before moving to hardware. (Agent can self-verify
> via screenshot; this is a courtesy check, not a blocker.)

---

## Phase 3 -- Real Pi camera backend + home-LAN verify (INTERACTIVE)

Implements `RpicamBackend::preview_frames` as a **temporary preview-only camera mode**
(no recording in `fox`): spawn
`rpicam-vid -n -t 0 --codec mjpeg --width 640 --height 480 --framerate 10 --quality
50 --flush -o -` with `Stdio::piped()` + `kill_on_drop(true)`; read stdout into
`JpegSplitter`; push frames into an `mpsc::channel(4)`; a `tokio::select!` on
`tx.closed()` vs `stdout.read(...)` tears down promptly and `child.kill().await` reaps
rpicam on client disconnect (the explicit `kill().await` is the deterministic reap;
`kill_on_drop` is only the backstop if the task is cancelled before the select arm
runs). Per-connection subprocess (simplest correct for one client; runs only while
previewing -> good for thermals). A shared broadcaster for multi-client / instant-connect
is deferred to `jet`. **This drives the camera's main stream in MJPEG mode; it does NOT
validate the ADR's libcamera lores substream running concurrently with H.264
recording** -- that is `jet`'s risk, recorded in Phase 5.

> **PAUSE #2 -- ask Dan (hardware up):** "Power on the Pi with the IMX708 camera
> attached, and confirm it's on home Wi-Fi and reachable (`dancam.local`)." Wait for
> confirmation before proceeding.

After confirmation, the agent (over SSH; `deploy.sh` already uses the key
`~/.ssh/id_ed25519` to `<user>@dancam.local`) does as much as possible itself,
pausing only if SSH host-key trust or `sudo` prompts for input:
- Verify rpicam flags on the installed build: `ssh ... rpicam-vid --help` (confirm
  `--codec mjpeg`, `--framerate`, `--quality`, `-t 0`, `-o -`, `--flush`). Capture a
  sample (`rpicam-vid --codec mjpeg -t 1000 -o /tmp/x.mjpeg`) and check for nested
  `FF D8`/`FF D9` (embedded EXIF thumbnail). If present, upgrade `JpegSplitter` to
  "EOI followed by next SOI or stream end." **If that upgrade is made, adding a `jpeg.rs`
  regression test in the same change is a hard requirement** (per F3): a synthetic frame
  whose body embeds a nested `FF D8 ... FF D9` (a stand-in EXIF thumbnail) before the
  real trailing `FF D9`, asserting the splitter emits exactly **one** complete frame (it
  must not terminate early at the inner EOI), plus a variant that splits the read
  mid-inner-marker to prove straddle-safety. This keeps the most fragile parser behavior
  covered rather than landing a hardware-driven pivot untested. (Full JPEG
  marker-segment parsing -- walk APPn/SOF/SOS lengths to the true EOI -- is the fallback
  only if the SOI-follows heuristic proves insufficient; record it as a `jet` note if
  so.)
- Confirm `<user>` can open the camera under systemd: check `groups <user>` for `video`. If
  missing, add `SupplementaryGroups=video` to the unit (or `usermod -aG video <user>`) --
  an onboard-state change the README must capture.

> **PAUSE #3 -- ask Dan only if SSH/sudo prompts** for a host-key fingerprint or the
> sudo password during the steps above or the deploy below. Otherwise no pause.

- Update `raspi/dancam.service`: add `Environment=DANCAM_BACKEND=camera` under
  `[Service]` (and `SupplementaryGroups=video` if needed). Deploy with
  `just raspi-deploy` (cross-builds, ships binary + unit, restarts, curls health).
- De-risk the transport before involving the AP: with `DANCAM_BACKEND=camera`
  deployed, verify the **real** stream over home Wi-Fi from the Mac:
  `curl -s -D - -o /dev/null --max-time 2 http://dancam.local:8080/v1/preview/live.mjpeg`
  (expect the multipart head + proto headers), then load the URL in Chrome MCP on the
  Mac to see the live camera feed and screenshot it. Measure first-frame latency, CPU%,
  and SoC/sensor temp over SSH (informs the later `jet` spike; either HW or SW JPEG is
  acceptable for `fox`).

> **PAUSE #4 -- ask Dan (aim/focus):** show Dan the home-LAN screenshot of the real
> camera feed and ask whether focus/orientation/framing look right (he may want to
> physically aim the camera). Adjust and re-check as he directs.

---

## Phase 4 -- On-device live preview over the AP: the spike (INTERACTIVE)

This is the roadmap's flagged spike and the headline "it works!" moment. Because `fox`
routes **both** the landing health fetch and preview over the pinned `NWConnection`
(per F1), every Pi request in this test is Wi-Fi-pinned -- there is no stray unpinned
`URLSession` request to muddy the pinning result. The Mac must stay on home Wi-Fi (its
only internet path) -- only the **iPhone** joins the Pi AP (per the README warning). The
agent flips the Pi to AP mode over SSH (the Mac keeps its own internet; only the agent's
SSH-to-Pi drops), then coordinates Dan.

- Agent (over SSH, Pi still on home Wi-Fi): arm the home-Wi-Fi restore timer and bring
  up the AP, per README section 6:
  `sudo systemd-run --unit=dancam-restore-home-wifi --on-active=5min /usr/bin/nmcli
  connection up netplan-wlan0-<name>` then `sudo nmcli connection up dancam-ap`.
  (Use a fresh unit name if that one is loaded.) The agent notes it will lose SSH to
  the Pi at this point; the restore timer / power-cycle returns the Pi to home Wi-Fi.

> **PAUSE #5 -- ask Dan (join AP):** "On your iPhone, join Wi-Fi `dancam-dev` (Settings
> -> Wi-Fi), entering the dev WPA2 password. Tell me once it's connected." Wait.

- Device pinning is governed by `cameraAPIInterfacePinning`: with the AP base URL
  `http://10.42.0.1:8080` (non-loopback), it **defaults to `.wifi`**, so the pinned run
  needs no override and both the health fetch and preview are pinned. Recommended first
  pass: prove the path **unpinned** to isolate basic connectivity by setting
  `DANCAM_PIN_WIFI=0` in the run scheme
  (`app/DanCam/DanCam.xcodeproj/.../DanCam.xcscheme`), then remove that override (back to
  the `.wifi` default) to validate the spike. The agent edits the scheme and tells Dan
  which run is which.

> **PAUSE #6 -- ask Dan (run on device):** "In Xcode, select your iPhone as the run
> destination and Run (trust the developer cert if prompted). When the app launches,
> tap Live preview, and grant the Local Network permission prompt. Tell me what you
> see." Wait.

> **PAUSE #7 -- ask Dan (collect spike findings):** ask Dan to report, and record his
> answers:
> 1. Does live preview render -- is the camera feed visible and moving? (the "it
>    works!" moment)
> 2. Did the Local Network permission prompt appear, and did granting it work?
> 3. Did a captive "no internet" sheet (CNA) appear on joining/using the AP, and did
>    it interfere with the preview?
> 4. Approx fps / latency / smoothness? Any stutter or device heat?
> 5. With cellular ON (so pinning matters), does it still reach the Pi -- i.e. does
>    `requiredInterfaceType = .wifi` route correctly? (compare the pinned vs unpinned
>    run)
> 6. Any drops? Does Stop then Start recover the stream?
>
> If a run fails, the agent diagnoses from Dan's description (and Pi-side logs once the
> Pi is back on home Wi-Fi: `journalctl -u dancam`) and iterates, pausing again as
> needed. Do not loop more than a couple of attempts without checking in.

---

## Phase 5 -- Close-out (Mac-only)

- **Record spike findings** (working-stance: write down evidence/pivots in the same
  change). Append a dated note to the transport ADRs
  (`raspi/docs/design/02-...` and `app/docs/design/02-...`) capturing: pinning behavior
  across **both health and preview** (device vs simulator), captive-probe outcome,
  measured fps/latency, and any pivot forced (e.g. JPEG-splitter change for embedded
  thumbnails, per-connection vs broadcaster, or pinning disabled). If a cross-cutting
  decision changed, amend/supersede per the ADR convention (`just adr-check`).
- **Record the deferred lores / concurrent-preview risk for `jet`** (working-stance: a
  deviation not written down is the next trap). The `fox` camera backend is MJPEG on the
  main stream and does **not** prove the ADR's lores-substream-while-recording path. In
  the same change, note this explicitly: a dated line in the raspi transport ADR
  (preview section) and an annotation on the `jet` roadmap entry stating that
  preview-from-lores **concurrent with H.264 recording remains unvalidated** and is
  `jet`'s headline risk. Check off `fox` only with this recorded.
- **README:** add a "Live preview (`fox`)" section -- the new endpoint, the unit's
  `DANCAM_BACKEND=camera` (+ `video` group if added), the home-LAN and AP smoke tests
  (`curl` head + browser/`ffplay`), and the mock check (`just raspi-run` + the ffmpeg
  regen command). Update `raspi/AGENTS.md` if onboard state changed.
- **Justfile (optional):** `raspi-run-camera` convenience recipe
  (`DANCAM_BACKEND=camera cargo run`, Pi-only). `raspi-run`/`raspi-run-lan` stay mock.
- **Roadmap:** check the `fox` box in `docs/roadmap.md`.
- **Commits:** small, logical, Conventional Commits, **only when Dan asks** (e.g.
  `feat(raspi): serve MJPEG live preview`, `feat(app): live MJPEG preview over pinned
  NWConnection`, `docs: record fox spike findings + mark fox complete`). Suggest a
  topic branch off `master`.

---

## Interactive checkpoints (consolidated -- the implementor pauses and asks Dan)

1. **PAUSE #1** (Phase 2, light): confirm the Simulator mock-preview screenshot looks right.
2. **PAUSE #2** (Phase 3): power on the Pi with camera attached, on home Wi-Fi.
3. **PAUSE #3** (Phase 3, conditional): only if SSH host-key / sudo prompts for input.
4. **PAUSE #4** (Phase 3): confirm real camera focus/orientation/framing (physical aim).
5. **PAUSE #5** (Phase 4): join `dancam-dev` on the iPhone.
6. **PAUSE #6** (Phase 4): run on the physical device from Xcode, grant Local Network, open Live preview.
7. **PAUSE #7** (Phase 4): report the spike findings (the 6 questions above).

Each PAUSE means: stop implementing, ask Dan the specific question, wait for his
response, then continue. Phases 1-2 need no Dan action and can run to completion first.

## Verification (end to end)

- **Mac-only:** `just raspi-test` (incl. `tests/preview.rs` + `jpeg` units) and
  `just app-test` (incl. the multipart parser + feature suites) pass; `just
  raspi-build` and `just app-build` succeed; Simulator shows the mock moving preview.
- **Real Pi (home LAN):** `curl` returns the multipart head + proto headers; the
  camera feed renders in a Mac browser via Chrome MCP.
- **On device (AP):** live camera preview renders on the iPhone over `dancam-dev`;
  spike questions answered and recorded.

## Risks / unknowns resolved only on hardware (become the PAUSE checkpoints)

- rpicam-vid flag spelling on the installed build; embedded-thumbnail nested
  `FF D8/FF D9` in real frames (JPEG-splitter robustness).
- libcamera single-session reconnect reliability across rapid disconnect/reconnect.
- Camera access under systemd (`video` group).
- Wi-Fi interface pinning actually routing to the no-internet AP with cellular up
  (the spike); captive "no internet" CNA sheet behavior; Local Network prompt.
- Real fps / latency / decode + thermal load over 2.4 GHz (sets final res/fps/quality
  caps; 640x480/10fps/q50 are starting points, not commitments).
- HTTP chunked transfer framing from hyper on the real wire: `HTTPBodyDecoder` is
  unit-tested against synthesized chunked bytes **and** against a committed `curl --raw`
  fixture of real hyper output (Phase 2, per F1), so the Swift de-chunk path has an
  automated real-wire assertion. Its first *live* exercise is the Phase 2
  Simulator-against-`just raspi-run` run; the Phase 3 `curl`/Chrome check does **not**
  exercise the Swift decoder (both de-chunk internally -- that check only proves the Pi
  emits valid chunked MJPEG). Watch the Phase 4 device run for any residual de-chunk
  mismatch (a sign the committed fixture needs re-capturing against the current hyper).

## Out of scope (deferred)

`NEHotspotConfiguration` auto-join + `NWBrowser` discovery (`opal`); warm / pooled
keep-alive control socket + SSE (`jet`); resumable `Range` pull (`lime`); `GET
/v1/preview/snapshot`, preview settings, preview-while-recording + the lores /
concurrent-preview encode spike (`jet`+); Host-allowlist / token / TLS hardening
(later); any CarPlay surface (preview is iPhone-screen-only by principle). The
`HTTPRequestEncoder` + `HTTPResponseHeadParser` + `HTTPBodyDecoder` + `NWByteStream` +
`HTTPRequestResponse` core built here -- serving **both** health and preview in `fox`,
with the byte-stream seam shaped as `(endpoint URL, request Data) -> stream` so callers
own their headers and HTTP body framing lives in one decoder -- is the camera-API
foundation `jet`/`lime` reuse for SSE/Range (`fox` opens a connection per request; warm
keep-alive pooling is `jet`'s).

## Implementation notes

- Captured the real-hyper fixture with `curl --raw -i` rather than body-only `curl --raw`
  so the committed `preview-wire-chunked.bin` exercises the full response-head parser,
  HTTP chunk decoder, and multipart parser path.
- `PreviewViewController` uses a single in-flight `Task.detached` decode and awaits
  `UIImage.byPreparingForDisplay()` because the current SDK exposes that preparation API
  as async; the pending-frame latch still preserves drop-to-latest preview behavior.
- Removed the generic `Store.send` debug `String(describing:)` logging after it triggered
  Swift runtime traps under Swift Testing while formatting generic state/action values;
  the store behavior is still covered by the existing store tests.
- On the real Pi, `rpicam-vid --help` exposes the planned MJPEG flags and
  `rpicam-vid --list-cameras` sees the IMX708 at index 0. A 5-frame hardware sample had
  exactly 5 SOI and 5 EOI markers, so the existing `JpegSplitter` did not need the
  nested-marker upgrade.
- The `<user>` account already has the `video` group on the Pi, so the systemd unit only
  needed `DANCAM_BACKEND=camera`; no `SupplementaryGroups=video` change was required.
- `just raspi-deploy` works with `DANCAM_HOST=<user>@dancam.local`; deploying to the raw
  `192.168.1.160` IP failed host-key verification because that raw IP was not a trusted
  known-host entry.
- Home-LAN preview with the camera backend returned the expected multipart headers and
  real JPEG bytes. First response bytes arrived in about 226 ms; a 20-second curl
  received about 2.96 MB. The `rpicam-vid` child was visible under the `dancam` service
  while streaming and was reaped after client disconnect. SoC temperature sampled around
  38-39 C during these desk checks.
- The Phase 4 AP device run passed twice: first with `DANCAM_PIN_WIFI=0` to isolate
  basic AP connectivity, then with the override removed so the AP gateway default used
  Wi-Fi pinning. The pinned run loaded health and live preview over `dancam-dev` with
  cellular left on, no captive sheet observed, and Stop -> Start resumed after the
  decode-state reset fix.
- Phase 5 records that `fox` proved the MJPEG wire path and pinned AP routing, but not
  preview-from-lores concurrent with 1080p30 H.264 recording; that remains `jet`'s
  headline risk.
