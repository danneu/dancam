# App-Pi transport boundary

The Pi serves one versioned local HTTP API and the iPhone is its only product
client. The link carries control, live state, low-resolution preview, and selected
finished clips. It never participates in recording: the Pi continues writing to its
microSD card when the phone is absent or the 2.4 GHz link is unusable.

This page owns the wire boundary and the app-side transport obligations. The
[Pi storage page](../pi/storage.md) owns the files and mutation mechanisms behind
clip operations. The [event reference](../../reference/events.md) projects the
canonical event bodies from `contract/events/`; this page owns why the events plane
uses snapshot-first SSE and how clients consume it.

## Boundary at a glance

The deployed service listens on one dual-stack `[::]:8080` socket with
`IPV6_V6ONLY` disabled. It accepts IPv6 and IPv4-mapped clients, matching the A and
AAAA records for `dancam.local`; the direct AP gateway path is IPv4 at
`10.42.0.1:8080`. Development may bind a different address or port.

All endpoints live below `/v1`. Every response, including errors, carries:

- `X-Dancam-Proto: 1`
- `X-Dancam-Boot-Id: <kernel-boot-uuid>`

An explicit `Host` port is checked against the service's actual bound port rather
than a hardcoded `8080`. Additive JSON fields and new event types are non-breaking;
clients ignore fields and event types they do not recognize. Renaming a field,
changing its meaning, or otherwise breaking the contract requires a new URL major
version.

The active route surface is deliberately small:

| Method | Route | Role |
|---|---|---|
| `GET` | `/v1/status` | One-shot read of the canonical snapshot |
| `GET` | `/v1/events` | Snapshot-first SSE stream, ordered deltas, heartbeat |
| `GET` | `/v1/clips` | Paginated metadata for finished clips |
| `GET` | `/v1/clips/{id}` | Immutable MPEG-TS body with resumable ranges |
| `DELETE` | `/v1/clips/{id}` | Durable deletion of one finished clip |
| `GET` | `/v1/preview/live.mjpeg` | Latest-frame low-resolution preview |
| `POST` | `/v1/recording/start` | Admit a recording start command |
| `POST` | `/v1/recording/stop` | Admit a recording stop command |
| `POST` | `/v1/time` | Write the current boot's wall-time offset |

The earlier `/v1/health` route is gone. `/v1/status` is the sole operational probe,
and its `recording_readiness` field is the authoritative answer to whether a record
command can be attempted. The Pi exposes no incident routes, no thumbnail route, no
HLS playlist, and no media format other than raw `.ts` clip bytes and MJPEG preview.

Several additions have decided boundary constraints but are not active v1 routes:

- Capability negotiation will identify supported protocol versions, firmware,
  device and boot identity, the single 1080p30 H.264 session, MJPEG preview limits
  and concurrency, named features, time-sync state, and GPS presence. Bonjour TXT
  keys may expose the small pre-connection subset.
- Settings remain JSON control over recording resolution, HDR, bitrate, microphone,
  preview quality, and auto-record policy. An update returns the effective settings
  and whether camera restart is required.
- A future preview snapshot is one maximum-quality lores JPEG, not an implied
  full-resolution still.
- Data-partition format, reboot, and any shutdown route are dangerous mutations and
  require explicit product design and confirmation when their owning swoops land.
  Format can affect `/data` only, never the OS or persistent-state partitions.
- `GET /v1/time` can expose the derived current time and source when a consumer needs
  it. The active handshake needs only `POST /v1/time` plus snapshot `time.synced`.
- HTTP log retrieval remains deferred. Request and service logs currently flow to
  journald and are read over SSH until a non-SSH consumer justifies a route.

When one lands, it extends this page and advertises any capability needed for an older
app to degrade safely. The `Authorization` header and `/v1/auth/*` namespace remain
unused seams for a future authenticated transport.

## Transport planes

The boundary uses four HTTP/1.1 behaviors chosen independently for their traffic:

| Plane | Transport | Constraint it serves |
|---|---|---|
| Control | JSON request/response | Low-rate operations stay simple and inspectable on a 512 MB Pi |
| Events | SSE on a separate long-lived connection | Server-to-client state needs one-way push and an absence-based liveness signal |
| Preview | `multipart/x-mixed-replace` MJPEG | A low-resolution lores frame stream avoids a second H.264 session |
| Clip pull | HTTP byte ranges over immutable `.ts` | Selected footage can resume across a slow, interrupted 2.4 GHz link |

The app implements these behaviors over `NWConnection`, not `URLSession`, because
Network framework connections can be pinned to Wi-Fi. Its parameters require Wi-Fi
and prohibit cellular, so a no-internet Pi AP cannot silently send Pi traffic over the
phone's cellular route. The cost is a bounded app-owned HTTP/1.1 implementation:

- request/response framing for control;
- `text/event-stream` parsing for events;
- multipart boundary parsing for MJPEG;
- `Range`, `If-Range`, `Content-Range`, and ETag handling for clip pull.

This is not a general HTTP stack. Each parser serves a fixed set of known endpoints
and is tested independently. Clip pull is the highest-risk parser because reconnect
and resume are normal behavior on this link.

## Connection and association

The production association model is a persistent `NEHotspotConfiguration`
(`joinOnce = false`) for the Pi's WPA2 network. The per-unit SSID and random password
come from the unit's QR label. The app declares `NSLocalNetworkUsageDescription` and
`NSBonjourServices`, and onboarding must handle Local Network permission denial.

Once associated, discovery uses `NWBrowser` for `_dancam._tcp` with the fixed
`10.42.0.1` gateway as the prompt fallback while mDNS settles. The current bring-up
client also supports an explicit `DANCAM_CAMERA_API_BASE_URL`, then the
`DANCAMCameraAPIBaseURL` Info.plist value, before falling back to
`http://10.42.0.1:8080`; those development seams sit behind the same networking
dependency.

The event and preview streams each own a long-lived connection. Current control and
clip operations open bounded request-scoped connections and send `Connection: close`;
per-plane keep-alive reuse remains a future latency optimization, not a current wire
requirement. A changed `X-Dancam-Boot-Id` means the Pi rebooted: discard boot-scoped
live state, sync time again, and resume clip pulls only through their representation
validators. A connection attempt and every post-connect receive wait have explicit
deadlines. Backoff and UI freshness policy are app-owned, while heartbeat presence is
the wire fact they consume.

### Service shutdown

The Pi owns a 2 second graceful connection deadline. Cancellation ends SSE and
MJPEG response streams cooperatively, so responsive clients normally observe EOF
before the deadline and reconnect through their existing liveness behavior. The
server owner closes every connection still present at the deadline, including an
unread client or an interrupted clip pull. There is no shutdown-specific 503,
goodbye event, MJPEG frame-boundary guarantee, or universal response adapter.

A clip pull interrupted by server shutdown keeps the bytes already received. Its
existing validator-bound `Range` plus `If-Range` flow resumes that prefix after the
Pi returns; connection close does not create a second recovery protocol.

The AP must not resolve Apple's captive-probe domains to the Pi. Returning no answer
keeps the probe from reaching HTTP and lets iOS classify the network as having no
internet without opening the Captive Network Assistant sheet. This is a DNS/AP
responsibility, not an HTTP route. A probe that reached the service would be rejected
by the Host policy and could itself trigger the sheet.

## Trust boundary and HTTP hardening

V1 uses plain HTTP. WPA2-PSK association is the trust boundary; there is no app bearer
token and no TLS. The development AP uses one manually installed password. Production
provisioning is intended to replace that with a per-unit random SSID and password
delivered by QR, but that does not exist yet. Anyone given the active Wi-Fi password
can use the full API and can observe footage in transit on the AP. This is an accepted
v1 limitation, not a confidentiality claim.

The service still defends against browser-originated requests from software already
on the associated phone:

1. Every request must use an allowed Host: the Pi's direct gateway address or its
   mDNS name, plus `localhost`, `127.0.0.1`, and `::1` for the local development
   service. A disallowed name receives `421 Misdirected Request`. This is the primary
   DNS-rebinding defense; CORS alone does not stop a rebound same-origin request.
2. Every mutation requires `Content-Type: application/json` and a nonempty
   `Idempotency-Key`. These custom request conditions force a browser preflight.
   The key is currently an admission requirement, not a promise that every active
   handler persists a replay result.
3. The Pi emits no `Access-Control-Allow-*` headers, so browser code cannot read
   footage responses cross-origin.

Origin-host and `Sec-Fetch-Site` rejection were part of the original hardening
design but remain deferred. The Host allowlist is the load-bearing rebinding defense;
future Origin checks are defense in depth and must not be described as active before
the middleware exists.

A future privacy hardening can add a per-unit bearer token and then TLS with a pinned
self-signed certificate whose fingerprint rides the same QR label. That is additive
at the reserved authorization seam. It must preserve Wi-Fi pinning for Pi traffic.

## Canonical live state

`GET /v1/events` is the live-state source. The first SSE frame is a complete
`snapshot`; subsequent frames are strictly ordered deltas and periodic `heartbeat`
events. The SSE `id:` line carries a per-boot sequence number. The JSON body has no
sequence envelope and uses its `type` field as the discriminator.

Reconnect does not replay from `Last-Event-ID`. It starts with a fresh snapshot,
which atomically replaces the client's folded world before later deltas are applied.
If the server-side broadcast receiver lags, the stream closes so the client reconnects
and obtains that replacement snapshot instead of folding across an unknown gap.

`GET /v1/status` materializes the same snapshot shape without SSE framing. It is a
one-shot read for deployment, diagnostics, and initial state, not a polling-based
second source of live truth. Recording commands return bare acknowledgements;
accepted transitions and their results become authoritative through the ordered event
stream.

Heartbeat absence is the primary offline signal because a Pi that loses power cannot
send a goodbye. Network-path loss and Bonjour removal may corroborate it sooner, but
they do not replace heartbeat freshness. Event `at_ms` and `t_ms` values are monotonic
milliseconds since Pi boot, paired with `boot_id`; they are ordering and display aids,
not wall-clock evidence.

The snapshot contains recorder state, camera state, recording readiness, boot
identity, uptime, storage, temperatures, memory, per-core CPU, and time-sync state.
Telemetry values are observations coarsened at the service boundary:

- temperature uses 0.5 C steps and exposes current plus maximum since service start;
- memory rounds down to 16 MiB buckets;
- storage rounds down to 64 MiB buckets while its recording-capacity field remains
  exact;
- CPU utilization is reported per runtime-discovered logical core as whole-percent
  current and 1m/5m/15m EWMA values.

Camera or storage observations that affect recording readiness publish the complete
replacement readiness shape in the same event. Sensor current temperature becomes
null when the camera child is not running, while its process-lifetime maximum remains.
The [event reference](../../reference/events.md) is the exact contract for event
bodies, replacement rules, recorder identity, and readiness reasons.

## Recording commands and time sync

`POST /v1/recording/start` and `POST /v1/recording/stop` are mutation-header guarded.
Admission is bounded; the camera supervisor owns execution and publishes
`recording_starting`, `recording_started`, `recording_stopping`,
`recording_stopped`, or `recorder_failed`. Stop finalizes the open segment. The clip
surface excludes every id at or above the recorder's `unpullable_from` floor during
starting, recording, rollover, stopping, and failure, so a partial file is never
listed or served.

The Pi has no RTC. `POST /v1/time` accepts only `{ "epoch_ms": ... }`, validates the
epoch against the supported 2026 through 2100 range, and writes the current boot's
monotonic-to-wall offset once. Success returns `{ "synced": true }` and the
false-to-true transition emits `time_synced`. There is no RTT-refined request body,
timezone field, implicit GPS override, or mutable resync within one boot. The
[storage page](../pi/storage.md#time-derivation) owns how stamped clips use the offset.

The app watches snapshot `time.synced` and posts the phone's current epoch while the
current boot remains unsynced. Until it becomes true, nullable clip wall times are
treated as approximate rather than evidence-grade. Boot-id change restarts that
obligation.

## Preview

`GET /v1/preview/live.mjpeg` serves
`multipart/x-mixed-replace; boundary=dancamframe` with JPEG parts and `no-store`.
Frames originate from the camera owner's low-resolution stream. Preview fan-out is
latest-frame-wins: one conflating slot holds the newest frame, a slow client skips
intermediate frames, and no stale backlog is replayed after a stall.

The low-resolution MJPEG path is on demand and iPhone-only. It does not feed CarPlay
and does not consume the one H.264 recording session. The design target is roughly
640x480 at 10 fps, bounded by measured link, recording, and thermal behavior. A
higher-rate preview would require re-evaluating whether conflation causes healthy
clients to skip too aggressively.

There is no `/v1/preview/snapshot` route today. If a still endpoint lands, its first
safe form is a maximum-quality JPEG from the existing lores frame, not an implied
full-resolution capture that competes with recording.

## Clip listing, pull, and deletion

`GET /v1/clips` lists finished segments newest first. `limit` defaults to 20 and is
clamped at 100. A decimal `cursor` is an exclusive upper sequence bound: the next page
contains ids lower than it. Only descending order is supported. `from` and `to`
wall-clock filters are rejected with 400 until the contract can provide them without
silently returning unfiltered results.

Each clip carries `id`, nullable `boot_tag`, nullable `session`, nullable `start_ms`,
nullable `dur_ms`, `bytes`, reserved `locked` (always false in v1), an unquoted
`etag` of `<id>-<bytes>`, and `time_approximate`. The response also carries nullable
`server_time_ms` and `next_cursor`. Bare segment names honestly produce null stamped
facts. A listing or lookup scan error other than a missing recording directory returns
503 rather than a false empty list or 404.

`GET /v1/clips/{id}` serves `application/mp2t` from an opened finished segment. Full
responses return 200; one satisfiable byte range returns 206 with `Content-Range`;
invalid, multiple, zero-length, or out-of-bounds ranges return 416 with
`Content-Range: bytes */<length>`. Responses carry `Accept-Ranges: bytes` and a
strong quoted ETag `"<id>-<bytes>"`. A mismatched `If-Range` ignores the range and
returns the complete 200 representation, allowing the app to truncate and restart
rather than append bytes from a changed body.

For pull, 404 means the id is absent, has become unpullable, or lost the normal race
with GC or manual deletion. A non-NotFound open, metadata, seek, or scan failure is
503, the only retriable HTTP status in the pull contract. The app retries exactly 503
as resumable no-progress and treats other HTTP failures, including other 5xx statuses,
as terminal. A 416 retains its resumable EOF meaning. An already-open file descriptor
continues streaming after unlink; a later request observes 404.

`DELETE /v1/clips/{id}` is the only active mutation of committed footage. A 204 means
the storage coordinator has raised the sequence witness, unlinked all matching paths,
fsynced the directory, and published `clip_removed`. A missing, active, or newly
reserved id is 404. A scan, witness, unlink, or fsync fault is 503. The endpoint is
off the recording path and never authorizes deletion of the open segment.

The app pulls selected raw TS bytes through this range surface, remuxes them without
re-encoding into its durable local MP4 cache, and plays the local file. AVPlayer never
talks to the Pi. The Pi serves no `.m3u8` and no MP4. Clip thumbnails are also
phone-derived from the local cache or a bounded ranged prefix; the Pi stores and serves
no thumbnail.

## Incident ownership

Incidents are phone-owned records assembled from clip listings, ordered recording
events, and ranged pulls. The Pi exposes no `/v1/incidents` namespace and no
`incident_saved` or `incident_resolved` event. It does not hold footage, force a
segment rollover, persist incident idempotency, or expose an all-ring protection set.
The clip `locked` field remains reserved for a possible future evidence-backed
protect-only pin, but no such endpoint or behavior exists in v1.

## Validation obligations

The transport choice is settled, but final production limits still depend on
hardware and in-car evidence:

- measure lores MJPEG beside 1080p30 H.264 on the Zero 2 W, preferring the separate
  hardware JPEG block and falling back to software JPEG only if necessary;
- use 2.4 GHz in-car measurements to set preview resolution, frame rate, quality,
  and expected pull time;
- measure persistent hotspot cold-join time and post-association mDNS reliability so
  the direct gateway fallback and reconnect bounds are evidence-based;
- recheck the no-internet join across supported iOS releases, including Wi-Fi pinning
  with cellular enabled and captive-probe DNS behavior.

If concurrent preview harms recording or thermals, `preview.concurrent` must report
false and the app limits preview to stopped/parked use. Recording quality and survival
win over preview availability.

## Decision log

### 2026-06-22: Use a versioned local HTTP boundary with specialized planes

(absorbed from raspi ADR 02, 2026-06-22)

The Pi records locally while an iPhone supplies the product UI over the Pi's own
2.4 GHz, no-internet AP. The boundary needed to cover control, status, preview,
events, and resumable clip transfer without adding a second H.264 encode or placing
the network on the recording path.

The decision chose a Pi-served `/v1` HTTP API with JSON control, SSE push, MJPEG
preview, and ranged TS downloads. The Pi has one H.264 hardware session and spends it
on 1080p30 recording, while libcamera can provide a free lores YUV stream from the
ISP. MJPEG can encode that stream without requiring another H.264 session and retains
per-frame detail useful for aiming and night checks. SSE fits one-way state push and
turns missed heartbeats into the only reliable power-loss signal. Immutable finished
segments make strong validators and ranged resume natural for the congested link.

The decision also accepted plain HTTP behind a per-unit WPA2 password, with Host
allowlisting and browser-request hardening, and reserved additive token and pinned-cert
TLS seams. The risk is explicit: a password holder has full API access and can inspect
traffic. The Pi remains simple, while the app accepts the real cost of four bounded
HTTP/1.1 parsers because only `NWConnection` can pin every plane to Wi-Fi.

Alternatives considered:

- gRPC/HTTP2 and a custom binary protocol were rejected as unnecessary machinery on
  a 512 MB Pi for a small, inspectable local API.
- HLS or LL-HLS preview was rejected because it needs another encode and smears
  low-light detail. WebRTC was too heavy and introduced a third-party iOS stack;
  RTSP/RTP lacked a native iOS playback path.
- WebSocket was rejected because the server push is one-way and the native
  `URLSessionWebSocketTask` cannot be Wi-Fi pinned. Long-poll wastes the link and
  detects failure less promptly.
- Background `URLSession` pull was not trusted on a no-internet AP because it cannot
  be pinned to Wi-Fi. It remains viable only if future iOS evidence changes that
  constraint.
- TLS plus a pinned certificate and app token was deferred by owner choice, not
  because WPA2 provides equivalent confidentiality.

### 2026-06-22: Make the iPhone a Wi-Fi-pinned client

(absorbed from app ADR 02, 2026-06-22)

The app-side companion decision deliberately delegated the wire format to the Pi and
recorded the client obligations created by it: persistent hotspot association,
Bonjour plus direct-gateway discovery, Local Network permission, per-plane
`NWConnection` use, bespoke framing parsers, boot-aware reconnection, local media
playback, and heartbeat-based offline presentation.

It chose `NEHotspotConfiguration(joinOnce: false)` so the unit configuration persists
across launches and drives, and `NWBrowser` with a fixed gateway fallback because mDNS
can lag immediately after association. All Pi connections require Wi-Fi and prohibit
cellular. The app owns reconnect deadlines and backoff; a changed boot id invalidates
boot-scoped state and triggers a new time sync.

The original design proposed one warm control connection so a Pi-owned incident mark
could avoid TCP setup. Current requests deliberately close after each response, and
the later phone-owned incident model removed that latency-critical Pi mutation.

The original playback proposal pulled TS, built a local HLS playlist, and served it to
AVPlayer over loopback. Later app decisions replaced that with passthrough remux into
a durable local fast-start MP4, eliminating both the loopback server and progressive
fMP4 experiment. The invariant survives: AVPlayer consumes only phone-local media and
never opens an unpinned connection to the Pi.

The original voice path also queued a client idempotency UUID and asked a Pi-owned
incident endpoint to preserve a retroactive window. Phone-owned incidents later
removed that entire transport obligation; voice marking, if added, creates the same
local record as the phone UI and uses ordinary clip/event reconciliation.

The original offline presentation paired missed heartbeats with a CarPlay alert and
local notification, and proposed comparing newest footage after reconnect to flag a
possible recording gap. Those product surfaces were not transport facts and remain
owned by later app/CarPlay work; the boundary retains only the heartbeat, boot, and
clip evidence they need.

Alternatives considered:

- Duplicating the wire contract in the app decision was rejected because two
  authoritative copies would drift.
- A loopback reverse proxy was deferred because it relocates rather than removes HTTP
  parsing. It would need Host and playlist rewriting, connection pooling, and correct
  pass-through for long-lived SSE and MJPEG in one higher-stakes always-on component.

### 2026-06-23: Reconcile the proposed storage and incident fields

(absorbed from raspi ADR 02 amendment, 2026-06-23)

The early storage design added incident truncation, deletion tombstones, Pi-derived
source metadata, and a max-age retention ceiling to the proposed wire contract. Those
fields were meant to keep late retries from resurrecting deleted incidents, distinguish
requested from preserved coverage, and prevent client metadata from changing lock
semantics. When incidents moved to the phone and byte-floor GC replaced age and
percentage policy, these fields and the proposed terminal-incident signaling became
unnecessary. The surviving storage boundary is the finished-clip list, range pull,
delete route, and `clip_removed` delta.

### 2026-06-25: Validate the AP and preview path on hardware

(absorbed from raspi ADR 02 amendment, 2026-06-25)

Real NetworkManager shared-mode bring-up fixed the gateway at `10.42.0.1`. An iPhone
loaded service state and moving MJPEG over the AP first without pinning as a diagnostic,
then with Wi-Fi pinning while cellular remained enabled. No captive sheet appeared,
and restarting preview exposed and fixed an app decode-order reset bug. The desk run
observed first preview bytes in about 226 ms, about 2.96 MB over 20 seconds, and a Pi
SoC near 38-39 C.

This proved the direct AP, HTTP, MJPEG, and app pinning path. It did not by itself prove
that the final lores preview remains smooth and thermally safe beside 1080p30 H.264
recording; that concurrency remains a hardware validation obligation. Captive-probe
DNS also remains an AP requirement even though the one-shot hardware run did not need
a dnsmasq override.

### 2026-06-26: Keep Pi clip transport raw while playback moves local

(absorbed from raspi ADR 02 and app ADR 02 amendments, 2026-06-26)

App implementation showed that durable local MP4 playback was cleaner than the
original local-HLS path. The change affected only the phone: the Pi continued serving
immutable raw `.ts` bodies with ranges, and AVPlayer continued to avoid the Pi. A later
progressive fMP4 experiment was also removed in favor of one durable cached MP4
artifact shared by playback and export.

Remuxing TS to MP4 for all playback was originally rejected because local HLS could
play the crash-safe bytes directly. Device evidence and the app cache design later
made passthrough remux the simpler durable result. Straight-from-Pi HLS remained
rejected because AVPlayer cannot use the pinned connection and a self-signed TLS
upgrade would compound that routing problem.

### 2026-06-30: Realize events as snapshot-first ordered SSE

(absorbed from raspi ADR 02 amendment, 2026-06-30)

The recorder state machine replaced the original flat status and threshold-alert
ideas with one atomic snapshot, ordered lifecycle and telemetry deltas, and a
heartbeat. Sequence moved exclusively to the SSE `id:` line; monotonic `at_ms` and
`t_ms` stayed display aids. Commands kept bare acknowledgements so read-your-writes
truth arrives through the same ordered stream as all other state.

Snapshot-first reconnect was chosen over event replay because replacing the folded
world resolves any gap without retaining a replay log on the Pi. Raw-state deltas
replaced `storage_full` and `temp_warning`: policy and presentation belong to clients,
while the Pi reports observed state. Unknown-event tolerance keeps additions
non-breaking.

### 2026-07-01: Bind dual-stack and compare the real service port

(absorbed from raspi ADR 02 amendment, 2026-07-01)

Avahi advertises both A and AAAA records. An IPv4-only listener could therefore fail
when iOS tried IPv6 first through Happy Eyeballs. The service moved to one dual-stack
IPv6 wildcard socket with IPv4-mapped acceptance. Host validation still gates names,
but an explicit port is compared with the runtime bound port so development binds do
not inherit a false 8080-only rule.

### 2026-07-01: Withdraw Pi thumbnails and define clip-pull errors

(absorbed from raspi ADR 02 amendment, 2026-07-01)

Client-side thumbnail generation made the proposed Pi JPEG cache and
`/v1/clips/{id}/thumb` route redundant. The app can use its cached MP4 or a bounded
ranged prefix without adding flash writes or another Pi-owned artifact.

The ranged pull also fixed its failure taxonomy: 404 covers absent or no-longer-
pullable footage, including an ordinary GC race; 503 alone represents a potentially
transient present-clip I/O failure and is resumable; 416 retains range EOF semantics.
Treating every 5xx as retriable was rejected because it hides unrelated server faults
inside an unbounded media retry loop.

### 2026-07-02: Simplify time sync and add durable clip deletion

(absorbed from raspi ADR 02 amendments, 2026-07-02)

The storage implementation reduced `POST /v1/time` from an RTT-refined
`{epoch_ms, tz, send_ts}` body to one `epoch_ms`. Segment-open polling already bounded
useful precision, and a write-once boot offset lets every stamped segment derive wall
time later without mutable per-clip metadata. Implicit GPS priority was dropped until
multiple sources have an explicit policy.

The same implementation added finished-clip deletion and `clip_removed`. The route
raises the durable sequence witness before unlink, refuses the recorder's live floor,
and acknowledges only after directory fsync. List and lookup scans began failing
closed with 503 so storage damage could not masquerade as an empty ring or missing
clip.

### 2026-07-09: Add boot identity and coarsen telemetry at the wire

(absorbed from raspi ADR 02 amendments, 2026-07-09)

Snapshot gained nullable `boot_tag`, matching stamped clip identity without repeating
a boot-level fact on every current-segment object. Telemetry was defined as raw
observed state rather than threshold policy, but intentionally quantized: temperature
to 0.5 C, memory to 16 MiB, and storage to 64 MiB. This reduces meaningless churn and
does not promise sensor-sample precision.

### 2026-07-10: Expose temperature maxima and per-core CPU state

(absorbed from raspi ADR 02 amendments, 2026-07-10)

Temperature readings became `{current,max}` pairs so the app can show the current
condition and the worst value observed since service start. Sensor current becomes
unknown when the camera child stops, while its maximum persists until the service
restarts. CPU telemetry became a complete runtime-ID-sorted per-core replacement with
current and 1m/5m/15m EWMAs. New baselines and counter resets publish null values;
whole-read failures clear topology and smoothing history rather than preserving stale
load.

Aggregate CPU load and policy thresholds were rejected because per-core saturation is
the useful fact on the four-core Zero 2 W and clients own presentation policy.

### 2026-07-14: Withdraw Pi-owned incidents

(absorbed from raspi ADR 02 and app ADR 02 amendments, 2026-07-14)

The original boundary reserved lock, list, extend, and delete incident routes plus
`incident_saved` and `incident_resolved`. It specified reboot-crossing idempotency,
force-finalizing the current segment once, conservative all-ring holds before time
sync, post-roll locking, reference-counted release, truncation, and tombstone replay.
That model made the Pi own durable product state and complicated the recording-side
failure surface.

The replacement makes incidents durable phone-local records. The phone marks a
window, observes finalized segments through the existing event stream, and pulls the
covering clips through the existing range surface. All Pi incident routes, events,
holds, hardlinks, and idempotency state were withdrawn rather than left as deferred
compatibility seams. A future protect-only pin remains possible only if real retention
evidence justifies it.

### 2026-07-15: Make canonical status the only operational probe

(absorbed from raspi ADR 02 amendment, 2026-07-15)

The separate health response duplicated live facts and could disagree with the
snapshot consumed by the app. The service removed `/v1/health`, made `/v1/status` the
sole one-shot operational probe, and added one atomically derived
`recording_readiness` replacement shared by status, the initial SSE snapshot, and
camera/storage deltas. This lets deployment and clients answer the same question from
the same state instead of inventing route-specific readiness logic.

### 2026-07-16: Bound shutdown at the server owner

Ordinary Axum graceful shutdown waited forever for SSE and MJPEG bodies, turning a
normal service stop into systemd SIGKILL. The boundary now lets those two streams
observe process cancellation and gives the server owner a 2 second deadline for
every connection. Residual clip pulls and unread clients end by connection close;
the app's existing SSE/MJPEG reconnect and validator-bound range resume remain the
recovery mechanisms.

A universal cancellation body layer was rejected because it adds machinery to
finite responses without strengthening the server-owned bound. Shutdown-specific
503 responses and goodbye events were rejected because a response may already be
streaming and connection loss already carries the required liveness meaning. A
frame-boundary close promise was rejected because the bounded owner must be able to
terminate a stalled connection at the deadline.

### 2026-07-16: Default clip listings to 20 entries

The app does not send an explicit clip-list limit, so the former 100-entry default
made every head refresh do more storage work than its recent-footage surface needs.
The default is now 20 entries. The explicit-request cap remains 100 so diagnostics
and future bounded consumers retain the existing upper range without imposing it on
ordinary app refreshes.
