# Plan: Power-cut in-flight durability, boot scrub of zero-byte leftovers, honest remux errors

## Context

A field power cut while recording produced `/data/rec/seg_00024_..._1705228.ts` as a
0-byte file. Root cause chain, fully diagnosed:

- The camera owner fsyncs a segment only at close
  (`raspi/camera/camera.py#watch_segment_events` -> `try_fsync_segment` on
  `segment_closed`), so the in-flight segment's data (~17 s, ~21 MB here) sat
  entirely in page cache.
- The Ansible dirty-writeback clamps (`vm.dirty_bytes=64MiB`,
  `vm.dirty_background_bytes=16MiB`) were **verified live on the Pi during the
  failure** and still saved nothing: ext4 delayed allocation commits size/extents
  only at writeback, so the journal preserved the stamped rename but zero data
  blocks. Empirical conclusion: only explicit periodic fdatasync bounds the loss
  window; writeback tuning demonstrably does not.
- After reboot the recorder boots Idle (`unpullable_from() == None`), the service
  reserved seg 25, and the 0-byte seg 24 listed as a normal finished clip
  (`bytes: 0`, etag `"24-0"`). The app pulled the empty body "successfully"
  (`HTTPBodyDecoder` treats `Content-Length: 0` as complete), then `TSDemuxer`
  threw `ClipRemuxError.invalidTransportStream("No H.264 PES packets found.")`,
  rendered to the user as the opaque "The operation couldn't be completed
  (DanCam.ClipRemuxError error 0.)" because `ClipRemuxError` has no
  `LocalizedError` conformance.

This breaks ADR 01's promise (`raspi/docs/design/01-2026-06-22-crash-safe-recording.md`)
that the partial segment is "usually still playable up to the cut". Three fixes,
three commits. The raspi work extends roadmap swoop `dune`'s "Service durability +
mount witness" bullet (`docs/roadmap.md`).

Facts that shape the design (verified in code):

- **Witness invariant:** `raspi/service/src/storage.rs#delete_finished_segment`
  raises the durable `state/state.json` `high_water_seq` **before** the first
  unlink, under the `StorageCoordinator` mutation mutex. Any scrub must do the
  same or `next_start_segment` could re-mint a deleted high id and alias an
  immutable ETag.
- **No boot races:** the camera child always dies with the service
  (`kill_on_drop` in `raspi/service/src/camera/mod.rs#spawn_child`, plus systemd
  cgroup kill), and recording never auto-starts (recorder boots Idle), so a boot
  scrub races no live writer.
- **Per-path recoverability, not canonical selection:**
  `raspi/service/src/clips.rs#dedupe_candidates` prefers the stamped file over a
  bare duplicate for the same seq *when listing*, but the boot scrub must not let
  that selection decide recoverability. A power cut can leave a stamped 0-byte file
  beside a bare nonzero file for the same seq (the nonzero file is recoverable
  video); letting the stamped-preferred canonical judge 0-byte-ness would delete it.
  The scrub therefore judges bytes **per path across every file for a seq** and only
  ever unlinks bytes that are themselves zero: it deletes a whole id (and raises the
  witness for it) only when *every* path for that seq is 0 bytes; a mixed group is
  repaired by unlinking just its zero-byte duplicate path(s) and keeping the nonzero
  segment. Timestamp facts never outrank nonzero video bytes in recovery.
- **DurationCache** (`raspi/service/src/ts_duration.rs`) is keyed by seq and
  validated by bytes, and is empty at boot -- the scrub needs no invalidation.
- **fsync *durability* is not in-process observable**: `flush`/plain writes already
  make file size visible in page cache, so a "bytes grow before rollover" test would
  pass without a real sync. Real durability is verified on hardware. What *is*
  in-process observable -- and therefore tested -- is the **wiring** (a periodic sync
  is actually invoked for the open segment on cadence) and the **error policy** (a
  failing sync is swallowed and never stops recording or the watcher). Both are
  observed with injected sync spies/hooks, so a regression that deletes the periodic
  sync call or flips its error handling fails a test; only durability itself is left
  to hardware.

---

## Commit 1 -- `fix(raspi): fdatasync the in-flight segment every 2s to bound power-cut loss`

### `raspi/camera/camera.py`

- New constant near `SEGMENT_WIDTH`: `INFLIGHT_FLUSH_INTERVAL_SECS = 2.0`.
- New class `InflightFlusher` next to `camera.py#try_fsync_segment` -- the pure,
  testable cadence + error policy:
  - `__init__(self, flush, interval=INFLIGHT_FLUSH_INTERVAL_SECS, now=time.monotonic, log=None)`
  - `tick(seq: int | None) -> bool`
  - Semantics: `tick(None)` never flushes; flushes at most once per `interval`
    (injected `now`); `last_flush` advances on every *attempt* (success or
    failure) so a failing card retries every 2 s, not every 250 ms tick; swallows
    **all** `OSError` (incl. `FileNotFoundError` rollover races) -- the watcher
    thread is a crash boundary per ADR 07
    (`raspi/docs/design/07-2026-06-25-picamera2-camera-owner.md`); log-once on
    failure (default log: plain stderr print, same style as `try_fsync_segment`),
    re-armed by a subsequent success; returns True only on successful flush.
- Harden `camera.py#try_fsync_segment` (the wrapper used by the close-time and
  shutdown-path fsyncs): catch **all** `OSError`, not just `FileNotFoundError`, log
  once in the existing stderr style, and return `False`. Linux surfaces writeback
  failures (`EIO`, `ENOSPC`) at `fsync`/`fdatasync` time
  (`man 2 fsync`); the watcher thread is a crash boundary per ADR 07, so a
  close-time sync error must not escape `scan_once` and stop all future
  `segment_closed`/`segment_opened` events and stamping. This makes the close and
  shutdown syncs symmetric with the swallow-all `InflightFlusher` policy above (both
  now log-and-continue on any `OSError`). The pre-existing `continue`-on-`False`
  behaviour in `scan_once` is unchanged: a segment whose sync failed simply isn't
  announced this pass, but the watcher survives.
- Wire into `camera.py#watch_segment_events`:
  `flusher = InflightFlusher(flush, interval=flush_interval)` where `flush` defaults
  to `lambda seq: fsync_segment(rec_dir, seq)`, then `flusher.tick(prev_max)` after
  `scan_once()` in the 250 ms loop. `prev_max` only ever holds ids >= baseline
  (filtered in `detect_segment_events`) -- note in a comment. Close-time fsync and
  the shutdown-path fsync keep firing (now via the hardened `try_fsync_segment`).
  To make the periodic wiring test-observable, `watch_segment_events` accepts the
  `flush` callable and `flush_interval` as injected parameters defaulting to
  `fsync_segment` and `INFLIGHT_FLUSH_INTERVAL_SECS`; production callers pass
  nothing and behave exactly as before. Both `FakeCameraDriver` and
  `RealCameraDriver` share the watcher, so parity inside Python is automatic.

### `raspi/service/src/backend.rs` (mock parity, required by swoop `dune`)

- New `const MOCK_INFLIGHT_SYNC_INTERVAL: Duration = Duration::from_secs(2);`.
- New pure struct `InflightSyncCadence { last: tokio::time::Instant, interval: Duration }`
  with `new(now, interval)` and `due(&mut self, now) -> bool` (true at most once
  per interval; resets on true).
- In `backend.rs#run_mock_recording_writer`: create the cadence at writer start;
  in the `interval.tick()` arm after the packet write, if `cadence.due(now)`,
  call the periodic-sync hook for the open file; on error `tracing::warn!` and
  **continue** (periodic-sync failure must not `Input::Fail` or kill the writer --
  symmetric with the Python swallow-all policy). Rollover/stop syncs keep calling
  `flush_and_sync_mock_segment` directly with their fail-fast behavior. Reset the
  cadence after a rollover sync.
- To make the periodic path test-observable (Finding 3), add a periodic-sync hook
  field to the (crate-private) `MockRecordingContext`, defaulting to
  `flush_and_sync_mock_segment`. Only the cadence path calls it; rollover/stop stay
  on the direct call. A `#[cfg(test)]` writer test can then inject a hook that
  counts invocations and returns `Err` on demand, without touching the public
  `MockBackend` surface. This is exactly the seam that distinguishes the
  swallow-and-continue error policy from the fail-fast one.

### Tests

- `camera.py#run_self_test` (already wired into `just raspi-test` via
  `raspi/service/tests/camera_process.rs#python_fake_self_test_passes_without_picamera2`):
  - **Cadence + error policy** -- drive `InflightFlusher` with a fake clock and
    recording fake `flush`/`log`: no flush before 2.0 s; flush at >= 2.0 s; no
    immediate second flush; next flush after another interval; `tick(None)` never
    calls `flush`; `flush` raising `OSError` / `FileNotFoundError` is swallowed,
    returns False, `log` fires exactly once across repeated failures, success
    re-arms logging; exactly one `flush` attempt per elapsed interval while failing.
  - **Close-time sync errors do not escape the watcher (Finding 2)** -- with the
    module `fsync_segment` temporarily replaced by one raising a generic
    `OSError(errno.EIO, ...)`, `try_fsync_segment(rec_dir, seq)` returns `False`
    and raises nothing, and logs once; then drive one `scan_once`-equivalent pass
    over a rec_dir holding a segment that triggers `segment_closed` and assert no
    exception propagates out of the watcher path (the watcher keeps running).
  - **Periodic sync is actually wired into the watcher (Finding 3)** -- run
    `watch_segment_events` with an injected `flush` spy and a near-zero
    `flush_interval`, a seeded open segment, and a `watcher_shutdown` the spy sets
    once it has recorded a call. Assert the spy was invoked with the open segment's
    id -- i.e. deleting the `flusher.tick(prev_max)` wiring makes this fail. Bound
    the run with a join timeout so a wiring regression can't hang the self-test.
- `backend.rs` `#[cfg(test)]`:
  - `InflightSyncCadence` -- not due at `now`, due after `interval`, resets after
    firing, not due again until another interval.
  - **Mock writer periodic-sync wiring + continue-on-failure (Finding 3)** -- run
    `run_mock_recording_writer` against a temp rec dir with a short roll interval
    and an injected periodic-sync hook that counts calls and returns `Err` on its
    first invocation, then `Ok`. Observe the hub events: assert the hook is called
    at least once mid-segment before the first `SegmentRollover` (cadence wired),
    and that despite the injected periodic `Err` the writer still emits a subsequent
    `SegmentRollover` and never emits `Input::Fail` from the periodic path
    (swallow-and-continue). Reverting the periodic call, or flipping it to
    fail-fast, fails this test.
- **No assertion on durability itself**: a successful fsync is invisible in-process,
  so nothing asserts the bytes are on the platter -- that stays a hardware check
  (Verification below). The tests above cover the *wiring* and *error policy*, which
  are the parts a code change can silently break.

### Docs (same commit)

- **New ADR `raspi/docs/design/19-2026-07-08-inflight-segment-durability-and-boot-scrub.md`**
  (highest existing is 18). Status: Accepted. Related: ADRs 01, 07, 16, 18.
  - Context: the field incident above, including that the live-verified dirty
    clamps saved nothing (delayed allocation), and that the 0-byte leftover
    listed as a normal clip.
  - Decision: (a) camera owner fdatasyncs the in-flight segment every ~2 s from
    the segment watcher (crash boundary: swallow all OSErrors, log-once, ids >=
    baseline only), with symmetric periodic sync in the Rust mock writer; the
    close-time and shutdown fsync wrapper (`try_fsync_segment`) is widened to
    swallow every `OSError` (not just `FileNotFoundError`), because writeback errors
    surface at sync time and must not kill the watcher thread;
    (b) at service startup, before either backend starts, the storage coordinator
    runs a **zero-byte repair pass** judged per path, never by canonical selection:
    for each seq it deletes the whole id only when *every* path for that seq is
    0 bytes; a mixed group (a 0-byte file beside a nonzero one for the same seq) is
    repaired by unlinking only the zero-byte duplicate path(s) and preserving the
    nonzero segment. `high_water_seq` is raised to the max **fully-deleted** id
    **before** the first unlink (a preserved seq keeps its identity and needs no
    witness bump); scrub failure logs and startup continues; no `clip_removed`
    events (no clients at boot).
  - Consequences: loss bound ~2 s + encoder buffering instead of a whole
    segment; small bounded extra SD writes; truly-empty (all-paths-0-byte) clips
    never appear in `/v1/clips`; fully-deleted ids never re-minted (ETag
    immutability); dirty clamps demoted to defense-in-depth; truncated-but-nonzero
    segments still list and play up to the cut; a nonzero file is never deleted just
    because a 0-byte twin for the same seq exists (mixed groups keep their video and
    keep listing under a `N-<nonzero-bytes>` ETag). A widened `try_fsync_segment` no
    longer distinguishes a vanished segment from a failed sync in its logging, but
    both correctly keep the watcher alive.
  - Alternatives: writeback clamps alone (empirically disproven); O_SYNC /
    per-write sync (wear + latency); shorter segments (loss still
    segment-scale); `data=journal` / `commit=1` (system-wide cost, still needs
    explicit sync); app-side bytes==0 filtering (dishonest Pi listing, every
    client re-implements); keeping 0-byte files (nothing to salvage).
- **`raspi/docs/design/01-2026-06-22-crash-safe-recording.md`**: append a dated
  2026-07-08 note after the 2026-07-04 note: the "playable up to the cut"
  promise failed in a field power cut (0-byte in-flight segment despite live
  dirty clamps); ADR 19 restores it (periodic in-flight fdatasync + witness-first
  boot scrub). Append-only per convention.
- **`docs/roadmap.md`**: extend `dune`'s "Service durability + mount witness"
  sub-bullet: "... fsync closed segments before events, fdatasync the in-flight
  segment every ~2 s and scrub unrecoverable zero-byte leftovers at boot
  witness-first (ADR 19), add mock parity, ...". Leave the checkbox unchecked.

---

## Commit 2 -- `fix(raspi): scrub unrecoverable zero-byte segments at boot`

Implements the scrub half of ADR 19 (landed in commit 1).

### `raspi/service/src/clips.rs`

- New `pub(crate) fn zero_byte_repair(rec_dir: &Path) -> io::Result<ZeroByteRepair>`,
  where `ZeroByteRepair { fully_empty_ids: Vec<SegmentId>, stale_empty_paths: Vec<PathBuf> }`.
  It scans the **raw (non-deduped)** parsed candidates so it sees every file for a
  seq, groups them by seq, and classifies each group:
  - every path for the seq is 0 bytes -> `fully_empty_ids.push(seq)` (delete the id);
  - the seq has >= 1 nonzero path (a mixed group) -> push each of its 0-byte paths
    onto `stale_empty_paths` and leave the nonzero segment alone (the id survives).
  Lives here next to `dedupe_candidates` to keep the byte judgment with the filename
  parsing, but deliberately classifies **before** dedupe so stamped-preferred
  canonical selection can never mask a nonzero bare file (the Finding-1 hazard).
  `segment_candidates`/`dedupe_candidates` are untouched -- listing still prefers the
  stamped file; only recovery uses the raw per-path view.

### `raspi/service/src/storage.rs`

- New method next to `delete_finished_segment`:
  `pub fn scrub_unrecoverable_segments(&self) -> io::Result<ScrubReport>`, where
  `ScrubReport { deleted_ids: Vec<SegmentId>, repaired_paths: Vec<PathBuf> }`.
  1. Take the mutation mutex; `ensure_rec_mounted()?`.
  2. `let repair = zero_byte_repair(rec_dir)?;` if both of its lists are empty,
     return an empty `ScrubReport` **without touching the witness** (no state dir
     creation on the happy path).
  3. Witness-first, once, **only for full deletions**: if `fully_empty_ids` is
     non-empty, `persist_witness(rec_dir, existing.max(max_fully_empty_id))?`
     **before** any unlink. Mixed-group repairs bump nothing -- the preserved
     nonzero segment keeps the seq present on disk, so `next_start_segment`'s
     `max_clip_seq` scan already accounts for it and no id can be re-minted.
  4. Unlink: for each `fully_empty_id`, unlink every path from `segment_paths_for_id`
     (bare + stamped duplicates); then unlink each `stale_empty_paths` entry (leaving
     the nonzero twin). `fsync_dir(rec_dir)?`. Return sorted `deleted_ids` +
     `repaired_paths`.
  - Doc comment: boot-time only (must run before any recorder session starts);
    idempotent (a crash between witness write and unlink re-scrubs next boot);
    a repaired mixed group promotes its surviving bare file to canonical, so its
    ETag legitimately changes from `N-0` to `N-<bytes>` (bytes differ -> no aliasing);
    references ADR 19. No floor parameter -- the boot precondition is the floor.

### `raspi/service/src/main.rs`

- New helper `fn scrub_unrecoverable_leftovers(storage: &StorageCoordinator)`,
  called in **both** backend arms of `main.rs#main` immediately after each
  `let storage = Arc::new(...)` and before `CameraProcess::spawn` /
  `MockBackend::recording_to`:
  - `Ok(report)` with any `deleted_ids` -> one
    `tracing::info!(deleted = ?report.deleted_ids, repaired = report.repaired_paths.len(), "scrubbed unrecoverable zero-byte segments left by power loss")`;
  - `Ok(report)` with only `repaired_paths` (a mixed group's empty twin removed,
    footage preserved) -> `tracing::info!(repaired = report.repaired_paths.len(), "removed zero-byte duplicate paths; preserved recoverable footage")`;
  - fully empty report -> silent;
  - `Err` -> `tracing::error!(..., "boot scrub of unrecoverable segments failed; continuing startup")` --
    **never** crash the service (e.g. `/data` absent fails the mount witness;
    diagnostics must stay reachable).

### Tests (behavioral)

- `clips.rs#tests`, `zero_byte_repair`:
  - bare-only 0-byte -> `fully_empty_ids == [seq]`, `stale_empty_paths` empty;
  - bare-only nonzero -> both lists empty;
  - bare 0-byte + stamped 0-byte, same seq -> `fully_empty_ids == [seq]` (all paths
    zero), `stale_empty_paths` empty;
  - **stamped 0-byte + bare nonzero, same seq (Finding 1) -> `fully_empty_ids`
    empty, `stale_empty_paths == [stamped 0-byte path]`** (the nonzero bare file is
    never flagged for deletion);
  - stamped nonzero + bare 0-byte, same seq -> `fully_empty_ids` empty,
    `stale_empty_paths == [bare 0-byte path]` (healthy stamped canonical preserved,
    stale empty twin repaired);
  - missing rec_dir -> empty `ZeroByteRepair`.
- `storage.rs#tests` (add `write_empty_segment` helper alongside `write_segment`):
  - `scrub_removes_zero_byte_segment_and_prevents_id_reuse`: nonzero seg 3 +
    empty seg 4 -> `deleted_ids == [4]`, file gone, seg 3 intact,
    `read_high_water_seq >= 4`, `allocate_start_segment() == 5` (the
    ETag-aliasing regression test -- the critical one).
  - `scrub_multiple_zero_byte_segments_raises_witness_to_max_before_unlink`:
    empty 2 and 6, nonzero 4 -> `deleted_ids == [2, 6]`, witness >= 6, next alloc 7,
    seg 4 intact.
  - `scrub_deletes_all_paths_for_an_all_empty_id`: bare 0-byte + stamped 0-byte for
    the same seq -> both files unlinked, id in `deleted_ids`, witness raised.
  - **`scrub_preserves_nonzero_bytes_in_mixed_duplicate_group` (Finding 1, critical):**
    healthy seg 3, plus seg 4 as stamped 0-byte + bare nonzero -> `deleted_ids`
    empty, `repaired_paths == [stamped 0-byte path]`, the bare nonzero seg-4 file
    still on disk, a fresh candidate scan lists seg 4 with its nonzero bytes, the
    witness is **not** bumped for 4 (no `state/state.json` written if it was the only
    change), and `allocate_start_segment()` still yields max-present+1 (seg 4 counts
    as present). Reverting to canonical-based deletion fails this test.
  - `scrub_leaves_segment_with_healthy_stamped_canonical`: nothing removed, empty
    report.
  - `scrub_noop_leaves_witness_untouched`: empty/missing rec dir -> empty report
    and no `state/state.json` created.
  - `scrub_fails_closed_on_corrupt_witness`: `Err`, empty segment still on disk.
  - `scrub_fails_closed_when_required_mountpoint_is_plain_dir`: `Err`, nothing
    unlinked, no witness created.
  - `scrub_is_idempotent_after_witness_only_crash`: pre-write witness 9, empty
    seg 4 -> `deleted_ids == [4]`, witness stays 9.
- `raspi/service/tests/mock_recording.rs` E2E:
  - `writer_mock_scrubs_zero_byte_leftover_and_records_above_it`: seed nonzero
    `seg_00023.ts` + empty `seg_00024.ts`, run `storage.scrub_unrecoverable_segments()`
    (mirroring main's wiring), build the app, assert `GET /v1/clips` lists only 23,
    start recording, first live segment is 25 (never re-minting 24), `seg_00024.ts`
    gone. This replays the field incident.
  - `writer_mock_preserves_nonzero_footage_in_mixed_duplicate_group` (Finding 1):
    seed seg 24 as a stamped 0-byte file **plus** a bare nonzero `seg_00024.ts` with
    real TS bytes, run the scrub, then assert `GET /v1/clips` still lists id 24 with
    its nonzero `bytes`, `GET /v1/clips/24` pulls the real body (not a 0-byte one),
    and the stamped 0-byte path is gone. Proves recovery keeps salvageable video.

---

## Commit 3 -- `fix(app): describe clip remux failures in human terms`

Independent of the raspi commits. `ClipViewerViewController` already renders
`error.localizedDescription` in the pull task's catch, so conformance alone fixes
the UI -- zero call-site changes. No app-side bytes==0 list filtering: the Pi
scrub owns that; this copy covers the residual case (tiny truncated file with no
PES).

### `app/DanCam/DanCam/Media/Remux/DemuxedH264Clip.swift`

Below the enum, mirroring the `ClipPullError: LocalizedError` precedent in
`app/DanCam/DanCam/Networking/Clips/ClipPullClient.swift` (lead clause + detail;
the associated detail strings are already human-ish sentences and keeping UI and
log text identical aids field correlation):

```swift
extension ClipRemuxError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidTransportStream(let detail):
            "Clip contains no playable video: \(detail)"
        case .invalidH264(let detail):
            "Clip video data is damaged: \(detail)"
        case .writer(let detail):
            "Could not prepare clip for playback: \(detail)"
        case .file(let detail):
            "Could not read clip data: \(detail)"
        }
    }
}
```

### Tests (Swift Testing)

- New `app/DanCam/DanCamTests/Media/Remux/ClipRemuxErrorTests.swift`: assert
  `error.localizedDescription` (the NSError-bridged surface UIKit renders) for
  all four cases, including the exact incident string:
  `invalidTransportStream("No H.264 PES packets found.")` ->
  `"Clip contains no playable video: No H.264 PES packets found."`.
- `app/DanCam/DanCamTests/Features/ClipViewer/ClipViewerViewControllerTests.swift`:
  new `remuxFailureShowsHonestMessage` using the existing `makeController` +
  `ClipRemuxer { _, _ in throw ... }` + `waitUntil` pattern: after the pull
  completes, `statusText == "Clip failed"` and `resultText` equals the honest
  message -- the suite's first assertion on the failure *message* (currently
  only `statusText` is asserted).

---

## Ordering and independence

| Order | Commit | Depends on |
|---|---|---|
| 1 | `fix(raspi): fdatasync the in-flight segment every 2s to bound power-cut loss` (+ ADR 19, ADR 01 note, roadmap) | -- |
| 2 | `fix(raspi): scrub unrecoverable zero-byte segments at boot` | ADR 19 from commit 1 (doc references); functionally independent |
| 3 | `fix(app): describe clip remux failures in human terms` | none |

Push commits 1 and 2 together (ADR 19's scrub half is implemented one commit
later within the same series).

## Verification

Automated (Mac):
- `just raspi-test` -- storage/clips unit tests, the mock_recording E2E, cadence
  tests, and the camera self-test (or directly:
  `python3 raspi/camera/camera.py --self-test`).
- `just raspi-check`, `just adr-check` (validates ADR 19 numbering/date),
  `just app-test`, `just app-lint`.

Manual end-to-end on the real Pi:
1. `just raspi-deploy` **without** deleting the existing 0-byte `seg_00024` --
   it is the live fixture. On first start, verify in `journalctl -u dancam`:
   "scrubbed unrecoverable zero-byte segments"; `GET /v1/clips` no longer lists
   id 24; `state/state.json` `high_water_seq >= 24`; the app's clip list no
   longer shows the phantom clip.
2. Start recording; ~15 s into a segment, hard-cut power (pull the USB feed).
3. Reboot. Verify the previously in-flight segment has nonzero size consistent
   with at most ~2 s of loss (~bitrate x seconds recorded), lists in `/v1/clips`
   with real bytes, and pulls + plays in the app up to the cut -- the restored
   ADR 01 promise.
4. Repeat with the cut landing inside the first ~2 s of a fresh segment: a
   0-byte leftover may still occur in that window -- verify the boot scrub
   removes it and the next session reserves an id above it.
5. Confirm no watcher regressions across several sessions: segments still stamp,
   `segment_closed`/`segment_opened` events still flow, no camera-child restarts
   in `journalctl` attributable to the watcher.

## Commit progress

- [x] 1. fdatasync the in-flight segment every 2s to bound power-cut loss
- [x] 2. scrub unrecoverable zero-byte segments at boot
- [ ] 3. describe clip remux failures in human terms
