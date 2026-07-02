# Plan: move the Record/Stop button below the preview (custom icon+text button)

## Context

The Home screen's Record/Stop control is currently a native `.prominent`
`UIBarButtonItem` in the navigation controller's bottom toolbar. It renders
**icon-only** or **text-only** but never both: a standard `UIBarButtonItem` shows
its image and suppresses its title when both are set, so the recent working-tree
edit dropped the icon to get the words "Record"/"Stop" to show.

We got here by mistake-driven history. The original control was a custom
`UIButton` (`Views/RecordButton.swift`, filled capsule, icon **and** text) that
wrapped "Record" mid-word ("Re/cor/d"). The root cause was **placement**: that
button lived in the bottom toolbar as a `UIBarButtonItem(customView:)` with only a
height constraint and no width constraint, so UIKit's iOS 26 toolbar could wrap the
under-constrained label. Commit `a06f0a8` "fixed" the wrap by switching to a native
bar item -- trading the wrap bug for the can't-show-both limitation.

**The better fix (this plan):** put a custom `UIButton` back, but in the content
area **below the live preview** where it has the full column width. Full width
structurally eliminates the mid-word wrap (the toolbar was the only place it could
happen), and a custom `UIButton.Configuration` renders icon + text together
natively. We get the icon+text control back and dissolve the original bug instead
of working around it.

Intended outcome: a centered red "Record" / gray "Stop" capsule with an SF Symbol
glyph, sitting directly under the preview, scrolling with it.

## Decisions (confirmed with Dan)

- **Shape:** centered natural-width capsule (not full-width). Sits centered in the
  content column under the preview.
- **Transitions (Starting/Stopping):** relabel + disable, **no spinner**. The icon
  stays in every state (`record.circle` while idle/starting, `stop.fill` while
  recording/stopping).
- **Visibility:** the button is an arranged subview of the header stack, so it
  **scrolls with the preview** (consistent with today -- the preview already scrolls
  off as you browse clips). No pinned/fixed region.

## Approach

Resurrect the deleted custom button as a view that consumes the existing pure
`RecordButtonStyle` mapping, place it centered under the preview inside the header
stack, and retire the bottom toolbar. Keep the clean split introduced by `a06f0a8`:
`RecordButtonStyle.swift` stays the pure state -> presentation data; a new
`RecordButton.swift` is the view that renders it.

### 1. `app/DanCam/DanCam/Views/RecordButtonStyle.swift` -- restore the icon column

Re-add a `systemImage` field to the returned tuple (the working tree deleted it).
Because every state now carries an icon, make it a non-optional `String` (cleaner
than the old `String?`). Final `RecordButtonStyle.from(_:)` returns
`(title: String, systemImage: String, isEnabled: Bool, treatment: RecordButtonTreatment, accessibilityLabel: String)`:

- `.unknown` -> `("Record", "record.circle", false, .record, "Start recording")`
- `.idle`, `.failed` -> `("Record", "record.circle", true, .record, "Start recording")`
- `.starting` -> `("Starting", "record.circle", false, .record, "Starting recording")`
- `.recording` -> `("Stop", "stop.fill", true, .neutral, "Stop recording")`
- `.stopping` -> `("Stopping", "stop.fill", false, .neutral, "Stopping recording")`

`RecordButtonTreatment` (`.record` / `.neutral`) is unchanged.

### 2. `app/DanCam/DanCam/Views/RecordButton.swift` -- recreate the custom view (NEW file)

A `final class RecordButton: UIButton` with an `apply(_ state:)` method, adapted
from the deleted original (`RecordButton.swift` at `a06f0a8^`) but **without** the
spinner path, and reading `accessibilityLabel` straight from the style (the old
version computed it separately; the style now carries it):

- `UIButton.Configuration.filled()`, `cornerStyle = .capsule`, `imagePadding = 8`.
- `configuration.title = style.title`;
  `configuration.image = UIImage(systemName: style.systemImage)`.
- `configuration.titleLineBreakMode = .byTruncatingTail` -- forces a single-line
  title that truncates (never wraps mid-word) if space is ever tight. Together with
  the compression-resistance setting below this **structurally closes** the original
  "Re/cor/d" wrap regardless of container width, not just because we moved out of the
  toolbar.
- Treatment colors: `.record` -> red fill (`.systemRed`) / white text;
  `.neutral` -> `.systemGray5` fill / `.systemRed` text.
- Headline font via `titleTextAttributesTransformer`;
  `titleLabel?.adjustsFontForContentSizeCategory = true`.
- `contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24)`.
- `isEnabled = style.isEnabled`; `accessibilityLabel = style.accessibilityLabel`.
- `init(frame:)` sets horizontal content **hugging** to `.required` (button stays at
  its natural width and never stretches) but horizontal **compression resistance**
  *below* required (`.defaultHigh`) -- so at extreme Dynamic Type / narrow widths the
  button yields and the title truncates instead of forcing an unsatisfiable conflict
  with the row's required `leading >= / trailing <=` edge constraints. (Required
  compression resistance vs. required edge constraints would be the wrap/overflow
  failure mode.) `init?(coder:)` unavailable.
- No `showsActivityIndicator` (decision: no spinner).

The Xcode project uses `PBXFileSystemSynchronizedRootGroup` with no explicit file
references, so a new file under `Views/` is compiled automatically -- **no
`.pbxproj` edit required** (verified: zero `RecordButton*.swift` refs in
`project.pbxproj`).

### 3. `app/DanCam/DanCam/Features/Home/HomeViewController.swift` -- swap the control

- **Properties:** replace `private let recordItem = UIBarButtonItem()` with
  `private let recordButton = RecordButton(frame: .zero)` plus a centering wrapper
  `private let recordButtonRow = UIView()`.
- **`configureViews` (`HomeViewController.swift#fn configureViews`):**
  - Delete the `recordItem.style = .prominent ...` setup block and the
    `toolbarItems = [.flexibleSpace(), recordItem, .flexibleSpace()]` assignment.
  - Wire the button: `recordButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)`,
    `recordButton.apply(.unknown)`.
  - Build the centered row: set
    `recordButton.translatesAutoresizingMaskIntoConstraints = false` **before**
    activating constraints (it is a plain subview of `recordButtonRow`, not
    stack-managed, so its default autoresizing-mask constraints would otherwise fight
    the explicit ones and lay out wrong despite compiling), add `recordButton` as a
    subview of `recordButtonRow`, and constrain top/bottom to the row, `centerXAnchor`
    to the row's center, with `leadingAnchor >= row.leading` /
    `trailingAnchor <= row.trailing` to prevent overflow at large Dynamic Type sizes.
    (`recordButtonRow` is added via `insertArrangedSubview`, so the stack disables
    *its* mask automatically -- only the button needs the explicit flag.) Same
    centering idiom as `emptyClipsView` in `configureClipsTable`.
  - Insert the row directly under the preview:
    `headerStack.insertArrangedSubview(recordButtonRow, at: 1)` -- order becomes
    preview / record button / status pills / "Recent clips" label. The header is a
    self-sizing `tableHeaderView` measured by `sizeHeaderToFit()`, so it grows to
    fit the new row automatically; no manual height math.
- **`renderRecording` (`HomeViewController.swift#fn renderRecording`):** keep the
  `recPill` show/hide switch; replace the `applyRecordItem(state)` call with
  `recordButton.apply(state)`.
- **Delete `applyRecordItem(_:)`** -- its logic now lives in `RecordButton.apply`.
- **`viewWillAppear` (`HomeViewController.swift#fn viewWillAppear`):** remove
  `navigationController?.setToolbarHidden(false, animated: animated)`. The toolbar
  held only the record item; with it gone the toolbar stays hidden (nav controller
  default). Confirm no other code references `toolbarItems` / `setToolbarHidden`
  (current audit: none).
- **`recordTapped`** is unchanged (still `store.send(.recordTapped)`).
- **Test hook:** rename `recordItemForTesting` (returns `UIBarButtonItem`) to
  `recordButtonForTesting` returning the `RecordButton` (a `UIButton`).

### 4. Tests

- **`app/DanCam/DanCamTests/Views/RecordButtonStyleTests.swift`:** add the
  `systemImage` column back to the parameterized table (values per section 1) and
  restore `#expect(style.systemImage == testCase.image)`. Note the column type is
  now `String`, not `String?`.
- **`app/DanCam/DanCamTests/Features/Home/HomeViewControllerTests.swift`** ->
  `recordItemPresentationFollowsRecordingState` (rename to
  `recordButtonPresentationFollowsRecordingState`): read from
  `controller.recordButtonForTesting`. Assert `button.configuration?.title`,
  `button.configuration?.image != nil` (icon present in every state now),
  `button.isEnabled`, and `button.accessibilityLabel`, across the idle -> starting
  -> recording sends already in the test.
- **`HomeViewControllerTests` -- new `recordButtonLivesBelowPreviewNotInToolbar`:**
  regression guard for the placement change itself (the presentation test above would
  still pass if someone reintroduced the toolbar path). Embed the controller in a
  `UINavigationController` inside a key window and lay out -- the existing `embed(_:)`
  helper roots the controller directly, so this test needs a nav-controller root for
  a toolbar to exist to check (add a small nav-embedding variant or inline it). After
  layout assert:
  - `controller.recordButtonForTesting.isDescendant(of: controller.view)` -- the
    control lives in the content view hierarchy; a toolbar `customView` would hang off
    the `UINavigationController`, **not** `controller.view`, so this fails if the
    button regresses into the toolbar. Structure-insensitive (asserts descendant, not
    an exact parent).
  - the nav controller's `isToolbarHidden == true` -- verifies the removed
    `setToolbarHidden(false)` stays gone.

## Files touched

- `app/DanCam/DanCam/Views/RecordButtonStyle.swift` (restore `systemImage`)
- `app/DanCam/DanCam/Views/RecordButton.swift` (**new** -- recreated view)
- `app/DanCam/DanCam/Features/Home/HomeViewController.swift` (swap control + layout)
- `app/DanCam/DanCamTests/Views/RecordButtonStyleTests.swift`
- `app/DanCam/DanCamTests/Features/Home/HomeViewControllerTests.swift`

## Verification

1. `just app-build` -- compiles clean (confirms the new `Views/RecordButton.swift`
   is auto-picked-up by the synchronized group).
2. `just app-lint` -- full recompile, no new warnings.
3. `just app-test` -- the updated suites pass:
   `RecordButtonStyleTests.mapsRecordingStatesToButtonPresentation` (now asserts the
   icon), `HomeViewControllerTests.recordButtonPresentationFollowsRecordingState`
   (title/icon/enabled/accessibility across idle/starting/recording), and
   `HomeViewControllerTests.recordButtonLivesBelowPreviewNotInToolbar` (button is a
   descendant of the content view; toolbar stays hidden).
4. Manual (simulator, `just app-build` then run in Xcode): on Home, a centered red
   **"[record.circle] Record"** capsule sits directly under the preview; the words
   render (no mid-word wrap even at large Dynamic Type). Tap -> it disables and
   relabels **"Starting"**, then becomes a gray **"[stop.fill] Stop"** capsule when
   recording; the "REC" pill shows on the preview. Tap Stop -> "Stopping" (disabled)
   -> back to red "Record". Scrolling the clip list carries the preview and button
   off-screen together. The bottom toolbar no longer appears.

## Out of scope

- No change to `RecordingFeature` state, the reducer, or `store.send(.recordTapped)`.
- No spinner / activity indicator (explicitly decided against).
- No pinned/fixed top region -- button scrolls with the preview.
