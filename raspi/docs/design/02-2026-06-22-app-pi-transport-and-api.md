# ADR: app<->Pi transport and API

- **Status:** Accepted
- **Date:** 2026-06-22
- **Owner:** raspi (the Pi serves the wire contract; the canonical copy lives here)
- **Related:** root `AGENTS.md` (all five cross-cutting principles);
  `raspi/docs/design/01-2026-06-22-crash-safe-recording.md` (recording format / the
  footage this transport serves -- this ADR appends a preview-transport supersession
  note to it); `app/docs/design/01-2026-06-22-carplay-integration-surface.md` (consumes
  the incident-lock + offline signal defined here);
  `app/docs/design/02-2026-06-22-app-pi-transport-and-api.md` (the app-side companion ADR
  that delegates the wire contract to this one);
  `03-2026-06-23-storage-ring-buffer-incident-lock.md` (the later ADR that owns the
  storage/ring-buffer mechanisms this ADR only calls)

> **Note (2026-06-23):** Editorial pass after the storage ADR
> (`03-2026-06-23-storage-ring-buffer-incident-lock.md`) landed. Two changes, no decision
> altered: (1) the repeated "mechanism owned by the storage ADR" reminders are
> consolidated into the Context paragraph below rather than restated at each endpoint;
> (2) a *Storage companion fields* subsection is appended to the API surface,
> reconciling the additive fields that ADR introduced (`coverage_truncated`, the
> `deleted` tombstone marker, lock `source`, `retention` ceiling semantics) so the two
> docs agree. Append-only per the ADR convention.

> **Note (2026-06-25):** Real AP bring-up reconciled the fixed gateway examples with
> NetworkManager shared mode. The AP profile now pins `10.42.0.1/24`, so every fixed
> gateway reference in this contract should be read as `10.42.0.1`: the discovery
> fallback, the Host allowlist's AP gateway entry, and the app's hardcoded health target
> for the first hardware proof. The captive-probe DNS lever is deferred for now: an
> iPhone one-shot Safari fetch to `http://10.42.0.1:8080/v1/health` succeeded without a
> dnsmasq drop-in, but that does not weaken this ADR's standing requirement for robust
> persistent no-internet joins. The AP plumbing decision lives in
> `06-2026-06-25-ap-networking-bring-up.md`.

> **Note (2026-06-25):** Swoop `fox` validated the live-preview wire path and the
> no-internet AP routing path on real hardware, but deliberately did not validate
> concurrent preview while recording. The deployed service used
> `DANCAM_BACKEND=camera`, spawning `rpicam-vid --codec mjpeg` for a temporary
> preview-only stream from the camera's main path. Over the home LAN, the endpoint
> returned the expected multipart headers and real JPEG bytes; first response bytes
> arrived in about 226 ms, a 20-second curl received about 2.96 MB, and the Pi SoC was
> around 38-39 C during desk checks. Over the `dancam-dev` AP, the iPhone app loaded
> health and live preview first with `DANCAM_PIN_WIFI=0` for an unpinned diagnostic
> pass, then again with the override removed so the AP gateway default was Wi-Fi-pinned.
> The pinned pass succeeded with cellular left on, no captive sheet was observed, and
> Stop -> Start resumed after the app reset preview decode state on stream restart.
> Therefore spike 3 below is satisfied for `fox`; spike 1 remains open for `jet`
> because the lores-substream path concurrent with 1080p30 H.264 recording is still
> unvalidated.

> **Note (2026-06-25):** Swoop `jet` implements the lean recording-control slice with
> a single Picamera2 camera owner supervised by the Rust service. `POST
> /v1/recording/start` and `/v1/recording/stop` now exist, `/v1/health.recording`
> reflects real backend state, and live preview is fanned out from the child process
> rather than spawning a per-request camera command. The minimal mutation hardening
> required for these first state-changing endpoints is also implemented: global Host
> allowlisting plus `Content-Type: application/json` and non-empty `Idempotency-Key`
> on recording mutations. `Origin` / `Sec-Fetch-Site`, the reserved bearer token,
> pinned-cert TLS, `GET /v1/events`, `GET /v1/status`, and
> `GET /v1/capabilities.preview.concurrent` remain deferred. The hardware spike still
> must validate that the Picamera2 lores preview stays smooth while 1080p30 H.264
> recording runs on the Zero 2 W.

## Context

The camera unit (Raspberry Pi Zero 2 W) records continuously to its own microSD --
the source of truth -- and the iPhone app is the UI and brains. The two talk over the
**Pi's own 2.4 GHz Wi-Fi access point**: there is no router and the AP has no internet.
The open design question this ADR closes is **how they talk**: which transport carries
live preview, control, events, and clip pull; the full v1 API surface; the connection
lifecycle; the v1 auth posture; versioning; and the link-health ("camera offline")
signal. The deliverable is this design, reconciled against the five cross-cutting
principles and the two existing ADRs.

This is the third design decision. The Pi storage ring-buffer / incident-lock
internals (how segments are protected, reference-counted, force-finalized, and how
pre-sync locks are held pending resolution) live in a separate ADR,
`03-2026-06-23-storage-ring-buffer-incident-lock.md`. This ADR only **calls** that
interface and fixes the observable wire contract around it. **Read every mechanism
named below with that split in mind:** wherever this ADR describes finalize,
persistence, pending-resolution, or reference-counting behavior, the storage ADR owns
the mechanism and this ADR fixes only the contract -- stated once here rather than
repeated at each endpoint.

### Key technical facts (validated this session)

- The Pi has **one** H.264 hardware encode session, and it is spent on the 1080p30
  recording. A second concurrent H.264 encode is infeasible. (Confirmed.)
- libcamera can emit a **free low-res YUV "lores" stream** concurrently with the main
  recording stream, produced by the ISP -- not the encoder. (Confirmed.) MJPEG preview
  is built on this stream, so it never contends with the recording encoder.
- **AVFoundation supports MPEG-TS** (`video/mp2t`, ISO/IEC 13818-1) -- confirmed in the
  iPhoneOS SDK (`AVAsset.h` playability, `AVSampleCursor.h`). It plays TS **via HLS (a
  local `.m3u8`), not as a standalone `file://`**, matching the crash-safe ADR. So clip
  playback wraps the pulled `.ts` in a local HLS playlist; no remux is needed for
  playback. **AVPlayer + HLS + self-signed TLS is broken**, so the future-TLS path
  keeps AVPlayer on a loopback HLS server (the pull itself may be TLS) rather than
  streaming HLS straight from the Pi over self-signed TLS.
- **`NWConnection` can pin to the Wi-Fi interface; `URLSession` cannot.** The "Wi-Fi
  has no internet" AP is a real routing landmine. The lever to keep iOS from hijacking
  the join with a Captive Network Assistant (CNA) sheet is **DNS, not the HTTP server**:
  the Pi's dnsmasq must **not** resolve Apple's captive-probe domains to the Pi, so the
  probe fails to connect and iOS marks the AP "no internet" silently. A probe that
  reached the server would hit the `Host` allowlist (below) and get a `421` -- itself a
  non-Success response that would pop the very CNA sheet we want to avoid.

## Decision

Use **three deliberately different transports**, all over `NWConnection` **pinned to
the Wi-Fi interface**, behind a single **versioned local HTTP API served by the Pi at
`http://<pi>/v1/...`** (plain HTTP, no TLS, in v1).

### Transport per function (three planes)

| Plane | Functions | Transport | Why | Rejected alternative |
|---|---|---|---|---|
| **Control** | status, start/stop, settings, time sync, incident-lock, capabilities, clip list | HTTP/1.1 + JSON request/response over a **warm `NWConnection` pinned to Wi-Fi**; idempotency keys on mutations | Low rate, must stay simple/debuggable on 512 MB; a kept-warm pinned socket lets incident-lock skip TCP setup | gRPC/HTTP2 (too heavy + iOS friction); custom binary protocol (reinvents HTTP) |
| **Events/health** | server push + heartbeat | **SSE** (`GET /v1/events`) over a second long-lived pinned `NWConnection`; heartbeat = periodic keepalive | One-way push is all we need; trivial on the Pi; heartbeat-absence is the offline signal | WebSocket (bidirectional not needed; `URLSessionWebSocketTask` cannot pin); long-poll (wasteful, worse offline detection) |
| **Live preview** | low-res live view on the iPhone (never CarPlay) | **MJPEG over HTTP** (`multipart/x-mixed-replace`) from the libcamera **lores YUV** stream; plain HTTP over the pinned connection | Per-frame clarity for aiming / night checks; never touches the H.264 encoder; simplest Pi server; low latency | HLS/LL-HLS (encoder contention, smears night detail, more Pi machinery); WebRTC (too heavy for 512 MB / A53, 3rd-party iOS SDK); RTSP/RTP (no native iOS player) |
| **Clip pull** | download selected finished clips | HTTP **GET with `Range`/`If-Range`** (resumable) over a pinned `NWConnection`; raw `.ts` bytes | Flaky 2.4 GHz needs resume; finished segments are immutable, so `ETag`/`If-Range` make resume safe | `URLSession` background (cannot pin the interface, may be starved on the no-internet AP -- kept as a spike-gated option) |

All planes run over `NWConnection` pinned to Wi-Fi
(`requiredInterfaceType = .wifi`, `prohibitedInterfaceTypes = [.cellular]`) so the "no
internet" AP cannot push traffic to cellular. Plain HTTP (no TLS) in v1.

### API surface (v1, base `http://<pi>/v1/...`)

Conventions: JSON request/response bodies; every response carries `X-Dancam-Proto: 1`
and `X-Dancam-Boot-Id`; mutations accept an `Idempotency-Key` header; the
`Authorization` header slot is **reserved (unused in v1)** for the future token.

**Handshake / identity / time**

- `GET /v1/capabilities` -- proto versions, firmware semver, `device_id`, `boot_id`,
  `encode{max:"1080p30", sessions:1}`,
  `preview{kind:"mjpeg", max_res, snapshot:true, concurrent:bool}`, `features[]`,
  `time_synced`, `has_gps`. (Unauthenticated.)
- `GET /v1/time` -- `{epoch_ms, source:"app|gps|none", synced_at, boot_id}`.
- `POST /v1/time` -- **time sync at handshake** (the Pi has no RTC). Body
  `{epoch_ms, tz, send_ts}`; RTT-compensated (the app may send a second corrected
  value). The Pi maps a monotonic boot clock -> wall clock, so segments recorded
  before sync get corrected times; pre-sync segments are tagged "time approximate."
  GPS, if fitted, overrides.

**Status / control**

- `GET /v1/status` -- `recording`, `since`, `current_segment_id`,
  `storage{used,total,locked,oldest_ts,newest_ts}`, `temp_c{soc,sensor?}`,
  `encode_active`, `time_synced`, `last_incident_id`, `boot_id`, `uptime_s`. (Feeds the
  CarPlay panel.)
  > **Note (2026-06-26):** Swoop `fern` ships a dashboard subset of this accepted
  > contract without changing the full contract: `recording`, `camera_state`,
  > `boot_id`, `uptime_s`, nullable `storage{used,total}`, nullable
  > `temp_c{soc,sensor}`, and nullable `mem{total,available,swap_total,swap_used}`.
  > The status fields `since`, `current_segment_id`, storage
  > `locked/oldest_ts/newest_ts`, `encode_active`, `time_synced`, and
  > `last_incident_id` remain intentionally deferred until the storage coordinator,
  > time-sync, and incident layers exist. `temp_c.sensor` is present but null until
  > the Picamera2 owner surfaces sensor metadata.
- `GET /v1/health` -- tiny liveness `{boot_id, uptime_s, recording, t_ms}`. (Unauth.)
- `POST /v1/recording/start` / `POST /v1/recording/stop` (idempotent; stop finalizes
  the current segment).
- `GET /v1/settings` / `PATCH /v1/settings` -- resolution (1080p30), hdr, bitrate,
  retention, mic, `preview{res,fps,quality}`, `auto_record_on_boot`; PATCH echoes the
  settings + `requires_restart`.
- `POST /v1/system/reboot` / `POST /v1/system/shutdown` (clean).
- `GET /v1/logs?since=&level=` -- tail from the writable partition (ASCII).
- `POST /v1/storage/format` -- dangerous; double-confirm (`confirm:"FORMAT"`).

**Incident lock (CarPlay-critical, low latency)**

- `POST /v1/incidents/lock` -- body
  `{idempotency_key(UUID), at_epoch_ms?, pre_s?, post_s?, note?}` ->
  `{incident_id, locked_segment_ids, window, pending_post, pending_resolution}`.

  Returns immediately. The handler locks the segments the mark resolves to, and -- on
  the **first delivery of the idempotency key**, and **only when the mark falls in the
  currently-open segment** (the live / just-happened case) -- **force-finalizes that
  open segment** (closes it and opens a new one), so the pre-roll up to the mark becomes
  an immutable, *pullable* segment within seconds instead of only at the next natural
  rollover. (Incident review is a headline use case; without this the most recent
  ~30-60 s would sit in the open segment, unreviewable up to the mark.) This is the same
  finalize `recording/stop` performs, just triggered by the lock. A **past**
  `at_epoch_ms` (e.g. the
  cold post-reboot path below) needs **no split**: its footage is already in finalized,
  pullable segments, and force-finalizing the *current* segment would only cut unrelated
  live footage. The **post-roll** is then locked lazily as future segments finalize, so
  the call never blocks on time passing.

  The client generates the UUID before speaking ("save that clip") so retries fold into
  one incident. **Voice / cold path:** if there is no warm socket, the app **queues the
  lock locally (client UUID + `at_epoch_ms` wall-clock timestamp) and flushes it after
  the reconnect handshake's `POST /v1/time`** (lifecycle step 6), so the Pi's monotonic
  -> wall map exists before any `at_epoch_ms` is resolved; the Pi then locks
  retroactively by `at_epoch_ms` while the segments are still in the ring.

  - **Idempotency survives a Pi reboot (observable contract).** A power cut mid-incident
    is the *expected* event here, so dedupe cannot assume the Pi stayed up: a lock with a
    given `idempotency_key` must collapse to a **single** incident even if the Pi reboots
    between the original call and a flushed retry. The key is client-generated and
    **boot-independent** -- `boot_id` is **not** part of the idempotency scope -- and the
    Pi must retain seen keys for at least a realistic reassociation gap (a drive's worth,
    generously). **The force-finalize is bound to the same key:** it happens **at most
    once** -- on the first delivery, and only if the mark is in the open segment (above);
    a deduped retry (or a queue-flush after reboot, the dominant path here) returns the
    existing incident and performs **no further segment split**. So "retries are safe"
    covers the side effect, not just the incident record.

  - **Pre-sync locks are preserved, not lost (observable contract).** The dominant
    cold-path case is a lock queued *before* a power cut and flushed against a
    freshly-rebooted Pi that has not yet time-synced. Pre-sync, segments are indexed by
    monotonic time only, so a wall-clock `at_epoch_ms` cannot yet be resolved to a
    window. Safety therefore does **not** hinge on client flush ordering: the Pi MUST
    accept an `at_epoch_ms` lock received before time sync, **immediately protect all
    in-ring footage from eviction** (a past mark is then covered no matter how old --
    "current + recent" near *now* could miss the older pre-reboot segments the mark
    actually lives in), and **bind the precise `[at_epoch_ms - pre_s, at_epoch_ms +
    post_s]` window once `POST /v1/time` lands**, releasing the rest. The hold is
    short-lived (time sync normally lands at the handshake, seconds after association,
    step 6), so briefly freezing eviction is cheap. The app still normally flushes after
    time sync (above); this guarantee makes preservation robust even if it does not.

    **Wire representation of a pre-sync lock:** the response returns the `incident_id`
    immediately with `pending_resolution: true`, `window: null`, and an **empty
    `locked_segment_ids`**. It MUST NOT expose the conservative all-in-ring eviction hold
    as the incident's segment set, or a client would treat the whole ring as the incident
    and bulk-pull it over 2.4 GHz (violating "preview + pull only, no bulk mirroring").
    The all-in-ring hold is an internal eviction guard, not a client-visible segment list.
    Once `POST /v1/time` binds the precise window, the incident's
    `window`/`locked_segment_ids` narrow to `[at_epoch_ms - pre_s, at_epoch_ms + post_s]`,
    observable via `GET /v1/incidents` and announced by an `incident_resolved` SSE event
    so the client knows when it is safe to read/pull.

- `GET /v1/incidents?limit=&cursor=` -- list locked incidents. A pre-sync lock appears
  with `pending_resolution: true` and no concrete `window` until time sync binds it.
- `POST /v1/incidents/{id}/extend` -- `{post_s}` (event still unfolding).
- `DELETE /v1/incidents/{id}` -- unlock. **Only releases segments not referenced by any
  other incident** (segment protection is the union of all incidents' segment sets /
  reference-counted), so unlocking one incident never exposes footage another incident
  still needs.

**Preview**

- `GET /v1/preview/live.mjpeg` -- `multipart/x-mixed-replace` MJPEG from the lores
  stream; default ~640x480 @ ~10 fps, high quality, configurable up toward 720p.
- `GET /v1/preview/snapshot` -- a single frozen frame from the same lores stream at
  **maximum JPEG quality** (low compression): sharper and artifact-free versus the
  streaming preview's lossy frames, for unhurried night/low-light inspection. It is
  **preview-resolution, not higher-resolution** -- the lores frame sets the pixel
  ceiling, so "quality" here means compression, not added detail. A true full-res still
  would need a capture off the main stream that contends with the H.264 encoder/ISP
  (thermal cost); that is **out of v1 scope** and, if ever wanted, folds into spike 1.

**Clips**

- `GET /v1/clips?from=&to=&limit=&cursor=&order=` -- windowed / paginated metadata
  `{clips:[{id, start_ms, dur_ms, bytes, locked, etag, time_approximate}], next_cursor,
  server_time_ms}`. The in-progress segment is **not** listed (finished segments only)
  -- except that an incident lock force-finalizes the current segment, so just-marked
  footage appears here within seconds (see incident-lock). **Time-sync caveat
  (evidence-grade timestamps):** a clip recorded before `POST /v1/time` carries
  `time_approximate: true`, and its `start_ms` is the Pi's best monotonic estimate -- it
  may be **corrected** (monotonic -> wall clock) once time sync lands, so `start_ms` can
  change after sync. Consequently `from=`/`to=` window queries before sync are
  **best-effort** and should be re-run after sync for an evidence-grade window.
  (`app/AGENTS.md` makes correct timestamps an evidence requirement; this states what the
  contract guarantees before vs. after sync.)
  > **Note (2026-06-26):** Swoop `fern` ships a cheap finished-segment listing for
  > the current flat `seg_NNNNN.ts` layout. It returns newest-first clip metadata with
  > `id`, `bytes`, `etag`, `locked:false`, `time_approximate:true`, null
  > `start_ms`/`dur_ms`, `server_time_ms`, and `next_cursor:null`; it excludes the
  > highest sequence while recording because that segment is still open. Real
  > `start_ms`, `dur_ms`, `locked`, and non-approximate time provenance remain
  > deferred until the storage/time-sync/incident layers land.
- `GET /v1/clips/{id}` -- resumable pull; `Range`/`If-Range`, `Accept-Ranges`, `ETag`,
  `Content-Range`; `application/mp2t` (the `.ts` segment bytes).
- `GET /v1/clips/{id}/thumb?w=` -- keyframe JPEG (the Pi caches one per segment).

The Pi serves **no `.m3u8`**: HLS playlists are built **app-side** over loopback (see
clip playback below). This keeps every Pi request on the pinned `NWConnection`.

**Events / heartbeat**

- `GET /v1/events` -- SSE stream: periodic heartbeat (keepalive, ~2 s) plus
  `incident_saved`, `incident_resolved` (a pre-sync lock's precise window has bound after
  time sync -- safe to read/pull now), `storage_full`, `recording_stopped`,
  `temp_warning`, `time_synced`. Offline is detected by **absence of heartbeat**, not a
  push.

**Storage companion fields (reconciled 2026-06-23).** The storage ADR
(`03-2026-06-23-storage-ring-buffer-incident-lock.md`) introduced facts the app needs to
rely on contractually. They are folded into the wire contract here, all additive
(clients ignore unknown keys, so no version bump):

- **`coverage_truncated` (bool)** -- added to the incident object on both the lock
  response and `GET /v1/incidents`. `true` means a bounded cap/eviction policy clamped
  the pre-roll/post-roll or evicted older incidents, so the saved window is narrower than
  requested. The marked moment is always preserved; only surrounding context may be
  clamped.
- **`deleted` (bool, optional)** -- present and `true` only on a lock response that is a
  tombstone-hit replay (the `idempotency_key` matches an already-deleted incident). Such
  a response carries the original `incident_id`, an empty `locked_segment_ids`,
  `window: null`, and performs no side effects, so a late retry cannot resurrect a
  deleted incident.
- **`source`** -- **set Pi-side from the request's invocation context, not accepted from
  the wire body.** It is opaque metadata for listings/telemetry and MUST NOT affect
  idempotency or force-finalize logic. (A wire-supplied `source` is therefore ignored.)
- **`retention`** (in `GET`/`PATCH /v1/settings`) -- a **max-age ceiling** layered on the
  space-based ring, not a minimum-retention guarantee: GC also drops segments older than
  the ceiling, with the same protected-segment skip rules. Defaults **unset** = pure
  space-based retention. Best-effort for never-synced footage (the age compares derived
  wall times).
- **Terminal incidents over SSE (deferred).** An incident that becomes provably
  unresolvable or is truncated is surfaced in v1 via `GET /v1/incidents`
  (`coverage_truncated: true`, or a terminal status) plus the existing `storage_full`
  event. A dedicated terminal SSE event is intentionally **not** added yet:
  `incident_resolved` keeps its single meaning ("precise window bound, safe to
  read/pull"). Adding a terminal event later is an additive companion change.

### Clip playback / export (app side)

This aligns with the crash-safe ADR ("HLS for preview and pull, remux to MP4 only for
export"). **Primary playback:** pull the `.ts` segment(s) via the resumable range
request, build a **local HLS playlist** referencing the pulled segments, and play it
with **AVPlayer via a loopback HTTP server** (AVPlayer requires HLS over http(s), not
`file://`). This is robust over a flaky link (download then play), works offline once
pulled, reuses the pulled bytes for export, and is future-TLS-safe (the pull can be TLS
while AVPlayer stays on loopback, sidestepping the AVPlayer + HLS + self-signed-TLS
break). **Export / share:** remux the pulled `.ts` to MP4 (passthrough, no re-encode)
for Photos / AirDrop -- **gated by a spike** (below); not on the playback hot path.
**No straight-from-Pi HLS in v1:** AVPlayer cannot use the pinned `NWConnection`, so
pointing it at the Pi's IP would reintroduce the exact "no-internet AP" routing problem
the design avoids. All playback therefore goes through pulled bytes + the loopback HLS
server, where AVPlayer only ever talks to `127.0.0.1`.

### Connection lifecycle

1. **Discovery:** `NWBrowser` for `_dancam._tcp` (Bonjour), with a **fixed AP gateway
   IP fallback** (`10.42.0.1`) for the first seconds after association, when
   mDNS is often unresolved.
2. **Join the Pi AP:** `NEHotspotConfiguration` with `joinOnce = false` so the
   configuration **persists** -- the app auto-rejoins the Pi AP across app launches and
   across drives instead of re-prompting/re-configuring every trip (`joinOnce = true`
   would drop the configuration after the session). Justified by the documented
   semantics, not an OS-bug claim. Needs the Hotspot Configuration entitlement; the SSID
   + random password are provisioned via a QR sticker on the unit.
3. **Local Network permission:** `NSLocalNetworkUsageDescription` + `NSBonjourServices`
   in Info.plist; the prompt fires on first local access; handle denial gracefully in
   onboarding.
4. **No-internet AP mitigations:** all Pi traffic over `NWConnection` pinned to Wi-Fi;
   and the Pi's **DNS (dnsmasq) must not resolve Apple's captive-probe domains to the
   Pi** (return NXDOMAIN / no answer, not the gateway IP), so the probe simply fails to
   connect and iOS marks the AP "no internet" **without** the CNA sheet hijacking the
   join. This is an AP/DNS-layer mitigation, **not** an HTTP-server one: with the `Host`
   allowlist (auth section) a probe that reached the server would get a `421` -- a
   non-Success response that would itself pop the CNA sheet -- so the probe must never
   reach the server.
5. **Channels:** open one warm pinned `NWConnection` for control + a second for the SSE
   event/heartbeat stream.
6. **Handshake order:** `GET /v1/capabilities` -> `POST /v1/time` (mandatory, no RTC) ->
   `GET /v1/status`. Until time sync succeeds the app shows "time unverified" and tags
   pulled clips accordingly. **Any queued incident locks flush only after
   `POST /v1/time`**, so a retroactive `at_epoch_ms` resolves against a valid monotonic
   -> wall map; the Pi also accepts pre-sync locks defensively and preserves footage
   regardless (see incident-lock).
7. **Reconnection:** missed heartbeats (~3 x 2 s) -> mark offline + back-off reconnect
   (`NWConnection` state handler + `NWPathMonitor`). A changed `boot_id` on reconnect
   means the Pi rebooted -> re-run time sync + capability check. Pulls resume via
   `Range`/`If-Range`.

### Auth / trust (v1)

- **WPA2-PSK with a per-unit random password** is the v1 trust boundary: a phone that
  lacks the password cannot associate, so it cannot control the unit or pull clips. The
  password is provisioned via the QR sticker (SSID + password), consumed by
  `NEHotspotConfiguration`.
- **No TLS and no separate app token in v1** (explicit owner decision). Documented
  tradeoff: a party who *has* the password (e.g. a passenger handed the QR) gets full API
  access and could sniff footage in transit on the same AP.
- **HTTP hardening (covers the no-token gap against browser-originated requests).** WPA2
  gates network association, not request *intent*: any software on an associated phone --
  including a malicious web page in the browser -- could otherwise hit
  `http://<pi>/v1/recording/stop`, `/system/reboot`, `/storage/format`. v1 rules,
  enforced Pi-side:
  1. **Host allowlist (primary anti-DNS-rebinding defense, all requests):** reject any
     request whose `Host` header is not the Pi's AP gateway IP (`10.42.0.1`) or
     its mDNS name (e.g. `dancam.local`). This is the rule that stops DNS rebinding: a
     rebound page is *same-origin* to the Pi's IP (so CORS/preflight checks pass and
     `Sec-Fetch-Site: same-origin`), but it still sends `Host: <attacker-domain>`, which
     is not on the allowlist. CORS checks alone do **not** cover rebinding; the Host
     allowlist does. Reject with `421 Misdirected Request`.
  2. **Preflight-forcing headers on mutations:** every mutating endpoint requires
     `Content-Type: application/json` **and** the custom `Idempotency-Key` header -- both
     force a CORS preflight a cross-origin browser cannot satisfy.
  3. **Origin / Sec-Fetch checks:** if an `Origin` is present, its host must be on the
     same allowlist as (1); reject `Sec-Fetch-Site: cross-site`.
  4. **Never emit `Access-Control-Allow-*` headers**, so a browser also cannot read
     footage GET responses cross-origin.

  Native clients (the app's `NWConnection` sending the correct `Host`, AVPlayer on
  loopback) are unaffected; only browser cross-origin / rebound access is shut.
- **Non-breaking upgrade path:** the `Authorization` header slot and `/v1/auth/*` paths
  are reserved; adding a per-unit bearer token (authz), then TLS with a pinned
  self-signed cert (confidentiality vs a same-AP attacker; the fingerprint can ride the
  same QR), are additive and require no protocol break. Adding TLS later must keep
  AVPlayer on the loopback HLS pattern (AVPlayer + HLS + self-signed is broken), so the
  pull is TLS but playback stays on loopback. This is the first hardening to do when
  footage privacy from a password-holder matters.

### Versioning

- URL prefix `/v1/...`; a breaking change -> `/v2` (the Pi may serve both during
  migration).
- `GET /v1/capabilities` returns supported proto versions + firmware semver + named
  feature flags, so a newer app degrades gracefully against older firmware.
- Bonjour TXT keys (`proto`, `fw`, `did`, `preview`, `feat`, `boot`) let the app detect
  capability/version before opening a socket.
- Additive JSON fields are non-breaking (clients ignore unknown keys); renames or
  semantic changes require a major bump.

### Status / link-health push ("camera offline")

A Pi that loses power or Wi-Fi cannot send a goodbye, so offline is inferred
client-side: (1) **missed SSE heartbeats** (primary) -> `camera_offline`;
(2) `NWPathMonitor` reporting the Wi-Fi path down (faster corroboration);
(3) `NWBrowser` service-removed (secondary). Offline raises the CarPlay alert (per the
CarPlay ADR item 4) + a local notification, because the dangerous case is recording
silently stopping. On reconnect, a gap in `newest_ts` flags "possible gap in coverage."

### Constraint reconciliation

- **SD is the source of truth:** every endpoint is preview/read/pull; nothing is on the
  record path; all can fail with zero effect on what is written; only finished segments
  are served. The in-progress segment is not pullable -- with one benign exception: an
  incident lock force-finalizes the current segment (a recording-pipeline close/reopen,
  not a transport write to the card) so the just-marked footage becomes a finished,
  pullable segment within seconds.
- **Wi-Fi is 2.4 GHz preview + pull only:** preview is low-res capped MJPEG; pull is
  on-demand + resumable + by selection (no bulk mirroring); control/SSE are tiny. The
  pre-sync incident hold is deliberately **not** exposed as a segment list precisely so a
  client never bulk-pulls the whole ring.
- **CarPlay is voice/status/control, not video:** no video endpoint feeds CarPlay;
  preview is iPhone-screen-only; CarPlay consumes `GET /v1/status` + the offline
  inference + the single low-latency incident-lock.
- **Recording survives power loss:** transport consumes the crash-safe pipeline's
  finished `.ts`; `boot_id` + time-sync recover cleanly after unclean shutdowns. The
  incident-lock idempotency contract is explicitly **reboot-crossing** (a mid-incident
  power cut must not double- or zero-count the event), and a lock queued before the cut
  and flushed against the freshly-rebooted, not-yet-synced Pi still **preserves the
  footage** (the Pi protects all in-ring footage on a pre-sync `at_epoch_ms`, then binds
  the precise window once time sync lands) -- because here the power cut is the expected
  case, not an edge case.
- **Alignment with the crash-safe ADR (clip playback):** that ADR mandates `.ts`-only
  and "HLS for preview and pull, remux to MP4 only for export." This ADR matches it for
  pull: clips are served as `.ts`, played back via a **local HLS playlist** (no remux on
  the playback path), and MP4 remux is **export-only** and spike-gated. No supersede
  needed -- this ADR realizes the playback path the crash-safe ADR delegated to it.
- **Divergence with the crash-safe ADR (preview) -- explicit, surfaced:** that ADR
  anticipates HLS for *live preview* but delegates the realized preview/playback
  transport to this ADR. This ADR keeps **MJPEG** for preview because (a) the single
  H.264 encoder is committed to the 1080p30 recording, so a low-res HLS preview would
  need a second hardware encode (impossible) or heavy software H.264, whereas MJPEG of
  the free lores stream never touches the encoder; and (b) low-bitrate H.264 smears the
  low-light detail the preview exists to assess. The "same segments feed preview" premise
  holds for pull/playback (recorded `.ts`) but not for preview (recording is 1080p;
  preview must be low-res for the 2.4 GHz link). MJPEG preview is accepted (reviewer
  concurred). To avoid two accepted docs disagreeing, a **dated note appended to the
  crash-safe ADR** scopes *only its live-preview transport language* to this ADR; its
  recording/container/crash-safety decisions stand untouched.
- **Thermals:** preview is optional/on-demand and CPU-bounded; the preview-encode spike
  (below) explicitly guards against preview adding heat during recording, with
  preview-when-stopped as the safe fallback.
- **No contradiction with the CarPlay ADR:** this ADR provides the exact single
  low-latency lock call and the camera-offline signal that ADR requires; it consumes
  (does not redesign) the ring-buffer / incident-lock interface.

## Consequences

- **The Pi server stays simple.** Four plain HTTP behaviors -- request/response JSON,
  an SSE stream, a `multipart/x-mixed-replace` MJPEG stream, and resumable `Range` GETs
  -- all serve-able by a small service on 512 MB with no extra muxing machinery and no
  second encoder. This is the "simple/debuggable" win, and it is on the **Pi** side.
- **The app hand-rolls an HTTP/1.1 client (recorded in full in the app-side ADR).**
  Because `URLSession` cannot pin to the Wi-Fi interface, the app builds an HTTP/1.1
  client on the pinned `NWConnection` for *every* plane: request/response framing +
  keep-alive (control), `text/event-stream` parsing (SSE), `multipart/x-mixed-replace`
  boundary scanning (MJPEG), and the resumable `Range`/`If-Range`/`Content-Range` loop
  (clip pull, the riskiest). The simplicity win is the Pi's; the client cost is real and
  named here so it is recorded, not implied-free. Scope is bounded: HTTP/1.1, a fixed set
  of known endpoints, four plane parsers -- not a general HTTP stack.
- **Incident-lock is the latency-critical path** and the contract carries real
  subtlety: reboot-crossing idempotency, force-finalize-once-per-key, and pre-sync
  preservation with a `pending_resolution` wire shape. These are observable contracts
  here; the storage/ring-buffer ADR owns the mechanisms (segment finalize, eviction
  holds, pending-resolution binding, reference counting). That ADR must honor every
  contract this one fixes.
- **Several premises are spike-gated** (below). The headline risk is whether MJPEG
  preview can run concurrently with the 1080p30 recording; the `preview.concurrent`
  capability lets the app adapt if it cannot, falling back to preview-when-stopped (which
  still fully covers the positioning/night use case).
- **Auth is deliberately minimal** (WPA2 + random password + HTTP hardening, no TLS, no
  token). The upgrade path (token, then pinned-cert TLS) is additive and pre-wired
  (reserved `Authorization` slot, `/v1/auth/*` paths, loopback-HLS playback that already
  survives the AVPlayer+TLS break). The cost is on record: a password-holder sees footage
  in transit until that hardening lands.

## Alternatives considered

- **Preview transport: HLS/LL-HLS, WebRTC, RTSP/RTP.** Rejected -- see the transport
  table. HLS specifically needs a second encode (impossible on the single H.264 session)
  or software H.264, and smears the night detail the preview exists to check; WebRTC is
  too heavy for a 512 MB / A53 board and needs a third-party iOS SDK; RTSP/RTP has no
  native iOS player.
- **Push transport: WebSocket, long-poll.** Rejected -- SSE is sufficient and lighter,
  and `URLSessionWebSocketTask` cannot pin the interface; long-poll wastes the link and
  detects offline worse.
- **Clip playback (a): remux `.ts` -> MP4 for *playback*.** Rejected -- it contradicts
  the crash-safe ADR and is unnecessary (AVFoundation plays TS via local HLS). MP4 is
  export-only.
- **Clip playback (b): stream on-demand HLS VOD straight from the Pi**
  (`GET /clips/playlist.m3u8`). **Rejected for v1** -- AVPlayer cannot use the pinned
  `NWConnection`, so it would reintroduce the no-internet-AP routing problem (and would
  break under the future self-signed-TLS upgrade). Playback is pulled-bytes + loopback
  HLS only; the Pi serves no `.m3u8`.
- **Client transport: an in-app loopback reverse-proxy** -- pin one upstream
  `NWConnection` to Wi-Fi and re-expose the Pi at `127.0.0.1`, so `URLSession` owns the
  resumable pull (mature `Range`/resume) and `AVPlayer` streams HLS straight through,
  both talking only to loopback. Attractive: it consolidates onto the loopback server the
  design already builds for playback, and it dissolves the "no straight-from-Pi HLS"
  limitation. **Deferred for v1, not adopted** -- the proxy does not remove the HTTP
  work, it *relocates* it: a correct L7 proxy must still parse both directions (to
  rewrite `Host` to satisfy the Pi's allowlist and rewrite HLS playlist URLs to loopback)
  and pool concurrent loopback connections onto pinned upstreams, while also passing
  through long-lived MJPEG/SSE responses. That is a single higher-stakes always-on
  component versus four contained per-plane parsers, and it is a deliberate architecture
  bet better made with the owner than folded in mid-review. Recorded here so a revisit
  (if the hand-rolled client surface proves burdensome) starts from the tradeoff, not
  from scratch.
- **Security: TLS + pinned cert + token in v1.** Deferred by owner decision; recorded
  above as the upgrade path.

## Spikes flagged

1. **Preview encode spike (headline).** Can MJPEG preview of the lores stream
   (~640x480 @ ~10 fps) run concurrently with the 1080p30 H.264 recording on the Zero 2 W
   without dropping recording frames or overheating? **Test the cheap path first.** The
   VideoCore SoC has a *hardware* JPEG block that is a separate function from the H.264
   encoder (exposed via the V4L2 `bcm2835-codec` / Picamera2's `MJPEGEncoder`); the
   "single H.264 session" limit is about the H.264 encoder specifically, so hardware JPEG
   *may* run alongside it and make the headline CPU cost largely vanish. So the spike is
   **(a)** determine whether the hardware JPEG encoder runs concurrently with the H.264
   session and measure that path, and **(b)** only if hardware JPEG is unavailable or
   contends, fall back to measuring *software* JPEG of the lores stream. Either way MJPEG
   stands -- it never needs a second H.264 encode; the spike decides whether
   preview-while-recording is free, cheap, or must fall back to **preview only when
   recording is stopped/parked** (which still fully covers the positioning/night use
   case, usually done parked). The Pi advertises `preview.concurrent` via capabilities so
   the app adapts.
2. **2.4 GHz in-car throughput.** Sets preview res/fps/quality caps and confirms pull
   times for ~30-60 s 1080p `.ts` segments.
3. **`NWConnection` Wi-Fi pinning + no-internet AP.** Confirm pinning reliably routes to
   the Pi across iOS versions, and that the AP/DNS captive-probe handling (dnsmasq must
   not resolve Apple's probe domains to the Pi) yields a silent "no internet" without the
   CNA sheet; decide whether `URLSession` background pull is viable or `NWConnection`
   chunked pull is required.
4. **`NEHotspotConfiguration` cold join time.** Bounds the incident-lock cold path; sets
   the retroactive-lock window.
5. **Clip media paths on-device.** (a) Confirm local-HLS playback of pulled `.ts` via a
   loopback HTTP server + AVPlayer works on-device -- low risk (the crash-safe ADR
   endorses it; the SDK supports `video/mp2t`), but verify before building on it; (b)
   **gating for the export feature only:** confirm `.ts` -> MP4 passthrough remux
   (AVAssetReader/Writer, no re-encode) is reliable for our segments; ffmpeg fallback if
   fragile. Core playback does not depend on (b).
6. **mDNS reliability post-association in-car.** Is the fixed-IP fallback a rare path or
   the common path?
