# Plan: StorageCoordinator seam with durable segment-id high-water witness

## Context

ADR 03 (`raspi/docs/design/03-2026-06-23-storage-ring-buffer-incident-lock.md`)
commits the Pi service to a single-writer storage coordinator that owns all
storage mutations, and to a durable `high_water_seq` witness so segment ids
never alias after deletion ("Reusing a deleted `seq` would alias that
segment's immutable ETag and break resumable pulls"). None of that exists yet:
segment-id allocation today is a stateless directory scan,
`max_clip_seq(rec_dir).map(|seq| seq.saturating_add(1)).unwrap_or(0)`,
duplicated in `raspi/service/src/backend.rs#MockRecorder::start` and
`raspi/service/src/camera/mod.rs#CameraBackend::start_recording`, with no
serialization and no durable state. ADR 03's own Note (2026-07-01) labels the
durable witness as deferred "coordinator work".

This plan builds the minimal ideal first step: a first-class
`StorageCoordinator` that owns segment-id allocation, the in-process
serialization primitive for storage mutations, and a durable high-water
witness file. It deliberately does NOT implement clip deletion, ring-buffer
GC, or incident locks -- but it is the seam those land on, and it makes the
upcoming user-clip-delete plan a small, safe addition instead of a redesign.

## Design

### New module: `raspi/service/src/storage.rs`

```rust
pub struct StorageCoordinator {
    rec_dir: Arc<Path>,
    // In-process serialization primitive for storage mutations (ADR 03
    // single-writer coordinator). Allocation is the only mutation in this
    // cut; future delete/GC/incident link-unlink serialize under it too.
    mutation: std::sync::Mutex<()>,
}

impl StorageCoordinator {
    pub fn new(rec_dir: PathBuf) -> Self;          // no I/O at construction
    pub fn rec_dir(&self) -> Arc<Path>;            // for the read paths
    pub fn allocate_start_segment(&self) -> io::Result<SegmentId>;
}
```

Registered as `pub mod storage;` in `raspi/service/src/lib.rs`. The API is
sync and called inline from the async backends -- exactly how the blocking
`clips::max_clip_seq` scan is called inline today; start is rare and
user-initiated, so two fsyncs on that path are fine (do not `spawn_blocking`
in this cut).

`delete_finished_segment(...)` is a doc-comment placeholder on the type
describing its future contract (see "Future absorption") -- no code.

### Witness file

`<rec_dir>/state/state.json` containing `{"high_water_seq": <u32>}`.

- ADR 03 names exactly this file and key ("`state.json` stores
  `high_water_seq`, the boot-anchor table, and the eviction-floor mirror"),
  so future keys join the same file. Parse via serde_json into a struct with
  a `high_water_seq: SegmentId` field; unknown extra keys tolerated (forward
  compat), anything else is corrupt.
- It lives under a `state/` subdir of the recording directory (precedent:
  the `time/` subdir from TimeStore), survives restart, and can never be
  parsed as a segment: `clips.rs#segment_candidates` filters
  `metadata.is_file()` and `recorder.rs#parse_segment_filename` accepts only
  round-tripping `seg_*.ts` names.
- Semantics: `high_water_seq` = highest id ever handed out by the allocator.

### Allocation semantics (all under the mutation mutex)

1. Read witness:
   - `ErrorKind::NotFound` -> absent, OK (fresh directory).
   - Any other read error, invalid JSON, missing key, or wrong type ->
     fail closed: `Err(io::Error::new(ErrorKind::InvalidData, ...))` whose
     message names the path and the manual recovery (delete `state.json`;
     footage is untouched, only the id floor is lost).
2. `let scanned = max_clip_seq(rec_dir)` (reuse `clips.rs#max_clip_seq`,
   already `pub(crate)`; keep it in clips.rs -- `list_clips` shares its
   scan helpers).
3. `next = witness.into_iter().chain(scanned).max().map(|seq| seq.saturating_add(1)).unwrap_or(0)`
   -- no witness and no files gives 0 (current behavior); otherwise
   max-of-witnesses + 1 per ADR 03's restart rule.
4. Persist witness = `next` durably BEFORE returning (write-ahead):
   `create_dir_all(<rec_dir>/state)`, fsync `rec_dir` (new `state/` entry
   must be durable), write `state.json.tmp`, `sync_all`, `rename` over
   `state.json`, fsync the `state/` dir. Torn writes must be impossible --
   a corrupt witness fails recording closed, so our own crash must never
   produce one; the only path to the `state.json` name is
   rename-after-fsync. A leftover `.tmp` from a crash is inert (never read,
   overwritten next allocation). Do NOT reuse `time_sync.rs#fsync_dir`: it
   swallows errors; the coordinator's dir fsyncs must propagate.
5. Return `next`.

Write-ahead gives the allocator guarantee: every id returned by
`allocate_start_segment` has a persisted witness >= that id before the caller
sees it, so a crash after allocation but before the first segment write
cannot re-issue the id. (This covers session-start ids only; see "Future
absorption" for how rollover ids are covered.)

### Backend integration

Both backends replace the inline scan with the coordinator call, placed so a
failure returns BEFORE `hub.drive_now(Input::StartCommand { .. })` -- no
`RecordingStarting` is emitted and the recorder stays Idle:

```rust
let start_segment = self.storage.allocate_start_segment().map_err(|error| {
    tracing::error!(%error, "start segment allocation failed");
    BackendError::Storage
})?;
```

- `backend.rs#MockRecorder::start`: after the running-task guard (so a
  start that no-ops into an already-running writer never touches the
  witness), before `drive_now`.
- `camera/mod.rs#CameraBackend::start_recording`: after the phase /
  camera-state early returns, before `drive_now`. `CameraBackend`'s
  `rec_dir` field is replaced by `storage: Arc<StorageCoordinator>` (the
  scan was its only use); `ChildRuntime` / `parse_stderr` keep their own
  `Arc<Path>` from the config as today.
- New unit variant `backend.rs#BackendError::Storage` (stays `Copy`),
  `IntoResponse` -> 500 "storage allocation failed". 500 rather than 503:
  a corrupt witness is a fail-closed invariant breach needing operator
  action, not a transient condition.
- `backend.rs#MockBackend::drive_start_without_writer` keeps its hardcoded
  `start_segment: 0` with a one-line comment: it serves the recorder-less
  `MockBackend::new()` used by pure-router tests, has no recording
  directory, and performs no storage mutation.

### Ownership and wiring

The coordinator is the single owner of the recording-dir path, constructed at
the composition root and shared as `Arc<StorageCoordinator>` -- owned by
`AppState`, injected into the backends; never hidden inside `Backend`.

- `lib.rs#AppState`: drop `pub rec_dir: Arc<Path>`, add
  `pub storage: Arc<StorageCoordinator>`. `AppState::new` keeps its two-arg
  signature, defaulting to a coordinator on `DEFAULT_REC_DIR` (construction
  does no I/O, so stub-only tests need no changes). Delete `with_rec_dir`,
  add `with_storage(Arc<StorageCoordinator>)`.
- Read paths swap one line each to `state.storage.rec_dir()`:
  `clips.rs#list_clips`, `clips.rs#serve_clip`,
  `events.rs#enrich_current_segment`, and the `spawn_telemetry` arg in
  `main.rs`. (`rec_dir()` returns `Arc<Path>`, which the existing
  `spawn_blocking` closures already move.)
- `backend.rs#MockBackend::recording_to(rec_dir, roll_interval)` becomes
  `recording_to(storage: Arc<StorageCoordinator>, roll_interval)`;
  `with_recorder` threads the Arc; `MockRecorder` gains `storage` alongside
  its existing `rec_dir` (writer tasks keep using the plain path -- the
  recording byte path stays outside the coordinator per ADR 03).
- `camera/mod.rs`: add `CameraConfig::rec_dir(&self) -> &Path` accessor
  (field is private); `CameraProcess::spawn(config)` becomes
  `spawn(config, storage: Arc<StorageCoordinator>)`.
- `main.rs`: build the coordinator per backend arm and thread one Arc to
  both the backend and `with_storage`. Camera arm builds it from
  `config.rec_dir()` -- this also fixes a latent divergence where a
  `--rec-dir` arg in `DANCAM_CAMERA_CMD` could point the child somewhere
  `AppState.rec_dir` (from `DANCAM_REC_DIR`) does not; note this in the ADR.

### Why non-mutating reads do not move in this cut

`list_clips`, `serve_clip`, and `DurationCache` stay filesystem-backed:

1. ADR 03 explicitly keeps media reads outside the coordinator ("Media reads
   do not go through the coordinator ... POSIX unlink semantics keep an
   already-open fd readable even if GC unlinks the directory entry") -- this
   is the target architecture, not a shortcut.
2. Reads are non-mutating, so they cannot violate the allocation invariant;
   serializing them buys nothing and puts directory scans behind the
   mutation lock.
3. No deletion exists yet, so there is no read-vs-delete race to serialize.
   When delete lands, ADR 03's model already covers it: open fds survive
   unlink, and a listed-then-deleted clip 404s harmlessly.

### Future absorption (module docs + ADR 16)

State the guarantee precisely -- what this cut enforces vs the end state --
so the docs never overclaim:

- **Implemented guarantee (this cut):** every id returned by
  `allocate_start_segment` has a persisted witness >= that id before it is
  handed out. Rollover ids are still minted OUTSIDE the coordinator (the
  mock writer and the camera child increment past the start id), so they
  exceed the witness and are covered only by the directory-scan witness
  while their files exist. That is safe today because nothing deletes
  files.
- **Target invariant (end state, per ADR 03):** a segment id is only ever
  handed out or unlinked when the persisted witness is >= that id. Reached
  once segment finalize/register moves into the coordinator and bumps the
  witness per segment. Until then, every mutation that removes a file must
  write-ahead the witness itself:

- **Clip deletion (next plan):** `delete_finished_segment(seq)` enters the
  same mutation mutex, validates the segment is finished and below the
  unpullable floor, and -- critically -- persists
  `witness = max(witness, seq)` durably BEFORE unlinking (write-ahead
  delete). This is required because rollover segments exceed the witness
  (above); deleting the highest file without the write-ahead would let the
  next allocation re-issue its id. It also invalidates the segment's
  `DurationCache` entry. The rule holds until finalize/register enters the
  coordinator per ADR 03.
- **Ring-buffer GC:** same write-ahead-unlink rule; oldest-first eviction
  runs as coordinator turns under the same mutex, checking link count /
  eviction floor for protection.
- **Incident locks:** hardlink link/unlink under `incidents/` are further
  mutations under the same mutex; they never move the witness (links
  preserve inodes).

## Implementation steps

### Commit 1 -- coordinator module + unit tests (no callers)

1. Add `raspi/service/src/storage.rs` as designed (module docs carry the
   invariant and the `delete_finished_segment` placeholder note).
2. `pub mod storage;` in `lib.rs`.
3. In-file `#[cfg(test)]` mod with a local `TempRecDir` helper (copy the
   `clips.rs#tests` pattern: `env::temp_dir()` + uuid + `Drop` cleanup).
   Tests (a)-(d), (f), (g), (h) below.
4. Gate: `just raspi-test`, `just raspi-check`.

### Commit 2 -- wire backends, AppState, main, tests

1. `backend.rs`: `BackendError::Storage` + 500 arm; `recording_to` /
   `with_recorder` / `MockRecorder` changes; allocation swap in
   `MockRecorder::start`; comment on `drive_start_without_writer`; drop the
   now-unused `max_clip_seq` import.
2. `camera/mod.rs`: `CameraConfig::rec_dir()` accessor; `spawn` signature;
   `CameraBackend.storage` field; allocation swap in `start_recording`;
   drop the `max_clip_seq` import.
3. `lib.rs#AppState`: field/builder swap as designed.
4. Reader one-liners: `clips.rs#list_clips`, `clips.rs#serve_clip`,
   `events.rs#enrich_current_segment`.
5. `main.rs`: per-arm coordinator construction + `with_storage` +
   `spawn_telemetry` arg.
6. Mechanical test-construction updates (verified full list):
   - `tests/events.rs` (state helper + 4 `recording_to` sites)
   - `tests/time.rs` (state helper)
   - `tests/mock_recording.rs` (2 inline construction sites)
   - `tests/clips.rs`, `tests/status.rs` (state helpers -> `with_storage`)
   - `tests/camera_process.rs` (6 `CameraProcess::spawn` sites + 1
     `with_rec_dir` site)
   - Unchanged: `tests/recording.rs`, `tests/health.rs`,
     `tests/request_id.rs`, `tests/preview.rs` (never construct with a
     rec dir); no in-file `#[cfg(test)]` mod constructs AppState/MockBackend.
7. Integration tests (e) in `tests/mock_recording.rs` and (e2) in
   `tests/camera_process.rs`; extend the existing regression
   `tests/mock_recording.rs#writer_mock_starts_after_six_digit_existing_segment_without_mutating_it`
   to also assert the witness file content after start.
8. Gate: `just raspi-test`, `just raspi-check`. Existing behavior must hold:
   absent witness + `seg_100000.ts` on disk still starts at 100001;
   `tests/camera_process.rs` seeded-dir starts still count from the scan
   (witness never exceeds the last allocation, so repeated start/stop
   cycles are unaffected).

### Commit 3 -- records

1. New ADR `raspi/docs/design/16-2026-07-02-storage-coordinator-segment-id-witness.md`
   (raspi max is 15; sharing the date with 15 satisfies `just adr-check`).
   Status: Accepted. Content: the Decision above, plus explicitly recorded
   refinements vs ADR 03:
   - witness written at session-start allocation, not per-segment finalize;
     state the implemented guarantee vs the target invariant exactly as in
     "Future absorption" above (rollover ids remain scan-covered until
     finalize/register enters the coordinator; hence the write-ahead-delete
     rule for any future unlink);
   - fail-closed-on-corrupt policy; manual recovery = delete `state.json`;
     the future `format` flow (which ADR 03 defines as carrying
     `high_water_seq` forward) is the sanctioned reset;
   - flat `seg_*.ts` layout retained vs ADR 03's `segments/` subdir; only
     two of ADR 03's four witnesses exist today (no `index.log`, no
     `incidents/`);
   - camera-mode rec_dir now derived from `CameraConfig`, closing the
     allocator/reader/writer divergence.
   Out of scope: delete, ring GC, incident locks, finalize-in-coordinator.
2. Amend ADR 03 with a dated note (existing `> **Note (...)**` blocks are
   the precedent) in "Segment Identity And Time" pointing at ADR 16 and
   summarizing what is now realized vs still deferred.
3. Add the ADR 16 bullet to the ADR index in `raspi/AGENTS.md`
   ("Design decisions (ADRs)" list, established format).
4. `just adr-check`.

## Test plan

| # | Case | Where |
|---|------|-------|
| a | No witness: empty dir -> 0; with files -> max+1. Also assert `state/state.json` parses to `high_water_seq == returned` (write-ahead observable). Existing regression `writer_mock_starts_after_six_digit_existing_segment_without_mutating_it` pins end-to-end behavior; extend with witness assertion. | `src/storage.rs` tests; `tests/mock_recording.rs` |
| b | Valid witness above files: hand-write `{"high_water_seq":10}` + `seg_00005.ts` -> allocate == 11. | `src/storage.rs` |
| c | Highest file missing, witness intact: allocate (persists witness), delete all `seg_*.ts`, allocate again == witness+1. Plus hand-written-witness + empty-dir variant. | `src/storage.rs` |
| d | Corrupt witness fails closed: `not json`, `{}`, `{"high_water_seq":"7"}`, `{"high_water_seq":-1}` -> `Err` (`InvalidData`). Extra unknown key alongside a valid value still succeeds (forward compat). | `src/storage.rs` |
| e | Mock backend start with corrupt witness: corrupt `state/state.json`, build `recording_to(storage, ..) + with_storage(storage)`, POST `/v1/recording/start` -> 500; `/v1/status` shows `phase == "idle"`, `current_segment == null`; no `seg_*.ts` created. (Idle proves no `Input::StartCommand` was applied, hence no `RecordingStarting`.) Integration over unit: `MockRecorder` is private and this pins the 500 contract. | `tests/mock_recording.rs` |
| e2 | Camera backend start with corrupt witness: corrupt `state/state.json` in the temp rec dir, `CameraProcess::spawn(config, storage)` with the fake camera script, wait for the camera to report Running (existing helper pattern in this file), then `backend.start_recording().await` -> `Err(BackendError::Storage)`; recorder phase stays Idle; `segment_ids(&rec_dir)` empty (proves no `ChildCommand::StartRecording` reached the fake child, which writes segments on start). Pins the camera-side ordering: allocation failure precedes both `drive_now` and the child command. | `tests/camera_process.rs` |
| f | Serialization at the seam: sequential allocations return n, n+1; concurrent (`std::thread::scope`, ~8 threads, one coordinator) -> all ids distinct, final witness == max id. Allocation is itself a mutation, so this covers the serialization requirement now; further mutation APIs add their own interleaving tests when they land. | `src/storage.rs` |
| g | Witness survives restart: allocate on empty dir (0), drop the coordinator, construct a new one on the same dir (no `seg_*.ts` exists by construction) -> allocate == 1. | `src/storage.rs` |
| h | Leftover `state.json.tmp` is inert: plant `state/state.json.tmp` containing garbage, and separately one containing a higher `{"high_water_seq":...}` than the committed `state.json`; allocate -> result derives only from `state.json` + file scan (tmp neither corrupts nor raises the id), and afterwards the committed `state.json` parses to the returned id. | `src/storage.rs` |

## Verification

1. `just raspi-test` and `just raspi-check` (fmt + clippy `-D warnings`).
2. `just adr-check`.
3. Manual smoke with the mock backend (`just raspi-mock`, rec dir
   `raspi/service/.mock-rec`):
   - POST `/v1/recording/start` -> 200; confirm
     `.mock-rec/state/state.json` contains `{"high_water_seq":N}` matching
     the first segment id in `/v1/status`.
   - Stop the service; `echo garbage > .mock-rec/state/state.json`;
     restart; POST start -> 500; `/v1/status` stays `idle`.
   - `rm .mock-rec/state/state.json` (the documented recovery); POST start
     -> 200; ids continue from the surviving `seg_*.ts` scan.

## Notes

- `serde_json` and `uuid` (tests) are already dependencies; no new crates.
- `u32::MAX` saturation pins rather than wraps (consistent with the current
  `saturating_add`); unreachable in practice (30 s segments -> millennia).
- Fail-closed is deliberately strict per the requirement; the atomic
  write-ahead protocol is what keeps "our own crash bricked recording" out
  of the failure space -- only genuine corruption (bit rot, manual damage)
  trips it, and the recovery is documented in the error message and ADR.

## Commit progress

- [x] 1. coordinator module + unit tests
- [x] 2. wire backends, AppState, main, tests
- [ ] 3. records
