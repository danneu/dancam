# dancam

dancam is a do-it-yourself, iPhone-only dashcam. It separates reliable recording
from the product interface so losing Wi-Fi never means losing footage.

## System picture

### Camera unit

A Raspberry Pi Zero 2 W and wide-angle camera capture, encode, and store footage
on the unit's microSD card while recording is active. The Pi is deliberately
narrow: it owns safe recording, a rolling segment buffer, and a local API that
serves status, preview, and requested clips. It does not own the user's incident
library or the product experience.

Read [hardware](hardware.md) for the physical unit, [Pi recording](design/pi/recording.md)
for capture and media durability, and [Pi storage](design/pi/storage.md) for the ring.

### iPhone app

The iPhone app is the primary interface and the system's brains. It connects over
the Pi's direct 2.4 GHz Wi-Fi network, shows low-resolution live preview, controls
recording, browses and pulls clips, manages settings, and permanently owns marked
incidents. The app asks the Pi for footage; it never depends on the link to create
the source recording.

Read [app architecture](design/app/architecture.md),
[connection](design/app/connection.md), and
[incident capture](design/app/incidents.md) for the app model.

### CarPlay

CarPlay is a constrained layer inside the iPhone app. It provides voice control,
automatic start/stop, status, and alerts while driving. Third-party CarPlay apps
cannot present a live camera feed, so video remains on the iPhone.

Read the [CarPlay boundary](design/app/carplay.md) for the allowed product surface.

## Cross-cutting principles

### SD is the source of truth

Whenever recording is active, the Pi writes full-quality footage locally. The
phone reads footage on demand, and a dropped or congested Wi-Fi link must never
create a recording gap. Preview and pulls are clients of the recording system,
not part of its write path. See [Pi recording](design/pi/recording.md) and
[storage](design/pi/storage.md).

### Incidents are phone-owned

The Pi maintains recent footage in its ring and serves immutable clips. When the
user marks an incident, the app plans the covering window, pulls those clips into
durable phone storage, and owns the incident's recovery, review, sharing, and
deletion. Pi segments are not pinned for incidents in v1. See
[incident capture](design/app/incidents.md).

### Wi-Fi is 2.4 GHz, preview and pull only

The Zero 2 W has no 5 GHz radio, and the direct link may be slow or congested.
The product therefore uses low-resolution preview and on-demand, resumable clip
pulls instead of continuous bulk mirroring. See [hardware](hardware.md),
[Pi networking](design/pi/networking.md), and the
[transport boundary](design/boundary/transport.md).

### CarPlay is not a video viewport

CarPlay exposes voice, status, recording control, and alerts. Live preview stays
on the iPhone because the platform does not allow a third-party dashcam viewport.
See the [CarPlay boundary](design/app/carplay.md).

### Recording survives abrupt power loss

The car may cut power without warning. The media format, segment lifecycle,
filesystem layout, mount policy, card reserve, and startup recovery all assume
there may be no clean shutdown. See [Pi recording](design/pi/recording.md),
[storage](design/pi/storage.md), and the [OS image](design/pi/os-image.md).

### Thermals are a first-class constraint

The unit lives against a windshield in Texas heat. The camera's 50 C rating is
the weakest limit, below the Pi board's 70 C rating, so mounting, ventilation,
and parked-recording expectations must follow the sensor. See
[hardware](hardware.md#arducam-imx708-autofocus-wide).

### The app<->Pi link is local, versioned, and Wi-Fi-pinned

The Pi serves a versioned local API for request/response control, MJPEG preview,
resumable ranged clip pulls, and snapshot-first SSE events. `/v1/events` is the
live state source: every connection begins with a snapshot, then ordered deltas
and heartbeats. Heartbeat presence defines liveness; `/v1/status` is a one-shot
read of the same snapshot shape. None of these transports sits on the recording
path. See the [transport boundary](design/boundary/transport.md).

## Where to go next

- The [roadmap](roadmap.md) shows the current build sequence and Icebox.
- The [Pi setup runbook](setup/pi-runbook.md) covers flashing, deployment, and
  operations.
- The design chapters in the book describe the current system and preserve each
  decision's rationale in append-only Decision logs.
- [Research](research/1-rust-camera-owner.md) and
  [battle notes](battle-notes/2026-07-02-ffmpeg-first-segment-latency.md) are
  point-in-time investigations rather than living design.
