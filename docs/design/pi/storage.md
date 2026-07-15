# Pi storage

The Pi records continuously to its own microSD card. The recording directory is
the source of truth; the phone browses and pulls finished footage without joining
the recording path. Storage is a maximally full, oldest-first segment ring whose
mutations are serialized through one coordinator.

This page owns segment identity, timestamp facts, recording-session identity,
directory scanning, deletion, garbage collection, and power-cut repair. The
[roadmap](../../roadmap.md) describes product sequencing around those mechanisms.

## On-disk model

All hot recording state lives under the configured recording directory, normally
`/data/rec` on the dedicated writable data partition:

```text
/data/rec/
  seg_<seq>.ts
  seg_<seq>_<boottag>_<session>_<monoMs>.ts
  seg_<seq>_<boottag>_<session>_<monoMs>_<durMs>.ts
  state/state.json
  time/<full-boot-uuid>.json
```

Finished and open MPEG-TS segments stay flat in the recording directory. Stamped
filenames are the durable index, and each operation scans the directory instead of
maintaining an append log, snapshot, database, or in-memory canonical index.

The bare filename is a real live state, not a compatibility form. It can exist while
ffmpeg has created a segment but the watcher has not stamped it, after a stamping
rename failure, or after power dies inside that window. A bare file carries only its
sequence; all other facts are unknown.

The finalized filename carries five immutable facts. The four-field stamped form is
the live form and omits only `durMs`:

- `seq` is the stable clip id and total order. It is a decimal `u32`, zero-padded
  to at least five digits and allowed to grow wider after 99999.
- `boottag` is the first 12 lowercase hexadecimal characters of the kernel boot
  UUID after removing dashes.
- `session` is a decimal `u64` identifying one contiguous recording run. It is
  `start_segment + 1`, so it is at least 1 and survives a service restart.
- `monoMs` is the `CLOCK_BOOTTIME` millisecond reading captured when the segment
  is first observed open.
- `durMs` is the measured MPEG-TS duration as a canonical decimal `u64`. It is added
  only after the writer has moved on and is immutable once present.

The Rust and Python parsers accept a name only when all numeric fields fit their
declared integer types and rendering the parsed value reproduces the input
byte-for-byte. Short sequence aliases, over-padding, uppercase or wrong-length boot
tags, leading-zero numeric aliases, and the retired three-fact stamped form are
invalid. Directory scans accept bare, four-field stamped, and five-field finalized
forms. Duplicate recovery uses one total order everywhere: five-field finalized over
four-field stamped over bare, then the lexicographically smallest ASCII filename
within the same rank. Bulk deletion still removes every valid path for the id.

The camera owner still asks ffmpeg to create bare `seg_%05d.ts` files. Its watcher
detects a new open segment, captures boot time, renames the bare path to the stamped
form, and then emits `segment_opened`. Renaming does not interrupt ffmpeg's open file
descriptor. If stamping fails, the watcher logs the error and emits anyway; missing
timestamp facts must not stop recording.

When Rust finalizes a four-field segment, it measures the duration while the data is
hot, renames the path to the five-field form under the storage mutation mutex, and
fsyncs the recording directory before publishing `clip_finalized`. A measurement or
rename failure leaves the four-field path usable and duration remains best-effort.

The Pi stores no per-segment JPEG thumbnail and exposes no thumbnail mutation path.
The app derives first frames from ranged reads or its local clip cache.

## Segment and recording identity

Sequence ids are never reused, including after their files have been deleted. The
storage coordinator reserves a start id under its mutation mutex:

1. Read `state/state.json` and its `high_water_seq`.
2. Scan the recording directory for the greatest valid segment sequence.
3. Select one greater than the maximum witness, or 0 when neither exists.
4. Persist the selected id to `state/state.json` before returning it.

The state write creates `state/` as needed, writes and fsyncs a temporary file,
renames it over `state.json`, and fsyncs the directory. The recording directory is
also fsynced after first creating `state/`. A crash after reservation but before the
first media write therefore cannot make the id available again.

Committed witness state fails closed. Invalid JSON, a missing or incorrectly typed
field, or a non-NotFound read error prevents recording start before the recorder state
machine or camera child changes. Deleting `state/state.json` is a manual emergency
recovery that leaves footage intact but deliberately lowers the floor to the surviving
file scan. A future data-partition format must carry the witness forward so deleting
all footage does not permit aliasing.

Start allocation fails when the maximum witness is `u32::MAX`; it never saturates to
or repeats the last id. `u32::MAX` is the final legal reservation. The controlled Rust
mock and Python fake writers also fail closed rather than rolling over past the
ceiling. The real ffmpeg path accepts only an `INT_MAX` start number and has no
documented post-`INT_MAX` rollover behavior. Reaching that point at the configured
segment cadence is outside the supported device lifetime, so the real path makes no
runtime guarantee beyond it.

The recorder derives `session = start_segment + 1` from the durable reservation,
not from a process-local counter. A recording is therefore identified by
`(boottag, session)` and can be reconstructed from the card alone. A same-boot
service restart obtains a new start id and cannot merge the next recording into the
previous one. The Pi exposes per-clip facts; grouping clips into recordings remains an
app-side view.

## Time derivation

The Pi has no real-time clock. Segment filenames store monotonic measurements rather
than wall-clock conclusions. When the phone posts time, the service computes:

```text
offset_ms = epoch_ms - boottime_now_ms
```

and writes one offset file for the full boot UUID:

```text
time/<full-boot-uuid>.json
```

```json
{"boot_id":"...","offset_ms":0,"source":"app","synced_at_mono_ms":0}
```

The file is write-once for that boot and is persisted by temporary-file write, file
fsync, rename, and best-effort directory fsync. Startup loads parseable offset files
by boot tag. Torn or unparsable files are skipped so the boot can be synced again; a
boot-tag collision makes that tag unresolvable.

The time request contains only `epoch_ms` and accepts values from
2026-01-01T00:00:00Z through 2100-01-01T00:00:00Z. There is no RTT-refinement or
implicit GPS override. A future GPS source needs an explicit source-priority rule.

At read time a stamped segment resolves:

```text
start_ms = monoMs + offset_ms
```

If the name is bare, the offset is missing, the tag is ambiguous, or checked
arithmetic fails, `start_ms` is null and `time_approximate` is true. No wall time is
written into a segment filename or stored in a per-segment sidecar. Listings always
order by sequence, so gaining an offset can sharpen timestamps without reordering
footage.

Clip listings and `clip_finalized` derive their timestamp fields from the same facts
and offset store. `server_time_ms` stays null until the current boot is synced, then
derives from boot time plus its offset. Snapshot state exposes whether time is synced,
and the false-to-true transition emits `time_synced`.

On non-Linux development hosts, Rust falls back from `CLOCK_BOOTTIME` to monotonic
time, while the Python camera owner uses `time.monotonic()` and a random boot tag.
That is sufficient for Mac tests but does not prove cross-process boot-id matching.

## In-flight durability and startup repair

The camera watcher calls `fdatasync` on the open segment about every 2 seconds. This
bounds power-cut loss to roughly the sync cadence plus encoder buffering instead of
allowing a whole open segment to remain only in page cache. Periodic sync catches
every `OSError`, logs only the first in a run of failures, and retries on the next
cadence. Close-time and shutdown syncs also keep the watcher alive on sync errors. The
Rust mock mirrors the cadence but keeps rollover and stop sync failures fatal.

Before either backend starts, the storage coordinator scrubs zero-byte segment paths.
It scans raw candidates before normal deduplication and groups them by sequence:

- If every path for an id is empty, the coordinator first raises
  `high_water_seq` to at least the greatest fully deleted id, then unlinks all paths
  for those ids and fsyncs the recording directory.
- If any path for an id is nonzero, the footage survives. Only empty duplicates are
  removed; no witness raise is needed because the surviving path still prevents reuse.

This path-by-path rule deliberately prefers recoverable bytes over a stamped filename.
A stamped empty file beside a bare nonempty file loses its timestamp facts but keeps
the video. Truncated-but-nonzero segments remain available and can play through the
power cut. Startup continues after a scrub failure so a missing or damaged data mount
does not take the control and diagnostic API offline. No removal events are emitted
before clients connect.

## Filesystem-backed reads

Clip listing, lookup, pull, current-segment enrichment,
next-sequence selection, and GC all scan or open the flat recording directory. A
missing recording directory is a truthful empty listing. Other scan failures fail
closed: list and lookup return 503 rather than turning an unreadable directory into an
empty list or a false 404, and start allocation does not lower its floor.

Listings include finalized segments only, order newest first, and use a cursor as a
strict lower-sequence boundary. The server clamps page size and returns a next cursor
only while older candidates remain. A five-field filename supplies duration without
opening media. Durationless four-field or bare recovery files remain listable and
pullable with `dur_ms: null`; listing never scans media or rewrites filenames.

An immutable clip `ETag` derives from stable facts such as sequence and byte length,
never inode, mtime, or path.

Media reads do not take the mutation mutex. A reader opens the segment and streams
from its file descriptor. POSIX unlink semantics let an already-open pull finish after
manual deletion or GC; a later request gets 404. A stale listing that loses the race
can re-list, and resumable pulls retain their representation boundary through the
`ETag`.

## Mutation coordinator and manual deletion

One `StorageCoordinator` owns recording-directory mutations. Its mutex serializes
start reservation, duration persistence, boot scrub, manual deletion, and each GC
delete. Recorder byte
streaming and all non-mutating reads stay outside it. The composition root shares one
coordinator between application state and the active backend, using the camera
configuration's recording directory so custom camera commands cannot split storage
ownership.

`DELETE /v1/clips/{id}` removes one finished clip through
`StorageCoordinator::delete_finished_segment`:

1. Recheck the live recorder floor under the mutex. An id at or above it is not
   deletable and returns 404.
2. Scan for every regular bare or stamped path with the requested sequence. This
   avoids leaving footage behind during the stamping window.
3. Raise `high_water_seq` to at least the id before the first unlink. Corrupt
   committed state fails closed.
4. Remove every matching path and fsync the recording directory.

The endpoint returns 204 only after durable deletion, then emits ordered
`clip_removed { id }`. A floor block or missing match is 404. Scan, witness, unlink,
or directory-fsync failures are 503. If failure happens after one of several duplicate
paths is unlinked, no success or event is emitted; a later attempt converges on the
surviving paths. The write-ahead witness still prevents id reuse.

There is no separate delete witness or handler-owned unlink path. A new recording file
is created only after start reservation has set the recorder floor, so the under-mutex
floor check protects active and newly reserved ids. Mutation routes share the same
JSON content-type and nonempty idempotency-key validation.

## Ring garbage collection

An independent worker keeps available non-root-writable space at a byte floor.
`DANCAM_GC_FLOOR_BYTES` defaults to 2 GiB and 0 disables GC. The probe uses
`statvfs` `f_bavail`, because ext4 blocks reserved for root are unavailable to the
service and camera child.

The worker probes about every 2 seconds, including while recording is idle. There is
no high watermark. When available space is below the floor, each pass scans finished
segments, deduplicates same-id paths, and considers them in ascending sequence. It
deletes until the floor is restored or 16 ids have succeeded. A floor larger than the
partition can intentionally drain the ring during development.

The scan-time evictability check is only an optimization. The coordinator rechecks
the live recorder floor under its mutex immediately before the witness raise and
unlink. The same point retains an unused seam for a future evidence-backed clip pin,
but v1 has neither incident hardlinks nor a persisted protection floor.

A pass never holds the mutex across its scan or batch. It can take the mutex once for
an optional batch witness raise and separately for each attempted deletion. The
16-item cap counts successful ids and emitted events, not refused candidates, mutex
acquisitions, raw path unlinks, scan work, or wall time. Space is probed after each
success; restoring the floor on the 16th delete is reported as reached-floor. If 16
successes leave the card below the floor, another bounded pass begins immediately.

GC amortizes witness writes. For an ordered candidate scan:

- `scan_max` is the newest finished candidate.
- `prefix_max` is the newest of the oldest 16 candidates, or `scan_max` when fewer
  exist.
- If committed `high_water_seq` is below `prefix_max`, GC durably raises it to
  `scan_max` before deleting anything. Otherwise it skips the write.

Jumping ahead is safe because the witness only prevents reuse; it never authorizes a
deletion. If an authoritative protection check skips prefix candidates and GC reaches
later ids, the ordinary per-id write-ahead raise remains the correctness backstop.

Each durable eviction emits `clip_removed`. An already-open pull can finish; a later
range request returns 404.
Phone-cached MP4s remain available after Pi roll-off, and the app bounds stale-list
suppression to outstanding request generations rather than accumulating permanent
tombstones.

The worker emits a structured `ring_gc_outcome` record only when it deletes footage
or enters backoff. `outcome` distinguishes `reached_floor`, `batch_capped`,
`exhausted`, `probe_unavailable`, and `failed`. The record includes the successful
delete count, ordered bounded ids, available bytes before and after the pass, and the
configured floor. Backoff records add the retry interval, and failures add the error.
Healthy above-floor probes remain silent.

GC never deletes without a successful space probe. An unavailable probe, no evictable
candidate below the floor, a witness or unlink failure, or a panicking blocking pass
causes one loud error and a 30-second backoff. It does not spin or delete blind;
recording may reach ENOSPC honestly.

## Incident ownership

The Pi does not own incident state and exposes no incident mutation in v1. It has no
incident directory, hardlink locks, pre-sync holds, idempotency tombstones, locked-byte
caps, incident metadata, or incident events. The phone records an incident and pulls
its window through the existing list, event, and ranged-read surfaces; see
[phone-owned incidents](../app/incidents.md).

The old in-mutex protection seam remains intentionally unused. A future protect-only
pin must be justified by retention evidence and must recheck protection at the same
authoritative point as the recorder floor.

## Decision log

### 2026-06-23: Space-based ring and the original incident-lock model

(absorbed from raspi ADR 03, 2026-06-23)

The camera records locally, the Pi has no RTC, and power can disappear without
warning. Storage needed a total order independent of wall time, recovery from torn
writes, enough free space to keep recording, and a way to protect user-marked footage
without placing Wi-Fi on the recording path.

The decision established a space-based MPEG-TS segment ring, a global monotonic
sequence, immutable ETags, a single-writer mutation coordinator, filesystem-backed
rebuild, and direct reads through open file descriptors. It also proposed a more
elaborate end state: `segments/`, `incidents/`, an append-only `index.log` plus
snapshots, an in-memory index, percentage watermarks, and incident hardlinks with
pre-sync floors, metadata sagas, tombstones, post-roll registration, and locked-space
caps. Exact percentages, incident windows, segment lengths, and commit ordering were
explicitly starting points rather than frozen contracts.

Implementation evidence simplified that design. Stamped filenames made the flat
directory a sufficient index, and byte-floor drip GC replaced percentage hysteresis.
The phone later became the permanent incident owner, so the Pi-side hardlink tree and
all incident mutations were abandoned. The current page body retains the durable
parts: SD as truth, monotonic ids, serialized mutations, oldest-first retention,
write-ahead deletion, and POSIX pull-race behavior.

Alternatives considered:

- Primary time-based retention was rejected because variable bitrate on a fixed card
  can still fill the filesystem. Space pressure must govern retention.
- Copying locked bytes was rejected because it multiplies flash writes and creates
  copy/ring crash windows. Hardlinks were the cheaper original lock mechanism.
- Sidecar-only lock flags were rejected because they require separate reference
  counts and make rebuild depend on perfectly current metadata.
- Per-segment sidecars and wall-time filenames were rejected because wall time is bad
  before sync and extra files add inode and fsync churn.
- SQLite was rejected for the first implementation because filesystem truth and a
  simple journal appeared easier to rebuild on a 512 MB Pi. Stateless scans later
  removed the journal as well.
- Refusing every new incident at a full cap was rejected because the just-marked
  moment should displace older evidence if necessary. Always displacing old incidents
  was also rejected because an extending incident could erase the store. The proposed
  compromise privileged initial seating and clamped later growth.
- A global cap alone was rejected because one incident could consume the budget.
- Per-boot sequence ids were rejected because they complicate stable ids and ETags
  across reboot.
- Fine-grained mutation locks were rejected because the mutation rate is low and a
  single coordinator closes GC, lock, finalize, and reader races more directly.
- Moving locked clips out of the ring was rejected because stable ids plus hardlinks
  avoided rename and copy complexity.

### 2026-07-02: Stamp segment facts and derive wall time

(absorbed from raspi ADR 15, 2026-07-02)

The camera can record before a phone supplies wall time, while `CLOCK_BOOTTIME` is
trustworthy across service restarts in one kernel boot. Keeping segment facts in a
rebuildable index and boot anchors in shared mutable state could skew a file from its
metadata or lose a timestamp that was knowable at creation.

The decision stored measurements rather than conclusions: sequence, boot tag, and
monotonic open time moved into the segment filename, while one write-once per-boot
offset file turns monotonic time into wall time at read time. A watcher renames the
open ffmpeg file without interrupting its descriptor. Bare filenames remain honest
unknown-fact states, scans are authoritative, and invalid or ambiguous facts degrade
to approximate time. The 2026-07-09 session decision later extended the stamped
grammar without changing the offset model.

Alternatives considered:

- Wall-time filenames were rejected because wall time can be garbage at boot and must
  not join the recording path.
- A rebuildable fact index and mutable per-segment sidecars were rejected because
  either can skew from the media under power loss.
- An RTT-refined handshake was rejected because watcher polling already bounds the
  useful precision to about 0.25 seconds.
- An unconditional GPS override was deferred; multiple sources require an explicit
  priority policy rather than silent rebinding.

### 2026-07-02: Add the durable sequence witness and coordinator

(absorbed from raspi ADR 16, 2026-07-02)

Directory-only next-id selection was safe only while the highest segment always
survived. Manual deletion and GC could remove that witness and cause a public sequence
and immutable ETag to be reused.

The decision introduced `StorageCoordinator` and the fsync-durable
`state/state.json` `high_water_seq`. Start ids are reserved under the mutation mutex
and persisted before the caller sees them. Corrupt committed state fails closed rather
than silently falling back to a lower scan. Reads remain filesystem-backed and outside
the coordinator. Later deletion and GC completed the target invariant by raising the
witness before unlink; amortized GC raises cover rollover ids without moving segment
finalization behind the mutex.

Alternatives considered:

- Continuing to scan only was rejected because a deleted highest id could be reused.
- Falling back to a scan on corrupt witness state was rejected because it makes the
  durable floor optional precisely when it is least trustworthy.
- Storing the floor in a rebuildable index was rejected because cache loss must not
  lose the no-aliasing guarantee.
- Moving all reads behind the coordinator was rejected because reads do not mutate
  storage and open descriptors already survive unlink.

### 2026-07-02: Delete finished clips through the coordinator

(absorbed from raspi ADR 17, 2026-07-02)

Phone-initiated deletion was the first mutation of committed footage. It had to stay
off the recording path, refuse active segments, preserve the sequence witness, and
distinguish an unreadable directory from an authoritative empty result so optimistic
app reconciliation remained sound.

The decision added durable `DELETE /v1/clips/{id}` and the ordered
`clip_removed` event. The coordinator rechecks the live floor, finds every matching
bare and stamped path, raises the witness before unlink, fsyncs the directory, and
acknowledges only after success. Scan failures now fail closed across list, lookup,
and allocation paths. A partial duplicate-path failure returns 503 without an event,
but the prior witness raise preserves the no-reuse invariant.

Alternatives considered:

- Reconstructing only `seg_<id>.ts` was rejected because stamped-only clips are valid
  and bare/stamped duplicates can coexist during rename.
- A separate delete witness was rejected because it would split the one no-reuse
  invariant.
- Treating an already-gone clip as idempotent success was rejected so 404 retains its
  established meaning; the app can still treat delete 404 as a removed row.
- An optional backend removal hook was rejected because returning 204 without a
  reconciliation event would be a silent correctness bug.
- `If-Match` was deferred because ids are never reused; it can be added if stale-row
  feedback becomes a product need.

### 2026-07-08: Bound in-flight loss and scrub empty leftovers

(absorbed from raspi ADR 19, 2026-07-08)

A real field power cut left a stamped zero-byte file. Dirty-writeback clamps had been
verified but ext4 delayed allocation persisted the rename without any media blocks.
On reboot the empty file appeared to be a valid finished clip, and HTTP could deliver
a successful zero-length body that only failed later during remux.

The decision added periodic `fdatasync` for the open real and mock segment and a
startup repair pass. Scrub works on every raw path: it deletes an id only when all its
paths are empty, raising the witness first, while a nonempty duplicate always wins over
timestamp facts. Startup remains available if repair fails so mount damage does not
hide diagnostics.

Alternatives considered:

- Dirty-page clamps alone were rejected because they had already failed in the field.
- Synchronous segment writes were rejected as excessive latency and flash wear; a
  periodic sync bounds loss more narrowly.
- Shorter segments were rejected as the primary fix because they do not bound
  page-cache loss inside the open segment.
- `data=journal` and shorter ext4 commits were rejected as system-wide costs that do
  not replace explicit file sync.
- App-side filtering and retaining empty files were rejected because the Pi owns
  recording truth and zero bytes contain no recoverable video.

### 2026-07-09: Persist recording sessions in filenames

(absorbed from raspi ADR 20, 2026-07-09)

Grouping clips only by boot merged manual stop/start cycles and same-boot service
restarts into one apparent recording. The process-local session counter also reset on
restart and was absent from the crash-safe fact store.

The decision extended the filename with `session` and derived it from the durable
start reservation. A recording is reconstructible as `(boottag, session)` from a
directory listing. Both controlled writers and start allocation fail closed at the
`u32` ceiling, while the real ffmpeg rollover boundary is documented honestly as
outside the device-lifetime contract. The retired three-fact form was intentionally
not accepted because the project had no shipped compatibility obligation.

Alternatives considered:

- A session sidecar or counter was rejected because it adds another crash and skew
  window instead of reusing an existing durable witness.
- Encoding session in sequence ranges was rejected because it aliases the clip id.
- Accepting both old and new stamped forms was rejected because two canons would be a
  compatibility shim and could diverge between Rust and Python.

### 2026-07-10: Use byte-floor drip eviction and stateless scans

(absorbed from raspi ADR 21, 2026-07-10)

At the measured write rate, finished segments fill a 128 GB card in roughly 24-50
hours. By then, working code had shown that the dedicated data partition, natural
segment cadence, stamped filenames, and stateless scans were enough; the proposed
percentage watermarks, directory tree, append log, snapshots, and in-memory index
added state without solving a demonstrated problem.

The decision made the flat filename directory final and added a worker that
drip-evicts oldest finished segments to a non-root `f_bavail` byte floor. It bounds
successful events to 16 per pass, keeps each mutex hold small, performs an amortized
batch witness jump, retains per-id raises for uncommon skips, evicts duration-cache
entries, and backs off loudly instead of deleting without a trustworthy probe. The
authoritative under-mutex protection recheck was retained for future pinning; the
phone-owned incident decision left it unused in v1.

Alternatives considered:

- High/low percentage watermarks were rejected because they sacrifice retention at
  the high watermark and cause bursty reclamation despite a natural one-segment
  cadence.
- A percentage floor was rejected because a byte count directly states the required
  write margin across card sizes.
- One unbounded delete-to-floor pass was rejected because it could create an
  unbounded event burst and delay other coordinator mutations.
- Raising the witness before every drip was rejected because it would rewrite state
  on every rollover; the guarded jump provides the same no-reuse guarantee with
  amortized writes.
- Trusting the mutex-free scan for protection was rejected because protection can
  change before deletion.
- Building an index log, snapshots, and an in-memory index was rejected because the
  filenames already carry durable facts and bounded-ring scans are simpler and
  crash-safe.

### 2026-07-15: Persist measured duration in the finalized filename

Cold clip listings repeatedly scanned 768 KB of MPEG-TS data per segment after every
service restart. Those SD reads competed with camera startup, while the in-memory
duration cache could not make the immutable fact survive a restart and its global
generation invalidated unrelated in-flight inserts after deletion.

The decision made duration the fifth finalized filename fact. Finalize measures and
persists it with an atomic rename and directory fsync; inactive listings lazily
backfill four-field segments through a single measurement gate. Every resolver uses
the same fact-rank and filename tie-break order, and listing migration yields as soon
as recording is observed active.

Startup warming was rejected because it creates maximum SD contention at recording
startup. A sidecar or index was rejected because the filename already owns immutable
per-segment facts. Keeping the cache with per-id invalidation was rejected because a
durable filename makes the cache a rare-case optimization rather than useful state.

### 2026-07-15: Reset existing footage instead of carrying duration migration

The duration filename change had no shipped-user compatibility requirement, and the
development Pi could be reset at the transition. Keeping listing-time measurement and
backfill would permanently retain synchronization, recording-yield, retry, and
instrumentation code for a one-time local migration.

The decision removed listing-time duration scans and backfill. Clip listing now reads
duration only from the five-field finalized filename; durationless recovery files
remain usable with unknown duration. The development Pi recording directory was reset
at the transition. Retaining lazy migration was rejected because operationally
clearing disposable footage is simpler and removes the SD contention path entirely.
