# Plan: SD card layout migration (swoop `dune`)

## Context

Research (2026-07-02..04; three adversarially-verified web-research passes) settled
the ideal SD layout for the camera unit and invalidated two standing assumptions:

- **No consumer endurance microSD has power-loss protection.** Teardown-confirmed
  (SanDisk High Endurance = plain 3D TLC; MAX Endurance = same TLC in pMLC mode; no
  vendor makes any power-fail claim -- PLP is industrial-only). Crash-safe ADR 01's
  "Layer 3: PLP card" cannot be bought in the consumer tier the project is using.
  The residual FTL write-abort risk is accepted and mitigated by making every layer
  recoverable (reflash OS / mkfs data / card-as-consumable / prompt incident pull).
- **The raspi-config overlayfs route has verified silent-failure modes**: the
  overlayroot initramfs script exits 0 on failure (boots read-write, unprotected,
  silently); a live Trixie 6.18 kernel-upgrade regression drops the `overlay`
  module from the initramfs (same silent rw boot); the `recurse=1` default converts
  extra fstab partitions -- i.e. our data partition -- into read-only overlays; and
  the tmpfs upper defaults to ~half of the Zero 2 W's 512 MB. A **plain read-only
  ext4 root** is RAM-safer, fails loud (EROFS), and remounts rw in one command.
- Two implementation gaps surfaced during exploration: ffmpeg's segment muxer never
  fsyncs, so ADR 01's "fsync() at segment close" is currently implemented nowhere;
  and the rec dir rides on `StateDirectory=dancam` (writable-root-only mechanism).

Decision accepted by Dan (2026-07-04): 4-partition MBR layout, plain-ro ext4 root
for the car image, tiny rw `/persist` OS-state island, ext4 `data=ordered` ring
partition, ~5% never-written tail as FTL overprovisioning. **Minimum supported
card: 32 GB**; p1-p3 sizes are fixed, only the data partition flexes.

Defaulted while Dan was AFK (both trivially revisable): (a) one swoop `dune`
containing all five stages, car hardening as the final gated stage; (b) the
current dev card is reflashed at stage 4 (its root already fills the card; ext4
cannot shrink online) rather than bringing up a spare card.

## Target layout

MBR (Zero 2 W legacy boot flow reads MBR only; exactly 4 primaries), every
partition start 4 MiB-aligned:

```
p1  512 MiB  FAT32  /boot/firmware  ro (car)   firmware+kernel; bench-only writes
p2  8 GiB    ext4   /               ro (car)   plain read-only root, no overlay
p3  1 GiB    ext4   /persist        rw         journald, NM state, timesync clock
p4  rest-5%  ext4   /data           rw         recording ring (only hot partition)
    ~5% unpartitioned tail, never written (FTL overprovisioning)
```

Dev image: same partition layout now, root stays rw (AGENTS.md dev-vs-car split).
The ro flip + writable-state landmines are the car-image stage, gated behind an
Ansible `car_image` flag.

mkfs/mount (ext4 defaults data=ordered/commit=5/barriers/metadata_csum are
deliberate; lazy-init off so no half-initialized journal on a power-cut device and
no background zeroing racing first recordings):

```
mkfs.ext4 -L dancam-data    -E lazy_itable_init=0,lazy_journal_init=0 <p4>
mkfs.ext4 -L dancam-persist -E lazy_itable_init=0,lazy_journal_init=0 <p3>

LABEL=dancam-persist /persist ext4 noatime,errors=remount-ro,nofail,x-systemd.device-timeout=10s 0 2
LABEL=dancam-data    /data    ext4 noatime,errors=remount-ro,nofail,x-systemd.device-timeout=10s 0 2
/persist/journal /var/log/journal none bind,nofail 0 0
```

`nofail` is load-bearing: without it a dead `/data` drops a headless unit into
emergency mode (unreachable brick); with it boot proceeds and the service-side
mount witness refuses recording while health/status/preview stay phone-visible.
Weekly `fstrim.timer`, never the `discard` mount option.

### Sizing (fixed 9.5 GiB OS overhead + 5% tail; 10 Mbps recording)

| Card   | Usable     | /data      | Ring at 10 Mbps |
|--------|------------|------------|-----------------|
| 32 GB  | ~29.8 GiB  | ~18.8 GiB  | ~4.5 h          |
| 64 GB  | ~59.6 GiB  | ~47.1 GiB  | ~11 h           |
| 128 GB | ~119.2 GiB | ~103.7 GiB | ~25 h           |
| 256 GB | ~238.4 GiB | ~217 GiB   | ~52 h           |

## Design decisions

1. **Partition tooling: `sfdisk` + `partx -u` + `resize2fs`, on-Pi script.**
   macOS has no ext4 tooling, so partitioning happens on the Pi from the freshly
   flashed stock image (auto-expand disabled pre-first-boot). `sfdisk -N 2
   --no-reread` + `partx -u` is the growpart-proven mechanism for resizing a
   mounted root (kernel BLKPG ioctl); `resize2fs` grows ext4 online (grow-only is
   safe). All boundaries computed in 512-byte sectors, aligned to 8192 sectors
   (4 MiB); p2 start parsed from `sfdisk --dump`, never hardcoded. Guards, in
   order, each with an actionable message: root + `/dev/mmcblk0` + MBR label;
   already-applied (4 partitions + both labels resolve) = no-op success; card
   < ~60,000,000 sectors = refuse with the 32 GB floor message; not the stock
   2-partition shape = refuse; p2 already larger than 8 GiB = refuse with
   "reflash via README" (the current dev card triggers exactly this -- a free
   guard test). Include a `--dry-run` that prints the computed sfdisk input,
   plus a hardware-free seam for it: `--total-sectors N` (with `--p2-start S`
   defaulting to the stock image's) runs the pure sector math and the size
   guard with no device access, so the layout computation is regression-testable
   off-Pi (macOS included).
   The script's scope is geometry + filesystems ONLY: guards, sfdisk/partx/
   resize2fs, mkfs with labels. It does NOT write fstab, mount anything, or
   create directories -- those are playbook facts (stage 4), so no fact has two
   homes: a future mount-option change is edited in `site.yml` alone.
   `ansible.posix.mount` creates the mountpoint dirs itself, and `/data/rec` +
   `/persist/journal` are playbook file tasks that run after the `dancam` user
   task, so the "user does not exist at partition time" problem never arises.
   One home per fact: geometry + filesystems = script; fstab/mounts, dirs,
   ownership = playbook.

2. **Ansible dev-vs-car scoping: a `car_image` boolean var (default false) +
   `when: car_image` guards.** Not tags (a forgotten `--skip-tags` silently
   applies car hardening -- the silent-failure class this migration kills), not a
   second play (duplicates hosts/handlers, breaks the single-play why-comment
   style). New Justfile recipe `raspi-provision-car` passes `-e car_image=true`.

3. **journald relocation: fstab bind mount `/persist/journal` ->
   `/var/log/journal`, dev-shared.** systemd orders it for free twice over: the
   fstab generator makes the bind depend on `persist.mount`, and upstream
   `systemd-journal-flush.service` ships `RequiresMountsFor=/var/log/journal`.
   The existing `60-dancam-persistent.conf` drop-in tasks (Storage=persistent,
   SystemMaxUse=200M, SyncIntervalSec=60s) are untouched -- only the backing
   store moves. Beats a symlink (tmpfiles/ownership fixups across symlinks, must
   be baked before ro flip) and journald namespaces (overkill).

4. **Mount witness: builder on `StorageCoordinator`, env-gated, st_dev check,
   per-mutation; rec-dir creation moves behind it.** `StorageCoordinator::new`
   unchanged (whole test suite untouched); add `with_required_mountpoint(PathBuf)`
   + a private `ensure_rec_mounted()` called first inside `reserve_start_segment`
   and `delete_finished_segment` -- every rec-dir mutation fails closed, mirroring
   the corrupt-witness idiom (`raspi/service/src/storage.rs#fn
   corrupt_witness_error`): `ErrorKind::InvalidData`, actionable message
   ("/data is not a mounted filesystem ... check 'findmnt /data', /etc/fstab,
   dmesg"), surfaces as HTTP 500 via `BackendError::Storage` without driving the
   recorder FSM. The witness only holds if nothing touches the rec dir before
   it runs, and today two startup paths do: `MockRecorder::start` calls
   `create_dir_all(rec_dir)` before `reserve_start_segment`, and both camera.py
   drivers call `ensure_rec_dir` in `start()` -- before `ready` -- so an absent
   `/data` would silently grow `/data/rec` on the root fs (dev, rw root) or
   kill the camera process before preview ever comes up (car, EROFS), breaking
   the "health/status/preview stay phone-visible" promise. Fix the ordering,
   not just the check: `reserve_start_segment` runs `ensure_rec_mounted()`
   first, THEN `create_dir_all(rec_dir)` -- rec-dir creation becomes
   coordinator-owned and witness-gated; drop the mock's pre-create; move
   camera.py's `ensure_rec_dir` from `FakeCameraDriver.start` /
   `RealCameraDriver.start` into both drivers' `start_recording`. That move is
   safe by ordering: the Rust arm reserves via the coordinator before
   commanding the camera process (`raspi/service/src/camera/mod.rs#fn
   start_recording`), so by then the witness has passed and the dir exists;
   keeping the call in `start_recording` preserves standalone camera.py runs.
   The witness must also cover the one rec-dir writer outside the coordinator:
   `TimeStore::sync` -> `persist_record` does `create_dir_all(rec_dir/time)` +
   a file write (`raspi/service/src/time_sync.rs#fn persist_record`), and
   `POST /v1/time` is app-auto-triggered whenever the phone is online and the
   snapshot shows unsynced (`AppFeature.swift#shouldSyncTime`) -- so with an
   unmounted `/data`, the very act of connecting the phone to diagnose would
   silently recreate `/data/rec/time` on the root fs, and offset records
   written there are shadowed (lost) once `/data` mounts. Extract the
   mountpoint check into a shared helper (one implementation, used by both);
   `TimeStore` gains the same `with_required_mountpoint` gate, checked in
   `sync` before `persist_record` runs, surfacing through the existing
   `io::Result` -> `TimeSyncError::Unavailable` mapping (503, correct
   semantics: sync genuinely is unavailable). Composition root
   (`raspi/service/src/main.rs#fn main`): if `DANCAM_REQUIRE_REC_MOUNT` is
   set, its value is the required mountpoint; apply to the coordinator AND the
   TimeStore in both camera and mock arms (camera arm builds its store from
   `config.rec_dir` in `raspi/service/src/camera/mod.rs`; mock arm from
   `storage.rec_dir()` in `raspi/service/src/backend.rs`); `tracing::error!`
   once at startup if unhealthy (visibility without killing the process --
   health/status/preview/clip reads stay up for phone-side diagnosis). Check =
   `stat` of mountpoint vs parent: mount iff `st_dev` differs (or `st_ino`
   equal, covering `/`) -- the mountpoint(1) algorithm, two syscalls, no
   /proc/mounts parsing. Deliberately NO `RequiresMountsFor=/data` on
   dancam.service: with `nofail` fstab that would keep the whole service down
   on a dead /data, losing diagnosability.

5. **Segment-close durability: in `camera.py`, fsync before emitting
   `segment_closed`; mock parity.** Placement rationale: `stamp_segment` fires
   on segment_opened (file still being written -- wrong); the Rust side learns of
   closes via polled stderr after the fact, so a coordinator barrier would let
   `clip_finalized` reach the app before bytes are durable (and ADR 16
   deliberately defers coordinator finalize). Right seam:
   `raspi/camera/camera.py#watch_segment_events` -- in the segment_closed branch,
   `fsync_segment(rec_dir, seq)` (fdatasync the file via an O_RDONLY fd + fsync
   the dir; also makes the earlier stamp rename durable), THEN emit the event.
   Critical detail: by close time the segment has virtually always been renamed
   `seg_{seq}.ts` -> `seg_{seq}_{boottag}_{mono}.ts` by `stamp_segment` at open,
   so `fsync_segment` MUST resolve the segment's current filename by scanning
   the dir with `SEGMENT_RE` (match on seq), never by building
   `segment_filename(seq)` -- a bare-name lookup would hit the missing-file
   path on every close and turn the headline durability change into a silent
   no-op. `fsync_segment` returns the resolved path so tests can assert on it.
   Event-after-durability matches the repo's witness-before-commit idiom.
   Session tail: the final post-shutdown `scan_once` additionally fdatasyncs the
   last segment (drivers finish files before `watcher_shutdown.set()`); no event
   emitted, contract fixtures untouched. Missing file = non-fatal stderr
   warning. Cost: one fdatasync of a ~38 MB mostly-written-back file per 30 s.
   Mock writer (`raspi/service/src/backend.rs#run_mock_recording_writer`):
   `file.sync_data().await` after flush at roll and stop, before the rollover/
   stop event is driven.

6. **Code defaults unchanged.** `DEFAULT_REC_DIR` (`raspi/service/src/lib.rs`),
   camera.py argparse default, and Justfile mock recipes keep
   `/var/lib/dancam/rec` / local paths; only the deployed unit points at
   `/data/rec`. The unit env is the single deployed truth; smaller change now.

7. **vm.dirty clamps (dev-shared):** `/etc/sysctl.d/60-dancam-writeback.conf`
   with `vm.dirty_background_bytes=16777216`, `vm.dirty_bytes=67108864`
   (16/64 MiB). On 512 MB the default ratio limits let ~50-100 MB of dirty
   segment data pool, inflating power-cut loss windows and close-time fdatasync
   spikes. Byte form because ratio form rounds brutally at this RAM size.
   Why-comment marks values tunable.

## Stages

Next raspi ADR seq is **18** (`17-2026-07-02-clip-delete.md` exists).

### Stage 1 -- Decision record (no behavior change)

- New `raspi/docs/design/18-2026-07-04-sd-card-layout-and-readonly-root.md`:
  the layout table above, fixed-p1..p3/flex-p4, 32 GB floor, 4 MiB alignment,
  5% tail; plain-ro root over overlayfs (with the silent-failure evidence);
  no-consumer-PLP reality + card guidance (Samsung PRO Endurance /
  SanDisk MAX Endurance; card-as-consumable); `/persist` island rationale
  (kelp's format = true mkfs of /data; logs survive /data damage);
  mkfs/fstab/fstrim parameters and whys; boot health witness requirement;
  on-Pi partitioning approach.
- Dated notes (append-only): ADR 01 -- Layer 3 "PLP card" superseded (accepted
  residual FTL risk + recoverable layers) and "fsync at segment close" lands in
  stage 2; ADR 12 -- journal relocates to `/persist`, not `/data`.
- `raspi/AGENTS.md`: replace the "microSD partition layout (car image)" section;
  fix overlayfs + PLP language in "Software stack"; dev-vs-car table rec-dir and
  logs rows.
- `docs/roadmap.md`: new swoop `dune` (before `kelp`) with a checklist mirroring
  stages 2-5; note on `kelp` that format = mkfs of `/data` only and card-health
  surfacing to the app belongs to kelp, not dune.
- Verify: `just adr-check`.

### Stage 2 -- Service durability + mount witness (Mac-first; no-op on current card)

- `raspi/camera/camera.py`: `fsync_segment` helper resolving the segment's
  current (stamped) filename via `SEGMENT_RE` and returning the resolved path
  (decision 5); call in `watch_segment_events` before emitting
  `segment_closed` and in the final post-shutdown scan. Move `ensure_rec_dir`
  from `FakeCameraDriver.start` / `RealCameraDriver.start` into both drivers'
  `start_recording` (decision 4) so the process reaches `ready` and serves
  preview without `/data`. Mandatory `run_self_test` assertion: a temp dir
  holding only a stamped-name segment -> `fsync_segment(dir, seq)` finds and
  syncs it (assert the returned path is the stamped file) -- this is the
  regression that catches a bare-name lookup silently no-oping every close.
- `raspi/service/src/backend.rs`: `sync_data()` at mock roll + stop; drop
  `MockRecorder::start`'s pre-witness `create_dir_all` (rec-dir creation is
  coordinator-owned and witness-gated, decision 4).
- `raspi/service/src/storage.rs`: `with_required_mountpoint` builder +
  `ensure_rec_mounted` first in both mutations, then coordinator-owned
  `create_dir_all(rec_dir)` in `reserve_start_segment`; tests: (a) required
  mountpoint on a plain temp dir -> `reserve_start_segment` fails InvalidData
  with the actionable message AND neither the rec dir nor any witness state
  was created (the bypass regression); (b) `with_required_mountpoint("/")`
  succeeds; (c) no builder = existing suite green unchanged (with creation now
  inside the coordinator); (d) mock backend start against an unmounted
  required mountpoint surfaces `BackendError::Storage` and leaves the rec dir
  uncreated; (e) `delete_finished_segment` with a required mountpoint on a
  plain temp dir holding a preexisting stray segment fails closed with the
  InvalidData witness error (via `SegmentDeleteError::Io`) and leaves the
  segment files and witness state untouched -- delete is a mutation reachable
  from `DELETE /v1/clips/{id}` and needs the same bypass regression as start.
- `raspi/service/src/time_sync.rs`: `with_required_mountpoint` gate on
  `TimeStore`, checked in `sync` before `persist_record` (decision 4; shared
  mountpoint-check helper with the coordinator); test (f): sync against a
  plain temp dir with a required mountpoint fails and creates nothing -- no
  `time/` dir, no record file (the last unguarded rec-dir writer).
- `raspi/service/src/main.rs`: read `DANCAM_REQUIRE_REC_MOUNT`, apply to the
  coordinator and the TimeStore in both arms, startup error log.
- Verify: `just raspi-test && just raspi-check`; `python3 raspi/camera/camera.py
  --self-test`; preview-without-/data check: run the fake camera with an
  uncreatable `--rec-dir` (e.g. a path whose parent is read-only), assert
  `ready` is emitted and only `start_recording` then fails -- the process must
  not die before `ready` (decision 4's phone-visibility promise, checked here
  rather than first surfacing at stage 4's bench); `just raspi-mock` + app
  loop unchanged; `just raspi-deploy` to the current card -- behavior identical
  (env unset on the old unit file).
- Not here: dancam.service changes (stage 4); no contract/events fixture changes
  anywhere in this migration (no Snapshot/Event shape changes).

### Stage 3 -- Partition tooling (guards provable against current card)

- New `raspi/scripts/partition-card.sh` per decision 1 (guards, sector math,
  mkfs + labels, idempotent no-op, `--dry-run` + `--total-sectors` test seam;
  no fstab, no mounts, no dir creation -- those are playbook-owned).
- New `raspi/scripts/partition-card-test.sh`: hardware-free regression over
  the test seam -- asserts the generated sfdisk layout for 32/64/128/256 GB
  sector counts against the sizing table, the < 32 GB refusal, 8192-sector
  (4 MiB) alignment of every partition start, and the ~5% unpartitioned tail.
  Pure bash assertions, runs on macOS; this is the automated coverage for the
  riskiest math in the migration -- shellcheck and on-Pi guard refusals cannot
  catch a sizing regression.
- `Justfile`: `raspi-partition` recipe -- scp to `/tmp`, `ssh -t sudo bash`,
  same `DANCAM_HOST` env conventions as `raspi-ap`; `raspi-partition-test`
  recipe running the regression locally.
- `raspi/README.md`: new section between flash and SSH -- "disable auto-expand,
  then partition": before first boot, edit `cmdline.txt` on the Mac-mounted FAT
  partition to remove ` init=/usr/lib/raspi-config/init_resize.sh`; boot; `just
  raspi-partition`; verify `lsblk -o NAME,SIZE,LABEL` shows the 4 partitions
  and both labels (mountpoints appear only after stage-4 provisioning, which
  owns fstab). Note the >= 32 GB high-endurance card requirement in the flash
  section.
- Verify: `shellcheck`; `just raspi-partition-test` green; `just
  raspi-partition` against the current dev card refuses with the "root already
  expanded -- reflash" guard.

### Stage 4 -- Dev-shared adoption + dev-card reflash (the flag day)

- `raspi/ansible/site.yml`: `car_image: false` var; layout precheck task (fail
  fast with "run `just raspi-partition`" if `/dev/disk/by-label/dancam-data`
  missing -- loud beats silent); `ansible.posix.mount` tasks converging the three
  fstab entries -- the single home for mount facts, and the module creates the
  mountpoint dirs (confirm module availability via `nix develop -c ansible-doc
  ansible.posix.mount`; fall back to lineinfile + mount commands);
  `/persist/journal` dir (root:systemd-journal 2755) + journal bind notifying the
  existing Restart/Flush/Sync journald handler chain; `/data/rec` created +
  owned `dancam:dancam 0755` (dir creation is playbook-owned, decision 1);
  vm.dirty sysctl drop-in (decision 7); systemd task
  enabling + starting `fstrim.timer` (converge, don't assert -- the playbook
  owns the state, so a fresh image with the timer disabled gets fixed rather
  than failing provisioning); update the two stale scoping comments (play
  header "dev image only" block and the journald "relocate to /data"
  sentence).
- `raspi/dancam.service`: `DANCAM_REC_DIR=/data/rec`,
  `DANCAM_REQUIRE_REC_MOUNT=/data`, remove `StateDirectory=dancam` (nothing
  lives under /var/lib/dancam anymore; would fail on the car's ro /var), update
  comments.
- `raspi/README.md`: rec-dir mentions -> `/data/rec`; reflash-migration note
  ("pre-dune cards must be reflashed; ext4 cannot shrink").
- Bench (in order): `raspi-provision-lint` -> reflash via new procedure ->
  `just raspi-partition` -> re-run (expect no-op) -> `just raspi-provision`
  (converge + reboot) -> re-run (expect changed=0) -> AP PSK re-entry ->
  `just raspi-deploy` -> smoke tests.
- Verify: `lsblk` shows 4 partitions + unpartitioned tail; `findmnt /data
  /persist /var/log/journal`; recording lands `seg_*.ts` under `/data/rec`
  owned dancam; `journalctl --list-boots` >= 2 and `/persist/journal`
  non-empty; `systemctl show systemd-journal-flush.service -p
  RequiresMountsFor` contains `/var/log/journal`; `systemctl is-enabled
  fstrim.timer`; negative test: comment the /data fstab line, reboot -- boot
  completes (nofail), `/v1/health` answers, MJPEG preview still serves (the
  camera process comes up without /data, decision 4), `/v1/recording/start`
  500s with the witness message in `journalctl -u dancam`, time sync fails
  closed (the app fires `POST /v1/time` automatically on connect -- expect
  503, no `/data/rec/time` created), and no stray `/data/rec` appears on the
  root fs; restore, reboot, record. Bench-verify the card facts while at it:
  `cat /sys/block/mmcblk0/queue/write_cache` (does fsync reach the card),
  `/sys/block/mmcblk0/device/preferred_erase_size`, `lsblk -D`.
- Risk watch: Trixie's auto-expand may be cloud-init growpart rather than the
  cmdline `init=` hook -- if the root grew anyway, fix is `growpart: {mode:
  off}` + `resize_rootfs: false` in the FAT partition's user-data; guard 5
  catches the miss (one extra reflash worst case).

### Stage 5 -- Car-image hardening (gated; applies only via `raspi-provision-car`)

- `site.yml` car-only tasks (`when: car_image`, each with the why-comment): ro
  on `/` and `/boot/firmware` fstab entries; tmpfs `/tmp` (64M) + `/var/log`
  (32M; journal bind nests on top by path-depth ordering); bind
  `/etc/NetworkManager/system-connections` + `/var/lib/NetworkManager` from
  `/persist/nm/...` with a one-time copy task (the hand-set AP PSK must
  survive); bind `/var/lib/systemd/timesync` from `/persist/timesync`; mask
  `apt-daily.timer`, `apt-daily-upgrade.timer`, `man-db.timer`,
  `dpkg-db-backup.timer`; converge swap to pure zram by naming and disabling
  any file-backed component of the stock mechanism -- Trixie ships zram-based
  `rpi-swap` (it replaced dphys-swapfile), so the task ensures no swapfile and
  no zram writeback device are configured, and masks `dphys-swapfile` if the
  image under test still carries it (confirm the actual mechanism during the
  stage-5 bench pass); install
  `dancam-storage-health.service` oneshot (`Before=dancam.service`,
  `WantedBy=multi-user.target`) asserting `/data` + `/persist` mounted rw ext4
  with a write probe -- red in `systemctl --failed` when the storage island is
  unhealthy (boot-time half of the witness; stage 2 is the per-mutation half).
  Comment recording that machine-id and SSH host keys are materialized at first
  boot and simply freeze under ro (no task needed).
- `Justfile`: `raspi-provision-car` recipe.
- `raspi/deploy.sh`: detect ro root (`findmnt -no OPTIONS /`) and wrap the
  install block in remount-rw ... remount-ro (bench-only deploy path).
- Docs: README "car image" section; AGENTS.md dev-vs-car table finalized.
- Verify (spare card or accepted dev downtime): provision through stages 3-4
  then `raspi-provision-car`; reboot; `findmnt -no OPTIONS /` shows ro;
  recording works; AP PSK persisted; `journalctl -b -1` works; pull power
  mid-recording ~10x: clean reboot every time, at most the open segment tail
  lost, closed segments playable (`ffmpeg -v error -i seg -f null -`);
  deliberate /data fstab break = failed health unit + 500-on-record, not a
  brick.
- Explicitly deferred: AP autoconnect posture (own decision later); card-health
  surfacing, `/v1/storage/format`, auto-format (kelp); power-good GPIO /
  crash-validation campaign (vine).

## Cross-cutting risks

- Online grow of mounted root is grow-only-safe; the script must never rewrite
  p2's start sector (parse from `sfdisk --dump`).
- journald flush ordering leans on upstream `RequiresMountsFor` -- asserted once
  in stage 4 verification; add a drop-in if a future systemd drops it.
- `nofail` means the only recording guard is the service witness -- which is why
  the witness is per-mutation, not startup-only.
- Ansible mount tasks make provisioning old-layout cards fail loudly at the
  precheck -- intentional; stage 4 is a contained flag day.
- Witness is opt-in (builder + env), so temp-dir test suites are untouched by
  construction.

## Verification summary

`just adr-check` (stage 1); `just raspi-test`, `just raspi-check`, camera
self-test, mock + app loop (stage 2); shellcheck + `just raspi-partition-test`
(layout-math regression) + guard-refusal on current card (stage 3); full bench
runbook + negative mount test + card-facts capture (stage 4); ro-root
power-pull campaign (stage 5).

## Commit progress

- [x] 1. docs(raspi): record sd card layout decision
- [x] 2. feat(raspi): add storage mount witness and segment fsync
- [ ] 3. feat(raspi): add sd partitioning tooling
- [ ] 4. feat(raspi): adopt data and persist partitions
- [ ] 5. feat(raspi): harden car image readonly root

## Implementation notes

- `camera.py` tolerates `EINVAL` from directory `fsync` so the self-test stays
  portable on development hosts that reject directory fsync; Linux ext4 still
  executes the directory fsync used by the Pi.
