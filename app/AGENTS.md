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
  per-plane HTTP/1.1 client, loopback-HLS playback, App Intents incident-lock). The
  wire contract itself is delegated to the raspi-side ADR of the same name.
- `03-2026-06-24-app-ui-architecture.md` -- UIKit programmatic UI and the bespoke
  minimal TEA core used by the app.
