# ADR: SD card layout and read-only root

- **Status:** Accepted
- **Date:** 2026-07-04
- **Owner:** raspi
- **Related:** `01-2026-06-22-crash-safe-recording.md` (crash-safe storage layers);
  `09-2026-06-26-pi-system-layer-config-ansible.md` (system-layer ownership);
  `12-2026-06-30-watchdog-and-persistent-journal.md` (persistent journald);
  [Pi storage](../../../docs/design/pi/storage.md) (storage mutation
  witness)

## Context

The camera unit records to its own microSD and loses power without warning. ADR 01
picked the right high-level layers: truncation-tolerant segments, a journaled data
partition, a read-only OS, and hardware caution around the card. The implementation
details that were still provisional have now been tested hard enough to settle.

Two assumptions changed.

First, consumer high-endurance microSD cards do not provide the kind of power-loss
protection ADR 01 hoped for. Teardown-confirmed consumer cards in this tier use
ordinary 3D TLC or pMLC-mode TLC and do not make vendor PLP claims. Industrial cards
with real power-fail protection exist, but they are a different cost and supply tier
than this v1 build is using. The remaining flash translation layer risk is accepted
and mitigated by recoverable software layers, treating cards as consumables, and
pulling important incident clips promptly.

Second, the `raspi-config` overlayfs path is not the car-image root strategy. Its
failure modes are the wrong shape for a headless dashcam: the overlayroot initramfs
path can fail and still exit successfully, a Trixie kernel-update regression dropped
the `overlay` module from the initramfs, the default recursive behavior can turn extra
fstab partitions into read-only overlays, and the tmpfs upper defaults to about half
of the Zero 2 W's 512 MB RAM. A plain read-only ext4 root is simpler, RAM-safer, and
fails loudly: writes get `EROFS`, and bench work can remount it read-write with one
command.

The current dev card also cannot be reshaped in place: its root partition already
fills the card, and ext4 cannot shrink online. Moving to the final layout is a reflash
flag day.

## Decision

Use one MBR-partitioned microSD card with exactly four primary partitions. The Zero 2
W legacy boot path reads MBR; every partition starts on a 4 MiB boundary. The minimum
supported card is 32 GB. Partitions p1 through p3 have fixed sizes, and only p4
flexes with card capacity.

```
p1  512 MiB  FAT32  /boot/firmware  ro in car  firmware and kernels
p2  8 GiB    ext4   /               ro in car  plain read-only root, no overlayfs
p3  1 GiB    ext4   /persist        rw         OS state island
p4  rest-5%  ext4   /data           rw         recording ring
    5% unpartitioned tail, never written       flash overprovisioning
```

The dev image uses the same partition layout but keeps the root writable. The car
image flips `/` and `/boot/firmware` read-only behind an explicit `car_image` Ansible
variable, not a tag.

### Filesystems and mounts

`/data` and `/persist` are ext4. Keep ext4's default `data=ordered`, barriers,
metadata checksums, and `commit=5`; they are part of the crash-safety layer. Disable
lazy initialization at mkfs time so the device does not have background journal or
inode-table zeroing racing first recordings:

```
mkfs.ext4 -L dancam-data    -E lazy_itable_init=0,lazy_journal_init=0 <p4>
mkfs.ext4 -L dancam-persist -E lazy_itable_init=0,lazy_journal_init=0 <p3>
```

The playbook, not the partitioning script, owns fstab and mount facts:

```
LABEL=dancam-persist /persist ext4 noatime,errors=remount-ro,nofail,x-systemd.device-timeout=10s 0 2
LABEL=dancam-data    /data    ext4 noatime,errors=remount-ro,nofail,x-systemd.device-timeout=10s 0 2
/persist/journal /var/log/journal none bind,nofail 0 0
```

`nofail` is deliberate. A bad `/data` partition must not strand a headless unit in
emergency mode; it should boot far enough for health/status/preview and phone-visible
diagnosis. Recording mutations then fail closed through the service mount witness.

Enable the weekly `fstrim.timer`. Do not use the `discard` mount option on this
write-heavy path.

### `/persist`

`/persist` is a small OS-state island, not a recording partition. It holds state that
must survive a `/data` format or a damaged `/data`: persistent journald backing store,
NetworkManager state, and systemd-timesync state.

This separation keeps `kelp` honest. The app's "format SD" action is a true mkfs of
`/data` only, not a directory cleanup on the same filesystem as logs or network
state. Logs surviving `/data` damage also makes storage failures diagnosable after the
fact.

### Recording partition and witness

`/data` is the only hot partition. The deployed service records under `/data/rec`, and
the service is configured with `DANCAM_REQUIRE_REC_MOUNT=/data`.

The witness is required because fstab uses `nofail`: boot can proceed without `/data`,
so every recording-directory mutation must prove `/data` is actually mounted before
creating directories, allocating a segment, deleting footage, or writing time-sync
records. The check is a mountpoint witness (`stat` the mountpoint and parent; mounted
if `st_dev` differs or the inode is the same for `/`), not `/proc/mounts` parsing.

Do not add `RequiresMountsFor=/data` to `dancam.service`. That would keep the whole
service down when `/data` is bad, losing the phone-visible diagnostics this layout is
designed to preserve.

### Card guidance

Use a consumer high-endurance card, preferably Samsung PRO Endurance or SanDisk MAX
Endurance, and buy enough capacity for both ring length and wear headroom. Do not call
these PLP cards: the project accepts the residual FTL write-abort risk.

Cards are consumables in this design. The system mitigates card failure by keeping the
OS recoverable, making `/data` reformattable, reserving an unwritten tail for flash
overprovisioning, and expecting important incidents to be pulled to the phone promptly.

### Partitioning approach

macOS does not provide the ext4 tooling this layout needs, so partitioning happens on
the Pi after flashing a stock image and disabling first-boot root auto-expand.

The on-Pi script owns only geometry and filesystems: guards, sector math, `sfdisk`,
`partx -u`, `resize2fs`, and mkfs with labels. It does not write fstab, mount
anything, or create application directories; those are Ansible-owned system facts.

The script parses p2's start sector from `sfdisk --dump` and grows the mounted root
with the growpart-proven path: update p2's end with `sfdisk -N 2 --no-reread`, tell
the kernel with `partx -u`, then grow ext4 online with `resize2fs`. It refuses cards
below the 32 GB floor, non-MBR cards, non-stock two-partition shapes, and already
expanded roots that need a reflash.

## Consequences

- The car image has no overlayfs dependency and no tmpfs upper consuming scarce RAM.
- `/data` can fail or be absent without bricking the unit; recording and time-sync
  writes fail closed at the service boundary while read-only diagnostics stay up.
- `/data` can be reformatted independently by `kelp`; logs and OS connectivity state
  survive in `/persist`.
- The system no longer claims consumer-card PLP. Residual FTL risk is explicit and
  managed operationally.
- The current dev card must be reflashed when this layout is adopted.

## Alternatives considered

- **`raspi-config` overlayfs root.** Rejected. It is RAM-expensive on the Zero 2 W and
  has verified silent-failure modes, including failures that boot read-write while
  looking successful.
- **Single writable root plus `/data/rec` directory.** Rejected for the car image. A
  root filesystem write during power loss can brick the unit, and a future app format
  could not safely distinguish recordings from OS state.
- **Put journald on `/data`.** Rejected. The app must be able to mkfs `/data`, and
  logs are most valuable when `/data` is damaged or missing.
- **Industrial PLP card as a v1 requirement.** Rejected for now on cost and supply
  grounds. Keep it as a future hardware upgrade path, but do not design the software
  as if consumer cards have PLP.
- **`discard` mount option.** Rejected. Periodic fstrim gives the card trim
  information without adding synchronous discard work to the recording path.
