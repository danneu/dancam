# ADR: drive-grouped clip browsing

- **Status:** Superseded by 24-2026-07-09-recording-grouped-clip-browsing-and-attribution.md
- **Date:** 2026-07-08
- **Owner:** app
- **Related:** `02-2026-06-22-app-pi-transport-and-api.md`;
  `06-2026-06-26-domain-root-store-and-scoped-observation.md`;
  `16-2026-07-01-client-side-clip-thumbnails.md`;
  `17-2026-07-02-selector-observation-and-view-state.md`;
  `../../../docs/roadmap.md` (swoop `sift`);
  `../../../raspi/docs/design/15-2026-07-02-segment-fact-stamping-and-boot-offset.md`

> **Amended (2026-07-09):** ADR 20
> (`20-2026-07-09-live-recording-surfaces-and-drive-attribution.md`) changes where
> recorder state renders. Live and pending rows no longer render standalone in the
> Recent list; drive detail additionally renders a live row at top when its boottag
> is the one being recorded into, and drive cards carry a REC marker on the
> recording drive's newest card. The core drive-grouping decisions here still stand.

## Context

Home originally showed finished footage as one row per segment. That is usable for a
short recording, but it collapses under normal dashcam usage: a day of driving can mean
hundreds of roughly 30 second segment rows and, after ADR 16, many first-browse thumbnail
prefix reads over a 2.4 GHz link.

The user usually knows "the drive when this happened" before they know the exact segment.
For v1 hardware, one Pi boot maps to one drive because camera power is switched with the
car. The Pi already writes a random per-boot boottag into stamped segment filenames and now
exposes it as nullable `boot_tag` in `/v1/clips` and `clip_finalized`. Bare legacy or
rename-failed segment names can still appear with `boot_tag == nil`.

The app owns the browsing experience. The Pi should remain a flat clip metadata server
unless a stronger contract need appears.

## Decision

Treat the drive boottag as the browse unit for finished stamped clips.

Home composes drive cards app-side from the same flat `ClipsFeature.State` clip list it
already observes. Within each day section, consecutive finished clips with the same
non-null `boot_tag` collapse into one drive card. Unstamped clips remain ordinary finished
clip rows in place, and live or pending recorder rows stay standalone above finished
footage. A single stamped clip is still a drive card so the behavior is uniform.

The drive card is a summary, not a new domain entity. It shows a time span, clip count,
an honest total duration only when every member clip has duration, and one representative
thumbnail. The representative is the oldest clip in the visible drive run. That keeps the
thumbnail identity stable while an ongoing drive finalizes newer clips, and it matches the
card's leading start time.

Tapping a card opens a drive detail screen filtered by `boot_tag`. The detail screen is a
view over the root clips state, not a new reducer and not a stored drive snapshot. It
observes the root store, filters to the requested boottag, and renders normal per-clip
rows that push the existing clip viewer.

Drive detail pagination follows the global flat clip frontier. It may need to page through
trailing `nil`-boottag gaps because a bare segment can split a boot's stamped clips in the
loaded list. The detail stops asking for older pages only when the oldest loaded clip is a
different non-null boottag or when there is no next cursor. Its observed state includes the
global pagination frontier so pages that advance only through invisible `nil` clips still
wake the view and re-check pagination.

Home has the same pagination edge: a whole older page can merge into the existing bottom
drive card and produce no new visible rows. Home therefore observes `nextCursor` and runs
a post-apply visible-tail re-check after diffable snapshot application.

Deletion remains per clip. Drive cards have no swipe-to-delete action. Users can delete
individual clips from the drive detail screen or from the clip viewer, using the same
confirmation and the existing clip delete reducer path.

## Consequences

Easy:

- Recent clips becomes a drive-first browsing surface without adding another top-level
  screen or a Pi aggregation endpoint.
- Home thumbnail cost drops from one representative fetch per visible segment to one per
  visible drive card, while detail still loads per-clip thumbnails only after the user
  asks for that drive.
- The root store and selector-observation model from ADR 06 and ADR 17 remain intact:
  drive cards and drive detail are derived view state over the clip list.
- `boot_tag` stays an identity key only. The app never treats it as chronological or
  sortable.

Hard or risky:

- A midnight-spanning drive appears as one card per day section, but both cards open the
  same boottag detail. Row identity carries an occurrence counter to keep those cards
  unique.
- Bare `nil`-boottag clips can force conservative over-paging in drive detail. That is
  preferable to proving a drive complete too early and hiding older clips.
- Deleting the representative clip intentionally changes the card thumbnail identity.
  That is the correct reflection of the new oldest clip, but it must be handled as a
  reconfigure rather than a broken stale thumbnail.

Mitigations:

- Projection tests cover drive coalescing, nil gaps, midnight splits, single-clip drives,
  occurrence stability, unknown durations, and live/pending rows staying standalone.
- Controller tests cover card navigation, no drive swipe action, visible-tail pagination,
  bottom-card absorption, and representative-thumbnail stability.
- Drive detail tests cover filtering, pagination through nil gaps, empty-but-not-exhausted
  behavior, delete dispatch, viewer navigation, and self-removal when a drive is proven
  exhausted.

## Alternatives considered

- **Flat rows with drive headers.** Rejected. Headers improve orientation but keep the
  per-segment row count and thumbnail cost that made the Recent list hard to scan.
- **Pi-side grouping endpoint.** Rejected. The flat clip list already carries the facts
  the app needs, and grouping is presentation policy tied to day sections, pagination
  stalls, thumbnails, and deletion UX. Keeping it app-side avoids a new contract surface.
- **Newest-clip representative thumbnail.** Rejected. It would churn the card thumbnail
  identity on every finalized segment in an ongoing drive and repeatedly pull new prefix
  bytes over the link.
