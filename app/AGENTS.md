# dancam -- iPhone app

The iPhone app is the product. It is the primary UI and the "brains" of the system:
it connects to the camera unit (`../raspi/`) over Wi-Fi, lets the user preview,
browse, and pull footage, manages settings, handles incidents, and hosts the
CarPlay integration.

Read the root [`../AGENTS.md`](../AGENTS.md) first for the whole-system picture and the
cross-cutting principles. This file covers the app side; its sibling, the camera unit,
is documented in [`../raspi/AGENTS.md`](../raspi/AGENTS.md).

## Responsibilities

- **Connect to the camera unit** over its Wi-Fi access point (2.4 GHz). Discover it,
  join/associate, and talk to its control + media API.
- **Live preview** of the camera, on the iPhone screen, when it is safe/relevant.
  (Never on the CarPlay screen -- see the CarPlay ADR.)
- **Browse and pull clips** on demand. The Pi holds all footage; the app pulls
  selected clips, not the entire buffer. Bulk mirroring over 2.4 GHz is a non-goal.
- **Incident handling** -- mark/lock an incident so the Pi protects that clip from
  the ring buffer overwriting it; review and export incidents.
- **Settings / control** -- start/stop recording, resolution, retention, time sync.
- **CarPlay surface** -- voice control, auto start/stop, status, alerts.
- **Time provenance** -- the Pi has no real-time clock. The app is a trusted time
  source: push accurate wall-clock time to the Pi on connect (the Pi may also use
  GPS). Clips need correct timestamps for them to be useful as evidence.

## Tech (intended)

Decisions here are provisional until captured as an ADR; treat as the current
direction, not settled law.

- **Language/UI:** Swift, UIKit (programmatic, no storyboards). Target current iOS.
- **Architecture:** bespoke minimal TEA -- pure reducers, a `@MainActor` store,
  struct-of-closures dependencies, and a hand-written `TestStore`; zero third-party
  architecture dependencies. See
  `docs/design/03-2026-06-24-app-ui-architecture.md`.
- **Local persistence:** SwiftData for clip metadata / incident records / settings
  (provisional; UI-agnostic, decided separately). Footage itself is pulled on demand
  and stored as files, not in the store.
- **Playback:** AVFoundation / AVKit.
- **Networking to the Pi:** the Network framework (`NWConnection`/`NWBrowser`) for
  discovery and control; HTTP for the clip API; MJPEG over HTTP for low-res live
  preview. The transport is decided -- see the app<->Pi transport ADR
  (`docs/design/02-2026-06-22-app-pi-transport-and-api.md`) and the canonical wire
  contract it delegates to in `raspi/`. (HLS-for-preview and raw-stream options were
  considered and rejected there.)
- **CarPlay:** the App Intents framework for voice ("save that clip") and the
  CarPlay template framework (Driving Task app category) for the on-screen panel.

When reviewing or writing Swift here, the repo has helper skills: `swiftui-pro`,
`swift-concurrency-pro`, `swift-testing-pro`, `swiftdata-pro`. The load-bearing
skills for the current app architecture are `swift-concurrency-pro` (effect-runtime
correctness) and `swift-testing-pro` (TestStore + reducer tests). `swiftui-pro` is not
used because the app is UIKit. `swiftdata-pro` applies only if/when SwiftData
persistence lands. Prefer Swift Testing over XCTest for new unit tests.

## Logging

App diagnostics use Apple unified logging through the app-owned `Log` namespace.

- Subsystem: `com.danneu.dancam`.
- Categories double as greppable tags (`reducer`, `pull`, `remux`, `playback`, `nav`,
  and media parser categories).
- Levels: `.error` for failures, `.notice` for state transitions and pipeline
  boundaries that must reach exports, `.info` for live detail, and `.debug` for hot
  paths and no-op transitions. `.notice` and higher are the export-critical levels;
  `.info` and `.debug` are live/in-memory diagnostics and can be absent from in-app
  log exports.
- Diagnostic values default to `privacy: .public`; opt specific values back to
  private only when they are actually sensitive.
- Use `clip_id=<Int>` as the correlation field for clip pull, remux, playback, and
  cache-adjacent logs.

## CarPlay

The surprising constraint: third-party CarPlay apps **cannot render a live camera
feed** (no arbitrary-video template), so the live preview stays on the iPhone and
CarPlay is voice + status + control only. The ranked integration plan and entitlement
path are in `docs/design/01-2026-06-22-carplay-integration-surface.md`.

## Structure (planned)

```
app/
  AGENTS.md
  docs/design/        <- app-side ADRs
  DanCam/             <- Xcode project and app/test targets
```

## Build / run

The Xcode project is `DanCam`, with scheme `DanCam`.

- Build for simulator: `just app-build`.
- Run unit tests: `just app-test` (Swift Testing unit suites only; UI tests are left in
  the project but excluded from this recipe).
- Interactive run: open `app/DanCam/DanCam.xcodeproj` in Xcode and Cmd-R into an iOS
  26.5 simulator. The live app defaults to the Pi AP gateway
  `http://10.42.0.1:8080`; set `DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080` in
  the scheme environment when running against the local mock Pi from `just raspi-mock`.

CarPlay work needs the CarPlay simulator (Xcode > I/O > External Displays > CarPlay)
and, for device testing, the CarPlay entitlement from Apple.

## Design decisions (ADRs)

See the root `AGENTS.md` for the ADR convention. App-side ADRs live in
`docs/design/`. Current:

- `01-2026-06-22-carplay-integration-surface.md` -- what we expose to CarPlay and why.
- `02-2026-06-22-app-pi-transport-and-api.md` -- the app-side obligations for talking to
  the Pi (NEHotspotConfiguration join, NWConnection Wi-Fi pinning, the hand-rolled
  per-plane HTTP/1.1 client, raw clip pull feeding local cached MP4 playback, App
  Intents incident-lock). The
  wire contract itself is delegated to the raspi-side ADR of the same name.
- `03-2026-06-24-app-ui-architecture.md` -- UIKit programmatic UI and the bespoke
  minimal TEA core used by the app.
- `04-2026-06-26-connection-monitor-and-indicator.md` -- superseded by ADR 05; recorded
  the app-scoped `/v1/status` monitor, ambient navigation-bar connection pill,
  asymmetric disconnect debounce, and foreground/reconnect recovery hook.
- `05-2026-06-26-app-shell-status-strip.md` -- superseded by ADR 06; kept the
  app-scoped connection monitor and replaced the navigation-bar pill with a persistent
  shell-owned status strip.
- `06-2026-06-26-domain-root-store-and-scoped-observation.md` -- domain root store,
  scoped observation, and the live connection monitor head inherited from ADR 05.
- `07-2026-06-26-on-device-clip-remux-playback.md` -- remux pulled TS clips into
  on-device MP4 for durable playback.
- `08-2026-06-27-progressive-fmp4-clip-playback.md` -- progressively serve fMP4
  fragments over loopback while a clip pull is still running; superseded by ADR 13.
- `09-2026-06-29-connection-liveness-timeouts.md` -- bound transport connect and
  monitor status-fetch liveness so stale "Connected" cannot hang indefinitely.
- `10-2026-06-29-event-folded-state-machines.md` -- fold the ordered Pi event stream
  into root app state and use SSE heartbeat timeout as connection truth.
- `11-2026-06-30-receive-idle-deadline.md` -- bound post-connect receive idleness in
  the shared `NWByteStream` transport.
- `12-2026-06-30-bounded-resilient-clip-pull.md` -- make clip pull retry by byte
  progress, bound no-progress and runaway reconnects, and surface typed failures.
- `13-2026-07-01-durable-clip-cache.md` -- delete the progressive loopback player and
  make cached fast-start MP4 the sole clip playback and future export artifact.
- `14-2026-07-01-structured-logging-and-export.md` -- use Apple unified logging as the
  app's diagnostic stream and expose current-process log export from the Debug screen.
- `15-2026-07-01-clip-export-share.md` -- system share sheet over the cached MP4.
