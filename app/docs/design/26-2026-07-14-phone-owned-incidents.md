# ADR: Phone-owned incidents

- **Status:** Accepted
- **Date:** 2026-07-14
- **Owner:** app
- **Related:** root `AGENTS.md` (incidents are phone-owned); raspi ADR 02
  (`raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md`, clip list,
  ranged pull, and events contract); [Pi storage](../../../docs/design/pi/storage.md)
  (superseded Pi-side incident locks and current oldest-first ring retention)

## Context

An incident is footage the user has chosen to keep. The Pi's microSD is the
recording source of truth, but the phone is the better permanent home for kept
footage: it leaves the car, participates in the user's phone backup, and is not
lost with a failed or stolen camera unit.

The existing Pi API already provides every primitive needed to save an incident:
cursor-paged finished-clip listings, resumable ranged clip pulls, and the
snapshot-first event stream. The ring evicts oldest-first, so just-recorded
incident footage is last in line for eviction. At the expected bitrate, the ring
retains roughly 24-50 recording hours; normal wall-clock retention is longer
because the Pi only records while the car is powered.

The earlier design put incident state on the Pi: hardlink locks, incident
metadata, idempotency tombstones, locked-byte caps, dedicated incident endpoints,
and incident SSE events. That machinery makes the deliberately dumb recorder own
product state, adds mutations and recovery paths to the recording unit, and is not
needed for the initial product requirement.

## Decision

Incidents are phone-owned artifacts. A press in the iPhone app creates durable
local incident state and the app satisfies it entirely with existing read
surfaces. The Pi receives no incident mutation, stores no incident record, and
adds no incident endpoint or event.

### Capture and coverage

The v1 window is `[press - 30 s, press + 15 s)`, widened by 2 s at each edge to
absorb event-delivery and observation error. The app saves whole segments, so the
result is an approximate superset of that window rather than trimmed media.

A press is accepted only while the app is connected, the recorder reports
recording, and the current open segment is known. The mark records the recording
identity, open segment sequence, estimated age within that segment, and the
phone's exact wall-clock press time. The app walks segment durations backward and
forward from that anchor; it never converts a phone time into a Pi clock or
depends on a fixed segment length.

### Resolution and evidence

An incident starts `pending` and ends `saved` or `partial`:

- `saved` means every segment witnessed to exist within the requested window was
  pulled. A window edge clipped by session start or stop still counts as saved,
  because that footage never existed.
- `partial` means footage known to have existed was lost before the app could
  pull it. Evidence is a `clip_removed` event for a queued segment, a ranged pull
  returning 404 for a previously witnessed etag, a covered sequence gap inside a
  contiguous recording session, or the marked open segment disappearing when
  its session ends.

Absence is not evidence until the current clips-list cursor chain covers the
sequence. The app pages until it reaches the lowest unresolved sequence. An
active pull is not preempted by `clip_removed`: the Pi may finish streaming from
an already-open file descriptor after unlink, so the pull's outcome decides
whether that segment was salvaged.

### Durability and storage

The incident record is persisted before any post-press effect. Incident data
lives under Application Support and is included in normal phone backup:

```text
Incidents/<uuid>/
  incident.json
  seg_<seq>.mp4
  seg_<seq>.ts
  thumb.jpg
```

`incident.json` stores facts needed to resume: the mark, window settings, status,
and each wanted segment's resolution state, etag, duration, and bytes. The
filesystem is the index; no SwiftData store or second index is introduced.

Resolution is persisted before a pull or cache clone starts. Media is installed
through a sibling staging file followed by an atomic same-directory rename, and
the entry is marked pulled only after the final artifact exists. On launch, a
scan removes staging files and reconciles complete final artifacts ahead of the
record, healing a crash between rename and record persistence. Unreadable
incident directories remain visible with a delete affordance rather than being
silently discarded.

Pulled MPEG-TS segments are remuxed without re-encoding to one MP4 per segment. If
remux fails, the raw TS is kept as shareable evidence. The app reuses an existing
matching clip-cache MP4 when available and deduplicates one network pull across
overlapping incidents.

### Foreground completion and notification

Downloads are foreground-first and resumable without an incident-level retry
limit. The app gives an active pull a short best-effort background-task grace;
unfinished work resumes on the next foreground or reconnect. At press time it
schedules a quiet local notification for about three minutes later asking the
user to reopen DanCam if saving is still pending, and cancels that nudge when the
incident becomes terminal.

### Retention risk and hardening seam

If the phone does not reconnect within ring retention, the wanted footage can
roll off. This is accepted for v1 because new footage is evicted last, retention
is measured in days to weeks of normal driving, the common save completes within
minutes, and the notification nudges the user back to the app.

If real use shows that window is insufficient, add a narrow protect-only pin
operation for clips already identified by sequence. Clip bodies keep the
reserved `locked` field for that possible future contract. Evidence, not the old
incident-lock design, will decide whether the extra Pi state is warranted.

## Consequences

- The Pi stays a recorder and read server; incidents add no Pi mutation, durable
  state, idempotency protocol, locked-space policy, or wire surface.
- Kept footage survives later ring eviction, camera-unit theft, and card failure
  once it reaches the phone.
- Incident completion depends on the app running long enough to pull the window;
  foreground resume and the local nudge make that dependency explicit.
- The Incidents tab owns listing, playback, sharing, deletion, storage totals,
  and partial-save reporting. Deleting an incident removes only phone files and
  never mutates the Pi ring.
- Voice marking, if built later, creates the same local record and uses the same
  reconciler; it does not require a Pi lock call.

## Alternatives considered

- **Pi-side hardlink incident locks.** Superseded. They protect footage before a
  pull but add product state, mutation recovery, caps, tombstones, endpoints, and
  events to the recorder. The existing retention window makes that cost
  unnecessary for v1.
- **Background `URLSession` for incident pulls.** Deferred. The app's current
  transport is a hand-rolled HTTP client over Wi-Fi-pinned `NWConnection`;
  background transfer needs a proven interface-pinning and AP-association story.
- **Continuous phone mirroring.** Rejected. It makes the congested 2.4 GHz link
  part of storage and violates the selected-preview-plus-pull posture.
- **SwiftData incident index.** Rejected. Each incident is already a
  self-contained directory; a second index can drift from the media it describes.
