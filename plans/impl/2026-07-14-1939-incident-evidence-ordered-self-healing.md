# Plan: evidence-ordered, self-healing incidents

## Summary

The 16:55 incident exposed a stop/finalize race:

- The mark targeted Pi session 194, segment 445.
- Segment 444 downloaded successfully.
- At 16:55:48 the app requested recording stop.
- While 445 was still open, `/v1/clips` omitted it and the app treated
  `.stopping` as proof the session had ended.
- The incident persisted 445 as `lost` and became `partial`.
- About 2.4 s later, 445 finalized normally. It remains downloadable with etag
  `445-31098020`, but terminal partial incidents are excluded from reconciliation.

Fix the evidence model rather than adding blind partial retries. Negative absence
must be fresh and correctly ordered; later positive evidence may repair an inferred
absence. Confirmed deletion and 404 evidence remains terminal.

## Implementation changes

### Recorder and list evidence ordering

- Model `.stopping` as the same active, finalizing `RecordingID`. Disable new marks
  during stopping, but do not declare its open segment lost until
  `recording_stopped`, recorder failure, or a different session is authoritative.
- Forward every recorder lifecycle transition to incident reconciliation. Preserve
  the Pi guarantee that `clip_finalized` is folded before `recording_stopped`.
- Add `lastSuccessfulHeadEpoch` to clip state. On every SSE snapshot, start a new
  clips-head load before incident reconciliation and record that epoch as the
  minimum acceptable generation for negative evidence.
- Let stale clips remain visible and usable as positive witnesses, but expose list
  coverage as unavailable for absence decisions until a successful head/page chain
  from the required epoch covers the sequence.
- On a retryable incident page failure, settle paging but set
  `ClipsFeature.status` to the typed failure without discarding gathered clips. The
  next heartbeat uses the existing failed-head retry path to start a new head epoch;
  its successful `clipsChanged` clears the incident page-request gate so the planner
  can rebuild the page chain. Negative inference remains fenced until that chain
  supplies fresh coverage.

### Fact-based incident state and correction

- Remove persisted `IncidentRecord.status`; derive it from segment facts:
  - unresolved or wanted -> pending
  - all settled with any lost -> partial
  - all settled with no lost -> saved
- Continue decoding existing JSON records: the old `status` key is ignored, so no
  destructive migration is needed.
- Add optional persisted loss evidence to lost segments:
  - `inferred_absence` for covered gaps or a marked segment absent after a proven
    session end
  - `confirmed_missing` for `clip_removed` or a resolved-etag pull returning 404
- For legacy lost segments, infer `inferred_absence` when etag/duration are absent
  and `confirmed_missing` when they are present. This classifies the existing
  segment 445 record correctly.
- Allow a same-recording positive clip witness to change `inferred_absence` or
  `clipped` back to `wanted`, persisting that correction before starting a pull.
  Never revive `confirmed_missing` from a potentially stale list.
- Scan every readable incident for contradictions, including saved and partial
  records. This lets the current partial automatically become pending, pull 445,
  then derive saved.
- Publish every created or updated record through one ordered persistence effect:
  write the record durably, perform the notifier mutation for its derived-status
  transition, then emit the action that installs the record and resumes
  reconciliation. Creation and terminal -> pending schedule the nudge; pending ->
  terminal cancels it. Never merge a notifier mutation with reconciliation, so a
  fast cache-backed pull cannot overtake scheduling and leave a late false nudge.
  On store load, idempotently cancel nudges for already-terminal records.
- Keep local completed artifacts strongest: store reconciliation still upgrades any
  segment with a complete final phone artifact to pulled before network planning.

### Diagnostics and design record

- Add an `incident` unified-log category. Emit notice-level records for
  inferred/confirmed loss, corrective reopening, pull completion, and terminal
  state; emit debug-level records when negative inference waits for a fresh head
  epoch.
- Add app ADR 29 documenting evidence precedence, `.stopping` semantics,
  snapshot-scoped negative coverage, derived status, and corrective reconciliation.
  It supersedes ADR 26 only where ADR 26 declared saved/partial permanently terminal.
- Link ADR 29 from `app/AGENTS.md`. After device acceptance passes, mark the
  implemented `nova` roadmap items complete.
- Do not change the Pi, `/v1/clips`, SSE contract, or incident UI, and do not add a
  manual Retry button.

## Test plan

- Model/store tests:
  - Derive pending, partial, and saved solely from segment states.
  - Decode the actual legacy shape `status=partial` plus lost segment without etag
    as inferred absence.
  - Decode legacy lost-with-etag as confirmed missing.
  - Round-trip the new loss evidence while ignoring the legacy status key.
- Planner tests:
  - `.stopping` never proves the marked segment disappeared.
  - Negative inference waits until `lastSuccessfulHeadEpoch` satisfies the snapshot
    barrier and pagination covers the sequence.
  - A positive same-session witness reopens inferred-lost and clipped segments,
    persists first, then pulls on the next pass.
  - Confirmed 404 and `clip_removed` losses never reopen or loop.
  - A genuinely missing mark after fresh post-end coverage still becomes partial.
- App reducer tests reproducing the real symptom:
  - Mark 445 with 444 already pulled.
  - Fold `recording_stopping` and a pre-finalization head response that omits 445;
    assert pending/unresolved.
  - Fold `clip_finalized(445)` followed by `recording_stopped`; assert 445 resolves,
    pulls, and the incident becomes saved.
  - Repeat through background/foreground with an idle snapshot and stale pre-stop
    list; assert no loss before the fresh head response.
  - Cold-launch the legacy partial record with a fresh list containing 445; assert
    automatic partial -> pending -> saved recovery and balanced notification
    lifecycle.
  - Make an incident require a lower page, return a retryable 503 for that page,
    then deliver a heartbeat. Assert the heartbeat starts a fresh head/page chain,
    successful coverage clears the page-request gate, and the incident reaches its
    derived terminal state.
  - Parameterize the session-end witness over same-session `recorderFailed` and a
    different-session `recordingStarting`. With fresh list coverage proving the
    marked segment absent, assert each event is forwarded to reconciliation and the
    incident derives partial.
  - Gate terminal -> pending nudge scheduling while a cache hit is otherwise ready.
    Assert no pull/reconciliation publication overtakes the schedule, then release
    it and verify the final notifier operation after completion is cancellation.
- Run `just app-test`, `just app-build`, `just app-lint`, and `just adr-check`.
- Physical acceptance on the connected iPhone:
  - Install the fixed app while Pi clip 445 remains available.
  - Relaunch without editing the app container. Verify the 16:55 incident
    automatically downloads 445 and changes from Partial to Saved.
  - Verify it contains segments 444 and 445, covers about 54.1 s, plays and shares
    both, and preserves the already-downloaded 444.
  - Reproduce save -> background/foreground -> stop while the marked segment is
    open; verify the new incident finishes Saved.

## Assumptions

- Automatic healing is required for existing records when positive Pi evidence
  contradicts inferred absence.
- Genuine partials backed by `clip_removed` or pull 404 remain terminal and do not
  retry.
- The fix remains app-only; existing Pi event ordering and clip metadata are
  sufficient.
- No compatibility shim is needed beyond safely decoding the current on-device JSON
  so the observed incident can recover.

## Implementation notes

- Negative coverage compares `lastSuccessfulHeadEpoch` with the clips feature's
  current `headEpoch`. Because every snapshot synchronously starts a new head epoch
  before incident reconciliation, the current epoch is the minimum acceptable
  generation without duplicating that barrier in incident state. This also safely
  fences absence during manual and heartbeat-driven head reloads.

## Follow Up

- Run the physical acceptance cases in this plan on the connected iPhone, including
  automatic recovery of the existing 16:55 incident and a new stop-while-open mark;
  only then mark the implemented `nova` items complete in
  `docs/roadmap.md#Default order`.
