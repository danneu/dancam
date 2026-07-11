# Plan: Swoop `silt` -- ring-buffer GC (drip eviction to a byte floor)

6 commits: 5 Pi-side (Rust service + docs) plus 1 app-side commit (commit 6).
The app already folds `clip_removed`, so `silt` adds no wire surface; commit 6's
one production change (F16) scopes `ClipsFeature`'s removal tombstones to
outstanding request generations, so the suppression set is bounded by in-flight
head/page requests (near zero on a healthy idle connection) rather than by
lifetime eviction count -- durable, since continuous GC eviction would otherwise
grow that set without bound -- and pins the cache-retention behavior that already
exists. Each commit builds and tests green on its own; gates are `just
raspi-test`, `just raspi-check`,
and (commit 1) `just adr-check`; commit 6 is `just app-test` (or the Xcode
test scheme). `just raspi-check` runs `cargo clippy --all-targets -D warnings`,
so a `pub(crate)`/private symbol with no in-crate *production* caller trips
`dead_code` even when tests exercise it (the plain-lib target has `cfg(test)`
off). The GC worker is therefore the first production caller of the whole pass
machinery, so the batch-raise coordinator method, the pass core, the probe, the
worker, and the `main.rs` wiring all land together in commit 4 -- splitting the
pass core into its own earlier commit would fail the lint gate.

## Context

The Pi records ~38 MB segments every 30 s to the dedicated `/data` recording
partition (ADR 18) and today nothing ever deletes them except the app's manual
`DELETE /v1/clips/{id}` (ADR 17) and the boot scrub (ADR 19). A card fills in
~24-50 h of recording, so GC is the last piece between the current system and
"leave it recording in the car indefinitely". It also creates the evictor that
`nova`'s incident locks will need protection *from*, and both `kelp` and `nova`
build on its seams.

Design settled in brainstorm with Dan (2026-07-10); key pivots from ADR 03's
sketch, each recorded in the new ADR 21 rather than contorted into the old text:

1. **Drip, not hysteresis band.** ADR 03's high/low-watermark band predates the
   dedicated `/data` partition and the per-finalize cadence. Steady state is one
   ~38 MB segment in per 30 s, so "GC deletes one oldest segment when below the
   floor" IS the natural rhythm -- a band would permanently sacrifice retention
   (idling at the high watermark), burst dozens of unlinks and `clip_removed`
   events at once, and hold the mutation mutex in front of `nova`'s future
   panic-button lock saga (which awaits an fsync while holding it). Drip keeps
   the ring maximally full and every GC turn tiny.
2. **Floor in bytes, not percent.** `DANCAM_GC_FLOOR_BYTES`, default 2 GiB
   (Dan's call: conservative; ~53 worst-case segments of margin, matching ADR
   03's old ~2% figure on a 128 GB card). `0` disables GC. Measured via
   `f_bavail` -- the service and camera child run non-root, and ext4 reserves
   ~5% for root that `f_bfree` counts but we can never write.
3. **No new wire surface.** Each eviction emits the existing `clip_removed`
   verbatim (the app already folds it; golden corpus untouched on both sides).
   A loud incident-eviction event is `nova`'s, deliberately distinct.
4. **ADR 03's index machinery is dead.** `index.log`/`index.snapshot`/the
   in-memory index and the `segments/` subdir move are superseded: stamped
   filenames (ADR 15/20) turned out to BE the index, flat layout is the end
   state, and stateless per-op scans are the realized posture.
5. **GC I/O stays off the camera child's event reader.** `silt` adds NO GC work
   to `camera/mod.rs#parse_stderr`; the GC worker is its own task with its own
   ~2 s probe cadence, mirroring `events.rs#spawn_telemetry`. Note (F12) that
   `parse_stderr` is NOT I/O-free today -- it `await`s `finalized_clip_meta`
   (a `spawn_blocking` segment stat + duration read) on both `SegmentOpened`
   rollover and `RecordingStopped`. `nova`'s lock saga wants that reader
   mutex-free and I/O-free (to deliver sync acks while the saga holds the
   mutation mutex), so moving finalization meta off the reader is an explicit
   `nova` prerequisite, NOT a property `silt` establishes or relies on -- `silt`
   only commits to not adding to that reader's load.
6. **Protection is a seam, and the seam's authority is the in-mutex recheck**
   (F9). v1 filters candidates only by the live recorder floor
   (`unpullable_from`). The scan-time `evictable` filter runs mutex-free, so it
   is only an optimization -- the authoritative protection check is
   `delete_finished_segment`'s in-mutex re-evaluation of `live_floor()` under the
   mutation mutex, immediately before the witness raise/unlink (confirmed:
   `storage.rs#delete_finished_segment` calls `live_floor()` inside the lock and
   returns `NotFound` when `id >= floor`). A protection installed between scan
   and delete -- the recorder lowering the live floor, or `nova` persisting a
   protect-floor seq -- is caught there, never missed by the stale scan snapshot.
   `nova` plugs in two more predicates the same way: inode `nlink > 1` (incident
   hardlinks -- nearly free, the scan already stats every file) and a persisted
   minimum protect-floor seq. Both MUST be rechecked in the coordinator's
   in-mutex delete path (the authority); mirroring them in `evictable` is a
   scan-time optimization only.
7. **Witness raises are amortized per pass, not per eviction.** The naive
   "raise `high_water_seq` to the id before each unlink" rewrites `state.json`
   (tmp+fsync+rename+dir-fsync) on *every* drip in a continuous session,
   because the witness only carries the session-start id while thousands of
   rollover segments trail above it (ADR 16). GC instead does one write-ahead
   raise *per pass*, and only when the batch it is about to delete crosses the
   committed witness: it jumps the witness to the newest finished segment
   (`scan_max`), so the following ~thousands of oldest-first drips all satisfy
   the fast-path skip until the ring rotates past `scan_max` and one more raise
   fires. Guard on `batch_max` (what we unlink), jump to `scan_max` (newest
   finished) -- this decouples *when* we write (rarely) from *how far* we jump
   (far). Raising the witness above surviving/live segments is always safe: it
   only forbids id reuse, never causes deletion, and allocation already takes
   `max(witness, max_file_seq)`.

Verified code anchors (exploration 2026-07-10): the whole eviction primitive
already exists as `storage.rs#delete_finished_segment` (mutation mutex, mount
witness, live-floor refusal, `clips.rs#segment_paths_for_id` all-duplicate
unlink, write-ahead `high_water_seq` raise, dir fsync); candidates come from
`clips.rs#segment_candidates` (currently private; sorted by `seq`, dedupes
bare+stamped); `sysfacts.rs#disk_usage` already wraps rustix `statvfs` (but
reports `f_bfree` and serializes into the golden-corpus-pinned
`Snapshot.storage`, so `avail` must be a sibling fn, never a `DiskUsage`
field); `clip_removed` flows `Backend::note_clip_removed` ->
`Input::ClipRemoved` -> `Event::ClipRemoved` without touching recorder state;
the mock backend (`backend.rs#run_mock_recording_writer`) writes real `.ts`
files so the Mac dev loop exercises GC end to end; boot scrub runs in
`main.rs#scrub_unrecoverable_leftovers` before any backend spawn.

## Commit 1 -- `docs(raspi): add ring-GC drip-eviction ADR and roadmap silt swoop`

- New `raspi/docs/design/21-2026-07-10-ring-gc-drip-eviction.md` (Accepted).
  Decision content: the six pivots above, plus:
  - Eviction reuses `delete_finished_segment` per id; a GC pass does NOT hold
    the mutation mutex for its duration -- it acquires and releases the mutex
    separately for the one write-ahead batch raise and then once per *attempted*
    per-id deletion, with the full-directory scan and the probe running
    mutex-free between them. `MAX_EVICTIONS_PER_BATCH` caps only *successful*
    evictions and their `clip_removed` events, NOT attempts: a refused candidate
    (in-mutex live-floor/protection recheck returns `NotFound`, F17) consumes no
    cap budget, so the pass keeps descending the ordered scan and its mutex
    acquisitions and attempted deletions can span the whole evictable list, not
    just 16 -- there is no "at most 17 acquisitions" latency bound, and `nova`
    (which adds per-id refusals) must not inherit one. What IS bounded is the
    size of each individual hold: record the per-acquisition mutex latency
    budget for `nova`'s future lock-latency reasoning -- the lock saga holds the
    same mutex across an awaited fsync, so every one of these GC acquisitions
    must stay small (each is a single unlink-group or one witness fsync), and
    the pass must never coalesce them into one long hold. The batch pre-raise
    guards on `prefix_max` (the oldest-`MAX_EVICTIONS_PER_BATCH` ceiling if none
    are refused), not on the highest id actually unlinked -- under refusals the
    pass can unlink ids above `prefix_max`, whose witness coverage comes from
    `delete_finished_segment`'s own per-id write-ahead raise, so `prefix_max` is
    NOT an "always the highest unlinked id" invariant.
  - Amortized witness raise: one write-ahead `high_water_seq` raise *per pass*
    (to the newest finished segment `scan_max`), gated on the batch crossing
    the committed witness -- NOT one rewrite per unlinked id. State the naive
    per-id failure mode (continuous session witness trails thousands of
    rollover ids, so every drip would fsync `state.json`) and the fix
    (guard on `batch_max`, jump to `scan_max`; safe because a witness above
    surviving/live segments only forbids id reuse). Per-id
    `delete_finished_segment` keeps its own raise for the standalone manual-
    DELETE path (ADR 17); after the pass pre-raise those per-id raises degrade
    to a cheap read-and-skip (no fsync).
  - Bounded batches (`MAX_EVICTIONS_PER_BATCH = 16`) cap one `clip_removed`
    burst (a lagged SSE client reconnects to a fresh snapshot -- existing,
    correct behavior) and the number of evicted ids per pass. State the cap's
    limits precisely so `nova` does not inherit false latency/recovery
    assumptions: it is strictly an *id/event* bound, NOT a bound on the
    per-pass full-directory scan, the raw unlink count, or blocking duration.
    One id's duplicate paths (bare + stamped) are unlinked *sequentially*, not
    atomically: a mid-group unlink error leaves the remaining paths in place,
    the pass returns `Failed` with no `clip_removed` emitted for that id, and
    the next pass retries the group before the event is ever emitted (events
    fire only on a fully-successful `delete_finished_segment`). So the
    per-batch unlink count and wall-time can both exceed the cap; only the
    id/event count is bounded by it.
  - Below floor but nothing evictable / probe unavailable / unlink failure:
    one loud `tracing::error!` + 30 s backoff, never spin, never evict blind;
    recording then hits ENOSPC honestly. Card-health UI surface belongs to
    `kelp`.
  - Ordering slot for `nova`: a finalize-time incident linker must run before
    GC can consider that segment.
  - Protection authority is the in-mutex recheck (F9): every eviction candidate
    is re-tested against the live floor (and, later, `nova`'s `nlink`/protect-
    floor predicates) inside `delete_finished_segment` under the mutation mutex,
    immediately before the witness raise/unlink. The mutex-free scan's
    `evictable` filter is only an optimization; a protect-floor or live-floor
    change landing between scan and delete is honored by the in-mutex recheck,
    preserving the coordinator's GC-vs-lock serialization the `nova` lock saga
    depends on. The pass treats an in-mutex refusal as skip-not-evict (the
    `Err(NotFound)` arm), never blind-deletes on the stale snapshot.
  - Idle eviction is allowed (recorder idle -> `unpullable_from` is `None` ->
    the newest finished segment is evictable). Space cannot grow while idle, so
    once the floor is met GC stops until space drops again -- but reaching the
    floor is NOT necessarily one pass: an initial deficit larger than
    `MAX_EVICTIONS_PER_BATCH` returns `BatchCapped`, and the worker loops
    immediately (no backoff wait) through as many capped passes as it takes.
    Only a floor above the partition size (dev trick) can drain the whole ring,
    and it does so via a burst of back-to-back capped passes, not a single one.
  - Mid-pull eviction: POSIX unlink keeps an open fd streaming; the next
    ranged request 404s and the app's pull treats that as terminal (accepted).
  - Eviction prunes the in-memory `DurationCache` (`note_clip_removed` calls
    `DurationCache::forget`): the cache inserts one entry per finalized segment
    and had no eviction path, so continuous ring operation would grow it for the
    process lifetime on the 512 MB Pi. Ids never repeat, so forgetting is pure
    reclamation.
  - Consequences notes (app-side): cached MP4s are deliberately KEPT on eviction
    (ids never reused; watched footage surviving roll-off is a product feature --
    only manual delete purges the cache); `ClipsFeature` removal tombstones are
    scoped to outstanding request generations and released as those requests
    settle (commit 6, F16), so continuous eviction no longer grows an unbounded
    suppression set -- with no head/page request in flight the removal adds no
    lasting tombstone at all; viewer degrades to failed state if its clip evicts
    mid-pull.
- Comprehensively cross-reference ADR 21 from every accepted decision the flat
  stateless layout supersedes (F13 -- a note beside one heading leaves the rest
  of the accepted guidance still describing flat as transitional, contradicting
  the new end state):
  - ADR 03 (`raspi/docs/design/03-2026-06-23-storage-ring-buffer-incident-lock.md`):
    dated scoped-supersession `> **Note (2026-07-10)**` beside "Retention And
    Ring GC" (hysteresis high/low watermarks -> drip; percent headroom ->
    `f_bavail` byte floor) AND beside the "On-Disk Layout", "Index, Listing, And
    Rebuild", and "Concurrency Model" sections that still cast `segments/`,
    `index.log`, `index.snapshot`, and the in-memory index as the target: those
    are superseded -- stamped filenames (ADR 15/20) ARE the index, the flat
    layout is the end state, and stateless per-op scans are the realized posture.
    Hardlink incident locks, locked-space caps, pre-sync holds, and the
    single-writer coordinator model stay live (`nova` still builds on them).
  - ADR 16 (`raspi/docs/design/16-2026-07-02-storage-coordinator-segment-id-witness.md`):
    dated `> **Note (2026-07-10)**` beside its "current on-disk shape remains
    transitional" / future-`segments/`-subdir language and its "Target invariant"
    block. The write-ahead-delete witness rule ("any future mutation that removes
    a segment file must first persist `high_water_seq >= seq` under the same
    coordinator mutex") stays LIVE and is exactly what `silt` builds on; what ADR
    21 supersedes is the framing that flat is transitional and that rollover-id
    witness coverage waits on moving finalize/register into the coordinator --
    `silt`'s amortized per-pass witness raise (pivot 7) is the realized
    rollover-id coverage without that move.
- `raspi/AGENTS.md#Design decisions` (F13): add the ADR 21 list entry and state
  that the flat, stamped-filename, stateless-scan layout is the end state (not a
  transitional shape), superseding ADR 03's `segments/`/`index.log`/in-memory
  index machinery. Keep AGENTS.md and the ADRs consistent in this same commit.
- `docs/roadmap.md`: insert before `kelp`:

  ```
  - [ ] **Swoop `silt` -- Ring-buffer GC (drip eviction).** Pi deletes oldest
        finished segments when /data available bytes fall below
        DANCAM_GC_FLOOR_BYTES (default 2 GiB), via the existing coordinator
        delete + clip_removed. Adds no wire surface (the app already folds
        clip_removed); the app change bounds its stale-response suppression so
        continuous clip_removed traffic no longer grows an unbounded tombstone
        set. Shapes the protection seam `nova` plugs incident hardlinks into.
        See raspi ADR 21.
  ```

Gate: `just adr-check`.

## Commit 2 -- `refactor(raspi): field-preserving witness read-modify-write`

Behavior-preserving. `raspi/service/src/storage.rs`:

```rust
#[derive(serde::Serialize, serde::Deserialize)]
struct StateWitness {
    high_water_seq: SegmentId,          // stays required: "{}" still fails closed
    #[serde(flatten)]
    extra: serde_json::Map<String, serde_json::Value>,  // preserved verbatim
}

fn read_witness_state(rec_dir: &Path) -> io::Result<Option<StateWitness>>
fn update_witness(rec_dir: &Path, mutate: impl FnOnce(&mut StateWitness)) -> io::Result<()>
```

`update_witness`: read current (absent -> default with `high_water_seq: 0`;
corrupt -> fail closed via existing `corrupt_witness_error`, never clobber),
mutate, then today's tmp+fsync+rename+dir-fsync sequence lifted from
`persist_witness`. Delete `persist_witness` (no shim). Callers:
`reserve_start_segment` -> `update_witness(|w| w.high_water_seq = next)`;
`delete_finished_segment` / `scrub_unrecoverable_segments` -> same shape with
`existing.max(id)` for now. Rationale: `read_witness` already tolerates unknown
fields but the writer DROPS them -- a live corruption class the moment `nova`
adds its second `state.json` field (its plan does); build the writer before two
writers exist.

Tests (`storage.rs#mod tests`, existing `TempRecDir` helpers):
- `witness_writer_preserves_unknown_fields_on_reserve`: seed
  `{"high_water_seq":10,"future":true}`; allocate; raw JSON keeps
  `"future":true`, `high_water_seq == 11`.
- Same preservation through delete and scrub paths.
- Existing suite untouched-green, especially `corrupt_witness_fails_closed`
  (pins that `high_water_seq` stays required despite the flatten) and
  `witness_tolerates_unknown_extra_keys`.

## Commit 3 -- `refactor(raspi): skip redundant witness rewrites on delete and scrub`

`raspi/service/src/storage.rs`:

Scope note (F1 commit-slicing): this commit lands ONLY
`raise_witness_at_least`, which has in-crate production callers here
(`delete_finished_segment`, `scrub_unrecoverable_segments`). The per-pass
`raise_witness_for_batch` coordinator method is deferred to commit 4, where its
only production caller (`run_gc_pass`) lands in the same commit -- landing it
here would leave a `pub(crate)` method with no production caller and trip
`dead_code` under `just raspi-check`'s `--all-targets -D warnings` (tests don't
count for the plain-lib target).

```rust
/// Write-ahead raise: durably ensure high_water_seq >= floor before any unlink.
/// No-ops (no write, no fsync) when the committed witness already covers it --
/// GC deletes oldest ids, so at steady state this saves an fsync per eviction.
fn raise_witness_at_least(rec_dir: &Path, floor: SegmentId) -> io::Result<()>
```

`raise_witness_at_least`: read; `Some(w) if w.high_water_seq >= floor` ->
`Ok(())`; else `update_witness(|w| w.high_water_seq = w.high_water_seq.max(floor))`.
Use in `delete_finished_segment` (replacing the read+max+persist block) and
`scrub_unrecoverable_segments`. Corrupt witness still fails closed before any
unlink (the fast-path read errors).

Tests:
- `delete_below_witness_skips_rewrite`: witness 9, delete id 2; assert no
  rewrite by making `state/` read-only for the call (a rewrite would `EACCES`;
  the skip returns `Ok`); allocation still yields 10.
- `gc_style_delete_of_highest_remaining_id_prevents_reuse`: segments 0..=3;
  delete 3 (witness -> 3); then delete 2, 1, 0 (skips); allocation == 4 with
  the dir empty. The witness-correctness scenario for oldest-first GC.
- `scrub_below_witness_skips_rewrite`.
- Existing `corrupt_witness_fails_delete_before_unlinking` and
  `delete_raises_witness_and_prevents_id_reuse` stay green.

## Commit 4 -- `feat(raspi): GC pass core, worker, startup, and f_bavail probe`

This commit lands the whole GC machinery in one green step because every
`pub(crate)`/private symbol below has its first production caller here (the pass
core calls `raise_witness_for_batch`; the worker calls the pass core; `main.rs`
spawns the worker). Splitting any of it earlier would trip `dead_code` under
`just raspi-check` (`--all-targets -D warnings`, plain-lib target has
`cfg(test)` off). Because it is large, the sub-sections below (batch raise, pass
core, worker, main wiring, `DurationCache::forget`) each list their own tests.

**Batch-raise coordinator method** (`raspi/service/src/storage.rs`; moved here
from commit 3 so it lands with its `run_gc_pass` caller):

```rust
/// Per-pass amortized raise used by GC (mutation mutex; write-ahead, durable).
/// Fails closed on a missing required mount before touching `state.json` (F5),
/// exactly like `delete_finished_segment`. Guard on `batch_max` (the pass passes
/// `prefix_max` here -- the highest id it would unlink if NO candidate is refused,
/// NOT a guaranteed ceiling on the actual highest unlink: under in-mutex refusals
/// the pass can descend past it, and those beyond-`batch_max` ids are covered by
/// `delete_finished_segment`'s own per-id `raise_witness_at_least`); when the
/// committed witness is below it, jump the
/// witness to `ceiling` (the newest finished segment observed this scan) in ONE
/// fsync so the following oldest-first drips satisfy `raise_witness_at_least`'s
/// fast path. When the witness already covers `batch_max`, does not write at all.
pub(crate) fn raise_witness_for_batch(
    &self,
    batch_max: SegmentId,
    ceiling: SegmentId,
) -> io::Result<()>
```

`raise_witness_for_batch` (coordinator method, takes the mutation mutex):
**first `self.ensure_rec_mounted()?` (F5 fail-closed), before any witness read
or write** -- this pre-raise runs ahead of the pass's first
`delete_finished_segment`, and that method fails closed on a missing
`required_mountpoint` (`storage.rs#delete_finished_segment` calls
`ensure_rec_mounted` before its own witness raise), so without this guard a GC
pass on an unmounted `/data` would rewrite `state.json` *before* any delete
rejected the missing mount -- violating fail-closed storage and breaking the
`pass_fails_closed_on_mount_witness` "no witness written" assertion. Then read
the committed witness once; if present and `high_water_seq >= batch_max`, return
`Ok(())` with no write; otherwise `raise_witness_at_least(ceiling)` (one durable
raise; `ceiling >= batch_max` by construction). This is the F1 amortization seam
-- `delete_finished_segment` keeps its own per-id raise for the standalone
manual-DELETE path, but after a GC pass pre-raises to `ceiling` each per-id
raise is a read-and-skip. Because the guard is on `batch_max` (not on `ceiling`,
which climbs every pass as the recorder writes), a continuous session raises the
witness roughly once per full ring rotation, not once per eviction.

Tests (`storage.rs#mod tests`):
- `raise_witness_for_batch_jumps_to_ceiling_when_below`: witness 0; call
  `(batch_max=3, ceiling=20)`; committed witness becomes 20 (one write);
  allocation yields 21.
- `raise_witness_for_batch_skips_write_when_batch_covered`: witness 20; make
  `state/` read-only; call `(batch_max=5, ceiling=20)`; returns `Ok`, witness
  still 20 (the read-only dir proves no write was attempted).
- `raise_witness_for_batch_fails_closed_on_corrupt_witness`: garbage
  `state.json`; call returns the corrupt-witness error, no write.
- `raise_witness_for_batch_fails_closed_on_missing_mount` (F5): coordinator
  built `.with_required_mountpoint(plain dir)`; witness 0; call
  `(batch_max=3, ceiling=20)` returns the mount-witness error and leaves
  `state.json` unwritten (mirrors
  `required_mountpoint_fails_delete_before_unlink_or_witness`). This is the
  unit-level twin of the pass-level `pass_fails_closed_on_mount_witness`.

`raspi/service/src/sysfacts.rs` -- sibling probe (NOT a `DiskUsage` field; that
struct is golden-corpus-pinned via `Snapshot.storage`):

```rust
/// Bytes available to the (non-root) service: f_bavail, not f_bfree -- ext4
/// reserves ~5% for root that we can never write.
pub fn disk_avail(path: &Path) -> Option<u64>
```

Smoke test: `disk_avail(temp_dir)` is `Some` and `<= disk_usage(temp_dir).total`.

`raspi/service/src/clips.rs`: `fn segment_candidates` -> `pub(crate)` (dedupe
is fine for ordering; `delete_finished_segment` re-collects all duplicate paths
per id itself).

New `raspi/service/src/gc.rs` (`pub mod gc;` in `lib.rs`):

```rust
pub const DEFAULT_GC_FLOOR_BYTES: u64 = 2 * 1024 * 1024 * 1024; // ~53 worst-case 38 MB segments
pub(crate) const MAX_EVICTIONS_PER_BATCH: usize = 16;          // caps ids + events, not raw unlinks

// Debug only: `Failed` carries an io::Error, which is not PartialEq, so the
// enum cannot derive PartialEq. Tests pattern-match variants (`matches!` /
// `if let`) and assert `deleted` and `error.kind()`, never `assert_eq!`.
#[derive(Debug)]
pub(crate) enum GcPass {
    AboveFloor,
    ReachedFloor { deleted: Vec<SegmentId> },
    BatchCapped  { deleted: Vec<SegmentId> },  // still below floor; caller loops
    Exhausted    { deleted: Vec<SegmentId> },  // below floor, nothing evictable
    ProbeUnavailable { deleted: Vec<SegmentId> },
    Failed { deleted: Vec<SegmentId>, error: io::Error },
}

pub(crate) fn run_gc_pass(
    storage: &StorageCoordinator,
    floor_bytes: u64,
    max_evictions: usize,
    avail: &dyn Fn() -> Option<u64>,
    live_floor: &dyn Fn() -> Option<SegmentId>,
    on_removed: &mut dyn FnMut(SegmentId),
) -> GcPass

/// Scan-time protection filter -- an OPTIMIZATION only, not the authority (F9).
/// v1: only the live recorder floor. nova adds, additively: inode nlink > 1
/// (incident hardlink) and a persisted min protect-floor seq. The authoritative
/// recheck is delete_finished_segment's in-mutex live_floor() test (and, for
/// nova, its predicates); anything installed between this scan and the delete is
/// caught there, so a stale snapshot here can never evict protected footage.
fn evictable(candidate: &SegmentCandidate, live_floor: Option<SegmentId>) -> bool
```

Pass algorithm: probe (`None` -> `ProbeUnavailable`, never evict blind);
`>= floor` -> `AboveFloor`. Scan `segment_candidates` (error -> `Failed`), sort
ascending by seq, filter `evictable`; empty while below floor -> `Exhausted`.
Let `scan_max` = newest evictable candidate's seq and `prefix_max` = the seq of
the `max_evictions`-th oldest evictable candidate (or `scan_max` when fewer than
`max_evictions` are evictable) -- the highest id this pass would unlink if none
are refused. **Pre-raise once (F1 amortization):**
`storage.raise_witness_for_batch(prefix_max, scan_max)?` (error -> `Failed`,
before any unlink) -- one fsync only when the would-be batch crosses the
committed witness, so a continuous session does not fsync per drip. Guarding on
`prefix_max` (the oldest-16 ceiling, well below a recent witness) is what
preserves amortization; jumping to `scan_max` is what covers the whole scan when
it does write.

**The cap counts successful evictions, not attempts (F17).** Iterate the FULL
ordered evictable list oldest-first (NOT a pre-sliced first-`max_evictions`
prefix -- a pre-slice lets protected candidates consume the slice while later
evictable footage is never attempted, which under `nova`'s per-id protection
would let GC back off or spin at ENOSPC with safely-evictable segments still on
disk). Maintain a `deleted: Vec<SegmentId>`; per candidate
`storage.delete_finished_segment(seq, live_floor)`:
- `Ok` -> `on_removed(seq)`, push `seq`; then **re-probe FIRST** (F22): if
  `avail() >= floor` return `ReachedFloor` -- the cap check must NOT preempt
  this, or a cap-th deletion that reaches the floor would wrongly return
  `BatchCapped` and trigger an immediate needless follow-up pass, contradicting
  the "still below floor" contract of `BatchCapped`. Only when still below floor,
  check the cap: `deleted.len() == max_evictions` -> `BatchCapped` (the caller
  loops immediately).
- `Err(NotFound)` -> skip and continue to the next candidate (raced a manual
  DELETE, or the in-mutex floor/protection recheck refused -- the mutex is the
  authority); a refusal consumes NO cap budget, so the pass keeps descending
  the scan toward footage it may evict.
- `Err(Io)` -> `Failed`.

Only after the full evictable list is exhausted while still below floor return
`Exhausted` -- never mid-scan on a refusal, so a refused prefix followed by an
evictable tail still makes progress in one pass rather than spinning at zero.
Witness coverage for candidates BEYOND `prefix_max` (reachable only when earlier
candidates are refused) is guaranteed by `delete_finished_segment`'s own per-id
write-ahead `raise_witness_at_least(id)` -- it always runs before the unlink, so
correctness never depends on the pass pre-raise having covered them. In the
common no-refusal path the pass never descends past `prefix_max`, so those per-id
raises stay skips and amortization is untouched; only the rare `nova`-refusal
tail pays a per-id fsync, which is acceptable for a degraded path and needs no
second coordinator raise. Never touches `state/` or `time/` by construction
(`segment_paths_for_id` matches parsed segment names only).

Unit tests (`gc.rs#mod tests`, `TempRecDir` + segment-filename helpers as in
`storage.rs#mod tests`; probes as closures over the dir or scripted
`RefCell<VecDeque<Option<u64>>>`):
- `pass_is_noop_at_or_above_floor`
- `pass_evicts_oldest_first_and_removes_all_duplicate_paths` (bare+stamped id 0)
- `pass_stops_at_floor_mid_batch`
- `pass_skips_ids_at_or_above_live_floor` (floor `Some(2)`, ids 0..=3: deletes
  0,1 then `Exhausted`; 2,3 intact)
- `pass_returns_exhausted_without_candidates` (empty dir; no `state/` created)
- `pass_batch_cap_returns_batch_capped` (cap 2, 4 evictable, all deletable, probe
  stays below floor through both deletions: two successes -> `BatchCapped` after
  the cap is hit by SUCCESSES, not attempts)
- `pass_cap_th_deletion_reaching_floor_returns_reached_floor` (F22 exact-cap
  boundary: cap 2, 3 evictable, all deletable, but a scripted probe crosses the
  floor exactly on the 2nd (cap-th) deletion -- assert the pass returns
  `ReachedFloor` with `deleted == [oldest, next]`, NOT `BatchCapped`, so the
  worker does not schedule a spurious immediate follow-up pass against an
  already-satisfied floor)
- `pass_skips_not_found_race` (`on_removed(0)` deletes id 1's file mid-pass)
- `pass_reaches_evictable_tail_after_refused_prefix` (F17 -- refused prefix does
  not starve later footage): ids 0..=3 all below floor; a scripted `live_floor`
  (or the in-mutex protection seam) refuses ids 0 and 1 in the coordinator but
  admits 2 and 3. Assert the pass descends past the refused prefix and evicts 2
  (and 3 if still below floor), that `deleted` reflects only the successes, and
  that it does NOT return `Exhausted`/`BatchCapped` with zero progress while
  evictable ids remain. With a small cap (e.g. 1), assert the refusals consume
  no cap budget -- one SUCCESS (id 2) triggers `BatchCapped`, not the two
  earlier refusals. Proves the cap counts successful evictions, not attempts,
  and that a protected prefix cannot spin GC at ENOSPC.
- `pass_fails_closed_on_mount_witness` (`with_required_mountpoint(plain dir)`:
  `Failed`, files intact, no witness written)
- `pass_reports_probe_unavailable` (up-front and after a deletion)
- `pass_reevaluates_live_floor_in_mutex_after_scan` (F9 -- protection authority
  is the in-mutex recheck, not the scan): a scripted `live_floor` closure
  returns `None` for every call the scan's `evictable` filter makes (so id 0 is
  scanned as evictable), then flips to `Some(0)` once `delete_finished_segment`
  calls it under the mutex (e.g. a `Cell<usize>` call counter). Assert id 0's
  files survive, `on_removed` is never called for 0, and the pass emits no
  `clip_removed` for it -- proving a protection installed between scan and delete
  is honored by the coordinator's in-mutex recheck, never missed by the stale
  scan snapshot. This is the behavioral race test for the `evictable`-is-only-an-
  optimization contract `nova` inherits.
- `pass_deletes_below_witness_without_rewriting_it` (ties commit 3 in:
  witness above all ids; `state.json` bytes unchanged)
- `pass_amortizes_witness_writes_across_continuous_session` (F1 regression --
  the case the naive design breaks): seed a session-start witness of 0 with
  finished rollover segments 1..=20 all above it; run five drip passes whose
  probe returns below-floor for exactly one deletion each, then above. Assert
  the committed witness jumps to `scan_max` (20) on pass 1 and that passes 2-5
  perform NO witness write -- proved by making `state/` read-only for passes
  2-5 and asserting they still succeed and delete their id (a per-drip fsync
  would `EACCES`). ids 1..=5 deleted, 6..=20 intact. Distinct from the old
  `gc_style_...` test, which only pins single-delete witness correctness.
- `pass_failed_mid_duplicate_group_retries_and_emits_once` (pins the
  partial-duplicate failure contract the ADR documents): seed id 0 with two
  duplicate paths (bare + stamped) and make the *second* `remove_file` fail
  after the first path is already gone. A filesystem trick cannot induce this
  deterministically: both `clips.rs#segment_candidates` and
  `clips.rs#segment_paths_for_id` drop non-files via `metadata.is_file()`, so
  replacing the second path with a directory just excludes it from the group --
  the delete then unlinks only the first file, succeeds, and emits
  `clip_removed`, the exact opposite of the contract. Instead add a
  compiled-out fault seam in storage's segment-unlink helper: a
  `#[cfg(test)]`-gated thread-local counter (`FAIL_UNLINK_AFTER`) that the real
  `remove_file` wrapper consults and, when armed, returns a synthetic
  `io::Error` on the Nth call within this thread. Production builds compile the
  check out entirely (zero signature change, zero runtime cost), and the seam
  lives in `storage.rs` beside `delete_finished_segment`, not threaded through
  `run_gc_pass`. The test arms it to fail on the 2nd unlink of the group, drives
  one `run_gc_pass`, and asserts: `GcPass::Failed`, the *first* path gone but the
  *second* real duplicate file still present (retryable), and `on_removed` NOT
  called (no premature `clip_removed`). Then disarm the seam and re-run
  `run_gc_pass`; assert the surviving path is now gone and `on_removed(0)` fires
  exactly once. Covers the gap the mount-witness test (fails before any
  deletion) and the happy-path duplicate-removal test leave open.

The GC worker, its pure `GcBackoff` policy, `main.rs` wiring, and integration
tests all land in this same commit 4 (below):

`raspi/service/src/gc.rs`:

```rust
pub struct GcConfig {
    pub floor_bytes: u64,
    pub interval: Duration,                                // production: 2 s
    pub probe: Arc<dyn Fn() -> Option<u64> + Send + Sync>, // production: sysfacts::disk_avail(rec_dir)
}
impl GcConfig { pub fn from_env(rec_dir: Arc<Path>) -> Self }
pub(crate) fn parse_floor_bytes(raw: Option<&str>) -> u64  // pure; garbage -> default (warn), "0" -> 0
pub fn spawn_gc(storage: Arc<StorageCoordinator>, backend: Arc<dyn Backend>, config: GcConfig) -> JoinHandle<()>
```

**Scheduling is a pure policy (F2), not ad-hoc `if`s.** Modeled on
`backend.rs#InflightSyncCadence`; no I/O and no clock of its own -- the caller
passes a `tokio::time::Instant` (so `tokio::time::pause`/`advance` drive it in
tests; the `Instant` below is `tokio::time::Instant`, not `std::time::Instant`):

```rust
pub(crate) const GC_BACKOFF: Duration = Duration::from_secs(30);

/// Pure GC scheduling policy. Arms a backoff deadline on a below-floor stall,
/// clears it on progress, and tells the worker when to loop without waiting.
pub(crate) struct GcBackoff { retry_at: Option<Instant> }

pub(crate) enum GcStep { Continue, Wait }  // Continue = re-run now (BatchCapped)

impl GcBackoff {
    pub(crate) fn new() -> Self                              // retry_at: None
    pub(crate) fn ready(&self, now: Instant) -> bool         // no deadline, or now >= deadline
    pub(crate) fn record(&mut self, outcome: &GcPass, now: Instant) -> GcStep
}
```

`record`: `AboveFloor`/`ReachedFloor` -> `retry_at = None`, `Wait`;
`BatchCapped` -> `retry_at = None`, `Continue`;
`Exhausted`/`ProbeUnavailable`/`Failed` -> `retry_at = Some(now + GC_BACKOFF)`,
`Wait`. `ready(now)` = `retry_at.map_or(true, |t| now >= t)`.

Worker loop mirrors `events.rs#spawn_telemetry`: `tokio::time::interval`; on
each tick, `if !backoff.ready(tokio::time::Instant::now()) { continue }`; otherwise run a
pass via `tokio::task::spawn_blocking` (probe + scan + unlinks are blocking;
`Backend::note_clip_removed` is sync `hub.drive_now`, safe from the blocking
thread -- `on_removed = |id| backend.note_clip_removed(id)`, emitted per
durable success, in order). A `spawn_blocking` `JoinError` (the blocking
closure panicked) is mapped to a synthetic below-floor stall: one loud
`tracing::error!` and `backoff.record` as if `Failed` -- the worker never
unwraps the `JoinResult` and never dies. Then `match backoff.record(&outcome, tokio::time::Instant::now())`:
`GcStep::Continue` -> loop immediately (re-run without awaiting the next tick);
`GcStep::Wait` -> await the next interval tick. Info-log the deleted count on
progress; the loud `error!` for `Exhausted`/`Failed`/`ProbeUnavailable` fires
inside the stall arm. The interval's first tick fires immediately => the
startup pass; `main.rs` spawns the worker after `scrub_unrecoverable_leftovers`
has run.

`GcBackoff` unit tests (`gc.rs#mod tests`; `#[tokio::test(start_paused = true)]`
so `tokio::time::Instant::now()` is a deterministic base, plus `Duration`
offsets -- no wall clock):
- `first_stall_arms_backoff`: `record(Failed, t0)` -> `ready(t0)` false.
- `backoff_holds_before_deadline`: `ready(t0 + GC_BACKOFF - 1ms)` false.
- `backoff_expires_at_deadline`: `ready(t0 + GC_BACKOFF)` true.
- `progress_clears_backoff`: after `Failed`, `record(ReachedFloor, t1)` returns
  `Wait` and `ready(t1)` true.
- `batch_capped_requests_immediate_continue`: `record(BatchCapped, t0)` returns
  `Continue` and leaves `ready` true.
- `exhausted_and_probe_unavailable_arm_backoff`: both -> `ready` false.

These pin spin-safety directly: a below-floor stall cannot re-run before the
deadline, so the "scan/unlink/log every 2 s" regression fails the test.

Worker panic/backoff wiring test (`gc.rs#mod tests`, NOT the external
`tests/gc.rs` crate -- it reads `pub(crate) GC_BACKOFF`, which an integration
crate cannot; it drives `spawn_gc` with a minimal in-crate `#[cfg(test)]`
no-op `Backend` stub, since a panicking probe never reaches
`note_clip_removed`):
- `gc_worker_panic_arms_backoff_then_retries_after_deadline` (a `spawn_blocking`
  `JoinError` actually arms backoff, proven by paused time, not by absence of
  activity): `#[tokio::test(start_paused = true)]` with a probe closure backed
  by an `AtomicUsize` call counter that panics on call 1 and returns a normal
  `Some(avail)` afterward. Advance to just before the deadline
  (`GC_BACKOFF - epsilon`) and assert the counter is still 1 -- the worker did
  not re-probe, so the panic-mapped `Failed` genuinely suppressed work through
  the backoff window (a plain interval wait would be indistinguishable without
  this). Advance to the deadline and assert the counter reaches 2 -- backoff
  expired and the worker retried. Also assert the task never completes (survived
  the `JoinError`) and logged the loud error. Requires the `GcBackoff` policy
  clock to be `tokio::time::Instant` (which `tokio::time::pause`/`advance`
  control) rather than `std::time::Instant`; the worker feeds
  `tokio::time::Instant::now()` into `backoff.ready`/`record`.
- `gc_worker_drains_multiple_capped_batches_in_one_startup_turn` (F14 -- proves
  the WORKER honors `GcStep::Continue` by re-running immediately, not awaiting
  the interval): `#[tokio::test(start_paused = true)]`, `GcConfig.interval` =
  60 s, the same in-crate `#[cfg(test)]` no-op-hub `Backend` stub, and a probe
  closure that reports below-floor until the seeded ring drains to a target
  count. Seed more than `MAX_EVICTIONS_PER_BATCH` finished segments (e.g. 20) so
  the first pass returns `BatchCapped` after 16. WITHOUT advancing time past the
  immediate first tick, assert all 20 (down to the floor target) are evicted --
  the worker looped through back-to-back capped passes on `GcStep::Continue`. If
  `spawn_gc` ever awaited the 60 s interval between capped passes, no time
  advance means only the first 16 evict and the assert fails. Complements the
  pure `batch_capped_requests_immediate_continue` policy test by pinning the
  worker's behavior, not just the policy's return value.

`start_paused`, `tokio::time::pause`, and `advance` all live behind Tokio's
`test-util` feature, which the crate does not currently enable. Commit 4 adds it
for test builds only -- `[dev-dependencies] tokio = { ..., features = [...,
"test-util"] }` (or the equivalent feature line on the existing dev-dependency)
-- so both the `GcBackoff` unit tests and this panic test compile. Production
`[dependencies]` tokio features are untouched, so `test-util` never ships in the
Pi binary.

`raspi/service/src/main.rs`, after `spawn_telemetry`:

```rust
let gc = dancam::gc::GcConfig::from_env(state.storage.rec_dir());
if gc.floor_bytes > 0 {
    tracing::info!(floor_bytes = gc.floor_bytes, "segment gc enabled");
    dancam::gc::spawn_gc(state.storage.clone(), state.backend.clone(), gc);
}
```

One call site covers camera and mock backends (both hang off `AppState`), so
`just raspi-mock` gets GC parity for free.

**Bound `DurationCache` on eviction.** `ts_duration.rs#DurationCache` is a
`Mutex<HashMap<u32, (u64, Option<u64>)>>` that `duration_ms` inserts into for
every finalized segment and never prunes. Before GC, disk exhaustion indirectly
capped it; with continuous ring eviction it would grow for the whole process
lifetime on the 512 MB Pi. Add a `forget` reclamation path AND close a
`forget`/`duration_ms` resurrection race (F6):

```rust
struct DurationCacheState {
    entries: HashMap<u32, (u64, Option<u64>)>,
    generation: u64, // bumped on every forget while the state mutex is held
}

pub struct DurationCache {
    state: Mutex<DurationCacheState>,
}

impl DurationCache {
    /// Drop a segment's cached duration once it is evicted; ids never repeat
    /// (witness), so this is pure reclamation. Bumps `generation` so any
    /// `duration_ms` computation already in flight for this id does not
    /// resurrect the entry after this remove.
    pub(crate) fn forget(&self, seq: u32)  // one lock: bump generation + remove entry
}
```

The race: `duration_ms` (`ts_duration.rs#duration_ms`) drops the entries mutex
across the multi-hundred-KB file read in `segment_duration_ms`, then re-locks to
`insert`. There are TWO distinct resurrection windows, and the generation
counter alone closes only the first:
- **Concurrent forget (F6)** -- `forget(seq)` runs inside the read window: its
  `remove` is immediately undone by the trailing `insert`. The generation
  counter closes this (below).
- **Forget-before-lookup (F10)** -- eviction (`delete_finished_segment` then
  `forget`) completes ENTIRELY before a straggler `duration_ms` for the same id
  even starts (a listing captured the path pre-eviction, then reads it after).
  That lookup captures the ALREADY-bumped generation, so the generation check
  passes, and it inserts a stale/failed entry for an id that ids-never-repeat
  guarantees is never forgotten again -- the cache silently regresses to
  unbounded growth (one leaked entry per raced eviction; the mid-pull eviction
  path the ADR already accepts makes serve+evict overlap a real occurrence). The
  generation counter cannot see an eviction that finished before capture.
Holding the lock across the file read is the wrong fix -- it serializes every
duration lookup behind an unrelated segment's disk I/O. Instead combine a
cache-wide generation counter with a post-computation path-identity revalidation:
- Put the entries and the generation counter in one mutex-protected
  `DurationCacheState`. The initial lookup captures `state.generation` while
  holding that mutex, then releases it for the file read.
- After computing, take a single `path.metadata()` stat IMMEDIATELY BEFORE
  reacquiring the mutex (F18 -- NOT under the lock; a slow SD stat under the lock
  would serialize every duration lookup and every `forget` behind unrelated disk
  I/O, and the lock adds no safety to the stat itself). Save whether the file
  still exists with size `== bytes`. Then re-lock and `insert` ONLY if BOTH hold:
  `state.generation == gen` (no `forget` of this or any id took the same mutex
  and bumped it -- closes F6), AND the saved metadata result was `true` (the
  segment this computation described was still on disk when statted, not evicted
  -- closes F10). Because eviction unlinks the file BEFORE calling `forget`
  (`note_clip_removed` runs on durable delete success), the stat reliably catches
  a forget-before-lookup id whose file is already gone. Moving the stat ahead of
  the re-lock is still safe against an eviction landing in the stat->lock gap: an
  eviction runs `unlink` then `forget`, and `forget` bumps the generation and
  removes the entry under the same cache mutex. If that `forget` reaches the lock
  BEFORE this re-lock, the generation no longer matches `gen` and the insert is
  skipped; if it reaches the lock AFTER this insert, its `remove` deletes the
  just-inserted stale entry. Either ordering leaves no resurrected entry, so the
  cheap stat need not run under the lock. No I/O is held under the cache mutex.
- `forget` bumps the generation and removes the entry in the same short critical
  section. Keeping both operations under the existing cache mutex gives the
  invalidation one unambiguous ordering point; an atomic bumped before locking is
  deliberately NOT used, because a lookup already holding the mutex could observe
  that new generation before `forget` removes the entry, then reinsert after the
  remove.
Return the computed `dur_ms` regardless of whether the insert was skipped. The
mutex is released across BOTH the large file read AND the `metadata()` re-stat;
only the generation check, the saved-metadata-result check, and the `insert`
itself run under the re-lock -- no I/O.

Call `forget` from the eviction emit path in BOTH concrete backends'
`note_clip_removed` (`backend.rs#note_clip_removed` and
`camera/mod.rs#note_clip_removed`), right where each already emits
`Event::ClipRemoved`, via the shared `clip_durations` handle. Manual `DELETE`
flows through `note_clip_removed` too, so it also forgets -- correct, since a
deleted clip's file is gone. Tests:
- `ts_duration.rs#mod tests` `forget_evicts_entry_so_same_size_content_recomputes`:
  `duration_ms(seq, path, bytes)` to seed; overwrite the file with DIFFERENT
  content of the SAME byte length (the byte-length guard alone would return the
  stale value); `forget(seq)`; a second `duration_ms(seq, path, bytes)` returns
  the NEW content's duration -- proving the entry was dropped, not merely
  invalidated by size.
- `ts_duration.rs#mod tests` `forget_during_inflight_compute_does_not_resurrect`
  (F6 regression, deterministic, single-threaded): add a compiled-out
  `#[cfg(test)]` thread-local hook (mirroring commit 4's `FAIL_UNLINK_AFTER`
  seam) that `duration_ms` invokes exactly once after capturing `gen` and before
  the conditional insert; the test installs a hook that calls `forget(seq)` at
  that point, then drives one `duration_ms(seq, path, bytes)`. Assert the return
  value is the computed duration AND that `state.entries` does not contain `seq`
  afterward -- proving the stale-generation insert was skipped, not merely that
  size differed. Production compiles the hook out entirely (zero cost).
- `ts_duration.rs#mod tests` `forget_before_lookup_does_not_resurrect_evicted_id`
  (F10 regression, deterministic, single-threaded): the file for `seq` is absent
  (evicted before the lookup starts) and `forget(seq)` has ALREADY bumped the
  generation, so the generation check alone would pass. Drive one
  `duration_ms(seq, evicted_path, bytes)`; assert `state.entries` does NOT
  contain `seq` afterward -- proving the path-identity revalidation (the
  `metadata()` stat finding the file gone), NOT the generation counter, skipped
  the insert. Distinct from `forget_during_inflight_compute...`, which exercises
  the concurrent-forget window the generation counter alone closes; this one
  proves the eviction-finished-before-capture window is closed too.
- Extend a `tests/gc.rs` worker test (or the emit-order test) to assert the
  cache no longer contains an evicted id (e.g. a `len()`/`contains` test hook, or
  observe recompute), so the backend wiring -- not just the method -- is covered.

Integration tests, new `raspi/service/tests/gc.rs` (StubBackend + hub
subscription per the `tests/clips.rs` pattern):
- `gc_worker_evicts_oldest_and_emits_clip_removed_in_order`: seed 0
  (bare+stamped), 1, 2; probe derives "avail" from remaining file count (low
  until <= 1 id remains); assert `Event::ClipRemoved { id: 0 }` then
  `{ id: 1 }` on the hub, both id-0 paths gone, 2 intact.
- `gc_worker_runs_startup_pass_immediately`: interval 60 s (only the immediate
  first tick fits the test window), probe low-then-high; one `ClipRemoved`
  arrives promptly.
- `gc_worker_respects_live_recorder_floor`: stub with
  `unpullable_from == Some(2)`, probe always low; 2's file survives, no
  `ClipRemoved { id: 2 }`.
- `gc_eviction_preserves_inflight_pull_then_404s` (F4 -- server-side proof of
  the accepted mid-pull behavior): via the axum harness from `tests/clips.rs`,
  seed finished clip id 0 and issue a ranged `GET /v1/clips/0`; hold that
  response open (do not drain it). Evict id 0 (drive one `run_gc_pass` /
  `delete_finished_segment` for id 0). Then (a) drain the held response to EOF
  and assert it yields the original bytes in full -- POSIX keeps the open fd
  alive past unlink -- and (b) a fresh `GET /v1/clips/0` returns `404`. This is
  the Pi-side coverage the app's terminal-404 test cannot provide.
  (The panic/backoff regression is an in-crate `gc.rs#mod tests` unit test, not
  an integration test here -- see the `GcBackoff` unit-test block above -- because
  `#[tokio::test(start_paused = true)]` needs to read `pub(crate) GC_BACKOFF`,
  which an external `tests/` crate cannot reach.)
- `parse_floor_bytes` unit tests: absent -> default; `"0"` -> 0; garbage ->
  default (and warn); explicit value round-trips.
- Timing-dependent backoff behavior is pinned by the pure `GcBackoff` unit
  tests above, not by a flaky wall-clock integration test.

Note for clippy (`--all-targets -D warnings` via `just raspi-check`): because
this commit lands the pass core, `GcBackoff`/`GcStep`, `raise_witness_for_batch`,
and the worker together, every `pub(crate)`/private GC symbol has an in-crate
*production* caller (worker -> pass core -> coordinator method; `main.rs` ->
worker), so `dead_code` is satisfied without leaning on tests. `pub fn`
API-surface symbols (`disk_avail`, `spawn_gc`, `GcConfig`, `DEFAULT_GC_FLOOR_BYTES`)
are exempt from `dead_code` regardless; this note is about the `pub(crate)`/private
ones, which is exactly why they cannot land a commit earlier than their caller.

## Commit 5 -- `chore(raspi): mock GC dev-loop recipe and docs`

- `Justfile`, beside `raspi-mock`:

  ```
  # Watch ring GC evict live against the mock recorder: an intentionally huge
  # floor keeps the Mac's "avail" below it, so while recording every FINISHED 5s
  # mock segment becomes eviction fodder (drip oldest-first; only the currently
  # open segment, protected by the live floor, survives) and the loud
  # below-floor-exhausted warning + 30s backoff show up in the logs. After you
  # stop recording, that last segment becomes evictable too and drains on the
  # next retry, leaving the ring empty before Exhausted fires.
  raspi-mock-gc:
      mkdir -p raspi/service/.mock-rec
      cd raspi/service && DANCAM_REC_DIR=.mock-rec DANCAM_MOCK_SEGMENT_SECS=5 DANCAM_GC_FLOOR_BYTES=18446744073709551615 cargo run
  ```

  (A dev Mac has hundreds of GB available, so no realistic floor is crossable;
  pinning the floor above `avail` is the only way to watch eviction live. The
  `mkdir -p` mirrors `raspi-mock-clips`: it pre-creates the probe path so the
  startup probe measures a real directory (`Some(avail)`) instead of returning
  `ProbeUnavailable`. It does NOT avoid the startup backoff -- with an
  impossible floor and an empty dir the immediate first pass is below floor
  with nothing to evict, returns `Exhausted`, and arms the same 30 s backoff.
  So the real observed cadence under this recipe is: an initial ~30 s quiet
  window (no segments recorded yet, GC in Exhausted backoff), then, once
  recording is running, eviction in ~30 s bursts -- each backoff expiry runs
  one pass that evicts a batch of the segments accumulated during the wait
  (looping through capped passes when the backlog exceeds
  `MAX_EVICTIONS_PER_BATCH`), then returns to Exhausted/below-floor backoff.
  This bursty cadence is an artifact of the impossible dev floor, not the
  steady one-in-one-out drip a realistic floor produces; the recipe is for
  watching eviction + the loud exhausted-warning/backoff path fire, not for
  observing production rhythm.)
- `raspi/AGENTS.md`: add the `just raspi-mock-gc` bullet to the local Mac
  service loop section; document `DANCAM_GC_FLOOR_BYTES` (default 2 GiB, `0`
  disables) near the existing `DANCAM_REQUIRE_REC_MOUNT` note. No
  `dancam.service` unit change -- the in-binary default is the deployed
  behavior.
- `raspi/README.md` (F7 -- runbook is the ops source of truth per
  `AGENTS.md#Conventions`, and this adds a human-facing mock workflow + a new
  env knob): in the local mock-service section (the "For app development
  against the local mock Pi" block that already documents `just raspi-mock`,
  `DANCAM_REC_DIR`, and `DANCAM_MOCK_SEGMENT_SECS`), add `just raspi-mock-gc`,
  the `DANCAM_GC_FLOOR_BYTES` knob (default 2 GiB, `0` disables), and its
  expected dev cadence -- an initial ~30 s Exhausted-backoff quiet window, then
  eviction in ~30 s bursts under the impossible dev floor (NOT the steady
  one-in-one-out drip a realistic floor produces), matching the Justfile
  comment. Keep AGENTS.md and README consistent -- both land in this commit.

## Commit 6 -- `feat(app): scope removal tombstones to outstanding request generations and pin GC roll-off cache retention`

Two app-side changes, one file each of production and test. Independent of the
Pi commits (it does not depend on any Pi-side symbol), so it can land in any
order.

**Production change (F16 -- scope removal tombstones to outstanding request
generations).** Today `ClipsFeature.State.suppressedClipIDs: Set<Int>` only ever
GROWS: `deleteTapped`, `clipRemoved`, and `clipsResponse`'s
`authoritativeAbsentIDs` fold all insert, and nothing prunes. Manual deletes made
this a slow trickle; `silt`'s continuous GC eviction turns it into ~2,880
machine-paced tombstones/day for the process lifetime -- a transient-on-purpose
shortcut in the very feature that introduces the unbounded growth, which the
durable-feature stance (`AGENTS.md`: "Build each feature durable, not transient")
rejects. Supersedes the earlier plan decision to defer this as "future cleanup"
AND the round-6 `headEpoch`-scoped prune, which does not actually bound the set:
`headEpoch` is neither a deletion-confirmation clock nor a wall clock. A healthy
connection performs NO periodic successful head fetch
(`AppFeature.swift#shouldReloadClipsOnHeartbeat` reloads clips only when
`clips.status` is a retryable `.failed`, never on a healthy `.idle` link), so
under steady `clipRemoved` SSE traffic the epoch never advances and the prune
never fires -- the set grows for the process lifetime. And pruning by epoch is
unsafe: `deleteTapped` suppresses BEFORE its async DELETE resolves
(`ClipsFeature.swift#deleteTapped`), so an epoch prune could release an optimistic
tombstone while the server still holds the clip, letting a same-epoch page
resurrect it.

The correct clock is REQUEST LIFETIME. A tombstone exists only to stop a stale
in-flight head/page response (one that captured a server snapshot before the
removal) from resurrecting a just-removed row via `merged`/`reconciledHead`.
Because both `.clipsResponse` and `.pageResponse` are gated by
`epoch == state.headEpoch`, only requests at the current `headEpoch` can apply;
any request issued after the removal queries current server state (where a
GC-removed id is already gone). So a confirmed removal needs suppression ONLY
while some head/page request that BEGAN before the removal is still outstanding,
and NOT AT ALL when nothing is in flight -- which bounds the set by request
concurrency (one head + one page at most), not by eviction count or refresh
cadence.

`app/DanCam/DanCam/Features/Clips/ClipsFeature.swift`:
- Replace `var suppressedClipIDs: Set<Int> = []` with two pieces of request
  bookkeeping plus the tombstone map:
  - `var requestSeq = 0` -- a monotonic generation counter, bumped each time a
    head OR page fetch is ISSUED.
  - `var inFlightRequests: Set<Int> = []` -- the generations currently
    outstanding (issued, not yet settled or cancelled).
  - `var removalTombstones: [Int: Int] = [:]` -- clip id -> the `requestSeq`
    value at the moment its removal was CONFIRMED ("born-at" generation). A
    tombstone is retained only while some outstanding request has generation
    `<= bornAt` (i.e. began at or before the removal, so its response could
    still carry the stale row).
  `pendingDeleteIDs: Set<Int>` stays and ALWAYS suppresses until its DELETE
  resolves. `headEpoch`/`clipFinalizeEpoch` are unchanged -- `headEpoch` still
  gates which response applies; it no longer clocks tombstone lifetime.
- The suppressed set passed to `merged`/`reconciledHead` is derived at each call
  site as `pendingDeleteIDs.union(Set(removalTombstones.keys))` -- no change to
  the merge/reconcile logic, which still takes a `Set<Int>`.
- Issue/settle helpers thread a generation through every head/page effect so its
  response can settle it:
  - Issuing a head fetch (`.load`/`.refresh`) or page fetch (`loadMore`) does
    `state.requestSeq += 1; state.inFlightRequests.insert(state.requestSeq)` and
    carries that generation into the effect (the response action gains a
    `generation:` field alongside `epoch:`). Because `.load`/`.refresh` cancels
    the prior head fetch (`cancelInFlight: true`) and `clipsResponse` success /
    `onDisappear` cancel the page (`.cancel(id: pageID)`), track the current
    head and page generations (`var headRequest: Int?`, `var pageRequest: Int?`)
    so a cancel that yields no response still settles its generation.
  - Settling does `state.inFlightRequests.remove(generation)` then prunes -- but
    the ORDER relative to the merge is load-bearing (F20). Settle+prune must run
    AFTER any merge/reconcile the response performs, not before it. A tombstone
    born at generation `g` exists precisely to suppress the stale rows a
    still-in-flight request `<= g` would otherwise resurrect; settling `g` first
    drops that tombstone via `pruneTombstones` (nothing `<= g` remains in flight)
    and the subsequent merge then resurrects the row -- the exact resurrection
    `confirmedRemovalSuppressesStaleOlderPage` asserts against. So:
    - A response that does NOT apply (its `epoch` guard fails -> stale, merges
      nothing) or a FAILURE (merges nothing) settles immediately at the top of
      the handler -- there is no merge for its tombstone-set to protect, so
      dropping tombstones held only for it is correct.
    - A response that DOES apply (current `epoch`, success) reconciles/merges
      FIRST, using the derived suppressed set while its own generation is still
      outstanding, and settles its generation + prunes ONLY after the merge.
    - A cancel point (a cancelled head/page that yields no response) settles
      immediately -- it merges nothing.
  - `pruneTombstones`: `let floor = state.inFlightRequests.min();
    state.removalTombstones = state.removalTombstones.filter { _, bornAt in
    floor.map { $0 <= bornAt } ?? false }` -- keep a tombstone only if some
    outstanding request began at or before it; drop everything when nothing is in
    flight. Run it on every settle and every removal confirmation.
- Confirm-removal path: `clipRemoved(id)`, `deleteResponse` success, and
  `deleteResponse .failure(.http(404))` all do
  `state.removalTombstones[id] = state.requestSeq; state.pendingDeleteIDs.remove(id)`
  then `pruneTombstones` (so a removal with nothing older in flight adds no
  lasting tombstone). `deleteTapped` inserts into `pendingDeleteIDs` only (its
  optimistic suppression rides on pending until the DELETE resolves; success/404
  then converts it to a request-scoped tombstone, non-404 failure clears pending
  and re-merges the clip -- only a non-404 failure restores it).
- `clipsResponse` success: order is reconcile-then-settle (F20). First tombstone
  each `authoritativeAbsentIDs` at the current generation
  (`for id in reconciliation.authoritativeAbsentIDs { state.removalTombstones[id]
  = state.requestSeq }`), `pendingDeleteIDs.subtract(...)`, and reconcile/merge
  the head into `clips` using the derived suppressed set -- all while THIS head
  fetch's generation is still in `inFlightRequests`, so the reconcile cannot
  resurrect a row a concurrent stale page (or this very head's stale payload)
  still lists. ONLY THEN settle this head fetch's generation and `pruneTombstones`:
  because the reconcile has already run and this response's own generation is now
  cleared, any tombstone that was only being held for it (and no older request)
  is released immediately, while one still held for a concurrently-outstanding
  older page survives until that page settles. The existing `.cancel(id: pageID)`
  return also settles the tracked `pageRequest` generation (a cancel yields no
  response), keeping `inFlightRequests` accurate.
- Bound: the tombstone map holds at most one entry per removal observed while a
  head/page request predating it is still in flight; on a healthy idle
  connection (no request outstanding) it holds nothing, and it can never exceed
  the removals within a single request's lifetime. Bounded by request
  concurrency, not by eviction count or refresh cadence -- closing both the
  no-refresh leak and the optimistic-delete resurrection the epoch design left
  open.

**Characterization test (retained).** Guards the product decision that
GC-evicted (or manually-remote-removed) clips whose MP4 the user already watched
stay playable offline: `ClipsFeature`'s `.clipRemoved` fold drops the row but
must NOT purge `ClipCache`, whereas manual `deleteTapped` (via `deleteEffect`)
DOES purge. A future reducer consolidation routing both through one cache-purging
path would silently break offline retention; today nothing catches that.

`app/DanCam/DanCamTests/Features/Clips/ClipsFeatureTests.swift`:
- Add a `ClipCacheProbe` actor (records ids passed to `remove`) and extend the
  private `dependencies(...)` helper with a `cacheProbe:` param that injects a
  probe-wired `ClipCache`. `ClipCache.init` requires `lookup` and `insert`
  (only `remove` defaults -- `ClipCache.swift`), so `ClipCache(remove:)` alone
  does NOT compile; build it by copying `.noop` and overriding its `remove`
  closure (`remove` is a `var`):
  `var cache = ClipCache.noop; cache.remove = { await probe.record($0) }`,
  then inject `cache` through `AppDependencies`.
- `clipRemovedKeepsCachedFootage` (new): state with `clips: [clip(id: 7)]` and
  NO head/page request in flight; `send(.clipRemoved(id: 7))` asserts `clips ==
  []`, `removalTombstones.isEmpty` (nothing outstanding -> no lasting tombstone,
  the F16 bound), and `#expect(await cacheProbe.removedIDs() == [])` -- the
  eviction fold dropped the row and left the cache untouched.
- Strengthen the existing `deleteTappedOptimisticallyRemovesAndSuccessKeepsRemoved`
  (or add a sibling): after the delete round-trips, assert
  `await cacheProbe.removedIDs() == [7]` -- manual delete's cache purge stays
  covered, so the two paths are pinned as behaviorally distinct.
- `optimisticDeleteSurvivesRefreshBeforeDeleteResolves` (new, F16 -- the
  optimistic-delete/refresh race the epoch design lost): `send(.deleteTapped(clip
  7))` (pending, clips drops 7, DELETE in flight); before delivering
  `deleteResponse`, `send(.refresh)` and deliver its `clipsResponse` head whose
  payload STILL INCLUDES 7 (the server has not processed the DELETE yet). Assert
  `clips` does NOT contain 7 -- `pendingDeleteIDs` keeps 7 suppressed across the
  refresh regardless of generation. Then deliver `deleteResponse(.success)` and
  assert 7 stays gone and `removalTombstones` is bounded (empty once no request
  predating the confirmation is outstanding).
- `confirmedRemovalSuppressesStaleOlderPage` (new, F16 -- confirmed removal
  racing an older request): issue a page (`loadMore`, generation g in flight);
  `send(.clipRemoved(id: 7))` while g is outstanding -> `removalTombstones[7]`
  retained (an in-flight request began at/before the removal); deliver the stale
  `pageResponse` carrying clip 7 and assert `clips` does NOT contain 7. After the
  page settles, assert `removalTombstones[7] == nil` (released once no predating
  request remains).
- `manyRemovalsWithNoRequestInFlightStayBounded` (new, F16 -- the bound):
  with no head/page request outstanding, `send(.clipRemoved)` for a batch of ids
  (say 1...50); assert `removalTombstones.isEmpty` throughout and all rows are
  dropped from `clips` -- proving continuous GC traffic on a healthy idle
  connection accumulates zero tombstones.

F20 settle-ordering lifecycle matrix (new, F23 -- the round-7/8 fix left the
merge-then-settle ordering across the head, failure, and cancel paths uncovered;
`confirmedRemovalSuppressesStaleOlderPage` exercises only the successful *page*
path, and the optimistic-delete test rides `pendingDeleteIDs` so it cannot catch
tombstone mis-ordering). Each extends the existing head/cancellation tests rather
than adding infrastructure:
- `confirmedRemovalSuppressesStaleSuccessfulHead` (the successful-HEAD twin of
  the page test -- the case an implementation that settles before reconcile would
  fail): issue a head (`.load`/`.refresh`, generation g in flight); while g is
  outstanding `send(.clipRemoved(id: 7))` -> `removalTombstones[7]` retained;
  deliver g's stale but SUCCESSFUL `clipsResponse` whose payload still lists 7.
  Assert `clips` does NOT contain 7 (the reconcile ran while g was still in
  flight, so the derived suppressed set covered 7), and only AFTER g settles is
  `removalTombstones[7] == nil`. Fails against a reducer that settles+prunes at
  the top of the handler before reconciling.
- `retainedTombstoneReleasedOnFailureAndStaleSettlement` (failure/stale settle a
  retained tombstone): with a page generation g outstanding, `send(.clipRemoved(id:
  7))` (tombstone retained). Deliver a settlement that merges nothing -- either g
  as a `.failure`, or a now-stale response whose `epoch` guard fails -- and assert
  it settles g at the top: `inFlightRequests` no longer contains g AND
  `removalTombstones[7] == nil` (no predating request remains). Guards against a
  reducer that only settles on the success path, which would strand g in
  `inFlightRequests` and pin tombstone 7 forever (the leak F20's cancel/failure
  arms exist to prevent).
- `cancelOnlySettlementLeavesNoOrphanedGenerationOrTombstone` (cancel-only settle,
  covering all three cancel points): with a tombstone retained behind an
  outstanding generation, drive each cancel path -- (a) a head replacement
  (`.load`/`.refresh` with `cancelInFlight: true` supersedes the prior head), (b)
  `onDisappear` cancelling the page, and (c) a `clipsResponse` success cancelling
  the in-flight page (`.cancel(id: pageID)`) -- and assert each settles the
  cancelled generation (`inFlightRequests` drops it) and prunes, leaving no
  orphaned generation and no tombstone stranded once nothing predating it is in
  flight. Pins the "a cancel that yields no response still settles its
  generation" contract the `headRequest`/`pageRequest` tracking exists for.

The cache assertions are on observable effects (ids removed), not internal call
structure, so they survive a behavior-preserving reducer refactor; the tombstone
tests assert observable state (`clips`, `removalTombstones`, resurrection
behavior) rather than a call sequence.

Gate: `just app-test`.

## Verification

- Mac gates per commit: `just raspi-test`, `just raspi-check`; commit 1 also
  `just adr-check`.
- Mock end-to-end: `just raspi-mock-gc`, start recording via the app or with
  the full mutation request (F8 -- `/v1/recording/start` runs through
  `mutation.rs#require_mutation_headers`, which rejects any request missing
  `Content-Type: application/json` or a non-empty `Idempotency-Key`, so a bare
  `curl -X POST` 400s):

  ```
  curl -X POST http://127.0.0.1:8080/v1/recording/start \
    -H 'Content-Type: application/json' \
    -H 'Idempotency-Key: dev-gc-smoke-1' \
    -d '{}'
  ```

  (The handler takes no `Json` body extractor, so `-d '{}'` is ignored, but the
  `application/json` content type is still required; use a fresh
  `Idempotency-Key` per real start.) Watch finished 5 s segments get evicted
  oldest-first in the logs and `clip_removed` frames on `curl -N .../v1/events`;
  the app's Recent list should shed rows live with no errors. While recording,
  the currently open segment is protected by the live floor and survives (finished
  ones drip oldest-first); when you STOP recording that last segment becomes
  evictable (`unpullable_from` -> `None`), so the next retry deletes it too,
  leaving the ring empty -- only THEN (empty ring, nothing left to evict) does
  the Exhausted warning + 30 s backoff fire (F15). A residual "newest survives
  forever after stop" would be the idle-eviction regression to watch for.
- Real Pi: deploy, temporarily set a floor just below current `/data` avail
  (systemd drop-in or env for one run) to watch a real eviction, then a soak:
  record until `/data` crosses 2 GiB avail and confirm steady one-in-one-out
  eviction, the app riding along via `clip_removed`, and -- per the F1
  amortization -- that `high_water_seq` climbs in occasional jumps (one per
  ring rotation past the last `scan_max`), NOT once per evicted segment. A
  witness that advances every ~30 s in lockstep with evictions is the
  regression the amortized pre-raise exists to prevent.
- App: `just app-test` (or the Xcode test scheme) covers commit 6.

## Explicitly out of scope (seams left for later swoops)

- Incident protection predicates (`nlink > 1`, persisted protect-floor) and
  the finalize-linker-before-GC ordering: `nova`. Its predicates plug into the
  in-mutex recheck inside `delete_finished_segment` (the authority, F9), mirrored
  in `gc.rs#evictable` only as a scan-time optimization.
- `retention` max-age ceiling: no settings surface exists yet.
- Card-health / storage UI and format: `kelp`.
- App cleanup flagged, not built: an explicit "clip was removed" viewer
  dismissal. (Request-generation-scoped tombstone lifecycle is now BUILT in
  commit 6 (F16), not deferred.)

## Commit progress

- [x] 1. docs(raspi): add ring-GC drip-eviction ADR and roadmap silt swoop
- [x] 2. refactor(raspi): field-preserving witness read-modify-write
- [x] 3. refactor(raspi): skip redundant witness rewrites on delete and scrub
- [ ] 4. feat(raspi): GC pass core, worker, startup, and f_bavail probe
- [ ] 5. chore(raspi): mock GC dev-loop recipe and docs
- [ ] 6. feat(app): scope removal tombstones to outstanding request generations and pin GC roll-off cache retention
