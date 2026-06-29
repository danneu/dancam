# Plan: show MM:SS clip length in the home screen clip list

## Context

The home screen lists recorded clips in a `UITableView`, and each row's
secondary line shows only the byte size (`Formatters.byteSize(clip.bytes)`).
Swoop `lime` already did the hard part end-to-end: the Pi derives an exact
per-clip duration from the TS PTS span and serves it as `dur_ms` on
`GET /v1/clips`, and the iOS app already decodes it into `Clip.durMs`
(`app/DanCam/DanCam/Networking/ClipsResponse.swift#Clip`). The value reaches
`HomeViewController` on every poll but is never displayed.

This is the open app-side item on the `lime` swoop (`docs/roadmap.md`, the
"clip rows show duration ..." step). The work is purely presentational: format
`durMs` as `MM:SS` and render it. No networking, model, or Pi changes.

Intended outcome: each clip row reads, e.g.

```
seg_00007.ts
00:34 - 37.3 MB
```

## Decisions

- **Placement:** duration joins the existing secondary metadata line as
  `"<MM:SS> - <byteSize>"`. Keeps the byte size, reuses the existing
  `UIListContentConfiguration.subtitleCell()` (no custom cell). A custom cell is
  deferred until the later roadmap row work (poster + created time) actually has
  data -- `start_ms` is still `nil` today, so building a richer cell now would
  have empty slots. The line is composed by a pure `Formatters.clipMetadata`
  helper (not inline in the cell) so the visible string has a cheap regression
  test (see Changes 1 and 3).
- **Format:** zero-padded `MM:SS` (e.g. `00:05`, `00:34`, `01:34`). Minutes use
  the `%02llu` UInt64 conversion, so a rare >= 100 min clip degrades gracefully
  (`100:00`) rather than truncating. Dashcam segments are short, so hours are not
  expected and we do not add an `H:MM:SS` branch.
- **Rounding:** round `durMs` to the nearest second. The Pi's
  `dur_ms = (maxPTS - minPTS) + frame_interval` already represents the full
  played length, so nearest-second is the most faithful display.
- **Separator:** an ASCII hyphen with spaces, `" - "` (e.g. `00:34 - 37.3 MB`),
  keeping source, tests, and docs plain-ASCII per the repo writing-style
  convention (`AGENTS.md#Conventions`). (Note: the `AskUserQuestion` preview that
  selected this layout rendered a middle dot (U+00B7); the placement choice --
  duration on the line -- is what was being decided there, and we render the
  separator in ASCII to avoid a lone non-ASCII glyph in the codebase. Flag for the
  user if that middle dot was actually wanted.)
- **Missing duration:** `durMs` is `Optional` (`null` when PTS parsing fails).
  When absent, omit the duration token and show the byte size alone -- never a
  placeholder like `--:--`.

## Changes

### 1. Add the formatters -- `app/DanCam/DanCam/Support/Formatters.swift`

Add two pure helpers to the existing `Formatters` enum, alongside `byteSize(_:)`:
`clipDuration` formats the MM:SS token, and `clipMetadata` composes the whole
secondary line so the cell does no formatting of its own.

```swift
static func clipDuration(_ durMs: UInt64?) -> String? {
    guard let durMs else { return nil }
    // round to nearest second; written to stay total -- (durMs + 500) would trap
    // on Swift integer overflow near UInt64.max.
    let totalSeconds = durMs / 1_000 + (durMs % 1_000 >= 500 ? 1 : 0)
    let minutes = totalSeconds / 60
    let seconds = totalSeconds % 60
    return String(format: "%02llu:%02llu", minutes, seconds)
}

static func clipMetadata(durMs: UInt64?, bytes: UInt64) -> String {
    let byteText = byteSize(bytes)
    guard let durationText = clipDuration(durMs) else { return byteText }
    return "\(durationText) - \(byteText)"
}
```

Notes:
- `%llu` (UInt64) -- not `%d`, which reads a 32-bit signed value from varargs.
  For small minute counts (incl. `100`) both happen to print the same, but `%d`
  misprints/wraps once minutes exceed `Int32.max`; `%llu` is the correct
  conversion for a `UInt64`, and the test below pins a beyond-`Int32.max` case so
  a regression to `%d` fails.
- Rounding is `durMs / 1_000 + (durMs % 1_000 >= 500 ? 1 : 0)`, not
  `(durMs + 500) / 1_000`: the latter traps on integer overflow near `UInt64.max`,
  and `durMs` is decoded straight from wire JSON (`ClipsResponse.swift#Clip`), so
  the formatter must stay total over any `UInt64`. Both forms round half-up
  identically for real values.
- `clipDuration` returns `String?` so `clipMetadata` can drop the token cleanly
  when duration is unknown, yielding just the byte size with no stray separator.
- Integer math (not `DateComponentsFormatter`) matches the project's fixed-format
  convention and needs no locale.

### 2. Render it -- `app/DanCam/DanCam/Features/Home/HomeViewController.swift`

In `tableView(_:cellForRowAt:)`, replace the single secondary-text assignment
(currently `content.secondaryText = Formatters.byteSize(clip.bytes)`) with a call
to the pure composer:

```swift
content.secondaryText = Formatters.clipMetadata(durMs: clip.durMs, bytes: clip.bytes)
```

All formatting logic lives in `Formatters`; the cell only wires the result.
Everything else in the cell config (fonts, colors, row height) is unchanged.

### 3. Tests -- `app/DanCam/DanCamTests/Support/FormattersTests.swift`

Add two `@Test`s to the existing `FormattersTests` struct (Swift Testing, same
style as `byteSizeFormatsKnownCounts`).

**`clipDuration` (MM:SS correctness):**

- `nil` -> `nil` (missing duration)
- `0` -> `"00:00"`
- `5_000` -> `"00:05"`
- `34_000` -> `"00:34"`
- `34_700` -> `"00:35"` (rounds up)
- `34_400` -> `"00:34"` (rounds down)
- `94_000` -> `"01:34"` (minute rollover)
- `600_000` -> `"10:00"`
- `6_000_000` -> `"100:00"` (>= 100 min: minutes overflow to 3 digits, no
  truncation and no `H:MM:SS` rollover -- pins the MM:SS-with-overflow choice)
- `128_849_018_880_000` -> `"2147483648:00"` (minutes exceed `Int32.max`: a
  minimal case that distinguishes `%llu` from `%d` -- a regression to `%d` would
  print a negative/wrong value here. Not a realistic clip length; a deliberate
  integer-width boundary so the `%llu` choice is under test.)
- `UInt64.max` -> `"307445734561825:52"` (totality guard: a malformed extreme wire
  value must render, not trap -- this is the case the overflow-safe rounding
  protects; it also exceeds `Int32.max`.)

**`clipMetadata` (the visible row line):** this is the behavioral output the
feature actually adds, so it gets its own test, structure-insensitively, by
reusing the known `byteSize(1_000) == "1 KB"` fixture (see the existing
`byteSizeFormatsKnownCounts`):

- duration present: `clipMetadata(durMs: 34_000, bytes: 1_000) == "00:34 - 1 KB"`
- duration absent: `clipMetadata(durMs: nil, bytes: 1_000) == "1 KB"` (no
  separator, no placeholder)

This means reverting the feature (e.g. back to byte-size-only) fails a test
rather than passing silently. The one remaining untested line is the cell's
single `content.secondaryText = Formatters.clipMetadata(...)` assignment, which
is irreducible view wiring and not worth standing up a `HomeViewController` +
`Store` to cover.

## Files to modify

- `app/DanCam/DanCam/Support/Formatters.swift` -- add `clipDuration(_:)` and
  `clipMetadata(durMs:bytes:)`.
- `app/DanCam/DanCam/Features/Home/HomeViewController.swift` -- call
  `Formatters.clipMetadata(...)` for the secondary line in
  `tableView(_:cellForRowAt:)`.
- `app/DanCam/DanCamTests/Support/FormattersTests.swift` -- add the
  `clipDuration` and `clipMetadata` tests.

No changes to the model, networking client, Pi service, or ADRs. (Optional
follow-up, not part of this change: tick the `lime` app-row step in
`docs/roadmap.md` once created-time + poster also land -- duration alone is only
part of that line, so leave it for now.)

## Verification

- **Unit tests:** run the app test suite (`just` task if present, e.g.
  `just app-test`, otherwise the Xcode test action). Confirm the new
  `clipDuration` and `clipMetadata` cases pass and existing `FormattersTests`
  stay green.
- **Simulator / device run:** launch the app, open the home screen with a clip
  list available (mock-Pi or real Pi). Confirm each row's secondary line reads
  `MM:SS - <size>` (e.g. `00:34 - 37.3 MB`), and that a clip whose `dur_ms` is
  `null` shows the byte size alone with no stray separator or placeholder.
- **Dynamic Type:** bump the text size; the secondary line should scale and wrap
  via the existing `adjustsFontForContentSizeCategory` / automatic row height.

## Follow Up

- `just app-test` failed on `ProgressivePlaybackIntegrationTests.livePullThroughProgressiveSegmenterProducesPlayableItem` in `app/DanCam/DanCamTests/Media/ProgressivePlaybackIntegrationTests.swift#livePullThroughProgressiveSegmenterProducesPlayableItem`; investigate the progressive playback integration failure separately.
