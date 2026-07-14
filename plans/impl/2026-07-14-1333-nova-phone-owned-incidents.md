# Plan: Swoop `nova` -- phone-owned incidents (iPhone-only press-to-save)

The "Incident" button: while connected and recording, one tap on the app Home
screen saves the moment -- roughly 30 s before the press plus 15 s after it --
by downloading the covering segments from the Pi into permanent phone storage.
The incident is a phone artifact: it starts `pending`, the app auto-finalizes
it by pulling each covering segment as it finishes on the Pi, and a local
notification nudges the user to reopen the app if the save could not finish
before they left. A new Incidents tab lists incidents, plays and shares their
footage, and deletes them.

**The Pi is not modified. The wire contract is not modified.** The feature is
built entirely from surfaces that already exist: the clips list, the resumable
ranged clip pull, and the `/v1/events` stream. There are no new endpoints, no
new events, no Pi-side state, and no mutation of the Pi at all -- the whole
feature is reads.

## Context

### Why phone-owned

The project stance (root `AGENTS.md`) is that the app owns the product
experience and the Pi is deliberately dumb: capture, encode, store safely,
serve footage on request. An incident is footage the user wants to *keep* --
and the phone is the better home for kept footage than the Pi's microSD:

- It leaves the car. Card death, card corruption, or theft of the unit after
  an incident cannot take the saved footage with it.
- It is in the user's pocket and in their iCloud backup.
- Phone storage is effectively unbounded next to the ring, so there is no
  locked-space cap, no reclamation policy, and no interaction with ring GC.

The ring is the buffer that makes this safe. GC evicts oldest-first
(`raspi/docs/design/21-2026-07-10-ring-gc-drip-eviction.md`), and an
incident's segments are by definition the newest data in the ring, so they
are last in line for eviction. Retention is ~24-50 *recording* hours; the Pi
only records while powered in the car, so in wall-clock terms an incident's
footage survives days to weeks of normal driving. The download deadline is
generous, and the common case completes within ~2 minutes of the press.

This decision supersedes the Pi-side incident-lock model (hardlink locks,
`POST /v1/incidents/lock`, idempotency tombstones, locked-byte caps) recorded
in `raspi/docs/design/03-2026-06-23-storage-ring-buffer-incident-lock.md` and
the incident surface reserved in both transport ADRs. The docs commit records
the supersession; see Part A. The one genuine regression versus a Pi-side
lock -- footage rolls off if the user never reconnects within retention -- is
accepted for v1, mitigated by the notification nudge, and has a cheap future
hardening path (a protect-only pin endpoint; the wire contract already
reserves `locked` on clip bodies) that we will build only if evidence demands
it.

### What already exists (the seams this plugs into)

- **Clips list**: `app/DanCam/DanCam/Networking/ClipsClient.swift#ClipsClient`
  fetches `GET /v1/clips` (cursor-paged, newest-first by id);
  `Networking/ClipsResponse.swift#Clip` carries `id` (the segment seq),
  `bootTag`/`session` (`Clip.recordingID`), `durMs`, `bytes`, `etag`.
  `Features/Clips/ClipsFeature.swift` holds the folded list and refetches the
  head on every snapshot.
- **Clip pull**: `Networking/Clips/ClipPullClient.swift#ClipPullClient.pull`
  is cache-independent: it streams a raw `.ts` to a temp file with resumable
  `Range`/`If-Range` replay and bounded retries, terminating in
  `.completed(ClipPullResult)`.
- **Remux + playback + share**: `Media/ClipRemuxer.swift#ClipRemuxer`
  (TS -> MP4), `AVPlayerViewController` playback, and the share-sheet
  clone-to-friendly-name pattern in
  `Features/ClipViewer/ClipViewerViewController.swift#makeShareArtifact`.
- **Recorder truth**: `Features/Connection/Link.swift#Link` folds the SSE
  snapshot and deltas; `Networking/Events/CameraEvent.swift#RecorderSnapshot`
  exposes `phase`, `session`, and `currentSegment` (`RecorderSegment`:
  `id`, `durMs`).
- **Thumbnails**: `Media/ThumbnailDecoder.swift` decodes a JPEG from raw TS
  prefix bytes.
- **TEA architecture**: caseless-enum features with `State`/`Action`/`reduce`,
  `App/AppDependencies.swift#AppDependencies` struct-of-closures with `.noop`
  defaults, and `DanCamTests/Support/TestStore.swift#TestStore` for reducer
  tests.

### What deliberately does not exist in v1

No retroactive marks, no offline press queue (the button is disabled unless
connected + recording), no extend, no stitched multi-segment export, no
save-to-Photos automation (the share sheet covers it), no background
`URLSession` transport, no Pi-side pin. Each is a follow-up, not a stub --
see Follow-ups.

## Decisions

- **Incidents are phone-owned artifacts; the Pi stays read-only.** No new
  endpoints or events; no `Idempotency-Key` anywhere because nothing mutates.
  Recorded as app ADR 26 with amendment notes on the superseded ADRs (Part A).
- **Window = `[press - 30 s, press + 15 s)`**, satisfied by whole segments
  (never trimmed); coverage is a superset of the window and is presented as
  approximate. A +-2 s slack widens the window at both edges to absorb mark
  anchoring error; over-grabbing a whole segment is cheap and safe.
- **The mark is `(recordingID, markSeq, markAgeMs)`** captured at press from
  folded state plus an observation anchor (Part C). No Pi clock math: the
  wanted segment set is derived by walking segment durations outward from the
  mark, so it is correct for any segment length (30 s real, 5 s mock).
- **Press requires connected + recording with a known open segment.** The
  button is disabled otherwise; a missed mark is recoverable from Recent
  clips. It does not require the clips list to have loaded -- capture is
  decoupled from list freshness; resolution catches up.
- **Durable before side effects**: the press persists the incident record to
  disk before any download or UI beyond the button feedback. A crash a moment
  after the press loses nothing; the reconciler resumes from the record.
- **Lifecycle: `pending -> saved | partial`**, both terminal.
  - `saved`: every wanted segment that was ever *witnessed* (resolved with an
    etag from the clips list or a `clip_finalized` event) has been pulled.
    Window edges clipped by the session boundary (recording started < 30 s
    before press, or stopped inside the post-roll) still count as `saved` --
    the footage never existed, nothing was lost; the row shows the true
    covered duration.
  - `partial`: footage that existed was lost before it could be pulled --
    a witnessed segment evicted or user-deleted from the ring, a
    never-witnessed interior seq proven to have existed by session
    contiguity, or the mark segment vanishing with a power cut. Whatever
    was salvaged is kept.
- **Downloads are foreground-first, resumable forever.** Pulls run while the
  app is open (plus a short best-effort background-task grace); anything
  unfinished resumes on the next foreground/reconnect. A local notification
  scheduled at press and cancelled on completion nudges the user to reopen
  the app. No background `URLSession` in v1 (the app's transport is a
  hand-rolled HTTP/1.1 over pinned `NWConnection`, per app ADR 02; migrating
  incident pulls to a background session is a follow-up with real unknowns).
- **Incident bytes live in Application Support**, not the purgeable caches
  directory and not the LRU-bounded `ClipCache`: `Incidents/<uuid>/` with a
  self-describing `incident.json`, one remuxed `.mp4` per segment, and a
  `thumb.jpg`. Filesystem-as-index, matching the `ClipCache`/`ThumbnailCache`
  idiom -- no SwiftData, no separate index file to drift. Included in iCloud
  backup (it is user data).
- **Per-segment artifacts are remuxed `.mp4`** (playable and shareable
  as-is, same lossless container conversion the viewer already trusts). If a
  remux fails, the raw `.ts` is kept instead for that segment -- bytes are the
  evidence; that segment is share-only in the UI.
- **No cap, no auto-cleanup on the phone.** The tab header shows count and
  total bytes; the user deletes incidents. Phone storage pressure is the
  OS's and user's problem at v1 scale (an incident is ~40-115 MB).
- **Press cooldown, not a lockout.** The button disables for ~3 s after a
  press (accidental double-tap guard). Overlapping incidents are allowed and
  simply share segment pulls; there is no coverage-gap concern because
  nothing on the Pi is consumed by a press.
- **Exact incident timestamps for free.** `pressedAt` is the phone's own
  wall clock -- no time-provenance dependency, no "time unverified" treatment
  on incident rows. (Per-clip footage timestamps still come from clip
  metadata and stay approximate as today.)

## Accepted risks

- **A never-witnessed edge seq with no surviving lower same-session witness
  is classified `clipped`, though it could have been evicted before it was
  ever witnessed.** Absence alone cannot distinguish "session started here"
  from "everything below was evicted" without Pi-side session-extent
  metadata. The window is narrow (requires pressing with a stale/empty
  clips state and then staying away long enough for eviction to reach the
  incident's own seqs, i.e. days of driving), and misclassification fails
  toward a quieter label on footage that was salvaged either way. Not worth
  new wire surface in v1.
- **Footage rolls off if the user never reconnects within retention** (days
  to weeks of driving; see Context). Mitigated by the nudge notification;
  the protect-only pin endpoint is the future hardening path if evidence
  ever demands it.

## Shared design

### Incident record and on-disk layout

```
<Application Support>/Incidents/
  <uuid>/
    incident.json      # atomic writes (temp + rename via Data .atomic)
    seg_00041.mp4      # remuxed segment artifacts, named by seq
    seg_00042.mp4
    seg_00043.ts       # raw fallback kept only if that segment's remux failed
    thumb.jpg          # decoded from the mark segment's TS prefix at pull time
```

`incident.json` (Codable; facts, not conclusions):

```json
{
  "id": "9F3A2C1E-...",
  "pressed_at_ms": 1784480523000,
  "boot_tag": "7f3a91c2b0d4",
  "session": 7,
  "mark_seq": 43,
  "mark_age_ms": 12000,
  "pre_ms": 30000,
  "post_ms": 15000,
  "slack_ms": 2000,
  "status": "pending",
  "wanted": [
    { "seq": 41, "state": "pulled", "etag": "41-38012345", "dur_ms": 30016, "bytes": 38012345 },
    { "seq": 42, "state": "wanted", "etag": "42-1048576", "dur_ms": 29984 },
    { "seq": 43, "state": "unresolved" }
  ]
}
```

The store is a small actor (`IncidentStore`, mirroring the
`Media/ClipCache.swift#ClipCache` actor shape): `list()` scans the directory
at launch, `create`/`update` write `incident.json` atomically, `delete`
removes the directory. A directory with an unreadable `incident.json` is
surfaced in the tab as unreadable with a delete affordance, never silently
skipped and never auto-removed (its media files may still be good; the user
decides).

The directory is a recoverable state machine, with the artifacts as ground
truth and the record catching up to them. One ordered publication protocol
makes a final artifact name safe to trust:

1. **Resolution is durable before install.** Witnessing persists the entry
   as `wanted(etag, dur_ms)`, and no pull or clone for a segment starts
   until that persist has landed (the same durable-before-side-effects
   posture as the press itself). The walks need every included segment's
   duration, so `dur_ms` riding the record keeps relaunch planning
   computable after the source clip has left the ring -- and this ordering
   makes "artifact paired with an `unresolved` entry" unrepresentable, even
   for the fast cache-hit clone path.
2. **Final names are published only by atomic rename.** Every install path
   (pull + remux, raw `.ts` fallback, cache-hit clone) writes to a sibling
   staging name in the incident directory (`seg_<seq>.mp4.part`) and
   publishes with a same-directory rename. A partial write can therefore
   only ever be a staging file; a present final artifact
   (`seg_<seq>.mp4|ts`) is complete media. No metadata beyond the name is
   needed: pulls are `(seq, etag)`-addressed and finalized segments are
   immutable.
3. **`pulled` is persisted after the rename.** A record claiming `pulled`
   without bytes would be a lie; the artifact leads, the record catches up.
4. **Scan reconciles final artifacts into the record before any planning.**
   If `list()` finds a final artifact for an entry not marked `pulled`, the
   entry is upgraded to `pulled` (bytes from the file) and the repaired
   record is persisted -- no re-pull, and a Pi clip that vanished in the
   meantime cannot demote footage already on disk to `lost`. Staging files
   are deleted on scan and never promoted. A missing `thumb.jpg` after such
   a crash is cosmetic (placeholder row), not a correctness concern.

### Mark capture

`World.folding` currently discards `segment_opened`'s `atMs` and keeps only
`RecorderSegment(id:durMs:)`; there is no stored anchor for how old the open
segment is. Press capture adds a lightweight anchor owned by the incidents
feature (Link/World stay untouched): `IncidentsFeature.State.openSegmentAnchor`
-- `(recordingID, seq, seedDurMs, observedAt: ContinuousClock.Instant)` --
updated in the reducer whenever a folded snapshot or `segment_opened`
changes the open segment identity (the reducer reads the injected clock from
dependencies, so tests control it).

At press: `markAgeMs = seedDurMs + (now - observedAt)`. Error sources are SSE
delivery latency and snapshot staleness, both sub-second in practice; the
+-2 s window slack absorbs them. The design is also tolerant of a rollover
race by construction: if the press lands just after a rollover the app has
not folded yet, the anchor attributes the press to the previous segment with
`markAgeMs` slightly past its duration -- the walk below still selects the
correct covering set, because it measures from `(mark open + markAgeMs)`,
not from "press was inside markSeq".

### The wanted-set planner (the core, a pure function)

`IncidentPlanner.plan(incidents, clips, listCoverage, recorder) -> [Command]`
-- pure and table-testable. For each pending incident it resolves the wanted
set incrementally, persisting every resolution:

- **Pre-roll walk (backward)**: `remaining = preMs + slackMs - markAgeMs`
  (clamped >= 0); for k = 1, 2, ... include `markSeq - k` while
  `remaining > 0`, subtracting each included clip's `durMs` as it is
  witnessed -- and persisted to the record as `dur_ms`, so the walk stays
  computable across relaunch without the clip still being listed. Pre-roll
  segments are already finalized at press, so this usually resolves fully
  (with etags) from the clips state at press time.
- **Post-roll walk (forward)**: `remaining = markAgeMs + postMs + slackMs -
  dur(markSeq)`; include `markSeq + j` while `remaining > 0`, resolving each
  as its `clip_finalized`/listing arrives. The mark segment itself resolves
  at its own finalize (rollover, <= one segment length after press).
- **Session clipping**: the walk stops at the recording session boundary.
  Backward: a wanted seq below the session's earliest witnessed seq that
  never appears under cursor-floor coverage (and has no witnessed
  same-session seq below it -- else the contiguity rule makes it `lost`)
  is `clipped` -- removed from the wanted set, window edge honest-shrunk. Forward: when the session is over
  (folded recorder identity differs from the incident's `recordingID`, or
  the recorder is no longer recording) and the seq never appears, it is
  `clipped`. Session-over is also the signal that no further resolution can
  arrive, forcing the incident terminal once pulls settle.
- **Loss evidence** (marks an entry `lost`; the incident will finalize
  `partial`). Three sources, one rule, no list-diffing:
  - **`clip_removed` fold**: the Pi emits `clip_removed` for user deletion
    and GC eviction alike (`raspi/service/src/backend.rs#fn note_clip_removed`,
    driven from both `clips.rs` delete and `gc.rs`), and the app already
    consumes it (`ClipsFeature.Action.clipRemoved`). While connected, this
    is real-time loss truth for any wanted seq -- *except the active pull*.
    `clip_removed` never preempts the pull in flight: the Pi streams from
    an already-open file descriptor
    (`raspi/service/src/clips.rs#fn serve_clip`), so an unlinked clip can
    still finish serving. The active
    entry resolves by the pull's own outcome -- `.completed` lands `pulled`
    (salvaged; terminal statuses never regress on the replayed removal),
    while a dropped connection resumes into a 404 and lands `lost` via the
    pull-404 rule. No pending-loss state is kept: if the pull fails for a
    non-404 reason, the entry returns to `wanted` and the very next retry
    404s into `lost`.
  - **Pull 404**: `ClipPullClient` fails typed (`ClipPullError.http(404)`).
    A 404 on a *resolved* entry (we hold an etag; finalized segments never
    un-finalize) means the clip was removed while the app was away -- the
    pull attempt doubles as the probe, no extra requests. All other pull
    failures stay retriable (`wanted`).
  - **Covered contiguity gap**: seqs are contiguous within a recording
    session, so a seq absent under list coverage with a *witnessed
    same-session seq below it* must have existed -- gone before it was ever
    witnessed. This is the only absence-based loss rule, and it is what
    gives never-witnessed interior gaps a terminal answer.

  The mark segment keeps its stronger rule: it was witnessed *open* at
  press, so if the session ends and it never finalizes (power cut took the
  in-flight segment), it is `lost`, not `clipped`. A `lost` entry whose
  duration was never witnessed ends that direction's walk -- coverage beyond
  it is uncomputable, and the incident is already `partial`; outer segments
  with known durations keep being salvaged.
- **List coverage**: absence is only evidence when the list actually covers
  the seq, and coverage is measured by the **cursor floor** of the current
  head epoch's response chain (`ClipsFeature.State.nextCursor` as the
  numeric lower bound, the same bound `reconciledHead` uses) -- never by
  merged entries. Paged responses merge without removing absent clips
  (`ClipsFeature.reduce` `pageResponse`), so entry *presence* can be stale;
  that is harmless, because a stale witness self-corrects through the
  pull-404 path. The planner emits `page` commands until the floor reaches
  the incident's lowest unresolved seq; until then, absent seqs stay
  `unresolved`. In the common case the head page covers everything.
- **Terminal rule**: no `unresolved` or `wanted` entries remain ->
  `saved` if nothing was `lost`, else `partial`. Terminal statuses are final;
  replayed events or stale lists never resurrect or regress an incident.

Commands are data: `persist(record)`, `pull(seq, etag, for: [incidentID])`,
`page(cursor)`, `finalize(incidentID, status)`, `cancelNudge(incidentID)`.
The reducer turns them into effects; the planner never touches IO.

### Downloads

One segment pull at a time, globally (the 2.4 GHz link is the bottleneck and
`ClipPullClient` already serializes bytes within a pull): the incidents state
holds a queue and an `activePull`; each completion re-plans. A segment is
queue-eligible only once its resolution persist has landed (publication
protocol step 1). A pull is `ClipPullClient.pull(seq, etag)` -> on
`.completed`, remux via `dependencies.clipRemuxer` -> install into every
wanting incident's directory via staging name + atomic rename (APFS
`copyItem` clones are instant and space-free; publication protocol step 2)
-> persist `pulled`. The mark segment's pull also decodes `thumb.jpg` from
the raw TS prefix via `Media/ThumbnailDecoder.swift` before the temp `.ts`
is discarded. Remux failure keeps the raw `.ts` as that segment's artifact
instead.

Deduplication: one pull serves every pending incident wanting that
`(seq, etag)`. If a wanted clip is already resolvable from `ClipCache`
(`lookup(id, etag)` hit, i.e. the user already watched it), clone the cached
`.mp4` into the incident directory (same staging + rename publication) and
skip the network entirely.

Failure handling: a pull that fails with `ClipPullError.http(404)` on a
resolved entry is loss evidence -- the entry goes `lost` (see the planner's
loss rules). Any other pull failure that exhausts `ClipPullClient`'s bounded
retries leaves the entry `wanted`; the next reconcile trigger retries it.
There is no retry counter to exhaust at the incident level -- the only
permanent failures are `lost` (footage gone) and `clipped` (footage never
existed), both evidence-driven.

Reconcile triggers (all funnel into one `.reconcile` action):
incident created; clips list changed (head load, page, `clip_finalized`
fold, or `clip_removed` fold); snapshot folded (covers reconnect and
session change); scene foregrounded; pull completed or failed.

### Notifications and lifecycle

A new `IncidentNotifier` dependency (struct-of-closures over
`UNUserNotificationCenter`, `.noop` default): `requestProvisionalAuth()`,
`scheduleNudge(incidentID, fireIn:)`, `cancelNudge(incidentID)`. Provisional
authorization (quiet delivery, no permission dialog) is requested lazily at
the first press.

- At press: schedule one nudge per incident at +3 minutes -- "Incident still
  saving -- open DanCam to finish." Cancel it when the incident goes
  terminal.
- On scene background with pending incidents: ensure the nudge is scheduled
  (idempotent), and take a best-effort `UIApplication` background-task
  assertion so an in-flight pull can finish in the ~30 s grace window. If it
  expires mid-pull, the pull fails and resumes on next foreground -- the
  resumable ranged pull makes interruption free.
- Terminal transitions while foregrounded show no notification (the UI shows
  it); the nudge is only for the walked-away case.

### UI surfaces

- **Home**: an Incident button in its own row of the existing `headerStack`
  (adjacent to `recordButtonRow` in
  `Features/Home/HomeViewController.swift#configureViews`). Enabled iff the
  link is online, the recorder phase claims recording, and an open segment
  anchor exists. Press: haptic, brief "Saving..." feedback on the row, 3 s
  cooldown. Failure to persist the record (disk full) shows a calm alert --
  the only press-time failure mode.
- **Incidents tab**: fourth top-level tab (built in
  `App/SceneDelegate.swift` alongside Home/Debug/Settings, tab order Home,
  Incidents, Debug, Settings). List rows: thumbnail, `pressedAt` (exact,
  phone clock), covered duration ("~45 s", whole segments), bytes, status
  (saving spinner / Saved / Partial badge). Header: count + total bytes.
  Unreadable incident directories appear as rows with a delete affordance.
  Swipe-to-delete with a destructive confirm (same pattern as
  `Views/ClipDeleteConfirmation.swift`).
- **Incident detail**: a new `IncidentDetailViewController` -- segment list,
  inline `AVPlayerViewController` playback of the local `.mp4`s, share via
  `UIActivityViewController` using the clone-to-friendly-name pattern, and
  Delete. It deliberately does not reuse `ClipViewerViewController`, whose
  orchestration is pull/cache-centric; local-file playback is simpler than
  what it does, not a subset worth entangling.

## Parts and commits

Strict order; every commit builds and passes its side's checks standalone
(`just app-build` + `just app-test`; `just adr-check` on the docs commit).

### Part A -- Commit 1: `docs(app): record phone-owned incidents`

- New `app/docs/design/26-2026-07-14-phone-owned-incidents.md` (Accepted):
  the decision, the eviction-risk analysis (driving-hours retention,
  oldest-first GC), the foreground-download posture and notification nudge,
  the wanted-set/evidence model, the storage layout, and the follow-up
  hardening path (protect-only pin endpoint; `locked` stays reserved on clip
  bodies).
- Amendment notes (append-only, pointing at app ADR 26):
  - `raspi/docs/design/03-2026-06-23-storage-ring-buffer-incident-lock.md`:
    the incident-lock model (hardlinks, `incident.json`, `seen-keys.log`,
    locked caps, commit sequence) is superseded; the ring, GC, witness, and
    crash-safety decisions remain in force.
  - `raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md`: the
    reserved `/v1/incidents*` endpoints and `incident_saved` /
    `incident_resolved` events are withdrawn.
  - `app/docs/design/02-2026-06-22-app-pi-transport-and-api.md`: the App
    Intents incident-lock / queue-and-flush obligations now describe a
    superseded direction (voice marking, if it ever lands, creates the local
    record and rides the same reconciler).
  - `raspi/docs/design/21-2026-07-10-ring-gc-drip-eviction.md`: the incident
    protection seam note stays as a seam, now unused by incidents.
  - `app/docs/design/01-2026-06-22-carplay-integration-surface.md`: the
    voice-marking dependency on a fast Pi "lock current buffer" control is
    withdrawn; voice marking creates the phone-local incident record and
    rides the same reconciler (no Pi call on the press path at all, which
    only improves the latency story).
- Root `AGENTS.md`: add a cross-cutting principle bullet -- incidents are
  phone-owned; the Pi serves footage, the phone keeps it -- linking app
  ADR 26. `app/AGENTS.md`: reword the incident-handling responsibility,
  provisional persistence, and ADR-summary lines.
  `raspi/AGENTS.md`: reword every line that states the Pi-lock model as
  current design -- the ring-buffer "incident-locked segments are exempt
  from deletion" line, the control-API surface mention of "incident lock",
  and the power/shutdown "prompt incident pull" framing -- and annotate its
  ADR-index summaries for ADRs 02/03/21 as partially superseded by app
  ADR 26 (living doc, so reworded in place; the append-only rule applies to
  the ADRs themselves).
- `docs/roadmap.md`: rewrite the `nova` entry (iPhone-only press-to-save,
  app-side checklist mirroring Parts B-F, mock-first); adjust the `sift`
  incidents-filter line (incident membership is phone-side state now), the
  `silt` protection-seam claim, the `moss` pre-sync-hold scope fence, and the
  `tide` "auto-save incidents" note; leave `pike` parked with a note that
  phone-owned incidents shrink it to "create the record by voice".

Exit: `just adr-check` green; the records match the decisions above.

### Part B -- Commit 2: `feat(app): incident model, store, and planner`

- `Features/Incidents/IncidentRecord.swift`: the Codable record, wanted-entry
  state machine (`unresolved -> wanted(etag, durMs) -> pulled | lost |
  clipped`), status derivation, covered-duration/bytes computed properties.
- `Features/Incidents/IncidentStore.swift`: the actor -- directory scan with
  artifact-to-record reconciliation (an artifact present for a non-`pulled`
  entry upgrades it to `pulled` and persists the repaired record before
  anything plans against it), atomic create/update, delete, unreadable-dir
  surfacing; wired into `AppDependencies` as a struct-of-closures client
  with `.noop` and `.live` (root under Application Support, injectable for
  tests).
- `Features/Incidents/IncidentPlanner.swift`: the pure planner (walks,
  evidence rules, clipping, terminal rule, command emission).
- Tests: planner table tests (the heart of the required coverage below) over
  synthetic clips lists at 30 s and 5 s segment durations; record round-trip
  and atomicity; store scan with a corrupted `incident.json`; the
  crash-boundary scan (artifact on disk, record entry still `wanted`, and
  the clip absent from every list the planner will see -> entry reconciled
  to `pulled`, incident can still finalize `saved`); an interrupted staging
  file (`seg_<seq>.mp4.part` left by a crash mid-install -> deleted on
  scan, never promoted, entry stays `wanted`).

Exit: `just app-build` + `just app-test` green; no UI yet, pure logic.

### Part C -- Commit 3: `feat(app): press capture`

- `IncidentsFeature` (State/Action/reduce) with `openSegmentAnchor`
  maintenance folded from snapshot/`segment_opened` actions forwarded by
  `AppFeature.reduce`; press action persists the record via `IncidentStore`
  (durable before any other effect), schedules the nudge, applies the
  cooldown, and emits the first `.reconcile`.
- Home button UI: `IncidentButton` row in `headerStack`, enablement
  projection, haptic, "Saving..." feedback, disk-failure alert.
- `IncidentNotifier` dependency (`.noop`/`.live`); provisional auth on first
  press.
- Tests: enablement matrix (offline / idle / no anchor / recording),
  persistence-before-effects ordering, anchor updates across snapshot and
  rollover, cooldown, the rollover-race press (anchor age past segment
  duration still yields a correct mark).

Exit: pressing in the simulator against `just raspi-mock` persists a pending
incident record (visible on disk); reducer tests green.

### Part D -- Commit 4: `feat(app): reconciler and downloads`

- Reconcile wiring: `AppFeature` forwards clips-list changes, `clip_removed`
  folds, snapshot folds, foreground, and pull completions into
  `IncidentsFeature.reconcile`; the planner's commands become effects
  (single-pull queue, paging requests via `ClipsFeature`, persistence,
  finalize, nudge cancel).
- The pull pipeline: `ClipPullClient.pull` -> remux -> install-by-clone
  (staging name + atomic rename) into each wanting incident dir ->
  thumbnail from TS prefix on the mark segment -> persist `pulled`;
  `ClipCache.lookup` short-circuit; remux-failure raw `.ts` fallback;
  background-task assertion around active pulls.
- Tests: end-to-end reducer tests with scripted clips/pull dependencies --
  the happy 3-segment save; resume after relaunch mid-download (no
  re-download of pulled segments); stop-recording inside the post-roll
  (clipped, `saved`); each loss-evidence source behaviorally: a
  `clip_removed` fold for a queued (not active) wanted seq (`lost`,
  `partial`), a pull 404 on a resolved entry after a scripted reconnect
  (`lost`, `partial`), and a covered contiguity gap that never resolves
  (`lost`, `partial`); the removal race ordering (`clip_removed` for the
  *active* pull, then the pull completes -> `pulled`, incident `saved`, no
  false `partial`); resolution persisted before the pull effect starts
  (ordering asserted for a fresh witness, including the cache-hit clone
  path); mark segment never finalizes after session death (`partial`);
  lost entry with unknown duration ends that direction's walk; shared
  segment across two overlapping incidents pulled once; non-404 pull
  failure retried on next trigger.

Exit: full save happens headlessly against `just raspi-mock` (5 s segments:
a press resolves ~7-8 wanted segments and lands them all in the incident
directory within ~a minute); tests green.

### Part E -- Commit 5: `feat(app): incidents tab and detail`

- Incidents tab in `SceneDelegate` (+ `AppShellViewControllerTests` update),
  list rows with live status projection, header totals, unreadable-dir rows,
  swipe-to-delete with destructive confirm.
- `IncidentDetailViewController`: segment list, local playback, share
  (friendly filename via `Formatters`), delete; share-only row treatment for
  a raw `.ts` fallback segment.
- Tests: row/projection state tests; delete removes directory and row;
  detail share-artifact naming.

Exit: full Mac-only pass -- press, watch the row finish saving, play, share,
delete -- against the mock Pi.

### Part F -- Commit 6: `feat(app): saving-state polish and nudge lifecycle`

- Nudge scheduling on background-with-pending, cancellation on terminal,
  Home "Saving..." row feedback tied to live incident state, Incidents tab
  badge while pending.
- Tests: notifier scheduling/cancel matrix across press, background,
  terminal, delete-while-pending.

Exit: walk-away flow verified manually -- press, background the app inside
~30 s, see the pull finish in grace or the nudge fire at +3 min, reopen,
watch the incident complete.

## Verification

Per-commit gates as listed above. End-to-end gate (after Part F): run
`just raspi-mock` (5 s segments), point the simulator at it via
`DANCAM_CAMERA_API_BASE_URL`, then:

1. Press while recording; watch the pending row appear instantly with exact
   press time, then fill in and flip Saved in ~a minute; confirm ~7-8
   segments in the incident directory and honest covered duration.
2. Kill the app mid-download; relaunch; confirm resume without re-pulling
   completed segments.
3. Press, then stop recording ~5 s later; confirm `saved` with clipped
   coverage (no post-roll padding, no `partial`).
4. Press, then delete a witnessed pre-roll clip from the Recent list before
   its pull; confirm `partial` with the survivors saved (exercises the
   `clip_removed` loss path live).
5. Delete an incident; confirm the directory is gone and (unlike a Pi-side
   lock design) the ring is untouched throughout -- clips list identical
   before/after.
6. Background the app immediately after a press; confirm the nudge fires at
   +3 min, and reopening completes the save.

Real-Pi validation (no new hardware surface, so a checklist, not a commit):
one 30 s-segment save end to end in the car; a press followed by cutting
power inside the post-roll, then confirming `partial` with the recovered
mark segment on next connect; a press followed by leaving Wi-Fi range and
completing on the next drive.

## Required regression coverage

Behavioral acceptance criteria, owned by the commits above:

- Planner walks: correct wanted sets at 30 s and 5 s segment durations;
  press early/late in the mark segment (post-roll crossing 0, 1, and many
  successors); pre-roll reaching exactly a boundary (slack included and
  excluded); session-start and session-end clipping; rollover-race press
  attribution.
- Evidence rules: absence without cursor-floor coverage stays `unresolved`;
  paging is requested until coverage; each loss source lands `lost`
  (`clip_removed` fold for non-active entries, pull 404 on a resolved
  entry, covered contiguity gap); `clip_removed` never preempts the active
  pull -- completion after removal salvages the entry as `pulled`;
  never-existed is `clipped`; mark-vanished-with-session is `lost`;
  a `lost` entry with unknown duration ends that direction's walk; terminal
  statuses never regress on replayed events or stale lists.
- Durability: record persisted before any post-press effect; resolution
  (`etag`, `dur_ms`) persisted before any pull or clone starts;
  atomic-write crash safety (torn temp never corrupts a readable record);
  final artifact names appear only via atomic rename from a staging
  sibling, and scan deletes staging files without promoting them; relaunch
  resume is idempotent (pulled segments never re-pulled, `(seq, etag)`
  keyed); the install-to-persist crash boundary heals via scan
  reconciliation (an installed artifact with a stale `wanted` entry and a
  vanished Pi clip still counts as `pulled` -- no re-pull, no false
  `partial`).
- Downloads: single-flight queue; dedupe across overlapping incidents;
  cache-hit clone path; remux-failure raw fallback; pull failure returns to
  `wanted` and retries on the next trigger.
- Notifications: scheduled at press, ensured on background-with-pending,
  cancelled on terminal and on delete.
- UI: enablement matrix; cooldown; delete removes bytes + row; unreadable
  directory surfaced, deletable, never auto-removed.

## Follow-ups (deferred, expected later)

- Protect-only pin endpoint on the Pi (`POST /v1/clips/{id}/pin`) if
  real-world use ever shows the retention window is too tight -- the clip
  `locked` field stays reserved for it.
- Background `URLSession` transport for incident pulls (survives suspension;
  needs a worked answer for the pinned-interface join).
- Voice marking via App Intents (`pike`, Icebox): create the record
  hands-free, same reconciler.
- Save-to-Photos automation; stitched multi-segment export; notes/rename.
- Incident membership badges in the Recent list (`sift`).

## Implementation notes

- Part A also updates the roadmap's stale `silt` protection-seam claim and
  `moss` pre-sync-hold scope fence so the living roadmap does not contradict
  the phone-owned incident decision.

## Commit progress

- [x] 1. docs + ADR + roadmap
- [x] 2. model, store, planner
- [x] 3. press capture
- [x] 4. reconciler + downloads
- [x] 5. tab + detail
- [ ] 6. polish + nudge lifecycle
