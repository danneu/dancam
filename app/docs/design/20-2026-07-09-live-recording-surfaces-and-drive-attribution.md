# ADR: live-recording surfaces and drive attribution

- **Status:** Accepted
- **Date:** 2026-07-09
- **Owner:** app
- **Related:** `17-2026-07-02-selector-observation-and-view-state.md`;
  `18-2026-07-08-heartbeat-fresh-present-tense.md`;
  `19-2026-07-08-drive-grouped-clip-browsing.md`;
  `../../../docs/roadmap.md` (swoop `sift`);
  `../../../raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md`;
  `../../../raspi/docs/design/15-2026-07-02-segment-fact-stamping-and-boot-offset.md`

> **Note (2026-07-09):** Decision point 6 is superseded by
> `21-2026-07-09-status-strip-recording-pill.md`: the preview REC overlay is
> deleted, and recording status moves to the shell status strip. The widget,
> drive-card marker, and drive-detail row decisions stand.

## Context

ADR 19 made a drive boottag the browse unit for finished footage and collapsed
Home's per-segment rows into per-drive cards. But the live and pending recorder
rows kept their old placement: standalone at the top of the Recent list's Today
section. Once finished clips became drive cards, that placement was wrong on two
counts. The row is recorder state, not browsable footage, so it does not belong
in a clip list. And keeping it there forced a pile of list special-casing: fake
Today bucketing so the row had a section, per-second `dataSource.indexPath`
lookups to tick the elapsed label, and diffable-identity churn every time a
segment rolled (30-60 s).

Separately, nothing on the live path carried a drive identity. The snapshot
exposed `boot_id` but no `boot_tag`, so a client could not answer "which drive
card is this recording streaming into." Finished clips already carried
`boot_tag` (ADR 19); the live state did not.

The app owns the browsing and recording-status experience. The Pi should stay a
flat state server unless a stronger contract need appears.

## Decision

Relocate the live/pending presentation to three purpose-built surfaces, and give
the live path a drive identity so two of them can attribute the recording to a
specific drive.

1. **Home widget, not a Recent-clips row.** The live/pending presentation is a
   dedicated widget mounted directly under the Record (Stop) button, outside the
   clip list. The Recent list holds only browsable footage. This deletes the
   fake-Today bucketing, the per-second table-tick path, and the segment-roll
   identity churn.

2. **Snapshot-level nullable `boot_tag` is the drive identity.** The `/v1/status`
   snapshot and the `/v1/events` first frame gain a nullable `boot_tag`, derived
   from `boot_id` by raspi ADR 15's canon and matching clip `boot_tag` (see the
   raspi ADR 02 dated note). It sits at the snapshot top level, not on
   `current_segment`: a drive is a boot, so the tag is a per-boot constant that
   must survive the pending and idle states when there is no current segment.
   Underivable boot ids carry null, which degrades honestly (widget still works;
   no card pill, no detail row).

3. **REC marker on the recording drive's card.** The recording drive's newest
   card (occurrence 0 only) carries a freshness-typed REC marker so the user can
   see which drive the recording streams into. Marking every occurrence would
   claim the recording streams into yesterday's card of a midnight-spanning
   drive.

4. **Live row atop the recorded drive's detail.** When the viewed drive's
   boottag matches the recording, its detail screen shows the shared live row at
   the top of the clip list. The detail stays alive while empty-but-recording (a
   fresh boot right after start, or all finished clips deleted mid-drive); once
   recording stops, the next render pops the empty drive as before.

5. **One recorder-truth projection feeds all three.** All three surfaces render
   from `RecorderTruth` per ADR 18: a red ticking badge for a heartbeat-fresh
   live segment, a gray frozen badge at `~mm:ss` for last-known. Recorder status
   and the boot tag are read together through one equality-gated projection
   (`LiveRecordingInputs`, per ADR 17), never two separate observations. Split
   observations would be a coherence bug: on a reconnect to a new boot the
   snapshot updates recorder state and `boot_tag` in one `send`, and a host that
   cached the two in separate ivars could paint one frame pairing the new
   recorder status with the old boot tag, flashing a REC marker on the wrong
   drive's card. Reading both from one value makes that frame unrepresentable.

6. **The preview REC overlay is retained.** The existing REC pill on the live
   preview's top-right corner stays, alongside the new widget. It answers a
   different question ("is the preview live") and is cheap to keep.

The widget and the drive-detail row share one renderer
(`LiveRecordingStatusView`); the row is a thin table-cell wrapper around the same
view. The view owns its own 1 Hz tick timer (running only while ticking and
onscreen), so neither screen's diffable data source participates in ticking.

## Consequences

Easy:

- Live recorder state and browsable footage stop sharing a surface. The Recent
  list is purely clip-date-driven; recording/recorder inputs leave the sections
  layer entirely.
- Drive attribution is a pure derivation over the shared projection. The same
  boot tag that ADR 19 uses for finished-clip grouping now also answers "which
  drive is recording," with no new Pi endpoint.
- Drive detail gets ticking for free from the shared view, and its stable
  `.liveRecording` identity turns pending->live and segment rolls into in-place
  reconfigures rather than remove+insert churn.

Hard or risky:

- The empty-but-recording drive detail must not pop while a live row is present.
  The pop gate now also depends on the live observation, so the host must know
  `showsLiveRow` before it can decide to pop; controller tests pin both the
  stay-while-recording and pop-after-stop transitions.
- A mid-segment push into drive detail would otherwise anchor elapsed at "now"
  and show 00:00 while Home has been ticking. Detail seeds its first elapsed from
  an `initialLiveSegment` passed at push time, then threads its own previous.
- `boot_tag` remains an identity key only, never chronological or sortable, same
  as ADR 19.

Mitigations:

- Model tests cover `LiveRecordingStatus` freeze/thaw/pending and
  `RecordingDrive` attribution (nil tag, none, pending, ticking, frozen).
- Controller tests cover the widget lifecycle, the card marker (newest
  occurrence only, none on tag mismatch/nil, grays offline, and a new-boot
  reconnect marking only the new card), and the detail live row (appears for the
  current boot, freezes/thaws in place, seeds elapsed mid-segment, stays while
  empty-but-recording, pops after stop).

## Alternatives considered

- **Keep the live/pending rows in the Recent list.** Rejected. It forces fake
  Today bucketing, a per-second table-tick path, and diffable-identity churn on
  every segment roll -- the exact plumbing this ADR removes.
- **Put `boot_tag` on `current_segment`.** Rejected. It would restate a
  boot-level constant on every segment and vanish exactly when the attribution is
  needed most -- during pending (no current segment) and idle.
- **Hide the card pill and detail row when the link drops.** Rejected. It
  reintroduces the flap ADR 18 rejected; last-known state stays visible and typed
  (gray frozen) rather than blinking out on a heartbeat gap.
