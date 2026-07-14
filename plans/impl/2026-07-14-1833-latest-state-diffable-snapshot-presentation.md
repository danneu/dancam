# Latest-state diffable snapshot presentation

## Summary

Replace `DiffableSnapshotApplyGate` with `DiffableSnapshotPresenter`, whose contract is: retain the latest requested snapshot and notify its controller once UIKit has caught up to that latest presentation. Preserve continuous model observation, lifecycle gating, immediate repair of interrupted UIKit applies, pagination behavior, and visible-cell safeguards.

## Interface and behavior changes

- Rename the type, source file, test suite, and controller properties from "gate" to "presenter."
- Remove the per-submission completion from `submit`; keep `submit(_:animatingDifferences:)`, `setActive(_:)`, and `flushIfReady()`.
- Add an initializer callback `didCommitLatest: @MainActor () -> Void`. Require every controller callback that references controller state to capture `[weak self]`; Debug passes an explicit capture-free no-op callback.
- Keep the presenter explicitly `@MainActor`; introduce no tasks, continuations, actors, or cross-actor state.

## Implementation changes

- Store one revision-tagged desired submission containing the latest snapshot and animation preference. Do not clear it when an apply starts.
- Preserve per-apply IDs. Deactivation marks reload repair required, invalidates ownership of the current callback, and permits immediate repair on reactivation because UIKit may never deliver the interrupted completion.
- When the owned callback arrives:
  - Ignore it if its apply ID is stale.
  - If a newer desired revision exists, apply that revision without notifying.
  - If the view became inactive or detached, retain the desired revision for reload repair.
  - If the callback matches the latest desired revision and the list is ready, clear that revision and invoke `didCommitLatest` once.
- Clear the committed desired revision before invoking the callback so synchronous store actions may safely submit another snapshot.
- Migrate controller reconciliation:
  - Home clears preserved thumbnails, refreshes visible day headers, and checks visible-tail pagination from one stable commit handler. Remove thumbnail generations and `renderRows(completion:)`; day rollover simply submits a fresh snapshot.
  - Recording Detail clears preserved thumbnails and runs `resumePaginationAfterSnapshot()` from one stable commit handler. Remove thumbnail generations and both per-submit closures.
  - Incidents refreshes visible headers from its stable commit handler.
  - Debug uses an explicit capture-free no-op handler.
- Retain all current active-and-attached checks, lifecycle activation, `viewDidAppear`/layout flushing, reload-data reattachment behavior, and immediate model/navigation reconciliation.

## Test plan

- Replace completion-order tests with deterministic latest-commit tests:
  - Inactive submissions coalesce to the newest snapshot and emit one commit.
  - A newer submission arriving during an apply suppresses the older commit; the newest apply emits one.
  - Deactivation invalidates an interrupted callback, reactivation immediately reloads the newest snapshot, the stale callback is harmless, and only repair completion emits a commit.
  - A commit handler may synchronously submit another snapshot without losing or duplicating either legitimate commit.
  - Geometry readiness, table/collection parity, reload-on-reactivation, serialization, and animation preference remain covered.
- Preserve controller regressions for Home day-rollover headers, thumbnail painting, inactive pagination suppression, active pagination chains, Recording Detail empty-projection convergence, Incidents header refresh, and Debug latest-state rendering.
- Add a Recording Detail regression that paints a thumbnail, updates non-identity metadata for the same clip, and verifies the stable row retains the image without another loader request.
- Run `just app-test`.
- Manually stress rapid Home/Incidents switching with `UITableViewAlertForLayoutOutsideViewHierarchy` enabled; accept only no warning, latest rows on return, and no inactive pagination.

## Assumptions

- This is an internal refactor with no reducer, persistence, contract, ADR, or product behavior change.
- Continuous observations remain intentional; only UIKit presentation is coalesced.
- Intermediate snapshot commits have no domain significance. Work that must happen exactly once belongs in the store/effect layer, not a snapshot callback.
- Active diff updates retain their animation preference; reactivation repair remains nonanimated reload data.
