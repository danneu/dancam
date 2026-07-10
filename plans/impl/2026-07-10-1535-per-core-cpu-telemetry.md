# Plan: Per-core CPU utilization telemetry on Debug

## Outcome

Add per-core CPU utilization to the Pi's snapshot-first telemetry stream and render it
on the iOS Debug tab. Each runtime-discovered logical core reports:

- current utilization over the latest sampling interval;
- 1 minute, 5 minute, and 15 minute exponentially weighted moving averages (EWMAs).

This is diagnostic telemetry for finding a single saturated core, especially while
preview and recording run together. It does not add aggregate CPU, load average, a
peak field, Home UI, or an automatic thermal/load policy.

Source brief: `plans/wip/cpu-telemetry-brief.md`.

## Resolved design

### Wire shape

The snapshot always contains a nonoptional `cpu` object:

```json
"cpu": {
  "cores": [
    {
      "id": 0,
      "current_pct": 98,
      "one_minute_pct": 74,
      "five_minute_pct": 52,
      "fifteen_minute_pct": 40
    }
  ]
}
```

The additive delta is the complete replacement value for that slice:

```json
{
  "type": "cpu_changed",
  "cores": [
    {
      "id": 0,
      "current_pct": 98,
      "one_minute_pct": 74,
      "five_minute_pct": 52,
      "fifteen_minute_pct": 40
    }
  ]
}
```

Rules:

- `cores` is sorted by Linux logical CPU ID. Count and IDs come from `/proc/stat` at
  runtime; neither side assumes four cores, contiguous IDs, or array index == core ID.
- Each percentage is an integer from 0 through 100. Whole-percent reporting is the
  service-side coarsening boundary; smoothing retains full precision internally.
- On the first counter observation for a core, or after that core's counters reset,
  all four percentages for that core are `null`. The next valid counter pair seeds and
  reports all four together.
- `cores: []` means no CPU topology/sample is currently available. This is the initial
  non-Linux mock state and the honest clearing state after a whole-file read/parse
  failure.
- `cpu_changed` carries the full `cores` array, not a per-core patch. The app replaces
  its CPU slice atomically, matching snapshot replacement and avoiding topology merge
  rules in the client.

The verbose duration field names are deliberate: they state units, avoid implying a
standalone kernel load average, and decode predictably through the app's existing
`JSONDecoder.KeyDecodingStrategy.convertFromSnakeCase`. Do not use `avg_1m_pct`; the
digit/underscore shape does not map to the natural Swift property name under that
strategy.

### Counter and smoothing semantics

Create a dedicated stateful CPU sampler rather than putting rate history in `World`.
`World` remains the pure fold/change-detection boundary; the telemetry task owns the
sampling lifecycle.

For each `cpuN` line in `/proc/stat`:

- Parse Linux's `user`, `nice`, `system`, `idle`, `iowait`, `irq`, `softirq`, and
  `steal` counters with checked arithmetic.
- Exclude `guest` and `guest_nice` from `total` because Linux already includes them in
  `user` and `nice`; adding them again would double-count work.
- Define idle ticks as `idle + iowait`, and utilization over two counter readings as
  `100 * (delta_total - delta_idle) / delta_total`, clamped to 0...100.
- Validate the two *derived* deltas the formula uses, not per-field monotonicity. Linux
  documents that individual `/proc/stat` fields are not all monotonic -- `iowait` in
  particular can decrease between reads (see the kernel `proc.txt` note on
  `/proc/stat`), so a per-field "any counter went down" regression check would falsely
  fire on a normal sample. The only condition that makes the utilization formula
  impossible is `delta_total <= 0` (a zero or negative total delta). Treat that single
  condition as an invalid derived observation. A `delta_idle` that is negative (from an
  `iowait` decrease) or that exceeds `delta_total` while `delta_total > 0` is still a
  valid, computable sample: compute `delta_total - delta_idle` and let the 0...100 clamp
  absorb the out-of-range busy fraction rather than resetting the core.
- Skip the aggregate `cpu` line completely.

The sampler retains one tracker per logical core ID. A tracker holds the previous
counter sample/time plus three unrounded EWMA accumulators. For a valid utilization
sample `x`, actual elapsed time `dt`, and time constant `tau`:

```text
decay = exp(-dt / tau)
next = previous * decay + x * (1 - decay)
```

Use `tau = 60s`, `300s`, and `900s`. Use actual monotonic elapsed time between that
core's counter reads, not the nominal 2 second task interval, so delayed ticks get the
right weight. Seed every EWMA to the first valid utilization sample rather than zero;
this avoids a knowingly low reading after service start. The service restart is the
smoothing-history boundary.

Topology and failure behavior:

- A newly appearing core gets a null baseline row, then valid percentages after its
  next counter sample.
- A disappearing core is removed immediately from the next complete CPU value.
- An invalid derived observation for a core -- `delta_total <= 0`, which covers both a
  zero total delta (identical consecutive reads) and a negative one (a genuine counter
  reset/rollover) -- resets only that core's tracker (clears its previous sample and all
  three EWMA accumulators) and publishes its null baseline. Recovery then follows the
  same two-sample path as a fresh core: the next read re-seeds the baseline, and the read
  after that produces the first valid percentages and EWMA seeds. This is one uniform
  reset rule, so all reported fields for the core go null together and no stale current
  value or partial EWMA history survives.
- A `/proc/stat` read or whole-file parse failure clears every tracker and publishes
  `cores: []`. The next successful read establishes new baselines. This prevents a
  heartbeat-fresh connection from presenting stale CPU as current.

Round the current value and all three raw EWMAs to the nearest whole percentage only
when constructing reported telemetry. Feed raw current utilization into the raw EWMA
state; never feed rounded wire values back into smoothing.

### Change detection and event rate

Store the reported whole-percent `Cpu` value in `World`. Compare the entire value at
each telemetry input and emit one `cpu_changed` only when it differs. This includes
topology changes, null-to-value transitions, and clearing to `cores: []`.

The instantaneous field means a busy machine can still produce one CPU delta on every
2 second telemetry tick. That is intentional and bounded at 0.5 Hz: current load is the
requested diagnostic signal. Whole-percent projection prevents invisible fractional
EWMA drift from creating changes, and the complete four-core payload still costs only
one event per tick. Do not add a second timer or debounce layer.

### Debug presentation

Add a `CPU per core` section after Camera and before Storage. Use one full-width custom
row per runtime core, not four standard value rows and not one long right-aligned value
cell. Each row renders:

```text
Core 0
Now 98% | 1m 74% | 5m 52% | 15m 40%
```

This keeps four cores compact while avoiding the wrapping problem that caused Debug's
combined current/max temperature rows to be removed. The detail is a full-width,
monospaced-digit, multiline label and remains neutral. The core title alone is tinted
from the 1 minute EWMA: orange at >= 85% and red at >= 95%. Current is too bursty for
alert color, while the 5 minute and 15 minute values react too slowly for the primary
diagnostic highlight. The thresholds indicate lost per-core headroom on Debug; they are
not thermal safety thresholds or product alerts.

Null fields render `--` in their column. `cores: []` renders one stable plain value row
`CPU --` so connecting, the macOS mock, and read failure never produce an empty or
apparently broken section. Offline last-known behavior is inherited from `Link`: the
existing staleness banner remains the qualifier and the last CPU rows remain visible.

Do not add an explicit per-core peak. A short utilization spike would quickly pin it at
100%, duplicating neither useful sustained history nor the temperature max semantics.

## Implementation

### 1. Add the CPU counter sampler and reported types

Create `raspi/service/src/cpu.rs` and register it in
`raspi/service/src/lib.rs#module declarations`.

Define wire-facing types:

```rust
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct CpuCore {
    pub id: u32,
    pub current_pct: Option<u8>,
    pub one_minute_pct: Option<u8>,
    pub five_minute_pct: Option<u8>,
    pub fifteen_minute_pct: Option<u8>,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct Cpu {
    pub cores: Vec<CpuCore>,
}
```

Give `Cpu` an `empty()` constructor. Keep raw counter records, EWMA state, parsing,
rate calculation, and the stateful `CpuSampler` private or `pub(crate)` as required by
the telemetry task and unit tests. No dependency is needed: use `f64::exp` from the
standard library.

Split IO from behavior:

- `read_proc_stat()` is one portable implementation on every platform: it reads
  `/proc/stat` unconditionally and maps the result to available/unavailable telemetry.
  On macOS the file simply does not exist, so the read returns `io::ErrorKind::NotFound`;
  treat that as "no CPU topology available" (the honest `cores: []` path), not an error
  to surface. Do not `cfg`-gate this function: a `cfg(target_os = "linux")` branch would
  leave the production read path uncompiled during the Mac `raspi-test` and `raspi-check`
  gates, so a mistake in it would only surface at cross-build/deploy time. A single
  compiled-everywhere path keeps the real logic under the normal test gates.
- `parse_proc_stat(raw)` is a pure parser returning ID-keyed/sorted counter records.
- `CpuSampler::sample()` performs the real read and routes success/failure into its
  state.
- An observation method accepting parsed counters plus an injected `Instant` (or an
  equivalent monotonic duration) drives deterministic sampler tests without sleeping.

The parser must reject a wholly malformed/empty per-core set, duplicate logical IDs,
missing required base counters, numeric overflow, and invalid CPU labels. A malformed
unrelated `/proc/stat` line is ignored; a malformed line claiming to be a `cpuN` line
makes the CPU read fail rather than silently dropping a core.

### 2. Thread CPU through the Pi telemetry fold

Update the existing memory/temperature path end to end:

- `raspi/service/src/events.rs#fn spawn_telemetry`: construct one `CpuSampler` inside
  the spawned task, before the interval loop, and pass `sampler.sample()` on each tick.
  The first `tokio::time::interval` tick remains immediate and establishes baselines.
- `raspi/service/src/backend.rs#trait Backend::update_telemetry` and both backend
  implementations: add the `Cpu` argument.
- `raspi/service/src/camera/mod.rs#impl Backend for CameraBackend`: forward CPU.
- `raspi/service/src/event_hub.rs#fn update_telemetry`: forward CPU in
  `Input::Telemetry`.
- `raspi/service/src/world.rs#enum Input::Telemetry`: add CPU.

In `raspi/service/src/world.rs#struct World`, add `cpu: Cpu`, initialize it empty, and
clone it into `World::snapshot`. In `World::apply_telemetry`, compare/store the already
whole-percent CPU value and emit `Event::CpuChanged { cores }` after the existing
storage/temp/memory events when it changes. Emitting CPU last preserves current event
ordering and makes the addition explicit in full-vector tests.

In `raspi/service/src/events.rs`:

- add `Event::CpuChanged { cores: Vec<CpuCore> }`;
- add `pub cpu: Cpu` to `Snapshot` next to `mem`;
- add canonical event construction/name mapping for `cpu_changed` and CPU data in the
  canonical snapshot.

Adding a required Rust snapshot field affects test fakes outside the telemetry path.
Sweep `rg 'Snapshot \\{' raspi/service` and give every literal an explicit `cpu`
value; use `Cpu::empty()` unless the test is about the contract/status projection.

### 3. Extend the golden wire contract and Pi-side documentation

Update the shared corpus atomically with Rust serialization:

- add `contract/events/cpu_changed.json`;
- add `cpu` to `contract/events/snapshot.json`;
- add a `CPU Telemetry` section to `contract/events/README.md` documenting replacement
  semantics, runtime IDs/order, integer/null rules, empty/unavailable behavior, EWMA
  time constants, counter baseline/reset behavior, and service-restart lifetime.

Use at least two nonidentical IDs in the corpus (for example 0 and 2), and make one core
a null baseline in `cpu_changed.json`. This ensures both consumers prove that IDs are
data, array length is runtime-defined, and nullable baseline values round-trip.

Append a 2026-07-10 CPU telemetry note to
`raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md`, alongside the existing
telemetry-coarsening and max-temperature notes. Record the new snapshot/delta shape,
per-core rationale, whole-percent boundary, actual-time EWMAs, and clear/reset
semantics. This deepens the existing transport/telemetry decision; it does not require
a new ADR.

### 4. Decode and fold CPU in the app

In `app/DanCam/DanCam/Networking/Events/CameraEvent.swift`, add matching app models:

```swift
nonisolated struct CPU: Codable, Equatable, Sendable {
    var cores: [CPUCore]
    init(cores: [CPUCore] = []) { self.cores = cores }
}

nonisolated struct CPUCore: Codable, Equatable, Sendable {
    var id: Int
    var currentPct: Int?
    var oneMinutePct: Int?
    var fiveMinutePct: Int?
    var fifteenMinutePct: Int?
}
```

The selected wire names map through the existing snake-case strategy, so do not add a
special decoder or misleading digit-heavy coding keys.

- Add `case cpuChanged(CPU)` to `CameraEvent`; decode the event body directly as `CPU`
  because its flat `cores` field matches the model.
- Add `var cpu: CPU` to `World` and replace it wholesale in
  `World.folding#case cpuChanged`.
- Extend `CameraEvent.logLabel` with `cpuChanged`.
- Add a compact, whitespace-free `cpu_cores=` token to
  `AppFeature.State.logSnapshot`, ordered as received and containing ID/current/1m/5m/
  15m values. This keeps reducer transition logs honest instead of reporting a CPU
  fold only as `(state changed)`, and makes exported state snapshots diagnostically
  useful.

Update `app/DanCam/DanCamTests/Support/CameraSamples.swift#CameraSamples.world` with a
default empty CPU parameter. Sweep direct `World(` construction; the corpus expectation
must provide its explicit CPU value, while helpers should default to empty.

### 5. Add CPU formatting, warning semantics, and Debug rows

In `app/DanCam/DanCam/Support/Formatters.swift`:

- rename `TempWarning` to `TelemetryWarning`, since the two-level warning value is no
  longer temperature-only; update temperature callers/tests mechanically;
- add CPU warn/critical thresholds 85 and 95;
- add a formatter returning `"98%"` or `"--"` from an optional integer percentage;
- add `cpuWarning(for:)`, reusing the inclusive generic warning comparison.

In `app/DanCam/DanCam/Features/Debug/DebugScreen.swift`:

- add `.cpu` to `DebugSectionID`;
- add `.cpuUnavailable` to `DebugValueID`;
- add `.cpuCore(Int)` to `DebugRowID`;
- add `DebugRow.cpuCore(id:detail:tint:)`, with its ID derived from the real logical
  core ID;
- insert the `CPU per core` section after Camera;
- project empty CPU to the `CPU --` value row and populated CPU to one ordered custom
  row per core;
- build the detail exactly from the four formatter results and derive the row tint only
  from `oneMinutePct`;
- generalize `tempTint` to `telemetryTint` for temperature and CPU callers.

In `app/DanCam/DanCam/Features/Debug/DebugViewController.swift`, add a dedicated cell
registration and `DebugCPUConfiguration`/`DebugCPUContentView`, following the existing
`DebugGaugeConfiguration` custom-content pattern:

- preserve the system list cell margins;
- use a body-style title label and a scaled monospaced-digit caption/detail label;
- allow the detail label to wrap instead of compressing it into value-cell trailing
  space;
- color the title with the row's sustained tint and keep the metric detail secondary;
- expose one accessibility element with label `Core N` and an expanded value such as
  `Now 98 percent, 1 minute 74 percent, ...` rather than reading punctuation. A null
  metric expands to the spoken word `unavailable`, not the visual `--` (for example
  `Now unavailable, 1 minute 74 percent, ...`), so a null-baseline core reads as words
  rather than VoiceOver announcing `--` as punctuation;
- add a focused test helper that returns the presented CPU configuration/color, like
  `presentedGaugeForTesting`.

Extend the row switch exhaustively; CPU rows have no selection or context menu.

### 6. Record the app presentation and roadmap deepening

Append a 2026-07-10 note to
`app/docs/design/23-2026-07-09-debug-tab-sse-only-telemetry.md` covering the new
full-width per-core rows, four displayed timescales, empty placeholder, and the 1 minute
85/95 title tint. This is an additive Debug presentation note, not a new ADR.

Add a completed deepening bullet under `docs/roadmap.md#Swoop fern` when the feature
lands: per-core current plus 1m/5m/15m CPU telemetry flows from `/proc/stat` through
snapshot/delta events to Debug. Do not claim aggregate load or policy automation.

## Behavioral test plan

### Pi CPU sampler (`raspi/service/src/cpu.rs`)

- Parse a representative `/proc/stat` with aggregate + multiple `cpuN` lines; assert
  numeric ID ordering and that the aggregate line is absent.
- Assert guest fields are not double-counted and `idle + iowait` is treated as idle.
- Reject duplicate IDs, malformed claimed core lines, missing base fields, overflow,
  and a file with no per-core lines.
- Derive known 0%, 25%, and 100% utilization deltas without underflow.
- Treat `delta_total <= 0` as the single invalid-observation condition: a zero total
  delta (identical consecutive reads) and a negative total delta (a counter reset) each
  reset that core's tracker and publish its null baseline, then a further two samples
  recover valid percentages -- assert that full re-seed path, not just the null step.
- An `iowait` decrease that still leaves `delta_total > 0` is a valid sample: assert it
  computes a clamped 0...100 percentage and does not reset the core or erase its EWMA
  history. This guards against a per-field monotonicity check that would falsely fire on
  Linux's non-monotonic `iowait`.
- First observation emits runtime IDs with all percentages null; the second seeds all
  three EWMAs to current.
- A deterministic step with a known `dt` matches the 60/300/900 second formula within a
  small floating-point tolerance before wire rounding.
- A delayed observation uses injected actual elapsed time, proving the result does not
  assume a 2 second tick.
- Sub-percent changes retain raw EWMA precision internally while reported percentages
  round to whole numbers.
- One core appearing, disappearing, or regressing resets only that core and preserves
  other core histories.
- Whole-read failure clears all output/history; recovery needs a baseline and then a
  second sample before percentages return.

These tests cover both new behavior and the plan's claims about Linux counter meaning,
runtime topology, initialization, actual-time smoothing, and failure honesty. They do
not assert private container choices or helper decomposition.

### Pi world and contract

- `world.rs`: first baseline CPU changes empty -> null rows and emits one full
  `CpuChanged`; repeating the identical reported value emits nothing; a whole-percent
  change emits; clearing after populated emits `cores: []`; every state is reflected in
  `World::snapshot`.
- `events.rs#events_match_the_golden_corpus`: snapshot and `cpu_changed` serialize and
  deserialize exactly against the new shared fixtures.
- `raspi/service/tests/status.rs#status_returns_snapshot_wire_contract`: assert the
  one-shot status body contains the same CPU object shape (including nullable values),
  proving the `/v1/status` claim rather than relying only on direct enum serialization.
- Update unrelated snapshot literals only for compilation; do not add redundant CPU
  assertions to clips/preview tests.

### App decode, fold, logging, and projection

- `CameraEventCorpusTests`: the new fixture must not decode as unknown; representative
  snapshot and `cpu_changed` equality asserts include noncontiguous IDs, values, and a
  null baseline.
- `AppFeatureTests#telemetryEventsFoldWorldSlices`: send `cpuChanged` and assert only
  the CPU slice is replaced.
- `AppTransitionLogTests`: a CPU delta produces an `event.cpuChanged` label and a
  meaningful `cpu_cores` token diff.
- `FormattersTests`: percentage/null display and inclusive 85/95 CPU warning thresholds;
  update renamed `TelemetryWarning` temperature expectations.
- `DebugScreenTests`: assert the complete CPU section order and rows for noncontiguous
  IDs, mixed values/nulls, and neutral/warn/critical 1 minute readings; assert
  `cores: []` produces exactly the placeholder row.
- `DebugViewControllerTests`: assert a projected CPU row uses the full-width custom
  configuration, expected detail, title tint, and accessibility label/value. Include a
  mixed null/value row (a null-baseline metric alongside populated ones) and assert its
  accessibility value speaks `unavailable` for the null metric while the visual detail
  still shows `--`. Existing value/gauge registrations remain unchanged.

Do not add snapshot tests coupled to private EWMA/container structure or pixel/snapshot
tests for the custom row. The pure row projection plus presented configuration tests
cover behavior without tying the suite to UIKit hierarchy details.

## Verification

Run from the repository root:

1. `just raspi-test`
2. `just raspi-check`
3. `just app-test`
4. `just app-lint`
5. `just adr-check`

Then verify both runtime tracks honestly:

- macOS mock: run `just raspi-mock`, connect the simulator, and confirm Debug shows the
  `CPU --` placeholder. macOS has no `/proc/stat`; the mock is not expected to invent
  Pi CPU data.
- Real Pi: deploy with `just raspi-deploy`, open preview and record, and confirm four
  rows appear for the Zero 2 W while count/IDs remain runtime-driven. Over SSH, pin a
  disposable busy loop to one core with `taskset`, confirm that core's current value
  approaches 100% and its 1 minute value/title tint rises while peer cores stay lower,
  then kill the loop. Automated deterministic tests cover the slower 5 minute and
  15 minute math; a 15 minute manual wait is not a merge gate.

## Commit shape

Land this as one coherent green commit:

`feat: add per-core CPU telemetry to Debug`

The corpus is shared by both consumers: splitting Pi/contract from app would leave an
intermediate commit where the app's golden-corpus test sees `cpu_changed` as unknown.
One end-to-end commit keeps the versioned boundary and both round-trip suites coherent.

## Out of scope

- Aggregate CPU utilization or a summary row.
- Linux load average or runnable-task counts.
- A max-since-service-start CPU field.
- Process-level attribution or claiming that preview caused observed load.
- CPU frequency, throttling flags, thermal response, or automatic policy.
- Home or CarPlay CPU surfacing.
