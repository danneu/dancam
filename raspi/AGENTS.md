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
  - 120 deg diagonal FOV, HDR, PDAF autofocus, Sony IMX708, libcamera-native.
  - Ships with a 15-22pin "Standard-Mini" FPC cable: 15-pin at the camera, 22-pin
    at the board. The 22-pin end plugs into the Zero 2 W's mini-CSI port (same
    connector as the Pi 5 and Compute Modules), and the 15-pin end plugs into the
    camera. A standard Pi 3/4's 15-pin CSI port would instead need a 15-15
    "Standard-Standard" cable.
  - This is not an official module, so it is not auto-detected. Enable it with
    `camera_auto_detect=0` and `dtoverlay=imx708` in `/boot/firmware/config.txt`;
    full steps live in "OS and first flash".
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
  resistant by design. See the recording ADR.
- **Thermals.** Windshield + Texas sun. Mount high near the rear-view mirror (coolest,
  most-shaded zone), ventilate, heatsink the SoC. Recording-while-parked ("sentry")
  is unreliable in peak summer because the cabin exceeds the camera's 50 C limit --
  treat it as best-effort, not a guarantee.

## Software stack (intended)

Most of this is now settled in ADRs (linked per item below); the remainder is the
current provisional direction until it is captured.

- **OS:** Raspberry Pi OS Lite, 64-bit (Trixie / Debian 13), with a **read-only
  root filesystem** (overlayfs) so power loss can never corrupt the OS. Footage
  goes on a **separate journaled partition** (ext4 or F2FS). See the crash-safe
  recording ADR.
- **Capture/encode:** `rpicam-vid` (libcamera), driven as a **subprocess** by the
  Rust service (never linked -- see the service-language ADR). Output segmented
  MPEG-TS (`.ts`) with inline headers -- truncation-tolerant and HLS-native for the
  iPhone. See the crash-safe recording ADR for why TS over raw H.264 / MP4.
- **Storage model:** a **ring buffer** of short segments; oldest deleted as the card
  fills; incident-locked segments are exempt from deletion. See the storage
  ring-buffer / incident-lock ADR.
- **Access point:** a NetworkManager hotspot (`nmcli`, `ipv4.method=shared`) on
  the 2.4 GHz band so the phone can connect directly with no router. The current
  dev profile is `dancam-ap`: SSID `dancam-dev`, WPA2-PSK entered manually (do not
  commit the password), channel 1, `ipv4.addresses 10.42.0.1/24`,
  `ipv6.method ignore`, and `connection.autoconnect no`. NM shared mode runs its own
  `dnsmasq` for DHCP/DNS; during bring-up it served `10.42.0.10` through
  `10.42.0.254`. ADR 02's captive-probe DNS lever is applied through that instance,
  not a hand-run DNS service, but is deferred until persistent no-internet joins need
  it. The concrete AP decision is in
  `docs/design/06-2026-06-25-ap-networking-bring-up.md`.
- **Control + media service:** a small **Rust** service (see the service-language
  ADR) exposing a control API (start/stop, settings, time sync, incident lock) and a
  media API (list/preview/pull clips) to the app.
- **Power-loss safety:** an industrial microSD with power-loss protection (PLP). The
  unit runs off a switched USB accessory source that dies with the car, so power loss
  is abrupt and unsignaled -- no clean-shutdown path and no supercapacitor; the
  crash-safe layers carry recording integrity. No lithium batteries -- they are a fire
  risk baking in a hot car. See `docs/design/04-2026-06-23-power-source-and-shutdown.md`.

## Structure (planned)

```
raspi/
  AGENTS.md
  service/            <- Rust service crate (package/binary `dancam`)
  docs/design/        <- raspi-side ADRs
  (capture/provisioning code to be added)
```

## Build / run

The service lives in `raspi/service/` and is written in **Rust** with the camera driven
as a subprocess (`rpicam-vid`); the rationale is in
`docs/design/05-2026-06-23-service-language-rust.md`. Two facts shape the whole workflow:
release code is **cross-compiled on the dev host** (never built on the Pi), and the
**dev image differs from the car image**.

### Local Mac service loop

Use the root `Justfile` for common service tasks. Agents should prefer these commands
over raw `cargo` commands unless they need to test a lower-level Cargo behavior.

- `just raspi-build` -- build the service for the local host.
- `just raspi-test` -- run the service test suite.
- `just raspi-run` -- run the mock Pi service on `127.0.0.1:8080`.
- `just raspi-run-lan` -- run the mock Pi service on `0.0.0.0:9000` for testing from
  another LAN device, such as the iPhone.

### Dev image vs. car image

Same Raspberry Pi OS base, two configurations:

| | Dev image (on the desk) | Car image (deployed) |
|---|---|---|
| Root filesystem | writable -- edit & restart freely | read-only (overlayfs) |
| Network | joins home Wi-Fi as a client; AP is a manual `dancam-ap` toggle | runs the AP (NetworkManager hotspot, 2.4 GHz) |
| Access | `ssh dan@dancam.local` over the LAN; if AP is up, use a separate client, not the Mac's only Wi-Fi interface | phone joins the Pi's AP |
| Recordings | a folder on root is fine early | dedicated journaled `/data` partition |

The early swoops live in the dev image. Read-only root, AP mode, and the partition
layout are a hardening pass (the crash-safe ADR is the north star, not the spec for
early swoops) -- not something to fight while iterating.

### OS and first flash (once)

- **Raspberry Pi OS Lite, 64-bit** (Trixie / Debian 13; the 2026-06-18 build,
  kernel 6.18 LTS). Lite = headless and lean for 512 MB; Trixie ships
  `rpicam-vid` and the IMX708 driver in-kernel. Our Arducam B0311 is not
  auto-detected (it is not an official module), so enable it with the kernel's
  in-tree overlay: set `camera_auto_detect=0` and add `dtoverlay=imx708` to
  `/boot/firmware/config.txt`, then reboot -- no install script, no tuning file,
  and it survives kernel upgrades. Do NOT use Arducam's legacy
  `install_pivariety_pkgs.sh` driver: it ships prebuilt per-kernel binaries that
  break on every `apt upgrade` (the source of the "had to downgrade the kernel"
  reports). The official Camera Module 3 would auto-detect with no config -- same
  IMX708 sensor -- if we ever want zero camera setup. On this 512 MB board,
  camera/codec buffers come from CMA; the old `gpu_mem` split is obsolete. If
  `rpicam` reports buffer-allocation failures, raise CMA with a `config.txt`
  overlay such as `dtoverlay=cma,cma-size=...`, not `gpu_mem`.
- Flash with **current Raspberry Pi Imager (2.0.10 or newer)**, pre-setting
  hostname (`dancam`), SSH on, the user, and **home Wi-Fi credentials**. Current
  Trixie images use cloud-init for first-boot customization: Imager 1.9.x cannot
  customize Trixie, and the 2.0.6-2.0.8 stable releases can leave headless SSH off
  by emitting the deprecated `enable_ssh` key (fixed in the 2.0.9 prerelease and
  stable in 2.0.10). Editing files on the boot partition is the legacy fallback.
  Boot headless, then `ssh dan@dancam.local` over the LAN (mDNS). No monitor or
  keyboard, and no card-shuffling after this.
- Scope Avahi/mDNS to the Wi-Fi interface after first boot:
  set `allow-interfaces=wlan0` in `/etc/avahi/avahi-daemon.conf`, then
  `sudo systemctl restart avahi-daemon`. Without this, Avahi can publish on
  loopback before Wi-Fi settles, later detect its own stale `dancam.local`
  advertisement as a conflict, and rename the host to `dancam-2.local`.
- Fallback if Wi-Fi is fussy: the data micro-USB port supports gadget mode
  (`g_ether`) -> SSH over the USB cable.

### microSD partition layout (car image)

One physical card (the Zero 2 W has a single slot); OS and footage share it in
separate partitions. The card must be high-endurance / PLP-rated (see the crash-safe
ADR).

```
p1  ~512MB  FAT32      /boot/firmware   firmware (effectively read-only)
p2  ~8-16GB ext4       /                OS root -- mounted READ-ONLY (overlayfs)
p3  rest    ext4/f2fs  /data            recordings ring buffer + logs (only RW partition)
```

Only `/data` is written at runtime, which is what makes abrupt power loss safe:
journaled, `fsync()` at segment close, on a PLP card; `p1`/`p2` are read-only so a
cut cannot corrupt the OS. Note: the app's "format the SD" action (swoop `kelp`)
clears **`/data` only**, never the whole card -- the OS lives on the same card. (Early
dev skips this layout entirely -- see the dev-vs-car note above.)

### Rust dev loop

Cross-compile on the Mac -- 512 MB cannot build a real dependency tree. The dev
machine's Rust is Nix-managed (no `rustup`), so the toolchain comes from a flake dev
shell, not `rustup target add`.

- One-time: nothing to install by hand -- `flake.nix` (repo root) pins a Rust
  toolchain carrying the `aarch64-unknown-linux-musl` target plus `zig` +
  `cargo-zigbuild` (zig is the cross-linker; the deps are pure Rust, so no C cross-
  toolchain is needed). Just need Nix with flakes enabled.
- Build: `nix develop -c cargo zigbuild --release --target
  aarch64-unknown-linux-musl --manifest-path raspi/service/Cargo.toml` -> a single
  static musl binary (nothing to install on the read-only root; the service-language
  ADR covers why musl/static).
- Deploy: `just raspi-deploy` (wraps `./raspi/deploy.sh`) -- cross-builds, rsyncs the
  binary + the systemd unit to the Pi, installs both, enables/restarts the service,
  and curls `/v1/health`. Idempotent; re-run on every change. Override the target with
  `DANCAM_HOST=... just raspi-deploy`.
  VS Code Remote-SSH is handy for poking around the Pi directly.

### Running

- A **systemd unit** (`raspi/dancam.service`, installed to `/etc/systemd/system/`
  by `deploy.sh`) runs the service: auto-start on boot (also how the car image
  auto-records on boot) and restart-on-crash. It sets `DANCAM_BIND=0.0.0.0:8080` so
  the service listens on all interfaces; the binary defaults to loopback-only.
- Logs: `journalctl -u dancam -f`. Under the read-only car image, point logs at
  `/data` or keep them in RAM -- root is not writable.

### Pointing the app at the unit

- Dev: app (or the mock Pi) and the Pi both on home Wi-Fi; hit
  `http://dancam.local:8080/v1/...` (port 8080 per the systemd unit; the transport
  ADR covers the wire contract). If `dancam.local` times out but the raw LAN IP
  works, check `systemctl status avahi-daemon`: a status like
  `running [dancam-2.local]` means Avahi conflict-renamed itself. Verify
  `/etc/avahi/avahi-daemon.conf` contains `allow-interfaces=wlan0`, then restart
  `avahi-daemon`.
- AP bring-up / car path: the phone joins the Pi's AP and talks to
  `http://10.42.0.1:8080/v1/...`. The dev AP profile does not autoconnect; schedule a
  detached revert before flipping it over SSH:
  `sudo systemd-run --unit=dancam-restore-home-wifi --on-active=5min /usr/bin/nmcli connection up netplan-wlan0-peluchonet`.
  Use a fresh unit name if that one is already loaded. After it returns, inspect it
  with
  `journalctl -b -u dancam-restore-home-wifi.service -u dancam-restore-home-wifi.timer`.
  Power cycling also returns the dev image to home Wi-Fi. The current dev image keeps
  only the current boot's journal, so previous-boot AP failures are lost after a
  reset unless persistent journald is enabled later.

## Design decisions (ADRs)

See the root `AGENTS.md` for the ADR convention. Raspi-side ADRs live in
`docs/design/`. Current:

- `01-2026-06-22-crash-safe-recording.md` -- how recording survives abrupt power loss
  (format + filesystem + card hardware layers).
- `02-2026-06-22-app-pi-transport-and-api.md` -- the app<->Pi wire contract: transport
  per plane (control/events/preview/clip-pull), the `/v1` API surface, connection
  lifecycle, WPA2-only auth posture, and the incident-lock idempotency contract. The
  Pi owns this contract; the canonical copy lives here.
- `03-2026-06-23-storage-ring-buffer-incident-lock.md` -- the Pi storage model:
  segment ring buffer, no-RTC ordering, incident hardlink locks, pre-sync holds,
  caps, rebuild, and the in-process storage service interface.
- `04-2026-06-23-power-source-and-shutdown.md` (Proposed) -- the v1 power topology
  (switched USB accessory source, 5V regulated, dies with the car) and the decision
  to design for abrupt, unsignaled power loss with no clean-shutdown path. Resolves
  the crash-safe ADR's deferred supercapacitor question (dropped for this topology).
- `05-2026-06-23-service-language-rust.md` (Accepted) -- the Pi service is written in
  Rust, cross-compiled on the dev host to a single static binary and run under
  systemd; the camera is driven as a subprocess (`rpicam-vid`), not linked. See the
  Build / run section above for the dev loop.
