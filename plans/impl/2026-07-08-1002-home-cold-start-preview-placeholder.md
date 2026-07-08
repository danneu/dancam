# Plan: Fix Home cold-start / connecting UI (empty state + preview placeholder)

## Context

The Home screen looks broken while the app is connecting or offline, and the
worst parts persist even once connected:

1. **"No clips yet" renders above the "Recent clips" header**, overlapping the
   disabled Record button. This happens in every state (confirmed both
   disconnected and connected -- see the two screenshots in the request), because
   the empty view is the table's `backgroundView`, which is independent of
   connection.
2. **The 4:3 preview box is flat black** during idle / connecting / stopped /
   failed -- harsh in light mode, an invisible void in dark mode. It carries no
   affordance about what state the preview is in beyond a small corner pill.

Root causes:

- The empty view is installed as `clipsTableView.backgroundView` in
  `HomeViewController#updateClipsPresentation`. A table's `backgroundView` fills
  the *entire* table bounds *behind* the tall `tableHeaderView` (preview + record
  button + "Recent clips" label), and its content is pinned to the full-height
  `centerY` (`HomeViewController#configureClipsTable`). The geometric center of
  the whole table lands up in the header region, so the label floats above
  "Recent clips."
- `ClipsFeature.State.Status` is `idle | loading | failed` only. Initial state and
  "loaded, zero clips" are *both* exactly `status == .idle && clips.isEmpty`, so
  "No clips yet" is asserted during the very first load and before any load has
  even been dispatched -- a claim the app cannot back yet.
- The preview is black because of two hardcoded `.black` layers
  (`PreviewViewController#configureViews` on `imageView`, and
  `HomeViewController#configurePreview` on the container) plus `imageView.image`
  is never cleared when leaving `.streaming`. `render(_:)` only updates the
  `statusPill`, never the box's fill.

Intended outcome: the clips empty/loading state sits correctly *below* "Recent
clips" and tells the truth (spinner on first load, "No clips yet" only after a
load confirms zero, nothing when never connected); the preview box is an adaptive
placeholder that reads well in light and dark and reflects the preview phase,
with black reserved for the streaming letterbox.

Scope chosen: **fix both bugs correctly** (not the minimal patch, not the larger
unified "connect your camera" hero redesign). No backwards-compat concerns --
delete and replace freely per the repo stance.

## Part A -- clips empty / loading state

### A1. Add a "loaded once" latch to the clips feature

`app/DanCam/DanCam/Features/Clips/ClipsFeature.swift`

- Add `var hasLoadedOnce = false` to `ClipsFeature.State`.
- Set `state.hasLoadedOnce = true` in the head-success case
  (`.clipsResponse(_, .success)`, where `state.status = .idle` is set today).
- Do **not** reset it anywhere -- monotonic per session. Rationale: a `.loaded`
  enum case would be non-monotonic (a refresh flips it back to `.loading`), so it
  cannot answer "has the list ever been populated." A boolean latch is the
  correct primitive and leaves the existing `Status` cases untouched.

`headEpoch` is not a substitute: it increments when a load *starts*, not when one
*succeeds*, so it is true during the first in-flight load.

### A2. Relocate the placeholder out of `backgroundView` and into the header

`app/DanCam/DanCam/Features/Home/HomeViewController.swift`

- Stop assigning `clipsTableView.backgroundView`. Delete `emptyClipsBackgroundView`
  and its centerX/centerY constraints in `configureClipsTable`.
- Build a single **body-placeholder container** and add it as an arranged subview
  of `headerStack` *after* `clipsHeaderLabel` (headerStack is the vertical stack
  inside the `tableHeaderView`, currently `[preview, recordButtonRow,
  statusPillsStack, clipsHeaderLabel]`). The container holds:
  - a `UIActivityIndicatorView(style: .medium)` (first-load spinner), and
  - the existing glyph+label stack (`emptyClipsView`: `film` SF Symbol tinted
    `.secondaryLabel` + "No clips yet" label). Reuse it as-is; just reparent it.
  - Give the container a little top spacing so it does not hug the header label
    (headerStack spacing is 12; add internal top margin if it reads cramped).
- A hidden arranged subview collapses in a `UIStackView` (zero height, no spacing),
  so when clips exist the header is exactly as it is today. On any visibility
  change, set `needsHeaderRefit = true; view.setNeedsLayout()` -- the exact
  pattern `renderStatusPills` already uses -- so `sizeHeaderToFit`
  (`systemLayoutSizeFitting`) re-fits the header height. `systemLayoutSizeFitting`
  already accounts for arranged subviews, so this composes with the existing
  `estimatedRowHeight`/`automaticDimension` table without special handling.

### A3. Rewrite `updateClipsPresentation()`

Decision table (`rows` = live + finished rows; the placeholder only ever shows
when `rows.isEmpty`):

| Condition | Failure banner | Body placeholder |
|---|---|---|
| `status == .failed(msg)` | shown | hidden (failure suppresses empty -- preserved) |
| rows non-empty | hidden | hidden |
| rows empty, `.loading && !hasLoadedOnce` | hidden | **spinner** (first load) |
| rows empty, `hasLoadedOnce` | hidden | **"No clips yet"** |
| rows empty, `.idle && !hasLoadedOnce` | hidden | hidden (never connected/loaded -- honest) |

Refresh interaction (validated): pull-to-refresh from a loaded-empty list sets
`status = .loading` while `hasLoadedOnce == true`. The `hasLoadedOnce` branch is
evaluated before the first-load-spinner branch is reachable, so we keep showing
"No clips yet" during the refresh while `refreshControl` spins at the top -- no
disruptive body-spinner flash. `handleClipsStatus`'s spinner-teardown logic
(keyed on `.idle`/`.failed`) is unaffected; no new `Status` case means that
switch does not change.

### A4. Wire the new signal and testing hooks

- Observe `\.clips.hasLoadedOnce` (new `StoreObservation`, mirroring the existing
  clips observations in `viewDidLoad`) storing it locally and calling
  `updateClipsPresentation`. `updateClipsPresentation` is already called from
  `renderRows` and `handleClipsStatus`, so it stays the single decision point.
- `isShowingEmptyStateForTesting`: change from "backgroundView != nil" to track
  the **"No clips yet" label** visibility specifically.
- Add `isShowingLoadingStateForTesting` for the spinner visibility.

## Part B -- preview placeholder

`app/DanCam/DanCam/Features/Preview/PreviewViewController.swift`

- Add a `placeholderView` subview inserted **above `imageView` but below
  `statusPill`** (order in `configureViews`: imageView, placeholderView,
  statusPill). It is edge-to-edge, opaque, `backgroundColor =
  .secondarySystemBackground` (adaptive: soft light-gray card in light, near-black
  card in dark). It contains, centered:
  - a `UIImageView` glyph tinted `.secondaryLabel`, and
  - a `UIActivityIndicatorView(style: .medium)`.
- `recPill` is added to the container by `HomeViewController#configurePreview`
  *after* the child loads, so it stays on top of the placeholder -- no change
  needed there.
- Rewrite `render(_:)` to also drive the placeholder and clear stale frames:

| phase | placeholder | glyph | spinner | pill (unchanged) | imageView.image |
|---|---|---|---|---|---|
| `.streaming(frame)` | hidden | -- | -- | "Live" | painted |
| `.connecting` | shown | hidden | animating | "Connecting" | set `nil` |
| `.failed` | shown | `video.slash` | hidden | "Preview offline" | set `nil` |
| `.idle` | shown | `video.slash` | hidden | hidden | set `nil` |
| `.stopped` | shown | `video.slash` | hidden | hidden | set `nil` |

- On entering any non-streaming phase, **invalidate the decode pipeline and then
  clear the image**, in that order:
  - Add `PreviewDecodeState.invalidate()` (bump `generation`, clear `pendingDecode`,
    reset `latestRenderedSequence` -- the same reset `beginNewStream` already does;
    have `beginNewStream` call `invalidate()` so there is one code path). Call it from
    `render(_:)` for `.idle` / `.connecting` / `.stopped` / `.failed`.
  - Then set `imageView.image = nil`.
  This is load-bearing, not belt-and-suspenders: a decode `Task.detached` started
  while streaming (generation N) can finish *after* the transition to
  `.stopped` / `.failed`. Today `finishDecode` would still repaint, because the
  decode generation only advances on `streamGeneration` (a *new* stream), not on
  stop/fail -- so a stale frame would be re-set behind the placeholder and its
  decoded `UIImage` retained. Bumping the generation on `invalidate()` makes that
  late `finishDecode` fail its `decodeGeneration == generation` check and return
  `false`, so it neither repaints nor retains.
- Keep `imageView.backgroundColor = .black`: it is the streaming **letterbox**
  color and is only visible while streaming. If MJPEG frames are not exactly 4:3,
  `.scaleAspectFit` leaves black bars -- conventional for video and acceptable; the
  placeholder must not show during `.streaming`.
- Remove the now-pointless `.black` container override in
  `HomeViewController#configurePreview` (keep its `cornerRadius` / `cornerCurve` /
  `masksToBounds`). The container fill is never visible (imageView or placeholder
  always covers it); dropping the override avoids a misleading second black layer.
- Add internal testing hooks that expose the *rendered presentation* (not the view
  tree), so phase->presentation is testable without poking the hierarchy or plumbing
  a live `PreviewClient`:
  - `placeholderStateForTesting` -- enum `.hidden` / `.spinner` / `.glyph`.
  - `statusCaptionForTesting` -- the pill caption, or `nil` when the pill is hidden.
  - `displayedImageForTesting` -- `imageView.image` (to assert the off-stream clear).
  - `seedDisplayedImageForTesting(_ image: UIImage)` -- assigns `imageView.image`
    directly, bypassing the async decode path, so the off-stream-clear test can start
    from a known non-nil frame. Load-bearing for that test: `.streaming` paints on a
    detached decode `Task`, so driving `.streaming` through `applyForTesting(_:)`
    leaves `imageView.image` nil synchronously. Without seeding, `displayedImageForTesting
    == nil` after `.stopped` / `.failed` would pass vacuously and a reverted
    `imageView.image = nil` clear would not fail the test.
  - `applyForTesting(_ state: PreviewFeature.State)` -- invokes the private
    `render(_:)` directly so a test drives `.idle` / `.connecting` / `.streaming` /
    `.stopped` / `.failed` deterministically and synchronously. `PreviewViewController`
    builds its own `Store` internally and `store` stays private; this shim is the
    seam. Async frame *painting* is out of scope for VC tests (it runs on a detached
    decode `Task`) -- the decode/paint gate is covered by `PreviewDecodeStateTests`.

## Files to modify

- `app/DanCam/DanCam/Features/Clips/ClipsFeature.swift` -- add `hasLoadedOnce`
  field + set it on head success.
- `app/DanCam/DanCam/Features/Home/HomeViewController.swift` -- relocate
  placeholder into `headerStack`, rewrite `updateClipsPresentation`, add
  observation + testing hooks, drop preview `.black` container override.
- `app/DanCam/DanCam/Features/Preview/PreviewViewController.swift` -- add
  `placeholderView`, rewrite `render(_:)`, add `PreviewDecodeState.invalidate()` and
  call it (then clear `imageView.image`) on every non-streaming phase, add the
  testing hooks + `applyForTesting(_:)` shim.

## Test updates

Structure-insensitive, behavioral tests -- keep and update to the corrected
behavior:

- `ClipsFeatureTests` -- head-success transitions assert `$0.status = .idle`; add
  `$0.hasLoadedOnce = true` to the same expected-state mutation in the success-path
  tests (`loadFetchesClipsOnce`, `staleLoadResponseKeepsClipFinalizedDuringThatRequest`,
  the head-reconciliation success tests, and `emptyHeadPrunesEverythingInAuthoritativeWindow`).
  Failure-path tests (`failureKeepsExistingClips`, delete-failure tests) are
  unaffected. Add one assertion that a `.load` (status `.loading`) does **not** set
  `hasLoadedOnce` -- locks the "first-load spinner, not empty" guarantee at the
  feature level.
- `AppFeatureTests` -- the ~18 connection-flow assertions of `$0.clips.status =
  .idle` on success need `$0.clips.hasLoadedOnce = true` alongside. `.loading`
  assertions are unchanged.
- `HomeViewControllerTests.clipsFailurePresentationIsVisibleAndSuppressesEmptyState`
  -- the assertion that a fresh, never-loaded controller with `clips: []` shows the
  empty state (`#expect(emptyController.isShowingEmptyStateForTesting)`) must flip
  to `== false` (never-loaded now shows nothing, not "No clips yet"). Add, after the
  existing empty-success response earlier in the same test, an assertion that
  `isShowingEmptyStateForTesting == true` once `hasLoadedOnce` is set by that
  success -- new coverage proving "No clips yet" appears only after a confirmed
  empty load.

New tests to add (behavioral, structure-insensitive):

- `PreviewDecodeStateTests` -- **regression for the late-decode repaint**: after
  `invalidate()`, `finishDecode(generation: oldGeneration, sequence:
  higherThanRendered)` returns `false` (the would-be paint is rejected). Pure,
  synchronous, structure-insensitive; this is the primary guard that a stale frame
  cannot repaint after leaving streaming.
- `HomeViewControllerTests` -- a loading / empty / refresh test, using a
  **parked/gated `ClipsClient`** (reuse the existing `parkedClipsClient()` helper) so
  fetches stay in flight and status holds at `.loading` deterministically --
  `ClipsClient.noop` returns an empty success and the `Store` runs effects on a
  `Task`, so a real client would race the load to `.idle` before the assertion.
  Manual epoch-matched sends mirror `clipsFailurePresentationIsVisibleAndSuppressesEmptyState`.
  Sequence:
  1. `.clips(.load)` (parked; `headEpoch` 0 -> 1) -> assert
     `isShowingLoadingStateForTesting == true && isShowingEmptyStateForTesting ==
     false` (first-load spinner).
  2. `.clips(.clipsResponse(epoch: 1, .success(empty)))` -> assert the flip to "No
     clips yet" (`isShowingEmptyStateForTesting == true`, loading false).
  3. `.clips(.refresh)` (parked; `headEpoch` 1 -> 2, stays in flight;
     `pullToRefreshForTesting()` is an alternative but also pokes the preview
     reconnect, so `.clips(.refresh)` isolates the branch) -> assert
     `isShowingEmptyStateForTesting == true && isShowingLoadingStateForTesting ==
     false` -- **the loaded-empty refresh branch**: "No clips yet" holds while `status
     == .loading && hasLoadedOnce == true` (the top `refreshControl` spins, the body
     does not). This locks the branch order against a regression that would flash the
     body spinner during an empty-list refresh.
  4. `.clips(.clipsResponse(epoch: 2, .success([clipA])))` -> assert both false (rows
     non-empty).
  5. Teardown: `.clips(.onDisappear)` cancels the in-flight fetch.
- `PreviewViewControllerTests` (none exists today) -- drive each phase via
  `applyForTesting(_:)` and assert `placeholderStateForTesting`,
  `statusCaptionForTesting`, and `displayedImageForTesting` per the Part B table:
  streaming hides the placeholder; connecting -> spinner + "Connecting"; failed ->
  glyph + "Preview offline"; idle/stopped -> glyph + no caption. Include a transition
  case: `seedDisplayedImageForTesting(<a non-nil UIImage>)` first, then render `.stopped`
  / `.failed`, and assert `displayedImageForTesting == nil` -- the off-stream clear.
  Seeding is what gives the assertion teeth: from a nil start the clear is a no-op, so
  a reverted `imageView.image = nil` would still pass.

Not touched: `HomeStatusPillsTests`, `ThumbnailDisplayStateTests`.

## Verification

1. `just app-build` and `just app-lint` -- clean build, no new warnings.
2. `just app-test` -- full Swift Testing suite green (updated + new tests above).
3. Manual, in the simulator, against the mock Pi (`just raspi-mock`, with the scheme's
   `DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080` per `app/AGENTS.md`; use
   `just raspi-mock-clips` to get a finished clip for the has-clips row states), plus a
   disconnected run. `just raspi-mock-lan` (`[::]:9000`) is for physical LAN-device
   runs, not the simulator:
   - **Cold start, disconnected:** preview box is an adaptive card (not black) with
     a `video.slash` glyph; light and dark both look intentional (toggle
     appearance in the simulator). Below "Recent clips" there is nothing (no false
     "No clips yet", no infinite spinner), and nothing floats above the header.
   - **Connecting:** preview shows the spinner + "Connecting" pill; the clips body
     shows the first-load spinner under "Recent clips" (once a load is dispatched).
   - **Connected, camera has zero clips:** after the load resolves, "No clips yet"
     appears *below* "Recent clips" and never overlaps the Record button.
   - **Connected, streaming:** live frames paint, "Live" pill, placeholder gone,
     any letterbox bars are black.
   - **Pull-to-refresh on an empty list:** "No clips yet" stays put while the top
     refresh spinner runs (no body-spinner flash).
   - **Failure:** failure banner shows, empty/loading placeholder is suppressed.
   - `just app-logs` if any state transition needs tracing.
