# dancam -- camera unit (Raspberry Pi)

The camera unit is the recorder. Its job is narrow and it should stay that way:
**capture -> encode -> store crash-safely on the microSD -> serve footage to the
phone on request.** It is the source of truth for footage. The iPhone app
(`../app/`) is the UI and brains; the Pi is deliberately dumb.

Read the root [`../AGENTS.md`](../AGENTS.md) first for the system picture and
cross-cutting principles. This file covers the camera unit; its sibling, the iPhone
app, is documented in [`../app/AGENTS.md`](../app/AGENTS.md).

## Hardware (v1)

- **Board:** [Raspberry Pi Zero 2 W (2021)](https://www.amazon.com/gp/product/B09LH5SBPS)
  (~60 USD).
  - Quad-core Cortex-A53 @ 1 GHz, **512 MB RAM** (tight -- keep the software lean).
  - **Wi-Fi: 2.4 GHz 802.11 b/g/n only. No 5 GHz.** This shapes the whole link
    design (preview + pull only; see below).
  - **Hardware H.264 encode capped at 1080p30.** Plan for 1080p30; no 4K, no HEVC
    encode, and the camera's higher modes (1080p50 etc.) cannot be hardware-encoded.
  - Operating range -20 C to +70 C ambient. **No real-time clock** -- time comes
    from the phone (on connect) and/or a GPS module.
  - 40-pin header is unpopulated from the factory.
- **Camera:** [Arducam 12MP IMX708 Autofocus Wide](https://www.amazon.com/gp/product/B0C5D97DRJ)
  (~30 USD; Camera Module 3 Wide equivalent).
  - ~120 deg diagonal FOV (Arducam's own specs disagree: the product page says
    120 deg D, their wiki says 110 deg D x 100 deg H x 72 deg V; either way slightly
    narrower than the official CM3 Wide's 120 D / 102 H / 67 V), HDR, PDAF autofocus,
    Sony IMX708, libcamera-native.
  - Ships with a 15-22pin "Standard-Mini" FPC cable: 15-pin at the camera, 22-pin
    at the board. The 22-pin end plugs into the Zero 2 W's mini-CSI port (same
    connector as the Pi 5 and Compute Modules), and the 15-pin end plugs into the
    camera. A standard Pi 3/4's 15-pin CSI port would instead need a 15-15
    "Standard-Standard" cable.
  - This is not an official module, so it is not auto-detected; it needs
    `camera_auto_detect=0` and `dtoverlay=imx708` in `/boot/firmware/config.txt`.
    The playbook applies that overlay (`ansible/site.yml`); the rationale lives in
    "OS and first flash".
  - **Operating temp 0 C to +50 C -- this is the system's thermal weak link**, not
    the board. Hot-parked operation is bounded by the sensor, not the Pi.

The chosen camera meets the v1 requirements: 120-140 deg + HDR + autofocus +
acceptable low light. Note that HDR + autofocus together exist only on the IMX708 in
this ecosystem, and autofocus tops out at 120 deg (wider needs a fixed-focus M12 lens).

## Constraints that drive the design

- **2.4 GHz, preview + pull only.** The Pi runs its own access point (the phone
  joins it). Realistic throughput is low and congested. Design: always record full
  quality to SD; serve a low-res preview and on-demand clip pulls. Never treat the
  Wi-Fi link as part of the recording path.
- **1080p30 H.264 ceiling.** Match the encode to the hardware. HDR mode reduces
  resolution and adds ISP load on a 512 MB board -- use it selectively, not always-on.
- **Power can be cut at any instant** (engine off). Recording must be corruption-
  resistant by design. See the [recording design](../docs/design/pi/recording.md).
- **Thermals.** Windshield + Texas sun. Mount high near the rear-view mirror (coolest,
  most-shaded zone), ventilate, heatsink the SoC. Recording-while-parked ("sentry")
  is unreliable in peak summer because the cabin exceeds the camera's 50 C limit --
  treat it as best-effort, not a guarantee.

## Software stack (intended)

Most of this is now settled in the living design pages linked per item below; the
remainder is the current provisional direction until it is captured.

- **OS:** Raspberry Pi OS Lite, 64-bit (Trixie / Debian 13). The car image uses a
  **plain read-only ext4 root** (no overlayfs), read-only `/boot/firmware`, a small
  writable `/persist` OS-state island, and a writable ext4 `/data` recording
  partition. The dev image uses the same partition layout but keeps root writable.
  See the [OS image design](../docs/design/pi/os-image.md).
- **Capture/encode:** a single Picamera2 camera-owner subprocess, supervised by the
  Rust service over stdio (never linked -- see the
  [service runtime design](../docs/design/pi/service.md) and the
  [recording design](../docs/design/pi/recording.md)). It owns libcamera once, emits
  low-res MJPEG preview from the lores stream, and writes segmented MPEG-TS (`.ts`)
  recordings with inline headers under `DANCAM_REC_DIR` -- truncation-tolerant and
  timestamped for the iPhone. The camera owner locks the lens to infinity and
  disables autofocus for both recording and preview streams; the recording page also
  owns the focus policy and why TS wins over raw H.264 / MP4.
- **Storage model:** a **ring buffer** of short segments; oldest finished segments
  are drip-evicted as the card fills. Incidents are phone-owned and do not lock
  Pi segments in v1; the coordinator retains an unused protection seam for future
  evidence-driven pinning. See the [storage design](../docs/design/pi/storage.md)
  and [incident design](../docs/design/app/incidents.md).
- **Access point:** a NetworkManager hotspot (`nmcli`, `ipv4.method=shared`) on
  the 2.4 GHz band so the phone can connect directly with no router. The current
  dev profile is `dancam-ap`: SSID `dancam-dev`, WPA2-PSK pinned to AES
  (RSN/CCMP, no TKIP), channel 1, `ipv4.addresses 10.42.0.1/24`,
  `ipv6.method ignore`, and `connection.autoconnect no`. Ansible provisions every
  field of this profile except the PSK (see the
  [provisioning design](../docs/design/pi/provisioning.md)); the password is set
  by hand on the Pi so it never enters the repo. NM shared mode runs its own
  `dnsmasq` for DHCP/DNS; during bring-up it served `10.42.0.10` through
  `10.42.0.254`. The transport boundary's captive-probe DNS lever is applied through
  that instance, not a hand-run DNS service, but is deferred until persistent
  no-internet joins need it. The concrete topology and AP decision are in the
  [networking design](../docs/design/pi/networking.md).
- **Control + media service:** a small **Rust** service (see the
  [service runtime design](../docs/design/pi/service.md)) exposing a control API
  (start/stop, settings, time sync) and a media API
  (list/preview/pull clips) to the app. Incidents use those read surfaces and add
  no Pi-side API in v1.
- **Power-loss safety:** a high-endurance consumer microSD treated as a consumable,
  plus software layers that recover cleanly when power is cut. Consumer endurance
  cards in this tier do **not** provide PLP, so the remaining FTL risk is accepted and
  mitigated with a read-only OS, journaled `/data`, segment-close fsync, a 5% unwritten
  tail, and oldest-first ring GC with a free-space floor. The unit runs off a switched
  USB accessory source
  that dies with the car, so power loss is abrupt and unsignaled -- no clean-shutdown
  path and no supercapacitor. No lithium batteries -- they are a fire risk baking in a
  hot car. See the [OS image design](../docs/design/pi/os-image.md).

## Structure (planned)

```
raspi/
  AGENTS.md
  camera/             <- Picamera2 camera-owner subprocess (`camera.py`)
  service/            <- Rust service crate (package/binary `dancam`)
```

## Build / run

The service lives in `raspi/service/` and is written in **Rust** with the camera driven
as a supervised subprocess; the rationale is in the
[service runtime design](../docs/design/pi/service.md), while the current Picamera2
owner is specified by the [recording design](../docs/design/pi/recording.md). Two facts
shape the whole workflow:
release code is **cross-compiled on the dev host** (never built on the Pi), and the
**dev image differs from the car image**.

The Ansible playbook (`ansible/site.yml`) is the source of truth for onboard **system
state** -- apt packages, `/boot/firmware/config.txt`, NetworkManager profiles, Avahi
scoping, locale, and group membership. When a raspi change touches any of that, update
`site.yml` and its task comment in the same change (the comment is the single home of
the *why*); see the [provisioning design](../docs/design/pi/provisioning.md). The
systemd unit and deploy paths stay `deploy.sh`'s. This directory's
[`README.md`](README.md) is the bootstrap/verify/ops runbook -- flash, SSH,
smoke-tests, the one-time manual AP PSK, the AP safe-flip procedure -- and is kept in
sync in the same change whenever the human-facing steps move.

### Local Mac service loop

Use the root `Justfile` for common service tasks. Agents should prefer these commands
over raw `cargo` commands unless they need to test a lower-level Cargo behavior.

- `just raspi-build` -- build the service for the local host.
- `just raspi-test` -- run the service test suite.
- `just raspi-mock` -- run the mock Pi service on `127.0.0.1:8080`.
- `just raspi-mock-gc` -- run the mock recorder with an impossible free-space
  floor to watch GC eviction and its exhausted/backoff path. Expect an initial
  ~30 s quiet window, then eviction in ~30 s bursts; this dev-only cadence is
  not the steady one-in-one-out drip produced by a realistic floor.
- `just raspi-mock-lan` -- run the mock Pi service on `[::]:9000` for testing from
  another LAN device, such as the iPhone.

### Dev image vs. car image

Same Raspberry Pi OS base, two configurations:

| | Dev image (on the desk) | Car image (deployed) |
|---|---|---|
| Root filesystem | writable plain ext4 root -- edit & restart freely | plain read-only ext4 root (no overlayfs) |
| Network | joins home Wi-Fi as a client; AP is a manual `dancam-ap` toggle | phone path uses the persisted `dancam-ap` hotspot; AP autoconnect policy is a later decision |
| Access | `ssh <your-username>@dancam.local` over the LAN; if AP is up, use a separate client, not the Mac's only Wi-Fi interface | phone joins the Pi's AP |
| Recordings | dedicated `/data/rec` partition path, with root still writable for dev | dedicated `/data/rec` on the journaled data partition |
| Logs / OS state | persistent journald and small OS state under `/persist` | journald, NetworkManager state, and timesync state under `/persist`; `/data` stays format-safe |

The dev image is where we build: writable root, manual AP toggle, same `/data` and
`/persist` partition layout, so we can edit and restart freely. The car image (plain
read-only root, writable `/data`, and `/persist` for OS/connection state) is how that
same durably-built software gets packaged for deployment; the recording and storage
designs are the specs both build toward. AP autoconnect is intentionally not
settled here. This is a forced difference in how the software is *run*, not a license
to build the software itself dumb first and harden later -- you just don't fight
read-only root on the desk.

### OS and first flash (once)

- **Raspberry Pi OS Lite, 64-bit** (Trixie / Debian 13; the 2026-06-18 build,
  kernel 6.18 LTS). Lite = headless and lean for 512 MB; Trixie ships
  `rpicam-vid` and the IMX708 driver in-kernel. Our Arducam B0311 is not
  auto-detected (it is not an official module), so it needs the kernel's in-tree
  overlay -- `camera_auto_detect=0` plus `dtoverlay=imx708` in
  `/boot/firmware/config.txt` -- with no install script, no tuning file, and it
  survives kernel upgrades. The playbook applies that overlay and reboots; the
  command and its idempotency notes live in `ansible/site.yml`. Do NOT use
  Arducam's legacy `install_pivariety_pkgs.sh` driver: it ships prebuilt
  per-kernel binaries that break on every `apt upgrade` (the source of the "had
  to downgrade the kernel" reports). The official Camera Module 3 would
  auto-detect with no config -- same IMX708 sensor -- if we ever want zero camera
  setup. On this 512 MB board, camera/codec buffers come from CMA; the old
  `gpu_mem` split is obsolete. If `rpicam` reports buffer-allocation failures,
  raise CMA with a `config.txt` overlay such as `dtoverlay=cma,cma-size=...`, not
  `gpu_mem`.
- Flash with **current Raspberry Pi Imager (2.0.10 or newer)**, pre-setting
  hostname (`dancam`), SSH on, the user, and **home Wi-Fi credentials**. Current
  Trixie images use cloud-init for first-boot customization: Imager 1.9.x cannot
  customize Trixie, and the 2.0.6-2.0.8 stable releases can leave headless SSH off
  by emitting the deprecated `enable_ssh` key (fixed in the 2.0.9 prerelease and
  stable in 2.0.10). Editing files on the boot partition is the legacy fallback.
  Boot headless, then `ssh <your-username>@dancam.local` over the LAN (mDNS). No monitor or
  keyboard, and no card-shuffling after this.
- The playbook scopes Avahi/mDNS to the Wi-Fi interface --
  `allow-interfaces=wlan0` in `/etc/avahi/avahi-daemon.conf` (see
  `ansible/site.yml`). Without this, Avahi can publish on loopback before Wi-Fi
  settles, later detect its own stale `dancam.local` advertisement as a conflict,
  and rename the host to `dancam-2.local`.
- Fallback if Wi-Fi is fussy: the data micro-USB port supports gadget mode
  (`g_ether`) -> SSH over the USB cable.

### microSD partition layout

One physical card (the Zero 2 W has a single slot); OS, OS state, and footage share it
in separate partitions. Minimum supported card: 32 GB high-endurance consumer microSD.
Consumer cards in this tier are **not PLP cards**, so the software assumes abrupt
power loss can still interrupt the card's FTL and keeps every higher layer
recoverable.

All partition starts are 4 MiB-aligned. p1 through p3 are fixed size; p4 flexes with
capacity and leaves about 5% of the card unpartitioned for flash overprovisioning.

```
p1  512 MiB  FAT32  /boot/firmware  ro in car  firmware and kernels
p2  8 GiB    ext4   /               ro in car  plain read-only root, no overlayfs
p3  1 GiB    ext4   /persist        rw         logs, NetworkManager, timesync state
p4  rest-5%  ext4   /data           rw         recording ring under /data/rec
    ~5% unpartitioned tail, never written
```

`/data` is the only hot recording partition. The app's "format the SD" action (swoop
`kelp`) reformats **`/data` only**, never `/persist` or the OS partitions, so logs and
connectivity state survive a data-partition format or failure. The deployed service
sets `DANCAM_REC_DIR=/data/rec` and `DANCAM_REQUIRE_REC_MOUNT=/data`; with `nofail`
fstab entries, boot and diagnostics stay up when `/data` is missing while recording
mutations fail closed at the service boundary. Ring GC uses
`DANCAM_GC_FLOOR_BYTES`, defaulting to 2 GiB of available space on the recording
filesystem; set it to `0` to disable GC. The deployed unit relies on this in-binary
default, so the systemd unit does not duplicate it. See the
[OS image design](../docs/design/pi/os-image.md).

### Rust dev loop

Cross-compile on the Mac -- 512 MB cannot build a real dependency tree. The dev
machine's Rust is Nix-managed (no `rustup`), so the toolchain comes from a flake dev
shell, not `rustup target add`.

- One-time: nothing to install by hand -- `flake.nix` (repo root) pins a Rust
  toolchain carrying the `aarch64-unknown-linux-musl` target plus `zig` +
  `cargo-zigbuild` (zig is the cross-linker; the deps are pure Rust, so no C cross-
  toolchain is needed). The same dev shell also ships `ansible` + `ansible-lint` for
  Pi provisioning (`just raspi-provision*`; see the
  [provisioning design](../docs/design/pi/provisioning.md)). Just need Nix with
  flakes enabled.
- Build: `nix develop -c cargo zigbuild --release --target
  aarch64-unknown-linux-musl --manifest-path raspi/service/Cargo.toml` -> a single
  static musl binary (nothing to install on the read-only root; the
  [service runtime design](../docs/design/pi/service.md) covers why musl/static).
- Deploy: `just raspi-deploy` (wraps `./raspi/deploy.sh`) -- cross-builds, rsyncs the
  binary + the systemd unit to the Pi, installs both, enables/restarts the service,
  then waits in two phases over `/v1/status`: first for a valid JSON boolean
  [`recording_readiness.ready`](../docs/design/pi/telemetry.md#recording-readiness),
  then for that boolean to become true. The first valid body is reused immediately
  by the readiness phase. Override the 60 second
  reachability bound with `DANCAM_STATUS_TIMEOUT` and the recording-ready bound with
  `DANCAM_RECORDING_READINESS_TIMEOUT` (it defaults to the reachability bound). A
  readiness timeout prints the last valid status and gathers separately bounded
  service-environment, `/data` mount, disk-space, and journal diagnostics. Idempotent;
  re-run on every change. Override the target with
  `DANCAM_HOST=... just raspi-deploy`.
  VS Code Remote-SSH is handy for poking around the Pi directly.

### Running

- A **systemd unit** (`raspi/dancam.service`, installed to `/etc/systemd/system/`
  by `deploy.sh`) runs the service: auto-start on boot and restart-on-crash. The
  recorder currently comes up idle until the app starts it; auto-record-on-boot is
  future work. The unit sets `DANCAM_BIND=[::]:8080` so
  the service listens on the dual-stack wildcard and `DANCAM_BACKEND=camera` so
  preview uses the real camera; the binary defaults to loopback-only and the mock
  backend.
- Logs: `journalctl -u dancam -f`. Persistent journald is backed by
  `/persist/journal` and bind-mounted at `/var/log/journal`, so previous-boot logs
  survive without making `/data` carry OS state.
- Ring GC emits a structured `ring_gc_outcome` event only when it deletes footage
  or enters its 30-second backoff. `outcome` distinguishes `reached_floor`,
  `batch_capped`, `exhausted`, `probe_unavailable`, and `failed`;
  `deleted_count`, ordered bounded `deleted_ids`, `avail_before`, `avail_after`, and
  `floor_bytes` preserve the decision evidence. Backoff events add
  `retry_after_s=30`, and failures add `error`. Healthy above-floor polling stays
  silent. Use `journalctl -u dancam --grep ring_gc_outcome` for recent decisions,
  or `journalctl -b -1 -u dancam --grep ring_gc_outcome` after a reboot.
- Request/response access logs include `x-request-id` for app/Pi correlation; grep
  `journalctl -u dancam` for the response id. Pi-generated ids are a per-process
  incrementing counter that resets on service start; safe inbound ids are still echoed.
  Raise runtime verbosity without a rebuild with `RUST_LOG=dancam=debug` (the current
  `Targets` filter supports `target=level`, not span/field directives) to include
  emitted SSE events with `seq` and body; `RUST_LOG=dancam=trace` adds heartbeats.
- The dev image auto-reboots on a hard freeze via the on-board BCM2835 hardware
  watchdog (systemd `RuntimeWatchdogSec`), recovering the service unattended; paired
  persistent journald keeps the previous boot's logs for the post-mortem. See the
  [OS image design](../docs/design/pi/os-image.md).

### Pointing the app at the unit

- Dev: app (or the mock Pi) and the Pi both on home Wi-Fi; hit
  `http://dancam.local:8080/v1/...` (port 8080 per the systemd unit; the transport
  [design](../docs/design/boundary/transport.md) covers the wire contract). If
  `dancam.local` times out but the raw LAN IP works, check
  `systemctl status avahi-daemon`: a status like
  `running [dancam-2.local]` means Avahi conflict-renamed itself. Verify
  `/etc/avahi/avahi-daemon.conf` contains `allow-interfaces=wlan0`, then restart
  `avahi-daemon`.
- AP bring-up / car path: the phone joins the Pi's AP and talks to
  `http://10.42.0.1:8080/v1/...`. The dev AP profile does not autoconnect; schedule a
  detached revert before flipping it over SSH:
  `sudo systemd-run --unit=dancam-restore-home-wifi --on-active=5min /usr/bin/nmcli connection up "$DANCAM_HOME_WIFI"`.
  Use a fresh unit name if that one is already loaded. From the Mac, `just raspi-ap
  [minutes]` wraps this arm + AP flip and prints a local countdown to the revert; it
  detaches the AP-up as a transient `dancam-go-ap` unit so the SSH session returns
  before Wi-Fi drops. After it returns, inspect it with
  `journalctl -b -u dancam-restore-home-wifi.service -u dancam-restore-home-wifi.timer`.
  Power cycling also returns the dev image to home Wi-Fi. Persistent journald is now
  enabled on the dev image, so previous-boot logs survive a reset -- including watchdog
  reboots and abrupt power loss -- and a prior boot's AP failure is diagnosable via
  `journalctl -b -1` (bounded by the last fsync; see the
  [OS image design](../docs/design/pi/os-image.md)).

## Design pages

- [Recording](../docs/design/pi/recording.md) -- read when changing camera capture,
  encoding, focus, segment format, recorder state, supervision, or command lifecycle.
- [Storage](../docs/design/pi/storage.md) -- read when changing segment identity,
  time derivation, startup scrub, clip deletion, or ring GC.
- [OS image, power, and recovery](../docs/design/pi/os-image.md) -- read when changing
  the power topology, partition or mount layout, writable OS state, card policy,
  watchdog, or persistent journald.
- [Networking](../docs/design/pi/networking.md) -- read when changing the Wi-Fi
  topology, NetworkManager AP profile, gateway, mDNS scoping, or AP safe-flip loop.
- [Provisioning](../docs/design/pi/provisioning.md) -- read when changing Ansible
  ownership, convergence, per-machine connection config, service identity, or the
  boundary between provisioning, deploy, partitioning, and operator steps.
- [Service runtime and request tracing](../docs/design/pi/service.md) -- read when
  changing the Rust runtime, cross-build or deploy model, request logs, request ids,
  runtime log filtering, or log-access path.
- [Operational telemetry and recording readiness](../docs/design/pi/telemetry.md) --
  read when changing canonical status, readiness derivation, filesystem observation,
  storage capacity telemetry, or deploy readiness checks.
- [Transport boundary](../docs/design/boundary/transport.md) -- read when changing
  routes, response semantics, SSE framing, preview, clip pull, or app/Pi trust.
