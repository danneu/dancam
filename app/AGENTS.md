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
- **Incident handling** -- capture a mark while connected and recording, pull its
  covering segments into permanent phone storage, then review, share, and delete
  the phone-owned incident.
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
  architecture dependencies. See the
  [app architecture](../docs/design/app/architecture.md) page.
- **Local persistence:** filesystem-backed Application Support directories for
  phone-owned incident records and footage; SwiftData remains provisional for any
  future clip metadata or settings store. See the
  [incident design](../docs/design/app/incidents.md).
- **Playback:** AVFoundation / AVKit.
- **Networking to the Pi:** the Network framework (`NWConnection`/`NWBrowser`) for
  discovery and control; HTTP for the clip API; MJPEG over HTTP for low-res live
  preview. The [transport boundary](../docs/design/boundary/transport.md) owns the
  wire contract and app-side connection obligations. (HLS-for-preview and raw-stream
  options were considered and rejected there.)
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
- Categories double as greppable tags (`reducer`, `pull`, `remux`, `playback`, `share`,
  `nav`, and media parser categories).
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

## Design pages

- [App architecture](../docs/design/app/architecture.md) -- read when changing the
  UIKit shell, Store/Effect runtime, root reducer composition, event folding,
  observation, view-state projection, or diffable identity rules.
- [App browsing](../docs/design/app/browsing.md) -- read when changing top-level tabs,
  Home recording cards, recording attribution or detail, browse pagination, or Debug
  telemetry presentation.
- [App connection](../docs/design/app/connection.md) -- read when changing event-stream
  liveness, network deadlines, reconnect lifecycle, freshness-typed UI, visible-screen
  recovery, or the shell status strip.
- [App clips](../docs/design/app/clips.md) -- read when changing resumable clip pull,
  TS-to-MP4 remux, durable clip caching, viewer playback lifecycle, or thumbnails.
- [App incidents](../docs/design/app/incidents.md) -- read when changing incident
  capture, post-roll lockout, coverage planning, durable evidence, reconciliation,
  notifications, or the Incidents tab.
- [Transport boundary](../docs/design/boundary/transport.md) -- read when changing
  Pi routes, HTTP framing, SSE, preview, clip pull, Wi-Fi pinning, or link trust.

During the migration, the remaining app ADRs under `docs/design/` stay authoritative
for subsystems that do not yet have a living page:

- `01-2026-06-22-carplay-integration-surface.md` -- what we expose to CarPlay and why.
- `14-2026-07-01-structured-logging-and-export.md` -- use Apple unified logging as the
  app's diagnostic stream and expose current-process log export from the Debug screen.
- `15-2026-07-01-clip-export-share.md` -- superseded by ADR 25; system share sheet over
  the cached MP4.
- `25-2026-07-10-clip-share-raw-file-url.md` -- superseded by ADR 30; removed the unnecessary
  `UIActivityItemSource` wrapper that crashed during share discovery and return to the
  device-verified raw MP4 file URL.
- `28-2026-07-14-estimated-recording-capacity.md` -- estimate footage retention from
  freshly finalized clips and Pi-provided recorder-writable capacity, scoped to one
  live connection epoch and presented in Settings.
- `30-2026-07-15-responsive-video-share-preparation.md` -- prepare cached clips and
  incident segments off the main actor with cancellable `clonefile` staging, inline
  progress, raw-URL fallback, and shared presentation cleanup.
