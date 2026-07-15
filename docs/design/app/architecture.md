# App architecture

The iPhone app is a programmatic UIKit application built around a small,
repository-owned Elm Architecture (TEA) runtime. One process-owned root store owns
shared domain state and coordination. View controllers render equality-gated
projections of that state; they do not coordinate sibling features or treat UIKit
objects as the source of truth.

The [App-Pi transport boundary](../boundary/transport.md) owns the wire protocol and
networking obligations. This page owns how the app turns inputs from that boundary
into state, effects, and UIKit rendering.

## UIKit shell

The app uses UIKit with programmatic view controllers and no main app storyboard. The
launch-screen storyboard is only a static launch resource. `AppDelegate` eagerly
creates the process-owned `AppRuntime`, dependency bag, and sole `AppStore` without
waiting for a phone window. Each `SceneDelegate` borrows that runtime, builds its tab
navigation controllers, and embeds them in `AppShellViewController`.

`AppRuntime` tracks active scene session identifiers. The first active scene starts
the event stream and foreground work; the last deactivation backgrounds the domain
and stops the stream. Activation and deactivation are idempotent because UIKit may
deliver both background and disconnect callbacks for one scene. Scene teardown gates
only process-ephemeral stream and freshness work; durable state does not depend on a
disconnect callback arriving at process termination.

The shell is persistent app chrome above all tabs. It owns the global status strip,
tab container, incident badge, and the offline-to-online hook that asks the visible
screen to resume live work. Feature view controllers receive the shared store and the
dependencies they need; they never create parallel stores for root domains.

Preview is deliberately separate from the root store. JPEG frames arrive at stream
rate and have their own decode and reconnect lifecycle, so routing every frame through
root state would create needless fan-out. Preview's store carries a generation signal
that changes on every reconnect attempt, even if its phase remains `connecting`, so
decode state can reset through state rather than a render side effect.

Debug is not a separate health domain. It renders telemetry from the root event-folded
world, keeping its values and staleness consistent with every other screen.

## TEA core

`Store<State, Action, Dependencies>` is a small `@MainActor` generic. Its reducer has
the shape:

```swift
reduce(inout State, Action, Dependencies) -> Effect<Action>
```

Reducers synchronously mutate value state and return effect data. They never call the
store directly. `Effect<Action>` supports:

- `.none`
- `.merge`, for effects that start from the same reducer pass
- `.run(id:cancelInFlight:operation:)`, which feeds later actions through an async
  `send` callback
- `.cancel(id:)`
- `.map`, which lifts a child effect into its parent's action space without losing its
  cancellation identity

Dependencies are a struct of closures assembled in the app layer. The architecture
core knows no concrete client or app dependency type. This keeps production clients
replaceable by deterministic test closures without a service locator or third-party
dependency framework.

The store tracks run effects with monotonic internal tokens. Optional public effect
IDs name cancellation domains; `cancelInFlight` cancels the prior token for that ID
before starting its replacement. Completion removes an ID only when it still points to
the completing token, so an older task cannot unregister its replacement. Effect tasks
and callbacks capture the store weakly so long-lived work does not extend the
process-owned runtime's lifetime.

Every externally sent or effect-produced action passes through `send(_:)`, which gives
reducer logging one ordered choke point. When a logger is configured, the store passes
it the action and old/new snapshots. It notifies observers only when the full state
changed and still executes effects returned by a no-state-change reducer pass.

### Concurrency boundary

The store, reducers, and action path stay on the main actor. The Xcode project enables
approachable concurrency and main-actor default isolation for the app target, so an
ordinary effect operation inherits the caller's actor unless it explicitly crosses a
boundary.

CPU- or I/O-heavy work crosses that boundary locally through `@concurrent`, detached
workers, or nonisolated `Sendable` clients and values. Thumbnail decode, remux, media
pull, artifact installation, log export, and share preparation use such explicit
boundaries. The root architecture does not impose blanket `Sendable` annotations on
all state, actions, or dependency closures just in case.

## Process-owned domain root

`AppFeature` is the process domain root shared by phone and future CarPlay scenes. Its
state currently contains:

- `Link`, the connection phase and latest Pi world
- recording command presentation state
- the clip collection and load/reconciliation state
- phone-owned incident state
- the connection-epoch retention estimator
- event-stream reconnect bookkeeping

Child reducers own their local state transitions. `AppFeature.reduce` invokes them
synchronously, maps their effects back into `AppFeature.Action`, and owns only rules
that cross child boundaries. Current examples include:

- routing the record button to start or stop based on recording state
- folding recorder phases into the optimistic recording control
- merging finalized and removed clips into clip and incident state
- feeding world and recorder lifecycle evidence to incidents
- starting a clip-head load and time sync after a fresh snapshot
- retrying a retryable failed clip-head load from an online heartbeat
- resetting connection-epoch estimates when the stream stops, fails, or receives a
  replacement snapshot

Screens are projections over this root. They do not bridge child stores or infer a
second domain model from controller-local flags. Cancellation IDs share one root
namespace and therefore remain domain-prefixed.

## Event-folded world

The app mirrors the canonical [event wire reference](../../reference/events.md) in
`CameraEvent`. Every event type in the golden corpus must decode to a concrete case.
An event type added by a newer Pi decodes as `.unknown(type:)` and is a safe no-op
until the app adds its typed mirror.

Connection and Pi-owned state use one sum type:

```swift
enum Link: Equatable {
    case suspended(last: World?)
    case connecting(last: World?)
    case online(World)
    case offline(last: World?)
}
```

`World.folding(_:_:)` is a pure fold:

- A snapshot replaces the whole world and moves an active link online. Suspended
  callbacks are ignored.
- Deltas apply only to an online world. A delta received before the base snapshot, or
  after the link went offline or suspended, is ignored.
- Recorder, camera, readiness, storage, temperature, memory, CPU, and time deltas
  update their typed world fields.
- A heartbeat advances only `World.uptimeS` from `t_ms`; it does not refresh or infer
  any other field.
- Clip finalization and removal do not mutate `World`; `AppFeature` routes those facts
  to the clip and incident reducers.
- Unknown events do not mutate state.

Suspended, connecting, and offline links retain a stale-but-useful world without
presenting it as live. Present-tense projections must preserve this freshness
distinction rather than erase it by selecting only the optional world value. The last
active scene moves the link to `suspended(last:)`; the next activation moves it to
`connecting(last:)`; only a replacement snapshot restores online truth.

The root owns one long-lived event-stream effect. Starting it also arms the heartbeat
deadline before the first snapshot so a connected but silent stream cannot leave the
app in `connecting` forever. Every received event replaces that deadline. Stream
failure or deadline expiry moves the link offline, cancels live work as appropriate,
resets connection-scoped state, and schedules a bounded reconnect. The current
deadline is 6 seconds, or three missed 2 second Pi heartbeats. The broader liveness and
foreground lifecycle policy belongs to the [app connection design](connection.md); the
architecture invariant is that SSE is the single ordered connection truth, never a
fallback beside `/v1/status` polling.

Recording controls are locally optimistic but reconcile against Pi-owned
`RecorderPhase`. While starting, a stale `idle` event cannot undo the optimistic
transition; while stopping, a stale `recording` event cannot undo it. Authoritative
success or error phases settle the overlay, and command-phase events also update a
client that did not issue the command. Evidence-like recording and clip surfaces use
the Pi-owned recorder and segment facts, not the optimistic control state. A displayed
open-segment duration is a local count-up seeded from the snapshot or segment-open
duration and advances only while that recorder truth is heartbeat-fresh; finished
duration comes from the finalized clip fact.

`ClipsFeature` keeps its collection across loads. A `clip_finalized` event upserts by
clip ID regardless of the current load status, while one-shot history responses
reconcile by ID and request epoch instead of blindly replacing the collection. This
prevents an older response from erasing a newer stream fact. Explicit removal events,
successful deletes, and authoritative head reconciliation remove clips through the
feature's tombstone rules. An online heartbeat starts at most one head retry when the
last failure is retryable; HTTP 4xx and decoding failures wait for a snapshot or
manual refresh.

## Observation and rendered projections

Store observation is selector-based. `observe(select:)`:

1. evaluates a pure projection from root state to an `Equatable` value;
2. fires once at registration;
3. fires again only when that selected value changes.

Key-path observation is one-line sugar over the selector primitive. Before invoking a
callback, the observer records its new cached value. Store notification also iterates
a snapshot of registered observers. Together these rules make a callback that sends a
new action re-entrant without duplicate delivery or mutation-during-iteration bugs.

Controllers select the narrowest value that is already their rendered view state.
Examples include the shell's combined connection/recording projection, Home's live
recording inputs and warning pills, Settings' recording-storage projection, and the
incident list projection. A raw child slice is appropriate when that slice already is
the view state. View-shaped fields do not belong in `AppFeature.State` merely to make
observation convenient.

Freshness is part of a projection whenever the UI makes a present-tense claim. A
selector must not collapse online and offline-last-known inputs to the same output if
that would let stale recorder or telemetry state look live.

## Identity-preserving UIKit updates

List controllers use diffable data sources when stable identity matters. Home derives
section and row values from root state, keys rows by durable identity, and reconfigures
only identities that survived from the old snapshot with changed rendered values.
Content is never used as identity, and unrelated domains do not trigger table reloads.

Home submits `reconfigureItems`, not `reloadItems`, for changed rows. This configures a
visible cell in place, preserving an already-painted same-identity thumbnail and scroll
position. The cell provider captures its controller weakly. Thumbnail prefetch handles
are keyed by clip identity (`id` plus `etag`), not index path, and a new row projection
prunes only identities that actually departed.

The exact Home grouping and row identities can evolve with the browsing model. The
durable architecture rule is that identities describe entities, content changes are
reconfigures, and selector projections prevent unrelated state from churning visible
UIKit work.

## Testing obligations

The architecture is small because the project owns and tests the hard parts directly:

- Store runtime tests cover effect execution, merge/map, ID cancellation and
  replacement, weak lifetime, equality gating, selector deduplication, cancellation,
  and re-entrant observation.
- The generic `TestStore` drives reducer actions and received effect actions with
  deterministic dependency closures.
- `AppFeature` tests cover event folding and the cross-domain rules rather than UIKit
  implementation details.
- Projection tests assert derived `Equatable` view state.
- Controller tests assert behavioral outcomes that pure projections cannot cover,
  including identity-preserving reconfiguration and thumbnail/prefetch survival.

## Decision log

### 2026-06-24: Use programmatic UIKit and a minimal repository-owned TEA

(absorbed from app ADR 03, 2026-06-24)

The first implementation slice needed a UI and state-management direction before the
health client landed. The unusual decisive force was that development is LLM-driven:
small, local, self-consistent APIs are easier to generate and review than large
external frameworks whose idioms have changed across versions. The app was also narrow
in scope, while its hardest surfaces -- MJPEG frame presentation, `AVPlayer`, and
CarPlay templates -- were already UIKit-shaped.

Programmatic UIKit and a minimal TEA made actions, state changes, and effects explicit.
Pure reducers, a main-actor store, data-shaped effects, closure dependencies, and a
hand-written `TestStore` offered a single traceable action stream with no third-party
architecture dependency. Zero dependencies was a consequence of owning this small
core, not a repository-wide ban on packages.

The main-actor posture matched the project's approachable-concurrency settings and
avoided broad `Sendable` requirements on the ordered action path. Off-main work was
reserved for deliberate local boundaries. Owning the runtime also meant owning
cancellation correctness, re-entrancy, task lifetime, and weak store capture, so direct
runtime tests were part of the choice.

SwiftUI was rejected because its implicit observation model duplicated the TEA source
of truth, its idioms move quickly, and the app's difficult surfaces were UIKit-native.
The Composable Architecture was rejected because its several API eras make mixed-era
LLM output likely. Mobius.swift would add a dependency for a core small enough to own;
ReSwift was too stale for a greenfield base. MVVM, MVC, VIPER, and Clean Swift did not
provide the same effect-as-data model and single action stream. A large custom
framework was also rejected: the point was a tiny standard architecture, not novelty.

The initial context mentioned loopback-HLS playback. That surface was later removed;
UIKit-hosted `AVPlayer` now plays durable cached MP4 files. The architecture rationale
did not depend on the retired loopback server.

### 2026-06-26: Move coupled domains into one scene-scoped root

(absorbed from app ADR 06, 2026-06-26)

Early Home code owned separate connection, recording, and clip stores, then coordinated
them in the view controller. Connection changes seeded recording, recording-stop
transitions refreshed clips, and pull-to-refresh carried controller-local gates. Those
were domain rules needed by future screens and CarPlay, not Home layout concerns.

The first store runtime also notified every observer after every action. Frequent
connection updates woke unrelated screens and pushed defensive diffing into view
controllers. The response was a scene-scoped, domain-organized `AppFeature`, effect
merge/map, equality-gated store notifications, and scoped observation. Child reducers
stayed synchronous and the root became the only owner of cross-domain rules.

Re-entrant sends were accepted deliberately. Selector caches update before callbacks,
and observer iteration uses a snapshot, so a shell recovery callback can send into the
same store safely. The one shared effect-ID namespace was accepted with the constraint
that IDs stay domain-prefixed.

Preview stayed separate because stream-rate frame state would cause avoidable root
fan-out. The original decision also left a separate health store because it had no
cross-domain consumers. That part did not survive: Debug now reads the event-folded
root world and the duplicate health lifecycle is gone. The original polled connection
slice was likewise replaced by `Link` and ordered events, while the scene root,
equality gating, scoped observation, shell ownership, and preview boundary survived.

Per-screen stores were rejected because they left domain coordination in controllers.
A `HomeFeature` root would bind shared rules to one page. Folding preview into the root
would route high-rate frame state through every observer, and folding health in before
it had shared consumers was premature. Notifying every observer and relying on local
diffing was rejected because it made render policy fragmented and wakeups the default.

### 2026-06-29: Fold the ordered Pi event stream into app state machines

(absorbed from app ADR 10, 2026-06-29)

The first root treated connection as a 1.5 second `/v1/status` poll with a three-failure
debounce. It diffed flat status fields to coordinate recording and clips. Poll responses
could race clip finalization, and local recording optimism could briefly present the
last finished segment as the live row before the Pi opened a new segment.

The Pi already owned the recorder state machine and an ordered snapshot/delta/heartbeat
stream. Mirroring that model through `CameraEvent`, `Link`, and the pure `World` fold
removed the poll-era flag cluster. The stream became connection truth; recorder phases
became recording truth; finalized-clip events merged into clip state; and snapshot
replacement established a coherent base before deltas.

Unknown event types became explicit safe no-ops, while the golden corpus continued to
fail if a known contract event lacked a typed mirror. `offline(last:)` intentionally
retained stale detail for screens able to label it honestly. A local optimistic control
was retained for responsiveness, but evidence-like rows required Pi-owned segment
facts. One-shot clip loads merged with stream facts so a stale response could not erase
a clip finalized later in stream order.

Later refinements kept this model while making heartbeat update only uptime, routing
clip removal explicitly, and using online heartbeats as the retry clock for one
retryable failed clip-head load. That retry adds no independent timer or cancellation
lifecycle and cannot outlive the event stream. Telemetry values remain opaque,
service-coarsened observations; the app does not infer precision the Pi did not send.

Keeping `/v1/status` polling as fallback was rejected because dual truth preserves the
ordering bugs. URLSession-style event APIs were rejected because Pi traffic must use
the Wi-Fi-pinned `NWConnection` transport. Driving evidence rows from optimistic local
recording was the bug being removed. Replacing clips on every one-shot response was
rejected because an older response can arrive after a finalized event.

### 2026-07-02: Observe rendered projections and preserve list identity

(absorbed from app ADR 17, 2026-07-02)

The process root and equality-gated key-path observation still left screens observing
state wider than what they rendered. Home status pills and telemetry views woke for
unrelated world changes. Home also called `reloadData()` for every row update. Once
thumbnail cells owned asynchronous loads, those broad reloads blanked painted images,
restarted work, and made telemetry updates visibly flicker the clip list.

Selector-based observation became the store primitive so screens could observe the
derived `Equatable` values they actually render. Key paths remained sugar for slices
that already are view state. Home moved to a diffable data source with entity-shaped
row IDs, changed surviving rows through `reconfigureItems`, and keyed thumbnail
prefetch by clip identity rather than index path. This preserved cells, scroll position,
and warmed thumbnail work across unrelated updates.

Computed view-state fields on root domain state were rejected because they put page
shape into the domain model. Combine, Observation, and KVO added machinery without
improving on the small TEA primitive. Narrow observation with `reloadData()`, or merely
gating that reload on array equality, still flashed every visible thumbnail on a real
one-row change. Whole-row identity turns content changes into delete/insert; bare
numeric clip identity cannot represent every distinct row shape. Hand-written batch
diffing was rejected in favor of UIKit's tested diffable identity and reconfigure path.

### 2026-07-15: Move domain runtime ownership above UI scenes

CarPlay may launch the app directly into the background with only a
`CPTemplateApplicationScene` and no phone window scene. A runtime lazily initialized by
the first phone `SceneDelegate` would therefore leave domain work unavailable to a
valid process entry point. `AppDelegate` now eagerly owns one `AppRuntime`, dependency
bag, and `AppStore`; UI scenes borrow that process root instead of creating their own.

The runtime tracks active scene session identifiers and gates process-ephemeral stream
and freshness work at the first-activation and last-deactivation edges. UIKit may send
both background and disconnect callbacks for one session, so deactivation is
idempotent. Disconnect is not guaranteed at process termination, so this lifecycle
owns no durable work and requires no teardown callback for correctness.

Per-scene stores were rejected because phone and CarPlay surfaces would diverge on
connection, recording, clips, and incidents. Lazy initialization by the first phone
scene was rejected because CarPlay can be the process's only initial scene. Durable
cleanup on disconnect was rejected because termination does not guarantee that
callback.
