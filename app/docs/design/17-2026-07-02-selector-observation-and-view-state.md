# ADR: selector observation and view state

- **Status:** Accepted
- **Date:** 2026-07-02
- **Owner:** app
- **Related:** `03-2026-06-24-app-ui-architecture.md`;
  `06-2026-06-26-domain-root-store-and-scoped-observation.md`;
  `10-2026-06-29-event-folded-state-machines.md`;
  `16-2026-07-01-client-side-clip-thumbnails.md`

## Context

ADR 06 established one scene-scoped root store, equality-gated `send`, and scoped
keypath observation. ADR 10 replaced polling with `/v1/events` folded into `Link` and
`World`. ADR 16 made finished Home rows render asynchronous client-side thumbnails.

Those decisions still hold, but together they exposed a narrower rendering problem. Home
and Health were still observing raw slices that were wider than what the screens actually
rendered:

- Home status pills observed `link.world` but displayed only a sensor warning and camera
  offline flag.
- Home rows observed `link.world` and `clips`, then called `reloadData()` for every row
  render. Telemetry deltas that did not affect rows still reloaded the table, and genuine
  row changes reloaded every visible thumbnail cell.
- Health telemetry observed `link.world` but displayed only formatted telemetry strings.

Before thumbnails, Home's extra table reload was mostly invisible. After ADR 16, each
`ClipThumbnailCell` owns an async thumbnail load, so `reloadData()` blanks visible cells to
their placeholder and dispatches new loads. The result is user-visible clip-list flicker
on telemetry updates and unnecessary prefetch churn.

## Decision

Make selector-based observation the store primitive:

- `Store.observe(select:)` accepts a pure selector from domain state to an `Equatable`
  value, fires once on registration, then fires only when that selected value changes.
- Keypath observation remains as one-line sugar over `observe(select:)`.
- The selector observer updates its cached value before invoking the observer, preserving
  the re-entrant send contract from ADR 06.

Screens should observe the derived `Equatable` view-state they render when that projection
is narrower than the domain slice:

- Home status pills observe `HomeStatusPills.from(link.world)`, which contains only the
  displayed thermal warning caption/color and camera-offline flag.
- Health observes `[TelemetryRow]`, the already-formatted telemetry rows, so non-rendered
  recorder/camera/boot/uptime changes do not rebuild the stack.
- Raw-slice and narrowed-keypath observers remain when the slice is already the view state:
  Home keeps observing `recording`, rows observe `link.world?.recorder`, and rows observe
  `clips.clips`.

Move the Home clip/live list from a manual `UITableViewDataSource` plus unconditional
`reloadData()` to `UITableViewDiffableDataSource<HomeSection, HomeRowID>`:

- `HomeRowID` keys rows by identity, with distinct `.live(session:id:)` and `.finished(id)`
  cases so a live segment and finalized clip with the same numeric id can coexist.
- `HomeRowDiff.reconfiguredIDs(old:new:)` marks only ids present in both snapshots whose
  `HomeRow` value changed.
- Snapshots use `reconfigureItems`, never `reloadItems`, so a visible
  `ClipThumbnailCell` is configured in place and keeps an already-painted same-identity
  thumbnail.
- Thumbnail prefetch handles are keyed by `ClipThumbnailIdentity` (`clip.id` plus `etag`)
  instead of `IndexPath`, and row renders prune only identities no longer present rather
  than cancelling every warm.

ADR 06, ADR 10, and ADR 16 remain Accepted. This ADR extends them: the root store and
event-folded state machines are unchanged, while view controllers now select narrower
rendered projections and Home renders row changes without a full reload. The diffable
choice is what lets ADR 16's async thumbnails update without a reload flash.

## Consequences

Easy:

- Telemetry deltas that do not change Home's displayed pill state no longer wake pill
  rendering.
- Telemetry deltas that do not change `recorder` no longer recompose or reload Home rows.
- Health rebuilds telemetry labels only when a displayed string changes.
- Genuine Home row inserts, moves, and reconfigures preserve scroll position and leave
  unchanged thumbnail cells painted.
- Prefetch warms survive unrelated row updates.

Hard or risky:

- `UITableViewDiffableDataSource` now owns Home cell provisioning, so the controller must
  avoid a retain cycle by capturing `self` weakly in the cell provider.
- `HomeRowID` must stay identity-shaped. Keying by whole `HomeRow` would turn content
  changes into delete/insert, while keying by bare clip id would collide with a live row.
- Prefetch cancellation is now identity-based. Any future clip removal or eviction action
  must keep pruning departed identities.

Mitigations:

- Store tests cover selector initial fire, derived dedup, and re-entrant send behavior.
- Pure projection tests cover `HomeStatusPills`, `[TelemetryRow]`, and `HomeRowDiff`.
- Home controller tests cover surviving prefetch preservation, stale identity pruning,
  telemetry deltas not churning rows, and the visible-cell outcome: changed rows
  reconfigure in place while unchanged thumbnail cells are not reloaded.

## Alternatives considered

- **Computed view-state properties on `AppFeature.State`.** Rejected: pushes view-shaped
  fields into the domain state and violates ADR 06's page-as-projection boundary.
- **Combine, Observation, or KVO.** Rejected: a selector observer is a small extension of
  the existing TEA store and preserves ADR 03's zero-dependency stance.
- **Narrow row observation but keep `reloadData()`.** Rejected: it would stop telemetry
  flicker but still flash every thumbnail on real row changes.
- **Gate `reloadData()` on `rows != oldRows`.** Rejected: it removes no-op reloads but
  still reloads every visible thumbnail for a one-row change.
- **Diffable keyed by whole row or bare numeric id.** Rejected: whole-row keys lose cell
  identity on content changes, and bare ids cannot represent a live row and finished row
  with the same segment id.
- **Manual batch-update diffing.** Rejected: UIKit's diffable data source provides the
  required identity diffing and reconfigure path without hand-written index math.
