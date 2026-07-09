# Plan: sift -- drive grouping (boottag in /v1/clips + drive cards on Home)

## Context

Day sections landed on Home (first `sift` checkbox). The next `sift` item
(`docs/roadmap.md#Swoop \`sift\``) groups the Recent clips list by **drive**: a
day of driving is 2-4 drive cards instead of hundreds of ~30 s segment rows,
cutting both scrolling and thumbnail prefix pulls over the 2.4 GHz link.

A "drive" is one Pi boot (v1 power is switched/drive-only). The identifier
already exists on disk: every stamped segment filename carries
`(seq, boottag, monoMs)` facts (`raspi/service/src/recorder.rs#SegmentFacts`,
ADR 15). The clip-listing path already parses it
(`raspi/service/src/clips.rs#SegmentCandidate` `.facts`) -- it is just never
serialized. So the wire change is one nullable field; the substance is app-side
composition and a new drive detail screen.

Product decisions (locked with Dan):

1. **Drive cards + detail screen.** Day sections contain one card per drive
   (thumbnail, time span, total duration, clip count). Tapping pushes a drive
   detail screen listing that drive's per-clip rows, which push the existing
   ClipViewer. Cards replace flat per-clip rows for stamped clips.
2. **Live REC/pending row stays standalone** at the top of Today, unchanged;
   the ongoing drive's card sits beneath it and accumulates finalized clips.
   No new snapshot/status contract surface.
3. **Single-clip drives are still a card + detail screen** (uniform behavior).

## Design

### Wire: `boot_tag` on clip metadata

- Add `boot_tag: Option<String>` to `raspi/service/src/clips.rs#ClipMeta`,
  populated in `clips.rs#clip_meta_from_candidate` from `candidate.facts`
  (`None` for bare legacy `seg_<seq>.ts` names).
- The SSE `clip_finalized` event flattens `ClipMeta`
  (`raspi/service/src/events.rs#Event`), so the field rides the event
  automatically. Update the golden corpus fixture
  `contract/events/clip_finalized.json` (both sides round-trip it).
- Mock parity is automatic: `backend.rs#open_mock_segment` already stamps
  `SegmentFacts` and serves through the same `clip_meta_from_candidate` path.
- boottag is an identity/grouping key only (first 12 lowercase hex chars of the
  random kernel boot UUID) -- NOT chronologically sortable. Collisions are
  negligible (worst case two drives render as one card; `time_sync.rs` already
  treats collisions as Ambiguous for offsets).

### App: grouping mechanics

Keep `HomeRow.compose` (flat timeline) untouched. Add a coalesce pass inside
`app/DanCam/DanCam/Features/Home/HomeSections.swift#composeSections`: after day
bucketing, collapse each **consecutive run of `.finished` clips with equal
non-nil `bootTag`** into one `.drive(DriveGroup)` row. `bootTag == nil` clips
stay as plain `.finished` rows in place.

This is exact, not heuristic: segment ids are globally monotonic and per-boot
contiguous, so drives never interleave in the id-descending order from
`ClipsFeature.merged`; and the per-boot time offset is keyed by boottag, so one
drive's clips are uniformly dated or uniformly undated -- a run can only be
split by a day boundary (midnight-spanning drive -> one card per day, accepted;
the detail screen shows the whole boottag) or by an unstamped segment.

- `DriveGroup`: `{ bootTag: String, clips: [Clip] }` (newest-first section-run
  slice), computed accessors for `representative` (= `clips.last`, the
  **oldest** clip), `clipCount`, `totalDurMs`, span dates.
- `totalDurMs` is an **honest aggregate**: nil unless *every* clip has a
  non-nil `durMs`. A finished clip can carry nil `durMs` (the Pi's duration
  cache may not have probed that segment yet -- `clips.rs#ClipMeta.dur_ms` is
  `Option<u64>`), so summing only known values would silently understate the
  drive. Nil -> the card omits duration (below) rather than showing a low
  number; the clip count always shows.
- Representative thumbnail = oldest clip: identity-stable while an ongoing
  drive appends finalized clips (newest-clip identity would churn a network
  thumbnail fetch every segment), and the cover frame matches the card's
  leading start time.
- `HomeRowID.drive(bootTag: String, occurrence: Int)` in
  `Features/Home/HomeRowDiff.swift#HomeRowID`; per-bootTag top-down occurrence
  counter (same pattern as the section occurrence counters) keeps IDs unique
  across midnight/bare-segment splits and stable across prepends/appends.
- No `HomeRowDiff` changes: `DriveGroup` is Equatable over its clips, so any
  clip joining/leaving/etag change/start_ms resolution reconfigures the card.

### App: drive card UI

Reuse `Features/Home/ClipThumbnailCell.swift` with a
`configure(drive:loader:preservedThumbnail:)` overload (same
`ThumbnailDisplayState`/load-token machinery; disclosure indicator for drives,
reset to `.none` on the clip path -- both paths share a reuse identifier, so
each must fully reset title/subtitle/accessory).

- Title: `"14:02 - 15:37"` (HH:mm span, ASCII hyphen); `"Drive"` when undated.
- Subtitle: `"1h 21m · 163 clips"` (`·` matches existing UI literals);
  duration omitted when unknown; `"1 clip"` singular.
- New formatters in `Support/Formatters.swift`: `timeOfDayShort` ("HH:mm",
  en_US_POSIX like siblings), `timeSpan(start:end:timeZone:)`,
  `compactDuration(_ durMs:)` ("58s" / "42m" / "1h" / "1h 21m"),
  `clipCount(_:)`, plus `driveCardTitle`/`driveCardSubtitle` composing them.

### App: drive detail screen

A drive is a *view* over `ClipsFeature.State` -- no new reducer, matching the
root-store/scoped-observation architecture (app ADRs 06/17). New
`Features/DriveDetail/`:

- `DriveDetailState.swift` (pure, unit-testable):
  `init(allClips:nextCursor:bootTag:)` -> `clips` (id-descending, filtered to
  bootTag) + `canLoadMore`. A bare segment (`nil` bootTag) is real live state
  that can land mid-run (rename failed inside this boot; ADR 15), so a target
  drive's clips can be split by a `nil` clip in the id-descending stream.
  Termination must therefore page *through* trailing `nil` gaps, not stop at
  them: `canLoadMore == nextCursor != nil && (allClips.last?.bootTag == bootTag
  || allClips.last?.bootTag == nil)`. The drive is proven complete -- and
  paging stops -- only once the globally-oldest loaded clip carries a **different
  non-nil** bootTag; a bare tail stays indeterminate, so we keep paging (worst
  case over-paging to `nextCursor == nil`, never hiding an older stamped clip
  of this drive).
- The observed projection must also carry a **pagination frontier** field --
  `paginationFrontier = allClips.last?.id` (the global oldest-loaded clip id) --
  participating in `DriveDetailState`'s `Equatable`. Rationale:
  `Store.observe(select:)` dedupes on `Value` equality
  (`Store.swift`: `if let last, last == value { return }`), so a page that adds
  only `nil`-bootTag clips leaves both `clips` and `canLoadMore` unchanged and
  would suppress the observer entirely -- no render, so the post-apply
  loadMore re-check below never runs and pagination re-stalls on the exact
  nil-gap case. Because such a page advances `allClips.last?.id`, folding the
  frontier into the projection guarantees the observer (and its re-check)
  fires on every page that moves the frontier, even when the visible rows are
  unchanged. The frontier drives no UI directly.
- `DriveDetailViewController.swift`: `init(dependencies:store:bootTag:)` (pass
  the boottag identity, not a stale `DriveGroup` snapshot). Observes the store
  via a selector building `DriveDetailState`. Plain table + diffable data
  source keyed by clip id, single section (no day headers), newest-first,
  `ClipThumbnailCell.configure(clip:loader:)` rows, per-clip prefetch
  mirroring Home.
- Tap -> `ClipViewerViewController(dependencies:store:clip:)`. Swipe-to-delete
  -> same confirm -> `.clips(.deleteTapped(clip))`; extract the alert
  currently inlined in
  `HomeViewController#trailingSwipeActionsConfigurationForRowAt` into a shared
  factory (`Views/ClipDeleteConfirmation.swift`) used by both.
- Pagination: when `canLoadMore` and a tail row displays (plus a post-apply
  visibility re-check), send `.clips(.loadMore))` -- reducer guards absorb
  duplicates.
- Drive becomes empty (deletes here, in the viewer, or `clip_removed` events):
  remove the controller from the nav stack (pop if topmost, else splice out of
  `navigationController.viewControllers`) **only once the drive is proven
  exhausted** -- `clips.isEmpty && canLoadMore == false`. If `clips.isEmpty` but
  `canLoadMore` is still true (the loaded page drained while older same-boot
  clips may sit behind nil gaps or on later pages), do NOT remove: keep the
  detail alive and issue `.clips(.loadMore)` instead. Each page advances the
  frontier and re-evaluates, so the screen repopulates if an older clip
  surfaces and removes itself only when paging proves the drive truly empty.
- Title: full-drive time span from the filtered clips, refreshed per state
  change; `"Drive"` when undated. Never shows live/pending rows.

### App: Home pagination + prefetch

- `HomeViewController#willDisplay` currently gates the loadMore trigger on
  `case .finished`; include `.drive` rows.
- New stall mode: a whole page can be absorbed into the *existing* bottom drive
  card (reconfigure, zero new rows), so `willDisplay` never re-fires. Fix with
  a post-apply re-check in the `renderRows` snapshot-apply completion: if a
  pagination-tail row is visible and `nextCursor != nil` (new
  `\.clips.nextCursor` observation), send `.clips(.loadMore)`.
- Prefetch only the representative clip's thumbnail for drive cards: rename
  `HomeRow.finishedIdentity` to `thumbnailIdentity` and add `thumbnailClip`
  (`.finished` -> clip, `.drive` -> representative); route prefetch/cancel/
  prune/preserved-thumbnail paths through them. Per-clip thumbnails inside a
  drive load when the detail screen opens -- the right cost model for the link.
- No "card still growing" affordance this pass; aggregates settle quietly via
  flicker-free reconfigure (stable oldest-clip thumbnail identity).

### Scope fences

- No drive-card swipe-to-delete (bulk drive delete is N sequential per-clip
  mutations needing progress/partial-failure UX -- its own feature; deletion
  stays per-clip in detail + viewer). Home returns nil swipe config for
  `.drive` rows.
- No calendar jump / locked filter (later `sift` items), no Pi-side drive
  aggregation endpoint, no snapshot/status contract change.

## Commits

### 1. `feat(raspi): expose boot_tag in /v1/clips and clip_finalized`

- `clips.rs#ClipMeta`: add `pub boot_tag: Option<String>`;
  `clips.rs#clip_meta_from_candidate`: populate from `candidate.facts`.
- Update `ClipMeta` literals: `events.rs` canonical corpus constructor
  (`boot_tag: Some("7f3a91c2b0d4".into())`) and the `world.rs` test `fn clip`
  helper (`boot_tag: None`).
- `contract/events/clip_finalized.json`: add `"boot_tag": "7f3a91c2b0d4"`
  (non-null so both golden corpora exercise string decode; null covered by
  unit tests).
- ADR 02 (`raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md`,
  Clips section): append a dated note after the 2026-07-01 note: `sift` adds
  nullable `boot_tag` (segment boottag per ADR 15; identity/grouping key,
  "one drive = one boot", not sortable; null for bare names; flattened
  `clip_finalized` carries it too).
- Tests: extend `read_finished_clips_derives_start_ms_from_facts_and_offset`
  to assert the tag; new unit test stamped-vs-bare -> `Some`/`None`;
  integration `raspi/service/tests/clips.rs` asserts `boot_tag` null in the
  bare-fixture test and the exact string in the stamped/time-synced test.
- Safe sequencing: the fixture change does not break the Swift corpus test
  before commit 2 (Codable ignores unknown keys; only unknown event *types*
  fail).

### 2. `feat(app): decode clip boot_tag`

- `Networking/ClipsResponse.swift#Clip`: add a trailing `var bootTag: String?
  = nil` (`.convertFromSnakeCase` auto-maps; no CodingKeys). The explicit
  `= nil` default is load-bearing: a bare optional would drop out of the
  synthesized memberwise initializer and break every direct `Clip(...)` literal
  in the suite (e.g. `HomeViewControllerTests.swift`, `ThumbnailLoaderTests`,
  `CameraEventCorpusTests`), not just `CameraSamples.clip`. With the default,
  those call sites stay source-compatible.
- `DanCamTests/Support/CameraSamples.swift#clip`: add `bootTag: String? = nil`
  parameter.
- `CameraEventCorpusTests` expected finalized `Clip` gains
  `bootTag: "7f3a91c2b0d4"`.
- Tests: `ClipsClientTests` raw snake_case decode with and without the key.

### 3. `feat(app): drive time-span and duration formatters`

- `Support/Formatters.swift`: `timeOfDayShort`, `timeSpan`, `compactDuration`,
  `clipCount`, `driveCardTitle`/`driveCardSubtitle` (over span/duration/count
  values so commit 4 can use them for the detail title before `DriveGroup`
  exists).
- Tests in `FormattersTests`: span incl. cross-midnight text, compactDuration
  boundaries (59s/60s/3600s/4860s), singular/plural clipCount, undated
  fallbacks.

### 4. `feat(app): drive detail screen for a boottag's clips`

- New `Features/DriveDetail/DriveDetailState.swift` +
  `DriveDetailViewController.swift` as designed above.
- New `Views/ClipDeleteConfirmation.swift`; adopt in `HomeViewController`
  (behavior-neutral refactor folded here).
- Not yet reachable from Home (wired in commit 5; note in commit body).
- Tests: `DriveDetailStateTests` (filtering/order; canLoadMore flip; **bare-gap
  paging**: a target-bare-target id sequence keeps both target clips, and
  canLoadMore stays true while the oldest loaded clip is `nil`/target and flips
  false only when an older different non-nil bootTag loads);
  `DriveDetailViewControllerTests` patterned on `HomeViewControllerTests`
  (renders only its drive; tap pushes viewer; swipe confirm sends
  deleteTapped; tail willDisplay sends loadMore only when canLoadMore;
  **nil-only page re-check**: with a visible tail, a merged page that adds only
  `nil`-bootTag clips (no new visible rows, `canLoadMore` still true) still
  advances the frontier and immediately issues the next `loadMore` -- proving
  the projection is not deduped away; **empty but not exhausted**: draining the
  loaded clips while `canLoadMore` is still true keeps the controller in the
  stack and issues `.clips(.loadMore)` rather than removing it; empty
  state removes the controller from the nav stack only once exhausted
  (`clips.isEmpty && canLoadMore == false`) -- covering both topmost
  (pop) and **non-topmost (splice out of `viewControllers` with another
  controller pushed above it)** so an emptied detail never lingers in the back
  stack; merged `clipFinalized` clip for the bootTag appears as new top row).

### 5. `feat(app): group Home clips into per-drive cards`

- `HomeSections.swift`: `DriveGroup` + coalesce pass with per-bootTag
  occurrence counters.
- `HomeRowDiff.swift#HomeRowID`: add `.drive(bootTag:occurrence:)`.
- `HomeViewController.swift#HomeRow`: add `.drive(DriveGroup)` case, `id`
  mapping, `thumbnailIdentity`/`thumbnailClip` (replacing `finishedIdentity`).
- `ClipThumbnailCell.swift`: drive configure overload.
- `HomeViewController`: cell provider `.drive` branch; `didSelectRowAt`
  pushes `DriveDetailViewController`; nil swipe config for `.drive`;
  `willDisplay` includes `.drive`; `\.clips.nextCursor` observation +
  post-apply loadMore re-check in the `renderRows` completion; prefetch/
  preserved-thumbnail paths via `thumbnailClip`.
- Tests: `HomeSectionsTests` (run collapses to one card with asserted ID +
  clip order; single stamped clip is a card; bare clips stay flat in place
  between cards; adjacent different bootTags -> two cards; midnight-spanning
  drive -> occurrence 0/1 across two day sections; undated stamped drive ->
  one card in `.dateUnknown`; live/pending stay standalone above the top
  card; occurrence stability across prepend/append; **mixed-duration
  aggregate**: a drive whose clips mix known and nil `durMs` yields
  `totalDurMs == nil` and a card subtitle that omits duration while still
  showing the clip count -- never an understated sum). `HomeRowDiffTests`
  (joined clip / changed etag reconfigures same drive ID).
  `ClipThumbnailCellTests` (reuse reset for the shared identifier: configure
  one cell drive -> clip and clip -> drive, asserting accessory/disclosure,
  title, subtitle, and accessibility label fully swap with no state leaked
  either direction). `HomeViewControllerTests` (card tap pushes detail; drive swipe yields no
  actions; tail `.drive` row triggers pagination; stall test: a page response
  absorbed entirely by the bottom card still issues the next fetch while the
  tail is visible; **representative-thumbnail regression**: a multi-clip drive
  requests/prefetches exactly one card thumbnail identity -- the oldest
  representative, not the newest -- and prepending a same-boot finalized clip
  requests no new card thumbnail identity, pinning both the oldest-clip choice
  and prefetch-only-representative against a newest-clip or churning
  implementation; extend `HomeLoaderProbe` to record requested prefetch
  identities, not just cancels).

### 6. `docs: record drive-grouped clip browsing`

- New app ADR `app/docs/design/19-2026-07-08-drive-grouped-clip-browsing.md`
  (Status: Accepted). One decision: the drive (boottag) is the browse unit for
  finished clips -- cards within day sections composed app-side from the flat
  listing; detail observes root clips state (no new reducer); oldest-clip
  representative thumbnail; pagination-edge semantics; per-clip-only deletion.
  Alternatives: flat rows with drive headers; Pi-side grouping endpoint;
  newest-clip thumbnail. Add to the ADR list in `app/AGENTS.md`.
- `docs/roadmap.md`: check the `sift` drive-grouping box.

## Verification

- Per-commit gates: `just raspi-test` + `just raspi-check` (1); `just
  app-test` + `just app-build` (2-5; `just app-lint` sweep on 4-5); `just
  adr-check` (6).
- Manual mock loop: `just raspi-mock` + simulator app pointed at
  `http://127.0.0.1:8080`. Verify: record -> REC row atop Today with the
  drive card beneath accumulating a clip every ~5 s (count/duration/span tick,
  thumbnail stable); tap card -> detail rows -> viewer plays; delete a clip in
  detail (Home count drops); delete the last clip -> detail pops, card gone;
  restart mock (new boottag) + record -> second card; `just raspi-mock-clips`
  bare sample `.ts` renders as a plain flat row, not a card. Time-unverified:
  before time sync the stamped drive groups under "Date unknown" titled
  "Drive", then migrates into a day section after `time_synced` reload.

## Risks / edge cases

- **Undated stamped drives**: whole drive in "Date unknown" (uniform per-boot
  offset), title "Drive"; after sync the card moves day sections under the
  same row ID -> diffable move + reconfigure, no thumbnail flash (identity
  unchanged).
- **Bare legacy segments**: flat rows; shared reuse identifier means both
  configure paths fully reset title/subtitle/accessory.
- **Midnight spanning**: two cards (occurrence keeps IDs unique), one detail
  screen showing the whole drive.
- **Deletion**: deleting the oldest clip swaps the representative ->
  reconfigure reloads thumbnail (correct); failed delete restores via existing
  `deleteResponse(.failure)` merge -> card regrows.
- **clip_finalized**: carries `boot_tag` end-to-end, so the ongoing drive's
  card absorbs each finalize as a reconfigure without touching the
  representative.
- **Pagination stall** (page absorbed by bottom card, zero new rows): fixed by
  the post-apply re-check; explicitly tested.
- **Corpus round-trip**: fixture must satisfy Rust Value-equality + decode
  equality + Swift expected Clip -- updated across commits 1-2; safe in
  between because Swift ignores unknown keys.

## Commit progress

- [x] 1. feat(raspi): expose boot_tag in /v1/clips and clip_finalized
- [x] 2. feat(app): decode clip boot_tag
- [x] 3. feat(app): drive time-span and duration formatters
- [x] 4. feat(app): drive detail screen for a boottag's clips
- [ ] 5. feat(app): group Home clips into per-drive cards
- [ ] 6. docs: record drive-grouped clip browsing
