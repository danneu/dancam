# dancam

dancam is a do-it-yourself, iPhone-only dashcam system. The Raspberry Pi camera
unit records safely to its own microSD card, the iPhone app owns the product
experience, and CarPlay is a small voice, status, and control surface inside the
app. Read the [system overview](docs/overview.md) before cross-side work.

## Working stance: take the ideal solution, not the prescribed one

This project is early and has no shipped users. Existing docs and code are evidence,
not compatibility commitments: delete and replace old shapes when a cleaner design
emerges, and update the owning design page in the same change.

Build every swoop as the durable version you would defend, not a deliberately weak
stub to harden later. When an approach needs proof, write a throwaway spike and then
build the committed version properly. Hardware-forced sequencing, such as a writable
dev image before a read-only car image, is the honest exception.

## Roadmap

[`docs/roadmap.md`](docs/roadmap.md) owns the ordered, codenamed swoops and Icebox.
Read it before choosing what to build next.

## Development environment

Dan develops on an M1 MacBook Pro running macOS. The iPhone app builds natively in
Xcode; current iOS toolchains and the simulator require Apple Silicon. Raspberry Pi
work is cross-built from the Mac and deployed over SSH; the full bootstrap and
operations guide is the [Pi setup runbook](docs/setup/pi-runbook.md).

## Repository layout

```text
dancam/
  AGENTS.md              <- whole-system stance, constraints, and conventions
  Justfile               <- common build, test, docs, and deploy tasks
  book.toml              <- mdBook configuration; source is docs/
  docs/                  <- overview, roadmap, living design, setup, and research
  contract/events/       <- canonical /v1/events golden corpus and framing reference
  app/                   <- iPhone app (Swift/UIKit); has its own AGENTS.md
  raspi/                 <- camera owner, Rust service, provisioning; has its own AGENTS.md
  references/            <- gitignored, pinned upstream source clones
```

When working in `app/` or `raspi/`, read that directory's AGENTS.md after this one.

## Contract

`contract/events/` is the canonical shared `/v1/events` wire corpus. Its
[`README.md`](contract/events/README.md) owns the SSE framing and explains how both
the Rust and Swift suites round-trip every golden event body. The contract stays at
the repo root because it is the boundary between the app and Pi, not owned by either.

## Reference guides

- [Hardware](docs/hardware.md) -- read for the selected parts, physical constraints,
  cabling, camera compatibility, and supported Raspberry Pi Imager versions.
- [Upstream source references](docs/references.md) -- read before changing camera-stack
  or kernel integration; it owns clone locations, pins, and refresh commands.

## System constraints

The [system overview](docs/overview.md#cross-cutting-principles) is the canonical full
explanation. Keep these always-on constraints in view:

- **SD is the source of truth:** the Pi records locally; Wi-Fi is never on the
  recording path. See [Pi recording](docs/design/pi/recording.md).
- **Incidents are phone-owned:** the app pulls and permanently owns marked footage.
  See [incident capture](docs/design/app/incidents.md).
- **Wi-Fi is 2.4 GHz, preview and pull only:** never design for bulk continuous
  streaming. See the [transport boundary](docs/design/boundary/transport.md).
- **CarPlay is voice, status, and control, not video:** live preview stays on the
  phone. See the [CarPlay boundary](docs/design/app/carplay.md).
- **Abrupt power loss is normal:** recording and storage must recover safely. See
  [Pi recording](docs/design/pi/recording.md) and the [OS image](docs/design/pi/os-image.md).
- **Thermals are a first-class limit:** the 50 C camera rating is weaker than the
  Pi board. See [hardware](docs/hardware.md#arducam-imx708-autofocus-wide).
- **The app<->Pi API is local, versioned, and Wi-Fi-pinned:** SSE is the live state
  source; status is a one-shot snapshot. See the
  [transport boundary](docs/design/boundary/transport.md).

## Design documentation

Design documentation is a set of living subsystem pages under
`docs/design/{boundary,pi,app}/`. The folder identifies the owner; pages have no
owner metadata or sequence numbers.

- Keep each page body as the canonical present-tense design. Every behavior change
  updates the owning page body in the same change.
- Record why a decision was made, including abandoned ideas, as a dated entry under
  the page's `## Decision log`. Append entries; never rewrite or delete them, and
  never preserve stale history in the page body.
- Link to pages inside the book with normal Markdown links so mdBook link checking
  validates them. Write out-of-book code or config references as backticked stable
  anchors such as `raspi/service/src/storage.rs#fn evict`.
- Research and battle notes are point-in-time findings, not living pages. They need
  no Decision log and may go stale honestly. Add every new file under
  `docs/research/` or `docs/battle-notes/` to `docs/SUMMARY.md` in the same change.
- Keep AGENTS.md files lean: always-on stance, constraints, and commands belong here;
  task-specific guidance belongs in a linked page with a when-to-read blurb.

## Conventions

- **Writing style:** use plain ASCII in docs, code comments, chat, and commit
  messages. Write `4x`, straight quotes, `--`, and `degrees`/`deg`; UI copy may use
  richer typography.
- **Stable references:** durable docs and plans never cite line numbers. Use
  `path/to/file#identifier`, where the identifier is a symbol or heading, or quote a
  short unique snippet when no anchor exists. Transient clickable `file:line` links
  in chat are fine.
- **Tasks:** use the root `Justfile` when a recipe exists. Run `just --list` to
  discover tasks; use raw lower-level commands only when testing that layer directly.
- **Pi operations:** changes to human setup, verification, or operations update
  `docs/setup/pi-runbook.md` in the same change. Onboard packages, boot config,
  NetworkManager, Avahi, mounts, systemd, and deploy paths belong in their owning
  playbook/unit/deploy artifact and comments; see [Pi provisioning](docs/design/pi/provisioning.md).
- **Commits:** make one coherent Conventional Commit at a time, using
  `type(scope): summary` with a body when the why is not obvious. Types are `feat`,
  `fix`, `docs`, `refactor`, and `chore`.
- **Context source:** AGENTS.md files are authoritative. CLAUDE.md files only import
  them for the Claude Code harness.
