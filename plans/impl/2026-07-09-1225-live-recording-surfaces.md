# Plan: relocate the live recording row -- widget under Record button, drive-detail live row, drive-card REC pill

## Context

The live recording row (and its pending "Starting..." precursor) currently renders
inside the Home "Recent clips" list, standalone at the top of the Today section
(decided in app ADR 19). With clips now grouped into per-drive cards, that placement
is awkward: the row is recorder state, not browsable footage, and it forces a pile of
list special-casing (fake Today bucketing, per-second cell lookups, diffable identity
churn on every segment roll). This plan moves the live/pending presentation to three
purpose-built surfaces:

1. Home: a live-recording widget directly under the Record (Stop) button.
2. Drive detail: the live row at the top of the list when the viewed drive (bootTag)
   is the one currently being recorded into.
3. Recent clips: a "REC" pill on the currently-recording drive's card, so the user
   knows which drive the recording streams into.

Out of scope: anything about surfacing recording-start failures.

User-confirmed choices:
- The existing REC pill overlaid on the preview's top-right corner STAYS (in
  addition to the new widget).
- The widget title is the raw segment filename ("seg_00066.ts"), identical to the
  drive-detail row -- one renderer, no per-host configuration flag.

## Key gap the plan closes

Nothing on the live path carries `boot_tag` today. The snapshot has only `boot_id`
(and the contract fixture's `"boot-7f3a91c2"` is not even hex-derivable -- it is
inconsistent with `clip_finalized.json`'s `"7f3a91c2b0d4"`). The derivation canon
lives only in Rust (`raspi/service/src/recorder.rs#fn boot_tag`: strip dashes,
lowercase, first 12 chars, must be lowercase hex; raspi ADR 15). So surfaces 2 and 3
need a small additive wire-contract change: the snapshot gains a nullable `boot_tag`.

## Architecture decisions

### (a) Contract: `boot_tag: Option<String>` at the Snapshot top level

- Per-boot fact, not per-segment: a drive IS a boot. Putting it on `current_segment`
  would restate a boot constant every segment and vanish exactly when needed most --
  during pending (currentSegment == nil) and idle.
- Production is one line: all snapshot construction funnels through
  `raspi/service/src/world.rs#fn snapshot`; populate
  `boot_tag: crate::recorder::boot_tag(boot_id)` there. Covers real Pi, mock,
  `/v1/status`, and the SSE first frame at once (`event_hub.rs` calls
  `world.snapshot(&self.boot_id, ...)`). `events.rs#fn enrich_current_segment` is
  untouched. Nullable mirrors clip `boot_tag` (underivable boot_id -> None).
- Fixture consistency fix in `contract/events/snapshot.json`:
  `"boot_id": "7f3a91c2-b0d4-4e15-b196-20e0416af749"` plus
  `"boot_tag": "7f3a91c2b0d4"` -- now internally consistent with
  `clip_finalized.json`.
- Swift: `CameraEvent.swift#struct World` gains `bootTag: String?` (snake_case
  decoding is automatic; `World.folding` needs no change -- the tag only arrives via
  snapshot and every reconnect is snapshot-first).

### (b) Shared pure model: `LiveRecordingStatus` + `RecordingDrive`

New file `app/DanCam/DanCam/Features/Recording/LiveRecordingStatus.swift`
(`LiveSegment` moves here from `HomeViewController.swift` unchanged):

```swift
nonisolated enum LiveRecordingStatus: Equatable, Sendable {
    case none
    case pending
    case live(LiveSegment)

    static func from(recording: RecordingFeature.State, recorder: RecorderTruth,
                     previous: LiveSegment?, now: ContinuousClock.Instant) -> Self
    var liveSegment: LiveSegment? { ... }
}
```

`from` absorbs verbatim `HomeRow.tickingLiveSegment`, `frozenLiveSegment`, and
`shouldShowPendingRow` (all currently in `HomeViewController.swift`). The ~17-test
freeze/thaw/pending suite in `HomeRowTests.swift` retargets nearly 1:1.

Drive attribution is a second, separate derivation (temporal status vs identity):

```swift
nonisolated struct RecordingDrive: Equatable, Sendable {
    enum Freshness: Equatable, Sendable { case live, lastKnown }
    var bootTag: String
    var freshness: Freshness

    static func from(status: LiveRecordingStatus, worldBootTag: String?) -> Self?
    // .none or nil tag -> nil; .pending -> .live; .live(seg) -> seg.isTicking ? .live : .lastKnown
}
```

Both hosts read their inputs through ONE equality-gated projection. Split
observations would be a coherence bug: `Store.swift#func notifyObservers` runs
observers sequentially per `send`, and a VC that caches slices in separate ivars
(as Home does today with `recorderTruth`) can render mid-pass with a fresh
recorder status paired to a stale boot tag -- one wrong frame that marks the old
drive's card as recording on a reconnect with a new boot. So the same file also
defines the shared selector:

```swift
nonisolated struct LiveRecordingInputs: Equatable, Sendable {
    var recording: RecordingFeature.State
    var recorder: RecorderTruth
    var worldBootTag: String?   // from world, not onlineWorld, so last-known
                                // pairing stays coherent

    static func from(_ state: AppFeature.State) -> Self
}
```

Each hosting VC observes `store.observe(select: LiveRecordingInputs.from)` and
derives `LiveRecordingStatus` and `RecordingDrive` from that one value in the
same callback (threading its own previous `liveSegment`, as `renderRows` threads
`previousLive` today); freshness carries the ADR 18 truth.

### (c) One renderer, two hosts: `LiveRecordingStatusView` + thin cell wrapper

New `app/DanCam/DanCam/Views/LiveRecordingStatusView.swift` -- the exact content of
today's `LiveClipCell`: filename title ("seg_%05d.ts" / "Starting..."),
`StatusPillView` REC badge (red when ticking/pending, gray when frozen), monospaced
elapsed label (`Formatters.countUpDuration` ticking / `Formatters.approximateDuration`
"~mm:ss" frozen), same accessibility strings. API:
`configure(status: LiveRecordingStatus, now: ContinuousClock.Instant)` plus test
hooks. `LiveClipCell` is deleted.

- Home: inserted into `headerStack` after `recordButtonRow`; `isHidden` when
  `.none`. Every show/hide sets `needsHeaderRefit = true` + `setNeedsLayout()` so
  `installOrSizeHeaderIfPossible` resizes the header.
- Drive detail: `LiveRecordingCell: UITableViewCell` (same file) pinning one
  `LiveRecordingStatusView` to `contentView.layoutMarginsGuide`,
  `selectionStyle = .none`. Two surfaces, two instances (a UIView cannot have two
  superviews); the ~30-line wrapper buys separators/margins matching
  `ClipThumbnailCell`.

### (d) Drive-card REC pill: `composeSections(clips:recordingDrive:today:calendar:)`

- `HomeSections.swift#composeSections` drops `recording`/`recorder`/`previousLive`/
  `now`, gains `recordingDrive: RecordingDrive?`. The forced-into-Today
  `.pending`/`.live` bucketing branch dies; `HomeRow.compose` collapses to
  `clips.map(HomeRow.finished)` and is inlined.
- `HomeSections.swift#DriveGroup` gains `recording: RecordingDrive.Freshness?`
  (nil = not recording). `coalescedDriveRows` sets it when
  `bootTag == recordingDrive.bootTag` AND `occurrence == 0` (newest run only --
  marking every occurrence would claim the recording streams into yesterday's
  card of a midnight-spanning drive).
- Reconfigure semantics verified: `HomeRowDiff.swift#reconfiguredIDs` compares full
  `HomeRow` equality under stable `HomeRowID`s; `.drive(bootTag:occurrence:)`
  excludes the flag, so a freshness flip is an in-place reconfigure, not
  insert/remove churn.
- `ClipThumbnailCell.swift` gains a `StatusPillView` REC pill in the title row,
  hidden by default; configured only by `configure(drive:...)` from
  `drive.recording` (red for `.live`, gray for `.lastKnown`), explicitly hidden in
  `configure(clip:...)` and `prepareForReuse`. Orthogonal to the
  loadToken/cancelLoad thumbnail machinery.

### (e) Tick timer: the view owns it

`LiveRecordingStatusView` owns its own 1 Hz closure-based `Timer` ([weak self]),
running only while the configured status is a ticking `LiveSegment` AND
`window != nil` (`didMoveToWindow` + configure). This deletes `liveTickTimer` +
`HomeViewController.swift#updateVisibleLiveElapsed` (the per-second
`dataSource.indexPath` + `cellForRow` path) and gives DriveDetail ticking for free.
Diffable data sources no longer participate in ticking on either screen.

### (f) Drive detail integration

- Item identifier changes from `Int` to:

```swift
private nonisolated enum DriveDetailRow: Hashable, Sendable {
    case liveRecording   // ONE stable identity for pending AND live
    case clip(Int)
}
```

  Stable identity means pending -> live and segment rolls are reconfigures (an
  improvement over Home's old `(session, id)` identity that churned every 30-60 s).
- One added equality-gated observation beside the existing clips projection:
  `store.observe(select: LiveRecordingInputs.from)` (the shared projection from
  (b)); the callback recomputes `liveRecordingStatus` and re-applies the
  snapshot. The row appears atop the `.clips` section only when the VC's
  `bootTag` matches `RecordingDrive.from(...)`. `DriveDetailState` stays a pure
  clips projection (its tests survive unchanged).
- Explicit reconfigure for the stable ID: re-applying a snapshot whose item set
  is unchanged does not refresh cells, so `render` extends the existing
  `changedClipIDs` pattern -- reconfigure = changed clips mapped to `.clip(id)`,
  plus `.liveRecording` whenever the previously rendered `liveRecordingStatus`
  differs from the new one and the row is present in both snapshots. That is what
  lands pending -> live, freeze/thaw (red/gray + formatter), and segment-roll
  title changes in the visible cell; the view-owned timer only ticks elapsed,
  everything else flows through `configure`.
- Mid-segment open seeding: `segment_opened` folds `durMs: nil`
  (`CameraEvent.swift#struct RecorderSegment`), so a detail VC pushed mid-segment
  with no previous segment would anchor elapsed at "now" and show 00:00 while
  Home has been ticking for a while. `DriveDetailViewController.init` gains
  `initialLiveSegment: LiveSegment?`; Home passes its current
  `liveRecordingStatus.liveSegment` at push time (safe to pass unconditionally --
  `LiveRecordingStatus.from` only consults `previous` when session and segment id
  match). Detail threads its own previous normally from then on.
- Delegate guards: selection no-op and nil swipe for `.liveRecording`; pagination
  tail compares `.clip(id)` only.
- Empty-drive behavior change: `DriveDetailViewController.swift#handlePostApplyState`
  currently pops/splices when `clips.isEmpty && !canLoadMore`; gate that on the live
  row being absent. A live/pending row with zero finished clips is legitimate (fresh
  boot right after start, or user deleted everything mid-drive); once recording
  stops, the next render pops as before.

## Edge cases

- Recording active, snapshot `bootTag` nil (unstamped boot / old binary): widget
  fully works (never consults the tag); `RecordingDrive.from` -> nil, so no card
  pill and no detail row. Honest degradation.
- Current drive has zero finalized clips: no card exists (cards derive from
  finished clips) -- the widget carries the state; detail stays alive per (f).
- Midnight-spanning / split-run drives: pill on occurrence 0 only (newest run).
- Day rollover: the widget is date-independent. `handleDayRollover` stays for
  finished/drive re-bucketing. With no live rows in the table, an active recording
  with zero finished clips shows the "No clips yet" placeholder under "Recent
  clips" while the widget shows the recording -- correct; pin in a test.
- Link drop mid-recording: widget and detail row freeze gray at `~mm:ss`, card pill
  goes gray; reconnect snapshot thaws all three (previous-threading keeps the
  count-up monotonic). Heartbeat-timeout-with-no-world (`.unknown`) -> everything
  hidden/`.none`.
- Stop/start within one boot: same bootTag -- pill correctly stays on the same card
  across sessions; pending keeps it lit.
- Reconnect to a different boot (Pi rebooted mid-session): the snapshot updates
  recorder state and `world.bootTag` in one `send`, and both hosts read them
  through the single `LiveRecordingInputs` projection, so no render can pair the
  new recorder status with the old boot tag -- the old drive's card never flashes
  a REC pill; pin in a test.
- Push the recording drive's detail mid-segment: elapsed seeds from Home's
  passed-in `initialLiveSegment`, not 00:00 (see (f)); pin in a test.
- Mock/dev: `raspi/service/src/lib.rs#fn resolve_boot_id` falls back to a random
  UUID, so the mock always yields a valid boot_tag -- all three surfaces are
  exercisable in the simulator.
- The preview `recPill` (kept, per user decision): still toggled by
  `HomeViewController.swift#renderRecording`; untouched by this plan.

## Implementation steps (commit split)

Each commit green on `just raspi-test` + `just app-test`. New Swift files need no
pbxproj edits (file-system-synchronized groups).

### Commit 1 -- `feat(contract): expose per-boot boot_tag in the events snapshot`
- `raspi/service/src/events.rs#struct Snapshot`: add `pub boot_tag: Option<String>`
  after `boot_id`; update the Snapshot literal in `events.rs#fn canonical_events`.
- `raspi/service/src/world.rs#fn snapshot`: populate via
  `crate::recorder::boot_tag(boot_id)`; extend
  `world.rs#fn snapshot_projects_boot_epoch_and_recorder_state` (asserts None for
  boot_id "boot") and add a valid-UUID derivation assert.
- `contract/events/snapshot.json`: boot_id -> full UUID + `boot_tag` (values above).
- `contract/events/README.md`: one-line note -- snapshot-level nullable `boot_tag`
  is the per-boot drive identity, matching clip `boot_tag`.
- App: `CameraEvent.swift#struct World` + `bootTag: String?`;
  `CameraEventCorpusTests.swift#decodesRepresentativeVariants` expected literal;
  `CameraSamples.swift#func world` gains `bootTag: String? = nil`.
- Same commit: dated additive note in
  `raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md` (this ADR already
  carries dated notes for exactly this kind of change, e.g. the sift clip
  `boot_tag` note): snapshot/status gain nullable `boot_tag`, derived per ADR 15
  canon, motivated by the app ADR in commit 6.

### Commit 2 -- `refactor(app): extract LiveRecordingStatus from HomeRow composition`
- New `Features/Recording/LiveRecordingStatus.swift`: `LiveSegment` (moved),
  `LiveRecordingStatus`, `RecordingDrive`, `LiveRecordingInputs`.
- `HomeViewController.swift#HomeRow.compose` delegates to
  `LiveRecordingStatus.from`; `tickingLiveSegment`/`frozenLiveSegment`/
  `shouldShowPendingRow` deleted from `HomeRow`. List behavior unchanged.
- Tests: `HomeRowTests.swift` retargets to new `LiveRecordingStatusTests.swift`;
  add `RecordingDrive.from` cases (nil tag, none, pending, ticking, frozen).

### Commit 3 -- `feat(app): move live recording out of Recent clips into a widget under the record button`
- New `Views/LiveRecordingStatusView.swift`: view + self-owned tick timer +
  `LiveRecordingCell` wrapper (wrapper goes live in commit 5).
- `HomeViewController.swift`: insert widget into `headerStack` after
  `recordButtonRow`; replace the separate `recordingObservation` +
  `recorderObservation` with one `store.observe(select: LiveRecordingInputs.from)`
  whose callback renders the record button, recomputes `liveRecordingStatus`,
  and triggers `renderRows`; delete `HomeRow.pending/.live`,
  `HomeRow.liveSegment`, `LiveClipCell` cell-provider branches, selection/swipe/
  prefetch special cases, `previousLive` threading, `liveTickTimer` +
  `updateVisibleLiveElapsed`, `LiveClipCell`. `recPill` and its toggling STAY.
  Migrate test hooks (`liveRecordingWidgetForTesting`,
  `isShowingPendingWidgetForTesting`, `tickWidgetForTesting`, ...).
- `HomeRowDiff.swift#HomeRowID`: drop `.pending`/`.live`.
- `HomeSections.swift#composeSections`: new signature
  `(clips:recordingDrive:today:calendar:)`; forced-Today branch dies (marker wiring
  may land here or in commit 4).
- Tests: `HomeSectionsTests.swift` -- delete
  `liveAndPendingRowsStayStandaloneAboveDriveCards`, `liveRowUsesTodaySection`,
  `pendingRowUsesTodaySection`; update the compose helper signature (~14 structural
  tests survive). `HomeRowDiffTests.swift` -- delete the pending/live identity
  tests. `HomeViewControllerTests.swift` -- retarget the pending/live lifecycle
  tests (`tappingRecordShowsPendingRowImmediatelyWithoutTickTimer`,
  `segmentOpenedReplacesPendingWithLiveRow`, `failedStartRemovesPendingRowSilently`,
  `recorderFailedEventClearsPendingViaProjection`, `heartbeatTimeoutHidesPendingRow`,
  `configurePendingResetsGrayFrozenBadgeToRed`,
  `liveRecordingRowFreezesOfflineAndThawsOnReconnectSnapshot`) at the widget;
  `dayRolloverMovesLiveRowAndRefreshesVisibleHeaders` -> headers-only; placeholder
  test gains the recording-with-zero-clips case. New
  `LiveRecordingStatusViewTests.swift` (badge reset red<->gray, timer starts/stops
  with ticking/window).

### Commit 4 -- `feat(app): mark the recording drive's card with a REC pill`
- `HomeSections.swift`: `DriveGroup.recording: RecordingDrive.Freshness?`;
  `coalescedDriveRows` occurrence-0 marking.
- `HomeViewController.swift`: derive `RecordingDrive.from(status:worldBootTag:)`
  inside the `LiveRecordingInputs` observation callback (the projection from
  commit 3 already carries `worldBootTag`) and pass it to `renderRows`. No
  second observation -- status and drive attribution come from the same value.
- `ClipThumbnailCell.swift`: REC pill + reset paths.
- Tests: `HomeSectionsTests` (marker on newest occurrence only; none on tag
  mismatch/nil), `HomeRowDiffTests` (freshness flip reconfigures stable drive ID),
  `ClipThumbnailCellTests` (pill red/gray/hidden + `prepareForReuse` reset),
  `HomeViewControllerTests` (pill appears while recording, clears on stop, grays
  offline; reconnect snapshot carrying a new boot tag plus active recorder marks
  only the new drive's card -- the old card never renders a REC pill).

### Commit 5 -- `feat(app): show the live recording row atop the recorded drive's detail`
- `DriveDetailViewController.swift`: `DriveDetailRow` identifier enum,
  `LiveRecordingCell` registration + provider branch, the shared
  `LiveRecordingInputs` observation, live-status reconfigure in `render` (per
  (f): `.liveRecording` joins the reconfigure list when the rendered status
  changed), `initialLiveSegment` init parameter, delegate guards, empty-stay
  gate in `handlePostApplyState`.
- `HomeViewController.swift`: the drive-card push passes
  `liveRecordingStatus.liveSegment` as `initialLiveSegment`.
- Tests: `DriveDetailViewControllerTests` -- new `currentDriveShowsLiveRowAtTop`,
  `otherDriveShowsNoLiveRow`, `liveRowFreezesWhenLinkDropsAndThawsOnReconnect`
  (freeze/thaw reconfigures the visible cell in place),
  `pendingRowShowsForCurrentBootBeforeFirstSegment`,
  `pendingToLiveReconfiguresTheStableLiveRow`,
  `segmentRollReconfiguresLiveRowTitleInPlace`,
  `openingCurrentDriveMidSegmentSeedsElapsedFromInitialLiveSegment` (elapsed
  continues from the seed, not 00:00),
  `exhaustedEmptyDriveStaysWhileRecordingIntoIt` (+ pops after stop); existing
  suite gets mechanical updates for the ID enum (helpers already key off clip IDs).

### Commit 6 -- `docs(app): record the live-recording surfaces decision`
- New `app/docs/design/20-2026-07-09-live-recording-surfaces-and-drive-attribution.md`,
  Status: Accepted. Decisions: (1) live/pending presentation is a dedicated widget
  under the record button, not a Recent-clips row; (2) snapshot-level nullable
  `boot_tag` is the "which drive is recording" identity (cross-ref raspi ADR 02
  note + ADR 15 canon); (3) the recording drive's newest card carries a
  freshness-typed REC marker; (4) the recorded drive's detail shows the shared live
  row at top and stays alive while empty-but-recording; (5) all three surfaces
  consume `RecorderTruth` per ADR 18 (red ticking live, gray frozen last-known),
  read together with the boot tag through one equality-gated projection
  (`LiveRecordingInputs`) so recorder status and drive identity can never render
  out of step; (6) the preview REC overlay is retained alongside the widget. Alternatives
  considered: keep rows in-list (rejected: fake Today bucketing + per-second table
  plumbing + identity churn), boot_tag on current_segment (rejected: vanishes
  during pending/idle), pill hidden when offline (rejected: reintroduces the flap
  ADR 18 rejected).
- ADR 19 (`app/docs/design/19-2026-07-08-drive-grouped-clip-browsing.md`) stays
  Accepted; add a dated amendment note under its Status block: amended by ADR 20 --
  live/pending rows no longer render in the Recent list, drive detail additionally
  renders a live row for the currently-recorded boottag, drive cards carry a
  recording marker. ("Superseded by" would be wrong; the core grouping decisions
  stand. ADR 18 needs no edit.)
- `app/AGENTS.md`: ADR 20 index bullet under 19.
- `docs/roadmap.md`: checked sub-item under swoop `sift` (this is drive-browsing
  ownership; fern/pulse bullets are historical and stay): attribute the active
  recording to its drive -- snapshot boot_tag, widget under the record button, REC
  marker on the recording drive's card, live row atop that drive's detail (ADR 20).
- Run `just adr-check`.

## Verification

Automated: `just raspi-test` (incl. `events_match_the_golden_corpus` pinning the
fixture edit), `just app-test` (incl. `CameraEventCorpusTests` from the app side),
`just app-build`, `just adr-check` after commit 6.

Manual simulator + mock walkthrough (`just raspi-mock`, 5 s segments; scheme env
`DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080`):
1. Tap Record: widget appears under the button as "Starting... 00:00" red REC, no
   tick; on `segment_opened` flips to `seg_*.ts` ticking. No live row in the list.
2. First `clip_finalized` (~5-10 s): drive card appears with red REC pill, newest
   card only. Preview recPill also visible (kept).
3. Tap the card mid-segment: detail shows the live row at top, ticking, above
   finished clips, with elapsed continuing from the Home widget's count (not
   00:00); segment rolls reconfigure in place (no row churn).
4. Freeze: `kill -STOP <mock pid>`; after the heartbeat window the widget and
   detail row freeze gray at `~mm:ss`, card pill grays. `kill -CONT` thaws all
   three from the fresh snapshot.
5. Other drive: restart the mock (new UUID -> new boot_tag), record again; the old
   drive's detail shows no live row, old card no pill; new drive's card gets the
   pill after its first clip finalizes.
6. Delete-to-empty: from the current drive's detail, delete all finalized clips
   while recording -- screen stays (live row only); stop recording -- it pops.

## Pitched simplifications folded into this plan

- `composeSections` shrinks to `(clips:recordingDrive:today:calendar:)` -- section
  composition becomes purely clip-date-driven; recording/recorder/previousLive/now
  leave the sections layer entirely.
- The per-second `dataSource.indexPath` tick path dies; the view owns its timer and
  neither screen's diffable data source participates in ticking.
- `HomeRow.triggersPagination` and its guards (`willDisplay`,
  `loadMoreIfVisibleTail`) become constant `true` with `.pending`/`.live` gone --
  delete them; `thumbnailClip` loses its nil-case branch.
- Stable `.liveRecording` identity in drive detail: pending -> live and segment
  rolls are reconfigures, not the remove+insert churn Home's old
  `(session, id)` identity forced every 30-60 s.
- Home's separate `recordingObservation`/`recorderObservation` collapse into the
  one `LiveRecordingInputs` projection both hosts share -- fewer observations,
  and no mid-notification renders mixing fresh recorder state with a stale
  cached boot tag.
- Fixture consistency fix: `snapshot.json` boot_id becomes a real UUID whose
  derived tag matches `clip_finalized.json`, so the corpus exercises the actual
  derivation instead of an underivable placeholder.

## Commit progress

- [x] 1. `feat(contract): expose per-boot boot_tag in the events snapshot`
- [x] 2. `refactor(app): extract LiveRecordingStatus from HomeRow composition`
- [x] 3. `feat(app): move live recording out of Recent clips into a widget under the record button`
- [x] 4. `feat(app): mark the recording drive's card with a REC pill`
- [ ] 5. `feat(app): show the live recording row atop the recorded drive's detail`
- [ ] 6. `docs(app): record the live-recording surfaces decision`

## Implementation notes

- Commit 2 made `RecordingFeature.State` explicitly `nonisolated` and `Sendable` so `LiveRecordingInputs` can stay a nonisolated `Equatable, Sendable` projection under the app target's default main-actor isolation.
