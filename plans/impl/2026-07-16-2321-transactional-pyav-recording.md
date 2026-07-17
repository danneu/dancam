# Plan: implement transactional per-segment PyAV recording

## Problem, desired outcome, and evidence

The current camera owner feeds raw H.264 to FFmpeg's input demuxer and segment
muxer. That path delays the first segment by about 4.5-5 seconds and hides segment
open, close, and rollover inside components that cannot expose the product's
durability truth points. Filesystem observation therefore permits false start
success, premature segment publication, and finalized footage that remains hidden
when the next open fails.

The real-Pi investigation selected direct per-segment PyAV as the only production
muxer path. With candidate initialization complete before owner readiness, all five
cold durable-publication trials took 358.373-437.510 ms and all five warm trials
took 90.008-142.554 ms. Every synced prefix decoded, the 30-second segment and exact
30 fps packet timeline passed, injected lifecycle failures were fatal, and the
recording-load sanity gate passed. The durable evidence is in
[first-segment delay and shutdown timeout](../../docs/research/3-first-segment-delay-and-shutdown-timeout.md#10-direct-per-segment-pyav-qualification----2026-07-16).

The desired outcome is a committed Rust/Python recording lifecycle in which the
service reports only durably true recording and footage state, direct PyAV opens one
ordinary MPEG-TS container per segment, and the binding end-to-end start latency is
under 1 second in every valid real-Pi trial.

This plan supersedes
`plans/wip/plan-the-ideal-pivot-ffmpeg-stream-info-simplified-2.md` and
`plans/wip/plan-the-ideal-fix-prancy-trinket.md`. It contains no conditional
production muxer branch. A failed acceptance obligation blocks this implementation;
it does not activate a runtime or implementation fallback.

## Decision

### D1. Direct PyAV is the sole recording muxer

The Python camera owner imports and initializes PyAV before it emits `ready`, retains
exclusive Picamera2 ownership, and feeds each hardware-encoded H.264 access unit
directly to an output-only PyAV MPEG-TS container. It supplies the configured 30 fps
timeline explicitly and depends on neither an input demuxer nor rate discovery.

The Pi provisioning contract installs the distro `python3-av` runtime alongside
Picamera2. The deployed interpreter must satisfy the same import-and-initialize path
before the camera owner can report readiness; PyAV is not a pip-installed or ambient
dependency. Repeating the converge from a fresh image is deferred to the next
car-image qualification rather than blocking this recording-path migration.

Each segment owns one ordinary output container. At rollover Python durably closes
and finalizes the old segment, receives Rust's acknowledgement of that finalization,
and only then opens the next container. Every new segment starts on the encoder's
repeated SPS/PPS/IDR content. FFmpeg's CLI, input probing, segment muxer, and
filesystem watcher are removed from the production recording path.

### D2. On-disk artifact state is the sole durable transaction ledger

The Python owner remains the process crash boundary supervised by Rust. Python owns
the fallible PyAV open, mux, write, sync, close, and release operations and advances
each live segment atomically through explicit uncommitted, committed-open, and
finalized on-disk states after the required syncs. Rust owns durable sequence
reservation, public recorder state, acknowledgement, owner replacement, and
reconciliation after either process dies.

The recording directory is the sole durable ledger of segment lifecycle. Rust
accepts an event only when the matching session, sequence, and durable artifact state
agree. Acknowledgements order the live view but create no second transaction journal;
the existing sequence witness remains identity-allocation state only. After an owner
is reaped, Rust removes its uncommitted artifacts and durably finalizes every orphaned
committed-open artifact before replacement or readiness. These states are explicit
producer-owned transitions, not lifecycle inferred from watcher-observed FFmpeg file
creation.

The committed behavior updates the present-tense bodies and appends dated Decision
log entries in [Pi recording](../../docs/design/pi/recording.md) and
[Pi storage](../../docs/design/pi/storage.md) in the same change. The distro PyAV
dependency also updates [Pi provisioning](../../docs/design/pi/provisioning.md) and
the [Pi setup runbook](../../docs/setup/pi-runbook.md).

## Invariants

### I1. Start truth point

The first accepted `segment_opened` of a starting session is the sole transition
from `starting` to `recording`, the sole start-POST success, and the sole source of
recording-state publication. `recording_started`, an allocated path, or a container
header cannot establish recording.

### I2. Publication truth point

`segment_opened` is accepted only after one complete, independently decodable
SPS/PPS/IDR access unit is durable on disk and the segment's existence would survive
a crash. Before that commit the segment is absent from `/v1/clips`, current-segment
state, pulls, and sequence-allocation scans. An uncommitted artifact is never
listable or pullable.

### I3. Recovery of committed footage

Every artifact left by an owner that no longer exists is reconciled exactly once
before replacement or recording readiness, without requiring a service restart. A
committed-open artifact is durably finalized and becomes listable and pullable
whether it was unpublished or previously published as the current segment. An
already finalized artifact remains listable and pullable, and an uncommitted artifact
is removed.

### I4. Finalization ordering

At rollover the old segment durably finalizes and its finalization is accepted as a
standalone transition before the next container may open. A later failure cannot
hide or roll back that footage. Final stop uses the same ordering and completes
before `recording_stopped` or idle is published. Active service shutdown completes
that final stop within `TimeoutStopSec=10` in `raspi/dancam.service`.

### I5. Sequence and cleanup ownership

Rust durably reserves each sequence before Python may create an artifact for it, and
a sequence that reached an open is never reused. After a failed owner is reaped,
Rust reconciles every artifact that owner could have created according to I3 before
replacement or readiness. Cleanup or finalization failure keeps the camera in error
and recording not ready.

### I6. Fatal and observable lifecycle failure

Every open, mux, write, close, sync, reservation, and finalization failure after
start is fatal to the owner or service operation that owns it. The owner exits
nonzero rather than dropping frames, reporting a clean stop, or silently continuing.
The service enters recoverable camera error/not-ready state, replaces the owner, and
never claims recording while no muxer can write.

### I7. Bounded, exactly-once transitions

Every lifecycle exchange has a bounded monotonic deadline whose expiry is fatal.
Across retries, lost acknowledgements, and owner replacement, a stale-session or
wrong-sequence event changes nothing and is not acknowledged; a duplicate accepted
event returns its committed result; and no committed effect is lost or applied
twice. Readiness, telemetry, preview delivery, and idle shutdown remain outside this
transactional contract.

### I8. Queued stop

A stop accepted while start is pending serializes behind the start outcome. A
successful start completes first and then performs normal durable stop finalization.
A failed start cleans up first and then resolves stop idempotently as already
stopped, without metadata, finalization, or `recording_stopped` publication.

### I9. Media contract

Every segment is independently decodable MPEG-TS beginning with SPS/PPS/IDR. Its full
video packet timeline is exactly 30 fps: first PTS and DTS are within one frame of
zero, `PTS == DTS` throughout, DTS strictly increases, and every adjacent delta is
one frame interval. A 35-second run produces a roughly 30-second first segment, and
a second session cannot overwrite any earlier session.

## Proof obligations

All real-Pi acceptance evidence in this section runs against the committed
implementation through the real Rust service. Throwaway code cannot discharge an
obligation. The research note receives only evidence actually produced by this
campaign.

### PO1. Binding latency and publication proof

Run at least five cold first-recording-after-owner-start and five warm second-session
trials as an unloaded baseline, with no concurrent `/v1/clips` requests. Repeat both
five-trial profiles under representative supported load: active preview, periodic
`/v1/clips` listings, and sustained validator-bound ranged reads of an existing
finalized clip. On one shared monotonic clock, measure accepted start-POST receipt to
accepted `segment_opened`. Every valid trial in both profiles is under 1 second, with
a directional unloaded median target near 300 ms. At each publication point, the
exact synced prefix independently demuxes and decodes a complete frame.

### PO2. Public-state honesty and media

For success and injected publication failure, the start POST remains pending and
status/SSE remain `starting` until I1 and I2 are satisfied. Clip durations agree
between `ffprobe` and `/v1/clips`. A 35-second run and every campaign segment satisfy
I9, and a second session preserves the first byte-for-byte. Run the 35-second media
case under the supported-load profile from PO1 and reject any dropped recording frame
or preview result outside PO7's cadence and stall gates.

### PO3. Transactional failure and recovery

Use deterministic end-to-end faults to prove each applicable invariant at initial
start, after publication, rollover, and final stop. Cover every lifecycle operation
named by I6, lost and duplicate acknowledgements, stale session and sequence input,
deadline expiry, owner and service death, cleanup failure, and reconciliation from
each on-disk artifact state. Explicitly cover death after `segment_opened` while the
published current segment remains committed-open. The observable service state,
files, clips, events, owner exit, replacement, and restored readiness must jointly
prove the outcome; a callback or isolated error return is insufficient.

### PO4. Queued and concurrent commands

Prove I8 for both successful and failed starts. Preserve existing idempotent
start/stop behavior and terminal command results under racing requests, queue
pressure, and owner replacement without relying on task timing or internal type
shape.

### PO5. Clean service shutdown

Stop the systemd unit mid-recording with live SSE and preview clients plus one unread
preview response. The service exits successfully within the existing 10-second unit
bound, durably finalizes and publishes the last clip, closes all clients, leaves no
owner or muxer, and does not respawn during shutdown.

### PO6. Abrupt power-loss recovery

Use controlled real hard power cuts at every distinct durability state of the
committed protocol. After restore:

- every committed survivor retains at least the bytes synced before the cut,
  byte-identically, and independently decodes a complete frame;
- every committed-open survivor, including a previously published current segment,
  is durably finalized and listed before recording readiness returns;
- every prior finalized segment remains listed, byte-identical, and playable;
- a cut before commit yields either a valid committed survivor or clean absence,
  never a phantom clip or reused sequence;
- uncommitted artifacts are removed, allocation overwrites no survivor, the
  filesystem mounts normally, and recording readiness returns.

### PO7. Resource and operational correctness

Run the committed PyAV stack at the deployed recording and preview settings for at
least 30 minutes twice: once without external HTTP consumers and once under the
representative supported-load profile from PO1. Sample status, process identity,
RSS, available memory, swap, CPU, and throttling at least every 10 seconds. These are
bench resource and stability soaks, not enclosure or hot-ambient qualification.

Reject an owner or service restart, recorder error, OOM, filesystem or recording I/O
error, thermal throttling, available memory below 128 MiB for more than 60 seconds,
or first-to-last 10-minute median growth above both 10 percent and 16 MiB for combined
RSS or above 32 MiB for swap. Recording stays exactly 30 fps across every full
segment, with representative beginning, middle, and end segments independently
decoding. Under supported load, delivered preview stays within 5 percent of its
configured cadence, its p95 inter-frame interval remains below 2x configured, no
interval exceeds 4x, and listing and ranged-read clients remain successful. A run
whose maximum interval exceeds 2x additionally requires a simultaneous 10-minute
loopback and Wi-Fi rerun under the same workload; reject any repeated 2x interval at
either observer. A new warning is accepted only with behavioral evidence that it is
harmless under these gates.

### PO8. Regression, provisioning, and documentation contract

Behavioral tests preserve preview, telemetry, clip listing/pull, duration persistence,
sequence monotonicity, startup scrub, recorder events, command admission, owner
retirement, and the deterministic shutdown behavior that this change does not
replace. Tests remain structure-insensitive and assert public or durable outcomes.
Provisioning lint passes, check mode reports no drift on the current image, and the
runbook verifies `av` and Picamera2 imports through the deployed Python interpreter
before service acceptance. The recording, storage, and provisioning design bodies
describe only the new present-tense design, their Decision logs preserve why FFmpeg
segmentation was replaced, and the runbook carries the matching operational checks.

## Non-goals

- Do not change Picamera2 ownership, move capture into Rust, move recording into the
  HTTP service, or change app behavior to conceal start latency.
- Do not retain a production FFmpeg CLI, segment-muxer, explicit-libav-helper, or
  alternate native-muxer fallback.
- Do not relax the under-1-second gate, publish a path/header/incomplete access unit,
  or run durability acceptance against a prototype.
- Do not redesign preview, telemetry, clip wire format, incident ownership, ring
  policy, or the phone-local MP4 derivative except where the new lifecycle contract
  requires truthful state.

## Accepted risks

- **AR1. Enclosure thermal behavior is not yet production-proven.** PO7 accepts
  bench resource stability only. Matched room-temperature and warm-equilibrium
  comparison waits for the intended enclosure and repeatable ambient setup in
  Icebox swoop `kiln`.
- **AR2. Consumer-card controller risk remains.** The transactional protocol and
  hard-power-cut campaign reduce and measure software/filesystem failure windows but
  cannot make hidden flash-translation-layer updates atomic.
- **AR3. Fresh-image dependency convergence is deferred.** The playbook owns distro
  `python3-av`, lint and current-image check mode pass, and the deployed runtime
  imports PyAV and Picamera2. A double converge from a newly flashed image remains a
  follow-on gate before the next car-image qualification.

## Rejected ideas

- **RI1. Keep FFmpeg segmentation and infer lifecycle from watcher-observed file
  creation.** It retains the measured startup floor and cannot expose
  close-before-open durability transitions.
- **RI2. Publish an empty path, TS header, or incomplete access unit.** It improves a
  number while making status and crash recovery false.
- **RI3. Revisit blind probe flags or a runtime fallback ladder.** The bounded-probe
  experiment already failed, and a fallback would restore the hidden lifecycle this
  design removes.

## Implementation discretion

- Transaction message shapes, carried fields, backpressure, in-memory
  acknowledgement bookkeeping, and fault-injection seams are implementation choices
  provided I1-I8 and PO1-PO5 hold.
- The names and placement of the three required on-disk artifact states, sync
  placement within their truth points, per-owner association, and power-cut
  instrumentation are implementation choices provided D2, I2-I6, and PO6 hold.

## Implementation notes

- Hidden artifacts use `.dancam-seg_<seq>_<boottag>_<session>_<monoMs>.pending`
  and `.open.ts`; ordinary stamped `seg_` paths remain the finalized namespace.
- Python retries opened, finalized, and reservation exchanges for 2 seconds on a
  monotonic clock. Rust derives duplicate replies from accepted in-memory child
  state while the recording directory remains the only durable lifecycle ledger.
- Finalization is a standalone recorder transition. It advances the pull floor
  before Rust reserves a successor, and owner reconciliation publishes recovered
  committed-open footage before replacement readiness.
- Picamera2 callbacks hand complete access units to a bounded queue. A dedicated
  mux worker owns PyAV and transaction boundaries, and each transaction owns its
  periodic sync worker, so storage latency cannot stall preview delivery.
- Committed implementation and real-Pi evidence through `203569f` discharge PO1-PO8.
  The evidence is recorded in
  [first-segment delay and shutdown timeout](../../docs/research/3-first-segment-delay-and-shutdown-timeout.md#11-committed-transactional-pyav-acceptance----2026-07-16).
- The two-run bench resource campaign from PO7 passed. Fresh-image double-converge
  evidence is deliberately deferred from PO8 to the next car-image qualification;
  the current implementation is ready for plan promotion.
- Enclosure thermal qualification is deliberately outside PO7 because no enclosure
  exists yet. Icebox swoop `kiln` preserves the matched former-FFmpeg-versus-PyAV
  room-temperature and warm-equilibrium comparison without claiming it here.
- The first PO6 uncommitted-state cut preserved the witness, removed the pending
  artifact, and recovered with a higher playable segment, but the first post-cut boot
  failed its Wi-Fi firmware transfer over SDIO and required another power cycle.
  A boot-local observer made that trial honestly inconclusive. Repeated cuts then
  passed uncommitted, committed-open, and finalized states on their first boots; the
  Wi-Fi anomaly did not recur and remains separate from PO6.
