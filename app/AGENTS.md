# dancam -- iPhone app

The iPhone app is the product and the system's brains. It connects to the Pi over
Wi-Fi, previews and browses footage, manages control and settings, owns incidents,
and hosts the CarPlay integration.

Read the root [`../AGENTS.md`](../AGENTS.md) first. This file owns app-side stance,
constraints, and commands; [`../raspi/AGENTS.md`](../raspi/AGENTS.md) owns the Pi.

## Responsibilities

- Connect to the camera unit over its 2.4 GHz access point and use its versioned
  control and media API.
- Show live preview on the iPhone only; CarPlay never displays video.
- Browse and pull selected clips on demand. The Pi owns the full footage ring; bulk
  mirroring is a non-goal.
- Capture incident marks while connected and recording, pull the covering window
  into permanent phone storage, and own review, sharing, and deletion.
- Own user-facing settings and recording control.
- Provide CarPlay voice control, automatic start/stop, status, and alerts.
- Push trustworthy wall-clock time to the RTC-less Pi so clips remain useful as
  evidence.

## Tech

- **Language/UI:** Swift with programmatic UIKit and no storyboards; target current iOS.
- **Architecture:** a minimal bespoke TEA with pure reducers, a `@MainActor` store,
  struct-of-closures dependencies, and a hand-written TestStore. See
  [app architecture](../docs/design/app/architecture.md).
- **Persistence:** filesystem-backed Application Support storage for phone-owned
  incident records and footage. SwiftData remains provisional for future metadata or
  settings. See [incidents](../docs/design/app/incidents.md).
- **Playback:** AVFoundation and AVKit.
- **Pi networking:** Network.framework for pinned transport, HTTP for API and clips,
  and MJPEG over HTTP for preview. See the
  [transport boundary](../docs/design/boundary/transport.md).
- **CarPlay:** App Intents for voice and Driving Task templates for the status/control
  surface. See the [CarPlay boundary](../docs/design/app/carplay.md).

When reviewing or writing Swift here, the repo has helper skills:
`swiftui-pro`, `swift-concurrency-pro`, `swift-testing-pro`, and `swiftdata-pro`.
The load-bearing skills for this UIKit architecture are `swift-concurrency-pro` for
effect-runtime correctness and `swift-testing-pro` for TestStore and reducer tests.
Use `swiftdata-pro` only if SwiftData lands; prefer Swift Testing over XCTest for new
unit tests.

## Build / run

The Xcode project is `app/DanCam/DanCam.xcodeproj`, scheme `DanCam`.

- `just app-build` -- build for the iOS simulator.
- `just app-test` -- run Swift Testing unit suites; UI tests remain excluded.
- Open the project in Xcode and Cmd-R into an iOS 26.5 simulator for interactive use.
  The app defaults to `http://10.42.0.1:8080`; set
  `DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080` for `just raspi-mock`.
- CarPlay work uses Xcode > I/O > External Displays > CarPlay. Device testing also
  requires Apple's CarPlay entitlement.

## Design pages

- [App architecture](../docs/design/app/architecture.md) -- UIKit shell,
  Store/Effect runtime, reducer composition, event folding, observation, projection,
  and diffable identity.
- [App browsing](../docs/design/app/browsing.md) -- tabs, Home recording cards,
  recording attribution and detail, pagination, and Debug telemetry.
- [App connection](../docs/design/app/connection.md) -- SSE liveness, deadlines,
  reconnect lifecycle, freshness, recovery, and the shell status strip.
- [App clips](../docs/design/app/clips.md) -- resumable pull, TS-to-MP4 remux, cache,
  playback lifecycle, and thumbnails.
- [App incidents](../docs/design/app/incidents.md) -- capture, post-roll, coverage,
  durable evidence, reconciliation, notifications, and Incidents UI.
- [App sharing](../docs/design/app/sharing.md) -- export naming, staging, progress,
  cancellation, activity sheet, fallback, and cleanup.
- [App capacity](../docs/design/app/capacity.md) -- clip sampling, retention estimate,
  epoch resets, writable capacity, and Settings storage UI.
- [CarPlay boundary](../docs/design/app/carplay.md) -- App Intents, scene automation,
  Driving Task templates, and car-screen alerts.
- [App logging](../docs/design/app/logging.md) -- categories, emit sites, privacy,
  levels, transition logging, and current-process export.
- [Transport boundary](../docs/design/boundary/transport.md) -- routes, HTTP and SSE,
  preview, pulls, Wi-Fi pinning, and trust.
