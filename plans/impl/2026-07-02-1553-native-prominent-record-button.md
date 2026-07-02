# Plan: native prominent bar button for Record/Stop

## Context

On the Home screen the Record/Stop control is a custom `UIButton`
(`UIButton.Configuration.filled()`, capsule) hosted in the nav-controller
toolbar as a `UIBarButtonItem(customView:)` between two flexible spaces, with a
lone `heightAnchor = 44` and no width constraint (see
`HomeViewController.swift#configureViews` and `Views/RecordButton.swift`). The
title label has no line limit, and a `UIButton.Configuration` title label
word-wraps by default. Because a `UIToolbar` does not reliably give a custom view
a definite width from its intrinsic content size, the title lays out against an
under-defined width and "Record" wraps mid-word (`Re / cor / d`). iOS 26 also
actively degrades custom-view bar items (tint override, false-disabled look in
dark mode), so the custom view is the wrong tool here.

Deployment target is iOS 26.5 (all configs), so we can adopt the native iOS 26
`UIBarButtonItem.Style.prominent` unconditionally. A native bar item is laid out
by the system (no custom-view width bug), supports icon+text together, takes a
per-item tint, and stands alone (prominent items are not grouped). This replaces
the custom button with a native prominent bar button item.

Confirmed against Apple docs:
- `UIBarButtonItem(title:image:target:action:menu:)` displays **both** a title and
  an image -- we keep `record.circle`+"Record" / `stop.fill`+"Stop".
- `UIBarButtonItem.Style.prominent` (iOS 26.0+): "not visually grouped with other
  items ... styling changes appropriate to their context to indicate prominence."
- Per-item `var tintColor: UIColor?` -> force red (Record) / gray (Stop) instead
  of the app accent. `var possibleTitles: Set<String>?` reserves width so the
  button does not jump as the label changes.
- Cost accepted: bar items have no `showsActivityIndicator`, so the in-button
  spinner is dropped.

## Decisions (from review)

- Record = red prominent capsule; Stop = **gray** prominent capsule (closest to
  today's gray Stop). Both states are `.prominent`; only the tint differs.
- Starting/Stopping = **disabled + relabeled** ("Starting"/"Stopping"), no
  spinner, no symbol animation.
- Keep the leading SF Symbol in every state (including Starting/Stopping, which
  keep their base treatment's icon) so the button does not lose/regain its icon or
  jump width during transitions.

## Changes

### 1. `app/DanCam/DanCam/Views/RecordButton.swift` -> rename to `RecordButtonStyle.swift`

- Delete `final class RecordButton: UIButton` entirely (and its
  `accessibilityLabel(for:)` helper, the `UIButton.Configuration` setup, the
  `showsActivityIndicator`/`.filled()`/`cornerStyle`/`contentInsets` code).
- Keep `RecordButtonTreatment { case record; case neutral }` -- now it selects a
  tint (record -> red, neutral -> gray), both rendered `.prominent`.
- Keep `RecordButtonStyle.from(_:)` as the pure state->presentation mapping,
  reshaped. Drop `showsActivityIndicator`; fold in the accessibility label so it
  stays covered by the existing pure-function test:

  `from(state) -> (title: String, systemImage: String?, isEnabled: Bool, treatment: RecordButtonTreatment, accessibilityLabel: String)`

  | state    | title    | systemImage    | isEnabled | treatment | accessibilityLabel  |
  |----------|----------|----------------|-----------|-----------|---------------------|
  | unknown  | Record   | record.circle  | false     | record    | Start recording     |
  | idle     | Record   | record.circle  | true      | record    | Start recording     |
  | failed   | Record   | record.circle  | true      | record    | Start recording     |
  | starting | Starting | record.circle  | false     | record    | Starting recording  |
  | recording| Stop     | stop.fill      | true      | neutral   | Stop recording      |
  | stopping | Stopping | stop.fill      | false     | neutral   | Stopping recording  |

  (Change from today: starting/stopping now carry an icon instead of `nil`, since
  there is no spinner to replace it.)
- The mapping stays a plain value type (no UIKit `UIColor` in it) -- the VC maps
  `treatment` -> tint. Rename is optional churn but preferred; if the target uses
  a synchronized file-system group no `.pbxproj` edit is needed, otherwise update
  the file reference. Build after renaming to confirm.

### 2. `app/DanCam/DanCam/Features/Home/HomeViewController.swift`

Follow the existing stored-bar-item precedent in
`ClipViewerViewController` (`shareButton = UIBarButtonItem()`, configured once,
`isEnabled` toggled from the render switch).

- Replace the `recordButton` property with `private let recordItem = UIBarButtonItem()`.
- In `configureViews`, delete the custom-view setup (addTarget, `apply(.unknown)`,
  `translatesAutoresizingMaskIntoConstraints`, the `heightAnchor = 44`
  constraint). Configure the item once:
  - `recordItem.style = .prominent`
  - `recordItem.target = self; recordItem.action = #selector(recordTapped)`
  - `recordItem.possibleTitles = ["Record", "Stop", "Starting", "Stopping"]`
  - `toolbarItems = [.flexibleSpace(), recordItem, .flexibleSpace()]` (the modern
    `class func flexibleSpace() -> Self` -- it is a function, so the parens are
    required; a bare `.flexibleSpace` would be the unapplied function value and
    fails to type-check)
  - initial `applyRecordItem(.unknown)`
- Add `applyRecordItem(_ state:)` that reads `RecordButtonStyle.from(state)` and sets
  `title`, `image` (`systemImage.map { UIImage(systemName: $0) }`), `isEnabled`,
  `accessibilityLabel`, and `tintColor` (`treatment == .record ? .systemRed : .systemGray5`).
  Style stays `.prominent` (set once).
- `renderRecording` calls `applyRecordItem(state)` instead of `recordButton.apply(state)`.
  Everything else in `renderRecording` (the `recPill` show/hide) is unchanged.
- `recordTapped` is unchanged (`store.send(.recordTapped)`).
- Add a `recordItemForTesting` accessor mirroring the existing `*ForTesting`
  accessors, for the VC test below.

State flow is untouched: `store.observe(\.recording)` ->
`renderRecording` -> `applyRecordItem` (see `HomeViewController.swift#viewDidLoad`).
Tap routing (`AppFeature` `.recordTapped` -> start/stop, no-op while
starting/stopping) is untouched, so disabling the item in transitional states
stays correct.

## Tests

- **Update** `app/DanCam/DanCamTests/Views/RecordButtonStyleTests.swift` (Swift
  Testing) to the new tuple: assert `title`, `systemImage`, `isEnabled`,
  `treatment`, and `accessibilityLabel` for all six states per the table above;
  drop the `busy` column. This is the primary behavioral, structure-insensitive
  test (state -> presentation), and it now also covers the accessibility label
  that moved out of the deleted class.
- **Add** one focused `HomeViewController` test (Swift Testing, `@MainActor`,
  `loadViewIfNeeded()`) that drives a couple of `recording` states through the
  store observation and asserts, for representative states, all the user-visible
  fields `applyRecordItem` sets on the item:
  - `recordItemForTesting.title` (idle -> "Record", starting -> "Starting",
    recording -> "Stop")
  - `recordItemForTesting.isEnabled` (idle/recording enabled, starting disabled)
  - `recordItemForTesting.accessibilityLabel` (idle -> "Start recording",
    starting -> "Starting recording", recording -> "Stop recording") -- guards the
    VoiceOver wiring, since the label differs from the visible title.
  - `recordItemForTesting.image != nil` in every asserted state -- guards the
    "keep the icon in every state" decision (an impl that forgets `.image`, or
    reverts starting/stopping to a nil icon, must fail).

  This asserts the VC actually pushes the mapping onto the item (title/enabled/
  label/icon present), behaviorally, without pinning colors or layout. The exact
  symbol name and label strings per state remain owned by the pure
  `RecordButtonStyle.from` test.
- No test should assert tint `UIColor`, font, or capsule geometry (structure-
  sensitive, verified visually instead).

## Verification

1. `just app-build` -- compiles after the rename + type reshape.
2. `just app-test` -- Swift Testing unit suites green (updated
   `RecordButtonStyleTests`, new VC test, and the untouched `RecordingFeature`/
   `AppFeature` reducer tests still pass).
3. Run in the simulator (see `/run`) against the mock Pi and visually confirm:
   - "Record" renders on **one line** as a red prominent capsule with the
     `record.circle` icon -- the original wrap bug is gone.
   - Tap -> "Starting" (dimmed/disabled, icon retained) -> "Stop" as a **gray**
     prominent capsule; tap -> "Stopping" (disabled) -> back to "Record".
   - Button does not jump width across states (possibleTitles).
   - Accessibility: inspector/VoiceOver reads "Start recording" / "Stop recording"
     etc. (labels differ from the visible title, as today).
   - Check the gray Stop capsule is legible; if `.systemGray5` reads too faint as a
     prominent fill, step to `.systemGray4`/`.systemGray3`. (If red "Stop" text on
     gray is later wanted, `UIBarButtonItem` has no `attributedTitle`; use the
     inherited `setTitleTextAttributes([.foregroundColor: UIColor.systemRed], for:)`
     for the title color, and for a red icon pass an explicitly tinted symbol,
     e.g. `UIImage(systemName: "stop.fill")?.withTintColor(.systemRed, renderingMode: .alwaysOriginal)`.
     Note both may interact with `.prominent`'s automatic foreground contrast --
     verify in the simulator. Not in scope now.)

## Risks / notes

- Residual visual unknowns (exact prominent+custom-tint rendering, icon+title
  spacing, gray-fill contrast) are resolved by the simulator check in step 3, not
  by docs. Fallback if `.prominent` ever drops the icon in practice: text-only
  prominent "Record"/"Stop" is still clean and fixes the bug.
- `possibleTitles` width reservation with an image is best-effort; titles are
  short and similar length, so jitter should be negligible. If it appears, set a
  fixed `recordItem.width`.
- No production code other than `HomeViewController` referenced `RecordButton`;
  `RecordButtonStyle`/`RecordButtonTreatment` are used only by the button and the
  one test -- so the blast radius is these three files plus the new VC test.
