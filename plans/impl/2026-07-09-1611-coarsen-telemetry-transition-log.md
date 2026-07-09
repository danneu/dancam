# Plan: Coarsen telemetry change-detection + honest reducer transition log

## Context

The `/v1/events` stream is spammy in practice: the Pi samples telemetry every 2s
and `apply_telemetry` compares readings at full precision, so SoC temp jitter
(millidegree reads), 1 MiB memory wobble, and every byte written while recording
each fire a delta event. Separately, the app's reducer log line is dishonest:
`AppFeature.logTransition` compares only `logSummary`, which excludes telemetry
fields, so `storage_changed`/`temp_changed`/`mem_changed` events that DID change
app state print `(no change)`.

Two independent changes, one commit each:

1. **raspi:** quantize telemetry before compare-and-store -- temp to 0.5 C
   (nearest), mem quantum 1 MiB -> 16 MiB, storage to 64 MiB (per user decision).
2. **app:** three-tier transition log using true state equality, with a compact
   field diff for changes invisible to the summary.

The per-fact delta event design itself is sound and stays; the wire contract
(`contract/events/`) is untouched -- its fixtures are hand-authored wire-shape
data built directly (`events.rs#fn fixture`), so they never pass through
`apply_telemetry` and need no quantization to stay valid. The literals are not
themselves on-grid (e.g. `snapshot.json` `used: 1000000000` is not a 64 MiB
multiple, `mem.total: 512000000` is not a 16 MiB multiple), and they do not need
to be -- they exercise decoder round-trip, not the quantizer.

---

## Change 1: raspi -- coarsen telemetry quanta

Commit: `feat(raspi): coarsen telemetry change-detection quanta`
(body: temp nearest 0.5 C, mem 1 -> 16 MiB, storage 64 MiB round-down; bounds
SSE delta chatter at the 2s sampling interval. Quantized values flow to
snapshot//v1/status by design -- mem already behaved this way. Records the
coarsening as a dated note on ADR 02.)

### Code (`raspi/service/src/world.rs`)

Mirror the existing `quantize_mem` pattern (quantize before compare AND store,
so drift cannot accumulate; snapshot clones stored values, so `/v1/status`
reports quantized values too, as mem already does).

- Hoist quanta to module-level `pub(crate)` consts next to `quantize_mem`
  (pub(crate) because the `event_hub.rs` test fix below needs `STORAGE_QUANTUM`):
  ```rust
  pub(crate) const MEM_QUANTUM: u64 = 16 * 1024 * 1024;
  pub(crate) const STORAGE_QUANTUM: u64 = 64 * 1024 * 1024;
  ```
- `quantize_mem`: drop its local 1 MiB `QUANTUM`, use `MEM_QUANTUM`.
- New `fn quantize_storage(DiskUsage) -> DiskUsage`: `round_down` both `used`
  and `total` by `STORAGE_QUANTUM` (reuse existing `round_down`).
- New `fn quantize_temp(TempC) -> TempC`: map both `soc` and `sensor` through
  `(v * 2.0).round() / 2.0` (nearest 0.5; multiples of 0.5 are exact in f32 so
  `PartialEq` stays stable).
- `raspi/service/src/world.rs#fn apply_telemetry`: quantize incoming `storage`
  (`.map(quantize_storage)`) and `temp_c` (`quantize_temp`) at the top; the
  existing compare/store/emit blocks then operate on quantized values. Mem
  block unchanged apart from the new quantum.

No changes to `snapshot`, `sysfacts.rs`, `spawn_telemetry`, or the golden corpus
(`events.rs#fn fixture` builds literals directly).

### ADR amendment (same commit)

Storage and temp move from full-precision to coarsened here (only `mem` was
quantized before), so the "raw telemetry deltas" wording in ADR 02 is now
misleading -- `raw` could be read as "full-precision sensor samples," and future
work must not reintroduce that assumption. Append a dated note to
`raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md` (append-only, in
the same style as its existing 2026-06-30 / 2026-07-01 notes -- do not rewrite
prior notes, and no new sequence-numbered ADR): clarify that the
`storage_changed` / `temp_changed` / `mem_changed` deltas, and the matching
`/v1/status` snapshot fields, expose service-coarsened *observed* values
(temp nearest 0.5 C, mem 16 MiB, storage 64 MiB round-down) -- still raw-state
deltas rather than threshold alerts (the point the original "raw" wording was
making), but deliberately not full-precision samples. Note that mem was already
coarsened, so this only widens an existing property to storage and temp.

### Tests

**`world.rs`:** replace `telemetry_emits_only_changed_quantized_values_and_tick_never_mutates`
with four tests expressing values via the consts so assertions are exact.
Shared seed sample (consider a small local `sample(...)` helper, precedent:
`clip()` in the same test module):

- storage `used: 149 * STORAGE_QUANTUM + 12_345`, `total: 476 * STORAGE_QUANTUM + 1`
- temp `soc: Some(51.5)` (on-grid), `sensor: Some(40.3)` (-> 40.5, proves
  nearest-rounding and the sensor path)
- mem: keep existing literals (`total: 512_000_123` -> `30 * MEM_QUANTUM`,
  `available: 256_999_999` -> `15 * MEM_QUANTUM`, `swap_total: 134_217_728`
  = `8 * MEM_QUANTUM` unchanged, `swap_used: 1` -> `0`)

1. `telemetry_first_sample_emits_quantized_payloads` -- `assert_eq!` the full
   event vec (Storage/Temp/Mem order, quantized payloads -- strengthens the old
   `matches!`-only asserts). Also assert the quantized values project into
   `world.snapshot(...)` (pins coarsened `/v1/status`).
2. `telemetry_sub_quantum_jitter_emits_nothing` -- second sample entirely
   within buckets (`used +60_000_000`, `soc 51.7` -> 51.5, `sensor 40.4` ->
   40.5, `available 256_999_500`) -> `.is_empty()`.
3. `telemetry_bucket_crossings_emit_quantized_values` -- third sample crossing
   all three buckets (`used: 152 * STORAGE_QUANTUM + 7`, `soc 51.8` -> 52.0,
   `available: 17 * MEM_QUANTUM + 9`) -> `assert_eq!` full vec with quantized
   payloads; sensor fed 40.3 again stays 40.5 so `TempChanged` carries it
   unchanged.
4. `tick_emits_heartbeat_and_never_mutates` -- the existing tail: seed, clone,
   `Input::Tick` -> `vec![Event::Heartbeat { .. }]`, world unchanged.

(f32 sanity, verified: 51.7 -> 51.5, 51.8 -> 52.0, 40.3/40.4 -> 40.5.)

**`event_hub.rs` (real risk found in review):**
`event_hub.rs#fn concurrent_connects_fold_to_final_projection_without_duplicate_ids`
drives telemetry with `DiskUsage { used: 1..=100, total: 100 }`. Under 64 MiB
quantization every sample becomes `{0, 0}`, so only one `StorageChanged` is
ever emitted -- the test still passes but its 100-events-interleaved-with-50-
connects coverage silently evaporates. Scale the driver so each iteration
crosses a bucket:
```rust
storage: Some(DiskUsage {
    used: used * crate::world::STORAGE_QUANTUM,
    total: 100 * crate::world::STORAGE_QUANTUM,
}),
```

Scaling alone is necessary but not sufficient: the existing assertions only fold
each connection's post-snapshot deltas and compare to the *final* snapshot, so a
connection that snapshots after all 100 inputs receives zero deltas and still
passes -- if the driver ever collapsed again, `folded == final` would hold
vacuously. Add a connection taken *before* the driver spawns and assert it
receives exactly 100 `StorageChanged` deltas (this pins that the post-snapshot
deltas actually flowed, which the final-snapshot fold cannot):
```rust
let mut pre = hub.connect();          // snapshots the initial storage=None state
// ... spawn driver, interleave the 50 connects, driver.await ...
let mut pre_deltas = 0;
while let Ok(seq_event) = pre.rx.try_recv() {
    if matches!(seq_event.event, Event::StorageChanged { .. }) {
        pre_deltas += 1;
    }
}
assert_eq!(pre_deltas, 100);
```
(`connect()` subscribes under the hub mutex, so a connection created before the
driver spawns cannot miss an event; `EVENT_CHANNEL_CAPACITY` is 256 > 100, so the
pre-driver receiver never lags and drops deltas.) Keep the existing per-connection
fold-to-final assertions unchanged.

### Verify

- `just raspi-test`
- `just raspi-check`

---

## Change 2: app -- honest three-tier transition log

Commit: `fix(app): make reducer "(no change)" log honest with snapshot diffs`
(body: telemetry deltas mutate `link.onlineWorld` but logged "(no change)"
because `logSummary` excludes those fields; add a three-tier transition log and
surface `mem_available` + `time_synced` in `logSnapshot`.)

All production edits in `app/DanCam/DanCam/Features/App/AppFeature.swift`.
`Store.swift` already passes `(action, old, new)` to the log closure and
`AppFeature.State` is fully `Equatable`, so no plumbing changes.

### ADR amendment (same commit)

App ADR 10 says telemetry panels "keep updating from raw `storage_changed`,
`temp_changed`, and `mem_changed` events" (Consequences). With Change 1 shipped,
the values the app folds are service-coarsened, and this commit newly *logs*
their field diffs, so `raw` reads as inaccurate. Append a dated note to
`app/docs/design/10-2026-06-29-event-folded-state-machines.md` (append-only, no
new ADR): the app folds telemetry deltas as opaque service-coarsened *observed*
values and must not assume full-precision samples; the coarsening quanta are the
Pi's concern, recorded in raspi ADR 02. This is the app-side counterpart to the
raspi ADR 02 note; each side amends its own ADR in its own commit.

### Extend `logSnapshot`

`memChanged` and `timeSynced` currently change state invisibly to BOTH log
strings. In the `if let world = link.onlineWorld` block, after `temp_sensor_c`,
matching existing token styles:

```swift
if let mem = world.mem {
    fields.append("mem_available=\(mem.available)")
}
fields.append("time_synced=\(world.time.map { String($0.synced) } ?? "nil")")
```
(`world.time` is `TimeStatus?` -- verified.)

### Three-tier log with a pure, testable core

Replace the body of the `extension AppFeature` holding `logTransition`:

```swift
enum TransitionLog: Equatable {
    case notice(String)
    case debug(String)
}

static func transitionLog(action: Action, old: State, new: State) -> TransitionLog {
    let oldSummary = old.logSummary
    let newSummary = new.logSummary

    if oldSummary != newSummary {
        return .notice("action=\(action.logLabel) \(oldSummary) -> \(newSummary)")
    }
    if old != new {
        let diff = tokenDiff(old: old.logSnapshot, new: new.logSnapshot)
        return .debug("action=\(action.logLabel) \(diff.isEmpty ? "(state changed)" : diff)")
    }
    return .debug("action=\(action.logLabel) (no change)")
}

static func logTransition(_ action: Action, _ old: State, _ new: State) {
    switch transitionLog(action: action, old: old, new: new) {
    case .notice(let message): Log.reducer.notice("\(message, privacy: .public)")
    case .debug(let message): Log.reducer.debug("\(message, privacy: .public)")
    }
}
```

`tokenDiff(old:new:)` -- pure helper over the space-joined `key=value` token
strings (keys are unique, no spaces in keys/values today):
- Parse each string into ordered `(key, value)` pairs (split on `" "`, then
  first `"="`).
- Walk new-side pairs in order: emit `key=oldValue->newValue` when values
  differ, `key=absent->newValue` for new keys.
- Then old-side pairs in order: emit `key=oldValue->absent` for removed keys.
- Join with `" "`; equal inputs -> `""`.

Tier semantics stay within `app/AGENTS.md#Logging` / ADR 14: `.notice` remains
the export-critical summary transition; snapshot-level churn (telemetry hot
path) and true no-ops are `.debug`. Heartbeat -- a genuine no-op (verified:
`World.folding` breaks on `.heartbeat`) -- now honestly earns `(no change)`.
The extra `old != new` compare duplicates what `Store.send` already does for
observer notification -- no new cost class. `LogExporter` copies
`composedMessage` opaquely; no format coupling.

### Tests -- new file `app/DanCam/DanCamTests/Features/App/AppTransitionLogTests.swift`

Swift Testing, pure-function tests on `transitionLog` / `tokenDiff` (no
TestStore needed). Reuse `CameraSamples.world(...)`
(`DanCamTests/Support/CameraSamples.swift`) -- its keyword defaults cover these
cases; build states with `var s = AppFeature.State(); s.link = .online(world)`.

1. `heartbeatWithEqualStateLogsNoChange` -- identical online states,
   `.event(.heartbeat(...))` -> `.debug("action=event.heartbeat (no change)")`.
2. `tempChangeInvisibleToSummaryLogsSnapshotDiff` -- worlds differing only in
   `tempC.soc` 51.5 -> 52.0 -> `.debug("action=event.tempChanged temp_soc_c=51.5->52.0")`.
3. `memChangeLogsMemAvailableDiff` -- worlds differing only in `mem.available`
   -> `.debug` containing `mem_available=100->200` (pins the new token).
4. `summaryChangeLogsNoticeWithOldAndNewSummaries` -- connecting -> online via
   `.event(.snapshot(...))` -> `.notice("action=event.snapshot \(old.logSummary) -> \(new.logSummary)")`.
5. `stateChangeInvisibleToSnapshotFallsBackToStateChanged` -- worlds differing
   only in `mem.swapUsed` (in state, absent from `logSnapshot`) ->
   `.debug("action=event.memChanged (state changed)")` (pins the fallback).
6. `timeSyncedLogsTimeSyncedDiff` -- `time.synced` false -> true ->
   `.debug("action=event.timeSynced time_synced=false->true")`.

7. `tokenDiffEmitsChangedValues` -- `"a=1 b=2 c=3"` vs `"a=1 b=5 c=3"` -> `"b=2->5"`.
8. `tokenDiffHandlesAppearingAndDisappearingKeys` -- `"a=1 b=2"` vs `"a=1 c=9"`
   -> `"c=absent->9 b=2->absent"` (pins ordering).
9. `tokenDiffOfEqualStringsIsEmpty` -- identical inputs -> `""`.

(New file is picked up automatically -- project uses file-system-synchronized
groups.)

### Verify

- `just app-test`
- `just app-lint`

---

## Sequencing and verification (end to end)

Two self-contained commits (code + tests each), raspi first, then app.

After both: run the service with the mock backend and the app in the simulator
(dev-mac note: temp/mem are `None` off-Linux, so the observable win locally is
`storage_changed` going quiet between 64 MiB crossings); watch the Xcode
console -- telemetry events should now log honest `.debug` field diffs (e.g.
`action=event.storageChanged storage_used=...->...`), heartbeats log
`(no change)`, and the every-2s spam drops to bucket crossings only. Full
temp/mem coarsening behavior is exercised by the world.rs unit tests; on-Pi
confirmation can wait for the next deploy.

## Out of scope

- Temp `NaN` from a garbage sysfs read would emit every 2s (compares unequal
  forever); pre-existing behavior, unchanged by this plan.
- No contract/ changes and no new ADR files -- the coarsening pivot is recorded
  as dated notes appended to the existing raspi ADR 02 and app ADR 10 (one per
  side, in that side's commit; see each change above), not a new
  sequence-numbered ADR. No storage UI changes (a 32 GB card's meter cannot show
  sub-64 MiB differences).

## Commit progress

- [x] 1. raspi coarsen telemetry change-detection quanta
- [x] 2. app honest three-tier transition log
