# Plan: Day section headers for the Home "Recent clips" list

## Context

The Home screen's "Recent clips" table is one flat, newest-first, infinitely-paging
list of ~30 s segments. Finding footage from a known time ("an incident happened
yesterday") means scroll-hunting through potentially hundreds of rows. Now that swoop
`moss` (time provenance) is finished, clips carry verified wall-clock `start_ms` /
`time_approximate: false` once the per-boot offset is synced -- so the app can finally
group the list by real calendar days.

This plan adds sticky day section headers ("Today", "Yesterday", "Tuesday, Jul 7")
to the existing table. It is the first step of the clip-finding arc (later candidates:
drive grouping by boottag, calendar jump via the reserved `from`/`to` params, incidents
filter after `nova`); those are recorded in the roadmap but not built here.

Decisions already made with Dan:

1. **In-place run sections.** Keep the global newest-first seq order (clips arrive
   sorted id-desc from `ClipsFeature`). Contiguous dated clips bucket into
   local-calendar-day sections; contiguous undated clips (`startMs == nil` or
   `timeApproximate == true` -- whole never-synced boots) form their own
   "Date unknown" sections in place, between whatever day sections they fall between.
   Never re-sort.
2. **Live/pending row lives under "Today"**, creating that section if no finished
   clip is from today (Today's day key comes from the phone clock).
3. **Row subtitles switch to time-of-day only** (e.g. "14:02:31" + duration) since
   the header now carries the date. Viewer detail line and export filename keep the
   full date.

## Ground truth (verified)

- `app/DanCam/DanCam/Features/Home/HomeRowDiff.swift#HomeSection` is a single-case
  enum (`.main`); `HomeRowID` and `HomeRowDiff.reconfiguredIDs` live beside it and
  operate on flat row arrays.
- `app/DanCam/DanCam/Features/Home/HomeViewController.swift#HomeRow.compose` is the
  pure row builder (live/pending gating via `HomeRow.shouldShowPendingRow`); it takes
  only a `ContinuousClock.Instant` -- no wall clock. `renderRows` builds a
  single-section `NSDiffableDataSourceSnapshot<HomeSection, HomeRowID>`.
- The table is `UITableView(style: .plain)`, so sticky section headers come free.
  No header code, no `Calendar` usage, and no `NotificationCenter` usage exist
  anywhere in the app target yet.
- `row(at:)`, row selection, swipe actions, and both prefetch delegate callbacks
  already resolve rows via `dataSource.itemIdentifier(for:)` -- section-safe as-is.
  Only the pagination trigger in `tableView(_:willDisplay:forRowAt:)` does flat
  `indexPath.row >= rows.count - paginationThreshold` math and breaks under sections.
- `app/DanCam/DanCam/Support/Formatters.swift` is the formatter home: inline
  `DateFormatter`s, `en_US_POSIX`, injectable `timeZone: TimeZone = .current`. The
  `startMs != nil && timeApproximate == false` guard is duplicated in
  `Formatters.clipCreatedTime` and `Formatters.clipExportFilename`.
- Tests: `DanCamTests/Support/FormattersTests.swift` pins `clipListLine` to
  `"2026-01-01 00:00:00 . 00:30"`-style output (must change);
  `DanCamTests/Support/CameraSamples.swift#CameraSamples.clip` already accepts
  `startMs`/`timeApproximate` (defaults undated). The Xcode project uses filesystem-
  synchronized groups, so new `.swift` files need no pbxproj edits.
- `AppFeature` already reloads clips on `time_synced`; `.finished(id)` row IDs are
  stable across that migration.

## Design

### Section identity

```swift
nonisolated enum HomeSection: Hashable, Sendable {
    case day(startOfDay: Date, occurrence: Int)
    case dateUnknown(occurrence: Int)
}
```

Replace the single-case enum outright (no shim). `startOfDay` is
`calendar.startOfDay(for:)` of the clip's resolved date (or of `today` for the
live/pending row). `occurrence` counts earlier runs with the same base, walking
top-down -- it exists because runs of the same day CAN split (synced boot today /
never-synced boot / synced boot today) and multiple Date-unknown runs coexist, and
duplicate section identifiers crash the diffable snapshot.

Tradeoff, stated: anchoring run identity to a member clip id churns on the *common*
mutations (top run's newest id changes on every finalize; bottom run's oldest id
changes on every page append). Ordinals are stable under both -- prepending into the
top run and appending to the bottom run never change any run's occurrence. Cost: in
the rare split-run case a lower duplicate's occurrence bumps and that one section
animates as remove+insert. Acceptable; pick ordinals.

### Pure composition layer

New `HomeRow.composeSections` wraps the existing `HomeRow.compose` verbatim (all
live/pending gating and freeze/thaw logic stays single-sourced):

```swift
nonisolated struct HomeSectionModel: Equatable, Sendable {
    var id: HomeSection
    var rows: [HomeRow]
}

extension HomeRow {
    static func composeSections(
        clips: [Clip],
        recording: RecordingFeature.State,
        recorder: RecorderTruth,
        previousLive: LiveSegment?,
        now: ContinuousClock.Instant,   // live-elapsed math, unchanged semantics
        today: Date,                    // wall clock; Today's day key
        calendar: Calendar              // injectable zone for bucketing
    ) -> [HomeSectionModel]
}
```

Algorithm: flat rows from `compose`; map each row to a bucket base
(`.pending`/`.live` -> `startOfDay(today)`; `.finished` -> `clip.resolvedStartDate`
bucketed by `startOfDay`, or the unknown base when nil); group contiguous equal bases
into runs; assign occurrences per base top-down. The live/pending row is always first
with base = today, so it merges into a leading today run or creates a fresh Today
section above undated/older runs.

### Rendering, rollover, pagination

- Small `UITableViewHeaderFooterView` subclass, registered on the table;
  `tableView(_:viewForHeaderInSection:)` resolves the section via
  `dataSource.sectionIdentifier(for:)` and computes the title at dequeue time (so
  scrolled-in headers are always fresh).
- Day rollover: section identity is the absolute date, so at midnight the snapshot
  for yesterday's clips does NOT change -- only labels do. Observe
  `.NSCalendarDayChanged` and `UIApplication.significantTimeChangeNotification`;
  handler re-renders (live row migrates to the new Today section via normal diffing)
  and then re-configures the *visible* header views in place, because a snapshot
  apply does not re-dequeue headers of unchanged sections.
- Injectable wall clock + calendar: the VC takes a `wallNow: () -> Date` provider
  and a `currentCalendar: () -> Calendar` provider (both default to `.current`,
  settable in tests) and routes every wall-clock/calendar read through them --
  `renderRows`'s `today:`/`calendar:`, the header-title helper's `now:`/`calendar:`,
  and `refreshVisibleDayHeaders`. The pair travels together on purpose: the same
  guarantee the pure layer already gives (`composeSections` and `dayHeader` share one
  `Calendar` so bucketing and labeling never disagree on zone) must hold at the VC, or
  a test can pin `wallNow` but not the calendar/zone the day boundary is computed in.
  This is a deliberate reversal of the earlier "no VC clock seam" stance: the rollover
  *logic* is pure-tested, but the *wiring* that composes it (observer registration +
  two wall-clock reads + `refreshVisibleDayHeaders`) is the one runtime path where a
  stale read, missed observer, or broken refresh would silently strand
  "Today"/"Yesterday" headers or the live row in the wrong day. The seam makes that
  path deterministically testable (fix the calendar/zone, advance the clock, post the
  notification, assert the outcome) and also de-flakes the date-dependent VC tests
  that today lean on the real wall clock.
- Pagination: at render time compute `paginationTailIDs = Set(flatRows.suffix(paginationThreshold).map(\.id))`;
  `willDisplay` triggers `.loadMore` when the displayed item's ID is in that set and
  the row is `.finished`. No other delegate changes needed.

## Implementation steps

### Commit 1 -- `feat(app): add day-header and time-of-day formatters`

1. `app/DanCam/DanCam/Networking/ClipsResponse.swift` -- add the single source of
   date truth:
   ```swift
   extension Clip {
       /// Non-nil only when the Pi recorded this clip with verified wall-clock time.
       var resolvedStartDate: Date? {
           guard let startMs, timeApproximate == false else { return nil }
           return Date(timeIntervalSince1970: Double(startMs) / 1_000)
       }
   }
   ```
2. `app/DanCam/DanCam/Support/Formatters.swift` -- two new functions in the existing
   inline-formatter / `en_US_POSIX` style:
   - `clipTimeOfDay(_ clip: Clip, timeZone: TimeZone = .current) -> String?` --
     `"14:02:31"`; nil unless `resolvedStartDate` is non-nil.
   - `dayHeader(_ dayStart: Date, now: Date, calendar: Calendar = .current) -> String`
     -- "Today" via `calendar.isDate(_:inSameDayAs: now)`, "Yesterday" via
     `calendar.date(byAdding: .day, value: -1, to: now)`, else `"EEEE, MMM d"`,
     appending `", yyyy"` when the year differs from `now`'s
     (`calendar.component(.year, from:)`). Taking a `Calendar` (which carries its
     `TimeZone`) is a deliberate deviation from the bare-`timeZone` convention:
     Today/Yesterday needs calendar day arithmetic, and `composeSections` takes the
     same `Calendar` so bucketing and labeling can never disagree.
   - Rewrite the guards in `Formatters.clipCreatedTime` and
     `Formatters.clipExportFilename` to use `clip.resolvedStartDate` (behavior
     identical; kills the duplicated guard). Do NOT touch `clipListLine` yet --
     keeps this commit green and the date visible on screen until headers exist.
3. `app/DanCam/DanCamTests/Support/FormattersTests.swift` -- `dayHeader` and
   `clipTimeOfDay` cases (fixed gregorian calendar + explicit zone, fixed `now`;
   pin exact strings: Today / Yesterday / same-year weekday form / prior-year form).

### Commit 2 -- `feat(app): compose home rows into day sections`

4. New `app/DanCam/DanCam/Features/Home/HomeSections.swift` -- the two-case
   `HomeSection` (moved out of `HomeRowDiff.swift`), `HomeSectionModel`, and
   `HomeRow.composeSections` as designed. `HomeRowDiff.swift` keeps `HomeRowID` and
   `HomeRowDiff` unchanged.
5. New `app/DanCam/DanCamTests/Features/Home/HomeSectionsTests.swift` -- pure
   composition tests (list below). Reuse `CameraSamples.clip` for dated fixtures;
   lift `HomeRowTests`' private `recorder(...)` helper into shared test support if
   that beats copying it.

### Commit 3 -- `feat(app): render home clips in sticky day sections`

6. New `app/DanCam/DanCam/Features/Home/HomeDayHeaderView.swift` --
   `UITableViewHeaderFooterView` subclass in the app's programmatic-view convention
   (unavailable `init?(coder:)`), one secondary-styled `UILabel` pinned to
   `contentView.layoutMarginsGuide`, `configure(title:)`, plus a
   `titleTextForTesting` accessor.
7. `app/DanCam/DanCam/Features/Home/HomeViewController.swift`:
   - `configureClipsTable`: register the header view; `sectionHeaderTopPadding = 0`;
     `sectionHeaderHeight = UITableView.automaticDimension`;
     `estimatedSectionHeaderHeight = 32`.
   - New state: `sections: [HomeSectionModel]`, `paginationTailIDs: Set<HomeRowID>`.
     Keep `rows`/`rowsByID` as the flattened view (still feeds `previousLive`,
     `HomeRowDiff`, `updateVisibleLiveElapsed`, `updateLiveTickTimer`,
     `updateClipsPresentation`'s empty check).
   - Injectable wall clock + calendar: add `wallNow: () -> Date` (defaults to
     `Date.init`) and `currentCalendar: () -> Calendar` (defaults to `{ .current }`)
     as init params, stored beside the existing monotonic `clock`. `wallNow` is named
     to stay distinct from `renderRows`'s monotonic `now: ContinuousClock.Instant?`.
     Every wall-clock/calendar read below goes through them. Tests drive `wallNow` by
     capturing a mutable `var` in the closure (or a small settable box) and advancing
     it, and pass a fixed gregorian/zoned calendar for `currentCalendar`.
   - `renderRows(now:)`: call `composeSections(..., today: wallNow(), calendar: currentCalendar())`;
     flatten for the diff (`HomeRowDiff.reconfiguredIDs` unchanged); build the
     snapshot per section; recompute `paginationTailIDs`.
   - `tableView(_:willDisplay:forRowAt:)`: replace flat-index math with the
     `paginationTailIDs` check described above.
   - Add `tableView(_:viewForHeaderInSection:)` + a `headerTitle(for: HomeSection)`
     helper (`.day` -> `Formatters.dayHeader(startOfDay, now: wallNow(), calendar: currentCalendar())`;
     `.dateUnknown` -> `"Date unknown"`).
   - Day-rollover observers for `.NSCalendarDayChanged` and
     `UIApplication.significantTimeChangeNotification` (block-based, main queue,
     `MainActor.assumeIsolated`, tokens removed in deinit -- mirror the
     `liveTickTimer` lifecycle pattern). Handler: `renderRows()` then a
     `refreshVisibleDayHeaders()` helper that walks visible
     `clipsTableView.headerView(forSection:)` views and re-configures their titles
     via `headerTitle(for:)` (so it reads the same `wallNow()`).
   - ForTesting accessors: `sectionHeaderTitlesForTesting: [String]`,
     `dayHeaderViewForTesting(section:)`, and a way to advance the injected
     `wallNow` provider.
8. `app/DanCam/DanCam/Support/Formatters.swift#clipListLine` -- switch
   `clipCreatedTime` to `clipTimeOfDay` (lands with the headers so the date never
   disappears between commits). `clipDetailLine` / `clipExportFilename` untouched.
9. Update affected existing tests in the same commit (see test plan).

Time-sync reload needs no code: on `time_synced` -> `.load`, re-dated clips re-bucket
from `.dateUnknown` into `.day` sections as diffable moves (stable `.finished(id)`
IDs) plus subtitle reconfigures; the existing
`trustedTimestampUpdateReconfiguresRowWithoutReloadingThumbnail` test doubles as the
regression net. A large one-time migration animates busily -- accepted.

### Commit 4 -- `docs: add sift clip-finding swoop to roadmap`

10. `docs/roadmap.md` -- add swoop `sift` (find clips in the Recent list): day
    section headers as a checked item (this plan), with unchecked one-liner
    candidates for the rest of the arc: drive grouping via boottag exposed in
    `/v1/clips`, calendar jump backed by the reserved `from`/`to` window params,
    and a locked/incidents filter (gated on `nova`). No ADR: this is UI composition
    within existing contract surfaces, not an architecture decision.

## Test plan

**New `DanCamTests/Features/Home/HomeSectionsTests.swift`** (fixed gregorian
calendar, explicit zones, epoch-ms helpers):
- Dated clips across two days -> two `.day` sections in order; same-day clips share one.
- Contiguous undated run between dated runs -> in-place `.dateUnknown` section;
  ordering never re-sorted.
- Split same-day runs (dated-today / undated / dated-today) ->
  `day(today, 0)`, `dateUnknown(0)`, `day(today, 1)`; two unknown runs ->
  `dateUnknown(0)`, `dateUnknown(1)`; assert all section IDs unique.
- Live row merges into an existing today section; creates `day(today, 0)` when the
  newest finished clip is older or undated (undated-newest yields
  `[day(today) [live], dateUnknown [clips]]`); same three cases for `.pending`.
- Identity stability: prepending a new dated-today clip keeps every prior section id;
  appending an older page keeps the bottom section id when the day continues.
- Timezone boundary: clip at `2026-01-01T23:30Z` buckets Jan 1 under UTC, Jan 2
  under UTC+2.
- Empty clips + no live -> `[]`.

**`DanCamTests/Support/FormattersTests.swift`**: `dayHeader` four label forms;
`clipTimeOfDay` trusted vs approximate/nil; update the `clipListLine` expectation to
the time-of-day form.

**`DanCamTests/Features/Home/ClipThumbnailCellTests.swift`**: dated-clip subtitle
matches `^\d{2}:\d{2}:\d{2} . 00:30$` (regex, zone-agnostic) and contains no year.

**`DanCamTests/Features/Home/HomeViewControllerTests.swift`**:
- Header presence: one clip dated now + one dated ~2 days back ->
  `sectionHeaderTitlesForTesting.first == "Today"`, two sections, and the section-0
  header view's `titleTextForTesting == "Today"` after layout.
- Pagination across sections: seed dated + undated clips with a cursor installed and
  a fetch-spy `ClipsClient`; `willDisplay` on the last index path of the last section
  fires a fetch with that cursor; the first row's index path does not.
- Day rollover wiring: construct the VC with an injected fixed gregorian/zoned
  `currentCalendar` and a mutable `wallNow` set to 23:59 on day N; seed a
  live/recording world plus a finished clip dated day N. Before rollover the live row
  and the clip share one section -> `sectionHeaderTitlesForTesting == ["Today"]`.
  Advance `wallNow` to 00:01 on day N+1, post `.NSCalendarDayChanged`, and assert:
  (a) `sectionHeaderTitlesForTesting == ["Today", "Yesterday"]`; (b) the live/pending
  row is now in section 0 (the freshly inserted `day(N+1)` "Today" section); (c) the
  finished clip is in section 1 -- the persisting `day(N)` section, whose identity did
  NOT change, so its header retitles "Today" -> "Yesterday" via the in-place
  `refreshVisibleDayHeaders` path (assert the visible `dayHeaderViewForTesting(1)`
  reads "Yesterday", which is exactly the re-dequeue-skipped case the refresh exists
  for). This exercises observer -> `renderRows` -> `refreshVisibleDayHeaders` end to
  end; the injected calendar/zone keeps the day boundary deterministic across hosts.
- Existing prefetch tests and the trusted-timestamp reconfigure test keep passing
  (their all-undated fixtures land in one `dateUnknown(0)` section 0).

`HomeRowTests`, `HomeRowDiffTests`, `ClipsFeatureTests` need no changes (compose,
diff, reducer untouched). Day rollover is covered on two levels: the pure layer
(`dayHeader`/`composeSections` take `now`/`today`) for the grouping/labeling logic,
and the injected-`wallNow` VC test above for the observer -> `renderRows` ->
`refreshVisibleDayHeaders` wiring that the pure tests can't reach.

## Verification

- `just app-test` -- full Swift Testing suite.
- `just app-lint` -- clean build; zero new warnings.
- Manual mock-Pi flow: `just raspi-mock-clips` (mock Pi with a sample finished clip),
  run the app in the simulator against `http://127.0.0.1:8080`. Check: clips grouped
  under day / "Date unknown" headers; start recording (`just raspi-mock`, 5 s
  segments) and confirm the REC row sits under a "Today" header even when finished
  clips below are undated; headers stick while scrolling; row subtitles show
  time-of-day only while the clip viewer keeps the full date.

## Out of scope

Drive grouping (boottag), calendar jump / `from`-`to` realization, incidents filter,
any Pi/contract changes -- recorded in the roadmap `sift` entry, not built here.

## Commit progress

- [x] 1. feat(app): add day-header and time-of-day formatters
- [x] 2. feat(app): compose home rows into day sections
- [x] 3. feat(app): render home clips in sticky day sections
- [ ] 4. docs: add sift clip-finding swoop to roadmap

## Implementation notes

- Commit 2 keeps the existing flat Home table wired through one section until commit 3 replaces rendering; that temporary section uses `.dateUnknown(occurrence: 0)` because `.main` was removed with the new two-case `HomeSection`.
- Commit 3 snapshots visible thumbnail images around section rebuckets because `UITableView` may recreate a visible cell when the section identifier changes even though the row identifier is stable.
