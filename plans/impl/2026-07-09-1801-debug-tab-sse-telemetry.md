# Plan: Debug tab + SSE-only debug screen

Move the Debug screen from Home's navigation-bar button to a third tab
([Home] [Debug] [Settings]) and rebuild it: live SSE world as the sole data
source, inset-grouped list presentation, progress-bar gauges for storage /
memory / swap, and richer tabular rows for the rest.

## Settled decisions (discussed 2026-07-09)

1. **Data source: SSE-only.** The screen renders entirely from the folded
   `World` in the app store (`AppFeature.State.link`). The one-shot
   `/v1/health` fetch is deleted from the app: the SSE snapshot already
   carries `bootId`, `uptimeS`, `recorder.phase`, and `time.synced`; the only
   field it lacks is raw `tMs`, which is stale the instant it renders and is
   replaced by the more useful "Time synced" row. `HealthFeature`,
   `HealthClient`, `HealthError`, and `HealthResponse` go away. The Pi keeps
   serving `/v1/health` (curl/ops surface); the wire contract is untouched.
2. **Presentation: inset-grouped list.** `UICollectionView` with
   `UICollectionLayoutListConfiguration(appearance: .insetGrouped)`,
   Settings-style sections, value cells plus custom gauge cells.
3. **Gauge tinting: neutral storage, thresholds on memory/swap.** Loop
   recording is designed to run the card near-full, so a threshold-tinted
   storage bar would be a permanent false alarm; storage stays default tint.
   Memory and swap tint orange/red under pressure (real warnings on a Pi
   Zero 2 W). Temperatures stay value rows (no 0-100 scale) with the camera
   temp tinted via the existing `Formatters.sensorWarning` thresholds.
4. **Tab icon:** `waveform.path.ecg`, title "Debug", middle position (tag 1;
   Settings moves to tag 2).

## Design

### Projection: `DebugScreen`

A pure projection (per ADR 17's derived rendered view-state) replaces
`HealthTelemetry`: `DebugScreen.sections(for: AppFeature.State,
exportError: String? = nil) -> [DebugSection]`, returning render-ready rows
so the view controller stays dumb and tests stay pure. Row model (all display
strings + a semantic tint, not UIColor):

- `.banner(String)` -- staleness notice (below).
- `.value(id:label:value:tint:)` -- key/value row; monospaced-digit value.
- `.gauge(id:title:detail:fraction:tint:)` -- title, detail line, 0...1 bar.
- `.button(.exportLogs)` -- action row.
- `.exportError(String)` -- inline export-failure message (critical tint),
  composed from controller-local state (see Actions), not from the world.

Sections and rows (live world):

- **Recorder:** Phase (from `Link.recorderTruth`, see staleness), Session,
  Segment (current segment id only -- "Segment #24" -- when
  `recorder.currentSegment != nil`), Detail row (critical tint) only when the
  recorder is in `.error` with a detail string. Debug shows no live elapsed
  segment duration: `segment_opened` folds `durMs: nil` and no SSE delta
  advances it, so a duration here would sit frozen at the snapshot value.
  Live elapsed stays Home's job (its local count-up per ADR 10); Debug shows
  only the stable id.
- **Camera:** State (`cameraState` raw value), SoC temp, Camera temp
  (tint from `Formatters.sensorWarning`; SoC stays untinted -- the board's
  70 C rating is not the weak link and has no defined threshold yet).
- **Storage:** when `world.storage != nil`, one gauge -- detail
  "98.2 GB of 128 GB -- 29.8 GB free" via the existing
  `Formatters.storageDisplay` (already returns `usedFraction`), always
  neutral tint. When `world.storage == nil` (online but not yet sampled), a
  plain `.value(id: .storage, "Storage", "--")` row and no gauge.
- **Memory:** when `world.mem != nil` and `mem.total > 0`, RAM gauge
  (used = `total - available`, clamped; detail "412 MB of 512 MB") with
  pressure tint, plus a Swap gauge (`swapUsed/swapTotal`, same pattern);
  `swapTotal == 0` renders a plain value row "Swap: none" and no gauge. When
  `world.mem == nil` (online but not yet sampled) *or* `mem.total == 0`
  (guards a `0/0` NaN fraction), plain `.value` placeholder rows
  ("RAM"/"Swap" = "--") and no gauges.
- **System:** Boot ID (monospaced, copyable via long-press context menu),
  Boot tag (row present only when `bootTag != nil`), Uptime ("2d 7h 33m"),
  Time -- "synced" when `time?.synced == true`; "not synced" (warn tint,
  consistent with the Home time-unverified pill) when synced is false; "--"
  when `world.time == nil` (not yet reported).

  Uptime is heartbeat-fresh. Each heartbeat carries `t_ms` -- milliseconds since
  Pi boot, derived from the same `started` clock the snapshot's `uptime_s` comes
  from (see `contract/events/README.md#Event Rules` and
  `raspi/service/src/event_hub.rs#fn now_ms`) -- so `World.folding`'s `.heartbeat`
  case folds `t_ms / 1_000` into the online world's `uptimeS`. On a long-lived
  healthy connection the row stays current instead of frozen at the connect-time
  snapshot, which is what ADR 18 requires (no stale present-tense claim while the
  connection is live and the banner is absent). The fold updates only `uptimeS`
  and only while online; heartbeat still leaves recorder/telemetry untouched.
  That narrows ADR 10's "heartbeat does not mutate World" rule -- recorded in
  ADR 23 (below) and cross-referenced from ADR 10. A local count-up timer is
  still rejected: the wire already carries elapsed-since-boot, so a timer would
  only duplicate a clock we already have (and Home's live-elapsed count-up per
  ADR 10 is *recording* duration -- a different quantity from device uptime, and
  unaffected). The per-heartbeat `World` change is bounded: ADR 06's scoped
  selectors gate UI callbacks for observers whose slice is unchanged, and the
  minute-resolution Uptime string re-renders only about once a minute.
- **Actions:** Export logs button row; on export failure an `.exportError`
  row appears directly under it. Export outcome is controller-local, not in
  the app store, so the projection takes it as an explicit argument
  (`exportError:` above). This keeps the single diffable render path -- there
  is no second render mechanism -- and keeps the projection pure and
  unit-testable.

### Staleness (ADR 18 compliance)

Present-tense claims require heartbeat-fresh state:

- `link == .online(world)` -- normal rendering, no banner.
- `link == .offline(last: world?)` with a last world -- prepend a
  `.banner("Not connected -- showing last known values")` section and render
  the same rows from the last-known world. Recorder phase reads through
  `Link.recorderTruth` so `.lastKnown` is what gates the banner wording for
  that row; no value is presented as live.
- `.connecting` or no world at all -- the whole screen renders its rows with
  "--" placeholder values and no gauge rows (mirrors today's placeholder
  behavior). This is distinct from an *online* world merely missing individual
  fields (`storage`/`mem`/`time` still `nil`): there the present fields render
  live and only the absent ones fall back to the per-field "--" value rows
  described above, with no banner.

### View controller: `DebugViewController`

`Features/Health/` is renamed to `Features/Debug/` (the "Health" name loses
its meaning once the `/v1/health` fetch is gone; the Xcode project uses
file-system-synchronized groups, so moves need no pbxproj edits).

- Owns a `UICollectionView` (inset-grouped list) + diffable data source keyed
  by the semantic row id (e.g. `.gauge(.storage)`). Cells read their display
  data from a stored `[RowID: DebugRow]` map, not from the item identifier, so
  the identifier stays stable while the value changes. **Every projection that
  differs from the last applies a snapshot** -- a stable-id row with no
  snapshot never re-renders, which is the frozen-telemetry bug this guards
  against. The controller diffs the new rows against the last rendered map:
  when the id set is unchanged it applies a snapshot that `reconfigureItems`
  the ids whose row content differs (storage/memory/temp/recorder values
  update in place as their SSE deltas arrive; uptime updates on each heartbeat
  as `t_ms / 1_000` folds into `uptimeS` -- see System); when the id set changes
  (banner appears,
  swap/section shape changes) it applies a structurally new snapshot.
- Gauge cell: a custom `UIContentConfiguration`/content view (title +
  detail label + thin bar). Tint mapping: neutral = default tint color,
  warn = `.systemOrange`, critical = `.systemRed`.
- Observes the app store and renders through a single `render()` that builds
  `DebugScreen.sections(for: appStore.state, exportError: currentExportError)`
  and applies the snapshot -- one scoped observation, no local feature store.
  Both the store observation and the export-logs completion call `render()`,
  so the export-failure row flows through the same diffable path as live
  telemetry. No `HealthFeature` store, no `.onAppear`; the tab loads lazily on
  first selection (like Settings) and is live from `viewDidLoad` on.
- Pull-to-refresh stays as the manual "retry now" affordance: sends
  `.reconnectStreamIfOffline` and ends the spinner immediately (there is no
  request/response to await; live values update on their own).
- Export logs keeps `buildExportText`, `lastExportOutcome`, and the app
  version + `logSnapshot` header exactly as today; on completion it derives
  `currentExportError` from `lastExportOutcome` (failure -> message, success
  -> nil) and calls `render()` so the `.exportError` row appears/clears.
- No `ConnectionResumable` conformance -- the store observation is the live
  path; there is nothing extra to resume on a reconnect edge.

### Wiring

- `SceneDelegate` builds a third `UINavigationController` with
  `DebugViewController`, tab items: Home (`house`, 0), Debug
  (`waveform.path.ecg`, 1), Settings (`gearshape`, 2); passes all three into
  `AppShellViewController(tabs:)` so delegate logging stays complete (per
  ADR 22's consequence).
- `HomeViewController` drops the `chart.bar` right bar button and
  `debugTapped` (grep for the "Status detail" accessibility label to catch
  any UI-test references).

### Formatters additions

- Extend `Formatters.compactDuration` with a days tier ("2d 7h") and add
  `Formatters.uptime(_ seconds: UInt64)` on top of it.
- `Formatters.memoryDisplay(_ mem: Mem)` -- used/total text + clamped used
  fraction (guard `available > total`), plus the swap equivalent.
- Usage-pressure thresholds as named constants (tunable), compared with an
  inclusive `>=` (a fraction exactly at the threshold takes the higher tint):
  memory warn 0.80 / critical 0.90; swap warn 0.50 / critical 0.80
  (some swap use is normal on Pi OS; sustained high swap means thrash and
  dropped frames).

### Deletions

- `Features/Health/HealthFeature.swift`, `Networking/HealthClient.swift`
  (incl. `HealthError`), `Networking/HealthResponse.swift`,
  `Features/Health/HealthTelemetry.swift` (superseded by `DebugScreen`).
- `AppDependencies.health` -- currently the only non-defaulted parameter of
  the member-wise `init`. Dropping it would make that init callable with no
  arguments, colliding with `init(configuration: AppConfiguration = .live())`
  (also no-arg) and rendering `AppDependencies()` ambiguous. So in the same
  change, remove the default from `init(configuration:)`; `AppDependencies()`
  then resolves uniquely to the member-wise (all-`.noop`) init, and
  `AppDependencies.live` already passes `.live()` explicitly. The ~9 test call
  sites that pass `health:` just drop the argument.
- Separate cleanup commit: `StatusClient` (+ its tests and
  `AppDependencies.status`) has zero production references -- dead since
  ADR 10 moved connection truth to SSE. Verify with a fresh grep before
  deleting. Server-side `/v1/status` and the contract are untouched.

## ADR

New `app/docs/design/23-2026-07-09-debug-tab-sse-only-telemetry.md`:

- Context: Debug was pushed from Home (pre-tab-bar); the screen straddled a
  one-shot `/v1/health` fetch and the live SSE world, and the fetch's fields
  are redundant with the snapshot.
- Decision: Debug becomes a top-level tab; the screen renders solely from
  the folded world; the app's `/v1/health` usage and client are deleted;
  inset-grouped list with gauges; staleness banner per ADR 18. Uptime is
  heartbeat-fresh: `World.folding` folds each heartbeat's `t_ms / 1_000` into the
  online world's `uptimeS`, which narrows ADR 10's "heartbeat does not mutate
  World" rule to "heartbeat advances only `uptimeS`" (recorded here, cross-linked
  from ADR 10). The Debug segment row shows only the current segment id (live
  elapsed *recording* duration stays Home's local count-up, a distinct quantity).
- Consequences: one live data source, no fetch-on-appear staleness in a
  persistent tab; `/v1/health` remains a Pi-side ops/curl surface only;
  `AppDependencies` loses `health` (and `status` in the cleanup).
- Alternatives: keep dual-source with a `viewWillAppear` refetch (rejected:
  staleness + duplicated truth); keep the nav-bar button (rejected: Debug is
  a peer surface, and the button competes with Home's own chrome);
  snapshot-frozen uptime (rejected: on a long-lived healthy connection the row
  would show connect-time uptime with no staleness banner -- an ADR 18
  violation); a controller-local count-up timer (rejected: heartbeat `t_ms`
  already carries elapsed-since-boot, so a timer would duplicate a clock the
  wire provides and Home's live-duration machinery). The chosen fold touches
  only `uptimeS`; the per-heartbeat `World` change is bounded by ADR 06's scoped
  selectors, which gate UI callbacks for observers whose slice is unchanged.

Append the entry to `app/AGENTS.md#Design decisions (ADRs)`. ADR 22 is
extended, not superseded -- no status change. ADR 10 likewise gets a
forward cross-reference note that ADR 23 narrows its "heartbeat does not mutate
World" rule to allow the `uptimeS` fold (heartbeat still touches nothing else);
ADR 10 keeps its status -- this is a one-directional narrowing recorded in both
files, like the ADR 22 extension, not a wholesale supersede of ADR 10's other
decisions (event-folded state machines, Home's local count-up).

## Tests

New/changed (Swift Testing; behavioral, structure-insensitive):

- `DebugScreenTests` (pure, replaces `HealthTelemetryTests`):
  - online world -> expected sections/rows: recorder phase/session, Segment
    row showing only the id ("Segment #24") for a world folded through
    `.segmentOpened` (no elapsed duration), storage gauge fraction + detail
    text, RAM/swap gauge fractions, boot id/tag/uptime/time rows; no banner.
  - offline with last world -> banner row + same values.
  - connecting / no world -> "--" placeholders, no gauges.
  - online world missing `storage`, `mem`, and `time` (fields still `nil`) ->
    per-field "--" value rows for storage/RAM/swap and an untinted "--" Time
    row (not "not synced"), no gauges, no banner, while live fields (uptime,
    boot id) still render.
  - `swapTotal == 0` -> "none" value row, no swap gauge.
  - `mem.total == 0` -> RAM renders a "--" value row with no gauge (no NaN).
  - uptime is heartbeat-fresh: a world folded from `.heartbeat(tMs:)` shows the
    Uptime row at `tMs / 1_000` (proves a heartbeat advances uptime), and a
    freshly folded snapshot with a new `uptime_s` also updates it; the heartbeat
    fold changes nothing else in the world.
  - export failure -> `.exportError` row (critical tint) in Actions when
    `exportError:` is non-nil; nil -> no such row.
  - tint thresholds (parameterized, both RAM and swap, pinning the inclusive
    `>=` boundary): RAM 0.79 -> neutral, 0.80 -> warn, 0.89 -> warn,
    0.90 -> critical; swap 0.49 -> neutral, 0.50 -> warn, 0.79 -> warn,
    0.80 -> critical (so swap uses the swap thresholds, not memory's, and a
    below-warn value is left untinted); storage neutral even at 0.97; camera
    temp 50/55 -> warn/critical; time not synced -> warn; recorder error ->
    detail row with critical tint.
- `LinkTests`: `unknownAndHeartbeatAreWorldNoOps` splits -- `.unknown` stays a
  full World no-op, while `.heartbeat(tMs:)` now advances `uptimeS` to
  `tMs / 1_000` and leaves every other field untouched (mirrors the
  `World.folding` `.heartbeat` case changing from a no-op to that single-field
  fold).
- `AppFeatureTests`: `heartbeatDoesNotBounceOptimisticStarting` is updated for
  the fold at the reducer level -- it keeps asserting a heartbeat leaves
  optimistic `.starting` recording state intact, but its previously
  no-change `.event(.heartbeat(tMs:))` step now expects `link`'s online world
  to advance `uptimeS` to `tMs / 1_000` with every other field unchanged.
  Without this the existing `link == .online(world)` no-change assertion would
  fail once heartbeat folds uptime, so the update ships with the fold in
  commit 2.
- `FormattersTests` additions: `uptime` (45 -> "45s", 3725 -> "1h 2m",
  200000 -> "2d 7h 33m"); a direct days-tier case appended to the existing
  parameterized `compactDuration` test (`200_000_000` ms -> "2d 7h 33m") so the
  new tier is pinned independently of `uptime` -- `driveCardSubtitle` calls
  `compactDuration` directly and would otherwise regress to hour-only formatting
  silently; `memoryDisplay` fraction + clamping; and `memoryDisplay` with
  `total == 0` -> nil (no fraction; guards `0/0`).
- `DebugViewControllerTests` (replaces `HealthViewControllerTests`):
  - keep export success/failure tests (snapshot header, recorded outcome,
    inline error row) -- mechanical adaptation.
  - export failure-then-success on the *same* controller: fail an export
    (assert the `.exportError` row is present), then succeed (assert the row
    is gone) -- proves `currentExportError` clears, not just that a fresh
    controller renders each state independently.
  - keep `pullToRefreshReconnectsOfflineAppStore`; spinner-end assertions
    simplify to "ends after dispatch" (no gated health client).
  - one render smoke test: send `.event(.snapshot(world))` -> data source
    contains the storage gauge row with the expected fraction (deep
    assertions live in `DebugScreenTests`).
  - live-update test (guards F1): send two worlds with identical row ids but
    different storage/memory values and assert the rendered gauge
    fraction/detail changes -- proves a structurally-unchanged snapshot still
    reconfigures cells rather than freezing.
  - drop the health-fetch status-label tests ("Loading health...",
    "Unable to reach camera") -- that state machine no longer exists.
- `DanCamUITests` (XCUITest, new): launch the app and assert the tab bar shows
  Home / Debug / Settings in that order. With Home the selected tab, assert the
  "Status detail" element is absent (the removed nav-bar button,
  `HomeViewController#accessibilityLabel = "Status detail"`) -- checked while
  Home is visibly selected and before navigating away, so a button still living
  on the offscreen Home tab cannot slip past. Then tap Debug and assert its
  screen appears. This is the only automated check of the `SceneDelegate`
  wiring -- the `DanCamTests` shell tests inject tabs and cannot catch a
  missing/misordered/leftover tab.
- Delete `HealthFeatureTests` and `Networking/HealthClientTests` (the latter
  covers `HealthClient` / `HealthError` / `HealthResponse`) in commit 2;
  delete `StatusClientTests` with the cleanup commit.
- `AppShellViewControllerTests` are tab-count-agnostic (they inject tabs);
  only the `makeStore` helper loses its `health:` argument.

## Commits

1. `feat(app): add uptime and memory formatters` -- Formatters + tests.
2. `feat(app): rebuild Debug as an SSE-driven top-level tab` -- one atomic
   change, because the pieces cannot compile apart: renaming
   `HealthViewController` -> `DebugViewController` and deleting the Health path
   breaks `HomeViewController.debugTapped` (`app/DanCam/DanCam/Features/Home/
   HomeViewController.swift#func debugTapped`), so the Home bar-button removal
   and the SceneDelegate tab wiring have to land in the same commit as the
   screen -- and ADR 23's "Debug is a top-level tab" claim is only true once
   that wiring lands. Contents: the projection, view controller, gauge cell,
   the `World.folding` heartbeat -> `uptimeS` fold (and the split `LinkTests` +
   the updated `AppFeatureTests.heartbeatDoesNotBounceOptimisticStarting`),
   deletions of HealthFeature/HealthClient/HealthResponse/HealthTelemetry,
   `AppDependencies.health` removal, test suite replacement, ADR 23 +
   `app/AGENTS.md` entry (incl. the ADR 10 cross-reference note), the
   SceneDelegate third tab, the Home bar-button removal, the `DanCamUITests`
   tab-navigation test, and the `just app-test-ui` recipe.
3. `chore(app): delete unused StatusClient` -- after a verifying grep.

## Verification

- `just app-test`, `just app-build` after each commit. `just app-test` runs
  `-only-testing:DanCamTests` and does **not** exercise the UI target, so once
  the tab wiring lands (commit 2) also run `DanCamUITests`:
  `xcodebuild -project app/DanCam/DanCam.xcodeproj -scheme DanCam -destination
  'platform=iOS Simulator,OS=26.5,name=iPhone 17' -only-testing:DanCamUITests
  test` (via the `just app-test-ui` task added in that commit).
- Manual run against the mock Pi (`just raspi-mock`,
  `DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080` in the scheme): Debug
  tab renders live gauges; kill the mock -> staleness banner + last-known
  values + strip agreement; pull-to-refresh while offline reconnects after
  mock restart; export logs presents the share sheet; boot ID long-press
  copies.

## Out of scope

- Raspi-side `/v1/health` endpoint removal (kept as ops/curl surface; would
  be its own raspi decision).
- SoC temperature thresholds (no defined limit yet; camera sensor is the
  stated weak link).
- Storage thresholds tied to a retention/prune target (revisit when loop
  pruning exists).

## Implementation notes

- The plan's swap equivalent is a separate `Formatters.swapDisplay(_:)`
  alongside `memoryDisplay(_:)`; both share one clamping formatter so the
  Debug screen can independently render `Swap: none` when swap total is zero.

## Commit progress

- [x] 1. `feat(app): add uptime and memory formatters`
- [x] 2. `feat(app): rebuild Debug as an SSE-driven top-level tab`
- [ ] 3. `chore(app): delete unused StatusClient`
