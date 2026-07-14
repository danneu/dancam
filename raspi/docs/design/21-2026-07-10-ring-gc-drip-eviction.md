# ADR: Ring GC with drip eviction

- **Status:** Accepted
- **Date:** 2026-07-10
- **Owner:** raspi
- **Related:** `03-2026-06-23-storage-ring-buffer-incident-lock.md` (ring,
  incident protection, and mutation serialization -- GC policy and the target
  indexed layout scoped-superseded here);
  `16-2026-07-02-storage-coordinator-segment-id-witness.md` (durable segment-id
  witness and write-ahead unlink rule);
  `17-2026-07-02-clip-delete.md` (finished-segment deletion primitive and
  `clip_removed` event);
  `18-2026-07-04-sd-card-layout-and-readonly-root.md` (dedicated `/data`
  partition and mount witness)

> **Note (2026-07-14):** App ADR 26 makes incidents phone-owned and supersedes the
> Pi-side hardlink/protect-floor incident model. The authoritative in-mutex protection
> recheck remains a valid, currently unused seam for a future protect-only clip pin;
> `nova` does not implement either protection predicate. All GC policy, witness,
> deletion, event, cache, and pull-race decisions in this ADR remain in force.

## Context

The Pi writes roughly 38 MB every 30 seconds to the dedicated `/data` recording
partition. Finished segments currently remain until the app manually deletes
them. A 128 GB card therefore fills in roughly 24-50 hours, making automatic
retention the last requirement for indefinite recording.

ADR 03 sketched percentage high/low watermarks, a `segments/` tree, an
append-only index plus snapshots, and an in-memory index. Implementation evidence
has made those parts obsolete. The dedicated recording partition gives GC one
clear capacity domain, segment finalization supplies a natural cadence, and the
stamped filename work in ADRs 15 and 20 makes the flat directory itself the
authoritative index. Listing, pulling, deletion, and recovery already use
stateless scans successfully.

GC must preserve three existing invariants. Recording stays independent of the
phone and network. A removed segment id is never reused, so every unlink remains
covered by ADR 16's durable write-ahead witness. Future incident locking must be
able to install protection without racing a stale GC scan.

## Decision

Run an independent GC worker that drip-evicts the oldest finished segments when
space available to the non-root service falls below a byte floor.

### Floor And Cadence

`DANCAM_GC_FLOOR_BYTES` is an unsigned byte count. It defaults to 2 GiB, enough
for about 53 worst-case 38 MB segments, and `0` disables GC. The space probe uses
`statvfs` `f_bavail`, not `f_bfree`, because ext4's root reserve is not writable
by the service or camera child.

The worker probes about every 2 seconds in its own task, like telemetry. It does
not add work to `camera/mod.rs#parse_stderr`. That reader currently awaits
finalization metadata I/O on rollover and stop; moving that work away from the
reader remains a prerequisite for `nova`'s lock saga, not a property established
by this decision.

There is no high watermark. At steady state, GC deletes the oldest finished
segment when available bytes fall below the floor, then stops as soon as the
floor is restored. This keeps the ring maximally full, avoids bursty band
reclamation, and keeps individual mutation-mutex holds short.

GC may evict while the recorder is idle. With no live floor, even the newest
finished segment is eligible. Space does not shrink while idle, so GC stops once
the floor is reached. A floor larger than the partition, useful for development,
can drain the entire ring.

### Stateless Candidate Scan And Protection

Each pass scans the flat recording directory, parses stamped or bare segment
filenames, deduplicates same-id paths, and orders candidates by ascending
sequence. Stamped filenames are the durable index; the flat layout and stateless
per-operation scans are the end state. ADR 03's `segments/`, `index.log`,
`index.snapshot`, and in-memory segment index are not deferred machinery.

The scan-time `evictable` predicate is only an optimization. In v1 it filters
against the recorder's live floor. The authoritative protection decision is a
recheck inside `StorageCoordinator::delete_finished_segment`, under the mutation
mutex and immediately before the witness raise and unlink. A recorder floor that
changes after the scan is therefore honored. A refusal returns `NotFound`; GC
skips that candidate and continues through the ordered scan.

`nova` adds two protection predicates at the same authoritative point: inode
link count greater than 1 for incident hardlinks, and a persisted minimum
protect-floor sequence. It may mirror them in the mutex-free scan as an
optimization, but must recheck both under the coordinator mutex. A finalize-time
incident linker must run before GC can consider the finalized segment.

### Mutation And Batch Bounds

GC reuses `StorageCoordinator::delete_finished_segment` for each id. A pass does
not hold the mutation mutex across its scan or across a batch. It acquires the
mutex once for an optional batch witness raise, releases it, and then acquires
and releases it separately for every attempted id deletion. Each hold contains
one witness fsync or one duplicate-path unlink group; no future implementation
may coalesce a pass into one long hold. This per-acquisition latency bound is the
relevant constraint for `nova`, whose lock saga will await an fsync while holding
the same mutex.

`MAX_EVICTIONS_PER_BATCH` is 16 and counts successful ids, hence at most 16
`clip_removed` events. Refused or concurrently-removed candidates consume no cap
budget, so a pass can attempt the full candidate list and acquire the mutex more
than 17 times. The cap does not bound scan size, raw unlink count, or wall time.

A segment id can have bare and stamped duplicate paths. Those paths are unlinked
sequentially, not atomically. If an unlink fails mid-group, the remaining paths
stay on disk, the pass returns failure, and no `clip_removed` is emitted for that
id. A later pass retries the surviving group. Thus one successful id may require
multiple unlinks and the raw unlink count can exceed 16.

After each successful deletion, GC probes space before checking the cap. A
cap-th deletion that restores the floor returns reached-floor, not batch-capped.
If 16 successful deletions leave space below the floor, the worker immediately
runs another pass without waiting for the normal interval. This permits an
initial deficit to recover through back-to-back bounded event bursts.

### Amortized Segment-Id Witness

The standalone manual-delete path retains ADR 17's per-id write-ahead witness
raise. Applying that naively to every GC drip would rewrite `state.json` on every
rollover eviction: the committed witness can remain at the session-start id while
thousands of later finished segments accumulate.

GC therefore performs at most one amortizing batch raise before unlink attempts.
For the ordered evictable scan:

- `scan_max` is the newest finished candidate in the scan.
- `prefix_max` is the newest id among the oldest 16 candidates, or `scan_max`
  when fewer exist. It is the highest id the pass would delete if none are
  refused.
- If the committed witness is below `prefix_max`, GC durably raises it to
  `scan_max` before any unlink. If it already covers `prefix_max`, the raise is
  a read-and-skip.

Guarding on `prefix_max` determines when the rare write is needed; jumping to
`scan_max` determines how far it advances. A witness above surviving or live
segments is safe because it only prevents reuse and never authorizes deletion.
The following oldest-first drips therefore skip witness writes until the ring
rotates beyond the prior `scan_max`.

`prefix_max` is not always the highest id actually removed. When authoritative
protection refuses candidates in the prefix, the pass continues into later ids.
Those later unlinks remain correct because `delete_finished_segment` performs its
own per-id write-ahead raise. The uncommon refusal path may pay extra witness
fsyncs; the common path remains amortized.

### Events, Caches, And Pull Races

Every fully successful eviction emits the existing `clip_removed` event after
durable deletion. No wire type or golden-corpus fixture changes. A client that
lags the bounded burst reconnects to a fresh snapshot under the existing SSE
contract.

The backend handling `clip_removed` also removes that sequence from the in-memory
`DurationCache`. Segment ids never repeat, so forgetting is pure reclamation and
prevents continuous ring operation from growing the cache for the process
lifetime on a 512 MB Pi.

An already-open pull fd remains readable after POSIX unlink. A later ranged
request for the same id returns 404, which the app treats as terminal. Cached
MP4s on the phone are deliberately retained: ids never repeat, and watched
footage surviving Pi roll-off is a product feature. Manual app deletion remains
the path that purges the cache. If a viewer has not cached the clip and it evicts
mid-pull, the viewer degrades to its failed state.

The app's removal tombstones are scoped to outstanding head/page request
generations. A confirmed removal needs suppression only while a request that
began before it may still return stale data. With no request in flight, an
eviction leaves no lasting tombstone, so continuous `clip_removed` traffic does
not grow process-lifetime state.

### Failure And Backoff

GC never evicts without a successful `f_bavail` probe. If space is below the
floor but no candidate is evictable, the probe is unavailable, a witness or
unlink operation fails, or a blocking pass panics, the worker logs one loud
error and backs off for 30 seconds. It does not spin. Recording is allowed to
reach ENOSPC honestly rather than deleting blind. Storage/card-health UI and
formatting belong to `kelp`.

## Consequences

- The recording partition becomes a maximally-full, oldest-first ring with a
  2 GiB default non-root-writable safety floor.
- The normal steady-state cost is one segment deletion per finalized segment;
  witness fsyncs occur roughly once per ring rotation instead of once per drip.
- Every individual coordinator hold stays small, but a pass has no fixed bound
  on scan work, attempted deletions, mutex acquisitions, raw unlinks, or elapsed
  time. Only successful ids and events are capped at 16 per batch.
- The flat stamped-filename layout is final. Removing the planned index reduces
  state, recovery paths, and consistency hazards.
- GC-vs-lock correctness rests on the in-mutex protection recheck, giving
  `nova` a clear hardlink/protect-floor seam and finalize-before-GC ordering.
- Persistent below-floor stalls are loud and rate-limited; richer diagnosis is
  deferred to `kelp`.

## Alternatives considered

- **High/low percentage watermarks.** Rejected. They permanently sacrifice
  retention at the high watermark and burst many mutations despite the natural
  one-segment finalize cadence.
- **A percentage floor.** Rejected. A byte floor expresses the actual write
  margin and behaves predictably across supported card sizes.
- **Delete until the floor in one unbounded pass.** Rejected. It creates an
  unbounded event burst and delays competing mutations; capped batches preserve
  progress while limiting successful ids per turn.
- **Raise the witness before every GC unlink.** Rejected. During a continuous
  session it fsyncs `state.json` once per drip. The guarded jump provides the
  same no-reuse guarantee with amortized writes.
- **Trust the mutex-free candidate scan for protection.** Rejected. Protection
  can change between scan and deletion; only an in-mutex recheck serializes GC
  correctly with recording and incident locks.
- **Build `index.log`, snapshots, and an in-memory index.** Rejected. Stamped
  filenames already carry the durable facts and stateless scans are simpler,
  crash-safe, and adequate on the bounded ring.
