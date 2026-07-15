# dancam

dancam is a do-it-yourself dashcam system built around an iPhone. It has three
parts:

- A Raspberry Pi camera unit records continuously to its own microSD card.
- The iPhone app is the primary interface for previewing the camera, managing
  recording, browsing footage, and keeping incidents.
- CarPlay provides a small voice, status, and control surface while driving.

The Pi owns reliable capture and local storage. The app owns the product
experience and retrieves footage over a direct Wi-Fi connection when it needs
it. CarPlay is part of the app and never displays live video.

See the [roadmap](roadmap.md) for the current build sequence. The
[research](research/1-rust-camera-owner.md) and
[battle notes](battle-notes/2026-07-02-ffmpeg-first-segment-latency.md) record
point-in-time investigations that inform future work.
