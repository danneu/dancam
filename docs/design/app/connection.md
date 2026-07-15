# App connection, liveness, and status

The app treats the camera's ordered event stream as both its live state feed and its
connection authority. It keeps last-known state across link loss without presenting
that state as current, bounds silent network failures at the app and socket layers,
and exposes the result through persistent shell chrome.

The [transport boundary](../boundary/transport.md) owns the wire protocol, Wi-Fi
pinning, and snapshot/delta/heartbeat contract. The
[app architecture](architecture.md) owns the root store and event fold. This page
owns the app's connection lifecycle, liveness deadlines, freshness policy, recovery
coordination, and status-strip presentation.

## One connection authority

The process-owned `AppFeature` owns one `GET /v1/events` stream while at least one
scene is active.
There is no parallel `/v1/status` poll, screen-local reachability reader, or
`NWPathMonitor` signal in product state. A generic network path says only that iOS
has a path; it does not prove that the camera API is answering on the local Wi-Fi
link.

Connection state is explicit:

```swift
enum Link {
    case suspended(last: World?)
    case connecting(last: World?)
    case online(World)
    case offline(last: World?)
}
```

The initial state is `suspended(last: nil)`. The first active scene starts the stream
and moves suspension to `connecting(last:)`, retaining stale facts for frozen display
while making `onlineWorld` unavailable. The first snapshot replaces the folded world
and moves the link online. A stream error, clean unexpected EOF, or heartbeat deadline
moves it offline while retaining the last world. Active reconnect attempts remain
offline until their replacement snapshot, preserving the offline-to-online recovery
edge. Deltas received without an online snapshot base do not restore the link; only a
new snapshot can establish a fresh online world.

The last scene deactivation moves every link state to `suspended(last: link.world)`
before stopping the stream. It resets recording controls to unknown, cancels pending
recording commands plus heartbeat, reconnect, and time-sync work, and resets
connection-epoch estimates. A foreground activation always returns suspension to
`connecting(last:)` and waits for a fresh snapshot. Suspended events are ignored, so
an already-queued stream callback cannot silently restore freshness after the process
has no active scene.

## Heartbeat liveness and reconnect

Starting the event stream arms a 6 second heartbeat deadline before the first
snapshot. Every received event, including non-heartbeat deltas, replaces that
deadline. This corresponds to three missed 2 second Pi heartbeats and prevents a
connected-but-silent stream from leaving the app in `connecting` or stale `online`
state forever.

Stream failure and heartbeat expiry share the same recovery outcome:

- preserve the last folded world in `offline(last:)`;
- cancel the heartbeat and any connection-scoped time synchronization;
- reset connection-epoch retention estimates;
- tell recording controls that the link went offline, cancelling an in-flight
  start or stop command;
- remove fresh-world input from incident reconciliation; and
- schedule another event-stream connection attempt.

Heartbeat expiry additionally cancels the still-open event stream. Reconnect delay
is bounded backoff: 1 second after the first failure, 2 seconds after the second,
and 4 seconds for later failures. A fresh snapshot resets the attempt counter. A
manual refresh also starts the stream immediately when the link is offline.

Stream, heartbeat, reconnect, time-sync, and recording-command effects share the
root effect-ID namespace described by the [app architecture](architecture.md). Their
IDs remain domain-prefixed so one recovery path cannot cancel another domain's work.

The heartbeat is the product liveness authority. Transport receive idleness is a
slower socket-level backstop, not a competing connection signal.

## Transport deadlines

Every real camera API client uses the shared `NWByteStream` transport with two
different inactivity bounds. The production dependency bag threads both values
through events, clip listing and pull, thumbnail prefix reads, preview, recording
control, and time synchronization. Injected `openByteStream` test seams stay
transport-agnostic and do not grow timeout parameters.

### Connect phase

Opening a byte stream has a 4 second default deadline from `NWConnection.start` to
`.ready`. A `.waiting` state is not itself terminal: transient Wi-Fi churn may
recover within the deadline. If readiness does not arrive, the transport cancels
the connection and throws `NWByteStreamError.connectTimedOut`.

`DANCAM_CONNECT_TIMEOUT_MS` overrides the default. Empty, nonnumeric, zero, and
negative values fall back to 4 seconds. The 4 second default admits the TCP SYN
retransmissions around 1 and 3 cumulative seconds that a congested 2.4 GHz camera
link may need while still remaining below the app's 6 second heartbeat deadline.

### Receive phase

After connection and request send, the byte stream arms an 8 second default
receive-idle deadline. Each receive completion cancels the old work item and, when
the stream should continue, rearms it. If no bytes, EOF, or transport error arrive
before the deadline, the transport cancels the underlying connection and finishes
with `NWByteStreamError.receiveIdleTimedOut`.

Connection start, deadline work, receive callbacks, and terminal resolution share
one serial Network queue. A queue-affined resolution object permits only one
terminal result, suppresses data after timeout, and makes late timeout work a no-op
after EOF, failure, or consumer termination. The timer observes socket receive
cadence rather than downstream consumption, so a slow consumer does not look like a
stalled peer.

`DANCAM_RECEIVE_IDLE_TIMEOUT_MS` overrides the default. Empty, nonnumeric, zero,
negative, and values less than or equal to the 6 second heartbeat timeout fall back
to 8 seconds. Enforcing `receiveIdleTimeout > heartbeatTimeout` keeps the event
heartbeat as the first liveness authority during tolerable congestion.

The same receive-idle value serves streaming and one-shot clients. Their domain
layers decide what a transport timeout means: event and preview streams reconnect,
clip pulls resume within their progress budget, and one-shot clients surface their
normal transport failure. The send phase has no separate deadline because requests
are tiny headers or `{}` bodies and Network's `.contentProcessed` completion reports
local acceptance, not peer response progress.

## Fresh and last-known state

The retained worlds in `suspended(last:)`, `connecting(last:)`, and `offline(last:)`
are useful only if projections preserve the freshness boundary.
Static detail may read `Link.world` and display retained facts under the visible
"Not connected" status. A present-tense claim must instead read `onlineWorld` or a
freshness-typed projection.

Recorder state uses:

```swift
enum RecorderTruth {
    case live(RecorderSnapshot)
    case lastKnown(RecorderSnapshot)
    case unknown
}
```

`Link.recorderTruth` maps online state to `.live`, any retained non-online world to
`.lastKnown`, and a non-online state without history to `.unknown`. Recording durations
tick only from live truth. Last-known segments remain visible but freeze and use muted
presentation rather than continuing to imply that the camera is recording now.

When the link goes offline or suspends, `RecordingFeature` resets its command
presentation to `.unknown` and cancels any in-flight command. Record taps require an
online world before they can call either recording route. On reconnect, the first
snapshot is always reconciled as fresh recorder evidence, even when its recorder
phase equals the last-known phase. This lets same-phase reconnects re-enable controls
and live presentation without manufacturing a phase change.

Incident reconciliation also records whether the process has an active scene. It may
continue one active pull under the pull's existing UIKit background-task grace, but it
does not start another queued pull while backgrounded. Foregrounding resumes
reconciliation and starts the next eligible pull. This keeps durable incident goals
queued without beginning new network and remux work outside the active lifecycle.

New UI must choose deliberately among retained world, online-only world, and typed
freshness. A view-local `isOffline` flag beside an untyped world is not an acceptable
substitute because it permits the two values to drift or render from different root
transitions.

## Recovery coordination

Connection recovery is an edge, not a general render callback. The shell derives a
coarse `suspended` / `connecting` / `online` / `offline` phase as part of its single status
projection. Only `offline -> online` asks the selected tab's top view controller to
`resumeLiveWork()`. First contact from `connecting -> online` is not a resume; each
screen owns its initial appearance.

Foregrounding also asks the visible screen to resume live work immediately. Home
uses the hook to nudge its separate preview store, whose stream failure/backoff
lifecycle remains independent from root connection truth. An immediate preview nudge
replaces any pending backoff so an old sleep cannot enqueue a stale reconnect. Recovery
targets only the visible screen and preserves every tab's navigation stack and existing
screen state. Connection loss never replaces the current screen with a full-screen
takeover.

## Persistent status strip

`AppShellViewController` owns a noninteractive, full-width status strip above the tab
container, outside every navigation stack. The strip remains visible on every tab
and pushed screen. It uses a neutral system-background band and bottom separator,
leaving screen-owned navigation items free for local actions. As the window's root
container, the shell forwards status-bar and home-indicator ownership to its embedded
tab controller.

The leading connection pill renders:

- `Paused` with a neutral dot and material background;
- `Connecting` with a neutral dot and material background;
- `Connected` with a green dot and material background; or
- `Not connected` with a red dot and red-tinted background.

A trailing recording pill renders recorder truth together with the phone's pending
recording command:

- hidden when recorder truth is unknown;
- red `REC` for a live current segment, a fresh starting/recording phase before the
  first segment opens, or a pending local start/record command against a fresh
  no-segment snapshot;
- gray `REC` when last-known truth still has a current segment or claims a
  starting/recording phase; or
- muted `Not recording` when fresh or last-known truth affirmatively says idle.

Stopping without an open segment maps to `Not recording`; `.stopping` deliberately
does not claim recording. The strip never shows elapsed time or owns a timer. Detailed
elapsed presentation belongs to recording surfaces, while the connection pill beside
the recording pill communicates whether the fact is fresh.

The connection pill is pinned leading and drives strip height. The recording pill is
pinned trailing, truncates first at large content sizes, and releases its trailing and
spacing constraints while hidden so it reserves no width. The connection and
recording pills render from one equality-gated projection that also carries the
coarse link phase. Unrelated world changes such as temperature, storage, memory, and
uptime therefore do not wake the strip, and adjacent pills cannot render from
different moments of one reducer transition.

## Testing obligations

Connection behavior is covered at the boundaries where regressions are observable:

- configuration tests pin the 4 second connect, 6 second heartbeat, and 8 second
  receive-idle defaults and reject invalid or sub-heartbeat overrides;
- loopback Network tests prove a silent receive times out, chunked slow progress
  survives, and a slow consumer does not trip the socket-idle deadline;
- root reducer tests cover suspension, pre-snapshot deadline arming, stream start/stop,
  offline folding, command cancellation, reconnect scheduling, fresh command guards,
  and same-phase snapshot recovery;
- link and rendered-projection tests cover live, last-known, and unknown recorder
  truth without erasing freshness;
- strip coordination tests cover pill mapping, `.stopping`, unrelated-world equality,
  and the offline-to-online resume edge; and
- shell tests cover red-to-gray REC on heartbeat loss, affirmative idle, hidden-pill
  width release, first contact, and selected-tab recovery routing.

Incident reducer tests prove queued pulls pause outside the foreground while an active
pull keeps its existing background-task grace and can finish without launching the
next queued pull.

## Decision log

### 2026-06-26: Try one scene-scoped status monitor and ambient indicator

(absorbed from dead app ADR 04, 2026-06-26)

Early Home, Recording, and Debug screens each polled `GET /v1/status` for as long as
their controller lived. A single missed Home poll could say "Can't reach camera" on
the congested link while stale preview frames and clip rows still made the rest of
the app look connected. Foreground and preview recovery were equally screen-local.

The attempted correction was one scene-scoped `ConnectionFeature`: the sole status
reader, started on launch and foreground, stopped in background, and injected into
screens. It retained the last successful response, required three failed polls to
disconnect, recovered on one success, and used `ConnectionResumable` to refresh the
visible screen. Preview retained its independent self-healing backoff.

The first indicator was an always-visible navigation-bar pill re-parented by a
`UINavigationControllerDelegate`. Connectivity stayed ambient so normal Wi-Fi churn
did not destroy screen context. `NWPathMonitor` was rejected because path availability
does not prove the Pi API is reachable. A parallel heartbeat beside screen readers
was rejected because it preserved conflicting truths, and a full-screen disconnected
takeover was rejected because it discarded useful context.

This mechanism did not pan out. The ordered event stream later became the single
connection truth, eliminating the status monitor, three-strike debounce, and
screen-local status facts. The ambient presentation and explicit visible-screen
recovery survived, but moved into the shell.

### 2026-06-26: Move global status out of navigation chrome

(absorbed from dead app ADR 05, 2026-06-26)

Re-parenting a custom navigation item made connection status compete with each
screen's title and actions. More app-wide facts were expected, including recording,
time verification, storage warnings, and pull state, so navigation chrome was the
wrong ownership boundary.

The app introduced `AppShellViewController` as the root container, with a compact,
noninteractive status strip above the embedded navigation content. Standard child
containment and safe-area constraints were chosen over a window overlay, whose
rotation and transition behavior would be more fragile. Keeping the navigation-bar
pill was rejected because it retained re-parenting and control contention. A
full-screen disconnected view was again rejected because connection loss should not
erase the user's current task.

The decision initially carried forward the now-dead `/v1/status` monitor and rendered
only one centered connection pill. Root-store composition later replaced the monitor,
tabs replaced the single embedded navigation controller, and recording added a second
pill. The durable outcome is the persistent shell-owned strip outside all navigation
stacks. This permanently spends a compact strip of vertical space, most visibly above
Home's preview, in exchange for status that does not compete with screen controls.

### 2026-06-29: Bound connection establishment

(absorbed from app ADR 09 and its amendments, 2026-06-29)

The Wi-Fi-pinned `NWConnection` could remain in `.waiting` indefinitely after the
phone left the camera AP. At the time, that stranded the status fetch and left the
strip showing its last successful "Connected" result. The broader problem applied to
every camera client: a connection attempt needed a finite time-to-ready without
treating the first transient `.waiting` state as failure.

The shared byte stream gained a configurable connect deadline. The original default
was 2 seconds. On 2026-07-10 it increased to 4 seconds because TCP retransmits a lost
SYN at roughly 1 second and again around 3 cumulative seconds; admitting both retries
is more tolerant of the camera's congested 2.4 GHz link while remaining below the 6
second heartbeat deadline. Invalid `DANCAM_CONNECT_TIMEOUT_MS` values fall back to the
default.

The original change also wrapped the status fetch in a whole-request timeout and kept
the poller's three-failure debounce. Both were retired when the event stream replaced
polling. Their rough 10 second off-network estimate was replaced by the explicit 6
second event heartbeat policy. A general `HTTPRequestResponse.roundTrip` deadline was
rejected because the then-critical seam was the monitor and the more concrete missing
primitive was time-to-ready. Immediate failure on `.waiting` was rejected because it would turn
ordinary Wi-Fi churn into a terminal attempt. `URLSession` request timeouts were
rejected because the app needs Network-framework interface pinning that prohibits
camera traffic from falling onto cellular. The connect deadline still lacks a dedicated
unsatisfied-path Network harness; configuration tests and app builds cover its current
seams while receive idleness has the loopback integration tests.

### 2026-06-30: Bound post-connect receive idleness

(absorbed from app ADR 11, 2026-06-30)

The connect deadline did not help a socket that reached `.ready` and then received
neither bytes, EOF, nor an error. An AP forwarding failure, range loss, or silent Pi
could leave the async byte stream open forever, preventing preview reconnect, clip
resume, event recovery, and one-shot error reporting.

The receive loop therefore gained a per-chunk idle deadline inside `NWByteStream`,
where timeout can cancel the real connection. One serial queue coordinates receive
callbacks, deadline replacement, terminal state, and consumer termination. The
default is 8 seconds and overrides must remain strictly above the 6 second event
heartbeat so socket policy cannot preempt the deliberate app-level liveness policy.
One value was accepted for all camera clients rather than creating speculative
per-client knobs.

Putting a generic timeout around the downstream async stream was rejected because
the stream is self-driving and buffered: such a wrapper could observe consumer timing,
could not directly reclaim `NWConnection`, and would add a second teardown structure.
A send deadline was rejected because tiny requests complete on local buffer acceptance.
Deriving receive idle from connect timeout was rejected because time-to-ready and
zero-byte inactivity are different failure modes. A default below heartbeat was
rejected because it would make transport policy the connection authority during
tolerable congestion. A whole-request timeout was again rejected because the shared
socket receive loop could bound the actual failure once for every client.

This choice accepts wall-clock loopback tests and queue-affined `@unchecked Sendable`
resolution helpers. A false positive may consume a clip pull retry, so the default
deliberately favors a finite but non-aggressive cutoff.

### 2026-07-08: Require heartbeat-fresh inputs for present-tense UI

(absorbed from app ADR 18, 2026-07-08)

Although `Link` preserved the online/offline distinction, some Home projections read
only `link.world`. After Pi power loss, a retained recorder segment could keep counting,
REC could remain live, and the record button could offer Stop against an unreachable
host. The app cannot know whether the Pi is still recording or lost power while
heartbeats are absent, so it must show what it knows rather than extrapolate.

`RecorderTruth` made freshness explicit. Live segments tick; last-known segments
freeze and mute; unknown state disables present-tense controls. Offline folding also
resets recording command presentation and cancels pending commands. Reconnect compares
fresh online phases rather than last-known phases so an unchanged-phase snapshot still
restores live behavior. Reused recording views must reset live and frozen styling in
both directions so a thaw does not retain stale muted presentation.

Removing the last-known row was rejected because useful segment evidence would flap
away on ordinary link loss. Continuing to tick beneath a stale label was rejected
because motion itself claims current activity. Pairing `link.world` with view-local
offline flags was rejected because every surface could erase freshness differently.
Static last-known temperature, camera, time, and telemetry detail remained allowed
under the visible disconnected state; the rule applies to present-tense claims.

### 2026-07-09: Put recording truth in the global strip

(absorbed from app ADR 21, 2026-07-09)

Home's preview carried a REC overlay driven by phone-side recording command state,
not preview liveness. On heartbeat timeout the command state reset, so the overlay
blinked out even when the retained Pi recorder snapshot said recording was last known.
Preview already had its own Connecting, Live, and Preview offline status; recording
was a system-wide fact better suited to persistent app chrome.

The strip gained a freshness-typed trailing recording pill and the preview REC overlay
was removed. Live truth is red, retained recording truth is gray, affirmative idle is
"Not recording", and unknown truth hides the pill. The connection pill supplies the
freshness context, and elapsed detail remains on recording-specific surfaces.

A single combined projection was chosen over separate observers so adjacent pills
cannot render different moments of one root transition and telemetry-only events do
not wake the shell. Keeping the preview overlay was rejected because it answered the
wrong question and flapped on heartbeat gaps. Adding elapsed time was rejected because
global chrome should not own a timer. The layout accepts the extra two-pill complexity:
the optional pill must release constraints when hidden, and REC accessibility labels
must describe live versus last-known state even though both visible captions are REC.

### 2026-07-15: Represent process suspension as a freshness state

The first process-owned runtime kept its last online or offline `Link` value when the
last scene deactivated. That made retained online state look heartbeat-fresh while no
event stream existed, and it allowed queued incident work to start from lifecycle
callbacks even though the app had left the foreground.

The link now has explicit `suspended(last:)` and freshness-preserving
`connecting(last:)` states. Last-scene deactivation revokes fresh truth immediately,
freezes retained projections, resets recording controls, and cancels ephemeral command
and deadline work. Foregrounding retains those display facts while waiting for the
replacement snapshot. Incident reconciliation separately gates starting queued pulls,
while preserving the already-established UIKit background-task grace for one active
pull.

Keeping stale online state was rejected because it made `onlineWorld` lie about the
only condition that authorizes present-tense controls. Erasing the world on background
was rejected because frozen recorder and telemetry facts remain useful. Cancelling an
active incident pull at the lifecycle edge was rejected because UIKit already provides
a short bounded completion window and abandoning partial progress would make recovery
less reliable.
