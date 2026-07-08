# Plan: trim the Recent clips subtitle to time + duration (drop filesize)

## Context

On the Home "Recent clips" list, each finished-clip row packs three facts --
segment filename, recording time, and duration/size -- into a filename line plus a
**single** subtitle line:

```
seg_00205.ts
2026-07-08 14:05:16 · 00:30 · 1.2 MB
```

That subtitle is one `UILabel` (`numberOfLines = 1`, default tail truncation) sitting
in a column that starts after a fixed 80pt thumbnail. On a narrow phone -- or at larger
Dynamic Type -- the width budget runs out around the duration, so the tail
(`· 00:30 · 1.2 MB`) is silently truncated:

```
seg_00205.ts
2026-07-08 14:05:16 · 0...
```

The list view does not need the filesize: it is already shown on the clip **detail** view
(`ClipViewerViewController`'s caption). So the fix is to drop the filesize from the list
row and keep just recording time + duration on the one subtitle line -- removing the widest,
least-useful field is what buys back the space:

```
seg_00205.ts                 <- filename (title)
2026-07-08 14:05:16 · 00:30  <- {when} · {duration}; filesize dropped (kept on detail view)
```

When a clip's time is not trusted (`timeApproximate` / missing `startMs`), the recording
time is omitted and the line shows just the duration (mirrors today's behavior, where the
subtitle drops the timestamp for untrusted clips):

```
seg_00205.ts
00:30
```

## Decision

Keep the list cell's **single** subtitle line, but stop feeding it `clipDetailLine`
(time + duration + size) and feed it a new `Formatters.clipListLine` (time + duration, no
size). Two files change:

1. `app/DanCam/DanCam/Support/Formatters.swift` -- add `clipListLine(_:timeZone:)`.
2. `app/DanCam/DanCam/Features/Home/ClipThumbnailCell.swift` -- point the subtitle at it.

The clip **detail** view keeps `clipDetailLine` unchanged, so the filesize stays visible
there. No new locale/relative logic, no row-stacking.

**Decision I made (flag for confirmation):** the subtitle label becomes multiline
(`numberOfLines = 0`, word wrapping) instead of today's `numberOfLines = 1`. Removing the
filesize makes truncation far less likely, but at large accessibility text sizes even
`2026-07-08 14:05:16 · 00:30` can still exceed the width left after the 80pt thumbnail.
`numberOfLines = 0` makes it *wrap* instead of tail-truncate, which is the durable
anti-truncation guarantee that motivated this task. At default text sizes it renders on one
line, so "keep it on a single line" still holds for the common case. If you'd rather it stay
strictly one line and re-truncate at accessibility sizes, say so and I'll set it back to `1`.

## Changes

### `app/DanCam/DanCam/Support/Formatters.swift`

Add a list-row formatter next to `clipDetailLine` (`#clipDetailLine` in the file), reusing
the existing `clipCreatedTime` and `clipDuration` component formatters:

```swift
/// The Home list-row subtitle: recording time + duration, no filesize (the filesize is
/// shown on the clip detail view). Recording time is included only when trusted, matching
/// `clipCreatedTime`'s gating; for an untrusted clip the line is just the duration.
static func clipListLine(_ clip: Clip, timeZone: TimeZone = .current) -> String {
    let created = clipCreatedTime(clip, timeZone: timeZone)   // nil unless trusted
    let duration = clipDuration(clip.durMs)                    // nil only if durMs is nil
    return [created, duration].compactMap { $0 }.joined(separator: " · ")
}
```

Yields:
- trusted + duration: `"2026-01-01 00:00:00 · 00:30"`
- untrusted + duration: `"00:30"`
- trusted, no duration (degenerate): `"2026-01-01 00:00:00"`
- neither (untrusted *and* no `durMs`): `""`. `Clip.durMs` is optional (`UInt64?`) and
  `durMs: nil` is exercised elsewhere in the suite, so this case **is** reachable -- the cell
  handles it by hiding the subtitle and dropping it from the accessibility label (see
  `configure` below), so the row shows just the filename with no blank slot and no
  trailing-comma label.

`clipDetailLine`, `clipMetadata`, `clipDuration`, `clipCreatedTime` keep their current
signatures and output -- `clipListLine` is purely additive.

### `app/DanCam/DanCam/Features/Home/ClipThumbnailCell.swift`

**1. Subtitle label styling (`configureViews`)** -- keep the single `subtitleLabel` and its
place in the vertical `[titleLabel, subtitleLabel]` stack; change only its line handling:

- `numberOfLines = 0` and `lineBreakMode = .byWordWrapping` (was `numberOfLines = 1`, default
  tail truncation). Font/color/`adjustsFontForContentSizeCategory` are unchanged
  (`.subheadline`, `.secondaryLabel`). The row already self-sizes, so it grows a line only
  when the subtitle actually wraps (accessibility sizes); at default sizes it is unchanged.
- `titleLabel` is untouched (`numberOfLines = 1`, `.byTruncatingMiddle` -- correct for a
  fixed-shape filename, and never the field that overflowed).

**2. Populate (`configure(clip:loader:)`)** -- change the subtitle source from
`clipDetailLine` to `clipListLine` (`#configure` in the file):

```swift
titleLabel.text = String(format: "seg_%05d.ts", clip.id)

let subtitle = Formatters.clipListLine(clip)
subtitleLabel.text = subtitle
subtitleLabel.isHidden = subtitle.isEmpty   // untrusted + no durMs -> no subtitle row at all

accessibilityLabel = [titleLabel.text, subtitle.isEmpty ? nil : subtitle]
    .compactMap { $0 }
    .joined(separator: ", ")
```

Building `accessibilityLabel` from the non-empty parts (rather than the old
`"\(title), \(subtitle)"` interpolation) avoids a trailing `", "` when the subtitle is empty,
and `subtitleLabel.isHidden = subtitle.isEmpty` collapses the empty label in the stack so the
degenerate clip renders as filename-only. The thumbnail load/identity/reuse logic below this
(the `displayState` / `loadTask` block) and the `subtitleTextForTesting` accessor
(`subtitleLabel.text`) are untouched.

## Explicitly unchanged (do not touch)

- `Formatters.clipDetailLine` / `clipMetadata` / `clipDuration` / `clipCreatedTime` -- no
  signature or output change; `clipListLine` is added alongside them.
- `ClipViewerViewController` -- its caption keeps `Formatters.clipDetailLine(clip)` (time +
  duration + **size**) on one roomy line. The filesize the list drops still lives here.
- `Formatters.clipExportFilename` (machine-safe filename) and `LogExporter` ISO8601 log
  timestamps -- unrelated, stay locale-independent.
- No ADR: this is a UI display tweak, below the architecture-decision bar.

## Tests

Carried over unchanged:

- `DanCamTests/Features/Home/HomeViewControllerTests.swift` -- untouched. The
  approximate->trusted test still flips (`subtitleTextForTesting` goes `"00:30"` ->
  `"2026-... · 00:30"`), and the `updatedSubtitle.contains("00:30")` / relabel-accessibility
  assertions still hold (the duration remains in the subtitle and in `accessibilityLabel`).
- `DanCamTests/Features/ClipViewer/ClipViewerViewControllerTests.swift` -- untouched (the
  detail caption still equals `clipDetailLine` / `clipMetadata`, both unchanged).
- The existing `FormattersTests.clipDetailLinePrefixesTrustedCreatedTime` stays -- it now
  doubles as the guard that the **detail** line keeps the filesize
  (`"2026-01-01 00:00:00 · 00:30 · 1 byte"`).

Add two behavioral, structure-insensitive tests:

1. **Formatter contract** -- in `DanCamTests/Support/FormattersTests.swift`, mirror
   `clipDetailLinePrefixesTrustedCreatedTime` for the new function (inject
   `TimeZone(secondsFromGMT: 0)` as the existing tests do):

   ```swift
   #expect(Formatters.clipListLine(trusted, timeZone: utc) == "2026-01-01 00:00:00 · 00:30")
   #expect(Formatters.clipListLine(approximate, timeZone: utc) == "00:30")
   ```

   This pins both halves of the intent: filesize is absent, and the recording time appears
   only when trusted.

2. **Cell wiring (filesize dropped)** -- add a test to the existing
   `DanCamTests/Features/Home/ClipThumbnailCellTests.swift` (`@MainActor struct`,
   inert loader) proving the list row drops the filesize. Configure a **trusted** cell
   (a clip with `startMs` set, `timeApproximate == false`, `bytes` non-trivial) and assert on
   the public `subtitleTextForTesting` hook, timezone-independently:

   ```swift
   let subtitle = try #require(cell.subtitleTextForTesting)
   #expect(subtitle.contains("00:30"))                                     // duration kept
   #expect(subtitle.contains(Formatters.byteSize(clip.bytes)) == false)    // filesize dropped
   ```

   The exact timestamp is not asserted (the cell formats in `.current`, so the string is
   machine-timezone dependent -- the datetime-gating is covered by test 1). The negative
   assertion uses `== false` rather than `!(...)` so Swift Testing prints the captured
   operands on failure (the suite has no `#expect(!...)` usages). This test **fails on a
   revert** to `clipDetailLine` (the subtitle would then contain the byteSize), which the
   carried-over tests do not catch.

3. **Cell degenerate case (untrusted, no duration)** -- add a test for the reachable
   empty-line path. `Clip.durMs` is optional (`UInt64?`) and `durMs: nil` is exercised
   elsewhere in the suite. Configure a cell with an untrusted clip whose `durMs == nil`
   (`startMs: nil, timeApproximate: false, durMs: nil`, `id: 8`) so `clipListLine` returns
   `""`, and assert the row is filename-only -- no blank subtitle and no trailing-comma
   accessibility label:

   ```swift
   #expect(cell.subtitleTextForTesting?.isEmpty == true)   // subtitle collapsed, nothing shown
   #expect(cell.accessibilityLabel == "seg_00008.ts")      // no trailing ", " for a missing subtitle
   ```

   This pins the `accessibilityLabel`-join / `isHidden` handling from `configure` and guards
   against a regression back to the `"\(title), \(subtitle)"` interpolation.

## Verification

1. `just app-test` -- runs `DanCamTests`; carried-over suites pass unchanged and both new
   tests pass.
2. `just app-build` (or the `/run` skill) -- launch in the iOS 26.5 simulator, open Home ->
   Recent clips, and confirm each finished row's subtitle reads `time · duration` with **no**
   filesize and nothing truncated. Open a clip's detail view and confirm the filesize is
   still shown there. At a large accessibility Dynamic Type setting, confirm the subtitle
   *wraps* (may occupy two lines) rather than tail-truncating. Confirm an approximate-time
   clip (or the just-recorded pending->finished row) shows just the duration, with no stray
   separator or blank where the time would be.

## Commit

Single commit, Conventional Commits, plain ASCII, e.g.:
`fix(app): drop filesize from Recent clips rows so time and duration fit`
