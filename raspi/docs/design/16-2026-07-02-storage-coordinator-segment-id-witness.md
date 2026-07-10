# ADR: Storage coordinator segment-id witness

- **Status:** Accepted
- **Date:** 2026-07-02
- **Owner:** raspi
- **Related:** `03-2026-06-23-storage-ring-buffer-incident-lock.md` (target storage
  coordinator, segment identity, and max-of-witnesses restart rule);
  `15-2026-07-02-segment-fact-stamping-and-boot-offset.md` (current flat segment
  filename facts and per-boot time offset files)

## Context

ADR 03 defines segment `seq` as the stable clip identity and commits the Pi to a
single-writer storage coordinator plus a durable `state/state.json`
`high_water_seq` witness. That witness prevents a deleted segment id from being
reissued later, which would alias immutable clip `ETag`s and break resumable pulls.

Before this decision, the service chose the next segment id by scanning the
recording directory at each start. That was safe only while no code deleted segment
files: the highest surviving `seg_*.ts` filename was still enough to keep the next
session above existing footage. It was not a durable allocation rule and left the
upcoming delete, GC, and incident-lock work without a storage-mutation owner.

## Decision

Add `StorageCoordinator` as the in-process owner for recording-directory mutations.
This first cut coordinates only start-segment allocation, but the coordinator mutex is
the seam for later delete, ring-GC, incident hardlink, and finalize/register turns.

`StorageCoordinator::allocate_start_segment` runs under the mutation mutex and:

1. Reads `<rec_dir>/state/state.json` as JSON with a `high_water_seq` field.
2. Scans the current flat recording directory for the max `seg_*.ts` sequence.
3. Chooses `next = max(high_water_seq, max_file_seq).saturating_add(1)`, or `0`
   when both are absent. (**Scoped-superseded by ADR 20, ceiling case only:** at
   `max == u32::MAX` allocation fails closed with an `InvalidData` error instead of
   reissuing the id, so start-segment reservation -- and the session ADR 20 derives from
   it, `start_segment + 1` -- is strictly monotonic and never repeats an id. The rest of
   this allocation rule is unchanged.)
4. Persists `{"high_water_seq": next}` before returning by creating `state/`, writing
   `state.json.tmp`, fsyncing the file, renaming it over `state.json`, and fsyncing
   the `state/` directory. The recording directory is fsynced after creating
   `state/`.

The witness is write-ahead for session-start ids: every id returned by
`allocate_start_segment` has already been persisted as `high_water_seq` before the
caller sees it. A crash after allocation but before the first segment write cannot make
that start id available again.

Corrupt or unreadable committed witness state fails closed. Invalid JSON, a missing
field, a wrong type, or a non-NotFound read error returns `InvalidData`; HTTP start
requests surface that as a 500 and do not drive the recorder FSM or camera child.
Manual emergency recovery is to delete `state.json`. Footage is untouched, but the
segment id floor falls back to the surviving file scan. The future `format` operation
defined by ADR 03 remains the sanctioned reset path and must carry
`high_water_seq` forward so formatting footage never reuses old ids.

The current implementation keeps the flat `seg_*.ts` layout. It does not move footage
under ADR 03's future `segments/` subdir and does not create `index.log` or
`incidents/`. Therefore only two witness classes exist today:

- `state/state.json` `high_water_seq`
- max sequence in flat `seg_*.ts` filenames

The other ADR 03 witnesses, max sequence in `index.log` and max sequence hardlinked
under `incidents/*/`, land with their owning features.

The implemented guarantee is intentionally narrower than ADR 03's end state:

- **Implemented now:** every id returned by `allocate_start_segment` has a persisted
  witness greater than or equal to that id before it is handed out.
- **Target invariant:** a segment id is only ever handed out or unlinked when the
  persisted witness is greater than or equal to that id. That requires
  per-segment finalize/register to move into the coordinator and bump the witness for
  rollover ids.
- **Still deferred:** rollover ids are minted outside the coordinator by the active
  recorder or camera writer. They exceed the persisted witness and are covered only by
  the directory scan while their files exist.
- **Rule until finalize/register moves into the coordinator:** any future mutation
  that removes a segment file must first persist `high_water_seq >= seq` under the
  same coordinator mutex. Clip delete and ring GC both need this write-ahead-delete
  step. Incident hardlink link/unlink operations serialize under the same mutex but do
  not move the witness because links preserve the segment inode and id.

Non-mutating reads stay filesystem-backed. Clip listing, clip serving, duration
caching, and event enrichment keep scanning or opening files directly. ADR 03 already
keeps media reads outside the coordinator; POSIX unlink semantics make an open fd
survive a future unlink, and a listed-then-deleted clip can cleanly 404.

The composition root constructs one `Arc<StorageCoordinator>` and shares it with
`AppState` and the active backend. In camera mode the coordinator's recording
directory is derived from `CameraConfig`, so the allocator, read paths, and camera
child agree when `DANCAM_CAMERA_CMD` supplies a custom `--rec-dir`.

Out of scope for this implementation: clip delete, ring-buffer GC, incident locks,
and finalize/register-in-coordinator.

## Consequences

- Segment-start allocation now has a durable high-water floor instead of relying only
  on the currently surviving files.
- A corrupt witness stops recording starts before observable recorder state changes,
  making storage corruption loud instead of silently risking id aliasing.
- The delete and ring-GC work can now add real mutations to the same coordinator
  without redesigning backend ownership.
- Rollover ids are not fully covered until finalize/register enters the coordinator.
  Deleting or evicting finished segments before that move requires write-ahead witness
  updates for every unlinked sequence.
- The current on-disk shape remains transitional: flat `seg_*.ts` files and no index
  or incident trees.

## Alternatives considered

- **Keep scanning only.** Rejected. It cannot protect against reusing a deleted
  highest sequence once delete or GC exists.
- **Fall back to scanning on corrupt witness.** Rejected. That would make the durable
  floor optional exactly when it is most needed. Operator action is safer than silent
  aliasing.
- **Store the high-water floor in the rebuildable index.** Rejected. ADR 03 keeps
  durable coordinator state out of `index/` so losing cache state cannot lose the
  no-aliasing floor.
- **Move all reads behind the coordinator now.** Rejected. Reads are non-mutating,
  current delete/GC do not exist yet, and ADR 03's target keeps media reads outside
  the mutation coordinator.
