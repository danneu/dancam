# Preserve coalesced row reconfigurations

## Problem

After the Pi finalizes a recording and reports `recording_stopped`, Home can leave the
recording card's REC marker visible even though the button and live-recording widget
already show that recording stopped. Returning to Home removes the marker because the
visible cell is configured again.

The model and recording event order are correct. The failure is in presentation:
diffable snapshots carry stable item identity declaratively, but `reconfigureItems` is
transition work. A newer snapshot can supersede the snapshot carrying that work before
UIKit commits it, while the controller has already advanced its diff baseline.

## Decision

Make the shared diffable snapshot presenter preserve content-reconfiguration
obligations while it coalesces structural snapshots. An obligation remains pending
until UIKit commits the latest desired presentation or a reload-data repair rebuilds
that presentation.

Controllers remain responsible for identifying semantic content changes. Stable row
identity and `reconfigureItems` remain the app-wide update mechanism; the presenter
becomes responsible for ensuring those updates survive presentation coalescing.

Update the identity-preserving UIKit guidance and append the decision rationale in
`docs/design/app/architecture.md` in the same change.

## Invariants

- I1: The latest committed presentation reflects the latest content for every
  surviving stable item, even when intermediate snapshots are superseded.
- I2: Same-identity content changes reconfigure cells in place; they do not force list
  reloads or replace row identity.
- I3: Pending content work survives in-flight applies, inactive or unusable geometry,
  and interrupted lifecycle repair. Stale apply callbacks cannot discard it.
- I4: A committed item removal ends any obsolete content obligation. Reinsertion after
  that commit is a fresh insertion; temporary omission before a commit must not lose a
  still-relevant obligation.
- I5: Existing latest-commit notification, animation, pagination, scroll-position, and
  painted-thumbnail behavior remains unchanged.
- I6: The fix is app presentation infrastructure only; Pi events, transport contracts,
  reducers, and recording truth do not change.

## Proof obligations

- PO1: Reproduce the production ordering -- final clip, recording stopped, then another
  Home render before UIKit catches up -- and prove the completed card loses REC without
  navigation while retaining its correct duration, count, and thumbnail.
- PO2: Deterministically prove at the shared presenter boundary that content work
  survives superseding snapshots and lifecycle repair, is not cleared by stale
  callbacks, and is cleared after the latest presentation commits.
- PO3: Prove temporary removal/reinsertion and committed removal satisfy I4 without
  attempting to reconfigure an absent item.
- PO4: Preserve the existing Home stop projection test and the list regressions for
  in-place updates, thumbnail preservation, pagination, serialization, and animation.
- PO5: `just app-test` and `just app-build` pass. On the production Pi, a brief
  record/stop cycle removes REC immediately without thumbnail flashing or leaving and
  returning to Home.

## Rejected ideas

- Hide the Home badge directly on stop: this creates a second presentation path and
  leaves every other same-identity content update vulnerable.
- Reload the list: this sacrifices stable cells, thumbnails, scroll position, and the
  architecture's established diffable-update behavior.
- Put content into row identity: this turns ordinary content changes into structural
  delete/insert churn.

## Implementation discretion

- The presenter's internal representation and normalization of pending content work.
- The exact deterministic test seam used to control snapshot apply completions.

## Follow Up

- Run the production Pi record/stop acceptance check from PO5 when the iPhone and Pi
  are available together; the current Mac session cannot reach `dancam.local`.
