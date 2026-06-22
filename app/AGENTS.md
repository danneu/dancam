# dancam -- iPhone app

The iPhone app is the product. It is the primary UI and the "brains" of the system:
it connects to the camera unit (`../raspi/`) over Wi-Fi, lets the user preview,
browse, and pull footage, manages settings, handles incidents, and hosts the
CarPlay integration.

Read the root `../AGENTS.md` first for the whole-system picture and the cross-cutting
principles. This file covers the app side specifically.

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

- **Language/UI:** Swift, SwiftUI. Target current iOS.
- **Local persistence:** SwiftData for clip metadata / incident records / settings
  (footage itself is pulled on demand and stored as files, not in the store).
- **Playback:** AVFoundation / AVKit.
- **Networking to the Pi:** the Network framework (`NWConnection`/`NWBrowser`) for
  discovery and control; HTTP for the clip API; a low-latency path (e.g. HLS or a
  raw stream) for preview. The transport is an open design question -- write an ADR.
- **CarPlay:** the App Intents framework for voice ("save that clip") and the
  CarPlay template framework (Driving Task app category) for the on-screen panel.

When reviewing or writing Swift here, the repo has helper skills: `swiftui-pro`,
`swift-concurrency-pro`, `swift-testing-pro`, `swiftdata-pro`. Prefer Swift Testing
over XCTest for new tests.

## CarPlay -- the one rule that surprises people

Third-party CarPlay apps **cannot render a live camera feed** (no arbitrary-video
template exists). The live preview stays on the iPhone. CarPlay gets a voice +
status + control surface only. The ranked integration plan and the entitlement
path are in:

- `docs/design/2026-06-22-carplay-integration-surface.md`

## Structure (planned)

```
app/
  AGENTS.md
  docs/design/        <- app-side ADRs
  (Xcode project / Swift package to be added)
```

## Build / run

Not yet established. When the Xcode project lands, document the exact build/run/test
commands here (scheme names, simulator vs device, how to point the app at a real Pi
vs a mock). CarPlay work needs the CarPlay simulator (Xcode > I/O > External Displays
> CarPlay) and, for device testing, the CarPlay entitlement from Apple.

## Design decisions (ADRs)

See the root `AGENTS.md` for the ADR convention. App-side ADRs live in
`docs/design/`. Current:

- `2026-06-22-carplay-integration-surface.md` -- what we expose to CarPlay and why.
