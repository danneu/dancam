# Fix Incident Detail's Zero-Size Initial Header Layout

## Problem and outcome

`IncidentDetailViewController` can assign its table header while the table is
unattached and has zero width. The incident detail must instead install a fully
measured, nonzero header once layout has usable dimensions, while preserving the
existing incident experience.

## Decision

Use the established deferred table-header lifecycle: content may be configured
before attachment, but the header is installed only after the table has positive
width. Subsequent layout and content changes remeasure the installed header when
its dimensions change.

## Invariants

- An unattached, zero-width incident detail table has no installed table header.
- Once hosted and laid out, the header matches the table width and has a nonzero
  height that includes the fixed 240-point player and its dynamic chrome.
- The header continues to track width and content-driven height changes after its
  initial installation.
- Incident behavior and public API remain unchanged.

## Proof obligations

- A layout regression test proves the header is absent before usable layout and is
  correctly sized after the controller is hosted and laid out.
- A layout regression test proves the installed header follows a later host-width
  change without becoming zero-sized.
- `just app-test` and `just app-lint` pass.

## Non-goals

- Changing the fixed 240-point player or the current visual design.
- Changing thumbnail, pull, remux, or other incident behavior.
- Updating design documentation for this internal UIKit lifecycle correction.

## Implementation discretion

- Internal helper shape and narrow test-only accessors are left to implementation.
