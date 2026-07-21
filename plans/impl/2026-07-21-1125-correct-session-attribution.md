# Correct session attribution and presentation

## Problem and outcome

Tapping Record immediately creates local pending state while the freshest Pi snapshot
can still be idle and retain the previous session. The app currently combines those
facts into a false attribution, so the completed recording briefly shows REC and its
detail can briefly appear live.

Keep immediate pending feedback, but do not associate it with stored footage until
fresh Pi recorder truth identifies the recording being started.

The grouped-footage UI also calls these runs "recordings" and ends their displayed
time span at the newest clip's start time. The desired user-facing noun is "session",
and the displayed range should distinguish a fresh live session from the latest end
time the app can support with finalized footage.

## Decision

Treat local command state as sufficient for the pending widget, but treat the Pi's
fresh recorder phase and session as authoritative for recording attribution. Pending
state can identify a recording only when fresh recorder truth says it is starting or
recording. An idle snapshot cannot identify the new recording even if the local start
command is pending or has returned successfully.

Apply this rule in the shared attribution model so Home cards and recording detail
agree. Update the browsing page's present-tense body and append a decision-log entry
covering the attribution boundary, Session terminology, and range-endpoint behavior;
the page must no longer describe Recording as the user-facing grouped-footage term or
the newest clip's start as a finished endpoint.

Use "Session" across UI that names a grouped run of clips, including the Home heading,
generic card title, detail terminology, and accessibility labels. Keep Record,
Recording, and REC where they describe the capture action or current recorder status.
This is a presentation-language change; the Pi's session field and internal identity
model remain implementation details.

A freshly attributed live session with a trusted start time displays `start - now`.
A finished or gray last-known session displays `start - end`, where `end` is the
newest finalized clip's trusted start plus its duration. Home calculates the range
from only the clips in that day-section occurrence; detail calculates it from every
loaded clip filtered to the selected session identity. If the required trusted time
or duration is unavailable, the surface uses the generic `Session` fallback rather
than inventing an endpoint. The literal `now` requires no ticking title update.

Same-local-day ranges retain the compact time-only form. Finished ranges crossing a
local day show both endpoint dates, including years when needed. A live detail range
whose loaded start is before today includes that start date before `- now`, so ranges
never appear reversed or hide a day boundary.

## Invariants

- A stop/start creates a new recording identity; the previous recording never regains
  REC during the next start attempt.
- The pending widget appears immediately while a start command is in flight.
- Pending/no-segment state receives attribution only from a fresh Pi phase that says
  it is starting or recording and supplies the authoritative session.
- Segment-backed attribution preserves the existing freshness and stop behavior,
  including while fresh stopping truth retains an open current segment.
- Once matching clips for that session exist, the newest matching group carries REC.
- Grouped clip runs are named sessions throughout the UI; recording remains the verb
  and live recorder-state term.
- Fresh live sessions display `start - now`; finished and last-known sessions display
  the latest trustworthy finalized-clip end time.
- Home ranges are occurrence-local; detail ranges cover all loaded clips for the
  selected session identity.
- Cross-day ranges expose enough local-date context to make their ordering clear.
- A connection loss removes the `now` claim immediately and preserves the existing
  gray last-known presentation.
- Existing last-known, live-segment, missing-identity, stop, and failure behavior is
  preserved.
- No Pi API, event contract, grouping identity, or diffable presentation change is
  required.

## Proof obligations

- Prove the shared attribution model rejects an idle snapshot's retained session while
  accepting fresh starting or recording truth.
- Prove Home shows pending feedback without marking the previous group, continues to
  reject that group after the new session is announced, and marks the new group once
  matching footage exists.
- Prove the previous recording's detail does not gain a pending live row, while detail
  for an authoritatively starting matching session still does.
- Prove fresh stopping truth with an open current segment retains segment-backed
  attribution until the segment closes or recording stops.
- Prove grouped-footage headings, generic titles, detail UI, and accessibility use
  Session terminology without changing Record/Recording/REC action and status copy.
- Prove a fresh live Home card renders `start - now`, then changes to its occurrence's
  newest finalized-clip end when recording finishes and to that latest known end when
  the connection becomes last-known.
- Prove recording detail uses the full loaded filtered-session range rather than one
  Home occurrence and follows the same live, finished, and last-known endpoint rules.
- Prove final end-time calculation handles clip duration and trusted-time fallback,
  and that rendered cross-day Home and detail ranges include unambiguous date context.
- Run `just app-test`, `just app-build`, and `just docs-build`.
- On the production Pi, verify that a stop/start never flashes REC on the completed
  group and that the new group gains REC only after matching footage is listed.

## Rejected ideas

- Suppress the pill only in Home: this leaves recording detail wrong and duplicates an
  identity rule at the presentation layer.
- Predict the next session locally: session allocation belongs to the Pi and failed or
  concurrent starts make inference unsafe.
- Delay the pending widget until an event arrives: this removes useful immediate
  command feedback even though only attribution is uncertain.
- Keep `Recent clips` or use `Recent recordings`: neither names the grouped-footage
  concept chosen for the UI.
- Continue using the newest clip's start as the displayed end: it understates every
  completed session and is not an end time.

## Implementation discretion

- Internal type naming, pending-status representation, and test seam placement are
  left to implementation, provided the shared attribution and UI contracts hold.
