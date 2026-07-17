# Phone-owned incident capture and recovery

An incident is footage the user has chosen to keep. The Pi remains the recording
source of truth and a read-only footage server; the iPhone turns a button press into a
durable local record, discovers the whole-segment superset covering the requested
window, and pulls those segments into permanent phone storage. The Pi receives no
incident mutation and owns no incident lifecycle.

The [transport boundary](../boundary/transport.md) owns clip listing, ranged pull, and
ordered event delivery. [Pi storage](../pi/storage.md) owns oldest-first ring eviction
and the intentionally unused protection seam. [App architecture](architecture.md) owns
event folding and effect ordering, while [app clips](clips.md) owns the shared pull,
remux, cache, playback, and thumbnail machinery. This page owns incident capture,
coverage planning, durable facts, evidence ordering, recovery, and incident UI.

## Ownership and capture window

The default requested window is `[press - 30 s, press + 15 s)`, widened by 2 seconds
at each edge to absorb event-delivery and observation error. The app preserves whole
segments rather than trimming media, so a saved incident is an approximate superset of
that window.

A press is accepted only when all of these facts are present together:

- the event stream has an online world;
- the incident store has loaded successfully;
- the recorder claims an active recording;
- the world has a complete `RecordingID(bootTag, session)`; and
- the current open segment matches the app's monotonic open-segment anchor.

The mark persists the recording identity, open segment sequence, estimated age within
that segment, the exact phone wall-clock press time, and the pre-roll, post-roll, and
slack settings. Segment age starts from the recorder's observed duration and advances
with `ContinuousClock` until the tap. The planner walks real segment durations backward
and forward from this anchor; it never converts phone time into Pi time and never
assumes a fixed segment length.

The incident record is written before notification authorization, the pending nudge,
or reconciliation begins. A failed create leaves no in-memory incident, clears only
the matching recording's create and lockout state, and presents a calm retryable error.

## Post-roll press lockout

One accepted press creates a `RecordingID`-scoped monotonic deadline spanning the
default post-roll plus slack, currently 17 seconds. The reducer samples that deadline
on every tap, and `IncidentButton` renders title and enabled state from the same
presentation enum. This prevents a second incident from duplicating the first one's
post-roll while ensuring the button never says "Saving..." when it is enabled.

The button owns a 1-second timer in the main run loop's common mode. The timer updates
only presentation, runs only while the deadline is live and the button is attached,
and stops when the lockout expires or the view detaches. Reducer state does not tick.
After the deadline, transfers for the first incident may continue; the Incidents tab
badge, rather than the Home button, reports that pending work.

A create still in flight for the current recording keeps capture disabled even after
the deadline. Create state is keyed by `RecordingID`, so suspended work from an older
recording cannot block a new recording or clear its state.

The persisted press time is a durable fact, not an in-process clock. After launch, the
reducer waits until the store and a validated current recording first meet, computes
any remaining fixed 17-second wall-clock window once, and converts that remainder into
a monotonic deadline. It does not use persisted durations to reconstruct the lockout.
Wall-clock changes after that one sample cannot end, extend, or reactivate it.
A bad reconstruction sample can omit the duplicate guard, but cannot strand the
button or make presentation disagree with reducer acceptance afterward.

## Coverage planning

Each record begins with its marked sequence unresolved. Once same-recording clip
metadata is observed, the planner records the segment ETag and real duration, then
walks backward until pre-roll plus slack is covered and forward until the marked age,
post-roll, and slack are covered. Session-start and session-end edges are `clipped`:
they settle the requested boundary without claiming footage was lost.

Clip-list absence is usable only when a successful head and cursor chain from the
current SSE snapshot epoch covers the sequence. Older loaded clips remain valid
positive witnesses, but they never prove absence. The planner publishes the minimum
unresolved sequence it requires as a pure coverage boundary. The root synchronously
passes that boundary to the single clip-list scheduler described in
[authoritative clip-list recovery](clips.md#authoritative-clip-list-recovery). Incidents
never request pages or track whether a page is pending.

Published coverage carries the fresh snapshot epoch that established it. Negative
evidence is accepted only while that epoch remains current. Stream failure, heartbeat
timeout, and suspension revoke the coverage before freshness disappears, so a late
pre-gap page cannot infer loss. A list failure retains the minimum boundary but starts
no more work until heartbeat or manual recovery establishes a replacement head.

Recorder lifecycle is evidence too:

- `stopping` is still active finalization for the same `RecordingID`; it disables new
  marks but cannot prove the open segment disappeared;
- `recording_stopped` and `recorder_failed` prove the session ended; and
- an active lifecycle for a different recording proves the earlier session ended.

The root reducer forwards lifecycle and clip actions to incident reconciliation in
event-stream order. A just-stopped open segment therefore stays unresolved until a
fresh list can show the finalized clip or provide authoritative post-session absence.

## Evidence and self-healing status

Segment facts, from weakest to strongest for recovery purposes, are:

- `unresolved`: the coverage walk still lacks enough evidence;
- `wanted`: same-recording metadata established that the segment exists and should be
  pulled;
- `clipped`: current evidence places the requested edge outside the recording;
- `lost` with `inferred_absence`: a fresh covered gap or post-session absence supports
  loss, but later positive evidence may correct it;
- `lost` with `confirmed_missing`: `clip_removed` or a resolved-ETag pull returning 404
  proves the known representation is gone; and
- `pulled`: a complete final artifact exists locally.

Positive same-recording metadata can reopen `clipped` or `inferred_absence` to
`wanted`. It never reopens `confirmed_missing`. Reconciliation scans every readable
record, including records currently displayed as saved or partial, so later clip
evidence repairs a premature conclusion automatically. On store load, a complete local
artifact is stronger still: it repairs stale record metadata to `pulled` before any
network planning.

Incident status is derived, never persisted:

- any unresolved or wanted segment makes the incident `pending`;
- all segments settled with at least one lost segment makes it `partial`; and
- all segments settled without a loss makes it `saved`.

Legacy records ignore their old persisted `status` key. A legacy lost segment without
ETag or duration decodes as inferred absence; one with resolved metadata decodes as
confirmed missing. This preserves conservative recovery without retrying known
deletions forever.

A `clip_removed` event confirms queued matching work as missing, but it never preempts
an active pull. The Pi may have unlinked the directory entry while the already-open
file descriptor can still finish streaming, so that pull's completion or 404 decides
whether the segment was salvaged.

## Durable store and media installation

Incident data lives in the app's Application Support directory and participates in
normal phone backup. The filesystem is the only index:

```text
Incidents/<uuid>/
  incident.json
  seg_<seq>.mp4
  seg_<seq>.ts
  thumb.jpg
```

`incident.json` stores resumable facts: the mark, window settings, recording identity,
and each segment's sequence, resolution state, evidence class, ETag, duration, and
bytes. It does not store derived incident status. Introducing SwiftData or another
index would create a second truth that could drift from the media directory.

Record updates use atomic file replacement. A segment's resolved metadata is persisted
before cache reuse or network pull begins. Media is copied to a same-directory `.part`
file and renamed to its final name; only then is the segment persisted as pulled. A
launch scan deletes abandoned staging files and promotes complete final MP4 or TS
artifacts into the record, healing a crash between artifact rename and record update.
Unreadable directories remain visible and deletable instead of being silently erased.

The reconciler first reuses a matching cached MP4 when one exists. Otherwise it uses
the normal resumable ranged pull, writes a thumbnail for the marked segment, and remuxes
MPEG-TS to MP4 without re-encoding. If remux fails, the raw TS remains durable,
shareable evidence. Overlapping incidents needing the same sequence and ETag share one
network pull, then install a complete artifact into each incident directory.

Every fact transition is one ordered effect: persist the record, update the local
notification for the derived-status transition, publish the record to reducer state,
then reconcile again. A terminal-to-pending correction schedules a nudge;
pending-to-terminal cancels it. Loading already-terminal records idempotently cancels
stale nudges.

Incident diagnostics distinguish inferred loss, confirmed loss, corrective reopening,
pull completion, terminal state, and waits for fresh negative coverage. These are
separate operational facts rather than one generic save failure.

## Completion and retention risk

Pulls are foreground-first and have no incident-level retry limit. An active network
pull receives a short best-effort iOS background-task grace; unfinished work resumes on
the next foreground or reconnect. The first successful create in a process requests
provisional notification authorization and schedules a quiet notification for about
three minutes later asking the user to reopen DanCam if saving is still pending.
Backgrounding also ensures each pending incident has a nudge.

The Pi ring evicts oldest footage first, so newly marked footage is last in line. At
the expected bitrate it retains roughly 24-50 recording hours, and normal wall-clock
retention is measured in days to weeks because the camera records only while the car is
powered. The common save completes within minutes. V1 accepts that a phone absent
beyond ring retention can lose unresolved footage.

Once a final artifact reaches the phone it no longer depends on the Pi and survives
later ring eviction, camera-unit theft, or card failure.

If real use shows this window is insufficient, the hardening seam is a narrow
protect-only operation for already identified sequences. The transport keeps a reserved
`locked` field and Pi storage keeps an unused in-mutex protection seam, but neither is
active. Retention evidence must justify adding Pi mutation and product state.

## Incidents tab and detail

The Incidents tab lists readable records newest-first, followed by any unreadable
directories. Rows show press time, saved duration and bytes, a marked-segment thumbnail,
and Saving, Saved, Partial, or Unreadable state. The section header reports total item
count and pulled bytes. The tab badge is the number of pending persisted or in-flight
records.

Readable rows push a detail screen with one player whose ephemeral composition contains
every on-disk, loadable MP4 artifact in ascending sequence order. Whole video tracks are
inserted back-to-back using their real media durations. Missing, still-saving, raw-only,
and unreadable segments are spliced out and annotated, so a pending incident becomes
watchable as soon as its first MP4 arrives and grows as reconciliation installs more.
The player and AVKit controller survive composition rebuilds and fullscreen presentation.
Rebuilds preserve the playhead as a segment sequence plus offset, with forward bias when
that segment disappears, and generation gating prevents stale builds from replacing a
newer timeline. One failed player item triggers one disk rebuild for that playable set;
a repeat failure leaves sharing and deletion available with an honest playback error.

The segment list renders every currently known unresolved, wanted, or installed sequence
in ascending order. Unresolved and wanted segments appear as muted, disabled waiting
rows with an in-progress indicator and no artifact type or share surface. They transition
in place to their installed presentation when the artifact lands, while newly discovered
pre-roll or post-roll sequences interleave as the planner expands coverage. Lost,
clipped, and artifact-less pulled segments remain annotation-only. The aggregate saving
progress line stays visible, while detail annotations report only missing and unavailable
segments rather than repeating the waiting state.

Each installed artifact remains a selectable row and the only share surface. Tapping a
playable MP4 row seeks the unified player to that segment; raw TS rows select for sharing
without seeking. Jump to press seeks to the marked segment's real composition position,
or forward to the next playable segment when the marked footage is absent. Both list
swipe and detail actions delete the entire phone-owned incident after confirmation.
Deletion cancels queued work and an active matching pull, removes only the local
directory, cancels its nudge, tears down any fullscreen playback, and never mutates the
Pi ring. Unreadable rows have the same explicit delete escape hatch.

Composition is presentation-only. No stitched movie is persisted or shared; the durable
unit remains one whole local artifact per covered Pi segment, preserving partial evidence
and keeping interrupted installation and repair independently recoverable.

## Testing obligations

Incident behavior is locked down at observable boundaries:

- record and store tests cover snake-case persistence, derived status, legacy evidence
  decoding, atomic updates, staging cleanup, final-artifact repair, and unreadable
  directory preservation;
- planner tests cover real-duration window walking, exact boundaries, cursor coverage,
  session clipping, interior loss, finalization, corrective reopening, confirmed loss,
  persistence-before-pull, and overlapping-incident deduplication;
- reducer and reconciler tests cover capture prerequisites, monotonic anchors and
  lockouts, relaunch reconstruction, recording scoping, current-epoch negative evidence,
  ordered lifecycle forwarding, nudge transitions, cache reuse, active-pull removal,
  404 handling, background assertions, remux fallback, and durable installation; and
- Home, shell, incident-list, detail-controller, and composition-builder tests cover
  consistent button enablement and accessibility, timer lifecycle, the pending tab badge,
  row ordering and totals, unreadable deletion, real-duration timeline ordering, gap and
  progress presentation, rebuild position and identity, stale completion, one-shot item
  self-heal, playback/share selection, fullscreen teardown, and incident deletion.

## Decision log

### 2026-07-15: Consume only current-epoch coverage from the list owner

Incident reconciliation previously converted an unresolved segment into a page action
and kept its own pending-page flag. That duplicated pagination state and could consume
absence from a cursor chain whose SSE snapshot was no longer fresh. The planner now
publishes only its minimum required sequence, and negative evidence comes exclusively
from coverage tagged and published by `ClipsFeature` for the current epoch.

Giving incidents their own page loop was rejected because it cannot coordinate safely
with browse demand, head replacement, or gap recovery. Treating rendered rows as
negative authority was rejected because old rows remain useful positive witnesses but
say nothing about deletions after an event gap.

### 2026-07-14: Keep incidents on the phone

(absorbed from app ADR 26, 2026-07-14)

The phone is the better permanent home for footage the user chooses to keep: it leaves
the car, participates in phone backup, and does not disappear with a failed or stolen
camera unit. The existing Pi API already exposed the required read primitives --
cursor-paged finished clips, resumable ranged pulls, and snapshot-first events -- while
oldest-first ring eviction placed newly recorded footage last in line for deletion.

The earlier Pi design used hardlink locks, incident metadata, idempotency tombstones,
locked-byte caps, dedicated endpoints, and incident SSE events. That made the
deliberately dumb recorder own product state and mutation recovery for a requirement
the phone could satisfy with existing surfaces. The selected design instead made the
phone record the mark durably, walk real segment durations around it, and preserve
whole-segment evidence under Application Support.

Pi-side hardlink incident locks were rejected because their protection did not justify
the added state, caps, tombstones, endpoints, and events within the expected retention
window. Background `URLSession` was deferred because the hand-rolled, Wi-Fi-pinned
transport did not yet have a proven background interface-pinning and AP-association
story. Continuous phone mirroring was rejected because it would put the congested
2.4 GHz link on the storage path. A SwiftData index was rejected because a
self-contained incident directory is already the recoverable index.

The consequence is explicit: completion depends on the app running long enough to
pull the window. Foreground resume, best-effort background grace, and a local nudge
make that dependency visible. Voice marking, when built, should create the same local
record and enter the same reconciler without a Pi lock call.

### 2026-07-14: Lock repeat presses through post-roll

(absorbed from app ADR 27, 2026-07-14)

The first button implementation combined a fixed 3-second cooldown with a "Saving..."
title tied to the full pending lifetime. The predicates could disagree, and an enabled
button during the 15-second post-roll could create a duplicate incident. The guard also
had to survive view updates, link changes, and relaunch without allowing old recording
work or in-process wall-clock corrections to control a new recording.

The app adopted one `RecordingID`-scoped `ContinuousClock` deadline for both reducer
acceptance and button presentation. A view-owned timer renders the countdown without
churning application state. Persisted press time is sampled once on relaunch to
reconstruct only the remaining fixed window, and capture stays unavailable until the
store has loaded enough to perform that reconstruction.

The 3-second cooldown was rejected because it expired inside post-roll and let title
and enablement disagree. A continuously evaluated wall-clock window was rejected
because time corrections could end or reactivate the guard differently across reducer
and view updates. A reducer-owned countdown was rejected because per-second actions
would add state churn without authority; the reducer only needs to validate the
deadline when an action arrives.

### 2026-07-14: Order evidence and repair inferred loss

(absorbed from app ADR 29, 2026-07-14)

An incident was once marked while its segment was open. When recording entered
`stopping`, the current clip head naturally lacked that unfinished segment. The app
combined absence from different moments, treated finalization as a completed stop,
persisted partial, and stopped reconciling just before the Pi finalized the segment.
The problem was evidence ordering, not a missing generic retry.

The reconciler now accepts positive same-recording metadata whenever it is observed but
uses absence only from a successful cursor chain tied to the current snapshot epoch.
`stopping` remains active finalization, lifecycle transitions preserve event order, and
incident status is derived from segment facts. Inferred absence and clipped edges can
reopen when later positive evidence arrives; confirmed deletion and resolved-ETag 404
remain terminal. Durable record writes, notification changes, reducer publication, and
continued reconciliation happen in that order.

Retrying every partial incident was rejected because it would loop confirmed losses
without fixing the evidence model. Treating every list response as current absence was
rejected because an SSE snapshot and an older or partial cursor chain describe
different moments. A Pi incident or finalize endpoint was rejected because the ordered
existing lifecycle and clip surfaces already contain enough evidence. Persisting
status was rejected because a duplicated conclusion can drift from its segment facts
and prevent later correction.

### 2026-07-16: Compose pulled segments only for incident playback

Reviewing an incident one segment at a time hid the event-shaped experience behind file
boundaries, and a pending incident could not be watched until post-roll finished even
when its pre-roll was already durable on the phone. The recorder's IDR-aligned,
video-only segments and the remuxer's zero-start MP4 output make consecutive pulled
artifacts safe to place back-to-back without changing the evidence model.

The detail screen now derives one ephemeral `AVMutableComposition` from current disk
state. The builder owns the composition, exact sequence-to-time map, and gap descriptors
as one result so record duration rounding cannot move seeks away from the media timeline.
The screen retains one player for its lifetime, replaces only its item, keys restoration
to sequence plus offset, and rejects stale async builds by generation. Per-segment files
remain the only durable and shareable artifacts.

`AVQueuePlayer` was rejected because it lacks one scrubbable duration and exposes item
boundaries. Persisting a stitched MP4 was rejected because it duplicates durable evidence
and immediately becomes stale as reconciliation adds or repairs segments. Empty timeline
slots were rejected because unknown edge durations and rounded metadata would create
dead air and dishonest proportionality. Local HLS was rejected because the removed
loopback playback stack added serving and handoff machinery without shortening pulls.

### 2026-07-17: Show pending segments as waiting rows

The artifact-only detail list started nearly empty after an incident press and inserted
rows unpredictably as files arrived. A separate "Still saving" annotation duplicated the
aggregate progress line without showing which future artifact would occupy each sequence
position.

The detail screen now derives rows from every currently known segment. Unresolved and
wanted sequences use an inert waiting presentation that cannot carry an artifact URL or
kind; installed artifacts retain their existing playback and sharing behavior. This keeps
sequence order visible immediately and lets a row change presentation when installation
publishes the updated record.

Optional artifact fields on the existing row were rejected because they would make
invalid waiting/share states representable. A separate pending section was rejected
because lower-sequence backfill could not interleave with installed rows. Keeping the
"Still saving" annotation was rejected because waiting rows and aggregate progress
already communicate the saving state.
