# Incident detail: pending segment waiting rows

## Context

Incident composition playback (commit `5b7cb6e`) made a pending incident watchable,
but the segment list still shows only `.pulled` segments with an on-disk artifact:
`IncidentDetailViewController.swift#artifactRows` drops everything else, and saving
segments surface only as a "Still saving: 43" chrome line. Right after a press --
the moment the user cares most -- the list starts near-empty and rows pop in
unpredictably, and the same saving fact is reported twice (chrome line plus the
"Saving N of M segments" progress line).

Desired outcome: the detail screen renders every segment currently known in
`record.wanted` as soon as that record publishes, in sequence order; pending
segments appear as disabled waiting rows that transition in place to their normal
presentation as artifacts install. Newly discovered pre-roll and post-roll
sequences may still insert progressively as the planner expands the record.

Load-bearing premises:

- P1 -- `record.wanted` enumerates every currently known segment with its seq and
  state and is kept seq-sorted (`IncidentRecord.swift#updateSegment`). It starts
  with the marked sequence and grows as `IncidentPlanner` discovers pre-roll and
  post-roll coverage, so each published record's current row set is derivable from
  the record alone.
- P2 -- the detail screen re-renders on every record change via deduped main-actor
  observation (`Store.swift#observe`), so the render that today creates a pulled
  row is the same render that transitions a waiting row.
- P3 -- a pending segment's artifact kind is unknowable before installation: remux
  failure decides TS-only at install time
  (`docs/design/app/incidents.md#durable-store-and-media-installation`), so a
  waiting row cannot carry a URL or artifact kind.

## Decision

Reshape the detail screen's row model from artifact-only rows to per-sequence
segment rows with two presentations: waiting (`.unresolved`/`.wanted`) and
installed artifact (`.pulled` with an on-disk file, keeping the existing playable
and share-only presentations). Remove the "Still saving" chrome line; the waiting
rows and the unchanged progress line now carry that fact.

Decisive constraints:

- A waiting row carries no artifact URL or kind (P3); selection and share
  machinery operate only on installed-artifact rows, so waiting rows can never
  reach the share or seek paths.
- The change is confined to the detail view controller and its tests; the
  timeline builder, reducers, persistence, installer, and Pi API are untouched.
- Docs travel with the behavior: update the detail section and add a dated
  Decision log entry in `docs/design/app/incidents.md` in the same change.

## Invariants

- I1: For each published record, the row set is derived from its current
  `record.wanted` in ascending seq order:
  `.unresolved` and `.wanted` segments render as waiting rows; `.pulled` segments
  with an on-disk artifact render with their existing playable or share-only
  presentation; `.lost` and `.clipped` segments and `.pulled` segments with no
  on-disk artifact have no row (unchanged).
- I2: A waiting row is inert: it cannot be selected, never enables sharing, never
  seeks the player, and exposes a disabled state to assistive technologies. It is
  visually muted, shows an in-progress indicator and waiting copy, and has no
  disclosure chevron.
- I3: When a segment's artifact installs, its row transitions in place: the row
  keeps its sequence position, and rows for other sequences are unaffected. When
  the planner later discovers another sequence, including a lower-seq backfill,
  its new waiting row interleaves into order.
- I4: The aggregate progress line ("Saving N of M segments" / "N of M segments
  saved") is unchanged.
- I5: Chrome annotations report only missing and unavailable segments; the
  "Still saving" line is gone, and the chrome never claims all segments are
  playable while the incident is pending.
- I6: Installed-artifact behavior is unchanged: playable MP4 rows seek the unified
  player and select for share, TS rows select for share only, and selection
  reconciliation, share-source-unavailable handling, timeline rebuild and
  self-heal, jump-to-press, and placeholder behavior are untouched.

## Proof obligations

Harness: the existing hosted-controller pattern in
`IncidentDetailViewControllerTests.swift`, driven via `store.send`.

- PO1 (I1): a record mixing unresolved, wanted, pulled-with-file, lost, and
  pulled-without-file segments renders exactly the expected row set in seq order.
- PO2 (I2): interacting with a waiting row leaves selection empty, share disabled,
  and player time unchanged; the waiting cell exposes a disabled accessibility
  state and no chevron.
- PO3 (I3): after an artifact installs and the record publishes, the same
  sequence's row presents as playable and seeking works; a lower-seq waiting row
  appearing later interleaves in order.
- PO4 (I4, I5): a fully-pending record shows the progress line with no
  "Still saving" line and no all-playable claim; missing and unavailable
  annotations still render for partial records. A terminal record that shows the
  all-playable claim then receives a corrective pending record while its timeline
  rebuild is held outstanding; the all-playable claim disappears immediately,
  before the rebuild completes. (Supersedes the "Still saving: 43" assertions in
  the existing empty-timeline test.)
- PO5 (I6): discharged by the existing detail-controller suite (playback,
  selection, share, rebuild, self-heal, teardown tests) continuing to pass.

## Non-goals

- Rows for `.lost`, `.clipped`, or artifact-less `.pulled` segments; they remain
  annotation-only.
- Diffable data source or animated row transitions; plain table reload stays.
- Timeline-builder or gap-reason changes; the builder still emits `.saving` gaps,
  the chrome just stops rendering them.
- Eliminating row insertion as `IncidentPlanner` progressively discovers pre-roll
  and post-roll sequences; the screen renders each newly published row promptly.
- Any reducer, persistence, installer, share-flow, or Pi/API change.

## Rejected ideas

- RI1: optional URL/kind fields plus a waiting flag on the existing row struct --
  makes invalid states representable and spreads guards across every consumer.
- RI2: a separate "pending" table section -- breaks seq-order interleaving when a
  lower-seq segment backfills.
- RI3: keeping the "Still saving" annotation alongside waiting rows -- presents
  the same fact twice.

## Implementation discretion

- D1: exact waiting-row copy, title format (no fabricated file extension),
  indicator style, and duration/bytes display while metadata is unresolved.
- D2: whether the annotation label is hidden or blank when nothing is missing or
  unavailable on a pending incident.

## Critical files

- `app/DanCam/DanCam/Features/Incidents/IncidentDetailViewController.swift` --
  row model, table rendering, selection guards, chrome.
- `app/DanCam/DanCamTests/Features/Incidents/IncidentDetailViewControllerTests.swift`.
- `docs/design/app/incidents.md` -- detail section body plus dated Decision log
  entry.

## Verification

- `just app-build`
- `just app-test`
- Simulator spot check: a pending incident shows waiting rows immediately and a
  row transitions in place when its artifact lands.

## Implementation notes

- Empty-timeline transition tests await the controller's active timeline build
  after publishing a new record. Fixed polling was unreliable under the full
  media-test load even when the timeline behavior was correct.

## Follow Up

- Stabilize `just app-test`: full runs can hang in the unrelated ClipRemuxer
  AVAssetWriter finish path and can fail timing-sensitive ClipViewer and Home
  controller tests. The incident-detail suite passes independently and within a
  complete serial test run.
