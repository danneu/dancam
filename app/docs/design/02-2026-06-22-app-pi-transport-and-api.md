# ADR: app<->Pi transport and API (app side)

- **Status:** Accepted
- **Date:** 2026-06-22
- **Owner:** app
- **Related:** `raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md` (the canonical
  wire contract -- this ADR delegates to it); root `AGENTS.md` (cross-cutting principle
  "The app<->Pi link is a versioned local API served by the Pi, pinned to Wi-Fi");
  `app/docs/design/01-2026-06-22-carplay-integration-surface.md` (the incident-lock and
  offline alert this ADR's client feeds)

## Context

The iPhone app is the client of the camera unit's local API. The **wire contract** --
the transports, the `http://<pi>/v1/...` endpoints, the auth posture, versioning, and
the incident-lock/idempotency semantics -- is owned and served by the Pi and is
specified in the raspi-side ADR (`raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md`).

This ADR records the **app-side obligations** that implementing that contract on iOS
imposes: which iOS frameworks the app uses for discovery, AP join, interface pinning,
playback, and voice; the client-side parsing the design forces; and the permission and
offline-detection plumbing. It does **not** restate the wire contract; where the two
could drift, the raspi ADR is authoritative.

## Decision

**Delegate the wire contract to the raspi ADR.** The app implements a client against
that contract with the following obligations.

### Transport and connection (iOS frameworks)

- **Discovery:** `NWBrowser` for `_dancam._tcp` (Bonjour), with a fixed AP gateway-IP
  fallback (`10.42.0.1`) for the first seconds after association when mDNS is
  often unresolved.
- **AP join:** `NEHotspotConfiguration` with **`joinOnce = false`** so the configuration
  **persists** -- the app auto-rejoins the Pi AP across launches and across drives,
  rather than re-prompting every trip. Chosen for the documented persistence semantics
  (config persists -> auto-rejoin), not any OS-bug claim. Needs the Hotspot Configuration
  entitlement; SSID + per-unit random password come from the QR sticker on the unit.
- **Interface pinning:** every Pi connection is an `NWConnection` pinned to Wi-Fi
  (`requiredInterfaceType = .wifi`, `prohibitedInterfaceTypes = [.cellular]`) so the
  "no internet" AP cannot push traffic to cellular. One warm connection for control, a
  second long-lived one for the SSE event/heartbeat stream.
- **Local Network permission:** `NSLocalNetworkUsageDescription` + `NSBonjourServices`
  in Info.plist; the prompt fires on first local access; the app handles denial
  gracefully in onboarding.
- **Reconnection:** `NWConnection` state handler + `NWPathMonitor` drive back-off
  reconnect; a changed `X-Dancam-Boot-Id` means the Pi rebooted, so the app re-runs time
  sync + the capability check and resumes pulls via `Range`/`If-Range`.

### Hand-rolled HTTP/1.1 client (the explicit cost of pinning)

Because **`URLSession` cannot pin to the Wi-Fi interface** but `NWConnection` can, the
app **hand-rolls an HTTP/1.1 client on the pinned `NWConnection` for every plane**:

- **Control:** request/response framing + keep-alive over the warm socket.
- **Events:** `text/event-stream` (SSE) parsing, with heartbeat-absence as the offline
  trigger.
- **Live preview:** `multipart/x-mixed-replace` boundary scanning to split the MJPEG
  stream into frames for a custom preview view (the live view is iPhone-screen only,
  never CarPlay).
- **Clip pull:** the resumable `Range`/`If-Range`/`Content-Range` loop -- the riskiest
  parser, since flaky 2.4 GHz makes resume the normal case, not the exception.

This is a deliberate, recorded cost. The raspi ADR's "simple/debuggable" framing
describes the **Pi server**; the matching client work lives **here** and is not free.
Scope is bounded, though: HTTP/1.1 only, a fixed set of known endpoints, four plane
parsers -- not a general HTTP stack.

### Time sync and clip provenance

The Pi has no RTC, so the app is the trusted time source. App obligations: send the
handshake's `POST /v1/time` (RTT-compensated), show "time unverified" until it lands,
tag pre-sync clips approximate, and re-run any pre-sync window query after sync for an
evidence-grade result. The handshake order and the `time_approximate` /
post-sync-`start_ms`-correction semantics are defined in the raspi ADR; this ADR does
not restate them.

### Incident lock with queue-and-flush (CarPlay voice path)

The incident lock is invoked via **App Intents** ("save that clip") and feeds the
CarPlay surface (per the CarPlay ADR). App obligations: **generate the idempotency UUID
before speaking** so retries fold into one incident; on the cold/voice path (no warm
socket) **queue the lock locally** (UUID + `at_epoch_ms` wall-clock timestamp) and
**flush it after the reconnect handshake's `POST /v1/time`**; and, for a pre-sync lock,
**wait for the `incident_resolved` SSE event** (observed via `GET /v1/incidents`) before
treating the incident's window as final. How the Pi preserves a pre-sync lock
(`pending_resolution`, reboot-crossing idempotency, force-finalize-once) is the raspi
ADR's contract, not restated here.

### Clip playback and export

- **Playback:** pull the `.ts` segment(s), build a **local HLS playlist** referencing
  the pulled segments, and play it with **AVPlayer over a loopback HTTP server**
  (AVPlayer requires HLS over http(s), not `file://`). AVPlayer therefore only ever
  talks to `127.0.0.1`; it never talks to the Pi (it cannot use the pinned
  `NWConnection`), which is why there is no straight-from-Pi HLS path.
- **Export / share:** remux the pulled `.ts` to MP4 (passthrough, no re-encode) for
  Photos / AirDrop. This is **export-only and spike-gated**; it is not on the playback
  hot path.

### Offline detection -> CarPlay alert

Offline is inferred client-side: missed SSE heartbeats (primary) -> `camera_offline`,
corroborated faster by `NWPathMonitor` (Wi-Fi path down) and secondarily by `NWBrowser`
service-removed. Offline raises the CarPlay alert (CarPlay ADR item 4) + a local
notification, because the dangerous case is recording silently stopping. On reconnect, a
gap in `newest_ts` flags "possible gap in coverage."

## Consequences

- **The per-plane client surface is the app's largest piece of bespoke networking.**
  Four parsers (framing/keep-alive, SSE, multipart MJPEG, resumable Range) must each be
  correct and individually testable; the resumable pull is the one most worth hardening,
  since resume is the normal case on this link. This is the direct cost of pinning to
  Wi-Fi, accepted so the no-internet AP cannot route Pi traffic to cellular.
- **Playback and export already absorb the future-TLS upgrade.** Keeping AVPlayer on a
  loopback HLS server (not pointed at the Pi) sidesteps the AVPlayer + HLS +
  self-signed-TLS break, so adding pinned-cert TLS later changes only the pull, not the
  player.
- **The voice incident path is robust to a mid-incident power cut** because the app
  queues locally and the Pi's contract is reboot-crossing and pre-sync-preserving; the
  app's obligation is to generate the UUID early, flush after `POST /v1/time`, and wait
  for `incident_resolved` before finalizing a pre-sync incident's window.

## Alternatives considered

- **A single ADR spanning both sides.** Rejected -- the Pi owns and serves the contract,
  so the canonical copy lives raspi-side; this app-side ADR delegates to it and records
  only the app obligations, avoiding two copies that can drift.
- **An in-app loopback reverse-proxy** (pin one upstream `NWConnection`, re-expose the
  Pi at `127.0.0.1` so `URLSession` owns the resumable pull and AVPlayer streams HLS
  straight through). Evaluated and **deferred for v1** -- it relocates the HTTP work
  rather than removing it and is a single higher-stakes always-on component versus four
  contained per-plane parsers. The full tradeoff is recorded in the raspi ADR's
  Alternatives; revisit there first if the hand-rolled client surface proves burdensome.

## Implementation notes

- **2026-06-25:** The first physical AP health slice proved the fixed AP gateway
  path, then moved the live health base URL behind `AppConfiguration`. For now, the
  app resolves the camera API base URL from `DANCAM_CAMERA_API_BASE_URL`, then the
  `DANCAMCameraAPIBaseURL` Info.plist key, then the `http://10.42.0.1:8080` AP
  fallback. Real `NWBrowser` discovery and Wi-Fi-pinned HTTP remain the later
  transport implementation behind the same dependency boundary.
- **2026-06-25:** Swoop `fox` moved both health and live preview onto the raw
  `NWConnection` HTTP client. On a physical iPhone joined to `dancam-dev`, the first
  pass with `DANCAM_PIN_WIFI=0` proved basic AP connectivity and preview rendering.
  The pinned pass removed that override, left cellular on, and still loaded health plus
  moving live preview from `http://10.42.0.1:8080`; this validates Wi-Fi pinning for the
  `fox` health and preview planes. No Local Network prompt or captive sheet was
  observed during the AP runs. Stop -> Start initially exposed a preview decode-state
  restart bug, fixed by resetting sequence ordering for each new stream generation.
