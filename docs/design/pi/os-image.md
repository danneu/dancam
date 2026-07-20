# Pi OS image, power, and recovery

The camera unit runs Raspberry Pi OS Lite, 64-bit (Trixie / Debian 13), from one
microSD card. The development and car images share the same four-partition layout;
the development root stays writable for iteration, while the car image mounts its
root and boot filesystems read-only. There is no overlay filesystem.

This page owns the physical power topology, SD-card and filesystem layout, car-image
write policy, persistent OS state, and whole-host freeze recovery. The
[recording design](recording.md) owns media-level crash tolerance, and
[storage](storage.md) owns recording-directory mutations, startup repair, and ring
garbage collection.

## Power topology

The unit is powered from a switched, regulated 5V USB accessory source. Either a
12V-socket USB adapter or the 2019 Toyota C-HR's 18W windshield-area USB tap works;
the windshield tap is preferred because it gives a short hidden cable run to the
mirror-mounted unit. Use a quality cable and a source rated for at least 2A. The Pi
and active camera draw roughly 3-5W, so a thin cable is a more likely undervoltage
cause than the 18W source.

Both candidate sources die when the car turns off and provide no power-fail signal.
Abrupt, unsignaled loss is therefore normal: there is no shutdown daemon,
power-good GPIO, supercapacitor, or clean-finalize path. The USB source already
regulates the car's 12V rail, so the unit adds no buck converter, fuse-box wiring,
or automotive transient handling. It also contains no lithium battery.

Switched power makes parked recording physically unavailable in this topology. That
is accepted for v1 and avoids running the camera in the worst hot-parked thermal
conditions. A future sentry mode is a different power and thermal design: it would
need an always-on fuse-box source, an automotive 12V-to-5V supply, low-voltage
battery cutoff, and renewed validation against the camera sensor's 50 C ceiling.

A crank brownout may reboot the Pi. The read-only car image and crash-tolerant media
path make that an expected recovery event, though recording remains idle after boot
until the app issues `/v1/recording/start`. Persistent undervoltage warnings are
treated as a cable or source fault first.

## Card and partition layout

The Zero 2 W uses one MBR-partitioned microSD card with exactly four primary
partitions. The legacy boot path reads MBR. Every partition begins on a 4 MiB
boundary, the minimum supported card is 32 GB, p1 through p3 have fixed sizes, and
only p4 grows with card capacity.

```text
p1  512 MiB  FAT32  /boot/firmware  ro in car  firmware and kernels
p2  8 GiB    ext4   /               ro in car  plain read-only root
p3  1 GiB    ext4   /persist        rw         OS state island
p4  rest-5%  ext4   /data           rw         recording ring
    5% unpartitioned tail, never written       flash overprovisioning
```

The development image uses the same layout but leaves `/` and `/boot/firmware`
writable. The car image switches both read-only behind the explicit `car_image`
Ansible variable. Plain read-only ext4 is deliberate: it consumes no tmpfs upper on
the 512 MB board, failed writes return `EROFS`, and bench recovery can remount the
root read-write explicitly. The image never uses `raspi-config` overlayfs.

`/data` and `/persist` use ext4 with the default `data=ordered`, barriers, metadata
checksums, and `commit=5`. Formatting disables lazy inode-table and journal
initialization so background initialization cannot race the first recording:

```text
mkfs.ext4 -L dancam-data    -E lazy_itable_init=0,lazy_journal_init=0 <p4>
mkfs.ext4 -L dancam-persist -E lazy_itable_init=0,lazy_journal_init=0 <p3>
```

The partitioning script owns only geometry and filesystem creation. It runs on the
Pi after a stock image is flashed with first-boot root auto-expansion disabled,
because macOS lacks the required ext4 tools. It parses p2's start from
`sfdisk --dump`, updates p2 with `sfdisk -N 2 --no-reread`, refreshes the kernel
view with `partx -u`, and grows ext4 online with `resize2fs`. It refuses cards below
32 GB, non-MBR cards, non-stock two-partition starting layouts, and an already
expanded root that requires a reflash. The current pre-layout development card
cannot be shrunk in place and must be reflashed.

## Mounts and writable state

The Ansible development/car-image path, not the partitioning script, owns fstab,
mounts, application directories, and the read-only switch. Its effective mount facts
are:

```text
LABEL=dancam-persist /persist ext4 noatime,errors=remount-ro,nofail,x-systemd.device-timeout=10s 0 2
LABEL=dancam-data    /data    ext4 noatime,errors=remount-ro,nofail,x-systemd.device-timeout=10s 0 2
/persist/journal /var/log/journal none bind,nofail 0 0
```

`nofail` lets a headless unit boot far enough for status, preview, and diagnosis when
`/data` is damaged or absent. The service must not declare
`RequiresMountsFor=/data`, because that would suppress those read surfaces. Instead,
every recording-directory mutation and time-sync write proves the mount is present
through the service's mountpoint witness and fails closed when it is not. The witness
stats the mountpoint and its parent: it accepts a different `st_dev`, or the same
inode when the tested path is `/`, rather than parsing `/proc/mounts`.

The production image has the same final `/data` options but uses a tracked
`data.mount` unit instead of an unconditional fstab entry. Its condition is a durable
storage-admission marker created only after commissioning commits `complete`; the
commissioner then starts the unit explicitly. This keeps p4 private from normal
service and GC work throughout first-boot growth while preserving the same mount on
every completed boot.

`/data` is the only hot recording partition. The deployed service records under
`/data/rec` with `DANCAM_REQUIRE_REC_MOUNT=/data`. The app's format-card operation
reformats `/data` only. The recording namespace's generation and sequence witness
live under `/data/rec/state/` and move with its footage. Formatting or deliberately
resetting that namespace causes the service to mint a new generation before recording
becomes ready.

`/persist` is the small writable OS-state island. It carries
`/persist/journal`, NetworkManager state, and systemd-timesync state, all of which
must survive a `/data` failure or format. Keeping logs away from `/data` preserves
the evidence needed to diagnose recording-partition failures.

Weekly `fstrim.timer` is enabled. The filesystems do not use the `discard` mount
option, which would add synchronous discard work to the recording path.

## Card durability

Use a consumer high-endurance microSD, preferably Samsung PRO Endurance or SanDisk
MAX Endurance, with enough capacity for ring length and wear headroom. Consumer
cards in this tier do not claim real power-loss protection; the design accepts the
residual flash-translation-layer risk instead of calling them PLP cards.

Cards are consumables. The unit reduces failure impact with a recoverable read-only
OS, an independently reformattable journaled `/data`, a 5% never-written tail for
flash overprovisioning, short fsynced recording segments, and prompt transfer of
important incidents to the phone. An industrial PLP card remains a possible
hardware upgrade, not a software assumption.

## Freeze recovery and persistent logs

Abrupt power loss and a software freeze with power still present are separate
failure classes. Media and filesystem design cover the former. The on-board BCM2835
hardware watchdog and persistent journald cover whole-host recovery and post-mortem
evidence for the latter.

Systemd arms `/dev/watchdog0` through
`/etc/systemd/system.conf.d/60-dancam-watchdog.conf` with
`RuntimeWatchdogSec=60s`. PID 1 pings at half that interval. If userspace stalls or a
kernel hard freeze stops the watchdog worker, the board resets and systemd starts
the service and camera backend again. This recovers the host, not an active recording:
the recorder returns in `idle` until the app starts it.

The BCM2835 hardware heartbeat is about 16 seconds, but the driver exposes it as
`max_hw_heartbeat_ms`, not a hard maximum timeout. The Linux watchdog core therefore
accepts the 60-second logical deadline and refreshes the shorter hardware heartbeat
while the kernel and PID 1 remain healthy. A kernel hard freeze stops that refresh,
so the hardware resets at roughly its own heartbeat; 60 seconds governs a PID-1
stall and avoids false resets when systemd is merely slow under transient IO or
thermal load.

`RebootWatchdogSec` remains at systemd's 10-minute default. It covers only the
shutdown or reboot phase. A shorter deadline could reset a writable development
root during a legitimate slow unmount without improving unattended operation.

Journald writes persistently through
`/etc/systemd/journald.conf.d/60-dancam-persistent.conf` with:

- `Storage=persistent`;
- `SystemMaxUse=200M`, bounding OS-log space and wear; and
- `SyncIntervalSec=60s`, bounding the normally lost tail after a hard freeze.

`/var/log/journal` is bind-mounted from `/persist/journal`, so logs survive watchdog
resets, abrupt power loss, and `/data` formats. Previous-boot evidence is available
with `journalctl -b -1`. A hard freeze can still lose up to roughly the last 60
seconds because only CRIT, ALERT, and EMERG messages force immediate sync.

The watchdog does not detect a hung `dancam` process while PID 1 stays healthy, nor
a kernel soft lock that still schedules systemd. A deterministic early freeze can
also produce a reboot loop. Persistent logs exist to classify the next incident; an
app-level `WatchdogSec`/`sd_notify` process watchdog or kernel lockup-to-panic policy
is added only if evidence identifies one of those uncovered classes. The original
2026-06-30 incident left no evidence, so it is not known whether PID 1 stopped
scheduling and the host watchdog would have caught it.

## Production image and commissioning

`just raspi-image` creates or reuses the dedicated ARM64 NixOS OrbStack builder when
launched from the Apple Silicon Mac, then runs the controlled Linux-native image
recipe there. OrbStack shares the checkout, so authenticated release outputs land
back under `dist/` without copying the signing key into a second source tree. The
builder verifies the pinned Raspberry Pi OS Lite input and assembles fixed p1 through
p3 plus initialized small p4 layout, installs the camera runtime and service, removes the
stock root-expansion trigger, and emits a versioned zstd image with a JSON manifest.
The image builder, first-boot commissioner, Mac eligibility policy, and writable
development partitioner all consume `raspi/system/card-layout.env`, so geometry,
labels, minimum capacity, and the reserved-tail boundary have one definition.
The publisher signs that manifest with the DanCam minisign key. The manifest records
both compressed and raw digests, raw size, OS release and digest, repository revision,
image identity, and the digest of a complete installed-package inventory. Runtime
packages not already present in the pinned OS image are installed at the exact versions
in `raspi/image/inputs.env`; the builder does not run a floating full-upgrade.

`just raspi-flash` is the native Mac consumer. It authenticates the manifest and
compressed image before media discovery, admits only writable removable whole disks
of at least 32 GB outside system storage, and binds typed confirmation to the I/O
Registry media identity. It verifies the raw image before personalization, writes a
versioned envelope to the FAT boot partition, verifies that envelope after remount,
and reports success only after eject. The Mac transfer holds an exclusive Disk
Arbitration claim across writing and readback so the OS cannot auto-mount and mutate
the FAT boot volume between those phases. An explicitly requested interrupted-write
resume compares every authenticated image chunk, retains up to 64 MiB of differing
chunks in memory, repairs and rereads only those chunks, and refuses broader repair.

Image assembly preserves the base Raspberry Pi OS DOS disk identifier when it
rewrites the partition geometry and asserts that the kernel's root `PARTUUID`
resolves to partition 2. The production boot line also pins the selected `US` Wi-Fi
regulatory domain.

The generic p4 filesystem has no recording witness. First boot validates the
authenticated image marker and matching envelope, brings up the per-unit AP, extends
only p4 to the aligned 95% card boundary, grows its existing ext4 filesystem, and
mints the storage generation while p4 is mounted privately. It commits commissioning
`complete` durably before exposing `/data` to the normal service. A completed state
permanently fences replay; interruption before that point reruns idempotent growth or
reports a stable failure. Root and boot are read-only in the resulting car posture.

## Decision log

### 2026-06-23 -- Use switched USB power and assume abrupt loss

(absorbed from raspi ADR 04, 2026-06-23)

The 2019 Toyota C-HR offered two already-regulated 5V sources: a 12V accessory
socket through a USB adapter and an 18W windshield-area USB tap. Both were confirmed
switched and therefore disappeared without warning at engine-off. The Pi Zero 2 W,
camera, and Wi-Fi AP draw only about 3-5W, well inside either source's capacity.

The decision was to accept that physical contract directly. Either source works,
with the windshield tap preferred for routing, and the recording stack bears the
entire abrupt-loss burden. The proposal status did not reflect uncertainty in later
implementation: the system and operational guidance already treated this topology
as settled, so this fold accepts it as the current design.

A supercapacitor and power-good GPIO were rejected because the chosen USB topology
offers no failure signal with which to trigger a clean finalize. A switched ACC
fuse plus buck converter was extra automotive wiring for identical drive-only
behavior. An always-on fuse could enable sentry mode, but it also needs low-voltage
cutoff and exposes the camera to the parked-cabin thermal worst case. OBD-II power is
commonly always-on, and a lithium battery or UPS violates the hot-car safety rule.

The consequences were intentional: simple reversible hardware, no parked mode, a
possible crank reboot, and complete dependence on the crash-safe recording and
filesystem layers. The switched topology also removes the worst parked thermal case.

### 2026-06-30 -- Add a host watchdog and durable post-mortem logs

(absorbed from raspi ADR 12, 2026-06-30)

During a deploy the Pi hard-froze: mDNS disappeared, an in-flight SSH/rsync session
hung without a TCP reset, and only a manual power cycle recovered it. The board came
back healthy, but `/var/log/journal` had been volatile under `/run`, so the failed
boot left no evidence. Abrupt hardware power loss was already covered; a powered but
wedged unattended host was not.

The decision paired the BCM2835 hardware watchdog with size-capped persistent
journald as the recovery and diagnosis halves of one concern. A 60-second logical
PID-1 deadline was chosen over an aggressive sub-16-second deadline to avoid false
resets during transient IO or thermal load. The driver and watchdog-core timeout
model was checked in the Raspberry Pi kernel source: the hardware's shorter heartbeat
is refreshed internally and still bites quickly when the kernel itself freezes.
`RebootWatchdogSec` was deliberately left at its roomy default to avoid resetting
mid-unmount on a slow writable development image.

Persistent logs use a 200 MB cap and 60-second sync cadence. That trades bounded SD
wear for a bounded diagnostic tail; it cannot guarantee preserving the final cause
of a freeze. The original decision placed development logs on the writable root and
deferred the car-image location. The 2026-07-04 layout decision resolved that by
moving the backing store to `/persist/journal`, never `/data`.

An app-level systemd process watchdog was deferred because it requires service work
and covers only a healthy-host/hung-process class that the incident did not prove.
An external GPIO watchdog duplicated the on-board device. Kernel soft-lock panic
handling remains another evidence-driven layer rather than speculative configuration.
Manual recovery was rejected because the unit is unattended.

### 2026-07-04 -- Use a four-partition card and plain read-only root

(absorbed from raspi ADR 18, 2026-07-04)

The early crash-safety design left two implementation assumptions open. First,
consumer high-endurance cards use ordinary 3D TLC or pMLC-mode TLC and do not make
the PLP claims hoped for; industrial power-fail-safe cards occupy a different cost
and supply tier. Second, `raspi-config` overlayfs had unsuitable failure modes for a
headless 512 MB unit: its initramfs path could fail while reporting success, a Trixie
kernel regression omitted the overlay module, recursive overlays could capture extra
fstab partitions, and the tmpfs upper default consumed about half the board's RAM.

The decision settled one MBR card with fixed boot, root, and persist partitions; a
capacity-flexing data partition; and a 5% unwritten tail. The development and car
images share the geometry, but only the car image mounts root and boot read-only.
`/persist` separates durable OS state from the independently formattable `/data`.
`nofail` mounts keep diagnostics alive when recording storage fails, while the
service's mount witness makes mutations fail closed.

The current expanded development root could not be shrunk online, making adoption a
reflash flag day. Partitioning stayed a guarded, geometry-only on-Pi operation;
Ansible retained ownership of fstab, mounts, directories, and image policy.

Overlayfs was rejected for RAM cost and silent read-write failure modes. A single
writable root could be bricked by a power cut and could not support a safe app-driven
data format. Journald on `/data` would erase the evidence most needed when that
partition failed. Industrial PLP media was deferred on cost and supply, and
synchronous `discard` was rejected in favor of periodic fstrim.

### 2026-07-17 -- Keep storage identity inside the recording namespace

The durable storage generation lives beside the sequence witness under `/data/rec`,
not in `/persist` or machine identity. This makes it survive service and OS restarts
and move with a deliberately preserved recording namespace, while format and reset
operations naturally create a new identity. Keeping it in OS state was rejected
because replacing or cloning recording media would detach identity from the footage it
names.

### 2026-07-17 -- Build complete signed cards and commission once

Production card creation moved from a development bring-up sequence to a complete
signed image plus a separately safe Mac flasher. A small initialized p4 lets first
boot grow an existing known filesystem without treating missing signatures as format
authority. The Mac owns per-unit secret creation because the same operation can emit
the QR recovery record without exposing a generic shared secret.

Runtime blank-media formatting and an app format route were rejected because damaged
post-commission footage is not distinguishable from disposable media. Building during
every flash was rejected because release inputs and results would vary between users.

### 2026-07-20 -- Make the controlled Linux builder a one-command Mac operation

Requiring the publisher to provision and enter an aarch64 Linux environment made the
documented image task incomplete on the development Mac. The Mac-facing task now owns
a reusable, pinned NixOS OrbStack machine and dispatches the unchanged privileged
Linux build inside it. A repository-shared working directory keeps the committed
source and resulting `dist/` artifacts identical on both sides while the ignored
signing key remains in its checkout-local protected location.

### 2026-07-20 -- Resume only after complete image verification

A flash interrupted after its complete image write can compare every card chunk with
the authenticated input instead of repeating the slow destructive write. Resume is
explicit, retains removable-media identity and typed confirmation, and only repairs
up to 64 MiB of differences held in memory. It rereads repaired chunks before
personalization and refuses a partial or broadly mismatched card.

### 2026-07-20 -- Claim media across write and verification

Rewriting a partition table causes macOS Disk Arbitration to discover and auto-mount
the FAT boot volume. An unmount before transfer does not prevent that later discovery,
and the mount changes FAT metadata before raw readback. The transfer helper therefore
claims the whole disk for exclusive use across both phases; releasing the claim only
after verification removes the mutation window rather than weakening verification.

### 2026-07-20 -- Preserve the boot root partition identity

Rewriting a DOS partition table without an explicit label id lets `sfdisk` generate
a new disk identifier while the inherited kernel command line still names the base
image's root `PARTUUID`. Firmware then loads the kernel, but Linux waits forever for
a nonexistent root device. Image assembly now preserves the authenticated base id,
asserts the resulting root reference, and pins the US regulatory domain needed by
the production access point.
