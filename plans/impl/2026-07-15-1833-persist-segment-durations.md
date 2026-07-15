# Persist segment durations in the finalized filename

## Context

`/v1/clips` takes ~6 s per cold 100-clip page because each segment's duration
is derived by a PTS scan reading 256 KB head + 512 KB tail from SD
(`raspi/service/src/ts_duration.rs#DurationCache`). The cache is in-memory
only, so every service restart is fully cold, and those cold scans contend
with recording start on the Zero 2 W -- inflating the first-segment delay from
~5 s to 13 s. Separately, `DurationCache::forget` bumps a global generation,
so any single deletion (GC evicts one id at a time) discards all in-flight
cache inserts, going cold again mid-session.

Diagnosis: `docs/research/3-first-segment-delay-and-shutdown-timeout.md`
(Anomaly 2; Recommended next work items C and D).

Fix shape: a finalized segment's duration is immutable, and the project
already chose self-describing filenames over sidecar indexes for durable
per-segment facts (storage.md decision log, 2026-07-02 and 2026-07-09). So:
stamp `dur_ms` into the filename as a fifth field via an atomic rename at
finalize time (when the data is hot and the duration is already computed for
`clip_finalized`), lazily backfill legacy segments once, and delete the
in-memory `DurationCache` entirely (per-id forget was considered and
rejected: once the filename is durable, the cache's only job is a rare-case
micro-optimization). Filenames never cross the wire -- the contract goldens,
ETag (`"{seq}-{bytes}"`), and the Swift app are all filename-agnostic -- so
this is a Pi-internal storage change.

Startup cache warming was rejected: it recreates the SD/CPU contention at the
worst time (right when recording starts after boot).

## Design

### New grammar (5-field, finalized form)

```
seg_<seq>_<boottag>_<session>_<monoMs>_<durMs>.ts
e.g. seg_00510_ffec6dedbed7_511_9593450_30016.ts
```

- 5-field = finalized with measured duration (immutable).
- 4-field = stamped at open: live, or finalized-but-unmeasurable (torn or
  implausible PTS span).
- Bare `seg_NNNNN.ts` = watcher never stamped it; duration stays best-effort
  per read (no boottag/mono facts to build a 5-field name from).
- `durMs` is canonical decimal `u64`, no padding; byte-identical re-render
  round-trip required, matching every other field.

Exactly two strict parsers exist and must move in lockstep:
`raspi/service/src/recorder.rs#parse_segment_filename` and
`raspi/camera/camera.py` `SEGMENT_RE`/`parse_segment_filename`. Everything
downstream (listing `raw_segment_candidates`, pull `resolve_segment`, delete
`segment_paths_for_id`, GC `segment_candidates`, Python watcher/fsync)
funnels through them with live per-request directory rescans -- nothing
caches paths.

When more than one valid path has the same sequence, every single-path
resolver uses the same total precedence key: higher fact rank first
(5-field finalized > 4-field stamped > bare), then the lexicographically
smallest filename among paths of the same rank. The strict grammar makes all
valid filenames ASCII, so Rust byte/string ordering and Python string
ordering agree. In Rust, centralize this comparison for `SegmentCandidate`
and make `dedupe_candidates` replace the current candidate when the new one
has a higher rank or the same rank and a smaller filename; therefore listing,
pull, finalize, GC candidate selection, and coordinator re-resolution agree
independently of `read_dir` order. In Python, apply the identical two-part
comparison in `resolve_segment_path` rather than letting directory order win.
Bulk deletion still returns/removes every matching path. Document this
duplicate-recovery rule in `docs/design/pi/storage.md`.

### Rename at finalize, under the storage coordinator

New method on `raspi/service/src/storage.rs#StorageCoordinator`, serialized
under the existing mutation mutex (closes rename-vs-delete/GC races for
free) and reusing the private `storage.rs#fn fsync_dir` for durability:

```rust
pub fn persist_segment_duration(&self, id: SegmentId, dur_ms: u64) -> io::Result<DurationPersist>
pub enum DurationPersist { Renamed, AlreadyPersisted, NoStampedPath, Vanished }
```

Under the lock: call `ensure_rec_mounted()` before touching `rec_dir` (the
same fail-closed boundary as allocation, delete, and GC); rescan by seq
(seq-keyed, never a cached path); missing -> `Vanished`; bare facts ->
`NoStampedPath`; already 5-field -> `AlreadyPersisted`; else re-render with
`dur_ms: Some(_)`, `fs::rename`, map rename `NotFound` to `Vanished` (debug
log), then `fsync_dir(rec_dir)`. Because re-resolution applies canonical
precedence, a coexisting 5-field path yields `AlreadyPersisted`; the method
must never select and rename a lower-ranked 4-field duplicate over it.

Deliberately no live-floor guard inside the method: both finalize sites run
while the floor still equals the finalizing id (camera finalizes N on
`segment_opened(N+1)`; the mock finalizes before `RecordingStopped` clears
the floor), so an `id < floor` check would refuse every legitimate finalize.
Safety comes from callers: finalize sites only pass ids whose writer has
moved on, and the listing backfill is floor-filtered. Document this in the
method comment.

### Finalize path

Reshape `raspi/service/src/clips.rs#clip_meta` (only called by the two
finalize sites) into:

```rust
pub(crate) fn finalize_clip_meta(storage: &StorageCoordinator, seq: SegmentId, time_store: &TimeStore) -> io::Result<Option<ClipMeta>>
```

It resolves the candidate; takes `facts.dur_ms` when present; otherwise runs
`ts_duration::segment_duration_ms` and, on `Some(dur)` with 4-field facts,
calls `persist_segment_duration` (failure logged, never blocks the event).
Scan `None` -> no rename. Keep the existing `TimeStore` retry behavior.

Both finalize sites swap their `Arc<DurationCache>` plumbing for the
`Arc<StorageCoordinator>` they already hold, still inside `spawn_blocking`:

- `raspi/service/src/camera/mod.rs#finalized_clip_meta` (and its callers in
  `apply_child_event`).
- `raspi/service/src/backend.rs#finalized_clip_meta` (mock backend).
  `backend.rs#open_mock_segment` keeps stamping 4-field at open
  (`SegmentFacts { dur_ms: None, .. }`).

### Opportunistic backfill in the listing

`list_clips` passes a live-floor reader (the backend handle/closure, not a
pre-sampled `Option<SegmentId>`) into the blocking listing. In
`clips.rs#read_finished_clips`, enumerate `segment_candidates` first, then
sample the live floor, and only then floor-filter, cursor-filter, or scan any
duration. This closes the window where recording can start after the async
handler's old floor snapshot but before the blocking directory scan. A
candidate at or above that post-enumeration floor is never scanned or
renamed. The floor reader remains live for the whole listing; the initial
sample is not permission to finish a cold page of scans.

For each remaining candidate without a filename duration -- whether 4-field
stamped or bare -- enter one dedicated listing-duration gate owned by
`StorageCoordinator`. The gate is separate from the mutation mutex and
covers fresh seq-keyed resolution, the PTS scan, and, for 4-field paths, the
call to `persist_segment_duration`. After waiting for the gate, re-resolve
first: if another request has already produced a 5-field name, use its
duration without scanning; if the candidate vanished, return that outcome
without a scan. Immediately before scanning -- after acquiring the gate and
fresh resolution -- sample recording activity again. If recording is active,
return `Deferred` with an unknown duration and do not scan or persist that
candidate. Otherwise scan the freshly resolved 4-field or bare path. On
`Some(dur)`, persist only a 4-field path; return a bare path's measured
duration without renaming it. Persistence errors are logged and the response
uses the computed value either way.

Keeping the expensive read outside the mutation mutex avoids delaying
allocation/delete/GC, while holding the listing-duration gate through the
short 4-field mutation prevents concurrent cold requests from scanning the
same legacy segment twice and prevents bare recovery scans from overlapping
other listing-triggered PTS reads.

Make that boundary an operation, not an exposed lock:

```rust
pub(crate) fn listing_segment_duration(
    &self,
    id: SegmentId,
    recording_active: impl FnOnce() -> bool,
    scan: impl FnOnce(&Path, u64) -> Option<u64>,
) -> io::Result<ListingDuration>

pub(crate) enum ListingDuration {
    FromName(u64),
    Scanned {
        dur_ms: Option<u64>,
        persist: Option<io::Result<DurationPersist>>,
    },
    Deferred,
    Vanished,
}
```

The method locks `listing_duration`, re-resolves `id` using canonical
precedence, selects the outcome, then invokes `recording_active`; only an
inactive, still-durationless 4-field or bare path reaches
`scan(path, bytes)`, using the byte count from that fresh resolution. The
callback reads the same backend floor source as initial listing filtering,
so a request that waited behind another listing scan cannot rely on its
earlier state. The scanner preserves
`segment_duration_ms`'s best-effort `Option<u64>` contract: open/read/seek
races, including delete or GC during measurement, become `None`, not a
listing error. For `Some(dur)` on a 4-field path, the method calls
`persist_segment_duration` before releasing the gate; for a bare path,
`persist` is `None` and the name remains unchanged. `clips.rs` supplies
`segment_duration_ms` as the scan closure and maps the outcome to response
metadata and counters.

Persistence failure is carried inside the `Scanned` outcome so listing can
log it and still return the computed duration. The outer `io::Result` is
reserved for fresh directory resolution failures. `DurationPersist::Vanished`
remains a successful raced outcome. The only nested lock order is listing
gate -> mutation mutex, and that nested acquisition occurs only for a
successfully measured 4-field path; no mutation path may acquire the listing
gate. Bare paths remain bare because they lack the boottag/session/mono facts
required to render a 5-field name. A concurrent delete/read race therefore
yields `dur_ms: None` for that candidate without failing the page.

This yield rule applies only to optional listing migration/recovery scans.
Finalize-time measurement still runs while recording is active because it
produces `clip_finalized` metadata for the segment whose writer just moved
on. Once recording begins during a cold listing, an already-running PTS scan
may complete, but every subsequent 4-field or bare candidate observes the
active floor and is returned unknown without SD reads or rename. Later
inactive listings retry deferred candidates.

The global listing-scan guarantee is: at most one listing-triggered PTS scan
is in flight across all requests and both legacy forms. Once recording is
observed active, every waiter re-checks activity after acquiring the shared
gate and defers without reading SD. The successful-persistence guarantee is:
after a duration has been durably persisted, future requests use the
filename and never scan that segment again. Failed scans, failed
persistence, process death, and power loss may retry because no durable
duration fact exists yet. Dur resolution moves up out of
`clip_meta_from_candidate` (which loses its
`Option<&DurationCache>` parameter) so the listing can count duration
sources and trigger backfill.

`read_finished_clips` takes the `StorageCoordinator`, the live-floor reader,
and the time store, and returns a page struct carrying `dur_sources` counts
(`from_name`, `scanned`, `backfilled`, `unknown`). The coordinator exposes
the listing-duration operation rather than its mutex guard so gate ownership
and lock ordering stay internal. `Deferred` increments `unknown`, not `scanned`
or `backfilled`, so the existing INFO counters expose that migration yielded
without adding an unbounded event.

While recording is inactive, one-time convergence cost for ~500 backfillable
4-field segments is 5 pages of scans plus per-id short mutation-mutex holds
and dir fsyncs -- dwarfed by the 768 KB/segment reads being eliminated. No
batching needed. Bare recovery files remain best-effort per listing because
they cannot carry the durable facts.

### Delete DurationCache

Remove `DurationCache`, its global generation, `forget`, the
`BEFORE_DURATION_INSERT` test hook, and their tests from
`raspi/service/src/ts_duration.rs`; keep `segment_duration_ms` (promoted
`pub(crate)`) and `ts_pts_packet`. Fallout:

- `Backend` trait drops `clip_durations()`; `AppState` drops
  `clip_durations` (`lib.rs`).
- `camera/mod.rs` / `backend.rs` `note_clip_removed` keep only the hub
  `ClipRemoved` drive; `gc.rs` reaches duration state through nothing
  anymore.
- `filesystem_observer.rs#DefaultProbe::observe_duration` calls
  `segment_duration_ms` directly -- no behavior change; the live segment's
  bytes grow every observation, so the cache was already an always-miss
  there.

Torn/bare segments whose scan persistently returns `None` re-scan per
listing appearance (~768 KB) -- rare, bounded, honest.

### Instrumentation (research item D)

One bounded INFO event inside `clips.rs#list_clips` (not span fields --
`lib.rs#request_trace` builds its span generically; the event inherits
`request_id`):

```rust
tracing::info!(cursor = ?cursor, limit, dur_from_name, dur_scanned, dur_backfilled, dur_unknown, "clips listed");
```

This supplies the page identity (cursor/limit) and zero-scan proof signal
the investigation lacked.

### Races (document in storage.md)

- Python fsync vs Rust rename: ordered away in the normal path --
  `camera.py#watch_segment_events` fsyncs the closed id before emitting
  `segment_opened`, and the watcher thread joins before `recording_stopped`;
  Rust only finalizes on those events. Residual overlap hits
  `try_fsync_segment`'s logged non-fatal `FileNotFoundError`; the next
  resolve is a fresh seq-keyed rescan.
- Renamed 5-field names cannot re-trigger watcher events:
  `detect_segment_events` only fires for `seq > prev_max`.
- Concurrent listings resolving duration: the coordinator listing-duration
  gate admits one scanner globally across 4-field and bare paths. A waiter
  for the same 4-field id re-resolves the new 5-field name and uses its
  duration without scanning; any waiter observes recording activity only
  after it acquires the gate.
- Recording starts during listing enumeration: the blocking listing samples
  the live floor after enumeration and before filtering/scanning, so the new
  live id is excluded even if it appeared in the candidate scan.
- Recording starts during a cold legacy page: every listing-triggered PTS
  scan re-reads activity immediately before its SD read after acquiring the
  shared gate; once active, remaining 4-field and bare candidates are
  deferred as unknown and are not renamed. The sole already-running scan may
  finish.
- Power cut between rename and dir fsync: old 4-field name may survive;
  re-scanned and re-renamed lazily. Harmless.
- Pull during the rename window: transient 404 possible between resolve and
  open -- same pre-existing class as the open-time stamping rename and
  deletion; already-open pulls survive (fd semantics), ETag is
  rename-stable.
- Duplicate same-sequence paths after an interrupted/manual recovery:
  single-path consumers deterministically choose higher fact rank, then the
  lexicographically smallest ASCII filename for a same-rank tie; deletion
  removes all forms. A lower-ranked duplicate is never scanned or renamed
  while a durable 5-field representation exists, and same-rank selection is
  independent of directory iteration order.

## Changes by file

- `raspi/service/src/recorder.rs`: `SegmentFacts` gains
  `pub dur_ms: Option<u64>`; `stamped_segment_filename` renders the fifth
  field when `Some`; `parse_segment_filename` gains the
  `[seq, boot, session, mono, dur]` arm with the same u64-bound +
  re-render check; unit tests.
- `raspi/camera/camera.py`: `SEGMENT_RE` gains an optional fifth group
  (`(?:_([0-9]+))?` inside the stamped alternative);
  `stamped_segment_filename(..., dur_ms_value=None)`;
  `parse_segment_filename` u64-bounds and re-renders the new group; watcher
  still stamps 4-field at open; `resolve_segment_path` ranks 5-field above
  4-field above bare and breaks same-rank ties by lexicographically smallest
  filename; self-tests mirror the Rust cases and total precedence.
- `raspi/service/src/storage.rs`: `persist_segment_duration` +
  `DurationPersist`, required-mount enforcement, and the dedicated
  listing-duration gate/operation shared by 4-field and bare scans, reusing
  `fsync_dir`.
- `raspi/service/src/clips.rs`: `clip_meta` -> `finalize_clip_meta`;
  `read_finished_clips` takes a live-floor reader and samples it after
  enumeration; filename-first gated 4-field backfill and gated best-effort
  bare scanning through the same coordinator operation, per-candidate
  recording-yield checks, and `dur_sources`;
  `dedupe_candidates` uses the shared total order of 5-field above 4-field
  above bare, then lexicographically smallest filename;
  `clip_meta_from_candidate` drops the cache parameter; `list_clips` INFO
  counters.
- `raspi/service/src/camera/mod.rs`, `raspi/service/src/backend.rs`: finalize
  sites swap cache handle for storage; `open_mock_segment` passes
  `dur_ms: None`; `note_clip_removed` slimmed; mock `SegmentFacts` sites
  updated.
- `raspi/service/src/ts_duration.rs`: delete `DurationCache` et al.; keep
  `segment_duration_ms`, `ts_pts_packet`.
- `raspi/service/src/lib.rs`, `raspi/service/src/filesystem_observer.rs`,
  `raspi/service/src/gc.rs`: cache-removal fallout.
- Test helpers hard-coding the 4-field form: `tests/mock_recording.rs`
  (`assert_new_segments_are_stamped`, `stamped_sessions`),
  `tests/camera_process.rs`, `clips.rs`/`storage.rs` `stamped_name` helpers.
- Docs: `docs/design/pi/storage.md` (On-disk model grammar, fifth-fact
  paragraph, second lifecycle rename, Filesystem-backed reads duration
  paragraph including the shared one-at-a-time gate for every
  listing-triggered legacy scan and the rule that listing migration yields
  while recording is active, duplicate recovery's fact-rank then
  lexicographically-smallest-filename total order, new dated decision-log
  entry "Persist measured duration in the finalized filename" recording
  rejected alternatives: startup warming, sidecar/index, keeping the cache
  with per-id forget);
  `docs/design/pi/recording.md` Segment observation and finalization
  (finalize now renames to the five-field form before publishing).
  `docs/research/3-...md` stays untouched (point-in-time).

## Behavioral tests

- Grammar round-trip, Rust (`recorder.rs`): 5-field round-trips; rejects
  padded dur (`_030016`), trailing underscore, >u64 dur, bad boottag;
  4-field still parses with `dur_ms == None`. Python
  (`camera.py#run_self_test`): mirrored, plus `fsync_segment` resolving a
  5-field name.
- Finalize renames on disk: extend
  `tests/events.rs#rollover_clip_is_pullable_when_clip_finalized_is_observed`
  and
  `tests/camera_process.rs#supervisor_tracks_rollover_and_finalizes_last_segment_on_stop`
  to assert the on-disk name parses to `dur_ms == Some(d)` equal to the
  `clip_finalized` event's and `/v1/clips`' `dur_ms`.
- Cold listing does zero scans (clips.rs unit): 5-field names over non-TS
  garbage content; listing returns filename durations (a scan would yield
  `None`); `dur_sources.from_name == n`.
- Cross-rank duplicate precedence (clips.rs unit): create same-sequence bare,
  4-field, and 5-field paths with distinct byte lengths, put non-TS garbage
  in the lower-ranked paths, and assert listing chooses the 5-field duration,
  bytes, and ETag with `from_name == 1`, `scanned == 0`, and no rename.
- Same-rank duplicate total order (Rust behavioral tests): in two temp
  directories, create equivalent duplicate sets in opposite creation order.
  Cover two valid 5-field names with distinct durations and byte lengths and
  two valid 4-field names with distinct facts, content, and byte lengths.
  Assert listing, pull resolution, GC candidate selection, and coordinator
  re-resolution all choose the lexicographically smallest filename and its
  duration/bytes, regardless of creation order; the non-canonical 4-field
  duplicate is neither scanned nor renamed.
- Python duplicate total order (`camera.py#run_self_test`): repeat the
  cross-rank case and both same-rank 5-field and 4-field cases in opposite
  creation orders, with distinct durations/byte lengths, and assert
  `resolve_segment_path` and fsync resolution always choose the
  lexicographically smallest filename within the highest rank.
- Backfill converges in one listing (clips.rs unit): 4-field name over real
  PTS content (`ts_pts_packet` fixtures); first listing returns the duration
  and the name is now 5-field; scramble contents to same-length garbage,
  list again -- duration still served `from_name`, proving zero scans.
- Measurement disappearance stays best-effort (clips.rs unit with a
  deterministic scan closure/hook): remove the freshly resolved 4-field
  candidate during measurement, return `None`, and assert `/v1/clips`
  succeeds with `dur_ms: None`, `dur_unknown` incremented, and no renamed
  path.
- Bare recovery duration remains available (clips.rs unit): a PTS-bearing
  `seg_NNNNN.ts` returns its measured duration on repeated listings and its
  path remains bare; replacing/removing it during a scan remains a
  successful page with an unknown duration.
- Live-floor snapshot regression (clips.rs unit, deterministic injected
  reader/hook): start with no floor, make recording begin after candidate
  enumeration at the former snapshot window, and assert the now-live
  4-field candidate is neither scanned nor renamed.
- Mid-page recording transition (clips.rs unit with ordered candidates and a
  scan probe): begin inactive with multiple legacy 4-field and bare
  candidates, flip the floor active from the first scan, and assert that
  scan may finish but every subsequent candidate returns unknown without a
  scan or rename. Include a 4-field candidate waiting behind the listing
  gate to prove activity is sampled after gate acquisition.
- Concurrent backfill convergence (coordinator/clips test with a blocking
  scan probe): start two listings for the same 4-field id, release the first
  scan, and assert the scan probe ran exactly once while both responses use
  the same duration.
- Mixed listing-scan serialization (coordinator/clips test with blocking
  probes): concurrently list distinct 4-field and bare ids while inactive;
  assert only one scan callback enters, make recording active before
  releasing it, then assert every waiter re-resolves and defers after taking
  the shared gate, no second scan overlaps or starts, and neither the bare
  path nor deferred 4-field paths are renamed.
- Never renames the wrong things: bare segments are coordinator-scanned but
  never renamed, and scan-`None` 4-field segments stay un-renamed; candidates
  at/above `unpullable_from` are never scanned or renamed.
- Coordinator unit (`storage.rs`): rename + idempotence
  (`AlreadyPersisted`), `Vanished` on missing seq, `NoStampedPath` on
  bare-only; coexisting 4-field + 5-field resolves to the 5-field path,
  returns `AlreadyPersisted`, and leaves both paths untouched; an invalid
  required mount returns an error before resolution or rename and leaves the
  4-field path untouched.
- Finalize persistence is best-effort (clips.rs unit with an invalid required
  mount after a valid duration scan): `finalize_clip_meta` still returns the
  computed metadata/duration, the original 4-field filename remains usable,
  and the caller can still publish `clip_finalized` without retaining its
  protective floor.
- Delete/GC over 5-field names: adapt the `segment_paths_for_id` test and
  one GC eviction test.
- Deleted with the cache: the `forget`/generation tests (existing
  404-after-delete tests cover the truthfulness of post-delete reads).

## Commit split (2 conventional commits)

1. `feat(raspi): persist segment durations in finalized filenames` -- both
   parsers/renderers and `SegmentFacts.dur_ms`; coordinator mount-safe rename
   and shared gated listing measurement/backfill; `finalize_clip_meta`
   reshape and both finalize-site swaps; post-enumeration live-floor
   sampling; filename-first listing and counters; grammar, race, failure,
   convergence, and e2e tests; complete storage.md and recording.md updates.
   This commit introduces, produces, consumes, and documents the 5-field
   contract atomically.
2. `refactor(raspi): remove the in-memory DurationCache` -- cache/
   generation/hook deletion, `Backend::clip_durations`/`AppState` removal,
   observer direct-scan, `note_clip_removed` slimming, test cleanup.

## Verification

- `just --list` for the test recipes; run the Rust service suite (unit +
  `tests/`) and the Python camera self-test per the Justfile.
- Simulator/mock path: run the mock backend (Justfile mock recipes), record
  a rollover, and confirm on disk that finalized segments carry the 5-field
  name and `/v1/clips` agrees with `clip_finalized`.
- On the real Pi (acceptance, per the research doc's safe protocol):
  deploy, restart the service, and `curl` two previously-cold `/v1/clips`
  pages -- first post-deploy pass backfills (one-time cost, watch the new
  "clips listed" INFO counters), then restart again and confirm pages
  return in the warm 8-15 ms range with `dur_scanned == 0`. Separately, with
  enough unbackfilled 4-field/bare segments to keep a cold listing busy,
  start recording after that request begins; confirm `dur_scanned` stops
  at the number completed before the transition plus at most one in-flight
  scan, remaining legacy durations are unknown/deferred, no further paths
  are renamed until recording stops, and first-segment delay is back at the
  ~5 s floor.

## Commit progress

- [x] 1. feat(raspi): persist segment durations in finalized filenames
- [ ] 2. refactor(raspi): remove the in-memory DurationCache
