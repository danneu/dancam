# dancam

dancam is a do-it-yourself dashcam system built around an iPhone. The camera unit
records locally, the iPhone app owns the product experience, and CarPlay exposes a
small voice, status, and control surface for use in the car.

The full system overview, working stance, and ADR conventions live in
[`AGENTS.md`](AGENTS.md).

## The three parts

- **Camera unit (`raspi/`)** -- a Raspberry Pi + wide-angle camera that records
  continuously to its own microSD card and serves footage on request.
- **iPhone app (`app/`)** -- the primary UI and brains for preview, clip browsing,
  downloads, settings, and incidents.
- **CarPlay integration** -- a safe surface inside the iPhone app for voice
  incident-marking, status, alerts, and start/stop control.

The project is iPhone-only. The app owns the experience; the Pi stays deliberately
dumb: capture, encode, store safely, and serve footage.

## Status

There are no users or shipped releases. The repo is still design-doc-heavy, with
early buildable code in `raspi/service/` and several thin end-to-end slices already
working. The current build order lives in [`docs/roadmap.md`](docs/roadmap.md).

## Hardware

The tentative v1 camera unit is a Raspberry Pi Zero 2 W with an Arducam IMX708
Autofocus Wide camera. See [`raspi/AGENTS.md`](raspi/AGENTS.md) for the full spec,
constraints, and part links.

## Design principles

- **SD is the source of truth.** The Pi always records locally; Wi-Fi is never on
  the recording path.
- **Wi-Fi is 2.4 GHz preview + pull only.** The phone gets low-res preview and
  on-demand clip pulls, not continuous full-quality streaming.
- **CarPlay is not a video viewport.** Live preview stays on the iPhone screen;
  CarPlay gets voice, status, alerts, and control.
- **Recording survives abrupt power loss.** The car can cut power at any time, so
  corruption resilience is designed in layers.
- **Thermals are a real constraint.** Windshield heat and the camera sensor's 50 C
  limit shape the hardware and operating model.

See [`AGENTS.md`](AGENTS.md) for the full cross-cutting principles and links to the
owning ADRs.

## Repository layout

```text
dancam/
  AGENTS.md              whole-system overview and conventions
  Justfile               common build/test/run tasks
  docs/roadmap.md        build plan and parked future work
  app/                   iPhone app
  raspi/                 Raspberry Pi camera-unit software and runbook
  references/            gitignored upstream source clones
```

## Where to go next

- Pi setup and operations runbook: [`raspi/README.md`](raspi/README.md)
- Camera-unit design and development notes: [`raspi/AGENTS.md`](raspi/AGENTS.md)
- iPhone app design and development notes: [`app/AGENTS.md`](app/AGENTS.md)
- Whole-system overview and design decision process: [`AGENTS.md`](AGENTS.md)
- Build plan: [`docs/roadmap.md`](docs/roadmap.md)
