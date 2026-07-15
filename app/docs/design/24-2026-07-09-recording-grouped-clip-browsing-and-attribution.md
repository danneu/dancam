# ADR: recording-grouped clip browsing and attribution

- **Status:** Accepted
- **Date:** 2026-07-09
- **Owner:** app
- **Related:** `19-2026-07-08-drive-grouped-clip-browsing.md` (superseded);
  `20-2026-07-09-live-recording-surfaces-and-drive-attribution.md` (superseded);
  [app connection](../../../docs/design/app/connection.md);
  `../../../docs/roadmap.md` (swoop `sift`);
  `../../../contract/events/README.md`;
  [Pi storage](../../../docs/design/pi/storage.md)

## Context

ADRs 19 and 20 made a Pi boot the browse unit: clips grouped by `boot_tag`, one
"drive" card per boot, live recording attributed to a boot. But one boot holds several
distinct recording runs -- a manual stop/start today, a CarPlay auto start/stop in the
`reef`/`sage` swoops, or a mid-boot power blip and service restart -- and the
boot-keyed model collapsed all of them into a single card.

The wire now carries a per-clip `session` (see the Pi storage design; app clip field
added in the preceding contract commit). A recording is identified by the pair
`(boot_tag, session)`, durable across a same-boot service restart, so the app can
finally group by the run that was actually recorded rather than by the boot that
happened to host it.

The domain rule that forces the rename: a *recording* is an observable contiguous
capture run -- a witnessed start..stop, stamped `(boot_tag, session)` into the segment
filenames. A *drive* or *trip* is not observable: the unit has no ignition signal,
odometer, or GPS trip boundary, and one drive may hold zero, one, or many recordings.
Naming a clip group a "drive" would assert trip boundaries the system never captured,
so the product must not; it names the unit a recording.

## Decision

The Home browse unit is a **recording**, identified by
`RecordingID(bootTag, session)`. All of ADR 19/20's mechanics carry forward, re-keyed
from `bootTag` to `RecordingID`:

- Contiguous same-`RecordingID` finished clips coalesce into one card; occurrences are
  counted per `RecordingID` so a run split across a midnight day-boundary keeps stable
  per-card identity.
- The card's representative thumbnail, aggregate duration, and clip count are unchanged.
- Recording detail projects over the root clip store, filtered to the target
  `RecordingID`, with conservative nil-facts-tail pagination that now also stops on a
  same-boot different-session tail.
- The REC marker attaches to occurrence 0 of the recording currently being written,
  read from one coherent `LiveRecordingInputs` projection (recorder truth and world boot
  tag derived from the same `state.link`, preserving ADR 20's one-projection
  constraint). Live attribution pairs the world boot tag with the live segment's own
  session (or, while pending before the first segment, the live recorder snapshot's
  session).

**"Recording" is now both the product vocabulary and the domain model.** The UI says
"Recording", and the code names the unit `Recording` /
`RecordingID` / `RecordingGroup` / `RecordingAttribution` / `RecordingDetail*`. The
obsolete "Drive" noun is retired from the active tree. `session` remains the low-level
persisted/wire discriminator only; `RecordingID` is the domain identity that pairs it
with `boot_tag`.

## Consequences

- Two recordings in one boot are two cards and two detail screens; on a same-boot
  restart the REC marker moves to the new recording's card.
- A stale-server clip that carries `boot_tag` but no `session` (`recordingID == nil`)
  degrades to an ordinary ungrouped finished row -- the all-or-nothing wire shape,
  handled with no special case.
- The gap-between-cards annotation is deliberately deferred (iceboxed).
- **Recording boundaries are not trip boundaries.** A future feature must not
  reconstruct drive/trip semantics from them: one trip may span many recordings or,
  during a stop, none. Trip grouping, if ever wanted, needs its own observable signal
  (GPS or ignition), not a fold over recording edges.

## Alternatives considered

- **Keep the boot-keyed "drive" model.** Rejected. It merges unrelated recording runs
  under one card and, post-CarPlay auto start/stop, would do so as the norm.
- **Group by session alone.** Rejected. `session` is unique only within a rec dir;
  `boot_tag` is needed to disambiguate across boots, so the identity is the pair.
- **Keep "Drive" as the product noun while grouping by recording.** Rejected. The word
  asserts trip semantics the unit cannot observe; the vocabulary must match what the
  system actually witnesses.
- **A typealias / deprecated shim from `Drive*` to `Recording*`.** Rejected per repo
  stance -- there are no shipped clients, so the old names are renamed in place.

## ADR bookkeeping

This ADR supersedes app ADRs 19 and 20. Those files are append-only historical record:
their filenames and "drive" wording stand unchanged; only their Status line gains the
supersession marker. ADR 24 additionally retires the "Drive" vocabulary going forward
and renames the "drive card" / "drive detail" surfaces described by the app connection
design's Decision log. The status strip is identity-agnostic; this decision records the
surface rename where it occurred.
