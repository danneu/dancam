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

**Optimize for the ideal solution, full stop.** There are no users and no shipped
releases, so there is nothing to be backwards-compatible with: never preserve an old
shape, keep a deprecated path, or add a compatibility shim "just in case." Delete and
replace rather than layer around. Code churn is not a cost we weigh -- rename, move,
restructure, and rewrite freely whenever it gets us to the cleaner end state. If a
change is the right one, the size of the diff or the number of touched files is never
a reason to hold back. The only bar is: is this the best design we can see right now?

**Build each feature durable, not transient.** When you build a swoop, build the
version you'd defend -- forward-thinking and robust -- not a deliberately dumb stub you
plan to "harden in a later pass." Suboptimal-on-purpose code compounds: the next
feature builds around the shortcut and inherits it, so the whole system ratchets toward
mediocre. If you genuinely need to prove an approach works first, do it with a
**throwaway spike** (code written to be deleted) and then build the committed version
properly -- never promote the spike into the feature. The one honest exception is
sequencing that hardware reality forces (e.g. the writable dev image before the
read-only car image), which the owning docs call out explicitly.

## Roadmap

The build plan lives in **[`docs/roadmap.md`](docs/roadmap.md)**: the **swoops**
(codenamed units of work across Pi -> Wi-Fi -> app -- `oak`, `fox`, ... -- each built
as a durable, forward-thinking feature rather than a transient stub; codenamed so they
reorder without renumbering), the default order and mock-Pi / real-Pi tracks, and an
**Icebox** of parked someday-maybe swoops. Read it before deciding what to build next.

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
  then iterate over SSH); see [`raspi/README.md`](raspi/README.md) for the full runbook.

## Repository layout

```
dancam/
  AGENTS.md              <- you are here (whole-system overview + conventions)
  Justfile               <- common build/test/run tasks; prefer these over raw commands
  docs/roadmap.md        <- build plan: swoops + Icebox
  app/                   <- iPhone app (Swift / UIKit). Has its own AGENTS.md.
    docs/design/         <- app-side ADRs ({seq}-YYYY-MM-DD-{slug}.md)
  raspi/                 <- camera-unit software (Raspberry Pi). Has its own AGENTS.md.
    service/             <- Rust control/media service crate
    docs/design/         <- raspi-side ADRs ({seq}-YYYY-MM-DD-{slug}.md)
  contract/events/       <- shared /v1/events wire contract (canonical event bodies + README)
  references/            <- third-party source clones (git-ignored; `just fetch-references`)
```

When you work inside `app/` or `raspi/`, read that folder's AGENTS.md first
([`app/AGENTS.md`](app/AGENTS.md), [`raspi/AGENTS.md`](raspi/AGENTS.md)) -- it carries
the details and constraints specific to that side. Each side's file links back here and
to its sibling, so the three stay navigable (and de-duped: root owns the cross-cutting
decisions, each side owns its own).

## Contract

`contract/` holds the versioned wire contract shared by both sides -- currently
`contract/events/`, the canonical `/v1/events` event bodies (one JSON file per
event `type`, plus a `README.md` describing the SSE framing). These files are the
source of truth for the format: both the raspi Rust service
(`raspi/service/src/events.rs#fn fixture`) and the app's Swift test suite
(`app/DanCam/DanCamTests/Networking/Events/CameraEventCorpusTests.swift`) load
them as a golden corpus and assert their decoders round-trip every file. It lives
at the repo root, a peer of `app/` and `raspi/`, because it belongs to neither
side -- it is the boundary between them, not documentation to file under `docs/`.

## References

`references/` holds read-only clones of upstream source we build against, so we target
the exact API. Git-ignored; seed or refresh with `just fetch-references`. Versions are
pinned in `scripts/fetch-references.sh` to match what the Pi runs; run
`just references-pi-version` to confirm the Pi's installed version before setting or
bumping a pin.

- **picamera2** (`references/picamera2/`) -- Raspberry Pi camera stack imported by the Pi
  camera process (`raspi/camera/camera.py`). Pinned to the `python3-picamera2` version on
  Raspberry Pi OS Trixie. Upstream: https://github.com/raspberrypi/picamera2
- **libcamera** (`references/libcamera/`) -- the Raspberry Pi **fork** (not upstream
  linuxtv), which is what runs on the Pi: it carries the `rpi` pipeline handlers and the
  IPA tuning under the picamera2 stack. Read for a future all-Rust camera owner; see
  `docs/research/1-rust-camera-owner.md`. Pin tracks the fork branch/tag matching the Pi's
  installed libcamera (`just references-pi-version`). Fork: https://github.com/raspberrypi/libcamera
- **linux** (`references/linux/`) -- the Raspberry Pi kernel fork, **sparse-fetched** to just
  two V4L2 driver folders: `drivers/staging/vc04_services/bcm2835-codec/` (the `/dev/video11`
  H.264 M2M encoder) and `drivers/media/platform/bcm2835/` (the `bcm2835-unicam` CSI-2
  receiver). Source for the encoder/capture wrappers a future Rust camera owner would drive;
  see `docs/research/1-rust-camera-owner.md`. Pinned to the `stable_YYYYMMDD` tag matching the
  Pi's running kernel (`just references-pi-version`). Fork: https://github.com/raspberrypi/linux

## Cross-cutting principles (the decisions that shape everything)

These are settled at the system level. Side-specific ADRs must not contradict them.

- **SD is the source of truth.** The Pi always records locally. The phone is a
  client that reads footage on demand; a dropped Wi-Fi link must never lose video.
- **Incidents are phone-owned.** The Pi ring buffers recent footage and serves it;
  the app pulls a marked window into permanent phone storage and owns incident
  lifecycle, review, sharing, and deletion. See
  `app/docs/design/26-2026-07-14-phone-owned-incidents.md`.
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
  Request/response control plus low-res preview, snapshot-first SSE events, and
  on-demand clip pull; never on the recording path. `/v1/events` is the live state
  source: snapshot, ordered deltas, and heartbeat. Connection liveness is heartbeat
  presence; `/v1/status` is a one-shot read of the same snapshot shape. The transport
  mechanics (MJPEG preview, resumable ranged pull, SSE events) live in the transport ADR.
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
  comments, and commit messages -- but not UI.
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
- **Raspberry Pi setup runbook:** [`raspi/README.md`](raspi/README.md) is the
  reproducible fresh-Pi bootstrap, verification, and operations guide. Changes to
  human-facing setup/verify/ops steps must update it in the same change. Changes to
  onboard system state -- packages, `/boot/firmware/config.txt`, Avahi,
  NetworkManager profiles, systemd units, deploy paths, AP/mDNS behavior, or other
  config files -- belong in the owning playbook/unit/deploy artifact and its comments;
  see [`raspi/AGENTS.md`](raspi/AGENTS.md) and
  [`raspi/docs/design/09-2026-06-26-pi-system-layer-config-ansible.md`](raspi/docs/design/09-2026-06-26-pi-system-layer-config-ansible.md).
- **Commits:** small and logical; one coherent change per commit. Follow
  [Conventional Commits](https://www.conventionalcommits.org/) -- a `type(scope):
summary` subject (types: `feat`, `fix`, `docs`, `refactor`, `chore`; scope optional,
  e.g. `app` / `raspi`), with a body when the why isn't obvious. Example:
  `docs(raspi): add power-source-and-shutdown ADR`.
- **Source of truth for context:** `AGENTS.md` files. `CLAUDE.md` exists only to
  import `AGENTS.md` for the Claude Code harness.
