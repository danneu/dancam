# ADR: Storage ring buffer and incident-lock model

- **Status:** Accepted
- **Date:** 2026-06-23
- **Owner:** raspi
- **Related:** root `AGENTS.md` (SD is source of truth; Wi-Fi preview + pull only;
  recording survives power loss); `2026-06-22-crash-safe-recording.md` (recording
  format, filesystem, and power-loss layers);
  `2026-06-22-app-pi-transport-and-api.md` (wire contract that consumes this
  storage service); `app/docs/design/2026-06-22-carplay-integration-surface.md`
  (voice/status/control surface that needs a low-latency lock call)

## Context

The camera unit records continuously to its own microSD card. That card is the
source of truth. The phone previews, browses, and pulls selected clips, but the
Wi-Fi link is never on the recording path and must not be treated as primary
storage.

Two accepted ADRs constrain this decision:

- `2026-06-22-crash-safe-recording.md` selects short MPEG-TS (`.ts`) segments,
  inline SPS/PPS, `fsync()` at segment close, a read-only root filesystem, and a
  separate journaled recording partition. It sketches a ring buffer: delete
  oldest segments as the card fills, but never delete incident-locked segments.
- `2026-06-22-app-pi-transport-and-api.md` fixes the observable wire contract:
  force-finalize on lock, reboot-crossing idempotency, pre-sync incident holds
  with `pending_resolution`, reference-counted union unlock, stable `ETag`s,
  and specific status/clip metadata fields. It deliberately delegates the
  storage internals to this ADR.

The Pi has no real-time clock. Wall-clock time arrives only when the phone calls
`POST /v1/time` or from a GPS module. Power can be cut without warning on every
engine-off. The storage model therefore has to preserve ordering without wall
time, recover from torn writes, protect incident footage without stalling the
recording path, and leave enough free space that recording never reaches a full
partition.

## Decision

Use a space-based segment ring buffer on the writable journaled recording
partition, with incident locks implemented as hardlinks. The filesystem is the
durable source of lock truth; the in-memory index is a rebuildable cache.

**On defaults and exact figures.** What this ADR *fixes* is the model: a space-based
ring, hardlink locks, a single-writer coordinator, and disk-as-truth rebuild. The
concrete numbers and shapes used to illustrate it -- the default percentages (2%
headroom, 40% global locked cap, ~25% per-incident ceiling), the 15 s/30 s incident
roll, segment length, the capacity/sizing tables, and the exact fsync step ordering in
the commit sequence -- are **design-time starting points to confirm and tune during
implementation, not frozen contract.** Where one of these becomes client-visible it is
owned by the transport ADR (e.g. `retention`), and that contract governs.

### On-Disk Layout

All paths live under `/rec/` on the writable recording partition, never on the
read-only root filesystem:

```text
/rec/
  segments/  seg-<seq>.ts
             seg-<seq>.jpg
  incidents/<id>/ incident.json
                  seg-<seq>.ts
  index/     index.log
             index.snapshot
  state/     state.json
             seen-keys.log
```

`segments/` is the ring. Each `seg-<seq>.ts` is a finalized 30-60 s MPEG-TS
segment. Each `seg-<seq>.jpg` is a cached first-keyframe thumbnail. Thumbnails
are generated off the storage coordinator and are regenerable on miss.

`incidents/<id>/seg-<seq>.ts` entries are hardlinks to the segment inodes locked
by that incident. `incident.json` stores durable incident metadata.

`index/` contains rebuildable cache state: an append-only `index.log` of
per-segment finalize records and periodic compacted `index.snapshot` files
written by atomic rename.

`state/` contains durable coordinator state, not cache state. `state.json`
stores `high_water_seq`, the boot-anchor table, and the eviction-floor mirror.
`seen-keys.log` is an append-only tombstone log for deleted incidents'
idempotency keys, retained for the reassociation window so retries after
`DELETE` cannot resurrect old incidents.

### Segment Identity And Time

`seq` is a single global monotonic integer, formatted at fixed width in the
filename. It is the stable segment ID and the total order. The transport returns
it as `current_segment_id`, `locked_segment_ids`, and clip `id`.

At boot, the recorder resumes at:

```text
next_seq = max(witnesses) + 1
```

The witnesses are:

- `state/state.json` `high_water_seq`
- max `seq` in `index.log`
- max `seq` hardlinked under `incidents/*/`
- max `seq` in `segments/` filenames

`high_water_seq` is the authoritative witness and is fsync'd as part of each
finalize commit. It is kept out of `index/` so losing the rebuildable index
cache cannot make the recorder reuse a deleted segment ID. Reusing a deleted
`seq` would alias that segment's immutable `ETag` and break resumable pulls.

Each `index.log` finalize record stores:

```text
{seq, boot_id, mono_start_ms, mono_end_ms, bytes, etag}
```

`boot_id` is the kernel boot UUID, also exposed as `X-Dancam-Boot-Id`.
`mono_*` values are `CLOCK_BOOTTIME` readings. `ETag` is derived only from
immutable segment facts, for example `"<seq>-<bytes>"`; it must not derive from
inode, mtime, incident path, or other volatile filesystem metadata.

Wall-clock time is derived, never a segment primary key. `state.json` stores a
boot-anchor table:

```text
boot_id -> {offset_ms, source: app|gps, state: provisional|frozen, bound_at}
```

When `POST /v1/time` lands, storage computes:

```text
offset_ms = epoch_ms - mono_at_receive
wall_start_ms = mono_start_ms + offset_ms
```

The transport may send an initial time and then an RTT-corrected value during
handshake. Storage therefore treats the current boot's offset as provisional
through the handshake and accepts the latest app value. The offset freezes only
when an evidence-grade wall value is first served to the client: a clip
`start_ms` with `time_approximate: false`, or an incident `window` returned by
`GET /v1/incidents`. `GET /v1/status` timestamps are explicitly exempt because
they are a live readout, not evidence-grade output. After freeze, later app
resyncs for the same boot are no-ops. GPS is the deliberate override and may
rebind a boot even after freeze.

Listings always order by `seq`, never by `start_ms`, so correcting wall time can
sharpen timestamps without reordering clips or changing which segments an
incident protects. Segments from a boot that never synced stay
`time_approximate: true`.

### Retention And Ring GC

Retention is primarily space-based. GC watches high/low free-space watermarks on
the recording partition. When free space falls below the low watermark, GC
deletes oldest-first until free space rises above the high watermark. Hysteresis
keeps GC from thrashing.

The recorder also reserves headroom: by default about 2% of the recording
partition, or a few segments, whichever is larger. Recording never consumes this
reserve. The safety valve fires at the reserve boundary, before the filesystem
hits 100% full.

GC deletes by oldest `seq` first, skipping protected segments. A segment is
protected when:

- its inode link count is greater than 1, meaning at least one incident
  hardlinks it; or
- its `seq` is at or above a persisted eviction floor from an unresolved
  pre-sync incident hold.

The thumbnail is dependent on the `.ts`, not an independent retention object.
It is deleted only with its segment and protected whenever the segment is
protected. `openThumb` regenerates a missing thumbnail.

GC is directory-driven and reconciled against the index. A segment present on
disk but missing from a lost index record is still a GC candidate and still
lockable.

The transport already exposes a `retention` setting. In this space-based model,
its enforceable meaning is a maximum-age ceiling, not a minimum guarantee. When
set, it is a secondary optional eviction trigger: GC also drops segments older
than the ceiling, oldest-first and with the same protected-skip rules, even when
space is healthy. It defaults to unset, which means pure space-based retention.
Because the ceiling compares derived wall times, it is best-effort for
never-synced footage.

### Incident Lock

Incident locks use hardlinks, never byte copies. Locking an incident links each
protected segment's inode into `incidents/<id>/`. `link()` is O(1) and journaled,
and the filesystem link count gives reference counting without separate
bookkeeping. Deleting an incident removes `incidents/<id>/`; segments still
hardlinked by another incident survive because their link count remains greater
than 1.

Locked bytes are the unique set of `.ts` inodes hardlinked by at least one
incident, counted once per inode even if multiple incidents share it. This total
is tracked incrementally and can be rebuilt at boot by unioning the inodes under
`incidents/*/`. `statvfs` free blocks measure ring/headroom pressure; the
locked-space cap is enforced against the unique locked-byte total.

Default incident span is 15 s pre-roll and 30 s post-roll, overridable by the
request. The protected interval is:

```text
[mark - pre_s, mark + post_s]
```

Pre-roll segments already finalized in the ring are linked immediately.
Post-roll keeps the incident open. Each future segment that finalizes inside the
window is linked synchronously in the finalize coordinator turn, before GC can
consider it, and `incident.json` is atomically rewritten in that same turn to add
the `seq` and refresh `pending_post`. The lock call does not wait for post-roll
time to pass. `extendIncident(id, post_s)` reopens or extends the window and
uses the same metadata rewrite discipline.

When the mark is in the current boot's open segment, storage force-finalizes the
open segment by closing it, fsyncing it, registering it, and opening a new one.
This makes the just-marked footage pullable within seconds. A past
`at_epoch_ms` mark needs no split because its footage is already finalized.
Force-finalize happens at most once per `idempotency_key`.

### Incident Commit Sequence

All mutations run in the single-writer storage coordinator. Every directory
mutation is followed by an `fsync()` of the containing directory.

1. Dequeue the lock and check the in-memory idempotency map, rebuilt from live
   `incident.json` files and `state/seen-keys.log`. A live hit returns the
   existing incident with no side effects. A tombstone-only hit returns the
   original `incident_id` with `deleted: true`, empty `locked_segment_ids`,
   `window: null`, `pending_post: false`, and `pending_resolution: false`, also
   with no side effects. Both cases short-circuit before force-finalize.
2. Create `incidents/<id>/`; write `incident.json` with
   `status: "committing"`, the idempotency key, mark, pre/post settings, source,
   and note; fsync the file and `incidents/`. The idempotency key is durable
   before any side effect.
3. If the mark is in the current open segment, call `forceFinalizeCurrent()`.
   Re-finalizing an already-final segment is a no-op.
4. Hardlink finalized in-span segments into the incident directory, tolerating
   `EEXIST` only after verifying the inode. Link the mark segment first, then
   fill context outward subject to the per-incident ceiling and global cap. Fsync
   `incidents/<id>/`.
5. Rewrite `incident.json` to `status: "locked"` with the window,
   `locked_segment_ids`, and `pending_post` by writing a temp file, fsyncing it,
   renaming it into place, and fsyncing the incident directory. This is the
   commit point.
6. Register any open post-roll window, emit `incident_saved`, and return.

Recovery treats `status: "committing"` as a saga to rerun from steps 3-5; all
steps are idempotent. `status: "locked"` is already committed. A mark stored as
`(boot_id, mono)` from a prior boot resolves to already-finalized prior-boot
segments after reboot, so recovery links without splitting current footage.

`DELETE /v1/incidents/{id}` first appends `{idempotency_key, incident_id, seq}`
to `state/seen-keys.log` and fsyncs it, then removes the incident directory.
That preserves dedupe and deleted-incident replay across reboot.

### Pre-Sync Incident Holds

If an `at_epoch_ms` lock arrives before time sync, storage cannot yet resolve the
wall-clock mark to a monotonic segment window. It still accepts the lock and
preserves footage:

- Create the incident with `status: "pending_resolution"`.
- Persist `protect_floor_seq = min seq currently in ring` in `incident.json` and
  mirror it in `state.json`.
- GC refuses to evict any `seq` at or above the minimum floor across pending
  incidents.
- The client-visible response is `pending_resolution: true`, `window: null`, and
  an empty `locked_segment_ids` list. The all-in-ring hold is internal and is
  never exposed as the incident segment set.

When `POST /v1/time` lands, storage binds or refines the current boot anchor,
then resolves pending incidents whose candidate boots are all anchored. Resolution
hardlinks the matching segments, rewrites `incident.json` to `locked`, clears
that incident's eviction floor, and emits `incident_resolved`.

If a pending lock becomes provably unresolvable, it transitions to a durable
terminal state with `coverage_truncated: true` and releases its floor. This
happens when the mark predates the earliest wall-anchored footage and can only
belong to an ended, never-synced boot, or when the relevant boot is anchored but
the target segments are no longer in the ring. The app observes this via
`GET /v1/incidents`; pushing it over SSE requires a companion transport change
because the accepted transport ADR defines `incident_resolved` as a successful
"safe to read/pull now" event.

If honoring a pre-sync eviction floor would breach the headroom reserve because
the phone never synced for an entire card fill, recording continuity wins. GC
resumes oldest-first eviction, marks each breached pending incident
`coverage_truncated: true`, and emits a loud storage warning. The loss is
durable and visible, never silent.

### Locked-Space Caps

Two caps keep locked footage from starving recording:

- Global locked cap: default 40% of the recording partition.
- Per-incident ceiling: default about one quarter of the locked budget.

Both caps are measured against unique locked `.ts` inodes and are checked at
every link: initial pre-roll, lazy post-roll, and extension.

Initial seating is privileged. Storage links the mark segment first, then adds
nearest context outward until the per-incident ceiling or global cap stops it.
If seating that bounded initial incident would breach the global cap and other
incidents exist, storage evicts oldest other incidents until the cap is restored,
after a durable warning. The marked moment is preserved; excessive pre-roll or
post-roll is clamped and records `coverage_truncated: true`.

Ongoing growth is not privileged. Lazy post-roll and `extendIncident` clamp the
growing incident instead of evicting older incidents. When the next link would
breach either cap, storage stops linking future context and records
`coverage_truncated: true`. A long-running or repeatedly extended incident cannot
consume the evidence store one segment at a time.

The app is still expected to pull and delete incidents to free budget. Eviction
and truncation are backstops.

### Index, Listing, And Rebuild

The in-memory index is a sorted segment table plus an incident table. It is a
cache and can be rebuilt from disk.

`listClips(from, to, limit, cursor, order)` filters by resolved wall time or a
monotonic estimate before sync, pages by `seq`, and returns finalized segments
only:

```text
{id, start_ms, dur_ms, bytes, locked, etag, time_approximate}
```

`locked` is derived from link count. The open segment is not listed until natural
rollover or force-finalize.

On boot, the coordinator rebuilds state by:

1. Scanning `segments/*.ts` for `seq` and file sizes.
2. Replaying `index.log` and `index.snapshot` for boot and monotonic metadata,
   parsing TS PTS for any segment missing a record.
3. Scanning `incidents/*/` and `state/seen-keys.log` to rebuild incidents,
   idempotency state, and eviction floors. Hardlinks are the lock truth.
4. Reconciling torn state: drop index entries with no file; discard a torn final
   `index.log` record; keep a truncated power-cut tail segment if it is valid TS
   up to the cut and finalize it into a normal segment.
5. Rebuilding each incident's `locked_segment_ids` from hardlinks and
   re-deriving `pending_post`. Post-roll from an ended boot is closed; only a
   current-boot incident still inside its window remains open.

Losing `index.log` and `index.snapshot` loses only cache convenience. Footage,
lock state, and dedupe survive through `segments/`, `incidents/`, `state.json`,
and `seen-keys.log`. Losing boot anchors degrades affected clips to
`time_approximate`. Losing `state.json` degrades safely except for the
`high_water_seq` aliasing risk, which is why `high_water_seq` is fsync'd as
durable state and included in the max-of-witnesses rule.

### Concurrency Model

A single-writer storage coordinator owns all mutations to the index and to the
`segments/` and `incidents/` trees: segment finalize/register, GC unlink,
incident link/unlink, post-roll linking and metadata rewrite, pending-hold
binding, time-sync resolution, `applySettings`, and `format`.

Recorder byte streaming stays outside the coordinator. The recorder enters the
coordinator only for the small finalize/register step, keeping the realtime write
path clear of GC, listing, and incident operations.

`applySettings` is an ordinary serialized coordinator operation. `format` is a
stop-the-world coordinator operation: it quiesces the recorder, drains GC and
post-roll work, wipes `segments/`, `incidents/`, and `index/`, resets `state/`,
carries `high_water_seq` forward, and resumes recording. A format deletes
footage but never makes segment IDs alias.

Thumbnail generation runs off the coordinator, either by an async worker reading
a finalized segment or by a hardware-JPEG grab from the lores stream. A missing
thumbnail is regenerated on demand.

Media reads do not go through the coordinator. A reader opens the segment fd and
streams it directly; POSIX unlink semantics keep an already-open fd readable even
if GC unlinks the directory entry. A stale listing that loses the race to GC gets
a clean 404 and can re-list or resume by `ETag`. The service caps concurrent or
idle pull fds and treats unlinked-but-open bytes conservatively in GC accounting.

This serialization closes the named races: GC vs lock, GC vs post-roll,
GC vs reader, concurrent locks, and lock during finalize.

### Capacity And Sizing

Let:

```text
C = recording partition bytes
B = encode bitrate in bits per second
L = segment length in seconds
H = headroom reserve fraction
K = locked-space cap fraction
```

Then:

```text
segment_size      ~= B * L / 8
headroom          =  C * H
locked_budget     =  C * K
ring_bytes        =  C * (1 - H - K)
ring_retention    =  ring_bytes / (B / 8)
segments_in_ring  =  ring_bytes / segment_size
index_ram         ~= segments_in_ring * 100 bytes
```

At 1080p30 H.264, 10 Mbps, 30 s segments, H = 2%, and K = 40%:

| Card | C after OS/root | Headroom | Locked budget | Worst-case unlocked ring | No-incident ring |
|---|---:|---:|---:|---:|---:|
| 128 GB | ~112 GB | ~2.2 GB | ~45 GB (~10 h) | ~65 GB (~14 h) | ~110 GB (~24 h) |
| 256 GB | ~232 GB | ~4.6 GB | ~93 GB (~20 h) | ~135 GB (~30 h) | ~227 GB (~50 h) |

A 30 s segment at 10 Mbps is about 37.5 MB. A 45 s incident
(15 s pre-roll + 30 s post-roll) is about 56 MB. On the 256 GB example, the
locked budget holds roughly 1,650 such incidents, and the worst-case ring holds
about 3,600 segments. The RAM index is only a few hundred KB.

Only bitrate and retention are currently on the transport settings surface.
Segment length, global locked cap, per-incident ceiling, and headroom reserve are
storage-internal configuration until a future transport ADR exposes them.

### In-Process Service Interface

The transport layer consumes this in-process interface. This is not a wire
protocol definition.

```text
StorageService:
  listClips(from?, to?, limit, cursor, order)
      -> { clips:[{id,start_ms,dur_ms,bytes,locked,etag,time_approximate}],
           next_cursor, server_time_ms }
  listIncidents(limit, cursor)
      -> { incidents:[IncidentMeta], next_cursor }
  storageStatus()
      -> { used, total, locked, oldest_ts, newest_ts,
           current_segment_id, last_incident_id, time_synced }
  syncState()
      -> { time_synced, anchor_state, has_gps }

  openClip(id)
      -> { stream, bytes, etag, content_type:"application/mp2t" }
  openThumb(id)
      -> jpeg bytes

  lock({ idempotency_key, mark:(at_epoch_ms | "current"),
         pre_s?, post_s?, note?, source })
      -> IncidentMeta { incident_id, locked_segment_ids, window,
                        pending_post, pending_resolution,
                        coverage_truncated, deleted? }
  extendIncident(id, post_s) -> IncidentMeta
  deleteIncident(id) -> { released_segment_ids }

  applySettings({ retention?, ... })
  format({ confirm:"FORMAT" })

  onTimeSync({ epoch_ms, source, mono_at_receive })

  onSegmentFinalized(seq, boot_id, mono_start, mono_end, bytes)
  forceFinalizeCurrent() -> seq
  currentSegmentId() -> seq

  events:
    incident_saved | incident_resolved | storage_full | recording_stopped
    (+ internal segment_finalized)
```

Endpoint mapping is one-to-one for storage-touching operations:

- `GET /v1/status` -> `storageStatus`, `currentSegmentId`, `syncState`
- `GET /v1/capabilities` time/anchor slice -> `syncState`
- `GET /v1/clips` -> `listClips`
- `GET /v1/clips/{id}` -> `openClip`
- `GET /v1/clips/{id}/thumb` -> `openThumb`
- `POST /v1/incidents/lock` -> `lock`
- `GET /v1/incidents` -> `listIncidents`
- `POST /v1/incidents/{id}/extend` -> `extendIncident`
- `DELETE /v1/incidents/{id}` -> `deleteIncident`
- `POST /v1/time` -> `onTimeSync`
- storage-relevant `GET`/`PATCH /v1/settings` fields -> `applySettings`
- `POST /v1/storage/format` -> `format`
- `POST /v1/recording/stop` force-finalize -> `forceFinalizeCurrent`

`lock(current, source)` is the single low-latency, trigger-agnostic call the
CarPlay ADR needs. `source` is opaque metadata and must not affect idempotency or
force-finalize logic.

### Constraint Reconciliation

This ADR honors the crash-safe recording ADR by keeping `.ts` segments, 30-60 s
segment boundaries, force-finalize as close/reopen, all recording state on the
journaled partition, fsync discipline, read-only root safety, and "at most the
last partial segment is lost." It extends that ADR with directory fsyncs and the
concrete ring/lock mechanism.

This ADR honors the transport ADR by providing:

- force-finalize once per idempotency key
- reboot-crossing idempotency with the key durable before side effects
- pre-sync incident holds with `pending_resolution: true`, `window: null`, and
  empty `locked_segment_ids`
- RTT-corrected `POST /v1/time` refinement before evidence-grade freeze
- reference-counted union unlock
- stable `ETag`s for immutable segments
- `current_segment_id`
- clip metadata including `time_approximate` and post-sync `start_ms` correction
- the accepted SSE event set, without redefining failure semantics for
  `incident_resolved`

This ADR also reconciles the five cross-cutting principles:

- SD is truth: disk segments and incident hardlinks are authoritative; the phone
  only reads and requests locks.
- Wi-Fi is preview + pull only: pre-sync holds never expose the whole ring as a
  segment list, and clip reads are by ID and resumable.
- CarPlay is voice/status/control: storage offers a fast source-agnostic lock
  call, not video.
- Recording survives power loss: journaled link/rename, file and directory fsync,
  disk-truth rebuild, reboot-crossing idempotency, persisted floors, and TS tail
  recovery all assume abrupt power loss.
- Thermals stay bounded: storage is I/O and small metadata work; thumbnails are
  generated off the coordinator and do not add H.264 encode load.

### Transport Companion Prerequisites

The transport ADR remains the canonical wire contract. This ADR introduces or
clarifies storage facts that must be documented there before the app can rely on
them contractually:

- `IncidentMeta.coverage_truncated`, returned by lock and incident listing.
- The optional `deleted` marker returned only for a tombstone-hit replay after an
  incident was deleted.
- The lock `source` input, or a statement that transport sets it from invocation
  context instead of accepting it from the wire body.
- `retention` semantics: a max-age duration with ceiling semantics on top of the
  space-based ring.
- A terminal SSE event or terminal variant for unresolved/truncated incidents, if
  the product wants push delivery. The current storage design does not redefine
  `incident_resolved`, because that event already means "precise window bound,
  safe to read/pull."

Until those companion updates land, additive fields can serialize harmlessly, and
truncation remains observable through `GET /v1/incidents` and `storage_full`, but
the app contract is not complete.

> **Update (2026-06-23):** These companion updates have **landed** in the transport
> ADR's *Storage companion fields* subsection: `coverage_truncated`, the `deleted`
> tombstone marker, Pi-side-set `source`, and `retention` max-age ceiling semantics are
> now part of the canonical wire contract. The dedicated terminal-incident SSE event
> stays deferred there by mutual agreement (`incident_resolved` keeps its single
> meaning). The wire contract and this ADR now agree.

## Consequences

- The ring adapts to card size and bitrate, and recording never depends on the
  phone or Wi-Fi link.
- Incident lock/unlock is O(number of segments in the requested window), avoids
  byte copies, and gets reference counting from the filesystem.
- The design is robust to abrupt power loss, including a cut during an incident
  lock, a cut before time sync, and a cut after the index cache is partially
  written.
- `high_water_seq` becomes durable state, not cache. This is a small fsync cost at
  finalize time, but it prevents segment ID and `ETag` aliasing after GC.
- The no-RTC story is explicit: `seq` orders footage, monotonic timestamps
  describe per-boot placement, and wall time is evidence-grade only after an
  anchor is frozen.
- Space pressure is explicit and bounded. Incident storage can evict or truncate
  with a durable signal, but it cannot starve the recorder.
- The app and transport docs need companion updates before new fields such as
  `coverage_truncated` are part of the canonical wire contract.

## Alternatives considered

- **Time-based retention as the primary trigger.** Rejected. A fixed-size card and
  variable bitrate cannot guarantee a minimum time window, and a primary
  time-based policy can still fill the partition. Space-based watermarks protect
  recording. A max-age `retention` ceiling remains useful as a secondary trigger.
- **Copy locked bytes into incident folders.** Rejected. Copies are slow, multiply
  writes on flash, and create power-loss windows where the copy and ring disagree.
  Hardlinks are O(1), journaled, and keep one inode as truth.
- **Sidecar flag only for locks.** Rejected. It requires separate reference-count
  bookkeeping and makes rebuild depend on metadata being perfectly current.
  Hardlinks make the filesystem itself the reference count.
- **Per-segment sidecars or wall-time filenames.** Rejected. Sidecars double inode
  and fsync churn, and wall-clock filenames do not work before time sync. The
  append log plus `seq` filenames gives stable order with minimal hot-path work.
- **SQLite as the primary index.** Rejected for v1. It can work, but a flat journal
  plus filesystem truth is simpler on a 512 MB Pi and easier to rebuild after a
  torn write. A future implementation can revisit SQLite if query complexity
  grows.
- **Refuse new incidents when the locked cap is full.** Rejected. The just-marked
  moment is the user reacting now and should be saved if any bounded policy can
  make room.
- **Always evict oldest incidents for cap pressure.** Rejected. It is right for
  initial seating of a marked moment, but wrong for lazy post-roll or repeated
  extends, where one runaway incident could erase the evidence store over time.
- **Clamp only the growing incident.** Rejected as a complete policy. It protects
  older evidence, but would fail the live "save that clip" case when the cap is
  already full of old incidents. The adopted phase split handles both cases.
- **Global cap only.** Rejected. One very large incident could consume the entire
  locked budget. The per-incident ceiling limits blast radius.
- **Per-boot ordinal segment IDs.** Rejected. It complicates stable clip IDs and
  ETags across reboot. A single global `seq` is simpler and gives one total order.
- **Fine-grained locks instead of one coordinator.** Rejected. The mutation rate is
  low and operations are small. A single writer is easier to reason about and
  closes GC/lock/post-roll races directly.
- **Move locked clips out of the ring.** Rejected. Moving adds rename/copy
  complexity and makes clip paths unstable. Keeping the ring path and hardlinking
  incidents keeps stable segment IDs while protecting locked inodes.
