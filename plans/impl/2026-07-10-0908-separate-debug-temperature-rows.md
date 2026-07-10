# Plan: Debug screen -- separate max-temp rows

## Context

The Debug screen shows current + max temperature as one value cell per sensor:
`"42.0 C (max 43.0)"` rendered as a two-tint attributed string. On the Camera
row the combined string is too wide to sit beside the "Camera temp" label, so
the valueCell layout stacks/wraps -- ugly and inconsistent with the SoC row.

Decision (discussed with Dan): split each temp into two plain value rows, the
standard Settings "one fact per row" idiom:

```
SoC temp       42.0 C
SoC max        43.0 C
Camera temp    45.5 C
Camera max     47.0 C
```

This is strictly less code than today: the `detail`/`detailTint` fields on
`DebugRow.value` and the entire attributed-string branch in the value cell
registration exist only for the max suffix, and get deleted. Each of the four
values keeps its own warn/critical tint via the existing per-row `tint`.

This reverses an accepted decision: ADR 23's 2026-07-10 note explicitly
specifies combined `current (max ...)` rows with independently tinted parts.
The repo requires pivots to be recorded in the same change, so this plan appends
a superseding note to ADR 23 (see "0. ADR" below). The reverted decision lives
in an inline note within ADR 23, not a standalone ADR, so it is superseded in
place with a new note rather than by spawning a whole new ADR for a debug
presentation tweak.

## Changes

### 0. ADR (record the pivot -- do this in the same change)

- Append a new dated note to `app/docs/design/23-2026-07-09-debug-tab-sse-only-telemetry.md`,
  immediately after the existing 2026-07-10 "Current + max temperatures" note,
  recording the pivot and superseding that note's render detail. Suggested
  shape:

  > **Note (2026-07-10, supersedes the render detail above): separate
  > current/max rows.** The Debug SoC and camera temperatures now render as two
  > plain single-fact value rows each (`SoC temp` / `SoC max` / `Camera temp` /
  > `Camera max`) instead of a combined `current (max ...)` value -- the
  > combined string was too wide to sit beside the "Camera temp" label and wrapped
  > inconsistently with the narrower SoC row. Max rows are always present,
  > showing `"--"` when unknown, and each row keeps its own warn/critical tint
  > (SoC 70/80 C, camera 50/55 C). The thresholds and Home's sensor-only
  > current-only pill are unchanged.

- No new ADR file is created (the reverted decision is an inline note, not a
  standalone ADR), and ADR 23's Status stays Accepted -- only the inline
  temperature-render note is superseded, not the SSE-only-telemetry decision the
  ADR exists to record. Because no ADR filename/sequence changes, `just
  adr-check` is not part of this change's verification.

### 1. `app/DanCam/DanCam/Features/Debug/DebugScreen.swift`

- `DebugValueID`: add `socMaxTemperature` and `cameraMaxTemperature`.
- `DebugRow.value`: delete the `detail: String?` and `detailTint: DebugTint`
  associated values; the case becomes `value(id:label:value:tint:)`. Delete the
  now-redundant `static func value(id:label:value:tint:)` convenience (the case
  itself now has that exact signature, so existing call sites compile
  unchanged). Shrink the 6-slot pattern match in `var id` to 4 slots.
- `tempRow` becomes a two-row builder (e.g. `tempRows`) returning
  `[current row, max row]`:
  - current row: unchanged -- `Formatters.temperature($0, precise: true)` or
    `"--"`, tint from `tempTint(warning(reading?.current))`.
  - max row: same formatting applied to `reading?.max` (so `"43.0 C"` /
    `"--"`), tint from `tempTint(warning(reading?.max))`. No parentheses, no
    `temperatureNumber`.
- `cameraRows` emits: State, SoC temp, SoC max, Camera temp, Camera max.
  Labels: `"SoC temp"` / `"SoC max"` / `"Camera temp"` / `"Camera max"`.
- Max rows are **always emitted**, showing `"--"` when max is unknown
  (deliberate change from today's hide-when-absent detail). Rationale: matches
  the screen's per-field placeholder convention (`"--"` everywhere when
  offline/connecting) and keeps row identity stable so the diffable data
  source reconfigures in place instead of inserting/removing rows when the
  first temp event lands.

### 2. `app/DanCam/DanCam/Features/Debug/DebugViewController.swift`

- Value cell registration: delete the `if let detail` attributed-string branch;
  always use plain `content.secondaryText` + `secondaryTextProperties`
  (font/color), i.e. what the `else` branch does today. Pattern match shrinks
  to 4 slots.
- Context-menu handler (`contextMenuConfigurationForItemAt`): shrink its
  `.value` pattern match to 4 slots.
- Replace `secondaryAttributedTextForTesting(_:)` with a plain-text equivalent
  (e.g. `secondaryTextForTesting(_ id: DebugValueID) -> (text: String?, color:
  UIColor?)`) reading `secondaryText` + `secondaryTextProperties.color` from
  the presented cell's configuration. This preserves coverage of the value
  string and the DebugTint -> UIColor mapping only; it does not assert the
  monospaced font (dropping the attributed-string path removes no font
  behavior worth a brittle font-configuration assertion).

### 3. `app/DanCam/DanCam/Support/Formatters.swift`

- Delete `temperatureNumber(_:)` -- its only caller was the `(max 43.0)`
  detail string.

### 4. Tests

- `app/DanCam/DanCamTests/Features/Debug/DebugScreenTests.swift`:
  - Rework `temperatureRowsComposeCurrentAndMaxWithIndependentTints` into a
    separate-rows assertion. Because the visible change is a Settings-style
    presentation (labels, order, one-fact-per-row), assert the Camera
    section's **complete ordered `rows` array**, not just per-ID values/tints
    -- so a swapped, duplicated, mislabeled, or reordered row fails. Using the
    same fixture (soc current 45 / max 72 -> warn max; sensor max-only 55 ->
    critical max, current `"--"`), the expected `camera` section rows are, in
    order: `State` (neutral), `.value(id:.socTemperature, label:"SoC temp",
    value:"45.0 C", tint:.neutral)`, `.value(id:.socMaxTemperature,
    label:"SoC max", value:"72.0 C", tint:.warn)`,
    `.value(id:.cameraTemperature, label:"Camera temp", value:"--",
    tint:.neutral)`, `.value(id:.cameraMaxTemperature, label:"Camera max",
    value:"55.0 C", tint:.critical)`. Add an empty-world case asserting the
    same ordered array shape with all four temp values `"--"` and neutral
    tints (max rows present, was: detail nil). Reuse the existing
    `sections.first(where: { $0.id == .camera })?.rows` access via a small
    helper if convenient; `DebugRow` is `Equatable`, so compare arrays directly.
  - Delete the `detail(for:in:)` / `detailTint(for:in:)` helpers; shrink the
    remaining `.value` pattern matches in `value(for:)` / `tint(for:)` to 4
    slots.
- `app/DanCam/DanCamTests/Features/Debug/DebugViewControllerTests.swift`:
  - Replace `temperatureValueRendersIndependentAttributedTintRuns` with a test
    using the new plain-text helper: soc current 45 / max 72 -> temp row
    renders `"45.0 C"` in `.secondaryLabel`, max row renders `"72.0 C"` in
    `.systemOrange`.
- `app/DanCam/DanCamTests/Support/FormattersTests.swift`:
  - Delete `temperatureNumberFormatsWithoutUnit`.

Blast radius is confirmed complete: the only 6-slot `.value` pattern matches
in the repo are in the files above, and `temperatureNumber` has no other
callers.

## Verification

- `just app-test` -- full Swift Testing unit suite (covers the reworked
  DebugScreen/DebugViewController/Formatters tests). Independent-tint
  verification lives here (fixtures with warn/critical maxes), since the mock
  Pi cannot produce those temperatures.
- `just app-lint` -- clean full-recompile warning gate (catches any leftover
  unused helper).
- Manual: run the app against `just raspi-mock`, open Debug, confirm the
  Camera section shows the four temp rows -- `SoC temp` / `SoC max` /
  `Camera temp` / `Camera max`, in that order -- on one line each with no
  wrapping. Note the mock cannot exercise tints: its fake camera temp ramps
  40.0->48.0 C (below the 50 C warn threshold) and macOS exposes no SoC
  temperature, so SoC rows read `"--"`. Tint behavior is covered by the
  automated fixtures above, not this manual pass.
