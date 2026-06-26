# Plan: Polish the DanCam home screen (Camera-paradigm UI)

## Context

The home screen (`HomeViewController`) currently reads like an engineering debug
panel, not a product. Three things give it away:

- Status is a raw `key: value` dump (`Camera: running`, `SoC: --`,
  `Storage: -- bytes`, `Memory: -- bytes`) -- jargon and raw byte counts no driver
  cares about.
- The primary action is a plain blue text-link button (`Start Recording`).
- The live preview -- the most important element of a dashcam's "brains" UI -- is
  sandwiched between the debug text and the button, in a flat un-styled box.

The live preview is the product. This change rearranges the screen around the
**Camera-app paradigm**: preview becomes a rounded hero, recording gets a
prominent labeled control, the screen shows *reassurance* (connection, storage
left) instead of telemetry, and the raw telemetry (exact temps, bytes, memory,
swap) moves to the Health/Debug screen where it belongs.

Decisions already locked with the user:
- Record control: **labeled prominent red capsule** ("Record" / "Stop" / busy).
- Home status: **minimal** -- pills over the preview + one storage chip; temp pill
  only on warning.
- Preview: **rounded hero card** (keeps record button + recent clips on-screen).

This is a **view-layer** change only. No reducers, features, networking, or models
change. All existing reducer/feature tests stay green.

## Target layout

```
 DanCam                                  [gauge]   <- large title + SF Symbol bar button
 +-------------------------------------------+
 | (* Live)                        (o REC)   |    <- pills overlaid on preview corners
 |           preview (rounded hero)          |    <- native ratio, dark fill, continuous
 |                                           |       corner radius, masked
 +-------------------------------------------+
   [====____]  12 GB free                        <- storage chip: thin bar + free text
   (! 52 C camera)                               <- temp warning pill, ONLY when hot
   (x Can't reach camera)                        <- error pill, ONLY on failure/offline
                ( (rec) Record )                 <- labeled prominent capsule, centered
   Recent clips                                  <- section header
   seg_00001.ts            2.3 MB                 <- polished cells (UIListContentConfiguration)
   seg_00002.ts            2.1 MB
   ( film "No clips yet" )                       <- centered empty state when none
```

The screen keeps its current non-scrolling frame: a fixed top cluster (preview +
chips + record button) and a clips table that fills the remaining height and
scrolls internally. No outer scroll view is introduced.

## New shared building blocks (new files)

The Xcode project uses file-system-synchronized groups
(`PBXFileSystemSynchronizedRootGroup` in `app/DanCam/DanCam.xcodeproj/project.pbxproj`),
so files added under the source tree are auto-included in the target -- no manual
`.pbxproj` edits. (Fallback if a file isn't picked up: add it to the DanCam target
in Xcode.)

The app has **no** existing reusable views, design tokens, or formatters today
(all inline). Add a small, focused set:

1. `app/DanCam/DanCam/Support/Formatters.swift`
   - Shared, structure-insensitive presentation helpers (pure functions):
     - `storageDisplay(_ storage: Storage) -> (freeText: String, usedFraction: Double)`
       using `ByteCountFormatter` (style `.file`) for free bytes; fraction = used/total.
       Free bytes are **clamped** against `UInt64` underflow:
       `let free = total >= used ? total - used : 0` -- a transient `used > total`
       status must not render a ~16-exabyte "free". The fraction guards 0-total (-> 0).
     - `byteSize(_ bytes: UInt64) -> String` (clip sizes, Health storage).
     - `temperature(_ celsius: Double, precise: Bool = false) -> String` -- keep ASCII
       "C". `precise: false` rounds for the glance pill ("52 C"); `precise: true` keeps
       one decimal ("52.3 C") for the Health rows, which are the precision/debug surface
       and must not regress below the current `%.1f C` fidelity.
     - `sensorWarning(for sensor: Double?) -> TempWarning?` where `TempWarning` is
       `.warn`/`.critical`. **Sensor-only** by design: the camera sensor is the
       documented weak link (rated ~50 C; see `raspi/AGENTS.md`), and scoping the Home
       pill to the sensor means the value the pill shows always matches the source that
       triggered it -- no "which temp?" ambiguity, and never an empty "-- C camera".
       Thresholds as named constants: `>= 50` -> warn, `>= 55` -> critical. Returns nil
       for a nil sensor reading. SoC temperature is not a Home pill; it still appears as
       a raw row on Health.
   - Replaces the inline `formatTemp` / `formatStorage` / `formatMemory` in
     `HomeViewController` (those are deleted).

2. `app/DanCam/DanCam/Views/StatusPillView.swift`
   - A small capsule view: optional colored status dot + caption label, directional
     content insets, `cornerCurve = .continuous`, two background styles --
     `.material` (`.ultraThinMaterial` via `UIVisualEffectView`, for overlay pills on
     the preview) and `.tinted(UIColor)` (for the temp/error pills below).
   - Dynamic Type via `preferredFont(forTextStyle: .caption1)` +
     `adjustsFontForContentSizeCategory`. `isHidden`-driven show/hide.
   - Used for: preview connection pill, REC pill, temp warning pill, error pill.

3. `app/DanCam/DanCam/Views/RecordButton.swift`
   - `UIButton` subclass that owns its look via `UIButton.Configuration.filled()`
     (`cornerStyle = .capsule`, `baseBackgroundColor = .systemRed`). A single
     `apply(_ state: RecordingFeature.State)` method drives the labeled-capsule
     visuals through a **pure** mapping function (extracted, testable):
     `RecordButtonStyle.from(_:) -> (title, systemImage, isEnabled, showsActivityIndicator)`:
     - `.unknown` -> "Record", `record.circle`, disabled, no spinner
     - `.idle`, `.failed` -> "Record", `record.circle`, enabled
     - `.starting` -> "Starting", spinner, disabled
     - `.recording` -> "Stop", `stop.fill`, enabled
     - `.stopping` -> "Stopping", spinner, disabled
   - `configuration.showsActivityIndicator` handles the busy states natively.
   - Accessibility label tracks intent ("Start recording" / "Stop recording").

These three shared files -- plus the Health-scoped `HealthTelemetry.swift`
(introduced in the Health section below) -- are the only new types. Everything else
is edits to existing view controllers.

## Edits to existing files

### `app/DanCam/DanCam/Features/Home/HomeViewController.swift`

The largest change. Restructure `configureViews` and the `render*` methods:

- **Nav bar**: replace the `Debug` text `UIBarButtonItem` (in `viewDidLoad`) with an
  SF Symbol button (image `gauge.medium` or `chart.bar`, accessibilityLabel
  "Status detail") that still calls `debugTapped`. Keep the large title "DanCam".
- **Delete** `cameraLabel`, `tempLabel`, `storageLabel`, `memLabel`, the
  `statusStack`, and the inline `formatTemp`/`formatStorage`/`formatMemory`.
  `statusErrorLabel` is replaced by an error `StatusPillView`.
- **Preview hero**: in `configureViews`, give `previewViewController.view` a
  `layer.cornerRadius` (~16), `cornerCurve = .continuous`, `masksToBounds = true`,
  dark fill. Keep the existing 0.75 aspect constraint (native-ish ratio).
- **Overlay REC pill**: add a `StatusPillView` (red dot + "REC", `.material`) as a
  subview of the preview view, pinned top-trailing with margin. Visibility driven by
  `renderRecording` (visible for `.starting`/`.recording`/`.stopping`). This replaces
  the current `recDot`/`recLabel`/`recIndicator` stack (deleted), and supersedes
  `setRecordingIndicatorVisible`.
- **Below-preview cluster** (vertical stack): a storage chip view (thin
  `UIProgressView` or a custom bar + free-text label, fed by
  `Formatters.storageDisplay`), a temp-warning `StatusPillView`, and an error
  `StatusPillView` -- the last two hidden by default.
- **Record control**: replace `recordButton` (`UIButton(type: .system)`) +
  `recordingControls` stack with a single `RecordButton`, centered, hugging content.
  `recordTapped` keeps its existing start/stop dispatch logic unchanged.
- **`renderStatus(_:)`** rework:
  - `.idle`/`.loading`: storage chip placeholder (dimmed / "--"); pills hidden.
  - `.loaded(response)`: storage chip from `response.storage`; temp pill visible iff
    `Formatters.sensorWarning(for: response.tempC.sensor) != nil`, with text
    `"\(Formatters.temperature(sensor)) camera"` and a warn/critical tint -- the sensor
    value is guaranteed non-nil whenever the pill shows, so the text is never empty or
    a below-threshold false alarm. Error pill visible iff
    `response.cameraState == .offline` ("Camera offline"). `.starting` and `.restarting`
    are **intentionally not** surfaced as an error pill: they are transient
    camera-process churn that the preview pill ("Connecting" / "Preview offline")
    already reflects, and the locked minimal-home decision keeps that churn off the home
    screen -- only `.offline` (the stuck state) lights the error pill.
  - `.failed(message)`: error pill visible ("Can't reach camera"); storage dimmed.
- **`renderRecording(_:)`**: keep state machine + `HomeCoordination.shouldRefreshClips`
  call; swap button title/enable logic for `recordButton.apply(state)` and REC-pill
  visibility.
- **Recent clips**: add a "Recent clips" header label above `clipsTableView`.
  Cells use `UIListContentConfiguration` (text = `seg_%05d.ts`, secondaryText =
  `Formatters.byteSize(clip.bytes)`) instead of the manual `cell.textLabel`.
  Add an **empty state**: a centered SF Symbol (`film`) + "No clips yet" caption set
  as the table's `backgroundView`, shown when `clips.isEmpty` in `renderClips`.

### `app/DanCam/DanCam/Features/Preview/PreviewViewController.swift`

- Replace the plain `statusLabel` (the "Streaming" text) with a `StatusPillView`
  pinned top-leading, reflecting `PreviewFeature.State` in `render`:
  `connecting` -> "Connecting" (amber dot), `streaming` -> "Live" (green dot),
  `stopped` -> hidden/"Paused", `failed` -> "Preview offline" (red dot), `idle` ->
  hidden. The MJPEG decode pipeline (`PreviewDecodeState`, `enqueueDecode`, etc.) is
  untouched.

### `app/DanCam/DanCam/Features/Health/HealthViewController.swift` (+ telemetry move)

The Health stack is currently top-anchored with **no bottom anchor and no scroll
container** (`HealthViewController#configureViews`). It already holds ~6 rows; the
telemetry block adds ~8 more (temps, storage, memory, swap), which will clip below
the fold on small screens or at large Dynamic Type. So:

- **Make Health scrollable first** (prerequisite, not optional): wrap the existing
  vertical stack in a `UIScrollView` -- stack pinned to the scroll view's
  `contentLayoutGuide` on all four edges, with `widthAnchor` tied to the scroll
  view's `frameLayoutGuide.widthAnchor` so it scrolls vertically only. The scroll
  view fills the safe area.
- Add a `StatusFeature` store to Health (same construction Home uses), observe it,
  and `send(.onAppear)` / `.onDisappear` in the view lifecycle. (`StatusFeature`
  already self-polls at 1500ms; Health keeps its existing `HealthFeature` store for
  boot id / uptime / recording / pi time unchanged.)
- **Status-backed render seam** (new file
  `app/DanCam/DanCam/Features/Health/HealthTelemetry.swift`): a pure function
  `HealthTelemetry.rows(for state: StatusFeature.State) -> [TelemetryRow]`, where
  `TelemetryRow = (label: String, value: String)`. It composes the shared
  `Formatters` primitives into an ordered row list -- SoC temp, sensor temp (both via
  `Formatters.temperature(_, precise: true)`, one decimal), storage
  used / total / free, memory total / available, swap total / used -- and emits a
  `"--"` value for every missing optional (`storage`/`mem` are `Storage?`/`Mem?`;
  `tempC.soc`/`tempC.sensor` are `Double?`) and for the non-`.loaded` states. This is
  where the detail removed from Home lands, so nothing is lost -- and the seam is
  unit-testable (see tests), so the move can't silently drop a field.
- Render the rows into a dedicated `telemetryStack` (vertical `UIStackView`) rebuilt
  from `HealthTelemetry.rows(for:)` on each status observation (clear arranged
  subviews, add one `.body` label per row). Utilitarian styling, friendly GB units --
  it's the debug surface, no heavy polish.

## Presentation logic + tests

Extract the display decisions into **pure functions** (in `Formatters.swift`, the
`RecordButtonStyle.from` mapping, and `HealthTelemetry.rows`) so they're testable
without touching UIKit. Add Swift Testing cases under `DanCamTests/` (the suite
`just app-test` runs):

- `Formatters.storageDisplay` -- fraction math + free-text for representative
  used/total pairs, the 0-total guard, and the **`used > total` underflow case**
  (must yield 0 free, not a near-exabyte value).
- `Formatters.sensorWarning` -- boundary behavior at the named thresholds
  (below 50 -> nil; at 50 -> warn; at 55 -> critical) and a `nil` sensor -> nil.
- `Formatters.temperature` -- rounded (`precise: false`) vs one-decimal
  (`precise: true`) rendering, pinning the Health surface's decimal fidelity.
- `RecordButtonStyle.from` -- each `RecordingFeature.State` maps to the expected
  (title, enabled, busy) tuple.
- `Formatters.byteSize` -- a couple of known byte counts.
- `HealthTelemetry.rows(for:)` -- the telemetry-move seam:
  - `.loaded` with all fields present -> rows carry the formatted figures for
    storage (used/total/free), memory (total/available), swap, and both temps at
    one-decimal precision.
  - `.loaded` with `storage`/`mem`/`tempC` optionals nil, plus the `.idle`,
    `.loading`, and `.failed` states -> the corresponding rows render `"--"`
    placeholders (every non-`.loaded` state pinned).
  This is the guard that fails if Health silently omits a telemetry field, so
  `just app-test` can no longer pass on an incomplete move.

These are behavioral and structure-insensitive (assert on returned values, not on
view hierarchy). No snapshot tests (none exist in the repo; out of scope).

## Accessibility & appearance

- All text via `preferredFont(forTextStyle:)` + `adjustsFontForContentSizeCategory`
  (existing convention). Pills truncate gracefully at large Dynamic Type sizes.
- Semantic colors / materials only (`.label`, `.secondaryLabel`, `.systemBackground`,
  `.systemRed`, `.ultraThinMaterial`) -> dark mode works automatically.
- VoiceOver: record button announces intent; REC pill labeled "Recording"; storage
  chip labeled e.g. "12 gigabytes free".

## Out of scope (note for later)

- Clip **thumbnails** / horizontal strip: no thumbnail endpoint exists (clips are
  `.ts` segments with id/bytes only). Keep the polished vertical list; revisit when
  the Pi can serve thumbnails.
- Full-bleed immersive viewfinder + swipe-up clips sheet (the rejected option).
- Elapsed recording timer in the REC pill (data not yet surfaced cleanly).

## Verification

1. `just app-build` -- compiles clean.
2. `just app-test` -- existing reducer/feature tests + new Formatters /
   RecordButtonStyle tests pass.
3. Manual (Xcode, iPhone 17 / iOS 26.5 simulator):
   - Against the current mock (test-pattern preview): preview shows as a rounded
     hero with a "Live" pill top-leading; storage chip shows GB; "Recent clips"
     header + empty state visible when no clips.
   - Tap **Record** -> capsule switches to "Stop", a red **REC** pill appears
     top-trailing on the preview; tap again -> returns to "Record", pill clears.
   - Tap the nav SF Symbol button -> Health screen now shows the full telemetry
     block (temps, storage, memory, swap) in friendly units.
   - Optional deeper check against a local mock Pi
     (`DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080` + `just raspi-mock`). Warning
     pills (hot temp / camera offline) are covered by unit tests; to see them in the
     UI, temporarily feed an over-threshold temp / offline `cameraState` from the
     mock.
   - Capture a before/after screenshot of the home screen.
