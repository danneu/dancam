# Pi recording

The camera unit owns at most one active 1080p30 H.264 recording pipeline. Once a
recording is active, its media path never depends on the phone or the Wi-Fi link: the
Pi captures, encodes, and writes short MPEG-TS segments to its local microSD card,
while the app observes state and pulls only finished footage.

This page owns the camera process boundary, capture and encode configuration,
recording format, recorder state machine, child supervision, and record-command
lifecycle. [Pi storage](storage.md) owns durable segment identity, timestamps,
startup repair, deletion, and ring garbage collection. The
[transport boundary](../boundary/transport.md) owns the HTTP routes and SSE framing
that expose recording state.

## Camera ownership and streams

One long-lived Python Picamera2 subprocess owns libcamera. The Rust service owns the
HTTP API, recorder state, storage coordination, command deadlines, child restart
policy, and preview fan-out. Keeping the camera stack out of process prevents a
libcamera, Picamera2, or PyAV/libav failure from taking down the control and diagnostic
API.

The child configures the camera once and starts it once with two simultaneous
streams:

- `main`: 1920x1080 YUV420 at 30 fps, consumed by the H.264 recording encoder;
- `lores`: 640x480 YUV420, consumed by the MJPEG preview encoder at a configurable
  output cadence that defaults to 10 fps.

Picamera2 uses four buffers and disables its completed-request queue. Recording and
preview therefore share one sensor owner without sharing encoded bytes or requiring
a second H.264 session. Preview stays active while recording starts and stops. The
child keeps only the newest encoded preview frame in its bounded handoff, and the
Rust service likewise publishes the latest complete JPEG to consumers.

The process protocol deliberately does not expose Picamera2 details to HTTP:

- stdout is raw concatenated JPEG frames from the lores stream;
- stdin is newline-delimited JSON commands for start, stop, shutdown, durable-event
  acknowledgement, next-segment reservation, and transaction rejection;
- stderr is a mixed stream: JSON records carrying an `event` key must decode as a
  supported lifecycle or telemetry event, while all other lines are camera logs;
- recording bytes never cross the process boundary and are written directly under
  `DANCAM_REC_DIR`.

The deployed child is `python3 /usr/local/lib/dancam/camera.py`. The program can be
replaced through `DANCAM_CAMERA_CMD` for development, and the protocol is intended to
survive a future all-Rust camera owner. That rewrite may remove Python and PyAV,
but it must not collapse the crash boundary into the Rust HTTP service.

## Focus policy

The Arducam IMX708 Autofocus Wide is operated as a fixed-focus dashcam. The camera
configuration sets `AfMode` to `Manual` and `LensPosition` to `0.0` diopters,
locking the lens at infinity before either stream starts.

Recording and preview share that lens position because focus is a sensor control,
not a per-stream setting. There is no focus environment variable, command-line
option, HTTP setting, or app control. A product retune is a code change backed by a
throwaway focus sweep and road evidence; the camera must never hunt onto rain,
windshield dust, glare, or a nearby hand during a drive.

## Encode and segment format

Starting a recording attaches a Picamera2 `H264Encoder` to the main stream with:

- 10,000,000 bit/s target bitrate;
- repeated SPS/PPS headers so every segment begins independently decodable;
- an intra period of 30 frames;
- no audio.

The encoder feeds a camera-owned output built directly on distro PyAV/libav. The
owner imports and initializes PyAV before `ready`, opens one ordinary output-only
MPEG-TS container per segment, and muxes each encoded H.264 access unit without an
input demuxer or subprocess. The Picamera2 output callback copies each complete
access unit into a bounded queue; overflow is fatal rather than dropping recording
frames. A dedicated mux worker assigns packet PTS and DTS from a 30 fps frame
counter, performs the PyAV and transaction work, closes the old container before
reserving or opening the next, and rolls on the first keyframe at or after 900
frames. Keeping storage latency off Picamera2's callback path preserves preview
delivery through publication, periodic sync, and rollover.

MPEG-TS is the hot recording container because it remains structurally usable when
power cuts through its tail. Short segments bound the footage exposed to one
in-flight failure, and inline codec headers keep each closed segment independently
decodable. The Pi serves those raw `.ts` bytes; the phone remuxes a pulled clip into
a local fast-start MP4 for playback, caching, and sharing.

Raw H.264 is not the recording format. Although its byte stream also tolerates
truncation, it carries no container timestamps, forcing every consumer to fabricate
timing for a potentially variable-rate source. Plain MP4/MOV is also excluded from
the hot path because its final index can be lost with the whole in-flight clip.
Fragmented MP4 remains a possible future format only if measurement and power-cut
testing show it improves the complete system without weakening recovery.

### Per-clip timestamp invariant

Every served clip has a self-contained coded timeline. The owner assigns
`PTS == DTS` in coded order and resets the frame counter for each segment, so each
segment starts at zero.
Within a valid clip, DTS increases strictly frame to frame and the PTS/DTS span never
approaches the MPEG-TS 33-bit wrap.

Consumers treat a duplicate or decreasing DTS, or an implausibly large span, as
corruption or an out-of-contract producer. They degrade locally: the app drops the
offending access unit and the Pi reports unknown duration. Neither condition may
crash a consumer or fail an otherwise recoverable clip. The camera self-test
initializes PyAV and pins the artifact grammar and explicit packet timeline.

## Segment observation and finalization

Rust allocates the durable start segment before dispatch and derives the recording
session from it. The child receives both `session_id` and `start_segment_index`,
and creates that sequence only in a hidden uncommitted artifact. After muxing a
complete first SPS/PPS/IDR access unit, Python flushes PyAV, syncs the file,
atomically renames it to committed-open state, syncs the directory, and emits
`segment_opened` with the positive byte count covered by that sync. Rust validates
the exact session and id, requires the matching committed-open artifact to contain at
least that many bytes, and only then acknowledges or publishes recording state. The
reported count identifies the exact crash-surviving prefix even when later packets
grow the file before Rust observes it. The
[storage page](storage.md#segment-and-recording-identity) owns the witness and
filename grammar.

At rollover and stop, Python closes the container, flushes and syncs the file,
renames committed-open state to the ordinary finalized filename carrying duration,
syncs the directory, and emits `segment_finalized`. Rust validates the finalized
artifact and the event's agreement with its durable duration fact. That validation
returns the accepted artifact view; Rust publishes `clip_finalized` from its id,
storage generation, session, bytes, duration, and ETag without another catalog
lookup, then acknowledges. Finalization fails closed if generation evidence is
unavailable.
Clock-derived `start_ms` is nullable enrichment: an unavailable or unusable offset
leaves it null and `time_approximate` true without blocking finalization.
Only then may Python ask Rust to reserve the next sequence and open its transaction.
`recording_stopped` follows finalization and only clears the recorder after the last
finalization was accepted.

Each lifecycle exchange retries lost messages within one monotonic deadline.
Duplicates receive the already-committed acknowledgement without reapplying their
effect. Stale sessions, wrong sequences, and artifacts in the wrong durable state
change nothing and receive no acknowledgement, which makes the owner fail closed.

Deterministic acceptance can select one named lifecycle operation and occurrence
through `DANCAM_RECORDING_FAULT=OPERATION[:OCCURRENCE]`. The owner injects an I/O
failure at the actual open, write, mux, sync, close, or finalize boundary. It parses
the selector before readiness, and the deployed systemd unit never sets it. This is
an offline validation seam, not an HTTP capability or a runtime fallback.

## Recorder state machine

The Rust service is the authority for recorder state. Its public snapshot contains:

- `phase`: `idle`, `starting`, `recording`, `stopping`, or `error`;
- `session`: `start_segment + 1`, at least 1 after the first accepted start;
- `current_segment`: the live id only after a real segment-open observation;
- `detail`: failure detail only in `error`.

Internally the recorder also carries the allocated start segment and an
`unpullable_floor`. The floor, rather than `current_segment`, protects unfinished
files: it exists while a reserved or committed-open artifact may exist, advances past
an accepted finalization so that footage is immediately pullable, returns to the new
id after its open is accepted, and clears after a clean stop. Clip list, pull, delete,
and garbage collection exclude ids at or above it.

The service and camera child start automatically with systemd, but the recorder
currently starts in `idle`. Recording begins only after `/v1/recording/start`; after a
service or watchdog restart, the app must issue a new start. Automatic recording on
boot remains future product behavior rather than a property of the current image.

Accepted inputs produce ordered domain transitions:

- start moves clean idle or recoverable error to starting;
- only a matching, durably validated first `segment_opened` moves starting to
  recording and completes the start request; `recording_started` is obsolete and
  cannot establish public state;
- a standalone accepted `segment_finalized` publishes the clip and clears the live
  id before any successor can be reserved or opened;
- a later accepted segment open records the newly reserved current id;
- stop moves starting or recording to stopping;
- a matching stopped input returns to idle only after the last segment finalization
  has already been accepted; missing finalization keeps the recorder in error;
- child error, exit, spawn failure, or camera loss moves the live transition to
  recoverable error, clears `current_segment`, and preserves the protective floor.

Successful owner reconciliation publishes every recovered committed-open clip and
then clears the dead owner's current segment and protective floor in one recorder
transition. A failed reconciliation retains the exclusions and blocks replacement,
so neither stale state nor a transient error can hide recovered footage or expose an
unfinished artifact.

Failure is deliberately a session-less control input. Spawn failure, child exit, and
camera-offline observations have no trustworthy child session to echo, so they apply
to whichever session is live when supervision detects them.

The event hub owns one mutex containing world state and stream sequence. It mutates
the world and broadcasts accepted deltas while holding that mutex. A new connection
subscribes, then captures the snapshot and sequence under the same mutex, so each
transition appears either in the snapshot or on the receiver, never both and never
neither. A separate lean watch value carries only recorder phase and camera state for
in-process exclusion decisions.

File-backed duration and timestamp materialization happens outside the hub lock. The
[transport boundary](../boundary/transport.md#canonical-live-state) describes how a
snapshot and the ordered deltas reach clients.

## Command admission and execution

HTTP request tasks own only bounded admission. The camera supervisor is the single
execution owner after handoff.

The command queue has capacity 8. Reserving a slot is bounded by a 250 ms admission
timeout, strictly shorter than the 3 second execution timeout. A closed queue returns
a channel failure and a saturated queue returns timeout; neither case changes
recorder state. Immediately before handing the intent to the reserved slot, the
request stamps one absolute execution deadline and then awaits one terminal
acknowledgement without starting a second timer.

A start request first allocates its durable segment witness in `spawn_blocking`.
One async start-handoff gate is held from before allocation through successful queue
handoff. This keeps slow SD-card work off async workers, limits allocation pressure to
one blocking task, and preserves allocation order when starts race. The gate is
released before the request awaits execution.

The always-running supervisor polls commands, absolute deadlines, shutdown, respawn
backoff, child exit, and decoded child events in every lifecycle state:

- an intent that expires without a ready child is acknowledged as timeout without
  dispatch or recorder transition;
- with a ready child, the supervisor rechecks the deadline, applies the recorder
  transition immediately before writing the child command, and waits for that
  session's target state within the same deadline;
- a start when already recording or a stop when already idle is an idempotent
  success: it writes no duplicate child command and leaves the healthy session alone;
- child events continue to flow through the supervisor after successful commands, so
  rollover, stop, and telemetry retain one mutation owner.

A stop admitted while start is pending remains queued behind that start. If durable
open succeeds, start completes and stop performs the ordinary durable finalization.
If start fails, owner retirement reconciles its artifacts first and the queued stop
resolves idempotently against error/idle state without inventing stop metadata.

Before reporting any post-transition failure, the supervisor drains every child
event already delivered and checks the session-specific target once more. A delivered
success wins. Otherwise timeout, write failure, child exit, child-reported error, or
service shutdown retires the child, reconciles the recorder to recoverable error, and
only then acknowledges the mapped failure. A retired event stream is never applied
again.

A returned command error is therefore terminal: no command continues in the
background and no starting or stopping transition is left stranded. Cleanup and
reconciliation may finish after the absolute deadline; terminal state is more
important than returning at the exact deadline instant.

## Child supervision and telemetry

The supervisor starts with camera state `starting`. Before initial readiness and
before every replacement, Rust removes uncommitted artifacts and atomically turns
every orphaned committed-open artifact into an ordinary finalized clip. Failure to
reconcile blocks the child and keeps recording not ready. A child `ready` event then
changes camera state to `running`. Child error or exit removes the current preview
frame, moves camera state through `restarting`, reconciles and publishes any durable
current footage, moves the recorder to error, and schedules a fresh child with
exponential backoff from 250 ms to 10 seconds. A child that stays alive
for 30 seconds resets the backoff. Once shutdown is observed, the supervisor checks
it before every spawn and never admits another child. Service shutdown asks the
child to stop, bounds the command and exit phases at 2 seconds each, and keeps the
enclosing join alive for 8 seconds. Success requires a clean exit, stderr EOF,
ordered application of queued terminal events, final metadata publication, child
reap, and joined stdout/stderr readers. A forced kill still reaps the child and joins
both readers, but makes shutdown fail. Cancellation during an active command takes
this same graceful path rather than the ordinary forced-retirement path.

The child and reader handles remain under the supervisor's resource-owning boundary
until cleanup completes. Task failure, timeout, and shutdown all converge on
explicit kill/reap and reader joins; no successful shutdown result is inferred only
from the process disappearing. The mock owner has the same terminal property: it
stops its frame producer and flushes, syncs, finalizes, and joins an active writer.

The child samples `SensorTemperature` about every 2 seconds. A Picamera2
`pre_callback` caches metadata from completed requests; the telemetry thread reads
only that cache and never submits a blocking metadata capture job. It emits a
required, nullable `celsius` field: unreadable or non-finite values become null, while
an omitted field is a protocol violation. The fake driver emits a deterministic
40.0 C through 48.0 C sawtooth through the same protocol. Current sensor temperature
is cleared whenever the child is not running.

The Rust mock backend and Python `--fake` driver exercise the same recorder taxonomy.
Both write small valid, PTS-bearing MPEG-TS segments so finalization, list, and pull
paths run against media-shaped bytes rather than empty placeholders. After a mock
writer flush and sync succeeds, the Rust mock publishes `clip_finalized` from the
facts it owns; duration remains null rather than triggering a media scan. The Python
fake also exposes bounded segment cadence and crash hooks for supervisor tests.

## Power-loss defense

Abrupt, unsignaled power loss is normal. No phone connection, shutdown request,
power-good signal, or supercapacitor is required for correctness. Recording defense
is layered:

1. Short, independently decodable MPEG-TS segments keep a severed tail from
   invalidating earlier footage.
2. The owner calls `fdatasync` at publication, about every 2 seconds while open, and
   again at finalization; every artifact-state rename is followed by directory fsync.
3. [Pi storage](storage.md#in-flight-durability-and-startup-repair) removes
   unpublished leftovers, finalizes committed-open survivors, scrubs unrecoverable
   zero-byte legacy segments, and preserves nonempty truncated footage.
4. The data partition is journaled ext4, separate from a plain read-only ext4 car
   root. Segment-close durability and a small dirty-writeback window protect the
   filesystem-level boundary.
5. The card is high-endurance consumer microSD, treated as a consumable. It does not
   claim power-loss protection, so residual flash translation layer risk is accepted
   and reduced through recoverable partitions, a 5% unwritten tail, oldest-first ring
   collection, and prompt incident pull.

Software cannot make the card controller's hidden mapping updates atomic. A real
power-cut validation campaign must therefore test the whole selected card, filesystem,
and camera pipeline rather than treating the truncation-tolerant container as proof
of complete crash safety.

## Validation obligations

The design remains gated on real Pi Zero 2 W evidence:

- run recording and preview concurrently at the deployed resolutions and cadences;
- measure the Python camera process, PyAV/libav, and Rust service RSS on the 512 MB
  board against the former FFmpeg baseline;
- reject sustained swap, OOM behavior, dropped recording frames, or unstable preview;
- exercise repeated hard power cuts across segment open, rollover, close, witness,
  and filesystem activity, then verify boot and footage recovery;
- road-test infinity focus by day, night, rain, glare, and windshield contamination;
- measure camera-start latency, encoder stability, temperatures, and restart behavior
  before treating the current Picamera2 owner as car-image proven.

These are evidence obligations, not invitations to weaken the committed interface.
If the Python stack fails the RAM, latency, or reliability gates, replace the child
with a durable Rust camera owner behind the same process boundary.

## Decision log

### 2026-06-22 -- Defend recording at the container, filesystem, and card layers

(absorbed from raspi ADR 01, 2026-06-22)

Power can disappear mid-write, and three distinct failure classes need different
defenses: the in-flight video tail, filesystem metadata, and the card controller's
hidden flash translation layer. A "crash-proof" container alone cannot keep the OS
bootable or make flash mapping updates atomic.

The original decision selected short MPEG-TS segments with inline headers, a
journaled recording partition, a read-only root, aggressive sync, and card hardware
chosen for endurance. It selected TS over raw H.264 because embedded timing avoids
fabricated PTS for variable-rate video, and over ordinary MP4 because a missing final
index can lose the entire clip. It also rejected FAT/exFAT plus offline repair because
the phone reads over Wi-Fi and no removable-media compatibility benefit offsets the
power-cut fragility. TS's HLS compatibility was also expected to serve both live
preview and clip playback with little extra glue.

The original operational sketch also called for recording to start automatically on
boot. The current service realizes only service and camera startup; the recorder
stays idle until the app sends a start command. Auto-record remains a future product
policy and is not silently claimed as present behavior.

A supercapacitor-only design was rejected because it neither guarantees that every
cut becomes clean nor protects a writable OS by itself. Fragmented MP4 was deferred:
it can be resilient, but TS was simpler and more truncation-tolerant on the 512 MB
board. Reconsidering it requires measured playback and power-cut benefits.

### 2026-06-22 -- Separate live preview from recording segments

(absorbed from the 2026-06-22 amendment to raspi ADR 01)

The original local-HLS preview path did not pan out. The single H.264 encoder is
committed to full-quality recording, and low-bitrate H.264 smeared the low-light
detail that preview exists to assess. Live preview therefore moved to MJPEG from the
camera's lores stream. MPEG-TS remained the recording container and raw clip wire
format; phone-local playback was resolved separately.

### 2026-06-23 -- Treat every power loss as abrupt and unsignaled

(absorbed from the 2026-06-23 amendment to raspi ADR 01)

The selected car power source is switched USB accessory power. It dies with the car
and exposes no power-fail signal, so there is no useful shutdown daemon or clean
finalization path. The optional supercapacitor and power-good GPIO idea was dropped;
without a signal, hold-up would merely delay the same cut. Lithium batteries were
also excluded because of hot-car fire and swelling risk.

This made the layered recording and storage defenses the normal shutdown mechanism,
not an edge-case fallback. The later card investigation also removed the original
assumption that a consumer card in the chosen tier could supply true power-loss
protection.

### 2026-06-25 -- Isolate a single Picamera2 camera owner behind stdio

(absorbed from raspi ADR 07, 2026-06-25)

The preview spike spawned `rpicam-vid --codec mjpeg` per request, but recording and
preview cannot be separate libcamera owners. Picamera2 could configure a main and
lores stream under one owner while leaving the Rust service responsible for API and
domain state.

The decision introduced the long-lived Python child and the stdout/stdin/stderr
protocol used today. Separate camera processes were rejected because libcamera
permits only one owner. Linking Picamera2 or libcamera into the service was rejected
because a camera-stack fault would then take down the API. Continuing with
`rpicam-vid` was rejected because it lacked the required independent stream contract.

Building the all-Rust camera owner immediately was deferred as a larger, higher-risk
path before hardware concurrency had been proven. The subprocess boundary was kept
as a permanent architectural seam so a later Rust child does not require HTTP or app
changes. The accepted cost was carrying CPython, Picamera2, numpy, and ffmpeg and
making their RAM use a measured gate on a 512 MB Pi.

### 2026-06-25 -- Lock the IMX708 lens at infinity

(absorbed from raspi ADR 08, 2026-06-25)

Autofocus is useful for general photography but dangerous behind a windshield: rain,
dust, glare, or a nearby object can steal focus from the road and bake softness into
the system-of-record stream. The decision fixed manual focus at 0.0 diopters for both
streams and deliberately exposed no runtime tuning surface.

Continuous autofocus and startup one-shot autofocus were rejected because both can
choose windshield artifacts. A tuned hyperfocal position was deferred until road
testing demonstrates a useful depth-of-field gain, and a `--lens-position` option was
rejected because focus is a product invariant rather than an operator preference.

### 2026-06-25 -- Produce segmented TS through Picamera2 and ffmpeg

(absorbed from the 2026-06-25 amendment to raspi ADR 01)

The new camera owner realized the existing format choice with Picamera2's H.264
encoder feeding `FfmpegOutput`, inline headers, and MPEG-TS segment muxing. This was
an implementation change, not a reopening of the format decision. It preserved the
short-segment and truncation-tolerance requirements while deferring full ring,
partition, and card hardening to their owning work.

### 2026-06-26 -- Make MP4 a phone-local derivative

(absorbed from the 2026-06-26 amendment to raspi ADR 01)

Standalone TS-through-HLS playback on the phone was replaced by pulling raw TS and
remuxing it without re-encoding into local MP4. The Pi remains optimized for crash
safety and serves its native recording bytes; the app owns the seekable playback,
cache, and sharing artifact. This removes player convenience from the hot recording
path without sacrificing timestamp fidelity.

### 2026-06-30 -- Define a strict self-contained timestamp contract

(absorbed from the 2026-06-30 amendment to raspi ADR 01)

Per-clip DTS behavior had become an implicit dependency of both the app assembler and
the Pi duration scanner. The decision made it explicit: ffmpeg assigns equal PTS and
DTS in coded order, resets each segment near zero, and produces strictly increasing
DTS within the clip. A 33-bit wrap needs no special repair because it is simply one
form of an impossible discontinuity under this contract.

Consumers gracefully drop the offending access unit or return unknown duration
rather than crashing or rejecting all recoverable footage. A camera self-test pins
the exact ffmpeg argument vector so the producer invariant is regression-guarded.

### 2026-06-30 -- Carry Rust-owned recording identity through the child protocol

(absorbed from the 2026-06-30 amendment to raspi ADR 07)

The original stdio protocol let the child allocate file numbers and exposed only
whole-recording confirmations. Rust needed one authority for recording sessions and
the clip exclusion floor, so `start_recording` gained `session_id` and
`start_segment_index`, and every recording or segment event echoes the session.

A directory watcher synthesizes rollover observations above the provided baseline
without controlling ffmpeg. It cannot prove the final close, so
`recording_stopped` deliberately finalizes the last observed open segment. The fake
driver gained controllable segment cadence while retaining its crash hook, letting
the same lifecycle contract run without camera hardware.

### 2026-06-30 -- Make recorder transitions authoritative domain events

(absorbed from raspi ADR 10, 2026-06-30)

Inferring the live segment from the newest directory entry could hide a finalized
clip after a rollover crash or expose a file before the recorder observed it. Rust
therefore took ownership of the recorder FSM, session and start allocation, while a
session-scoped watcher converted ffmpeg-created files into lifecycle observations.

The final open segment intentionally lacks `segment_closed`; a successful stop is
its finalization proof. Rollover and stop finalization became atomic FSM inputs. A
separate unpullable floor was retained because clearing `current_segment` on failure
must not expose the dirty partial file.

Polling status was rejected as live truth because it recreates ordering races.
Deriving the clips floor from the public current-segment field was rejected because
error state clears that field. One combined camera-and-recorder failure event was
rejected because supervision and recorder failure inputs own different facts. The
event hub instead emits the state transition owned by each input, and the transport
projects those ordered changes through snapshot-first SSE.

The original process-local session counter was later replaced by
`start_segment + 1`, preserving the state-machine design while making recording
identity durable across a same-boot service restart.

### 2026-07-04 -- Accept consumer-card FTL risk and use a plain read-only root

(absorbed from the 2026-07-04 amendment to raspi ADR 01)

Investigation found no credible power-loss-protection claim for consumer
high-endurance microSD cards in the selected tier. Industrial PLP cards exist at a
different cost and supply level, so v1 accepted the residual controller risk and
strengthened the recoverable layout, unwritten tail, card-as-consumable operations,
and prompt footage pull instead of pretending the hardware made power cuts atomic.

The car root also became plain read-only ext4 rather than Raspberry Pi OS overlayfs.
The separate journaled `/data` partition and segment sync requirements remained.

### 2026-07-08 -- Sync the open segment and scrub empty power-cut witnesses

(absorbed from the 2026-07-08 amendment to raspi ADR 01)

A real hard cut disproved the promise that the in-flight file would always be
playable to the cut: the stamped path survived as a zero-byte file even with the
filesystem dirty-writeback clamps verified. The correction added periodic open-file
`fdatasync` and a witness-first startup scrub for unrecoverable empty leftovers.

Nonempty truncated footage is still retained. The failed field assumption is kept
here because container choice and close-time sync alone must never again be mistaken
for evidence that the active tail reached the card.

### 2026-07-09 -- Sample sensor temperature without blocking Picamera2

(absorbed from the 2026-07-09 amendment to raspi ADR 07)

The camera protocol added a nullable sensor-temperature event so the system can
observe the component with the lowest heat ceiling. Calling `capture_metadata` for
each sample would create Picamera2 jobs and could disturb the camera event loop, so a
pre-callback caches completed-request metadata and a separate sampler only reads the
cache.

Null represents unreadable or non-finite data; omitting the field is a protocol
error. Shutdown stops the sampler before camera teardown, and camera state owns
whether the current reading remains live.

### 2026-07-14 -- Give the supervisor sole ownership after command handoff

(absorbed from raspi ADR 23, 2026-07-14)

Record commands previously had split ownership: the requester changed the FSM and
ran a timeout while the supervisor independently wrote commands and applied child
events. Queue failure could strand a transition, a request could return timeout while
the child kept executing, and spawn backoff stopped polling already-admitted work.

The decision separated bounded admission from supervisor-owned execution, used one
absolute deadline, moved durable allocation to the blocking pool, and added the
start-handoff gate to preserve allocation order. It also made the stderr reader a
decoder rather than an independent hub mutator. Delivered target events are drained
and checked before failure; otherwise the child is retired and recorder state is
reconciled before acknowledgement.

Requester-owned execution timeout and pre-admission FSM transitions were rejected
because both allow work to outlive its response. An independent stderr hub writer
was rejected because scheduler order could let a late abandoned-child event beat a
terminal failure. Holding the storage mutex across async execution was rejected in
favor of the narrow async handoff gate.

### 2026-07-16 -- Make cancellation a strict camera retirement

Service shutdown previously reached the camera only after the HTTP server drained.
With a long-lived client that point never arrived, while systemd could terminate
the child directly and cause the unaware supervisor to respawn it. The old
mid-command shutdown path also selected forced retirement, which could discard the
terminal events needed to finalize active footage.

Cancellation now prevents every later spawn and always sends the child shutdown
command. Retirement does not report success until the child exits cleanly, stderr
reaches EOF, queued events are applied in order, final metadata is published, the
process is reaped, and both readers are joined. The 8 second enclosing deadline
outlasts the two legitimate 2 second child phases while remaining below systemd's
10 second bound. Forced kill remains cleanup, but never becomes a successful
shutdown result.

Treating process disappearance as success was rejected because it loses protocol,
reader, and finalization failures. Aborting reader tasks immediately was rejected
because terminal events can still be queued after the child exits. Keeping the
mid-command force-kill shortcut was rejected because cancellation is precisely the
case where preserving the last active segment matters.

### 2026-07-16 -- Replace hidden FFmpeg segmentation with transactional PyAV

The FFmpeg input demuxer and segment muxer delayed first durable publication by about
4.5-5 seconds and hid open, close, and rollover behind filesystem observation. A
direct PyAV qualification on the real Pi kept every cold and warm durable-publication
trial below 1 second while preserving the exact 30 fps, SPS/PPS/IDR, and independent
decode contract.

The decision made direct per-segment PyAV the sole production muxer and made hidden
artifact states the durable transaction ledger. Python owns media and artifact
transitions; Rust owns reservation, validation, acknowledgement, recovery, and public
state. Finalize-before-reserve ordering ensures that a failed successor open cannot
hide footage that already closed.

Keeping FFmpeg plus a watcher was rejected because it retains both the startup floor
and false lifecycle observations. Publishing a container header or incomplete access
unit was rejected because it would make start success survive only in memory, not as
independently decodable footage. A runtime fallback ladder was rejected because it
would restore the hidden lifecycle the transaction removes.

### 2026-07-16 -- Isolate transactional mux work from camera callbacks

The first committed real-Pi acceptance run kept recording exact but exposed preview
stalls above the 200 ms gate. Moving periodic sync to its own thread removed random
SD-writeback stalls, but first publication and rollover still produced 249 ms and
233 ms gaps because those synchronous transaction boundaries ran inside Picamera2's
encoded-frame callback.

The decision made the callback a bounded access-unit handoff and moved PyAV muxing,
sync, lifecycle acknowledgement, rollover, and finalization to a dedicated worker.
Queue overflow remains fatal, and stop joins the worker before idle, so callback
isolation does not weaken recording truth. Under the same loaded real-Pi harness,
preview delivered 10.00 fps with a 184 ms maximum interval while recording retained
its exact 30 fps timeline.

### 2026-07-16 -- Keep lifecycle fault injection dormant in production

The transactional protocol requires end-to-end proof at the concrete PyAV and
filesystem operations, but permissions and process kills cannot deterministically
reach write, mux, sync, or close boundaries. A disabled-by-default environment
selector now fails one named operation and occurrence inside the committed owner.
The service then observes the real owner exit, artifact state, reconciliation,
public state, and replacement behavior.

An HTTP fault endpoint was rejected because it would expose destructive validation
behavior on the product surface. Throwaway owner patches were rejected because they
cannot prove the committed service/owner boundary. The production unit omits the
selector, so normal recording does not take an alternate muxer or lifecycle path.

### 2026-07-16 -- Attest publication bytes and release recovery exclusions

The initial transaction protocol validated the committed-open name but did not carry
the exact byte boundary covered by publication sync. It also preserved the pull floor
when an owner failed, which was correct until reconciliation finalized and published
that owner's current clip; leaving the floor afterward kept the recovered clip hidden.

The decision added a positive `durable_bytes` attestation to `segment_opened`. Rust
requires the matching artifact to contain the full attested prefix before accepting
the open, while allowing ordinary file growth after emission. Successful owner
reconciliation now publishes recovered clips before one explicit recorder transition
clears all exclusions belonging to the dead owner. Reconciliation failure retains
those exclusions and blocks readiness.

Treating the artifact's later total length as the publication boundary was rejected
because packets may arrive before Rust handles the event. Clearing the floor on child
error was rejected because it would expose committed-open footage before durable
reconciliation. Clearing it before recovered publication was rejected because clients
could race the recovery result.

### 2026-07-17 -- Publish finalization from one accepted artifact view

Rust previously validated a real-camera finalized artifact, discarded the resolved
candidate, and performed another directory lookup to build `clip_finalized`. That
second fallible read could fail the recorder after the first read had already proved
the durable identity, size, duration, and session facts needed for publication.

The decision made validation return the accepted artifact view and made publication
a pure projection of that view plus optional clock enrichment. The child duration
report must still match the durable filename fact before publication, and the event
still precedes recorder advancement and acknowledgement. The Rust mock similarly
publishes its known durable facts after flush and sync while leaving duration null.

Retrying the catalog lookup was rejected because it creates two competing artifact
views inside one finalization. Making missing clock data fatal was rejected because
wall time is enrichment rather than recording truth. Scanning mock media at close was
rejected because the mock does not need to invent a durable duration fact.

### 2026-07-17 -- Bind recordings and finalization to storage generation

Boot tag and session identify a recording only inside one logical recording
namespace. Resetting the namespace can reuse both, and sequence-plus-size validators
can likewise collide with old app media.

Recording identity is now `(storage_generation, boot_tag, session)`, and every
finalized clip carries the same generation in metadata and its validator. The owner
publishes only after the storage coordinator returns verified generation evidence;
unavailable evidence blocks finalization rather than minting an ambiguous clip.
