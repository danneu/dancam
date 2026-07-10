# Geometry-gated diffable snapshot application

## Summary

Replace the detached-aware helper with a snapshot gate that does not touch a diffable
data source until its list view is both in a window and has nonzero geometry. The
reload-data fallback can still queue UIKit work that runs when a table first attaches
at width 0.

Use `viewDidLayoutSubviews` to flush pending snapshots after Auto Layout has sized the
list.

## Implementation changes

- Introduce an internal generic `DiffableSnapshotApplyGate<Section, Item>` with table
  and collection view initializers. It coalesces gated submissions, aggregates their
  completions, uses reload-data for deferred snapshots, preserves normal diffing for
  ready submissions, and serializes submissions arriving during an apply.
- Replace `applyDetachedAware` in Home, Recording Detail, and Debug with one gate per
  data source. Flush each gate at the end of `viewDidLayoutSubviews`.
- Keep controller model projections synchronous while UI application is deferred.
  Recording Detail performs empty-recording removal or initial pagination immediately;
  visible-tail pagination and thumbnail cleanup remain tied to a completed apply. Home
  keeps immediate row models, with header refresh and visible-tail pagination after an
  actual apply. Debug builds desired snapshots from `renderedSections`, not the
  intentionally lagging data-source snapshot.
- Delete the detached-aware extension and replace its tests. Add a correction note to
  the previous promoted plan describing the attached-but-zero-width device finding and
  pointing to this successor plan.

## Test plan

- Cover the gate contract for table and collection views: detached and zero-sized
  submissions do no data-source/cell/layout work; a usable layout flushes the latest
  snapshot and completions; gated updates coalesce; in-flight updates serialize; and a
  ready view uses the normal diff path with its animation preference.
- Cover Home -> Recording Detail before destination layout, covered-screen synchronous
  model projection with newest-state rendering on reappearance, and immediate removal
  of an empty covered recording.
- Preserve existing pagination, day rollover, thumbnail preservation, and attached row
  update coverage.
- Run `just app-test`, then repeat physical-device navigation with symbolic breakpoints
  for `UITableViewAlertForLayoutOutsideViewHierarchy` and
  `UIViewAlertForUnsatisfiableConstraints`.

## Assumptions

- Initial and reattachment rendering is non-animated via reload-data; later ready-state
  updates retain their requested animation behavior.
- Windowless tests assert synchronous controller model state, not synchronous diffable
  data-source state. Rendered-cell assertions attach and lay out first.
