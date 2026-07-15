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

Decisions here are provisional until captured in the owning living design page; treat
them as the current direction, not settled law.

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
  CarPlay template framework (Driving Task app category) for the on-screen panel. See
  the [CarPlay boundary](../docs/design/app/carplay.md).

When reviewing or writing Swift here, the repo has helper skills: `swiftui-pro`,
`swift-concurrency-pro`, `swift-testing-pro`, `swiftdata-pro`. The load-bearing
skills for the current app architecture are `swift-concurrency-pro` (effect-runtime
correctness) and `swift-testing-pro` (TestStore + reducer tests). `swiftui-pro` is not
used because the app is UIKit. `swiftdata-pro` applies only if/when SwiftData
persistence lands. Prefer Swift Testing over XCTest for new unit tests.

## Structure (planned)

```
app/
  AGENTS.md
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
- [App sharing](../docs/design/app/sharing.md) -- read when changing clip or incident
  export naming, clone staging, share progress and cancellation, activity-sheet
  presentation, raw-URL fallback, or temporary-artifact cleanup.
- [App capacity](../docs/design/app/capacity.md) -- read when changing finalized-clip
  sampling, retention estimation, epoch resets, recorder-writable capacity, or the
  Settings storage section.
- [CarPlay boundary](../docs/design/app/carplay.md) -- read before adding App Intents,
  CarPlay scene automation, Driving Task templates, or car-screen alerts.
- [App logging](../docs/design/app/logging.md) -- read when adding log categories or
  emit sites, changing diagnostic privacy or levels, root transition logging, or
  current-process log export.
- [Transport boundary](../docs/design/boundary/transport.md) -- read when changing
  Pi routes, HTTP framing, SSE, preview, clip pull, Wi-Fi pinning, or link trust.
