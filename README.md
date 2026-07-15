# dancam

dancam is a do-it-yourself, iPhone-only dashcam. A Raspberry Pi camera unit
records safely to its own microSD card, the iPhone app owns the product
experience, and CarPlay provides a constrained voice, status, and control surface.

## The system

- **Camera unit (`raspi/`)** -- captures, encodes, and stores footage locally,
  then serves status, preview, and requested clips over its direct Wi-Fi network.
- **iPhone app (`app/`)** -- controls recording, shows live preview, browses and
  pulls clips, manages settings, and permanently owns incident footage.
- **CarPlay integration** -- lives inside the app and provides voice control,
  automatic start/stop, status, and alerts. Live video stays on the phone.

The Pi is deliberately narrow and reliable; the app is the brains. Wi-Fi is never
part of the recording path. Read the [system overview](docs/overview.md) for the
full architecture and cross-cutting principles.

## Documentation

Browse the documentation book locally:

```sh
just docs-serve
```

`just docs-build` builds the book and checks its links. Useful entry points:

- [Roadmap](docs/roadmap.md) -- current build sequence and Icebox.
- [Hardware](docs/hardware.md) -- selected parts and physical constraints.
- [Pi setup runbook](docs/setup/pi-runbook.md) -- flash, provision, deploy,
  verify, and operate the camera unit.
- [App-Pi transport boundary](docs/design/boundary/transport.md) -- local API,
  events, preview, clip pull, Wi-Fi pinning, and trust.
- [Pi recording](docs/design/pi/recording.md) and
  [storage](docs/design/pi/storage.md) -- capture durability and the footage ring.
- [App architecture](docs/design/app/architecture.md) and
  [incidents](docs/design/app/incidents.md) -- product state and permanent evidence.

Developer and agent conventions start in [`AGENTS.md`](AGENTS.md), with focused
guidance in [`app/AGENTS.md`](app/AGENTS.md) and
[`raspi/AGENTS.md`](raspi/AGENTS.md).

## Repository layout

```text
dancam/
  docs/                  mdBook source: overview, design, setup, and research
  contract/events/       canonical shared event bodies and SSE framing
  app/                   Swift/UIKit iPhone app
  raspi/                 Pi camera owner, Rust service, and provisioning
  references/            gitignored, pinned upstream source clones
  Justfile               common build, test, docs, and deploy tasks
```
