# CarPlay integration boundary

CarPlay is a voice, status, and control surface for DanCam. Live video stays on the
iPhone. Third-party CarPlay apps are template-based and have no arbitrary-video or
custom-view template; the navigation drawing surface is not a camera-video sink.
Product copy and onboarding must set the same expectation rather than implying that a
preview will appear on the dashboard display.

The app currently has no App Intent, CarPlay scene, or template implementation. This
page defines the product boundary and the sequence future integration must follow.
[Phone-owned incidents](incidents.md) owns the durable action behind voice incident
marking. [App connection](connection.md) and [app architecture](architecture.md) own
the link and root lifecycle that CarPlay automation will drive.

## Integration sequence

Build CarPlay value in this order:

1. **Siri and App Intents voice commands.** Hands-free "save that clip" is the
   highest-value action, followed by start and stop recording. Voice incident marking
   creates the same durable phone-local incident as the Home button and enters the same
   reconciler. It makes no Pi mutation on the press path. App Intents require no
   CarPlay entitlement.
2. **Automatic start and stop.** Use CarPlay scene connection and disconnection to
   join the Pi network and start recording on entry, then stop and finalize on exit.
   This also requires no on-screen CarPlay entitlement.
3. **Driving Task panel.** After Apple grants the Driving Task entitlement, available
   for third-party apps since iOS 16, expose a minimal panel for recording state, link
   health, remaining storage, the latest incident, and large save/start/stop controls.
   The product must remain useful without this panel because entitlement approval is
   an external gate.
4. **Alerts and notifications.** Surface incident saved, storage full, and especially
   camera-offline conditions so a silent link failure is visible to the driver.

Every car-screen interaction must be brief and low-attention. CarPlay limits items and
scrolling while the vehicle is moving, and the panel should be designed inside those
constraints rather than treating it as a second phone UI.

## Explicit non-goals

DanCam does not show live or recorded video on the CarPlay screen. It does not seek a
navigation entitlement to draw custom graphics or plot incidents, and it does not
masquerade as an audio or Now Playing app. CarPlay Ultra is an automaker integration,
not a third-party-app path.

CarPlay work needs the Xcode CarPlay simulator and, for an on-screen panel or device
testing, Apple's category entitlement. Voice and lifecycle automation must land and be
useful independently of that approval.

## Decision log

### 2026-06-22: Keep CarPlay to voice, status, and control

(absorbed from app ADR 01, 2026-06-22)

The phone is normally connected to CarPlay in the car, making it a natural dashcam
control surface. The initial instinct was a live preview, but third-party apps can
render only Apple-provided templates. The Driving Task category offers list, grid,
information, and alert templates, not video, and every on-screen experience must also
minimize driver attention.

The design prioritized entitlement-free voice commands and scene-driven automation,
then a status/control panel gated on Driving Task approval, then alerts. This ordering
kept the product useful even if Apple did not approve a dashcam panel.

Showing live video was impossible rather than merely undesirable. Shipping the panel
first was rejected because it put all value behind approval. A navigation category was
the wrong product category, carried heavier review risk, and still would not allow a
camera feed.

### 2026-07-14: Make voice marking phone-local

(absorbed from the 2026-07-14 incident amendment to app ADR 01)

The original voice sketch assumed a fast Pi "lock current buffer" call. Phone-owned
incidents later removed that dependency: an App Intent should persist the same local
record as the on-screen press and let reconciliation pull from existing clip surfaces.
This improves press latency and offline retry while preserving the CarPlay surface and
its priority order.
