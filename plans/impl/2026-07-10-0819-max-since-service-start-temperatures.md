# Plan: Max-since-service-start temperatures (current + max on the Debug screen)

## Context

The Debug screen shows only the instantaneous SoC and camera-sensor temperatures.
The unit lives on a windshield in Texas heat and the camera sensor is rated to
~50 C, so the reading that matters most -- "how hot did it get while I wasn't
looking" -- is exactly the one the app can miss over its intermittent Wi-Fi link.
This change tracks a max-since-service-start per temperature on the Pi (which
observes every sample) and surfaces it next to the current value on the Debug
screen.

The reset boundary is deliberately "service start," not "reboot": the max lives
in the service's in-memory `World`, and `raspi/dancam.service` sets
`Restart=on-failure` / `RestartSec=2`, so a service crash-restart -- not just a
power-cycle -- clears the peak. Naming it "since boot" would overstate the
guarantee; the whole plan, ADR, roadmap, and test names use "since service
start."

All design decisions are settled (workshopped with Dan):

- Each temp becomes `{current, max}`. No min, no peak timestamp.
- Max is computed over the quantized values (existing nearest-0.5 C rule) and
  resets only when the service process restarts (including a crash-restart via
  `Restart=on-failure`). It survives camera restarts: when the camera child
  leaves `running`, sensor `current` reverts to null but sensor `max` persists.
- No new event mechanics: max can only change when current changes, so the
  existing `temp_changed` emission points suffice.
- Wire shape (snapshot `temp_c` and the `temp_changed` body; the event keeps its
  flat top-level `soc`/`sensor` keys, each becoming the nested object):
  `"temp_c": {"soc": {"current": 51.5, "max": 62.5}, "sensor": {"current": 43.5, "max": 49.0}}`
- Debug screen: inline range in the existing two rows -- `51.5 C (max 62.5)` --
  with current and max independently tinted so a past-hot peak stays visible
  after current recovers. `-- (max 49.0)` when current is null but max exists;
  plain `--` when both are null.
- SoC gains its own thresholds: warn 70 / critical 80 (today the SoC row is
  always neutral). Sensor keeps 50/55.
- HomeStatusPills stays sensor-only and current-only (mechanical shape
  adaptation; no SoC pill).

Two commits: raspi + contract first, then app. `just app-test` is transiently
red between them (the shared corpus reshapes); both land in one push, matching
the split-scope precedent of the recorder-session series.

---

## Commit 1 -- `feat(raspi): track max-since-service-start temps in world and contract`

### New Rust type (raspi/service/src/world.rs)

Replace `world.rs#TempC`'s two bare fields with a shared reading type used by
BOTH the snapshot and the event (kills today's shape duplication where
`events.rs#Event::TempChanged` re-declares flat fields):

```rust
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq)]
pub struct TempReading {
    pub current: Option<f32>,
    pub max: Option<f32>,
}

pub struct TempC {
    pub soc: TempReading,
    pub sensor: TempReading,
}
```

Plain derives, no serde attrs (matches existing convention: keys are literal
identifiers, `None` -> `null`). Methods on `TempReading`:

- `empty()` -- both `None`.
- `observe(&mut self, sample: Option<f32>) -> bool` -- quantizes internally via
  `world.rs#quantize_temp_value` (moving the invariant "readings hold only
  quantized values" into the type; call sites drop their own `.map(quantize...)`),
  dedupes on `current`, folds `max = max(max, current)` when the new current is
  `Some`, returns whether current changed. Dedupe-on-current stays sufficient:
  max can never move without current moving.
- `clear_current(&mut self) -> bool` -- nulls `current`, PRESERVES `max`,
  returns whether anything changed (replaces the `sensor.is_some()` check).

### World call sites (raspi/service/src/world.rs)

- `World::apply_telemetry` -- `if self.temp_c.soc.observe(soc_temp_c) { push
  Event::TempChanged { soc: ..., sensor: ... } }` (clones both readings, as the
  merged-pair emission does today).
- `World::apply_sensor_temp` -- keep the camera-`Running` guard; body becomes
  `observe` + emit-on-change.
- `World::apply`, `Input::CameraState` arm -- the sensor-clearing path becomes
  `self.temp_c.sensor.clear_current()`; this is the path that must NOT touch
  sensor max.

`camera.py` needs no change (it emits instantaneous celsius; max lives in World).

### Event + snapshot (raspi/service/src/events.rs)

- `Event::TempChanged { soc: TempReading, sensor: TempReading }`.
- `Snapshot.temp_c` keeps type `TempC` (now nested).
- Update `events.rs#tests::canonical_events` in lockstep with the corpus files.

### Contract corpus (contract/events/)

- `snapshot.json` -- `"temp_c": {"soc": {"current": 51.5, "max": 62.5},
  "sensor": {"current": null, "max": 49.0}}`. The null-current/Some-max sensor
  deliberately showcases the persist-through-camera-restart semantics.
- `temp_changed.json` -- `{"type": "temp_changed", "soc": {"current": 51.5,
  "max": 62.5}, "sensor": {"current": 43.5, "max": 49.0}}`.

### ADR amendment (raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md)

Add a dated note in the existing amendment style (near the 2026-07-09
"Telemetry coarsening" note, and/or beside the `GET /v1/status` temp note):

> **Note (2026-07-10): Max-since-service-start temperatures.** `temp_c.soc` and
> `temp_c.sensor` in the snapshot/status body, and the `temp_changed` body's
> `soc`/`sensor`, become nested `{current, max}` readings. `max` is the peak
> quantized value observed since the service process started; sensor `max`
> persists while sensor `current` reverts to null whenever the camera child
> leaves `running`, and only a service restart (including a crash-restart via
> `Restart=on-failure`) resets either max. Deepens `fern`.

### Rust tests

Update existing `world.rs#tests` asserts to the nested shape (mechanical:
`TempChanged { soc: Some(51.5), .. }` becomes readings), then behavior coverage:

- Max rises with current and survives a drop: soc 51.5 -> 62.0 -> 51.5 emits
  `soc: {current: 51.5, max: 62.0}` on the final change; snapshot agrees.
- `null_sensor_sample_clears_value` -- extend: after a 43.5 sample, a null
  sample emits `sensor: {current: None, max: Some(43.5)}`.
- `camera_leaving_running_clears_sensor_after_state_event` -- assert max
  persists through the clearing emission.
- After a camera restart resumes samples, a LOWER sample does not lower the
  surviving max; a higher one raises it.
- `raspi/service/src/camera/mod.rs#tests::stderr_sensor_temp_filters_non_finite_and_projects_each_sample`
  -- `.temp_c.sensor` asserts become `.temp_c.sensor.current`.
- `raspi/service/tests/camera_process.rs#supervisor_clears_sensor_temp_after_crash`
  -- update `wait_for_sensor_temp` to poll `.current`; after the fake crash
  assert `sensor.current == None` AND `sensor.max` is `Some(v)` with
  `v >= 40.0` (the fake camera's sawtooth starts at 40.0 rising 0.25/sample;
  exact peak is timing-dependent, so assert presence + floor, not equality).
- `raspi/service/tests/status.rs#status_returns_snapshot_wire_contract` --
  JSON paths become `temp_c.soc.current` / `.max` etc., each number-or-null.

Gate: `just raspi-test` and `just raspi-check` green.

---

## Commit 2 -- `feat(app): show current and max temps on Debug screen`

### Decode + world mirror (app/DanCam/DanCam/Networking/Events/CameraEvent.swift)

```swift
nonisolated struct TempReading: Codable, Equatable, Sendable {
    var current: Double?
    var max: Double?
    init(current: Double? = nil, max: Double? = nil) { ... }
}
nonisolated struct TempC: Codable, Equatable, Sendable {
    var soc: TempReading
    var sensor: TempReading
    init(soc: TempReading = TempReading(), sensor: TempReading = TempReading()) { ... }
}
```

Custom inits with defaults (memberwise has none) keep the many test literals
tight, e.g. `TempC(sensor: TempReading(current: 43.5))`.
`convertFromSnakeCase` is unaffected: `current`/`max` have no underscores, and
`max` is a legal property name.

- `CameraEvent` case becomes `.tempChanged(TempC)` -- the payload is
  semantically a TempC now. `CameraEvent.TempChangedPayload` becomes
  `{soc: TempReading, sensor: TempReading}` (still decoding the event's flat
  keys) and `init(from:)` wraps it into `TempC`.
- `World.folding` `.tempChanged` case: `next.tempC = tempC`.
- `Link.swift` needs no change (snapshot already fully resets World).

### Formatters (app/DanCam/DanCam/Support/Formatters.swift)

- Add `socWarnThreshold = 70.0`, `socCriticalThreshold = 80.0`.
- Add `socWarning(for:)`; refactor it and `sensorWarning(for:)` onto a shared
  private `warning(for:warn:critical:)` (inclusive `>=`, matching today).
- Add `temperatureNumber(_:) -> String` -- `%.1f`, POSIX locale, no unit --
  for the `(max 62.5)` suffix (the row's current part already carries the unit).

### Debug row model (app/DanCam/DanCam/Features/Debug/DebugScreen.swift)

- Extend the case:
  `case value(id: DebugValueID, label: String, value: String, tint: DebugTint, detail: String?, detailTint: DebugTint)`.
  Add a static overload `DebugRow.value(id:label:value:tint:)` that fills
  `detail: nil, detailTint: .neutral` so the ~dozen non-temp *construction*
  call sites don't churn (overload-by-arity against the case constructor; if
  the compiler balks, fall back to updating call sites mechanically).
- The overload shields construction only; every *destructuring* pattern match
  on the case breaks on the new arity and must move to the 6-tuple explicitly:
  - `DebugScreen.swift#DebugRow.id` -- `case .value(let id, _, _, _)` gains two
    `_` (or `case .value(let id, ...)`).
  - `DebugViewController.swift` context-menu / rendering matches:
    `case .value(_, let label, let value, let tint) = row` and
    `case .value(_, _, let value, _) = renderedRows[.value(.bootID)]` both gain
    two `_` (the `.value(.bootID)` *key* is the separate `DebugValueID`-keyed
    row identifier, not this case -- leave it alone).
- Before building, run an `rg` sweep to catch every affected site rather than
  trusting this list: `rg 'TempC\(|\.tempChanged|DebugRow\.value|case \.value|\.value\(id:'`
  across `app/`, and reconcile each hit (construction, pattern match, or the
  keyed-identifier `.value(...)` false positive).
- `cameraRows` builds both temp rows through one private helper
  `tempRow(id:label:reading:warning:)`:
  - value: `reading.current.map { Formatters.temperature($0, precise: true) } ?? "--"`
  - detail: `reading.max.map { "(max \(Formatters.temperatureNumber($0)))" }`
  - tint: from `warning(reading.current)`; detailTint: from `warning(reading.max)`
  - SoC row passes `Formatters.socWarning` (drops the hardcoded `.neutral`);
    sensor row passes `Formatters.sensorWarning`.
  - nil world -> both rows `--`, no detail. Generalize `sensorTint(_:)` into a
    `TempWarning? -> DebugTint` mapper.

### Rendering (app/DanCam/DanCam/Features/Debug/DebugViewController.swift)

In `valueRegistration` inside `DebugViewController#makeDataSource`:

- `detail == nil`: existing plain `secondaryText` path, untouched.
- `detail != nil`: compose `NSAttributedString("\(value) \(detail)")` with the
  existing scaled monospaced-digit font applied as an attribute over the whole
  string (attributed values override `secondaryTextProperties`, so the font
  must live in the attributes) and per-range `.foregroundColor`:
  `tint.color(default: .secondaryLabel)` on the value run,
  `detailTint.color(default: .secondaryLabel)` on the detail run. Set
  `content.secondaryAttributedText`.

Attributed text over a custom `UIContentConfiguration` (the
`DebugGaugeConfiguration` pattern) because `valueCell()`'s label/value layout is
preserved for free; a custom content view would re-implement that layout just to
color two runs. Diffing already reconfigures on `DebugRow` equality, so the new
fields participate automatically.

### Pills, logging, fixtures

- `HomeStatusPills.from` -- read `world.tempC.sensor.current` (sensor-only,
  current-only stays; no SoC pill).
- `AppFeature.State.logSnapshot` -- temp tokens become four:
  `temp_soc_c` / `temp_soc_max_c` / `temp_sensor_c` / `temp_sensor_max_c`
  (currents and maxes).
- `DanCamTests/Support/CameraSamples.swift#CameraSamples.world` -- default
  becomes `tempC: TempC = TempC()`.

### Swift tests

Mechanical shape updates (pattern: `TempC(soc: 51.5, sensor: nil)` becomes
`TempC(soc: TempReading(current: 51.5))`; `.tempChanged(soc:sensor:)` becomes
`.tempChanged(TempC(...))`): `CameraEventCorpusTests` (representative snapshot
assert gains the corpus's `{current: 51.5, max: 62.5}` / `{nil, 49.0}` values --
also add a representative assert for the nested `temp_changed` decode),
`EventsClientTests#emitsDecodedEvents` inline JSON, `AppFeatureTests`,
`AppTransitionLogTests` (new log token format), `HomeStatusPillsTests`,
`HomeViewControllerTests`, `StripCoordinationTests` and `LinkTests` (both hold
bare-Double both-field literals like `TempC(soc: 40, sensor: 41)` -> each field
becomes `TempReading(current: ...)`). This list is a starting point, not the
authority -- the `rg` sweep in the Debug-row-model section is what guarantees
every `TempC(`, `.tempChanged`, and `.value` site is found.

Behavior coverage:

- `FormattersTests` -- `socWarning` thresholds (69.9 -> nil, 70 -> warn,
  79.9 -> warn, 80 -> critical); `temperatureNumber` formatting.
- `DebugScreenTests` -- update the pattern-matching helpers (`tint(for:)`,
  `value(for:)`) for the extended case, binding `detail`/`detailTint` too.
  `semanticTintsCoverStorageCameraTimeAndRecorderError`: soc 70 now asserts
  `.warn` (was `.neutral` -- deliberate flip from the new thresholds); add soc
  80 -> `.critical`. New composition/tint test: soc `{current: 45.0, max: 72.0}`
  renders value `45.0 C` (neutral) + detail `(max 72.0)` (warn); sensor
  `{current: nil, max: 55.0}` renders `--` + `(max 55.0)` (critical detail);
  both-nil renders `--` with nil detail.
- `DebugViewControllerTests` -- one rendering test in the existing
  embed-in-window style: a temp row with differing tints produces
  `secondaryAttributedText` with two distinct foreground-color runs.
- `HomeStatusPillsTests` -- new regression case pinning the current-only
  contract: sensor `{current: nil, max: <critical>}` (and a variant with a
  *safe* current under a critical max) yields `tempWarning == nil`. The
  existing cases prove SoC is ignored and that a sensor current at threshold
  produces a pill, but none distinguish sensor `current` from sensor `max`;
  without this a future change reading `sensor.max` would leave a permanent
  Home warning after the sensor cools, and no test would catch it.

### ADR amendment (app/docs/design/23-2026-07-09-debug-tab-sse-only-telemetry.md)

ADR 23 is the owning record for Debug telemetry -- its Decision fixes the
render-from-`link` projection, the semantic rows, and "Camera sensor temperature
uses the existing warning thresholds." This change alters that surface, so per
the repo's pivot-updates-its-decision rule it needs a dated note (same style as
the app ADRs, placed just after the metadata block, before Context):

> **Note (2026-07-10): Current + max temperatures.** `temp_c.soc` and
> `temp_c.sensor` are now nested `{current, max}` readings (see raspi ADR 02's
> 2026-07-10 note for the wire shape and the max-since-service-start semantics).
> The Debug SoC and camera rows render `current (max ...)` with the current and
> max parts independently tinted, so a past-hot peak stays visible after current
> recovers. The SoC row gains its own warn/critical thresholds (70/80 C); the
> camera row keeps 50/55. Home's temperature pill stays sensor-only and
> current-only -- it never reflects `max`, so it clears when the sensor cools.

### Roadmap (docs/roadmap.md)

Add a deepening bullet under swoop `fern` (matching the existing sensor-temp
deepening entry): track max-since-service-start temperatures in the Pi world
(`{current, max}` per sensor on the wire; max resets on service restart, not
just reboot) and show `current (max ...)` with independent warn/critical tints
on the Debug screen; SoC gains 70/80 thresholds.

---

## Verification

1. After commit 1: `just raspi-test` (world unit tests, fake-camera
   integration incl. max-survives-crash, status wire shape) and
   `just raspi-check`.
2. After commit 2: `just app-test` and `just app-build`.
3. UI null-path check: `just raspi-mock` + app in the simulator -> Debug
   screen. On macOS the mock serves null temps (`sysfacts::soc_temp_c` reads a
   Linux sysfs path; `MockBackend` has no camera child), so both rows must show
   plain `--` with no max suffix.
4. Live E2E (the real payoff): `just raspi-deploy` to the Pi, connect the app,
   watch Debug show `current (max ...)`; the max must hold when current dips,
   and the sensor max must survive a camera-child restart. The fake-camera
   integration test covers the restart case deterministically if the Pi isn't
   on hand.

## Commit progress

- [x] 1. `feat(raspi): track max-since-service-start temps in world and contract`
- [ ] 2. `feat(app): show current and max temps on Debug screen`
