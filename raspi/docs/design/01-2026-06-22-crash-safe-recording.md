# ADR: Crash-safe recording on the camera unit

- **Status:** Accepted
- **Date:** 2026-06-22
- **Owner:** raspi
- **Related:** root `AGENTS.md` (cross-cutting principle "Recording must survive
  abrupt power loss")

> **Note (2026-06-22):** This ADR's **live-preview transport** language -- that the
> same TS segments feed the iPhone live preview via HLS -- is **superseded by**
> `02-2026-06-22-app-pi-transport-and-api.md`, which selects **MJPEG from the camera's
> lores stream** for live preview (the single H.264 encoder is committed to the 1080p30
> recording, and low-bitrate H.264 smears the low-light detail the preview exists to
> assess). Everything else here stands unchanged: the `.ts` recording format/container,
> the crash-safety layers, and "HLS for clip pull/playback, remux to MP4 only for
> export/share" (which the transport ADR realizes). Append-only per the ADR convention.

> **Note (2026-06-23):** The **supercapacitor / clean-shutdown** path in Layer 3 and
> "Software behavior" (watch a power-good signal; run a clean `shutdown` on power loss)
> is **resolved and dropped** by `04-2026-06-23-power-source-and-shutdown.md`. The v1
> power topology is a **switched USB accessory source** that dies with the car and
> exposes no power-fail signal, so abrupt power loss is the design assumption and there
> is no clean-shutdown path. The residual FTL risk the supercap would have covered is
> handled by the PLP-rated card (Layer 3). The `.ts` format, segmentation, filesystem,
> and PLP-card layers here stand unchanged. Append-only per the ADR convention.

> **Note (2026-06-25):** `07-2026-06-25-picamera2-camera-owner.md` changes the
> implementation that produces recordings, not this ADR's recording-format decision.
> `jet` records with Picamera2's `H264Encoder` feeding `FfmpegOutput` segment muxing,
> with inline headers and MPEG-TS `.ts` segments. The `.ts` / short-segment /
> truncation-tolerant container choice remains unchanged; full crash-safe storage
> hardening (ring buffer, journaled data partition, read-only root, PLP validation) is
> still owned by the later hardening pass.

> **Note (2026-06-26):** The app-side playback/export realization is superseded by
> `app/docs/design/07-2026-06-26-on-device-clip-remux-playback.md`. The phone now remuxes
> pulled TS clips to local passthrough MP4 for both playback and future export/share.
> The `.ts` recording format, short segmentation, inline headers, and crash-safety
> layers in this ADR remain unchanged.

> **Note (2026-06-30):** This ADR is the authoritative home for the **per-clip
> timestamp contract** the recording format implies (previously written down nowhere).
> `recording_ffmpeg_output` (`raspi/camera/camera.py#recording_ffmpeg_output`) applies
> `-bsf:v setts=pts=N*DURATION:dts=N*DURATION`, forcing `PTS == DTS` in coded order, and
> `-reset_timestamps 1` with `-segment_time 30`; combined with one `.ts` segment per
> served clip, each clip's DTS starts near 0, increases strictly frame to frame, and
> never approaches the 2^33 PTS/DTS wrap. Consumers rely on this: the app's
> `H264AccessUnitAssembler` (batch and streaming) and the Pi's `ts_duration` treat a
> non-strictly-increasing DTS or an implausibly large PTS span as *impossible under
> contract*, so a violation can only mean corruption (the crash-safe threat model) or
> an out-of-contract producer. Both handle it by **graceful degradation** -- drop the
> offending access unit / report unknown duration -- never a crash or a whole-clip
> failure. A 33-bit wrap needs no special 2^33 arithmetic: it is just one trigger of the
> generic discontinuity policy. The contract is regression-guarded, not merely
> documented: `raspi/camera/camera.py#run_self_test` asserts the exact ffmpeg arg vector
> (`setts=pts=N*DURATION:dts=N*DURATION`, `-segment_time 30`, `-reset_timestamps 1`), so
> silently dropping any of these fails the self-test. Append-only per the ADR convention.

> **Note (2026-07-04):** `18-2026-07-04-sd-card-layout-and-readonly-root.md`
> supersedes two implementation details in this ADR. Layer 2's read-only root is now a
> **plain read-only ext4 root**, not the `raspi-config` overlayfs path. Layer 3's
> **consumer PLP-card requirement is dropped**: no consumer high-endurance microSD in
> the selected tier makes a power-loss-protection claim, so the project accepts the
> residual FTL risk and mitigates it with recoverable partitions, a reformat-friendly
> `/data`, card-as-consumable operations, and prompt incident pull. The Layer 2
> `fsync()` requirement remains correct; `dune` stage 2 implements segment-close
> durability in the camera owner and mock writer. Append-only per the ADR convention.

> **Note (2026-07-08):** The "playable up to the cut" promise failed in a field power
> cut: the in-flight segment was left as a stamped 0-byte file even though the
> dirty-writeback clamps from the `/data` hardening pass were verified live on the Pi.
> `19-2026-07-08-inflight-segment-durability-and-boot-scrub.md` restores the promise by
> adding periodic in-flight `fdatasync` and a witness-first boot scrub for
> unrecoverable zero-byte leftovers. Append-only per the ADR convention.

## Context

The camera unit is powered from the car. When the engine goes off, power is cut
**without warning, mid-write.** A dashcam that corrupts its footage -- or worse,
bricks its OS -- on every shutdown is useless. So corruption resistance is a
first-class requirement, not a nice-to-have.

There are three distinct failure modes when power is lost during a write, and they
are commonly conflated. They need different fixes:

1. **The in-flight file.** The clip being written loses its tail, or its container
   index never gets finalized.
2. **The filesystem.** Filesystem metadata was mid-update. This can orphan files,
   corrupt the directory, or -- if it hits the OS root partition -- prevent the unit
   from booting at all (a "dead dashcam").
3. **The SD card's own controller.** The card's Flash Translation Layer (FTL) is
   constantly rewriting its internal mapping tables (wear-leveling, garbage
   collection) *below* the OS. Power loss mid program/erase can corrupt data that
   was *already safely written*, or brick the card. **Software cannot make a single
   flash write atomic** -- this layer is invisible to the filesystem.

A common mistake is to fix only #1 (pick a "crash-proof video format") and assume
the problem is solved. #2 is the more dangerous failure (it can brick the unit), and
#3 is the part no software can fully solve.

Constraints from the platform (see `raspi/AGENTS.md`): Raspberry Pi Zero 2 W,
512 MB RAM, 1080p30 H.264 hardware encode, footage stored on microSD, no RTC, and a
hot-car environment that stresses the card.

## Decision

Defend in all three layers. The software layers are free and prevent the
catastrophic failures; the hardware layer covers the residual risk software cannot.

### Layer 1 -- crash-tolerant format and segmentation

- Record in **short segments** (target 30-60 s per file) rather than one long file.
- Use **MPEG-TS** (`.ts`) as the recording container. It is truncation-tolerant
  (a power cut can sever it at any byte and it still plays up to the cut) **and** it
  carries timing (PTS/DTS) and is the native HLS segment format on iOS. The same
  segments therefore feed both the iPhone live preview (HLS) and clip playback (wrap
  in a local HLS playlist) with minimal glue. The iPhone playback path -- HLS for
  preview and pull, remux to MP4 only for export/share -- is owned by the app<->Pi
  transport design.
- **Do not record raw H.264 elementary stream** (`.h264`), even though it is equally
  truncation-tolerant and is `rpicam-vid`'s default output: it has no container and
  no timestamps, so AVFoundation cannot play it without a remux *and* fabricated PTS
  values. Fabricating timing is especially nasty here -- variable framerate plus the
  Pi's lack of an RTC give no reliable clock to reconstruct it from. The ~2% size
  saving over TS is not worth it.
- **Do not record straight to MP4/MOV** as the recording format -- MP4 writes its
  index (`moov` atom) at the end, so a power cut loses the *entire* clip. (MP4 is
  produced later as an export format, off the hot path -- never as the live format.)
- Emit inline stream headers (SPS/PPS at every keyframe, e.g. `rpicam-vid --inline`)
  so each segment is independently decodable.
- A power cut then costs at most the final partial segment, and that segment is
  usually still playable up to the cut.

### Layer 2 -- filesystem and OS

- **Read-only root filesystem** (overlayfs; Raspberry Pi OS supports this via
  `raspi-config`). If root is never written, power loss **cannot corrupt the OS, so
  the unit always boots.** This is the single most important anti-bricking measure.
- **Separate, journaled recording partition** (ext4, or F2FS for flash-friendliness).
  Journaling recovers the filesystem to a consistent, mountable state on next boot.
  **Do not use FAT/exFAT** for recordings -- no journaling, fragile on power loss.
  (We do not need FAT compatibility: the card is read by the phone over Wi-Fi, not
  plugged into a PC.)
- Flush aggressively: `fsync()` at each segment close, mount with frequent commits
  (e.g. `noatime,commit=5`), and keep the dirty-page window small. The goal is that
  little unwritten data is ever in RAM.

### Layer 3 -- the SD card hardware

- Use an **industrial / high-endurance microSD with power-loss protection (PLP)** --
  on-card capacitors that flush the controller's buffers on power loss. This is the
  hardware fix for the FTL risk, and it must also be rated for the hot-car
  environment (85 C).
- **Optionally** add a **supercapacitor module** (e.g. Juice4Halt HV, 7-28 V input,
  -40/+85 C, ~60 s hold-up) for a clean power-down. This protects the FTL by giving
  the card a graceful shutdown and lets us finalize the current segment instead of
  truncating it. **No lithium batteries** -- fire/swelling risk in a hot car.

### Software behavior

- Auto-start recording on boot (ignition-on -> recording). 
- Watch a power-good signal (from the supercap module's GPIO, or a divider on a GPIO)
  and run a clean `shutdown` on power loss if hold-up power is present.
- Run a ring buffer: delete oldest segments as the card fills, but **never delete
  incident-locked segments** (the app locks an incident; see `app/AGENTS.md`).

## Consequences

- A power cut results in: OS always boots (read-only root), filesystem recovers
  automatically (journaling), at most the last ~30-60 s segment is lost, and the
  card's FTL is protected (PLP card, and clean shutdown if a supercap is fitted).
  This is a battery-free design that matches how commercial dashcams survive constant
  power cuts.
- **The supercap becomes optional, not mandatory.** With Layers 1-2 plus a PLP card,
  the supercap is belt-and-suspenders: it buys clean finalization of the current
  segment and extra FTL safety. Whether to fit it is a cost/effort call, deferred to
  a build-time decision; it is not required for correctness.
- Read-only root adds operational friction: configuration changes require toggling
  the overlay off/on, and logs must go to the writable partition (or be disabled).
  Document this in the raspi build/run notes.
- Recordings are `.ts`, not `.mp4`. iOS plays TS through **HLS** (a local `.m3u8`
  referencing the segments), not as a standalone file -- so the app serves and plays
  footage via HLS, and remuxes to MP4 only for export/share (Photos, AirDrop). That
  TS->MP4 remux is clean because the timestamps already exist in the stream.

## Alternatives considered

- **Supercap-only (no software hardening).** Rejected as the primary strategy: a
  supercap reduces how often a bad cut happens but does not eliminate it (the cut can
  still land mid-write before shutdown completes), and it does nothing to protect the
  OS root. Software hardening is free and addresses the bricking risk directly.
- **"Crash-proof format" only.** Rejected. Fixing only the in-flight file leaves the
  filesystem and OS exposed -- the dangerous failures. Format is necessary but not
  sufficient.
- **Raw H.264 elementary stream (`.h264`).** Equally truncation-tolerant and the
  simplest to produce on the Pi, but rejected: no container and no timestamps, so
  AVFoundation cannot play it without a remux plus fabricated PTS values (and there
  is no RTC to reconstruct timing from). TS's embedded timing and HLS-native iOS
  playback outweigh its ~2% packet overhead. See the Layer 1 decision.
- **Record straight to MP4 with a periodic-finalize trick (fragmented MP4).** fMP4 is
  more resilient than plain MP4, but TS is simpler, strictly more truncation-tolerant,
  and avoids muxer edge cases on a 512 MB board. Revisit only if MP4-native playback
  proves necessary on the hot path.
- **FAT recording partition + offline "repair" tool** (what many cheap dashcams do).
  Rejected: fragile, and we have no FAT-compatibility requirement.
