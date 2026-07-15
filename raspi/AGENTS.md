# dancam -- camera unit (Raspberry Pi)

The camera unit is the recorder: capture, encode, store crash-safely on microSD,
and serve footage to the phone on request. The Pi is the footage source of truth;
the iPhone app is the UI and brains.

Read the root [`../AGENTS.md`](../AGENTS.md) first. This file owns Pi-side stance,
constraints, and commands; [`../app/AGENTS.md`](../app/AGENTS.md) owns the app side.

## Hardware constraints

The v1 unit is a Raspberry Pi Zero 2 W with an Arducam IMX708 Autofocus Wide.
Read the [hardware reference](../docs/hardware.md) for parts, cabling, FOV, and OS
compatibility.

- 512 MB RAM -- keep the software lean.
- 2.4 GHz Wi-Fi only -- no 5 GHz radio.
- Hardware H.264 encode is capped at 1080p30 -- no 4K or HEVC encode.
- No real-time clock -- time comes from the phone and/or a future GPS module.
- The camera is rated only to 50 C -- it is the thermal weak link.

## Design constraints

- Record full quality locally and use Wi-Fi only for low-resolution preview and
  on-demand pulls. The link is never part of the recording path.
- Power may disappear at any instant. Segment format, filesystem policy, and card
  handling must recover without a clean shutdown.
- Windshield heat is expected. Sentry recording is best-effort in peak summer, not
  a guarantee.

## Software stack

- **OS:** Raspberry Pi OS Lite 64-bit (Trixie). The dev image has writable plain
  ext4 root; the car image uses read-only root and boot with writable `/persist` and
  `/data`. See the [OS image design](../docs/design/pi/os-image.md).
- **Capture and encode:** one supervised Picamera2 camera-owner subprocess owns
  libcamera and emits MJPEG preview plus segmented MPEG-TS recording. See
  [recording](../docs/design/pi/recording.md) and [service runtime](../docs/design/pi/service.md).
- **Storage:** short segments form an oldest-first ring on `/data`; incidents stay
  phone-owned. See [storage](../docs/design/pi/storage.md).
- **Networking:** NetworkManager hosts the 2.4 GHz `dancam-ap` profile; the phone
  reaches the service through the direct AP. See [networking](../docs/design/pi/networking.md).
- **Service:** the statically cross-built Rust binary owns control, media, status,
  events, and camera supervision. See [service runtime](../docs/design/pi/service.md).
- **Provisioning:** Ansible owns onboard system state; deploy artifacts own the
  service binary, unit, and paths. See [provisioning](../docs/design/pi/provisioning.md).

## Structure

```text
raspi/
  ansible/            <- declarative onboard system state
  camera/             <- Picamera2 camera-owner subprocess
  service/            <- Rust crate and committed media fixtures
  scripts/            <- partitioning and hardware-free regressions
  dancam.service      <- deployed systemd unit
  deploy.sh           <- cross-build and deployment path
```

## Commands

Prefer root Justfile recipes over raw Cargo, Ansible, or deploy commands:

- `just raspi-build`, `just raspi-test`, `just raspi-check` -- local build and gates.
- `just raspi-mock`, `just raspi-mock-gc`, `just raspi-mock-lan` -- mock service loops.
- `just raspi-deploy`, `just raspi-deploy-test` -- cross-build/deploy and its regression.
- `just raspi-provision`, `just raspi-provision-check`,
  `just raspi-provision-lint` -- converge or validate onboard state.
- `just raspi-partition-test`, `just raspi-reset-data-test`, `just raspi-hdr-test` --
  hardware-free regressions for their destructive or device-facing tools.

The [Pi setup runbook](../docs/setup/pi-runbook.md) owns flash, SSH, provisioning,
smoke tests, AP switching, deployment, and car-image hardening procedures.

## Dev image vs. car image

The dev image uses writable root and a manual AP toggle but keeps the same `/data`
and `/persist` partition model as the car image. The car image packages that same
durable software with plain read-only root, writable data and OS-state islands, and
the persisted AP. This forced run-mode difference is not permission to build a weak
dev-only feature and harden it later. AP autoconnect remains a separate decision.

## Environment and logs

- Connection overrides are `DANCAM_HOST`, `DANCAM_SSH_KEY`, and
  `DANCAM_HOME_WIFI`.
- Deploy bounds are `DANCAM_STATUS_TIMEOUT` and
  `DANCAM_RECORDING_READINESS_TIMEOUT`.
- Service configuration is `DANCAM_BIND`, `DANCAM_BACKEND`, `DANCAM_REC_DIR`,
  `DANCAM_REQUIRE_REC_MOUNT`, and `DANCAM_GC_FLOOR_BYTES`. The deployed unit uses
  `[::]:8080`, the camera backend, `/data/rec`, and the `/data` mount witness.
- `journalctl -u dancam -f` follows the service; `journalctl -b -1 -u dancam`
  reads the previous boot. Grep `ring_gc_outcome` for GC decisions and an
  `x-request-id` for request correlation.
- `RUST_LOG=dancam=debug` includes emitted SSE events; `dancam=trace` also includes
  heartbeats. The filter accepts `target=level`, not span or field directives.

## Design pages

- [Recording](../docs/design/pi/recording.md) -- camera capture, encode, focus,
  segment format, recorder state, supervision, and command lifecycle.
- [Storage](../docs/design/pi/storage.md) -- segment identity, time derivation,
  startup scrub, deletion, and ring GC.
- [OS image, power, and recovery](../docs/design/pi/os-image.md) -- power topology,
  partitions, mounts, writable state, card policy, watchdog, and persistent logs.
- [Networking](../docs/design/pi/networking.md) -- Wi-Fi topology, AP profile,
  gateway, mDNS, and safe switching.
- [Provisioning](../docs/design/pi/provisioning.md) -- Ansible ownership,
  convergence, machine config, service identity, partitioning, and operator boundary.
- [Service runtime and request tracing](../docs/design/pi/service.md) -- Rust runtime,
  cross-build, deploy model, request IDs, log filtering, and log access.
- [Operational telemetry and readiness](../docs/design/pi/telemetry.md) -- status,
  readiness, filesystem observation, capacity telemetry, and deploy checks.
- [Transport boundary](../docs/design/boundary/transport.md) -- routes, HTTP and SSE
  framing, preview, clip pulls, Wi-Fi pinning, and link trust.
