# Centralize Clip Media Work

## Problem and outcome

Thumbnail, viewer, and incident paths independently acquire and transform the same
clip. When their demand overlaps, the app can perform a thumbnail prefix read alongside
a full pull, remux the same TS more than once, and generate the same first frame through
separate pipelines.

The current `<id>-<bytes>` validator also lacks a durable origin. A reset or replacement
storage namespace can reuse an id and byte length, allowing old cache or resumable-pull
state to be mistaken for unrelated footage. Shared coordination must therefore begin
from an origin-scoped representation identity rather than amplify the existing alias.

Move phone-side clip acquisition behind one process-owned coordination boundary. One
clip representation should share useful work across every consumer while retaining the
bounded thumbnail-only path, permanent incident ownership, and existing user-visible
playback and saving behavior.

## Decision

Give every recording storage namespace a canonical lowercase UUID
`storage_generation`, persisted with the sequence witness. It remains stable across
service and Pi reboots and when the same storage moves to a replacement Pi; initializing
or resetting the recording namespace mints a new value. Legacy witness state is enriched
in place before clips are served, without lowering its sequence high-water mark.

Storage generation is nullable, mount-verified operational evidence. The existing
bounded storage observation publishes a generation only after the configured recording
namespace is verified and durable witness initialization succeeds. Status and the event
stream expose `storage_generation: null` while that evidence is unavailable; listing,
pull, recording, and finalization fail closed. Recovery publishes the generation and
matching readiness atomically through snapshots and `storage_changed` before those
media operations become available.

Every listed or finalized clip carries the non-null `storage_generation`. Active
recording identity is `(storage_generation, boot_tag, session)`, and clip validators
become the raw `<storage_generation>-<id>-<bytes>` value in JSON and the quoted form in
HTTP. Every pull response must match the expected generation-scoped validator before
its bytes can be appended or delivered. A mismatch discards partial work and makes the
demand stale; it must be resolved again from current snapshot/list authority rather
than publishing or persisting the changed response under a new identity.

Use one actor-backed media dependency keyed by storage generation, clip ID, and
canonical ETag. Home and recording-detail thumbnails, clip playback, incident
preservation, and clip deletion express their demand through this dependency instead
of directly orchestrating pull, remux, and cache clients.

Thumbnail-only demand remains a bounded prefix operation. Full-media demand supersedes
overlapping prefix work and is single-flighted across playback and incidents. Successful
full acquisition produces the shared playable MP4 and first-frame thumbnail; incidents
copy their evidence into Application Support and never depend on an evictable cache.

If the last full-media interest withdraws while thumbnail interest remains, unfinished
full-only work stops and bounded thumbnail acquisition resumes. An already usable full
artifact remains reusable rather than being discarded.

The Pi storage, telemetry, and OS-image pages, the transport boundary, the app clip,
incident, and architecture design pages, the shared event contract, and the Pi reset
runbook must describe the resulting identity, availability, ownership, and reset
behavior with dated decision-log entries on the owning pages.

## Invariants

- **I1 -- Representation identity:** Work, recording identity, resumable bytes, and
  regenerable artifacts are isolated by storage generation, clip ID, and canonical
  ETag. Equal id and byte length from different storage generations cannot join, hit
  cache, resume, display, or become incident evidence for one another. Any origin or
  validator change invalidates the demand before media is delivered or persisted. An
  unavailable generation cannot authorize listing, pull, recording, or finalization;
  operational status and preview remain available without claiming an identity.
- **I2 -- Bounded thumbnail demand:** A thumbnail by itself never requires a whole-clip
  pull. If full demand arrives while prefix work is outstanding, completed work is
  reused where possible and redundant outstanding work is cancelled. If full demand
  then disappears, remaining thumbnail interest returns to bounded work unless a usable
  full artifact already exists.
- **I3 -- One full pipeline:** Concurrent playback and incident demand for one identity
  performs at most one full pull and one remux. All interested consumers observe that
  result without starting competing pipelines.
- **I4 -- Independent consumer lifetime:** Cancelling one thumbnail, viewer, or incident
  interest does not cancel work still needed by another. Cancelling the final interest
  stops cancellable work and cleans temporary files.
- **I5 -- Safe artifact lifetime:** An artifact remains available while any consumer is
  copying, playing, or sharing it. Cache eviction, validator sweeping, and explicit clip
  removal defer destructive cleanup until active use ends.
- **I6 -- Evidence outranks cache:** A successful incident acquisition installs its
  artifact permanently before declaring the segment pulled. Remux failure preserves raw
  TS evidence, thumbnail failure remains cosmetic, and playback-cache failure cannot
  block incident preservation.
- **I7 -- Existing experience:** Playback retains cache hits, progress, preparing,
  Retry, sharing, self-heal, and removal-scoped cancellation. Incident saving retains
  background grace, overlapping-incident sharing, 404 handling, terminal-state
  persistence, and marked-segment thumbnails. Existing thumbnail cache tiers, bounded
  concurrency, cell identity protection, and prefetch lifecycle remain intact.

## Proof obligations

- **PO1 (I1-I3):** Deterministic concurrent tests prove that thumbnail, viewer, and
  incident demand for one identity shares full acquisition and thumbnail generation.
  Storage/wire tests prove generation survives ordinary restart, changes on namespace
  reset, enriches a legacy witness without lowering its high-water mark, and scopes
  list metadata, finalized events, snapshots, recording identity, and HTTP validators.
  Identical id/bytes from different generations cannot hit cache or satisfy an
  interrupted pull, viewer, or incident. Missing, wrong, and stalled recording mounts
  keep status and the initial event snapshot bounded with `storage_generation: null`;
  with the camera otherwise ready, matching readiness reports storage unavailable and
  list, pull, recording, and finalization fail closed. Recovery publishes one atomic
  non-null generation/readiness replacement before media operations succeed.
- **PO2 (I2, I4):** Tests prove full demand supersedes an outstanding prefix, one
  consumer can withdraw without disturbing others, and the final withdrawal cancels
  production and removes temporary artifacts. A gated escalation/de-escalation scenario
  proves that after the last full consumer withdraws, full production stops and a
  remaining thumbnail completes through a bounded path.
- **PO3 (I5):** Cache tests prove eviction, stale-validator cleanup, and deletion cannot
  remove an artifact during active use and complete after its final release.
- **PO4 (I6):** Incident tests prove artifact-before-record publication, persistence of
  the expected generation-scoped ETag, rejection of changed validators, raw fallback
  after remux failure, survival of cache-insert failure, cosmetic thumbnail failure,
  and balanced background assertions.
- **PO5 (I7):** Existing and adapted controller/reducer tests prove playback, incident,
  thumbnail, prefetch, deletion, and error presentation remain behaviorally unchanged.
- **PO6:** `just app-test`, `just app-lint`, `just app-build`, `just raspi-test`,
  `just raspi-check`, and `just docs-build` pass. A physical-iPhone incident capture
  while Home is visible shows one full pull/remux, successful permanent saving, and a
  later playback cache hit. Replacing or resetting the Pi recording namespace proves
  old cached or interrupted demand is rejected rather than displayed or saved.

## Non-goals

- Changing MPEG-TS media format, camera capture, ring eviction, or the Pi's role as
  recording source of truth.
- Making caches authoritative for incidents or migrating existing permanent incident
  artifacts.
- Fixing the separate incident-detail zero-size header layout warning.

## Accepted risks

- **AR1 -- Thumbnail latency during escalation:** Cancelling a prefix in favor of a full
  acquisition may delay that thumbnail until the full artifact is ready. Avoiding known
  duplicate 2.4 GHz work is preferred when a full consumer already needs the clip.
- **AR2 -- Regenerable cache invalidation:** Unifying the thumbnail representation may
  invalidate existing thumbnail-cache entries. They are disposable and regenerate on
  demand; permanent incident media is untouched.

## Rejected ideas

- **RI1 -- Incident-local reorder only:** Remuxing before incident thumbnail generation
  removes one transform but leaves concurrent thumbnail, viewer, and incident pulls and
  remuxes uncoordinated.
- **RI2 -- Post-hoc cache priming:** Publishing into another feature's cache after work
  finishes does not prevent the active race and creates direct cross-feature coupling.

## Implementation discretion

- Exact facade, progress-delivery, interest, and artifact-lease types are left to
  implementation, provided the identity, cancellation, and lifetime invariants hold.
- Internal task decomposition and thumbnail representation size are left to
  implementation; CPU-heavy transforms must remain off the main actor and concurrency
  tests must use controllable signals rather than timing sleeps.

## Implementation notes

- Active consumers keep private hard-link or copy leases rather than pinning cache entries.
- Legacy incident records decode into the reserved all-zero storage generation and never
  match live v4 namespaces.

## Follow Up

- On a physical iPhone, capture an incident while Home is visible and confirm one full
  pull/remux, permanent saving, and a later playback cache hit.
- On a physical Pi, reset or replace the recording namespace and confirm prior cached or
  interrupted phone demand is rejected rather than displayed or saved.
