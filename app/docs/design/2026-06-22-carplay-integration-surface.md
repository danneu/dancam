# ADR: CarPlay integration surface

- **Status:** Accepted
- **Date:** 2026-06-22
- **Owner:** app
- **Related:** root `AGENTS.md` (cross-cutting principle "CarPlay is a voice + status
  + control surface, NOT a video viewport")

## Context

The iPhone is always in the car and connected to CarPlay, so CarPlay is a natural
control surface for the dashcam. The instinct is to show the live camera feed on the
car screen -- but that is not possible, and understanding why bounds the whole
design:

- Third-party CarPlay apps are **template-based**. There is **no arbitrary-video or
  custom-view template**. Only navigation apps draw custom graphics, and that is a
  map-drawing surface, not a video sink. **A live dashcam preview cannot be shown on
  the CarPlay screen.**
- Every on-screen CarPlay app requires a **CarPlay entitlement from Apple**, granted
  per app category. For a dashcam the natural fit is the **Driving Task** category
  (iOS 16+), which gives list/grid/information/alert templates -- a status and
  control panel, not video.
- Safety: anything on the car screen must demand minimal attention while driving.

So the design question is not "how do we show video on CarPlay" but "what small,
safe surface do we expose, and via which mechanisms."

## Decision

Treat CarPlay as a **voice + status + control** surface. The live preview stays on
the iPhone screen. We build the integrations in priority order:

1. **Siri / App Intents voice commands (highest priority).** "Save that clip,"
   "bookmark this," "start/stop recording." The marquee feature is **hands-free
   incident bookmarking** -- the driver says one phrase and the app tells the Pi to
   lock the current buffer. Implemented with the App Intents framework. Works
   hands-free and **requires no CarPlay entitlement at all.** Build this first.

2. **Auto start/stop on CarPlay connect/disconnect.** Detect the CarPlay scene
   lifecycle to auto-join the Pi's Wi-Fi and start recording on entry, and stop/
   finalize on exit. High UX value ("it just works when I get in"); no on-screen
   entitlement needed.

3. **A Driving Task CarPlay panel (status + controls).** An on-screen panel showing
   recording on/off, Wi-Fi link health, storage remaining, last incident, and a big
   "Save clip" / "Start/Stop" control. Requires the Driving Task entitlement from
   Apple -- budget for an App Review conversation, since "dashcam" is not an
   obviously blessed use case. Design for minimal interaction (CarPlay limits item
   counts / scrolling while moving).

4. **CarPlay alerts/notifications.** Surface "incident saved," "storage full," and
   especially "camera offline / Wi-Fi dropped" -- the last one matters because
   otherwise recording silently stops and the driver never knows.

Explicitly **out of scope:** live video on the CarPlay screen (not possible); a
navigation/map entitlement and plotting incidents on a map (wrong category, low
payoff); audio/Now-Playing shoehorning. "Next-gen CarPlay" / CarPlay Ultra is an
automaker-level program, not a third-party app integration.

## Consequences

- The first two items ship value with **no entitlement risk** and no driving-safety
  concern -- they are the foundation and should land before the on-screen panel.
- The Driving Task panel (#3) is gated on Apple approval; the product must be useful
  without it, so we sequence it after #1 and #2.
- The live preview remains an iPhone-screen feature. UX copy and onboarding must set
  this expectation so users do not expect video on the dashboard display.
- Voice incident-marking depends on the Pi exposing a fast "lock current buffer"
  control (see `raspi/AGENTS.md` incident-lock and the ring buffer). The app/Pi
  control API must make this a single low-latency call.

## Alternatives considered

- **Show live video on CarPlay.** Not possible for third-party apps; no template
  exists. This is the central constraint, not a choice.
- **Ship the on-screen panel first.** Rejected: it is the only piece requiring an
  Apple entitlement, so leading with it blocks all value behind an approval. Voice +
  auto start/stop deliver most of the value with none of the risk.
- **Navigation app category** (to draw custom graphics / map incidents). Rejected:
  wrong category for a dashcam, heavier review, and it still would not allow a camera
  feed.
