# dancam

A do-it-yourself dashcam system built around an iPhone. Three parts work together:

1. **Camera unit** (`raspi/`) -- a Raspberry Pi + wide-angle camera that records
   continuously to its own microSD card. It is the recorder and the source of
   truth for footage.
2. **iPhone app** (`app/`) -- the primary UI and "brains." Connects to the camera
   unit over Wi-Fi to preview, browse, and pull clips, manage settings, and handle
   incidents. The system may require the iPhone to be useful.
3. **CarPlay integration** -- a layer inside the iPhone app that exposes a small,
   safe surface to the car screen: voice control, status, and start/stop. (It is
   part of the app target; it does not live in a separate folder.)

The project is **iPhone-only** and the app owns the product experience. The Pi is
deliberately dumb: capture, encode, store safely, and serve footage on request.

Dan (the software engineer) wants to develop this dashcam for fun and see if he
can make a good-enough dashcam + iphone + carplay implementation. Once working
in the real world in his car, he might consider upgrades (better resolution,
better hardware, better camera, etc).

## Status

Planning / greenfield. Most of this repo is currently design documentation. There
is no build yet. Decisions are captured as ADRs (see "Design decisions" below)
before code lands.

## Roadmap (breadth-first swoops)

We build this like sculpting clay, not stacking bricks: **breadth-first swoops**.
Each swoop is a thin slice across the whole pipeline (Pi -> Wi-Fi -> app) that
ends in something we can actually see or use. Later swoops deepen earlier ones
rather than bolting on isolated parts. The deep ADRs (storage ring buffer,
crash-safe recording) are the *north star* for the deepening passes -- not the
spec for the early swoops. Start dumb, get footage moving, harden later.

This list is **loose and reorderable.** Order is a default, not a contract; near-
term swoops are detailed, later ones are one-liners we'll flesh out when we reach
them. Each swoop carries a short **codename** (a stable handle) instead of a number,
so swoops can be reordered or inserted without renumbering -- list position, not the
name, conveys the default order. Two tracks run in parallel: a **mock Pi** (a small
fake local server with canned status + sample frames/clips) so app work never blocks
on hardware, and the **real Pi** firmware. Each app swoop should pass against the
mock first.

- [ ] **Swoop `oak` -- Bring-up + mock.** Real Pi: flash Raspberry Pi OS (64-bit) with
      read-only root, bring up the Wi-Fi AP (hostapd + dnsmasq), get the camera
      capturing, and serve a minimal `GET /v1/health` over HTTP. App: join the AP
      and get a 200 back. Stand up the **mock Pi** server in parallel. (Skip the
      hardware half fast if it's already done.) *Foundation for everything below.*
- [ ] **Swoop `fox` -- Live preview on iPhone.** Pi serves `GET /v1/preview/live.mjpeg`
      (MJPEG from the libcamera lores stream, never the H.264 encoder). App joins
      the AP, opens a pinned `NWConnection`, parses `multipart/x-mixed-replace`,
      and shows the live view on screen. *This is the first "it works!" moment.*
      Preview here need not run while recording (sidesteps the headline spike);
      *spike: confirm `NWConnection` Wi-Fi pinning + no-internet-AP / captive-probe
      handling behaves.*
- [ ] **Swoop `jet` -- Recording control + live status.** Start/stop recording buttons
      in the app (`POST /v1/recording/start|stop`); a status readout (recording
      on/off, storage left, temps) that updates as it changes (SSE
      `GET /v1/events`). *Spike: can MJPEG preview run concurrently with the
      1080p30 H.264 recording? If not, preview falls back to "when stopped."*
- [ ] **Swoop `kelp` -- SD card management.** Pi detects the card and surfaces issues
      (missing / unformatted / wrong filesystem); auto-format on first insert;
      format-from-app with a double-confirm (`POST /v1/storage/format`).
- [ ] **Swoop `lime` -- Watch recorded clips.** Browse a clip list (`GET /v1/clips`),
      pull one with resumable `Range` requests, play it via a local HLS playlist +
      AVPlayer on a loopback server. *The chunky one; now that recording exists, it
      pays off. Spike: 2.4 GHz in-car throughput / pull times.*
- [ ] **Swoop `moss` -- Time provenance.** `POST /v1/time` at handshake (the Pi has no
      RTC); "time unverified" UI until sync; timestamps on clips.
- [ ] **Swoop `nova` -- Incident lock (manual).** A "save this moment" button: Pi
      force-finalizes the open segment and protects the window. Start with a dumb
      hardlink lock; *deepen toward the storage ADR (idempotency, pre-sync holds)
      later.*
- [ ] **Swoop `opal` -- Connection robustness.** Persistent auto-rejoin
      (`NEHotspotConfiguration`, `joinOnce = false`); offline detection via missed
      heartbeats -> alert; back-off reconnect; resume pulls across drops.
- [ ] **Swoop `pike` -- CarPlay voice incident-mark.** App Intents "save that clip,"
      hands-free, with queue-and-flush on the cold path. *No entitlement needed --
      the highest-value, lowest-risk CarPlay piece.*
- [ ] **Swoop `reef` -- CarPlay auto start/stop** on CarPlay connect/disconnect.
- [ ] **Swoop `sage` -- CarPlay status panel** (Driving Task template). *Gated on the
      Apple entitlement; the product must be useful without it.*
- [ ] **Swoop `tide` -- Export / share.** TS -> MP4 passthrough remux to Photos /
      AirDrop (export-only, off the playback path).
- [ ] **Swoop `vine` -- Power-loss hardening for real.** Power-good GPIO + clean
      shutdown; supercap go/no-go; validate crash recovery in the actual car.
- [ ] **Later / deepening passes.** Thermal-behavior policy (what recording does at
      the sensor's 50 C limit); HDR tuning; auth hardening (token, then pinned-cert
      TLS); GPS time source; parked / sentry mode (gated on a future constant-power
      topology -- v1 power is switched / drive-only, see the power-source ADR).

## Hardware (tenative)

The hardware may change for the v1 as we start concrete implementation, but this
is the plan so far.

- [Raspberry Pi Zero 2 W (2021)](https://www.amazon.com/gp/product/B09LH5SBPS)
  (60 USD)
- [Arducam for Raspberry Pi Camera Module 3 Wide](https://www.amazon.com/gp/product/B0C5D97DRJ) (30 USD): 120°(D) IMX708 Autofocus Pi Camera V3, 15cm 15-22 Pin FFC Cable

## Repository layout

```
dancam/
  AGENTS.md              <- you are here (whole-system overview + conventions)
  app/                   <- iPhone app (Swift / SwiftUI). Has its own AGENTS.md.
    docs/design/         <- app-side ADRs (YYYY-MM-DD-{slug}.md)
  raspi/                 <- camera-unit software (Raspberry Pi). Has its own AGENTS.md.
    docs/design/         <- raspi-side ADRs (YYYY-MM-DD-{slug}.md)
```

When you work inside `app/` or `raspi/`, read that folder's `AGENTS.md` first --
it carries the details and constraints specific to that side.

## Architecture at a glance

```
[ Camera unit (raspi) ]                         [ iPhone (app) ]
  camera -> encode -> crash-safe ring buffer       live preview (when stopped/safe)
  on microSD (source of truth)                     browse + pull selected clips
        |                                           incident review
        |  Wi-Fi (Pi runs an access point)          settings / control
        +----------- 2.4 GHz link ----------------> CarPlay surface (voice/status/control)
```

Key data-flow rule: **the microSD is the system of record; Wi-Fi is only for
preview and selective pull.** Footage is never streamed-to-phone-as-primary-storage.

## Cross-cutting principles (the decisions that shape everything)

These are settled at the system level. Side-specific ADRs must not contradict them.

- **SD is the source of truth.** The Pi always records locally. The phone is a
  client that reads footage on demand; a dropped Wi-Fi link must never lose video.
- **Wi-Fi is 2.4 GHz, preview + pull only.** The chosen Pi (Zero 2 W) has no 5 GHz
  radio. Design for a slow, congested link: low-res preview, on-demand clip pull,
  never bulk continuous streaming. See `raspi/AGENTS.md`.
- **CarPlay is a voice + status + control surface, NOT a video viewport.** Third-party
  CarPlay apps cannot draw a live camera feed. The live preview stays on the iPhone
  screen. CarPlay gets: voice incident-marking, auto start/stop, a status panel,
  alerts. See `app/docs/design/2026-06-22-carplay-integration-surface.md`.
- **Recording must survive abrupt power loss.** The car cuts power without warning.
  Corruption resilience is a first-class requirement, solved in layers (format +
  filesystem + card hardware). See `raspi/docs/design/2026-06-22-crash-safe-recording.md`.
- **Thermals are a real constraint, not an afterthought.** The unit lives on a
  windshield in Texas heat. The camera sensor (rated to ~50 C) is the weak link,
  not the Pi board (rated to 70 C). See `raspi/AGENTS.md`.
- **The app<->Pi link is a versioned local API served by the Pi, pinned to Wi-Fi.**
  Control is request/response HTTP; live preview is low-res MJPEG derived from the
  camera's lores stream (never the H.264 recording encoder); clips are pulled
  on-demand with resumable byte ranges. The link is never on the recording path.
  See `raspi/docs/design/2026-06-22-app-pi-transport-and-api.md`.

## Design decisions (ADRs)

Architecture and design decisions are recorded as dated Markdown files under each
side's `docs/design/` directory. This is the project's ADR ("Architecture Decision
Record") system.

**Convention**

- Filename: `docs/design/YYYY-MM-DD-{slug}.md`, dated the day the decision is taken.
- One decision per file. Prefer short, specific slugs (`crash-safe-recording`,
  `carplay-integration-surface`).
- Every ADR has this shape:
  - **Title** (`# ADR: ...`)
  - **Status** -- Proposed | Accepted | Superseded by <file> | Deprecated
  - **Context** -- the forces and constraints in play
  - **Decision** -- what we are doing, stated plainly
  - **Consequences** -- what this makes easy, hard, or risky; follow-ups
  - **Alternatives considered** -- options rejected and why
- ADRs are append-only history. To change a decision, write a new ADR and mark the
  old one `Superseded by ...`; do not silently rewrite the old one.
- System-wide decisions that span both sides are summarized under "Cross-cutting
  principles" above and link to the owning ADR.

To start a new ADR, copy the structure of an existing one in the same folder.

## Conventions

- **Writing style:** plain ASCII. Write `4x` not the times sign, straight quotes,
  `--` not an em dash, `degrees`/`deg` not the degree sign. Applies to docs, code
  comments, and commit messages.
- **Commits:** small and logical; one coherent change per commit. Imperative subject
  line (`Add ...`, `Document ...`), with a body when the why isn't obvious.
- **Source of truth for context:** `AGENTS.md` files. `CLAUDE.md` exists only to
  import `AGENTS.md` for the Claude Code harness.
