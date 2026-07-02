# Plan: selector-based observation + derived view-state (surgical view updates)

## Context

This plan was first written against the poll-era state and is **retargeted here** twice:
for the post-`/v1/events` codebase (ADR
`app/docs/design/10-2026-06-29-event-folded-state-machines.md`, commit `e98eba3`), and
again for the **post-thumbnails** codebase (ADR
`app/docs/design/16-2026-07-01-client-side-clip-thumbnails.md`). The second retarget
matters: when this plan was first drafted, a finished clip row was a plain
`UIListContentConfiguration` subtitle cell, so the `reloadData()` this plan attacks was an
instant, invisible no-op. Since ADR 16, each finished row is a `ClipThumbnailCell` whose
first-frame thumbnail loads **asynchronously**, so the same `reloadData()` now blanks every
visible thumbnail to its gray placeholder and re-dispatches the load -- turning the latent
imprecision into a **user-visible ~1 Hz thumbnail flicker** in the Home clip list. That
flicker is the concrete bug this plan now fixes.

The old `\.connection.lastStatus: StatusResponse?` slice no longer exists; `StatusResponse`
is gone from the app entirely. Current app state
(`app/DanCam/DanCam/Features/App/AppFeature.swift#State`) is:

- `link: Link` -- a state machine (`Features/Connection/Link.swift#Link`):
  `.connecting | .online(World) | .offline(last: World?)`, exposing the latest telemetry
  as `World?` via `link.world`. The Pi event stream is folded into `World`
  (`Networking/Events/CameraEvent.swift#World`): `recorder`, `cameraState`, `bootId`,
  `uptimeS`, `storage?`, `tempC`, `mem?`.
- `clips: ClipsFeature.State` -- `{ clips: [Clip], status: .idle|.loading|.failed }`.
  `ClipsFeature.merged` (`Features/Clips/ClipsFeature.swift#merged`) keys incoming clips
  into a `[Int: Clip]` and returns them **sorted by id descending**, so `state.clips` is
  already deduped-by-id and ordered; `.loading`/`.failed` change only `status`, never the
  `clips` array.
- `recording: RecordingFeature.State`, plus `streamReconnectAttempt`.

The domain root store (ADR 06) already made observation **slice-surgical**:
`Store.observe(_:keyPath)` fires immediately and then only when the observed `Equatable`
slice changes, and `Store.send` notifies only when state actually changed. The remaining
imprecision is **inside** those slices, and the `/v1/events` migration sharpened it,
because telemetry now arrives as its own high-frequency deltas separate from row-affecting
events. (`heartbeat` is already free -- `World.folding` no-ops it, so it never changes
`World` and the equality-gated `send` never notifies; likewise there is no `uptime_changed`
event, `uptimeS` moves only on a full `snapshot`. The imprecision is the *world-changing*
deltas -- `temp_changed`, `mem_changed`, `storage_changed`, `camera_state_changed` -- each
of which mutates `World` but leaves most screens' projection unchanged):

- **Home status pills** observe the whole `\.link.world`
  (`HomeViewController#renderConnectionPills`) but render only a thermal *warning* (when
  `tempC.sensor` crosses a `Formatters.sensorWarning` threshold) and a camera-offline
  flag. Every `temp_changed`/`mem_changed`/`storage_changed` delta -- plus a
  `camera_state_changed` between two non-offline states or any `recorder` change -- mutates
  `World` and re-renders the pills though their displayed content is unchanged.
- **Home clip/live list** renders `[HomeRow]` (`HomeViewController#HomeRow`:
  `.live(LiveSegment)` + `.finished(Clip)`) via `HomeRow.compose`. `renderRows` runs from
  **two** observers -- `\.link.world` (for `world.recorder`) and `\.clips` -- and ends in
  an unconditional `clipsTableView.reloadData()`. So (a) every telemetry delta on
  `\.link.world` recomposes and full-reloads the table even when the composed `[HomeRow]`
  is byte-identical, and (b) even a genuine one-row change (a finalized clip, recording
  start) does a **full** reload -- flashing the whole list and losing scroll position.
  Since ADR 16 each `.finished` row is a `ClipThumbnailCell` (`Features/Home/ClipThumbnailCell.swift`)
  that owns one in-flight async thumbnail load, and `HomeViewController` drives a
  `UITableViewDataSourcePrefetching` warm path over an `IndexPath`-keyed `prefetchHandles`
  map that `renderRows` blanket-`cancelAllPrefetches()`es on every reload. So a `reloadData()`
  now routes every visible cell through `prepareForReuse` (blanking it to the placeholder,
  cancelling its load) before re-dispatching an async load that repaints a frame or more
  later -- the visible flicker -- and needlessly churns the prefetch warm set. The cell was
  deliberately built identity-keyed with a same-identity `configure` no-op
  (`ClipThumbnailCell.swift#configure`) so that an *in-place* reconfigure keeps its painted
  thumbnail; this plan is what finally routes updates through that path instead of reload.
- **Health telemetry** observes the whole `\.link.world`
  (`HealthViewController#renderTelemetry`) and tears down and rebuilds the entire
  telemetry stack on every world delta, though it renders only formatted telemetry
  strings (temps/storage/mem) -- never `recorder`, `cameraState`, `bootId`, `uptimeS`.

### Concrete examples of what breaks today (and what "fixed" looks like)

These are the observable behaviors the implementor is fixing and the verifier is checking.
Each is a **before -> after** pair; the Pi drives them via `spawn_telemetry` /
`spawn_heartbeat` (`raspi/service/src/main.rs`, both `Duration::from_secs(2)`) and the
recorder/clip event stream.

1. **Idle, connected, clip list on screen (the reported bug).** The Pi samples
   storage/temp/mem every ~2 s and emits `storage_changed` / `temp_changed` / `mem_changed`
   whenever a value moved (`raspi/service/src/world.rs#apply_telemetry`). Each delta mutates
   `World`, so the `\.link.world` observer fires -> `renderRows()` -> `reloadData()` ->
   **every visible thumbnail blinks to the gray placeholder and back, in unison**, roughly
   once a second. *After:* the rows observe only `\.link.world?.recorder`, which these
   deltas do not touch, so `renderRows()` never runs and the thumbnails stay painted. (The
   `heartbeat` delta was already inert -- `World.folding` no-ops it -- so it is not part of
   this and needs no narrowing.)
2. **Recording; a segment rolls or a clip finalizes.** A `segment_opened` (recorder change)
   or a `clip_finalized` (clips change) legitimately changes the row list. Today either one
   triggers a **full** `reloadData()`, flashing *every* thumbnail (not just the changed row)
   and dropping scroll position. *After:* the diffable snapshot inserts/updates exactly the
   one affected row (animated), leaves every other cell -- and its painted thumbnail --
   untouched, and preserves scroll. This is the half that narrowing alone (Change 3a) does
   **not** fix, and why the diffable move (Change 3b) is also required.
3. **Debug screen open while connected.** Every world delta (including pure telemetry)
   tears down and rebuilds the entire telemetry `UIStackView`. *After:* Health observes its
   rendered `[TelemetryRow]` strings, so it rebuilds only when a displayed string actually
   changes (and sub-display-precision drift dedups).

This migration keeps the root `AppStore` architecture (ADR 06) and the event-folded state
machines (ADR 10) and refines observation **granularity**: move from "observe a stored
state slice" to "observe the derived `Equatable` view-state a screen actually renders,"
and replace the `[HomeRow]` full reload with row-level diffing keyed by row identity. It
does **not** reintroduce per-screen domain stores and adds no third-party framework
(ADR 03's bespoke TEA, zero deps, stands).

### Guardrail carried from ADR 06

View state stays out of `AppFeature.State`. The derived projections (`HomeStatusPills`,
Health's `[TelemetryRow]`, and the `HomeRowID` diff) are computed by **pure functions the
view owns**, fed to the store via `observe(select:)` / narrowed keypaths; the domain
`State` type does not gain view-shaped fields. This is what keeps page/CarPlay
reorganization from touching the store.

Every new pure view-state/helper type introduced below (`HomeStatusPills` + its nested
`Warning`, `HomeSection`, `HomeRowID`, `HomeRowDiff`, `TelemetryRow`) is declared
**`nonisolated`**. The app target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an
unannotated type would be `@MainActor`-isolated and could not be used (or have its
`Equatable`/`Hashable` conformance exercised) from the non-actor Swift Testing suites.
This matches the existing pure helpers `LiveSegment`, `HomeRow`, and the `World`/`CameraEvent`
value graph, all of which are explicitly `nonisolated`.

---

## Change 1: `Store` selector-based observation (`Architecture/Store.swift`)

(Store core is unchanged by `/v1/events`; this change is exactly as before.)

Make `observe(select:)` the deduplicating primitive and re-express keypath observation as
one-line sugar over it. Replaces the current standalone keypath `observe` body
(`app/DanCam/DanCam/Architecture/Store.swift#func observe`).

```swift
@discardableResult
func observe<Value: Equatable>(
    select: @escaping (State) -> Value,
    _ observer: @escaping (Value) -> Void
) -> StoreObservation {
    var last: Value?
    return observe { state in
        let value = select(state)
        if let last, last == value { return }   // set last BEFORE observer (re-entrancy)
        last = value
        observer(value)
    }
}

@discardableResult
func observe<Value: Equatable>(
    _ keyPath: KeyPath<State, Value>,
    _ observer: @escaping (Value) -> Void
) -> StoreObservation {
    observe(select: { $0[keyPath: keyPath] }, observer)
}
```

- Layered on the base `observe(_ observer: (State) -> Void)` (unchanged), which fires
  synchronously on registration -- so `observe(select:)` fires **once initially**
  (`last == nil` on the first run), then only on a change of the selected value.
- The `isFirst` flag from the old keypath body is gone; `last: Value?` nil-state gives
  identical first-fire semantics with less code. (Safe even when `Value` is itself
  `Optional` -- the outer `last` sentinel `nil` is distinct from `.some(nil)`, so a
  `World?`/`RecorderSnapshot?` selector still fires its first real value.)
- **Re-entrancy contract preserved exactly**: `last` is assigned before `observer` is
  invoked, matching `scopedObserveUpdatesLastBeforeInvokingObserver`. The base
  `notifyObservers` already iterates an `Array(observers.values)` snapshot.

Naming: `select` (not `map`) -- `Effect.map` already exists
(`Architecture/Effect.swift`); reusing `map` here would read as the effect transform.

No equality-gate or `send` changes -- those landed in ADR 06.

---

## Change 2: Home status-pill view-state (`Features/Home/`)

Define the exact `Equatable` value the pills render and observe it derived, so the pills
wake only when their displayed content changes (zero fires across telemetry deltas in the
common no-warning, camera-running case).

New pure projection (own file `Features/Home/HomeStatusPills.swift`; mirror the
`RecordButtonStyle.from` / `HealthTelemetry.rows` pure-function idiom), reading `World?`:

```swift
nonisolated struct HomeStatusPills: Equatable {     // nonisolated: the target defaults to MainActor isolation
    var tempWarning: Warning?          // nil == no thermal warning pill
    var cameraOffline: Bool

    nonisolated struct Warning: Equatable {        // display-shaped; NOT Formatters.TempWarning (the threshold enum)
        var caption: String            // e.g. "52 C camera"
        var isCritical: Bool           // red vs orange
    }

    static func from(_ world: World?) -> HomeStatusPills {
        guard let world else { return .init(tempWarning: nil, cameraOffline: false) }
        var warning: Warning?
        if let sensor = world.tempC.sensor,
           let level = Formatters.sensorWarning(for: sensor) {   // -> TempWarning {.warn,.critical}
            warning = .init(
                caption: "\(Formatters.temperature(sensor)) camera",
                isCritical: level == .critical
            )
        }
        return .init(tempWarning: warning, cameraOffline: world.cameraState == .offline)
    }
}
```

`caption` holds the **displayed** (rounded) string, so dedup matches display granularity
-- sub-degree sensor drift that still renders `"52 C camera"` does not refire.

In `HomeViewController`:

- Replace the pill half of the current `store.observe(\.link.world)` observer with
  `store.observe(select: { HomeStatusPills.from($0.link.world) }) { renderStatusPills($0) }`.
  (The row half of that observer moves to its own narrowed observer in Change 3 -- the two
  responsibilities the single `\.link.world` observer currently bundles are split.)
- Rename/retarget `renderConnectionPills(_:)` to `renderStatusPills(_ pills: HomeStatusPills)`:
  the method now only *applies* `pills` to `tempWarningPill` / `errorPill` (caption, color
  from `isCritical`, hidden flags, and the `statusPillsStack.isHidden` rollup). The
  thermal/offline *derivation* moves into `HomeStatusPills.from`; delete the
  `renderTempWarning` / `renderCameraError` private helpers (their logic is now in the
  projection).

Leave `renderRecording` and its `\.recording` observer **as-is**: it switches on the whole
`RecordingFeature.State` and forwards it to `recordButton.apply(_:)`, so the slice already
equals the view state. Narrowing it would be over-modeling.

---

## Change 3: Home rows -> `UITableViewDiffableDataSource`, plus narrowed row observation (`Features/Home/`)

Two complementary moves; together they fix both halves of the row imprecision.

**(a) Narrow what recomposes the rows.** `HomeRow.compose(clips:recorder:previousLive:now:)`
reads only `recorder` from `World`; the rest of `World` (`tempC`/`mem`/`storage`/
`cameraState`/`uptimeS`) is irrelevant to the rows. So split the row inputs into two narrow
observers and drop the broad `\.link.world` row dependency:

- `store.observe(\.link.world?.recorder) { [weak self] recorder in self?.recorder = recorder; self?.renderRows() }`
  -- keypath sugar over `select`; `RecorderSnapshot?` is `Equatable`. Fires only on a
  recorder change, so a world-changing
  `temp_changed`/`mem_changed`/`storage_changed`/`camera_state_changed` delta no longer
  recomposes the rows at all (and `heartbeat`, which never changes `World`, was already
  inert).
- `store.observe(\.clips.clips) { [weak self] clips in self?.finishedClips = clips; self?.renderRows() }`
  -- narrower than `\.clips`: a `.loading`/`.failed` status transition that leaves the
  `clips` array unchanged (e.g. pull-to-refresh start, a failed poll) no longer recomposes.

Replace the stored `private var world: World?` with `private var recorder: RecorderSnapshot?`
(rows need only the recorder; pills derive their own projection). `renderRows` reads
`recorder` and `finishedClips`; `previousLive` and `now` stay local as today.

Because `ClipsFeature.merged` already dedupes by id and sorts, and the reducer preserves
`clips` across `.loading`/`.failed`, the displayed clips are simply `state.clips` -- there
is **no** preserve-on-failure or dedupe shim to build (the previous draft's
`ClipListDisplay` is unnecessary and is dropped).

**(b) Diff instead of full-reload.** Replace the manual `UITableViewDataSource` +
unconditional `reloadData()` with a diffable data source keyed by **row identity**, so a
genuine row change updates only the affected rows (no flash, scroll preserved):

```swift
nonisolated enum HomeSection { case main }

nonisolated enum HomeRowID: Hashable {
    case live(session: UInt64, id: Int)
    case finished(Int)
}
```

`HomeRowID` is a two-case enum on purpose: a live segment id and a finished clip id can
**momentarily coexist** with the same `Int` (folding's `clip_finalized` does not clear
`recorder.currentSegment`, so `HomeRow.compose` can emit both `.live(session, N)` and
`.finished(N)` for one frame). A bare-`Int` key would trap `snapshot.appendItems` on the
duplicate; the enum keeps them distinct. (`compose`'s finished ids are unique -- `merged`
dedupes -- and there is at most one live row, so the `[HomeRowID]` list is always unique.)

Add `var id: HomeRowID` to `HomeRow` (`.live(seg)` -> `.live(session: seg.sessionId, id: seg.id)`;
`.finished(clip)` -> `.finished(clip.id)`).

In `HomeViewController`:

- Build `dataSource: UITableViewDiffableDataSource<HomeSection, HomeRowID>` in `viewDidLoad`
  with a `[weak self]` cell provider that reads a backing `private var rowsByID: [HomeRowID: HomeRow]`
  and dequeues the same cells as today (`LiveClipCell` for `.live`; `ClipThumbnailCell`
  (reuse id `"clipThumbnail"`) for `.finished`, then
  `cell.configure(clip: clip, loader: dependencies.thumbnailLoader)` -- the identity-keyed
  async-thumbnail cell added in ADR 16; its `configure` is a no-op for an unchanged
  `(id, etag)`, which is what makes the reconfigure path in (c) flicker-free). Capture `[weak self]` (and
  dequeue a bare fallback cell when `self` is nil): the VC holds `dataSource` strongly and
  the data source retains the cell-provider closure, so a strong `self` capture would form a
  `self -> dataSource -> cellProvider -> self` retain cycle that leaks the VC graph across a
  scene disconnect/reconnect -- and `[weak self]` matches the codebase's observer-closure
  idiom (`\.link.world?.recorder`, `\.clips.clips` above). (The old `dataSource = self` had
  no cycle only because `UITableView.dataSource` is a weak reference.) Drop the
  `UITableViewDataSource` conformance and `numberOfRowsInSection` / `cellForRowAt`. Keep
  the `private var rows: [HomeRow]` (needed for `previousLive` and the live timer).
- `renderRows(now:)` becomes:
  1. `let new = HomeRow.compose(clips: finishedClips, recorder: recorder, previousLive: rows.first?.liveSegment, now: now)`,
  2. `let reconfigure = HomeRowDiff.reconfiguredIDs(old: rows, new: new)`,
  3. `rows = new; rowsByID = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })`
     (unique by construction, per above),
  4. prune prefetch handles for departed rows (see (c)) -- **not** a blanket
     `cancelAllPrefetches()`; a surviving row keeps its in-flight warm,
  5. snapshot: `appendSections([.main])`, `appendItems(new.map(\.id))`, then
     `snapshot.reconfigureItems(reconfigure)` -- **`reconfigureItems`, never `reloadItems`**
     (see (c): `reloadItems` re-runs `prepareForReuse`, which blanks the thumbnail);
     `dataSource.apply(snapshot, animatingDifferences: true)`,
  6. `clipsTableView.backgroundView = new.isEmpty ? emptyClipsBackgroundView : nil`,
  7. `updateLiveTickTimer()` (unchanged).
- `didSelectRowAt`: resolve the row via `dataSource.itemIdentifier(for: indexPath)` ->
  `rowsByID[id]`; `.finished(clip)` pushes the viewer, `.live` is non-selectable (as today).
- The 1 Hz live tick (`updateLiveTickTimer` / `updateVisibleLiveElapsed`) is **unchanged
  and orthogonal**: it still mutates the visible `LiveClipCell` directly via
  `cellForRow`/`dataSource.indexPath(for: .live(...))`, never through `reloadData`. During
  steady recording `compose` returns a value-equal live row (the `previousLive`
  short-circuit when `currentSegment.durMs == nil`), so snapshots produce **no** reconfigure
  for it and the timer owns its display.
- **One internal test seam** (the *only* window the Change 5 rendering test needs into the
  view): add `func clipThumbnailCellForTesting(clipID: Int) -> ClipThumbnailCell?`, which
  resolves `dataSource.indexPath(for: .finished(clipID))` ->
  `clipsTableView.cellForRow(at:) as? ClipThumbnailCell`. The diffable `dataSource` and
  `clipsTableView` themselves stay `private` -- the test target uses `@testable import DanCam`,
  so an `internal` (default-access) seam is visible without going `public` or exposing the data
  source. Mirrors the cell's existing `displayedImageForTesting` / `isLoadingForTesting`
  `*ForTesting` idiom.

One pure helper (`Features/Home/HomeRowDiff.swift`), so the row-update contract is testable
without UIKit (matches the codebase's pure-function idiom):

```swift
nonisolated enum HomeRowDiff {
    /// ids present in BOTH old and new whose HomeRow value changed -> reconfigure in place.
    /// (Inserts/removals/reorders are derived by the snapshot from the id list; not here.)
    static func reconfiguredIDs(old: [HomeRow], new: [HomeRow]) -> [HomeRowID]
}
```

Rationale (researched): the project targets iOS 26.5, so `apply(_:animatingDifferences:)`
(always diffs by item identifier and updates only affected rows) and `reconfigureItems`
(updates a cell's content in place, reusing the cell, vs reload's dequeue-and-rebuild) are
fully available; Apple's guidance is to key diffable items by the model's **identifier**,
not the whole value, so content changes reconfigure instead of delete+insert.
`animatingDifferences: true` is safe with `reconfigureItems` (cells are reused, so no
plain-cell flicker) and gives the per-row insert/remove animation. This is no longer a
future concern: the clip thumbnails shipped in ADR 16, so a full `reloadData()` (or a
`reloadItems`, which also runs `prepareForReuse`) blanks every visible `ClipThumbnailCell`
to its placeholder and re-dispatches the async load -- the ~1 Hz flicker this plan removes.
Row-affecting events (recording start/stop, `segment_opened`, `clip_finalized`) become
single-row updates that keep scroll position and never disturb the other rows' thumbnails.

**(c) Carry the thumbnail + prefetch machinery across (new since ADR 16).** The list is no
longer plain subtitle cells: each `.finished` row is a `ClipThumbnailCell` that owns one
in-flight async thumbnail load, and `HomeViewController` drives a warm path via
`prefetchHandles` + `willDisplay`/`didEndDisplaying` quieting. The diffable move must carry
this across cleanly, or it trades the flicker for a leak/regression. Four concrete pieces:

- **Never `reloadItems`; always `reconfigureItems`.** `reloadItems` routes the cell through
  `prepareForReuse` -- which `ClipThumbnailCell.prepareForReuse` uses to `cancelLoad()`,
  clear identity, and blank to the placeholder -- so it reintroduces exactly the flash this
  plan removes. `reconfigureItems` reuses the *same* cell without `prepareForReuse`,
  re-invoking the cell provider (`configure(clip:loader:)`) on it; for an unchanged
  `(id, etag)` that call is a no-op (`ThumbnailDisplayState.show` returns false and
  `hasThumbnail` is already true), so a reconfigured painted cell keeps its thumbnail. This
  is precisely the same-identity path `ClipThumbnailCell` was built for
  (`ClipThumbnailCell.swift#configure`, case (a)/(b)).
- **Key prefetch handles by clip identity, not `IndexPath`.** `prefetchHandles: [IndexPath: PrefetchHandle]`
  only worked because a full `reloadData()` invalidated every key at once -- which is *why*
  `renderRows` currently blanket-`cancelAllPrefetches()`es. Under diffable there is no full
  reload, and inserts/removes shift `IndexPath`s without one, so re-key the map to the
  clip's `(id, etag)`: `private var prefetchHandles: [ClipThumbnailIdentity: PrefetchHandle]`
  (the same `ClipThumbnailIdentity` the cell shows and the `ThumbnailLoader`/`ThumbnailKey`
  keys on -- `Features/Home/ClipThumbnailCell.swift#ClipThumbnailIdentity`). This needs one
  small conformance change: `ClipThumbnailIdentity` is declared `Equatable, Sendable` today,
  so make it `nonisolated struct ClipThumbnailIdentity: Hashable, Sendable` -- `Hashable`
  refines `Equatable` (existing `==` call sites are unaffected), and both stored fields
  (`id: Int`, `etag: String`) are `Hashable`, so the conformance is compiler-synthesized (no
  manual `hash(into:)`). Without it neither this dictionary key nor the prune's `Set` in the
  next bullet compiles. Resolve the
  prefetch data source's `IndexPath`s through `dataSource.itemIdentifier(for:)` ->
  `rowsByID[id]` -> `ClipThumbnailIdentity(clip)` in `prefetchRowsAt` /
  `cancelPrefetchingForRowsAt` (both still `UITableViewDataSourcePrefetching`, unchanged
  signatures). Keep the cancel-before-replace and remove-on-cancel discipline the current
  code documents.
- **Replace the blanket cancel with a precise prune.** `renderRows` step 4 drops
  `cancelAllPrefetches()` (and its "a full reload invalidates every index-path key"
  comment); instead, after composing `new`, cancel and remove only handles whose identity is
  absent from the new finished-row identities -- e.g.
  `let live = Set(new.compactMap(\.finishedIdentity)); for (id, handle) in prefetchHandles where !live.contains(id) { handle.cancel(); prefetchHandles[id] = nil }`.
  Add `var finishedIdentity: ClipThumbnailIdentity?` to `HomeRow` (`nil` for `.live`,
  `ClipThumbnailIdentity(clip)` for `.finished`) as the pure accessor this uses. A surviving
  row keeps its warm (no wasted re-fetch); only a genuinely departed row is cancelled.
  `viewWillDisappear`/`deinit` still `cancelAllPrefetches()` (cancel everything on the way
  out) -- unchanged.
- **`willDisplay` pagination and `didSelectRowAt`** resolve the row via
  `dataSource.itemIdentifier(for:)` (+ `rowsByID`) instead of `rows[indexPath.row]`, so they
  never index a stale row across an animated diff. `didEndDisplaying` still calls
  `(cell as? ClipThumbnailCell)?.cancelLoad()` (unchanged), and
  `reconfigureVisibleThumbnails()` / `quietVisibleThumbnailLoads()` keep their jobs: on
  disappear the visible loads are quieted to relieve the link; on appear the in-place
  reconfigure retries any quieted-but-unpainted cell cache-first. Diffable does not reload on
  appear, so already-painted cells keep their thumbnails and only the quieted ones
  re-request -- update the `reconfigureVisibleThumbnails` doc comment, which contrasts itself
  with a `reloadData()` that `renderRows` no longer performs.

---

## Change 4: Health telemetry view-state (`Features/Health/`)

Narrow Health to the **rendered telemetry rows** -- the strings the screen actually
displays -- so dedup matches display granularity, consistent with `HomeStatusPills`.

`HealthTelemetry.rows(for world: World?)` already returns the displayed `(label, value)`
rows and already takes `World?` (`Features/Health/HealthTelemetry.swift#rows`); the only
blocker is that `TelemetryRow` is a **tuple typealias** -- a tuple type cannot conform to
`Equatable`, so `[TelemetryRow]` cannot be the selected value. Promote it to a named
`Equatable` struct:

```swift
// HealthTelemetry.swift -- replace `typealias TelemetryRow = (label:, value:)`:
nonisolated struct TelemetryRow: Equatable {        // nonisolated: the target defaults to MainActor isolation
    var label: String
    var value: String
}
```

The `rows(for:)` body's `(label, value)` array literals become `TelemetryRow(label:, value:)`;
its logic and the placeholder rows are otherwise unchanged. The selected view-state is then
just `[TelemetryRow]` (Array of `Equatable` is `Equatable`) -- no separate snapshot type.

In `HealthViewController`:

- Replace `appStore.observe(\.link.world) { renderTelemetry($0) }` with
  `appStore.observe(select: { HealthTelemetry.rows(for: $0.link.world) }) { renderTelemetry($0) }`.
- `renderTelemetry(_ rows: [TelemetryRow])` iterates the rows **directly** (it no longer
  calls `HealthTelemetry.rows` itself -- the selector already produced them). Existing
  `row.label` / `row.value` accesses are unchanged (the struct exposes the same names).

The observer now fires only when a *rendered string* changes: changes to `recorder` phase
or `cameraState` (and to `bootId`/`uptimeS`, which move only on a full `snapshot`) -- none
of them rendered here -- no longer rebuild the stack, and sub-display-precision temp/byte
drift dedups because the formatted string is identical. (The separate `HealthFeature` store's `renderFields` -- bootId/uptime/recording
from the reload button's one-shot `HealthResponse` -- is unrelated and untouched.)

---

## Change 5: Tests (`just app-test`)

Follow existing idioms: Swift Testing `@Test`, array-based fire recording, `Signal`/`Gate`
for effect coordination, real `Store` for runtime tests, pure-function tests for
projections, and the `CameraSamples.world(...)` / `.clip(...)` builders.

**`DanCamTests/Architecture/StoreTests.swift`** -- add selector-observation cases
(alongside the existing `scopedObserve*` keypath tests, which now exercise the sugar path):

- *fires once initially*: `observe(select:)` records exactly one initial value.
- *derived dedup / unrelated change does not fire*: state `{ var temp: Int; var offline: Bool }`,
  selector `{ warn: temp > threshold, offline }`. A `send` moving `temp` within the same
  side of the threshold does **not** fire; one that crosses it **does**. This is the test
  that fails if selector dedup breaks or a broad state change leaks an update.
- *re-entrancy*: an observer that re-enters with a `send` leaving its selected value
  unchanged is not re-fired (mirror `scopedObserveUpdatesLastBeforeInvokingObserver`, via
  `select:`).

**`DanCamTests/Features/Home/HomeStatusPillsTests.swift`** (new, pure, `RecordButtonStyle`
style; build worlds with `CameraSamples.world`):
- normal sensor temp + `cameraState == .running` -> `tempWarning == nil`, `cameraOffline == false`.
- **dedup guarantee**: two worlds differing only in non-pill fields -- recorder
  `phase`/`currentSegment`, `uptimeS`, `mem`, `storage`, `tempC.soc`, and a non-offline
  `cameraState` transition (`.running` vs `.starting`, both -> `cameraOffline == false`) --
  produce **equal** `HomeStatusPills`. (Varying `recorder.phase` here is what fails if the
  projection accidentally leaks recording state and refires the pills on every record toggle.)
- **display-granularity dedup**: two worlds whose `tempC.sensor` differ below display
  precision but format to the same `"NN C camera"` caption -> **equal** pills. Pick the pair from
  a **threshold-free** display bucket that still produces a warning -- e.g. `52.1` vs `52.4`, both
  `.warn`/orange, both rounding to `"52 C camera"` -- so the caption dedup is actually exercised
  (both pills carry the same non-nil caption). Do **not** use the `50 C` or `55 C` buckets:
  `caption` rounds the raw sensor (`Formatters.temperature` -> `Int(sensor.rounded())`, 1-degree
  buckets) while `isCritical`/the warning itself read the raw value (`Formatters.sensorWarning`,
  `>= sensorCriticalThreshold` 55.0 / `>= sensorWarnThreshold` 50.0), so a threshold falls *inside*
  those buckets and splits them -- `54.7` and `55.2` both render `"55 C camera"` yet differ in
  `isCritical`, and `49.7` vs `50.2` differ in whether there is a warning at all. Such pairs are
  **correctly unequal** pills (the color/presence genuinely changes), so using one here is a false
  failure, not a projection bug.
- sensor crossing `Formatters.sensorWarnThreshold` / `sensorCriticalThreshold` -> non-nil
  `tempWarning`, `isCritical` correct for warn vs critical.
- `cameraState == .offline` -> `cameraOffline == true`. `nil` world -> empty pills.

**Health dedup tests** (fold into `DanCamTests/Features/Health/HealthTelemetryTests.swift`,
pure -- the view-state is now `[TelemetryRow]`):
- **dedup guarantee**: two worlds differing only in `recorder.phase` / `cameraState` /
  `uptimeS` (and a `bootId` variant built by constructing `World` directly, since
  `CameraSamples.world` fixes `bootId`) -> **equal** `[TelemetryRow]` (none are rendered).
- **display-granularity dedup**: two worlds whose raw temp/byte fields differ below display
  precision but format to identical strings -> **equal** `[TelemetryRow]` (pick values
  against `Formatters` rounding, e.g. sub-0.1-degree `tempC.sensor` drift still rendering
  `"52.3 C"`). This proves Health is display-shaped, not raw-shaped.
- a world differing in a rendered string (e.g. `mem.available` crossing a unit boundary)
  -> **unequal**.
- existing `loadedStateRendersAllTelemetryRows` / placeholder tests keep working
  (`rows.map { $0.label }` / `{ $0.value }` is unchanged by the tuple -> struct promotion);
  optionally assert full `[TelemetryRow]` equality now that rows are `Equatable`.

**`DanCamTests/Features/Home/HomeRowDiffTests.swift`** (new, pure -- `HomeRowDiff`, no UIKit;
build rows from `CameraSamples.clip` + `LiveSegment`):
- identical lists -> `reconfiguredIDs == []`.
- same ids, one finished clip's content changed (vary `durMs` -- e.g.
  `CameraSamples.clip(id: 4, durMs: 1_000)` vs `clip(id: 4, durMs: 2_000)`; the helper
  derives `bytes` from `id`, so `bytes` cannot be varied while holding `id`) -> exactly that
  `.finished(id)`.
- appended finished clip -> the new id **not** in `reconfiguredIDs` (insert, not reconfigure);
  unchanged ids absent too.
- removed clip -> the removed id absent.
- reordered same content -> `reconfiguredIDs == []` (ordering is the snapshot's job).
- live row stable across a same-segment recompose (value-equal `.live`) -> not in
  `reconfiguredIDs`; a live **segment id change** -> old `.live(_,N)` absent (it is a
  remove+insert, not a reconfigure).
- **id-collision safety**: a frame with both `.live(session, N)` and `.finished(N)` yields
  two **distinct** `HomeRowID`s, so `new.map(\.id)` has no duplicate (this is what keeps
  `snapshot.appendItems` from trapping; replaces the old bare-`clip.id` dedupe test).

**`DanCamTests/Features/Home/HomeViewControllerTests.swift`** -- this suite already exists and
**encodes the old full-reload contract**, so it must be retargeted (not just extended). It
uses `HomeLoaderProbe`, whose `prefetchCancelCount(clip)` keys on the clip's `(id, etag)`
string -- independent of the controller's internal handle-key type -- so the probe itself is
reused unchanged.

- **Invert `aClipsReloadCancelsEveryOutstandingHandle`.** Its comment ("A clips update drives
  a full renderRows() reload, which clears all handles") is the behavior this plan
  **deletes**. Replace it with `aClipsUpdatePreservesSurvivingPrefetchHandles`: prefetch
  rows 0 and 1, `store.send(.clips(.clipFinalized(clipC)))`, then assert
  `prefetchCancelCount(clipA) == 0` **and** `prefetchCancelCount(clipB) == 0` (the survivors'
  warms are kept by the precise prune, not cancelled).
- **Add `aReRepresentedClipCancelsItsStaleHandle`** to cover the prune's *cancel* branch
  through a path that is actually driveable today. Prefetch `IndexPath(row: 0)` (clipA, per
  the seeded row order -- `makeControllerAndStore` sets `state.clips.clips` directly, so it is
  not re-sorted), which stores a handle under identity `(1, "1-1")`. Then
  `store.send(.clips(.clipFinalized(Clip(id: 1, ... etag: "1-2", ...))))`: `ClipsFeature.merged`
  folds this in by **overwriting** `byID[1]` (`Features/Clips/ClipsFeature.swift#merged`), so
  the displayed set loses identity `(1, "1-1")` and gains `(1, "1-2")`. Assert
  `prefetchCancelCount(clipA) == 1` -- the stale handle is pruned -- while clipB is untouched.
  (A *full* removal, an id vanishing outright, is deliberately **not** tested here: the reducer
  only ever merges/replaces by id and never deletes, so it cannot be driven without a test-only
  seam or brittle direct state mutation. Add a removal-prune test when an authoritative
  removal/eviction action exists; the same-id/new-etag replacement exercises the identical
  `where !live.contains(id)` cancel branch in the meantime.)
- **New anti-flicker regression `telemetryDeltaDoesNotChurnTheClipList`** (this is the test
  that pins the reported bug): seed the store `state.link = .online(CameraSamples.world(...))`
  in `makeControllerAndStore`, prefetch a row, then
  `store.send(.event(.tempChanged(soc: 40, sensor: 41)))` -- a world-changing but
  **recorder-unchanged** delta -- and assert `prefetchCancelCount(clipA) == 0`. With the old
  broad `\.link.world` row observer this fails (the delta full-reloads and cancels every
  handle); with the narrowed `\.link.world?.recorder` observer `renderRows` never runs and it
  passes. (A `storage_changed` / `mem_changed` variant is equivalent; `temp_changed` is the
  cheapest to build.)
- **New behavioral rendering regression `aClipsUpdateReconfiguresChangedRowsWithoutReloadingSurvivors`**
  -- the one test that pins **both** halves of the render contract at once: (i) a changed row **is**
  actually reconfigured in place -- its displayed metadata updates while its already-painted
  thumbnail is *kept* (never routed through `prepareForReuse`), and (ii) an unchanged survivor is
  likewise not routed through `prepareForReuse`. The pure `HomeRowDiff` tests can prove neither --
  they check the diff *math* (which ids are in `reconfiguredIDs`), not that
  `snapshot.reconfigureItems(reconfigure)` is applied. Drive **one combined update** (an insert
  *and* an in-place metadata change in a single snapshot, the realistic pull/refresh shape) so both
  halves are exercised together.
  - Setup: embed the controller in a window (the existing `embed` helper) with clips
    `[clipA, clipB]`. **The loader must be gated, not immediately-ready**, and must hand back a
    **distinct image per identity** -- an always-ready loader false-passes, because a bad
    `reloadData()`/`reloadItems` impl would blank a cell, re-dispatch its load, and *repaint before
    the assertion runs*, leaving `displayedImageForTesting` non-nil and `isLoadingForTesting ==
    false`. Add a `GatedThumbnailLoader` whose `thumbnail(clip)`, keyed by
    `ClipThumbnailIdentity(clip)`, returns a ready `ThumbnailImage` wrapping an
    **identity-distinct** 1x1 `UIImage` on the **first** request for that identity and **parks
    unreleased** (awaits a never-fired signal) on every **later** request for the *same*
    identity.
  - Steps: `waitUntil` both visible cells show a non-nil `displayedImageForTesting`; snapshot
    `originalA = cellA.displayedImageForTesting`, `originalLabelA = cellA.accessibilityLabel`, and
    `originalB = cellB.displayedImageForTesting` (cells via
    `controller.clipThumbnailCellForTesting(clipID:)`, the Change 3 seam; `accessibilityLabel` is
    UIKit-public, so it needs no extra seam). Then
    `store.send(.clips(.clipsResponse(.success(ClipsResponse(clips: [clipC, clipARelabeled], serverTimeMs: 0, nextCursor: nil)))))`,
    where `clipARelabeled` is clipA's **id 1 with the SAME etag (`"1-1"`) and a different `durMs`**
    (pick two `durMs` that format to different metadata strings, e.g. `30_000` vs `45_000`). The
    same etag is deliberate and load-bearing: a *new*-etag change would repaint clipA's thumbnail
    under **both** `reconfigureItems` and `reloadItems` (the identity changes either way, so the
    assertion could not tell them apart -- the exact hole this retarget closes). Holding the etag
    fixed while changing displayed metadata is what makes reconfigure (keeps the painted thumbnail)
    and reload (blanks it, then parks) diverge observably. `merged` overwrites `byID[1]` and folds
    this into `[clipC(3), clipB(2), clipARelabeled(1)]`, so `.finished(1)` stays in the id list --
    its `HomeRow` value changed, so the full-value `HomeRowDiff` puts it in `reconfiguredIDs` -- while
    `.finished(3)` inserts and `.finished(2)` is untouched.
  - Assert (i) **reconfigure applied, thumbnail kept**: `clipThumbnailCellForTesting(clipID: 1)`'s
    `accessibilityLabel` **changed from `originalLabelA`** (it now reflects the new `durMs` -- proof
    `reconfigureItems` re-invoked the cell provider; if that call is forgotten, `.finished(1)` is
    unchanged in the applied snapshot so the cell is never re-rendered and the label stays stale),
    **and** its `displayedImageForTesting` **is identical to `originalA`** with `isLoadingForTesting
    == false` (the same-identity `configure` is a no-op, so the painted thumbnail is preserved).
    Under `reloadItems`/`reloadData` clipA is instead `prepareForReuse`d, its re-dispatched
    same-identity `(1, "1-1")` load **parks**, and the cell is left blanked and loading -- failing
    the image half even though the label changed. Assert (ii) **survivor untouched**:
    `clipThumbnailCellForTesting(clipID: 2)`'s `displayedImageForTesting` **is identical to
    `originalB`** and `isLoadingForTesting == false`; under `reloadData()` clipB routes through
    `prepareForReuse`, its re-dispatched `(2, "2-2")` load parks, and the cell is left blanked and
    loading -- so this fails (the gating is what makes that flash observable instead of masked by an
    instant repaint).
  - It asserts only the cell's public `*ForTesting` / `accessibilityLabel` state through one
    internal seam, never a diffable internal, so it stays behavioral and structure-insensitive.
    (This subsumes the earlier insert-only draft -- the combined update still leaves clipB a pure
    survivor, so the no-reload guarantee is covered -- and, by reconfiguring clipA at a *fixed*
    identity, it distinguishes `reconfigureItems` from `reloadItems`, which a new-etag row could not
    since a new etag repaints under reload too.)
- `prefetchCancelsTheReplacedHandleBeforeStoringANewOne`, `cancelPrefetchingCancelsTheStoredHandle`,
  `viewWillDisappearCancelsEveryOutstandingHandle`, and both offscreen-quieting tests
  (`viewWillDisappearQuietsVisibleCellLoads`, `didEndDisplayingQuietsTheDepartingCellLoad`)
  stay behaviorally valid -- the prefetch data source and delegate hooks keep their
  signatures under diffable. They need no change beyond compiling against the retargeted
  controller.

`HomeRow.compose` itself is **already covered** by `DanCamTests/Features/Home/HomeRowTests.swift`
(live-row presence, anchor preservation, re-seed on segment/session change, no-tick-backward)
-- do not duplicate it. `ClipsFeature.merged` dedupe/sort is the reducer's concern and lives
in `ClipsFeatureTests`.

Add **exactly one** UITableView-rendering test -- `aClipsUpdateReconfiguresChangedRowsWithoutReloadingSurvivors`
above -- and no more. The reconfigure/uniqueness *math* is pinned purely by `HomeRowDiff` and
the compose *math* by the existing `HomeRowTests`; neither can catch an implementation that
computes the right diff and then either applies it with `reloadData()`/`reloadItems` (blanking
survivors) or drops the `reconfigureItems(reconfigure)` call (leaving changed rows stale). That
one rendering test closes both gaps by asserting the user-visible outcome -- surviving
thumbnails stay painted with no reload, and a reconfigured row's metadata updates in place while
its already-painted thumbnail is kept (a same-identity change, so reload's blank-and-park is what
makes a wrongful `reloadItems` observable) -- through the cell's public seams. Do
**not** additionally assert diffable internals -- snapshot contents, which
`apply`/`reconfigureItems` overload ran, dequeue/`prepareForReuse` call counts: those are
structure-sensitive and would break on any faithful refactor. One outcome-level rendering
test, plus the pure diff/compose tests, is the whole rendering coverage.

No changes to `AppFeatureTests`, `RecordingFeatureTests`, `ClipsFeatureTests`,
`ConnectionCoordinationTests`, `LinkTests`, `PreviewFeatureTests`, or
`AppShellViewControllerTests` (reducers, effects, and the observed slices for those screens
are unchanged).

---

## Change 6: ADR 17 (extends ADR 06, ADR 10, and ADR 16; none superseded)

ADR 06's decisions still hold (one domain root store, equality-gated `send`, scoped
observation, pages as projections), as do ADR 10's (event-folded `Link`/`World`/`HomeRow`
state machines) and ADR 16's (client-side clip thumbnails via the identity-keyed
`ClipThumbnailCell`). This migration **generalizes** the observation primitive (keypath
becomes sugar over `select`) and adds a design stance ("observe derived view-state, not raw
slices") plus the diffable `[HomeRow]` rendering choice, which is what lets ADR 16's async
thumbnails update in place instead of flashing on every reload. That is an extension, not a
reversal, so:

- Write `app/docs/design/17-2026-07-02-selector-observation-and-view-state.md`
  (`{seq}` = 17, next after the existing 16 `client-side-clip-thumbnails`; date =
  2026-07-02, the day written). Status: **Accepted**.
- Decision records: `observe(select:)` as the deduplicating primitive with keypath as sugar;
  the principle that a screen observes the derived `Equatable` view-state it renders
  (`HomeStatusPills` from `World?`; Health's `[TelemetryRow]`) when that projection is
  narrower than the slice, while raw-slice/narrowed-keypath observers stay where the slice
  already equals the view state (`\.recording`, `\.link.world?.recorder`, `\.clips.clips`);
  and the Home list using `UITableViewDiffableDataSource` keyed by `HomeRowID`
  (`.live`/`.finished`) with `reconfigureItems` (never `reloadItems`), replacing
  unconditional `reloadData()`, with prefetch handles re-keyed from `IndexPath` to clip
  identity and pruned per-diff rather than blanket-cancelled -- so ADR 16's async
  `ClipThumbnailCell` updates in place instead of flashing.
- "Related" links to ADR 06, ADR 10, ADR 16, and ADR 03; note ADR 06, ADR 10, and ADR 16
  stay **Accepted** (this ADR builds on them, the 03 -> 06 "extended, not superseded"
  precedent). Call out that the diffable rendering choice is specifically what makes ADR 16's
  async thumbnails update without a reload flash.
- Add the new ADR to the list in `app/AGENTS.md#Design decisions (ADRs)`. That list is
  **already complete through ADR 16** (`client-side-clip-thumbnails`), so there is nothing to
  backfill -- append only the one-line ADR 17 entry.
- Run `just adr-check` (validates filename format + contiguous per-side sequence).

---

## Alternatives considered (why this is the ideal shape)

- **Computed view-state property on `AppFeature.State` + keypath observe.** Rejected: pushes
  view-shaped fields into the domain `State`, violating ADR 06's guardrail. A view-owned
  `select:` closure is strictly more general (keypath = `select` sugar) and keeps the
  projection next to the screen.
- **Combine / `@Observable` / KVO for derived streams.** Rejected: reintroduces a reactive
  framework ADR 03 deliberately avoided; `observe(select:)` is ~8 lines over the store.
- **Reselect-style memoization.** Unnecessary: Swift value-type `Equatable` compares by
  value, and the store already caches `last` and compares with `!=`.
- **Keep the single `\.link.world` row observer.** Rejected: it recomposes the rows and
  full-reloads the table on every telemetry delta (`temp_changed`/`mem_changed`/...), the
  exact imprecision this plan targets. Narrowing rows to `\.link.world?.recorder` +
  `\.clips.clips` is what makes telemetry deltas wake nothing on Home.
- **Narrow the row observation (3a) but keep `reloadData()` (skip 3b).** This is the
  smallest change that stops the *reported* ~1 Hz flicker: telemetry deltas no longer reach
  `renderRows`, so an idle connected list stops blinking. Rejected as the whole fix because a
  genuine recorder change (a `segment_opened` segment roll) or a `clip_finalized` still calls
  `renderRows` -> `reloadData()`, which still blanks and re-loads *every* `ClipThumbnailCell`
  -- so the list flashes on every segment roll / new clip and loses scroll position. Once
  cells carry async thumbnails (ADR 16), 3a alone is a partial fix; 3b is what removes the
  remaining flashes. (If a reviewer wants a minimal hotfix landed first, 3a is a safe
  standalone commit; this plan does both.)
- **Gate `reloadData()` on `rows != oldRows` instead of diffing.** Rejected: combined with
  narrowing it would kill the redundant no-op reloads, but a genuine one-row change still
  full-reloads -- flashing the list and losing scroll position. Diffable animates the single
  insert/reconfigure and preserves scroll, which is the plan's thesis and now matters
  directly because cells carry async thumbnails (ADR 16) and the incident-lock toggle is
  coming.
- **Diffable keyed by `clip.id` / whole `HomeRow` as identifier.** Rejected: a bare `clip.id`
  key cannot represent the live row and traps when a live segment id momentarily coexists
  with a finished clip of the same id; a whole-value identifier turns every content change
  into delete+insert (loses the cell). `HomeRowID` (`.live`/`.finished`) +
  `reconfigureItems` is Apple's recommended pattern and reuses the cell.
- **Manual `performBatchUpdates` diffing.** Rejected: error-prone index math vs the
  framework's diff.
- **Build `ClipListDisplay` to preserve-on-failure / dedupe.** Rejected as redundant: the
  `ClipsFeature` reducer already preserves `clips` across `.loading`/`.failed` and `merged`
  already dedupes-by-id and sorts, so the displayed clips are simply `state.clips`.

---

## Verification

1. `just app-test` -- all suites green, including the new `StoreTests` selector cases,
   `HomeStatusPillsTests`, `HomeRowDiffTests`, the new Health dedup tests in
   `HealthTelemetryTests` (plus the `TelemetryRow` tuple -> struct adaptation), and the
   unchanged `HomeRowTests`.
2. `just adr-check` -- passes with ADR 17 added (its one-line entry appended to the
   already-complete-through-16 `app/AGENTS.md` ADR list).
3. Build + simulator smoke against the mock Pi
   (`DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080`, `just raspi-mock`):
   - **Status pills**: with normal temps and camera running, a stream of *world-changing*
     `temp_changed` (below threshold) / `mem_changed` / `storage_changed` deltas, plus a
     `camera_state_changed` between two non-offline states, does **not** re-fire
     `renderStatusPills` (temporary log to confirm ~one initial fire -- this is the meaningful
     check; `heartbeat` is excluded because it never changes `World`, so the equality-gated
     `send` already suppresses it before any narrowing); driving a sensor temp across the
     warning threshold -> the pill appears with correct color; clearing it / a
     `camera_state_changed` to/from `.offline` -> updates; sub-threshold drift -> no fire.
   - **Home list (the reported flicker)**: with the clip list scrolled into view and the Pi
     connected, watch across several telemetry ticks (~every 2 s) -- the thumbnails must stay
     **painted and still**, with no ~1 Hz blink to the gray placeholder (this is the bug;
     before the fix every visible thumbnail flashes in unison). A `clip_finalized` inserts
     exactly one `.finished` row (animated, scroll position kept, no full flash, other rows'
     thumbnails untouched); recording start inserts the `.live` row and it ticks each second
     via the timer with **no** `reloadData`; recorder phase/segment deltas update only the
     affected rows; a pure telemetry delta does **not** recompose the list; an in-flight
     prefetch on a surviving row is **not** cancelled by an unrelated `clip_finalized`; an
     empty list shows the empty-state background.
   - **Home recording controls**: record button + REC pill still update on tap and on an
     external `recording` flip.
   - **Offline/heartbeat**: a `streamFailed`/`heartbeatTimedOut` -> `link` goes
     `.offline(last:)`, `link.world` keeps its last value, so the rows and any live row
     persist on screen (no blanking); the shell strip flips and resume fires only on the
     `disconnected -> connected` edge.
   - **Health debug screen**: telemetry rows update only when a rendered string changes
     (temps/storage/mem), not on `recorder`-phase or `camera_state_changed` deltas.

## Notes / risks

- The only Store contract change is additive (`observe(select:)` primitive; keypath is
  sugar). Existing keypath call sites and tests are unchanged in behavior.
- The diffable migration is orthogonal to the 1 Hz live-elapsed timer, which keeps updating
  the visible `LiveClipCell` directly; steady recording produces value-equal live rows so
  snapshots never reconfigure the live cell out from under the timer.
- `HomeStatusPills.from` / `HealthTelemetry.rows` call `Formatters` inside the selector each
  delta -- cheap, and what lets dedup match display granularity; if `Formatters` precision
  changes, the string-based dedup tracks it automatically.
- No duplicate-id crash risk: `merged` dedupes finished ids and `HomeRowID`'s two cases keep
  a coexisting live/finished pair distinct.
- **Thumbnail regression traps (the three ways a sloppy diffable migration reintroduces the
  flicker or a stale row), each pinned by a named test:** (1) using `reloadData()`/`reloadItems`
  instead of `reconfigureItems` -- either runs `prepareForReuse`, which blanks the
  `ClipThumbnailCell`; (2) leaving the blanket `cancelAllPrefetches()` in `renderRows` (or
  keeping the `IndexPath`-keyed handle map), which re-churns the warm set on every row change;
  (3) computing `reconfiguredIDs` but forgetting the `snapshot.reconfigureItems(reconfigure)`
  call, so a changed row keeps its stale metadata. Traps (1) and (3) are both caught by
  `aClipsUpdateReconfiguresChangedRowsWithoutReloadingSurvivors`, which reconfigures `clipA` at a
  **fixed identity** (same etag, changed `durMs`): its **gated, identity-distinct** loader parks any
  re-dispatched same-identity load, so a wrongful `reloadItems`/`reloadData` leaves an observable
  blank instead of an instant repaint (trap 1), while a forgotten `reconfigureItems` leaves clipA's
  `accessibilityLabel` stale (trap 3). The fixed identity is what separates the two failure modes
  from a correct reconfigure -- a new-etag row would repaint under reload too, so it could not.
  Trap (2) is caught by `telemetryDeltaDoesNotChurnTheClipList` and
  `aClipsUpdatePreservesSurvivingPrefetchHandles`. All three are called out in Change 3(c).
- The `ThumbnailLoader` is single-flight + cache-first (`Media/ThumbnailLoader.swift`), so
  even a same-identity reconfigure that *did* re-request would hit the memory cache and not
  re-fetch; the in-place no-op is the belt, the cache is the suspenders. Still fix both, so a
  cold cell isn't blanked.
- Pre-existing dirty tree (`DanCam.xcscheme`, `docs/roadmap.md`, `plans/wip/*`) is untouched
  user work; do not stage or revert it.
</content>
