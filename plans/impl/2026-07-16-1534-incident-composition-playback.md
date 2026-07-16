# Incident detail: composition playback of pulled segments

## Context

The incident detail screen plays one segment file per row tap, but an incident is
a ~47-second window spanning several segments; reviewing one means tapping through
files. Pending incidents are not watchable as a whole at the moment the user cares
most: right after a press, pre-roll segments pull within seconds while post-roll
cannot finalize for ~17+ seconds.

Desired outcome: the detail screen presents one seamless video of everything pulled
so far, growing and self-repairing as reconciliation lands segments, without
changing the durable per-segment evidence model. This deliberately supersedes the
"no stitched incident movie in v1" line in `docs/design/app/incidents.md` for
playback only -- the durable unit does not change.

Load-bearing premises:

- P1 -- seam continuity: segments are video-only H.264, CFR, `PTS == DTS`, cut on
  IDR boundaries with repeated SPS/PPS
  (`docs/design/pi/recording.md#encode-and-segment-format`), and each pulled MP4 is
  rebased to a zero-start timeline
  (`app/DanCam/DanCam/Media/Remux/ClipRemuxerEngine.swift#write`). Consecutive
  pulled segments are consecutive GOPs of one continuous encode, so back-to-back
  insertion is frame-continuous.
- P2 -- complete files only: a segment persisted as `pulled` has a complete final
  artifact installed atomically before the record update
  (`docs/design/app/incidents.md#durable-store-and-media-installation`); no
  growing-file handling is needed.
- P3 -- observation: the detail controller already re-renders on every change to
  its record via deduped main-actor observation
  (`app/DanCam/DanCam/Architecture/Store.swift#observe`). A pending record mutates
  on evidence transitions that do not change what is playable.
- P4 -- shrinkage: `pulled` never demotes in the record model, but the playable set
  can still shrink (a file that no longer loads, wholesale record replacement), so
  playback contracts are over the playable set, not record-model transitions. The
  playable set is recomputed from disk on every record render; shrinkage that
  arrives without a render is caught by item-failure self-heal (I8) and
  share-source-unavailable (I10). The app does not poll disk (AR5).

## Decision

Replace the detail screen's single-file player with one
AVMutableComposition-backed player whose timeline is the incident's playable
segments. The composition is ephemeral derived state, rebuilt from the record and
the on-disk files whenever the playable set changes; missing footage is spliced
out and annotated. Per user decision: tapping a playable row seeks the unified
player (no single-file playback mode remains), and a jump-to-press affordance is
in scope.

Decisive constraints:

- The timeline builder is a nonisolated pure helper (precedent:
  `app/DanCam/DanCam/Features/Incidents/IncidentListProjection.swift`), not an
  `AppDependencies` seam: no reducer effect calls it, and its proofs require real
  AVFoundation against real files.
- The builder returns the composition together with the seq-to-time map and gap
  descriptors derived from the same build; position math is never derived from
  record `durMs` (rounding drift would desync the map from the real timeline).
- One `AVPlayer` and one `AVPlayerViewController` per screen lifetime; rebuilds
  replace the player item only. Reuse the item-status observation and fullscreen
  delegate patterns from
  `app/DanCam/DanCam/Features/ClipViewer/ClipViewerViewController.swift`.
- Playback position is view state; it never enters reducer state.
- Docs travel with the behavior: update the detail section and decision log of
  `docs/design/app/incidents.md` and the single-timeline caveat in
  `docs/design/app/clips.md#raw-clip-boundary` in the same change.

## Invariants

- I1: The screen has exactly one player; its timeline is the incident's playable
  segments (on-disk, loadable MP4s of `pulled` segments), each whole, in ascending
  seq order, joined without inserted time.
- I2: Stitching is playback-only: no stitched artifact is persisted, and
  per-segment durable artifacts and their install/repair semantics are unchanged.
- I3: The player item is rebuilt only when the playable set changes or to recover
  a failed item (I8); record churn that does not change the playable set leaves the
  playing item untouched.
- I4: Across a rebuild, position is preserved as (segment seq, offset within
  segment) with forward bias: a seam-exact time maps to the next segment's start;
  a vanished playhead segment restores to the start of the lowest surviving seq at
  or above it, else clamps to the timeline end; paused/playing state is preserved
  (rate restoration best-effort, see AR4).
- I5: Rebuilds keep the same player and player-view-controller instances; a
  presented fullscreen session survives a rebuild.
- I6: Once record updates settle, the presented timeline matches the newest
  playable set -- a stale build never replaces a newer one.
- I7: An empty playable set presents a placeholder distinguishing still-saving
  from nothing-playable, with no player item; the first playable segment's arrival
  attaches playback at position zero, and losing the last playable segment returns
  to the placeholder without a failure state.
- I8: A segment file that cannot be loaded is treated as a gap, never as
  whole-player failure; a failed player item self-heals by one rebuild per
  playable set from current disk state, and repeated failure for the same set
  presents a terminal failure state that leaves rows, share, and delete
  functional.
- I9: Non-playable wanted segments between playable ones are visibly represented
  on the detail screen, distinguishing still-saving from missing; a pending
  incident surfaces saving progress.
- I10: The share flow is unchanged: rows remain the share surface for MP4 and TS
  artifacts; a rebuild that retains the selected row does not cancel in-flight
  share preparation, and one that drops it cancels (existing behavior).
- I11: Record disappearance tears down playback -- including dismissing a
  presented fullscreen session -- cancels share preparation, and pops; nothing
  rebuilds against a deleted directory.
- I12: Tapping a playable row seeks the unified player to that segment's start and
  selects it for share; TS rows select for share only.
- I13: Jump-to-press seeks to the press moment (marked segment start plus
  `markAgeMs`) when that position is playable, else forward-biases to the nearest
  playable position; it is disabled while the timeline is empty.

## Proof obligations

Harness: Swift Testing; controller hosted in a real `UIWindowScene` and driven via
`store.send`, as in
`app/DanCam/DanCamTests/Features/Incidents/IncidentDetailViewControllerTests.swift`.
Real multi-segment fixtures come from a multi-frame extension of the
`AVAssetWriter` helper pattern in
`app/DanCam/DanCamTests/Features/ClipViewer/ClipViewerViewControllerTests.swift#temporaryPlayableVideoFile`.

- PO1 (I1): builder over generated MP4s -- composition duration equals the sum of
  the video-track durations, the seq map is contiguous (including non-integer
  frame durations), and ordering follows seq.
- PO2 (I3): evidence-only record churn leaves player-item identity unchanged.
- PO3 (I4): position restores across an append and a lower-seq backfill (proving
  seq-based, not absolute-time, keying); a seam-exact position forward-biases to
  the next segment's start; and a vanished playhead segment restores to the lowest
  surviving seq at or above it, clamping to the timeline end when none survives
  above it.
- PO4 (I5): player and controller instance identity is stable across rebuilds
  (the practical proxy for fullscreen survival).
- PO5 (I6): a stale build completing after a newer one has landed does not replace
  the newer timeline, proven deterministically by delivering build completions out
  of order (the older result last).
- PO6 (I7): empty-to-playing attaches at zero; playing-to-empty returns to the
  placeholder; placeholder wording distinguishes pending from terminal.
- PO7 (I8): a corrupt file among valid ones is spliced and annotated; an injected
  item failure triggers exactly one rebuild, then the terminal state with rows,
  share, and delete still functional.
- PO8 (I9): gap and saving-progress presentation for pending and partial records.
- PO9 (I10): both share-preparation branches (selected row retained / dropped).
- PO10 (I11): record removal tears down playback and pops (extends the existing
  removal test with teardown and fullscreen-dismissal proxies).
- PO11 (I12, I13): row taps and jump-to-press land on the expected composition
  times; a TS row does not seek; jump-to-press is disabled when empty and
  forward-biases when the marked segment is not playable.
- P2 and P3 are already discharged by existing store, installer, and Store
  observation tests; they need no new coverage.

Manual gate: frame-level seam continuity, the absence of visible glitching during
rebuild, and fullscreen survival (I5) are not machine-provable in this harness
(AR3; PO4 proves only instance identity). Verify on the simulator with a seeded
multi-segment incident directory -- including a rebuild triggered while a fullscreen
session is presented, confirming it stays presented with position restored and
controls usable -- and once on a device with real footage (`just app-build`,
`just app-test`, then run the app).

## Non-goals

- Auto-playing the live tail: an ended player does not auto-resume when a new
  segment appends.
- Custom transport controls or scrubber gap/press markers; AVKit stock controls
  only.
- Single-file stitched export or share.
- Playing TS artifacts in the composition, and any remux-path change.
- Pi or API changes; cross-incident stitching.

## Accepted risks

- AR1: `replaceCurrentItem` during active playback may stall or flash briefly;
  ordering (seek the unattached item before attaching) bounds it, but it is not
  visually proven.
- AR2: splices compress time by design; the visible annotation (I9) is the honesty
  mechanism, and timeline proportionality is not preserved.
- AR3: frame-exact seam continuity rests on premise P1 plus the manual gate, not
  automated proof.
- AR4: rate restoration after a mid-playback rebuild and behavior when a rebuild
  lands mid-scrub-gesture are best-effort.
- AR5: a segment file deleted from disk with no accompanying record render, and not
  touched by playback or share, leaves a stale row until the next render; the app
  does not poll disk to detect it. No data-loss consequence: the durable record and
  the other files are unaffected.

## Rejected ideas

- RI1: AVQueuePlayer -- no unified duration or cross-segment scrubbing; visible
  item-boundary seams.
- RI2: materializing a stitched MP4 -- violates the per-segment durable unit and
  goes stale when evidence reopens segments.
- RI3: stable-slot timeline with empty ranges for unpulled slots -- dead-air
  playback, unknown edge durations, and `durMs` drift.
- RI4: local HLS or loopback serving -- a prior decision log
  (`docs/design/app/clips.md`, 2026-07-01) buried this shape.
- RI5: putting the builder behind `AppDependencies` -- stubbing it would destroy
  the proof value and no reducer effect exists to seam.

## Implementation discretion

- D1: gap-annotation placement (player content overlay vs detail-screen chrome);
  the contract is only "visible on the detail screen" (I9).
- D2: autoplay-on-open default and rebuild micro-timing while the user is
  actively interacting with the transport.

## Critical files

- `app/DanCam/DanCam/Features/Incidents/IncidentDetailViewController.swift` --
  the surface being replaced.
- New timeline builder alongside the incident feature (precedent:
  `IncidentListProjection.swift`).
- `app/DanCam/DanCamTests/Features/Incidents/IncidentDetailViewControllerTests.swift`
  and new builder tests; fixture helper extension in the ClipViewer test suite.
- `docs/design/app/incidents.md`, `docs/design/app/clips.md`.

## Implementation notes

- D1: Put gap annotations in persistent detail-screen chrome below the player so
  they stay visible without replacing AVKit's transport controls.
- D2: Autoplay when the first playable timeline appears, then preserve the user's
  paused or playing state across later timeline rebuilds.

## Follow Up

- Verify a seeded multi-segment incident in the simulator, including a rebuild
  while fullscreen is presented, for seamless position restoration and usable
  controls.
- Verify real incident footage on a physical iPhone for frame-level seam continuity
  and the absence of visible glitches during timeline rebuilds.
