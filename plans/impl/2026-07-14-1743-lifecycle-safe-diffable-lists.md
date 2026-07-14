# Lifecycle-safe diffable lists

## Summary

Make list rendering explicitly presentation-aware so model observations continue while screens are covered, but UIKit snapshots, visible-cell inspection, and pagination occur only while the owning screen is active and attached. Apply the fix consistently to Home, Recording Detail, Debug, and Incidents.

## Implementation changes

- Extend `DiffableSnapshotApplyGate` with an explicit inactive-by-default lifecycle:
  - `setActive(true)` attempts the latest pending snapshot once hierarchy and geometry are usable.
  - `setActive(false)` blocks new applies and marks pending work for reload-data application on reactivation.
  - If deactivated during an in-flight apply, retain the newest snapshot and reapply it with reload data after reactivation, repairing any transition-interrupted diff.
  - Treat that repair as a completion barrier: retain completions from the interrupted apply and any coalesced submissions, then drain them in submission order only after the newest reload-data apply completes. This prevents pagination completions from inspecting UIKit state left behind by the interrupted apply before the repair is installed.
  - Continue coalescing inactive submissions to the newest snapshot while preserving completion submission order across the repair barrier.
- Wire each continuously observed list controller into the gate from `viewWillAppear` and `viewWillDisappear`; keep `viewDidLayoutSubviews` as the geometry-ready flush point. Move Incidents from direct diffable application to the shared gate.
- Add an explicit active-and-attached predicate around production calls that inspect visible UIKit content:
  - Home: thumbnail preservation/reconfiguration, visible headers, snapshot-completion pagination, cursor-triggered pagination, and `willDisplay` pagination.
  - Recording Detail: thumbnail preservation/reconfiguration and all pagination entry points.
  - Incidents: visible-header refresh.
  - Cleanup during disappearance may inspect visible cells only while the list is still attached.
- Preserve model projection while inactive. On return, render only the newest queued snapshot without animation. After that reload completes, Recording Detail loads again when its matching `clips` projection is empty but `state.canLoadMore` is true; otherwise controllers perform their visible-tail check and resume pagination only when the newly displayed tail is genuinely visible. This prevents `clips.onDisappear` cancellation from being undone by stale snapshot completions and lets an empty filtered recording projection converge on older matching clips or exhaustion.
- No public product API, reducer, persistence, contract, or ADR changes are required.

## Test plan

- Expand gate tests for inactive-by-default behavior, activation with usable geometry, inactive coalescing, reload on reactivation, and deactivation during an in-flight apply. Cover the repair barrier with an apply that finishes after rapid deactivation/reactivation: no retained completion may run until the newest reload-data apply finishes, and all retained completions then run in submission order.
- Strengthen Home's covered-update tests to reproduce the reported sequence and exercise every guarded pagination trigger: cover Home with another tab/controller, finalize a clip with a cursor present, change the cursor, and invoke `willDisplay` for a pagination-tail row while inactive. Verify model state advances but snapshot-completion, cursor-change, and `willDisplay` paths issue no page request; then return and verify the latest rows render and legitimate visible-tail pagination resumes.
- Add the equivalent no-off-screen-pagination and reattachment coverage for Recording Detail. While covered, exercise cursor-change and pagination-tail `willDisplay` paths and verify neither requests a page. Also cover an update that removes the last matching clip while the cursor remains unexhausted; on return, verify the repair reload completes before pagination restarts and older matching clips can be discovered.
- Add covered-update tests for Debug and Incidents proving their projections stay current while inactive and the latest snapshot/header content appears on return.
- Keep the existing active-screen pagination-chain tests to prove pages still auto-continue when a returned page is absorbed into a visible recording group. Attach Home and Recording Detail controllers to visible windows in positive `willDisplay` pagination tests so those tests exercise active-screen behavior under the new inactive-by-default lifecycle.
- Run `just app-test`, then manually stress rapid Home/Incidents switching while clips finalize with the `UITableViewAlertForLayoutOutsideViewHierarchy` symbolic breakpoint enabled; acceptance is no breakpoint hit, no warning, and no pagination while Home is inactive.

## Assumptions

- "Active" begins in `viewWillAppear` and ends in `viewWillDisappear`; `window != nil` alone is intentionally insufficient during tab and navigation transitions.
- Store observations remain alive while covered so controllers retain current model projections; only UIKit work is deferred.
- Off-screen snapshot changes use reload data on return because there is no user-visible animation to preserve and reload is safer after a detached interval.

## Implementation notes

- UIKit can install an apply interrupted by a navigation transition without invoking its completion. Deactivation therefore invalidates ownership of the in-flight callback, and reactivation may begin the reload-data repair immediately. A per-apply identifier makes any eventual stale callback a no-op while the repair remains the completion barrier.
- Controllers also flush from `viewDidAppear`, where thumbnail lists retry visible-cell configuration. `viewWillAppear` is still the active-state boundary, but the list can remain detached at that point during a navigation return and may not receive another layout callback after attachment.

## Follow Up

- [ ] Manually stress rapid Home/Incidents switching with the `UITableViewAlertForLayoutOutsideViewHierarchy` symbolic breakpoint enabled. Deferred because symbolic-breakpoint interaction requires an operator-driven Xcode session; the automated covered-state regressions and full app suite pass.
