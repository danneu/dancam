# dancam

A do-it-yourself dashcam system built around an iPhone. Three parts work together:

1. **Camera unit** (`raspi/`) -- a Raspberry Pi + wide-angle camera that records
   continuously to its own microSD card.
2. **iPhone app** (`app/`) -- the primary UI and "brains." Connects to the camera
   unit over Wi-Fi to preview, browse, and pull clips, manage settings, and handle
   incidents.
3. **CarPlay integration** -- a layer inside the iPhone app that exposes a small,
   safe surface to the car screen: voice control, status, and start/stop. (It is
   part of the app target; it does not live in a separate folder.)

The project is **iPhone-only** and the app owns the product experience. The Pi is
deliberately dumb: capture, encode, store safely, and serve footage on request.

## Working stance: take the ideal solution, not the prescribed one

Early implementation: most of this repo is design documentation, but `raspi/service/`
is the first buildable code. Docs/notes/ADRs were written ahead of real hardware --
best guesses, not commitments. When planning or implementation surfaces a better approach, take it;
never stay trapped in a solution we spitballed before we had evidence. On every
pivot, update the record in the same change (amend or supersede the ADR -- see
"Design decisions"); a pivot that isn't written down is the next trap. The
"Cross-cutting principles" below are the firmest layer (hard physical constraints) --
revisit even those if reality disagrees, but at a higher, explicit bar.

## Roadmap

The build plan lives in **[`docs/roadmap.md`](docs/roadmap.md)**: the **breadth-first
swoops** (thin end-to-end Pi -> Wi-Fi -> app slices, deepened on later passes;
codenamed `oak`, `fox`, ... so they reorder without renumbering), the default order
and mock-Pi / real-Pi tracks, and an **Icebox** of parked someday-maybe swoops. Read
it before deciding what to build next.

## Hardware (tentative)

Pi Zero 2 W + Arducam IMX708 Autofocus Wide camera; full spec, part links, and prices
in [`raspi/AGENTS.md`](raspi/AGENTS.md). May change as concrete implementation starts.

## Development environment

Dan develops on an **M1 (Apple Silicon) MacBook Pro** running macOS -- the only dev
workstation.

- **iPhone app:** built and run natively in Xcode on this Mac (an Apple Silicon Mac
  is required for current iOS toolchains and the simulator).
- **Raspberry Pi:** flash the microSD from the laptop with Raspberry Pi Imager 2.0.10+
  (headless OS-customization sets Wi-Fi/SSH/hostname for first-boot without a monitor,
  then iterate over SSH); see [`README.md`](README.md) for the full runbook.

## Repository layout

```
dancam/
  AGENTS.md              <- you are here (whole-system overview + conventions)
  Justfile               <- common build/test/run tasks; prefer these over raw commands
  docs/roadmap.md        <- build plan: breadth-first swoops + Icebox
  app/                   <- iPhone app (Swift / UIKit). Has its own AGENTS.md.
    docs/design/         <- app-side ADRs ({seq}-YYYY-MM-DD-{slug}.md)
  raspi/                 <- camera-unit software (Raspberry Pi). Has its own AGENTS.md.
    service/             <- Rust control/media service crate
    docs/design/         <- raspi-side ADRs ({seq}-YYYY-MM-DD-{slug}.md)
  references/            <- third-party source clones (git-ignored; `just fetch-references`)
```

When you work inside `app/` or `raspi/`, read that folder's AGENTS.md first
([`app/AGENTS.md`](app/AGENTS.md), [`raspi/AGENTS.md`](raspi/AGENTS.md)) -- it carries
the details and constraints specific to that side. Each side's file links back here and
to its sibling, so the three stay navigable (and de-duped: root owns the cross-cutting
decisions, each side owns its own).

## References

`references/` holds read-only clones of upstream source we build against, so we target
the exact API. Git-ignored; seed or refresh with `just fetch-references`. Versions are
pinned in `scripts/fetch-references.sh` to match what the Pi runs; run
`just references-pi-version` to confirm the Pi's installed version before setting or
bumping a pin.

- **picamera2** (`references/picamera2/`) -- Raspberry Pi camera stack imported by the Pi
  camera process (`raspi/camera/camera.py`). Pinned to the `python3-picamera2` version on
  Raspberry Pi OS Trixie. Upstream: https://github.com/raspberrypi/picamera2

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
  alerts. See `app/docs/design/01-2026-06-22-carplay-integration-surface.md`.
- **Recording must survive abrupt power loss.** The car cuts power without warning.
  Corruption resilience is a first-class requirement, solved in layers (format +
  filesystem + card hardware). See `raspi/docs/design/01-2026-06-22-crash-safe-recording.md`.
- **Thermals are a real constraint, not an afterthought.** The unit lives on a
  windshield in Texas heat. The camera sensor (rated to ~50 C) is the weak link,
  not the Pi board (rated to 70 C). See `raspi/AGENTS.md`.
- **The app<->Pi link is a versioned local API served by the Pi, pinned to Wi-Fi.**
  Request/response control plus low-res preview and on-demand clip pull; never on the
  recording path. The transport mechanics (MJPEG preview, resumable ranged pull, SSE
  events) live in the transport ADR.
  See `raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md`.

## Design decisions (ADRs)

Architecture and design decisions are recorded as sequence-prefixed, dated Markdown
files under each side's `docs/design/` directory. This is the project's ADR
("Architecture Decision Record") system.

**Convention**

- Filename: `docs/design/{seq}-YYYY-MM-DD-{slug}.md`, date = day the decision is
  taken, slug short and specific (`crash-safe-recording`). `{seq}` = two-digit
  per-side sequence (each side starts at `01`, new ADR = highest in that folder + 1);
  it orders ADRs and breaks ties on same-day decisions. Enforced by `just adr-check`.
- One decision per file. Shape: Title (`# ADR: ...`) / Status (Proposed | Accepted |
  Superseded by <file> | Deprecated) / Context / Decision / Consequences /
  Alternatives considered.
- Append-only history: to change a decision, write a new ADR and mark the old one
  `Superseded by ...`; never silently rewrite it.
- System-wide decisions that span both sides are summarized under "Cross-cutting
  principles" above and link to the owning ADR.

## Conventions

- **Writing style:** plain ASCII. Write `4x` not the times sign, straight quotes,
  `--` not an em dash, `degrees`/`deg` not the degree sign. Applies to docs, code
  comments, and commit messages.
- **References in docs/plans:** never cite line numbers -- they drift the moment a
  file changes and silently rot. Point at a stable anchor instead:
  `path/to/file#identifier`, where the identifier is a symbol or heading that can be
  searched for verbatim -- e.g. `raspi/service/src/main.rs#fn run_server`,
  `app/AGENTS.md#Conventions`, `docs/roadmap.md#Icebox`. When no named anchor exists,
  quote a short unique snippet rather than a line number. (Clickable `file:line` in
  chat is fine -- it's transient; this rule is about durable docs, plans, and ADRs.)
- **Tasks:** use the root `Justfile` for common repo commands when one exists. Run
  `just --list` to discover tasks, and prefer those tasks over spelling out raw
  `cargo`/Xcode/etc. commands unless you are deliberately testing the lower-level
  command.
- **Raspberry Pi setup runbook:** [`README.md`](README.md) is the reproducible
  fresh-Pi setup guide. Any change that affects real Pi provisioning or onboard
  state -- packages, `/boot/firmware/config.txt`, Avahi, NetworkManager profiles,
  systemd units, deploy paths, AP/mDNS behavior, or other config files -- must
  update the README in the same change with exact commands and verification steps.
- **Commits:** small and logical; one coherent change per commit. Follow
  [Conventional Commits](https://www.conventionalcommits.org/) -- a `type(scope):
  summary` subject (types: `feat`, `fix`, `docs`, `refactor`, `chore`; scope optional,
  e.g. `app` / `raspi`), with a body when the why isn't obvious. Example:
  `docs(raspi): add power-source-and-shutdown ADR`.
- **Source of truth for context:** `AGENTS.md` files. `CLAUDE.md` exists only to
  import `AGENTS.md` for the Claude Code harness.
