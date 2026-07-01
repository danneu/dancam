# Plan: clip duration + size caption under the viewer

## Context

The clip detail screen (`ClipViewerViewController`) shows the video and pull
progress, but never surfaces the clip's duration or file size. We want a compact,
glanceable line directly under the player: duration and size together.

We settled on the most iOS-native treatment: a single **centered secondary caption**
with an interpunct separator -- `0:12 · 3.4 MB` -- duration first (the clip's
identity), size second. This is the App Store / Music caption idiom, not a
left/right justified split (which iOS reserves for transient playback UI).

Two native refinements ride along, and the user chose to apply them **app-wide** for
one consistent duration/metadata format everywhere:

- Separator is the interpunct `·` (not the current ` - `). Sanctioned under the
  repo's plain-ASCII convention via its explicit "user explicitly asks" exception.
- Minutes drop the leading zero under 10 minutes: `0:12`, not `00:12`.

Because the caption reuses the existing shared formatters, these two tweaks
propagate to every screen that already formats a duration or clip metadata:
the new caption, the Home clip-list subtitle, and the Home live REC count-up timer
all end up consistent.

## Approach

Reuse `Formatters.clipMetadata` verbatim for the caption -- it already returns
`durationText · byteText` in exactly the order we want and already falls back to
size-only when `durMs` is `nil`. The only source changes are the two formatting
tweaks (in `Formatters`) plus wiring one new label into the detail screen.

### 1. `Formatters` -- two shared tweaks

File: `app/DanCam/DanCam/Support/Formatters.swift`

- **Drop the leading zero on minutes (app-wide).** In
  `Formatters.minutesSeconds`, change the format string from
  `"%02llu:%02llu"` to `"%llu:%02llu"`. This is the shared helper behind both
  `Formatters.clipDuration` (clip durations) and `Formatters.countUpDuration`
  (the live REC timer), so both pick up `0:12` / `10:00` consistently. Seconds
  stay zero-padded to two digits.
- **Interpunct separator.** In `Formatters.clipMetadata`, change the joiner from
  `" - "` to `" · "` (middle dot, U+00B7). Nil-duration fallback is unchanged
  (returns size only).

No other production code calls `clipDuration`/`clipMetadata` directly, so blast
radius is exactly: the new caption, the Home finished-clip subtitle
(`HomeViewController#configureFinishedCell`), and the Home live REC timer
(`HomeViewController` `LiveClipCell.updateElapsed`).

### 2. `ClipViewerViewController` -- the caption label

File: `app/DanCam/DanCam/Features/ClipViewer/ClipViewerViewController.swift`

- Add a stored property alongside the other views: `private let captionLabel = UILabel()`.
- In `ClipViewerViewController#configureViews`, style it as a true caption:
  `.preferredFont(forTextStyle: .footnote)`, `adjustsFontForContentSizeCategory = true`,
  `textColor = .secondaryLabel`, `textAlignment = .center`, `numberOfLines = 0`.
  (Sibling `resultLabel` uses `.subheadline`; `.footnote` is chosen as the more
  caption-like size -- adjust to `.subheadline` if it reads too small on device.)
- Set the text once here (the caption is static from `clip`, not state-driven, so it
  does not belong in `render`):
  `captionLabel.text = Formatters.clipMetadata(durMs: clip.durMs, bytes: clip.bytes)`.
- Insert it into the arranged-subviews array **immediately after
  `playerContainerView`** (before `statusLabel`) so it sits directly under the video.
  It is an arranged subview, so it does not set
  `translatesAutoresizingMaskIntoConstraints`; the stack's `spacing = 12` handles
  placement. No new constraints.
- Expose a test-only read accessor mirroring the existing `statusText` / `resultText`
  computed properties: `captionText` returning `captionLabel.text`.

## Tests

Behavioral, structure-insensitive assertions only.

- `app/DanCam/DanCamTests/Support/FormattersTests.swift` -- update the three
  assertions the format change invalidates:
  - `clipDurationFormatsMillisecondsAsMinutesAndSeconds`: sub-10-minute cases lose the
    leading zero (`"00:05"` -> `"0:05"`, `"00:34"` -> `"0:34"`, `"01:34"` -> `"1:34"`,
    `"00:00"` -> `"0:00"`). Cases at 10 minutes and above (`"10:00"`, `"100:00"`, and
    the two large-value cases) are unchanged.
  - `countUpDurationFloorsSeconds`: same leading-zero drop (`"00:01"` -> `"0:01"`,
    `"01:00"` -> `"1:00"`, etc.; `"10:00"` unchanged).
  - `clipMetadataCombinesDurationAndByteSize`: `"00:34 - 1 KB"` -> `"0:34 · 1 KB"`;
    the nil-duration case (`"1 KB"`) is unchanged.
- `app/DanCam/DanCamTests/Features/ClipViewer/ClipViewerViewControllerTests.swift` --
  add one `@MainActor` test using the existing `makeController()` factory (all `.noop`
  deps -- the caption derives from `clip`, not from pull/remux): call
  `loadViewIfNeeded()`, then assert
  `captionText == Formatters.clipMetadata(durMs: clip.durMs, bytes: clip.bytes)`.
  This proves the caption is wired to the clip and reachable in the hierarchy; the
  exact rendered string ("0:30 · 1 byte" for the factory's clip) is already covered
  by FormattersTests, so we don't duplicate the format assertion here.

## Out of scope / no-ops

- No ADR: this is a UI/formatting tweak, not an architectural decision.
- No README / runbook changes (no Pi provisioning or onboard state touched).
- `Formatters.byteSize` is unchanged; the caption's size segment renders identically
  to the existing pull-progress and Health byte strings.

## Verification

1. Run the app test suite via the appropriate `just` task (check `just --list`);
   confirm `FormattersTests` and `ClipViewerViewControllerTests` pass, including the
   new caption test.
2. Launch the app in the simulator, open a finished clip from the Home list, and
   confirm the caption `M:SS · <size>` sits centered directly under the video and
   collapses to size-only if a clip has no duration.
3. Spot-check the two rippled screens for the consistent format: the Home
   finished-clip subtitle now reads `0:34 · 1 KB`, and the live REC count-up timer
   reads `0:07` (no leading zero).
