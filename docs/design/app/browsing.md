# App navigation, recording browse, and Debug

The app presents camera footage as recording-sized browse units, keeps global
navigation stacks independent, and renders operational detail from the same
event-folded world as the rest of the product. The Pi remains a flat clip and state
server; grouping, pagination policy, recording attribution, and telemetry presentation
belong to the phone.

The [app architecture](architecture.md) owns the scene store, shell composition,
selector observation, and diffable-update rules. [App connection](connection.md) owns
freshness and reconnect policy. [App clips](clips.md) owns per-clip pull, playback,
cache, thumbnail, and deletion mechanics. This page owns top-level tab navigation,
Home's recording-first browse projection, recording detail, and the Debug surface.

## Top-level navigation

`SceneDelegate` composes four tabs in this order: Home, Incidents, Debug, and Settings.
Each root view controller has its own `UINavigationController`, so pushed screens and
navigation state survive tab switches independently. The shell embeds the tab
controller below its global connection-and-recording status strip; the strip therefore
stays visible above every tab and pushed screen.

Home loads eagerly at scene startup because it starts live work. The other view
controllers are constructed during composition but their UIKit views load on demand.
The app uses the classic `viewControllers` and `UITabBarItem` APIs. iPad sidebar
adaptivity is irrelevant to this iPhone-only product, and eager shell delegate wiring
is clearer than an iOS 18 `UITab` provider.

`AppShellViewController` delegates both the tab controller and every navigation
controller. It logs tab selections and shown screens under the `nav` category. Its
visible screen is the selected navigation controller's `topViewController`, which is
also the only screen targeted by foreground and offline-to-online recovery. Switching
tabs never discards a pushed stack.

Screen content honors the tab bar through safe-area or automatic inset behavior. In
particular, Home's bottom failure presentation and clip list remain above the bar.

## Session-first Home browse

Home derives its sections and rows from the root `ClipsFeature.State` list. It does not
store a second recording collection and the Pi does not expose a grouping endpoint.
Finished clips retain their loaded order and are split into local-calendar day sections;
undated runs stay in place in explicit date-unknown sections.

A recording is identified by:

```swift
RecordingID(bootTag: String, session: UInt64)
```

The pair corresponds to one observable contiguous capture run. `session` alone is only
unique inside a recording directory, while `boot_tag` disambiguates boots. A clip with
either fact missing has no `RecordingID` and remains an ordinary per-clip row. The app
never guesses the missing half, and it never treats either identity field as a clock or
sort key.

Consecutive finished clips with the same non-null `RecordingID` inside a day section
coalesce into one session card. A single identified clip is still a card. The card is
a render projection, not a persisted domain entity, and shows:

- the session's visible time span;
- its clip count;
- total duration only when every member clip has a known duration;
- the oldest visible member as a stable representative thumbnail; and
- a freshness-typed REC marker when this is the newest occurrence of the recording
  currently being written.

The start is the oldest clip's trusted start. A fresh live session ends at the literal
`now`; a finished or last-known session ends at the newest finalized clip's trusted
start plus duration. A missing required trusted time or duration produces the generic
`Session` title. Home calculates both endpoints from only that day-section occurrence.
Same-day ranges show times only. Cross-day ranges show both dates, adding years when the
endpoints cross a year; a live range that began before today shows its start date.

Using the oldest member keeps the card's thumbnail and leading time stable as newer
segments finalize. Deleting that member intentionally changes the representative and
reconfigures the card. Session cards do not have swipe-to-delete actions; deletion
stays per clip in recording detail or the clip viewer.

One recording can appear in more than one day section when it spans midnight, or in
separate loaded runs when an unidentified clip interrupts it. An occurrence counter per
`RecordingID` keeps those card identities unique and stable across top prepends and
bottom pagination. Only occurrence 0 can carry the REC marker, so an older day card
never claims that recording is being written there now.

"Session" is the user-facing noun for a grouped run of clips. Record and Recording
remain the capture action and current recorder status. Internal types such as
`RecordingID`, `RecordingGroup`, `RecordingAttribution`, and `RecordingDetail*` retain
their implementation names; the Pi's `session` field remains an identity discriminator.

## Live recording placement and attribution

Recorder state is not a browse row. Home renders a dedicated live/pending widget below
the Record button and outside the finished-footage list. The shell status strip carries
global recording status; there is no preview REC overlay.

Home and recording detail share `LiveRecordingStatusView`. The view renders pending,
a red heartbeat-fresh ticking segment, or a gray frozen last-known segment. It owns its
1 Hz timer and runs it only while ticking and onscreen, so diffable lists do not churn
once per second or whenever the Pi rolls to a new segment.

Card and detail attribution come from one equality-gated `LiveRecordingInputs`
projection containing the local recording command state, `RecorderTruth`, and the
world's `boot_tag`. Reading these facts together prevents a reconnect transition from
pairing a new recorder session with the previous boot tag for one frame.

`RecordingAttribution` pairs the world boot tag with the current segment's session.
During the pending gap before a first segment exists, it does so only when fresh Pi
truth says the recorder is starting or recording. Local command state still presents
the pending widget immediately, but an idle snapshot's retained session cannot identify
the new run. Missing boot identity or non-recording status yields no attribution. Live
truth produces a red marker; last-known truth freezes the elapsed value and produces a
gray marker rather than hiding it during a heartbeat gap. Segment-backed attribution
continues through stopping while the fresh snapshot retains an open current segment.

## Recording detail and pagination

Tapping a card pushes `RecordingDetailViewController` for that `RecordingID`. The detail
screen observes the root clip state and filters it; it is not a child reducer or a
snapshot copied at navigation time. Rows stay newest-first and push the existing clip
viewer. Thumbnail loading, prefetch, cancellation, and per-clip deletion reuse the
normal clip paths. Its Session title uses the oldest and newest matching clips across
all loaded pages, with the same live, finished, last-known, trusted-time, and cross-day
range rules as Home rather than the selected Home occurrence's narrower range.

Detail pagination follows the global flat clip frontier. An unidentified tail keeps the
target recording indeterminate, so detail continues loading through `nil`-identity gaps.
It stops only when there is no next cursor or the oldest loaded identified clip belongs
to another `RecordingID`, including a different session from the same boot. The
projection includes the global frontier so a page containing only invisible gap clips
still wakes the controller and can request another page.

Home has a related edge: an older page can be completely absorbed into the bottom
recording card without adding a visible row. Home observes the cursor and repeats its
visible-tail check after the latest diffable snapshot commits. Both screens request
more only while active and attached.

When the detail's target is the recording currently being written, a stable live row
appears above its clips. The row stays in place across pending-to-live transitions and
segment rolls, and a detail pushed mid-segment receives the already-running elapsed
seed so it does not restart at 00:00. Empty detail remains on screen while that live row
is present. Once recording stops and the target is both empty and proven exhausted, the
controller removes itself from the navigation stack.

## Debug from the event-folded world

Debug is a peer tab, not a screen pushed from Home. It has no health request, response
model, fetch-on-appearance lifecycle, or second operational truth. It projects solely
from `AppFeature.State.link`, whose online world comes from `GET /v1/events`. The Pi's
canonical `/v1/status` is its sole one-shot operational probe, but the live app does not
poll it. See [Pi telemetry](../pi/telemetry.md) for the producer-side status model.

`DebugScreen` is a pure projection into sections and semantic rows. The controller
renders it with an inset-grouped collection view. Connecting without a world uses
placeholders. `offline(last:)` retains values under an explicit "Not connected --
showing last known values" banner, so stale facts never read as current.

The current sections are:

- **Recorder:** phase and session, plus current segment and critical error detail when
  present. Fresh and last-known recorder snapshots remain distinguishable at the link
  boundary.
- **Camera:** camera state, then separate `SoC temp`, `SoC max`, `Camera temp`, and
  `Camera max` rows. Max rows stay present with `--` when unknown. SoC values warn at
  70 C and become critical at 80 C; camera values warn at 50 C and become critical at
  55 C. Home's temperature warning remains sensor-current-only and clears when the
  sensor cools.
- **CPU per core:** one full-width row per runtime logical CPU ID, showing current, 1m,
  5m, and 15m utilization. Missing baseline values display `--`; unavailable or empty
  telemetry yields one stable `CPU --` row. Only the core title is tinted, from the
  sustained 1 minute value at inclusive 85 percent warning and 95 percent critical
  thresholds.
- **Storage:** a neutral used/free gauge. High utilization is expected under loop
  recording and is not itself a warning.
- **Memory:** RAM and swap gauges with their own pressure thresholds. Missing or invalid
  totals use placeholders; a system with no swap says `none` rather than drawing a
  meaningless gauge.
- **System:** boot ID, optional boot tag, uptime, and time-sync state.
- **Actions:** log export and any inline critical export failure.

Every online heartbeat advances only `World.uptimeS` from `t_ms / 1_000`; snapshots
still replace the whole world. Debug therefore shows heartbeat-fresh device uptime
without a controller-local clock. Home's live-segment timer is a separate recording
duration and does not derive from uptime.

Semantic section and row identifiers remain stable as values change. When structure is
unchanged, the controller reconfigures changed items rather than replacing identities;
otherwise live telemetry could freeze behind an unchanged diffable snapshot.

Log export keeps the current text format, state snapshot header, and outcome tracking.
A failure is projected as an inline critical row and clears after a later success.
Pull-to-refresh ends immediately and asks the root store to reconnect only when the
event stream is offline.

## Testing obligations

Browsing behavior is covered where it is observable rather than through implementation
shape:

- section projection tests cover day and unknown-date runs, recording coalescing,
  partial identities, same-boot different sessions, midnight and split occurrences,
  representative stability, incomplete durations, and REC attribution;
- Home controller tests cover card navigation, per-clip-only deletion, thumbnail
  preservation, bottom-card page absorption, cursor-driven tail checks, and live-widget
  transitions;
- recording-detail state and controller tests cover identity filtering, conservative
  gap pagination, same-boot session boundaries, live-row seeding and freshness,
  empty-but-recording retention, exhausted self-removal, deletion, viewer navigation,
  and thumbnail prefetch lifecycle;
- shell tests cover tab order, independent navigation stacks, selected-tab recovery,
  and navigation/status behavior; and
- Debug projection and controller tests cover placeholders, stale banners, heartbeat
  uptime, gauges and thresholds, independent current/max temperature tints, runtime CPU
  rows, stable reconfiguration, reconnect refresh, and log-export outcomes.

## Decision log

### 2026-07-08: Try boot-keyed drive cards

(absorbed from dead app ADR 19, 2026-07-08)

The first grouped Home design responded to hundreds of roughly 30-second rows and the
cost of one thumbnail prefix read per visible segment over 2.4 GHz. A user often knows
"the drive when this happened" before the exact segment, and v1 camera power initially
made one Pi boot look like a plausible drive boundary.

Home therefore collapsed consecutive stamped clips with the same non-null `boot_tag`
into cards while leaving bare clips flat. It established the mechanics that survive in
the current body: app-side grouping over the flat clip list, stable oldest-member
thumbnail, honest all-members duration, occurrence identity across midnight, derived
detail over root state, conservative pagination through bare gaps, and per-clip
deletion. A 2026-07-09 amendment moved live and pending recorder rows out of the list
and added card/detail attribution.

Flat rows with drive headers were rejected because they kept both the row count and
thumbnail cost. Pi-side grouping was rejected because day sections, pagination,
thumbnails, and deletion are phone presentation policy. A newest-member thumbnail was
rejected because every finalized segment would churn identity and pull more prefix
bytes.

The boot-keyed part did not pan out. A manual stop/start, future CarPlay automation, or
same-boot service restart creates several recordings under one boot. The model merged
unrelated runs and claimed a trip boundary the system could not observe. The
recording-identity decision later replaced it.

### 2026-07-09: Move live recorder state out of the footage list

(absorbed from dead app ADR 20, 2026-07-09)

Once finished footage became grouped cards, a live row at the top of Recent was both a
category error and a source of list machinery: fake Today bucketing, per-second index
lookups, and identity churn on each segment roll. The app moved recorder state into a
widget below the Record button, a REC marker on the newest matching card, and a shared
live row atop matching detail.

The initial attribution used snapshot-level `boot_tag`, placed outside
`current_segment` so it survived pending and idle phases. One `LiveRecordingInputs`
projection coupled that identity with recorder truth to rule out mixed-frame reconnect
artifacts. The shared renderer owned its timer, detail preserved empty-but-recording
state, and a mid-segment push carried the elapsed seed.

Keeping live rows in Recent was rejected because it preserved the exact list churn the
change removed. Putting `boot_tag` on `current_segment` was rejected because a boot
constant would disappear during pending. Hiding attribution on disconnect was rejected
because typed gray last-known state is more honest and less disruptive than flapping.

The placement and coherent-projection rules survived. Boot-only attribution and the
"drive" name were replaced by `RecordingID`. A same-day amendment also removed the
preview REC overlay and moved global recording status to the shell strip, now owned by
the [app connection](connection.md) design.

### 2026-07-09: Put peer surfaces in independent tabs

(absorbed from app ADR 22, 2026-07-09)

Settings was a peer of Home, not a destination in Home's stack, while global connection
and recording chrome needed to remain above every screen. The app embedded a tab
controller inside the shell and gave each peer its own navigation controller, leaving
`SceneDelegate` as the explicit composition root. Home remained eagerly loaded for live
work; screens without startup work retained UIKit's lazy view loading.

The shell became both tab and navigation delegate so navigation logging stayed complete
and reconnect recovery could target the selected stack's top screen. Home's safe-area
and automatic inset behavior kept bottom UI above the new tab bar.

The iOS 18 `UITab` provider was rejected because its lazy controller provider conflicted
with eager shell delegate wiring and offered iPad adaptivity this iPhone-only app does
not use. Owning tabs outside the shell was rejected because global status chrome must
remain above all peers. Later features added Incidents and Debug without changing the
container rule.

### 2026-07-09: Make Debug an SSE-only peer tab

(absorbed from app ADR 23, 2026-07-09)

Debug originally mixed a one-shot `/v1/health` response with storage, temperature, and
memory already folded from events. The duplicate request became stale immediately and
added appearance-driven fetching to what should be a persistent live surface. Snapshot
uptime had the same problem even though heartbeats already carried milliseconds since
Pi boot.

Debug moved out of Home's navigation bar into a peer tab and adopted the pure
`DebugScreen` projection over root link state. The app-side health feature, client,
response model, and dependency were deleted. Heartbeats began advancing only world
uptime, while snapshots remained authoritative replacements. Offline retained state
gained a visible staleness banner and missing fields gained placeholders.

Storage, RAM, and swap became gauges; storage stayed neutral because loop recording is
supposed to consume the card. Semantic IDs and explicit reconfiguration kept live
values updating without list churn. Export failures joined the same projection as an
inline critical row, and pull-to-refresh became an offline reconnect request.

Advancing uptime means every heartbeat now changes `World`, but equality-gated
selectors keep unrelated screens asleep and Debug changes only at the precision it
renders. Explicit row reconfiguration remains required even when section and row
identity do not change.

Keeping both health and SSE, refetching health on appearance, and leaving Debug behind
a Home button were rejected as duplicate or stale lifecycles. Freezing uptime at the
snapshot was rejected as a false present-tense claim. A local uptime timer was rejected
because heartbeat `t_ms` already supplies the device clock without drift or another
lifecycle.

### 2026-07-09: Group by observable recording identity

(absorbed from app ADR 24, 2026-07-09)

One boot can contain multiple capture runs, so the earlier drive model collapsed manual
stop/start cycles, future automatic cycles, and same-boot restarts. The wire now carried
per-clip `session`; pairing it with `boot_tag` produced an identity durable across a
same-boot service restart and exactly matched what the system could witness.

All grouping, occurrence, detail, pagination, and live-attribution mechanics were
re-keyed to `RecordingID`. Live segments provide their session; pending snapshots
provide the recorder session. A clip with only one identity fact degrades to a flat row,
and a same-boot different-session tail proves a detail page boundary.

Keeping boot-keyed drives was rejected because it merged unrelated runs. Session alone
was rejected because it is not globally unique. Keeping "Drive" as the product noun was
rejected because it asserts trip semantics without an ignition, GPS, or odometer signal.
A deprecated `Drive*` shim was rejected because the project has no compatibility burden;
the active model was renamed in place. Gap-between-card annotation stayed deferred.

### 2026-07-10: Preserve current and peak temperatures in Debug

(absorbed from the 2026-07-10 current/max amendment to app ADR 23)

Current temperature alone hid a thermal event as soon as the device cooled. Debug began
showing Pi-owned service-lifetime maximums beside current SoC and camera readings, with
current and max tinted independently. SoC adopted 70/80 C warning/critical thresholds;
the camera retained 50/55 C. Home deliberately stayed sensor-only and current-only so
its active warning clears after recovery.

### 2026-07-10: Keep temperature rows single-purpose

(absorbed from the 2026-07-10 separate-row amendment to app ADR 23)

The initial combined `current (max ...)` value wrapped inconsistently beside the longer
Camera label. Debug split each sensor into stable current and max rows. Max rows remain
present with `--` when unknown, and each row retains its own tint. This traded a little
vertical space for predictable layout and single-fact values.

### 2026-07-10: Show sustained load per logical CPU

(absorbed from the 2026-07-10 per-core amendment to app ADR 23)

An aggregate can hide one saturated core. Debug added runtime-discovered logical CPU
rows with current, 1m, 5m, and 15m utilization. Baseline and read failures stay explicit
as `--`, and an absent slice keeps one stable placeholder row. Tinting only the core
title from the sustained 1 minute value makes pressure visible without coloring every
number.

### 2026-07-15: Keep the app live path SSE-only after status consolidation

(absorbed from the 2026-07-15 operational-status amendment to app ADR 23)

The Pi removed `/v1/health` and made canonical `/v1/status` its sole operational probe.
That server-side consolidation did not change the app: events remain the only live state
and heartbeat-liveness source, so Debug still has no one-shot status fetch or competing
truth.

### 2026-07-21: Let fresh recorder truth own session attribution and ranges

Immediate local pending feedback briefly combined with an idle Pi snapshot's retained
session, which could put REC and a live detail row on the completed run during a new
start. Attribution now requires fresh starting or recording truth until a current
segment exists; local command state still owns the immediate pending widget.

Grouped footage adopted Session as its user-facing noun while Record, Recording, and
REC remain action and recorder-status language. Session titles now end fresh live runs
at `now` and finalized or last-known runs at the newest trustworthy clip end. Home uses
only the clips in its occurrence, detail uses every loaded matching clip, and cross-day
ranges expose their dates.

Suppressing REC only in Home was rejected because detail would retain the same false
identity. Predicting a new session locally was rejected because allocation belongs to
the Pi. Ending a range at the newest clip's start was rejected because it understates
completed footage.
