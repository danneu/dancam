# Detached-aware snapshot apply (fix off-window UITableView layout warnings)

## Context

Pushing into RecordingDetail spews Xcode console errors: "UITableView was told to
layout its visible cells ... without being in the view hierarchy" followed by repeated
unsatisfiable-constraint dumps (`'fittingSizeHTarget' UITableViewCellContentView.width
== 0` vs the required 80pt `thumbnailView.widthAnchor` in ClipThumbnailCell).

Root cause: `Store.observe` (app/DanCam/DanCam/Architecture/Store.swift#func observe)
delivers current state synchronously at registration. RecordingDetailViewController and
HomeViewController register observations in `viewDidLoad`, so
`UITableViewDiffableDataSource.apply(_:animatingDifferences:false)` runs before the
view is in a window. Even non-animated, `apply` diffs via batch updates and forces the
table to lay out at frame (0,0,0,0), so self-sizing cells measure at contentView width
0 and Auto Layout breaks constraints. The same exposure recurs whenever state changes
while the screen is covered (a pushed-over view leaves the window). Both VCs already
have a `canAnimateTableUpdates` window check, but it only picks the animation flag --
the apply itself is unconditional. DebugViewController shares the shape with a
collection view.

Harmless in the UI (everything re-lays-out at real width on attach) but noisy and
wasted double layout.

## Decision

When the target view is not in a window, route the snapshot through
`applySnapshotUsingReloadData(_:completion:)` instead of `apply(_:animatingDifferences:)`.
The reloadData path does not diff or force layout -- it marks the view dirty and cell
creation/self-sizing happens lazily at the next real layout pass, after attach. The
data source contents stay synchronously correct and the completion still runs, so
`handlePostApplyState()` (pop-on-empty, loadMore chaining) keeps its timing and every
existing window-less `loadViewIfNeeded()` test passes untouched. When detached there
are no visible cells, so diffing preserved nothing anyway.

This supersedes the defer-and-flush-in-`viewIsAppearing` idea discussed earlier: that
approach would defer pop-on-empty while covered, require coalescing RecordingDetail's
two apply sites, and break the many window-less synchronous tests. Detached-aware
apply strictly dominates -- simpler, no lifecycle flag, no behavior change.

Notes settled during design:
- `reconfigureItems` embedded in snapshots is harmlessly subsumed by reloadData;
  `makeSnapshot(reconfigure:)` and Home's `renderRows` stay unchanged.
- No thumbnail-flash mitigation needed: while detached, `visibleThumbnailImages()`
  returns `[:]` anyway, and ThumbnailLoader
  (app/DanCam/DanCam/Media/ThumbnailLoader.swift) has memory + disk cache tiers;
  `viewWillAppear -> reconfigureVisibleThumbnails()` already retries.
- Deployment target is iOS 26.5; `applySnapshotUsingReloadData` needs iOS 15. Fine.
- ClipThumbnailCell's 80pt width constraint stays at required priority -- with the
  gate, nothing measures at width 0 anymore.

## Implementation

1. **New file `app/DanCam/DanCam/Support/DiffableDataSourceDetachedApply.swift`**
   (Support/ is the misc-helper home, cf. Formatters.swift; project uses
   file-system-synchronized groups, so no pbxproj edit). Two overloads -- the data
   source does not expose its view, so it is passed in:

       extension UITableViewDiffableDataSource {
           func applyDetachedAware(
               _ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>,
               tableView: UITableView,
               animatedWhenAttached: Bool = true,
               completion: (() -> Void)? = nil
           ) {
               if tableView.window != nil {
                   apply(snapshot, animatingDifferences: animatedWhenAttached, completion: completion)
               } else {
                   applySnapshotUsingReloadData(snapshot, completion: completion)
               }
           }
       }

   plus the `UICollectionViewDiffableDataSource` twin taking `collectionView:`.
   `tableView.window != nil` subsumes the old `canAnimateTableUpdates` check, so
   attached applies animate exactly when they do today (first render in viewDidLoad is
   detached -> reloadData -> non-animated, as before).

   Write helper contract test 2 (below) first and confirm the detached branch's
   completion is synchronous before wiring the VCs. The body above is correct only if
   it is; if the test shows otherwise, adopt its fallback (call `completion?()`
   directly after `applySnapshotUsingReloadData(snapshot)` in the detached branch). The
   controllers depend on synchronous completion for pop-on-empty and pagination
   bookkeeping, so this is a prerequisite, not a post-hoc check.

2. **RecordingDetailViewController**
   (app/DanCam/DanCam/Features/RecordingDetail/RecordingDetailViewController.swift):
   in `render(_:)` and `renderLiveRecording(_:now:)`, replace
   `dataSource.apply(..., animatingDifferences: canAnimateTableUpdates, completion:)`
   with `dataSource.applyDetachedAware(..., tableView: tableView, completion:)`.
   Delete `canAnimateTableUpdates`.

3. **HomeViewController**
   (app/DanCam/DanCam/Features/Home/HomeViewController.swift): same substitution in
   `renderRows(completion:)` with `tableView: clipsTableView`; keep the existing
   completion body (preserved-thumbnail clear, `loadMoreIfVisibleTail()`, chained
   caller completion for `handleDayRollover`). Delete `canAnimateTableUpdates`.

4. **DebugViewController**
   (app/DanCam/DanCam/Features/Debug/DebugViewController.swift): replace both
   `dataSource.apply(snapshot, animatingDifferences: false)` calls with
   `dataSource.applyDetachedAware(snapshot, collectionView: collectionView,
   animatedWhenAttached: false)` (preserves its never-animate behavior).

## Tests (Swift Testing, behavioral)

### Helper-level contract tests (mandatory, gating)

These test `applyDetachedAware` directly against a bare data source + view -- no view
controller -- because the two properties the fix depends on must be proven at the helper
boundary, not inferred from integration outcomes the old `apply` already satisfied. Both
must exist and both must run against the table and the collection overloads. New file
`app/DanCam/DanCamTests/Support/DiffableDataSourceDetachedApplyTests.swift`.

1. **No detached cell work** (the discriminator the earlier plan lacked). Build a
   `UITableView(frame:)` that is NOT added to any window, with a diffable data source
   whose cell provider increments a counter (and dequeues a cell whose `layoutSubviews`
   increments a second counter). Call `applyDetachedAware(snapshot, tableView:)` with a
   non-empty snapshot. Assert the cell-provider counter is 0 immediately after the call
   -- no cell was built while detached. Then add the view to a `UIWindow`, force
   `layoutIfNeeded()`, and assert the counter is now > 0. This fails against a plain
   `apply(animatingDifferences:false)`, which invokes the cell provider and lays cells
   out synchronously on the detached table (the exact off-window layout the warning
   flags), so it genuinely discriminates the fix. Mirror for
   `UICollectionViewDiffableDataSource` + `applyDetachedAware(_:collectionView:)`.

2. **Detached completion timing** (verifies, does not assume). `var done = false;
   ds.applyDetachedAware(snapshot, tableView: detachedTableView) { done = true };
   #expect(done)` on the main actor. This directly checks the claim that the reloadData
   branch's completion runs before the helper returns. **This test gates the
   implementation:**
   - If it passes (expected -- it matches the synchronous behavior the existing
     window-less suite already relies on for `apply(animatingDifferences:false)`),
     leave the controller bookkeeping (`handlePostApplyState`, preserved-thumbnail
     clear, `loadMoreIfVisibleTail`) inside the completion as today.
   - If it fails (completion is deferred to a later main-queue turn), do not weaken the
     existing behavior: change the helper so the detached branch invokes `completion`
     synchronously itself (call `applySnapshotUsingReloadData(snapshot)` then
     `completion?()` on the same turn), since a detached view has no visible rows for
     the completion to wait on. Re-run this test and the window-less controller suites
     to confirm pop-on-empty / pagination bookkeeping timing is preserved.

### Integration tests (secondary -- exercise the wiring end to end)

- **RecordingDetailViewControllerTests**
  (app/DanCam/DanCamTests/Features/RecordingDetail/RecordingDetailViewControllerTests.swift):
  1. Covered state change keeps the data source current and pops on empty: embed the
     controller in a UINavigationController, push a plain covering UIViewController
     (animated: false) so the table leaves the window; send a store update adding a
     clip -> `indexPathForTesting(clipID:)` non-nil synchronously; then delete all
     clips (no live row, no cursor) -> controller removed from
     `navigationController.viewControllers`. Guards that the reloadData branch still
     runs `handlePostApplyState` synchronously in the real VC.
  2. Re-attach after a covered update renders fresh cells: pop the cover
     (animated: false), layout, assert `clipThumbnailCellForTesting(clipID:)` returns
     a configured cell.
- **HomeViewControllerTests**
  (app/DanCam/DanCamTests/Features/Home/HomeViewControllerTests.swift): mirror test
  via `embedInNavigationController`; cover Home, mutate clips, assert the row's index
  path reflects the update synchronously; pop back, layout, assert the cell is
  configured.
- Attached-path regression: covered by existing embed-based tests (thumbnail
  preservation, pagination, live row) -- no new tests needed.

The integration tests alone would pass against the old implementation; the helper-level
contract tests above are what actually prove the two essential behaviors (no off-window
cell work, preserved synchronous completion). No `visibleCellCountForTesting` probe --
contract test 1 measures the same thing directly and structure-insensitively.

## Verification

1. `just app-test` -- full DanCamTests suite; all pre-existing window-less synchronous
   assertions must pass untouched, plus the new helper contract tests and covered-update
   tests.
2. Simulator run of the original symptom: navigate Home -> RecordingDetail (and on to
   ClipViewer while events stream in). Console must show neither the
   "layout its visible cells ... without being in the view hierarchy" warning nor the
   `fittingSizeHTarget == 0` unsatisfiable-constraint dumps; lists render correctly on
   every return.
3. Frontmost animation still works: swipe-delete a clip, row animates out.
