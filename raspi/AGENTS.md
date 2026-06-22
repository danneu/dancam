# dancam -- camera unit (Raspberry Pi)

The camera unit is the recorder. Its job is narrow and it should stay that way:
**capture -> encode -> store crash-safely on the microSD -> serve footage to the
phone on request.** It is the source of truth for footage. The iPhone app
(`../app/`) is the UI and brains; the Pi is deliberately dumb.

Read the root `../AGENTS.md` first for the system picture and cross-cutting
principles. This file covers the camera unit specifically.

## Hardware (v1)

- **Board:** Raspberry Pi Zero 2 W.
  - Quad-core Cortex-A53 @ 1 GHz, **512 MB RAM** (tight -- keep the software lean).
  - **Wi-Fi: 2.4 GHz 802.11 b/g/n only. No 5 GHz.** This shapes the whole link
    design (preview + pull only; see below).
  - **Hardware H.264 encode capped at 1080p30.** Plan for 1080p30; no 4K, no HEVC
    encode, and the camera's higher modes (1080p50 etc.) cannot be hardware-encoded.
  - Operating range -20 C to +70 C ambient. **No real-time clock** -- time comes
    from the phone (on connect) and/or a GPS module.
  - 40-pin header is unpopulated from the factory.
- **Camera:** Arducam 12MP IMX708 Autofocus Wide (Camera Module 3 Wide equivalent).
  - 120 deg diagonal FOV, HDR, PDAF autofocus, Sony IMX708, libcamera-native.
  - Ships with a 22-22pin FPC cable that fits the Zero's connector (the official
    Raspberry Pi module's bundled cable does NOT fit the Zero -- ours does).
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

Provisional until captured as ADRs.

- **OS:** Raspberry Pi OS (64-bit), with a **read-only root filesystem** (overlayfs)
  so power loss can never corrupt the OS. Footage goes on a **separate journaled
  partition** (ext4 or F2FS).
- **Capture/encode:** `rpicam-vid` / libcamera (or Picamera2). Output segmented,
  crash-tolerant streams (MPEG-TS or raw H.264 with inline headers).
- **Storage model:** a **ring buffer** of short segments; oldest deleted as the card
  fills; incident-locked segments are exempt from deletion.
- **Access point:** hostapd + dnsmasq (or equivalent) so the phone can connect
  directly with no router.
- **Control + media service:** a small service exposing a control API (start/stop,
  settings, time sync, incident lock) and a media API (list/preview/pull clips) to
  the app.
- **Power-loss safety:** an industrial microSD with power-loss protection (PLP),
  optionally plus a supercapacitor module (e.g. Juice4Halt HV) for clean shutdown.
  No lithium batteries -- they are a fire risk baking in a hot car.

## Structure (planned)

```
raspi/
  AGENTS.md
  docs/design/        <- raspi-side ADRs
  (capture/service/provisioning code to be added)
```

## Build / run

Not yet established. When code lands, document here: how to flash/provision an SD
image, how to enable the read-only overlay and the recording partition, how to run
the capture + service locally, and how to point the app at the unit.

## Design decisions (ADRs)

See the root `AGENTS.md` for the ADR convention. Raspi-side ADRs live in
`docs/design/`. Current:

- `2026-06-22-crash-safe-recording.md` -- how recording survives abrupt power loss
  (format + filesystem + card hardware layers).
