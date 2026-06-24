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

## Roadmap

The build plan lives in **[`docs/roadmap.md`](docs/roadmap.md)** -- it's kept out of
this file so AGENTS.md stays lean (this file is loaded into every agent context).
That doc holds the **breadth-first swoops** (thin end-to-end Pi -> Wi-Fi -> app
slices, deepened on later passes; codenamed `oak`, `fox`, ... so they reorder without
renumbering), the default order and mock-Pi / real-Pi tracks, and an **Icebox** of
parked someday-maybe swoops. Read it before deciding what to build next.

## Hardware (tentative)

Raspberry Pi Zero 2 W + Arducam IMX708 Autofocus Wide camera. The full spec, part
links, and prices live in [`raspi/AGENTS.md`](raspi/AGENTS.md). Hardware may change as
concrete implementation starts.

## Development environment

Dan develops on an **M1 (Apple Silicon) MacBook Pro** running macOS. This is the
only dev workstation, and it shapes what's easy:

- **iPhone app:** built and run natively in Xcode on this Mac (an Apple Silicon Mac
  is required for current iOS toolchains and the simulator).
- **Raspberry Pi:** the microSD is flashed from the laptop. Raspberry Pi Imager
  runs natively on Apple Silicon; with a USB SD card reader, headless setup
  (Wi-Fi creds, SSH, hostname) is done via the Imager's OS-customization step, so
  the Pi can come up first-boot without a monitor/keyboard. Then iterate over SSH
  on the same Wi-Fi. (`dd` works too, but Imager is the default.)

## Repository layout

```
dancam/
  AGENTS.md              <- you are here (whole-system overview + conventions)
  docs/roadmap.md        <- build plan: breadth-first swoops + Icebox
  app/                   <- iPhone app (Swift / SwiftUI). Has its own AGENTS.md.
    docs/design/         <- app-side ADRs (YYYY-MM-DD-{slug}.md)
  raspi/                 <- camera-unit software (Raspberry Pi). Has its own AGENTS.md.
    docs/design/         <- raspi-side ADRs (YYYY-MM-DD-{slug}.md)
```

When you work inside `app/` or `raspi/`, read that folder's AGENTS.md first
([`app/AGENTS.md`](app/AGENTS.md), [`raspi/AGENTS.md`](raspi/AGENTS.md)) -- it carries
the details and constraints specific to that side. Each side's file links back here and
to its sibling, so the three stay navigable (and de-duped: root owns the cross-cutting
decisions, each side owns its own).

## Architecture at a glance

```
[ Camera unit (raspi) ]                         [ iPhone (app) ]
  camera -> encode -> crash-safe ring buffer       live preview (when stopped/safe)
  on microSD (source of truth)                     browse + pull selected clips
        |                                           incident review
        |  Wi-Fi (Pi runs an access point)          settings / control
        +----------- 2.4 GHz link ----------------> CarPlay surface (voice/status/control)
```

Key data-flow rule: the microSD is the system of record; Wi-Fi carries only preview
and selective pull (the "SD is the source of truth" principle below).

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
  Request/response control plus low-res preview and on-demand clip pull; never on the
  recording path. The transport mechanics (MJPEG preview, resumable ranged pull, SSE
  events) live in the transport ADR.
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
- **Commits:** small and logical; one coherent change per commit. Follow
  [Conventional Commits](https://www.conventionalcommits.org/) -- a `type(scope):
  summary` subject (types: `feat`, `fix`, `docs`, `refactor`, `chore`; scope optional,
  e.g. `app` / `raspi`), with a body when the why isn't obvious. Example:
  `docs(raspi): add power-source-and-shutdown ADR`.
- **Source of truth for context:** `AGENTS.md` files. `CLAUDE.md` exists only to
  import `AGENTS.md` for the Claude Code harness.
