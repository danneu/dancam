# ADR: Power source and shutdown behavior

- **Status:** Proposed
- **Date:** 2026-06-23
- **Owner:** raspi
- **Related:** root `AGENTS.md` (cross-cutting principles "Recording must survive
  abrupt power loss" and the thermals principle);
  `01-2026-06-22-crash-safe-recording.md` (the crash-safety layers this ADR leans on
  entirely; this ADR appends a dated note there resolving the supercap /
  clean-shutdown question); [Pi storage](../../../docs/design/pi/storage.md)
  (the storage model that already assumes abrupt power loss)

## Context

The camera unit is powered from the car. How it is wired determines two things the
rest of the design depends on: whether power loss comes with any **warning** (which
decides whether a clean shutdown is even possible), and whether the unit has power
**while parked** (which decides whether sentry/parked recording is on the table).
The crash-safe recording ADR explicitly deferred the supercapacitor / clean-shutdown
question to "a build-time decision." This ADR makes it.

Constraints and the chosen environment:

- The vehicle is a 2019 Toyota C-HR. Two candidate power sources, **both USB with an
  already-regulated 5V output**:
  - a 12V accessory socket ("cigarette lighter") with a USB adapter, or
  - the car's **18W windshield / mirror-area USB tap** (near the Toyota Safety Sense
    2.0 module), which gives a short, hidden cable run to a windshield-mounted unit.
- **Both sources are switched: they die when the car is turned off.** (Confirmed for
  the C-HR 18W tap.) Power is present only while driving, and it is cut **without
  warning** at engine-off.
- The board is a Raspberry Pi Zero 2 W (micro-USB 5V in), drawing roughly 3-5W with
  the camera and Wi-Fi AP active -- a small fraction of an 18W source.
- No lithium battery in the unit (fire / swelling risk in a hot car -- a standing
  project rule).

The open question this ADR closes: **which power source, and do we engineer for a
graceful shutdown or accept abrupt loss and lean entirely on crash-proofing?**

## Decision

**Power the unit from a switched USB accessory source (either the 12V-socket adapter
or the C-HR 18W windshield tap), and design for abrupt, unsignaled power loss. Do not
build a clean-shutdown path.**

1. **Source: switched USB, 5V regulated.** Either candidate works; the windshield tap
   is preferred for cable routing to a mirror-mounted unit. Because the source outputs
   regulated 5V, the unit needs **no buck converter, no fuse-box wiring, and no
   automotive-transient handling** on its input -- the USB source absorbs the 12V
   rail's noise, crank dips, and spikes. Use a quality 5V cable and a source rated
   >= 2A to avoid undervoltage throttling (the 18W tap is far past this; the failure
   mode is a thin cable, not the source).

2. **No clean shutdown; abrupt loss is the design assumption.** A switched USB source
   provides no power-fail signal to act on, so there is nothing to detect and no
   shutdown daemon to run. Recording integrity rests entirely on the crash-safe
   recording ADR's layers: short MPEG-TS segments, inline SPS/PPS, `fsync()` at
   segment close, read-only root filesystem, a separate journaled recording partition,
   and a high-endurance / PLP microSD. A power cut costs at most the final partial
   segment, and the OS always reboots.

3. **No supercapacitor / power-good GPIO.** The supercap option the crash-safe ADR
   left open is **dropped for this topology.** Without a power-fail signal the Pi
   cannot use hold-up time to finalize cleanly anyway; a supercap would only briefly
   delay the cut. The residual FTL risk it would have covered is instead handled by
   the PLP-rated card (crash-safe ADR Layer 3). A dated note is appended to the
   crash-safe ADR recording this resolution.

4. **No parked / sentry mode in this topology.** Switched power means the unit is
   unpowered while parked, so continuous parked recording is physically impossible
   here. Accepted for v1.

## Consequences

- **Simplest possible power hardware.** No regulator, no fuse tap, no shutdown wiring,
  no battery -- just a USB cable from a switched source. The install is reversible and
  requires no work on the car's electrics.
- **The crash-safe design now carries the entire burden, by design.** This is
  acceptable because that ADR was built for exactly this assumption ("power is cut
  without warning, mid-write"). Abrupt loss is the expected event, not an edge case;
  the storage ADR's reboot-crossing idempotency and torn-segment recovery already
  assume it.
- **A thermal win, not just a power simplification.** Switched power means the Pi is
  never running in a closed, parked cabin for hours -- it is on only while driving
  (car moving, often with A/C). This sidesteps the worst case for the camera sensor's
  50 C limit (the system's thermal weak link). Parked thermals drop out of scope along
  with parked recording.
- **Crank brownout may reboot the Pi.** The voltage dip at engine start can
  power-cycle the unit. Read-only root makes this a clean reboot costing only a few
  seconds of footage; auto-record-on-boot brings recording back with no user action.
- **Undervoltage is the one real failure mode to watch.** A cheap cable can cause
  throttling or instability that looks like a software bug. Treat persistent
  under-voltage warnings as a cable/source problem first, and document the known-good
  cable in the build notes.
- **Sentry mode is gated behind a different power topology.** Adding it later would
  require a *constant* (always-on) source -- a fuse-box hardwire to a constant fuse
  with a low-voltage battery cutoff, plus revisiting parked thermals. That is a
  deliberate future decision, not a small toggle, and is explicitly out of v1.

## Alternatives considered

- **Hardwire to a switched ACC fuse with a 12V->5V buck converter.** A tidier
  permanent install (no visible cable), but more work (fuse tap, ground,
  automotive-rated regulator, transient protection) for the *same behavior* as the
  switched USB source -- power only while driving, abrupt cut. The USB source gives
  identical semantics with zero car wiring. Rejected for v1 as effort with no
  behavioral gain.
- **Hardwire to a constant (always-on) fuse, for sentry mode.** Enables parked
  recording, but requires a low-voltage cutoff to protect the car battery, a buck
  converter, and -- the dealbreaker for v1 -- it puts the Pi and camera in a parked,
  sun-baked cabin, the exact thermal worst case. Deferred along with sentry mode
  itself.
- **Supercapacitor module (e.g. Juice4Halt) for clean shutdown.** The crash-safe
  ADR's optional Layer 3 extra. Rejected here because a switched USB source gives no
  power-fail signal to trigger a clean finalize, so the supercap's main benefit is
  unreachable; its residual FTL protection is covered by the PLP card. Revisit only if
  a future topology adds a power-good signal.
- **OBD-II port power.** Removable, but commonly always-on (battery drain) and not a
  clean fit for a switched, drive-only design. The accessory USB sources are simpler
  and switched by default.
- **Onboard battery / UPS pack.** Rejected by standing project rule: lithium chemistry
  in a hot car is a fire / swelling risk, and it would re-introduce parked thermals.
