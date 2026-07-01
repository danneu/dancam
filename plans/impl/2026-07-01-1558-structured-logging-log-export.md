# Plan: structured, LLM-legible logging + in-app log export

## Context

Dan routinely copies Xcode logs into an LLM to debug the app while running it. For
that to work, a log dump needs to be a **state-reconstruction artifact**: someone
reading it cold (an LLM, or Dan weeks later) should be able to rebuild what the app
was doing -- which screen, the connection/heartbeat state, and where each clip is in
the pull -> remux -> playback pipeline.

Today the app logs almost nothing. There are exactly **4 emit sites** across 3 files,
all on `os.Logger` (subsystem `com.danneu.dancam`, categories `pull` / `ts-demux` /
`h264-au`). The connection/heartbeat reducer, the clip-pull reconnect loop, the remux
engine, the `ViewerState` playback machine, and navigation all emit **nothing** --
state is surfaced only to the UI.

We evaluated the landscape (Apple `os.Logger`/OSLog, `apple/swift-log`, Pulse,
CocoaLumberjack) and chose to stay on **Apple-native unified logging** ("option 1"):
it is already in use, zero-dependency (the whole app has zero third-party deps), has
native Xcode console integration, and -- via `OSLogStore` -- can export the app's own
logs on-device for when Dan is debugging in the car with no Xcode attached. The other
libraries add a dependency and indirection for portability/features this single iOS
target does not need (see ADR, Alternatives).

This plan adds three things on top of `os.Logger`: (1) a unified `Log` namespace +
logging convention, (2) state-transition coverage across the reducer and the async
pipelines, and (3) an in-app `OSLogStore`-backed "Export logs" action.

## Decisions locked

- **Engine:** stay on `os.Logger` / OSLog. No new dependency.
- **Transition hook:** an optional injected `log` closure on `Store` (default `nil`;
  only the live `AppStore` opts in). This realizes what ADR
  `app/docs/design/03-2026-06-24-app-ui-architecture.md` already calls the "action
  log" at the `Store.send(_:)` choke point, where `old`, new `state`, and `action`
  are all in scope. Generic infra stays generic (no new constraint on `Action`); the
  domain rendering lives in `AppFeature`; `TestStore` and `StoreTests` stay silent.
- **Correlation id:** the existing **bare `Int` clip id**, emitted as a `clip_id=`
  field. We do NOT introduce a `ClipID` newtype (a wide, separate refactor -- see Out
  of scope).
- **Levels:** `.notice` for state transitions and boundaries (persisted, so they
  survive into `OSLogStore` exports and show in Xcode); `.info` for optional detail;
  `.debug` for hot paths and no-op transitions; `.error` for genuine failures.
  Per-clip terminal outcomes -- pull completion and remux finish, not only failures --
  are boundaries, so they emit at `.notice`. Critically, `.info` and `.debug` live only
  in the in-memory ring buffer; the unified-logging system does not persist them to the
  data store that `OSLogStore(scope: .currentProcessIdentifier)` reads, so they can be
  absent from an export (they still show in a live Xcode / `log stream` session).
  Nothing an export must contain may live at `.info`/`.debug`.
- **Privacy:** diagnostics default to `privacy: .public`. Nothing here is sensitive
  (clip ids, byte counts, states, phases), and `.public` is what keeps *exports* and
  Console.app captures from redacting to `<private>`. (Debugger-attached Xcode shows
  values regardless, but the export path does not.)
- **Export:** `OSLogStore(scope: .currentProcessIdentifier)` behind a `LogExporter`
  dependency, surfaced as a share-sheet button on the existing Health/"Debug" screen.
- **Logs are phase/boundary records, not a mirror of every state mutation.**
  Value-carrying states (e.g. per-chunk pull progress) collapse to a derived phase
  before logging at `.notice`; raw progress is `.debug` at most. This keeps the
  persisted stream -- and the export -- a clean state-reconstruction artifact instead
  of a firehose.
- **Actor isolation.** The app target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
  (both build configs), but the pull/remux code is `nonisolated`. Every shared
  diagnostic touched off-main (`Log`, the `LogLine` value type, `formatLogLines`, the
  `LogExporter` struct, and the `Duration` helper) is declared `nonisolated` so it
  compiles from those contexts without isolation warnings.

## Approach (phased commits)

Each phase is a self-contained, shippable commit; later phases build on earlier ones.

1. **`Log` namespace + convention** -- introduce the namespace, migrate the 3 existing
   loggers onto it. No behavior change.
2. **Reducer transition hook** -- `Store` seam + `AppFeature` render helpers +
   `SceneDelegate` wiring + a foreground snapshot line. Lights up
   link/heartbeat/reconnect/recording/clips transitions.
3. **Pipeline coverage** -- clip pull, remux (engine + demuxer + assembler),
   `ViewerState`, and a navigation delegate.
4. **In-app export** -- `LogExporter` dependency (`.live` OSLogStore / `.noop`), pure
   formatter, Health-screen button + `UIActivityViewController`.
5. **Docs** -- ADR 14, `AGENTS.md` convention section, `Justfile` log-stream recipe.

## Changes by area (stable anchors, not line numbers)

### 1. `Log` namespace -- new `app/DanCam/DanCam/Diagnostics/Log.swift`

A single enum that owns the subsystem and one `Logger` per area. Categories double as
the greppable subsystem tags. Keep the three existing category strings verbatim
(`pull`, `ts-demux`, `h264-au`) for continuity; add the new ones.

The declaration is `nonisolated` (the app target defaults to `MainActor` isolation, but
`Log` is read from the `nonisolated` pull/remux code; `Logger` is `Sendable`, so
`nonisolated` static lets are fine).

```swift
import OSLog

nonisolated enum Log {
    static let subsystem = "com.danneu.dancam"

    static let reducer  = Logger(subsystem: subsystem, category: "reducer")
    static let pull     = Logger(subsystem: subsystem, category: "pull")
    static let remux    = Logger(subsystem: subsystem, category: "remux")
    static let tsDemux  = Logger(subsystem: subsystem, category: "ts-demux")
    static let h264     = Logger(subsystem: subsystem, category: "h264-au")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let nav      = Logger(subsystem: subsystem, category: "nav")
}
```

Migrate the three ad-hoc `private static let logger = Logger(...)` declarations in
`ClipPullClient.swift#ClipPullClient`, `Media/Remux/TSDemuxer.swift#IncrementalTSDemuxer`,
and `Media/Remux/H264AccessUnitAssembler.swift#H264AccessUnitAssembler` to reference
`Log.pull` / `Log.tsDemux` / `Log.h264`. The `OSSignposter` in `ClipPullClient` stays
(built from `Log.pull`).

### 2. Store transition seam -- `Architecture/Store.swift#Store`

Add an optional injected closure; default `nil` keeps every existing call site
compiling and silent.

```swift
private let log: ((_ action: Action, _ oldState: State, _ newState: State) -> Void)?

init(initialState: State,
     dependencies: Dependencies,
     reduce: @escaping Reducer,
     log: ((Action, State, State) -> Void)? = nil) { ... self.log = log }

func send(_ action: Action) {
    let old = state
    let effect = reduce(&state, action, dependencies)
    log?(action, old, state)          // <- new; runs for every send, incl. effect re-entry
    if state != old { notifyObservers() }
    execute(effect)
}
```

Because effects re-enter `send` (`Store.execute`'s `.run`), effect-emitted actions
(`.streamFailed`, `.streamReconnect`, `.heartbeatTimedOut`, `.event(...)`) pass
through and are logged. Known limitation to document in the ADR: sub-reducers invoked
inline inside `AppFeature.reduce`'s `.event` case (`ClipsFeature.reduce`,
`reduceRecording`) do NOT pass through `send`, so their child actions won't appear as
separate lines -- the resulting `State` delta still does.

### 3. Reducer render helpers + wiring -- `Features/App/AppFeature.swift`, `App/SceneDelegate.swift`

Add pure, `.public`-safe render helpers on `AppFeature` (co-located with the types
they read):

- `AppFeature.Action.logLabel: String` -- compact case name, e.g. `streamFailed`,
  `event.heartbeat`, `event.snapshot`, `clips.load`.
- `AppFeature.State.logSummary: String` -- one-line state, e.g.
  `link=online recording=recording clips=loaded recon=0` (derive link phase from
  `Link` `.connecting/.online/.offline`).
- `AppFeature.State.logSnapshot: String` -- fuller "you are here" line (adds
  world/recorder detail when online) for the snapshot anchor.
- `static func logTransition(_ action:_ old:_ new:)` -- emits
  `Log.reducer.notice("action=<label> <oldSummary> -> <newSummary>")` when the summary
  changed, else `Log.reducer.debug("action=<label> (no change)")`. All interpolations
  `privacy: .public`. (Heartbeats are no-op transitions -> `.debug` by design, so they
  don't spam `.notice`.)

Wire it in `SceneDelegate.scene(_:willConnectTo:)`:

```swift
let appStore = AppStore(initialState: AppFeature.State(),
                        dependencies: dependencies,
                        reduce: AppFeature.reduce,
                        log: AppFeature.logTransition)
```

Emit the snapshot anchor at launch (after building `appStore`) and in
`SceneDelegate.sceneWillEnterForeground`:
`Log.reducer.notice("snapshot \(appStore.state.logSnapshot, privacy: .public)")`.

### 4. Clip-pull coverage -- `Networking/Clips/ClipPullClient.swift#ClipPullClient`

`clipID` is in scope only in `producePull` today: the reconnect switch and the
terminal-failure boundary both live there, but the `.restarted` event is yielded from
`prepareBodyDecoder` (reached via `runAttempt`), which does not receive `clipID` -- so
thread `clipID` into `runAttempt(...)` -> `prepareBodyDecoder(...)` to key the restart
line. Add, all keyed `clip_id=\(clipID, privacy: .public)`:

- **Promote the existing completion line from `.info` to `.notice`.** The one-per-clip
  completion summary (`bytes` / `elapsed_s` / `throughput_mbps`) is a terminal success
  boundary that must survive into exports; it stays exactly one line per successful
  pull. (`.info` would be memory-only -- see Levels.)
- `.notice` on each reconnect in `producePull`'s `.retry(madeProgress:)` switch branch:
  reason (`stall` vs `progress`), `bytes`, `consecutive_stalls`, `total_reconnects`,
  `backoff_ms`.
- `.notice` on the `.restarted` rewrite-from-zero (validator change) branch, emitted in
  `prepareBodyDecoder`'s `case 200:` path (using the threaded `clipID`).
- **One terminal-failure boundary.** Wrap the `producePull` body in a single
  `do/catch`; on *any* thrown terminal error -- `.http` / `.malformedResponse` /
  `.file` / `.transport` / `.exhausted(reason)` -- emit exactly one
  `Log.pull.error("clip_id=... phase=pull error=\(error)")`, then rethrow (finish the
  stream with the error) as today. This guarantees a single reliable, `clip_id`-keyed
  root-cause line for every failed pull regardless of variant; the reconnect `.notice`
  breadcrumbs above supply the lead-up. (Replaces logging only the `.exhausted` case.)

### 5. Remux coverage -- `Media/ClipRemuxer.swift`, `Media/Remux/ClipRemuxerEngine.swift`, `Media/Remux/TSDemuxer.swift`, `Media/Remux/H264AccessUnitAssembler.swift`

Thread the `Int` clip id down the *actual* call chain so remux-path logs correlate.
The engine reaches the demuxer through static `TSDemuxer.demuxH264(from:)` (not a direct
`IncrementalTSDemuxer` init), and `H264AccessUnitAssembler` is a static enum whose entry
point is `assemble(packets:timescale:)` (no init). So:

- Add a `clipID: Int` parameter to `ClipRemuxerEngine.remux(...)` /
  `remuxSynchronously(...)`; `ClipRemuxer.live` already has `clipID` in scope and passes
  it in (single call site, no default needed).
- Thread a **defaulted** `clipID: Int? = nil` through the demux chain:
  `TSDemuxer.demuxH264(from:clipID:)` -> `demuxH264(from:clipID:)` ->
  `demuxH264PESPackets(from:clipID:)` -> `IncrementalTSDemuxer(clipID:)` (stored, used by
  its two one-shot notices) and
  `H264AccessUnitAssembler.assemble(packets:timescale:clipID:)` (used by its one-shot
  notice). Defaulting to `nil` keeps the existing `TSDemuxerTests` /
  `H264AccessUnitAssemblerTests` call sites compiling unchanged; the lines include
  `clip_id=` only when present.
- `ClipRemuxerEngine.remuxSynchronously`: `Log.remux.notice` at start (`clip_id`,
  source bytes) and at finish (`clip_id`, out bytes, duration) -- **finish is `.notice`,
  not `.info`**, because a completed remux is a boundary that must appear in exports.
  Optionally `.debug` the `firstDecodeTicks` DTS-rebase base.
- **One terminal-failure boundary.** Wrap the whole remux stage (demux + H264 assembly
  + MP4 write) at its outer boundary -- the `ClipRemuxer.live` closure, where `clipID`
  is in scope -- in a single `do/catch` that logs *any* terminal `ClipRemuxError`
  (`.invalidTransportStream` / `.invalidH264` / `.writer` / `.file`) once as
  `Log.remux.error("clip_id=... phase=remux error=\(error)")`, then rethrows. Catching
  at the facade (not per-`throw` inside the engine) covers the demux/H264/format-
  description failures that occur *before* the `AVAssetWriter` `do/catch`, so a failed
  remux always leaves one `clip_id`-keyed root-cause line.
- Add `clip_id` to the existing one-shot `.notice` lines in `IncrementalTSDemuxer`
  (`logResyncIfNeeded` / `logDroppedPacketIfNeeded`) and `H264AccessUnitAssembler` (the
  DTS-discontinuity notice), keeping the once-only guards.

### 6. Playback + navigation -- `Features/ClipViewer/ClipViewerViewController.swift`, `App/AppShellViewController.swift`

- Playback: log a **derived viewer phase**, not the raw `ViewerState`. Because
  `.pulling(PullProgress)` carries progress that changes on *every* downloaded chunk,
  logging the raw `didSet` would emit a `.notice` per chunk and drown the export.
  Compute `ViewerState.logPhase` that collapses `.pulling(_)` to `pulling` (phases:
  `pulling` / `preparing` / `playing` / `failed`), and emit
  `Log.playback.notice("clip_id=\(clip.id, privacy: .public) viewer <oldPhase> ->
  <newPhase>")` only when the phase changes. Per-progress detail, if wanted at all,
  goes to `.debug` (throttled) -- never `.notice`. Also log (once each) the
  `handlePlayerItemFailed` self-heal decision (cache-hit re-pull vs fail) and the chosen
  `PlaybackSource` (`cacheHit` / `freshRemux`). Emit the source line in
  `play(_:source:)` -- the single point both entry paths converge on -- because the
  cache-hit path calls `play(_:source:)` straight from `viewDidLoad` and only
  `.freshRemux` flows through `prepareAndPlay`; logging inside `prepareAndPlay` would
  miss every cache hit.
- Navigation: make `AppShellViewController` the `UINavigationControllerDelegate` of the
  nav controller it already owns, and in `navigationController(_:didShow:animated:)`
  emit `Log.nav.notice("screen=\(name)")`. Name via `String(describing: type(of:
  viewController))` (optionally a tiny `LogNamed` protocol for friendlier names). One
  seam covers push, pop, and back-swipe.

### 7. Export -- `App/AppDependencies.swift`, new `Diagnostics/LogExporter.swift`, `Features/Health/HealthViewController.swift`

- New `LogExporter` client (mirrors the repo's `.live`/`.noop` closure-struct idiom):

  ```swift
  nonisolated struct LogExporter: Sendable {
      var export: @Sendable (_ since: Duration) async throws -> String
      static let live = LogExporter { since in /* OSLogStore fetch + format */ }
      static let noop = LogExporter { _ in "" }
  }
  ```

  `.live`: `OSLogStore(scope: .currentProcessIdentifier)`; compute the cutoff as
  `store.position(date: Date(timeIntervalSinceNow: -since.timeInterval))`, where
  `Duration.timeInterval` is a small `nonisolated` helper via `.components` (Swift's
  `Date` subtracts a `TimeInterval`, not a `Duration`, so `Date.now - since` would not
  type-check). Then `getEntries(at:matching:)` with `NSPredicate(format: "subsystem ==
  %@", Log.subsystem)`, map each `OSLogEntryLog` to a small `nonisolated` `LogLine`
  value (`date`/`category`/`level`/`composedMessage`), then a **pure**, `nonisolated`
  `formatLogLines(_:) -> String` (`[time] [category] [level] message`). The pure
  formatter is the unit-tested seam; the `OSLogStore` fetch is not.
- Register in `AppDependencies`: add `var logExporter: LogExporter`, default `.noop`
  in the memberwise init, `= .live` in the `configuration:` init.
- `HealthViewController`: retain `dependencies` as a stored property; add an "Export
  logs" `UIButton` next to `reloadButton` in the existing stack. Factor the work into a
  testable async method `func buildExportText() async -> Result<String, Error>` that
  calls `dependencies.logExporter.export(.seconds(600))` and, on success, prepends a
  header (`appStore.state.logSnapshot` + app version). The `@objc` tap handler branches
  on the result: on `.success`, present `UIActivityViewController(activityItems:
  [text])`; on `.failure`, surface a **visible** error (reuse the existing `errorLabel`
  or present a `UIAlertController`) -- it must never silently swallow an `OSLogStore`
  error. Record the last result in a test-visible `private(set) var lastExportOutcome`
  so tests can assert the workflow without inspecting the presented share sheet.
  Presentation stays in the VC (like `ClipViewerViewController` drives its async work
  directly), not routed through the reducer. This is the app's first
  `UIActivityViewController`.

## Docs

- New ADR `app/docs/design/14-2026-07-01-structured-logging-and-export.md` (next seq is
  14). Follow the house template: `# ADR: ...` H1; bullets **Status:** Accepted /
  **Date:** / **Owner:** app / **Related:** (link ADR 03 "action log", root
  `AGENTS.md`); `## Context` / `## Decision` / `## Consequences` (Easy / Hard or risky)
  / `## Alternatives considered` (os.Logger chosen; swift-log / Pulse / CocoaLumberjack
  rejected, one line each). Document the sub-reducer-not-through-`send` limitation and
  the `OSLogStore` caveats: current-process scope only (no prior-process/crash logs,
  see Out of scope), and -- called out for future emit sites so they pick levels
  correctly -- `.info`/`.debug` live only in the in-memory buffer and can be absent from
  exports, so any export-critical line must be `.notice` or higher (see Levels).
- `app/AGENTS.md`: add a short "Logging" convention subsection (source of truth for
  conventions) -- subsystem, category-as-tag, level ladder (incl. the persist split:
  `.notice`+ reaches exports, `.info`/`.debug` are memory-only), `.public` default,
  `clip_id` correlation field.
- `Justfile`: add an `app-logs` recipe for tethered/simulator streaming, e.g.
  `xcrun simctl spawn booted log stream --level debug --predicate 'subsystem ==
  "com.danneu.dancam"'`, and note Console.app for a physical device.

## Tests (behavioral, structure-insensitive)

- `StoreTests` (real `Store`): a store built with a capturing `log:` closure invokes it
  with `(action, oldState, newState)` on `send`, and the default-`nil` store does not
  crash / stays silent. Tests the *seam fires*, not any string.
- `LogExporterTests` (new, Swift Testing): the pure `formatLogLines` renders sample
  `LogLine`s so the output contains the category, level, and message tokens (assert
  on token presence/order, not exact whitespace).
- `HealthViewControllerTests` (new/extended, Swift Testing): drive the export workflow
  with an injected `LogExporter`, mirroring `ClipViewerViewControllerTests`' factory +
  read-only-seam style. With a **succeeding** exporter, `buildExportText()` returns
  `.success` whose text contains the snapshot header and the exporter body (proving the
  dependency is actually invoked), and `lastExportOutcome` records success. With a
  **throwing** exporter, the tap path records `.failure` and surfaces a visible error
  (`errorLabel` set / alert requested), never swallowing it. Assert via the exposed
  seams; the actual `UIActivityViewController` presentation is the thin, untested UI
  step.
- DI smoke: `AppDependencies` memberwise init still builds with `logExporter` defaulted
  to `.noop`, so existing `AppFeatureTests` / `ClipViewerViewControllerTests` factories
  compile unchanged.
- Signature compatibility: the demux/assembler `clipID` params default to `nil`, so the
  existing `TSDemuxerTests` / `H264AccessUnitAssemblerTests` call sites compile unchanged
  (no test churn from clip-id threading).
- **Explicitly not tested:** exact transition-log strings (`logSummary`/`logLabel`
  output) -- they are diagnostic side effects; asserting them verbatim is brittle and
  structure-sensitive. The live `OSLogStore` fetch -- system I/O with entitlement and
  process-scope constraints; verified manually/in Instruments, not in the unit suite.

## Verification

- `just app-test` is green.
- Run in the simulator against the mock Pi on the host loopback -- `just raspi-mock`,
  app pointed at `http://127.0.0.1:8080` (the simulator shares the Mac's loopback). Use
  `just raspi-mock-clips` (same `127.0.0.1:8080` bind) for the clip-open and
  force-a-failure steps below, which need a finished clip at `/v1/clips`. `just
  raspi-mock-lan` / `0.0.0.0:9000` is for physical-device LAN testing only, not the
  simulator.
  - Launch -> a `snapshot ...` line; background then foreground -> another snapshot.
  - Toggle the mock Pi off/on -> `Log.reducer` shows
    `action=streamFailed link=online -> link=offline`, the reconnect backoff, and
    recovery to `online`; heartbeats stay at `.debug`.
  - Open a clip -> `Log.pull` reconnect/complete, `Log.remux` start/finish (same
    `clip_id`), `Log.playback` `viewer pulling -> preparing -> playing` (one line per
    phase, not per chunk).
  - Force a failure (kill the mock Pi mid-pull, or feed a corrupt clip) -> exactly one
    `Log.pull`/`Log.remux` `error ... phase=... clip_id=...` root-cause line, and
    `Log.playback viewer ... -> failed`.
  - Navigate Home -> Debug -> a clip -> `Log.nav screen=...` lines.
- Tethered: `just app-logs` streams the above live.
- On the Debug screen, tap "Export logs" -> share sheet -> the shared text starts with
  a state snapshot header and contains recent transitions with **real values** (clip
  ids, phases), not `<private>`. Confirm the pull-completion and remux-finish lines for
  a successful clip are present in the export (proving those boundaries are `.notice`/
  persisted, not memory-only `.info`).
- `just adr-check` passes (ADR 14 filename/sequence valid).

## Out of scope / deferred

- **Crash-survivable file sink.** `OSLogStore(scope: .currentProcessIdentifier)` cannot
  read a previous process, and `.debug` is not persisted -- so an in-car crash loses
  its pre-crash logs. If field crash forensics become necessary, add a small rotating
  file sink under the same `Log` convention. Noted, not built.
- **`ClipID` newtype.** The bare `Int` risks being confused with other int fields;
  hardening it into a type is a wide, separate refactor (touches `Clip`, pull, remux,
  cache, events) and is orthogonal to logging.
- **Remote / streamed logging** (e.g. Pulse-style on-device inspector or live remote
  view). Revisit only if the export button proves insufficient.
- **Preview/MJPEG hot-path logging** stays off (or `.debug` only) to avoid a firehose.

## Commit progress

- [x] 1. Log namespace and convention
- [x] 2. Reducer transition hook
- [x] 3. Pipeline coverage
- [x] 4. In-app export
- [ ] 5. Docs

## Implementation notes

- Reducer summaries include `clip_count`, `paging`, and cursor presence so clips state
  transitions produce useful lines without logging full clip payloads or cursor values.
- The remux facade logs untyped non-cancellation terminal errors at the same outer
  boundary as `ClipRemuxError` so AVFoundation or file-I/O failures still produce one
  `clip_id`-keyed root-cause line.
- The live log exporter enumerates `OSLogStore` from an awaited detached task so the
  synchronous store fetch does not run on the app target's default main actor.

## Follow Up

- Investigate the intermittent full-suite failure in
  `app/DanCam/DanCamTests/Networking/Preview/PreviewClientTests.swift#realHyperChunkedFixtureDecodesMockFrameSequence`;
  it failed twice under `just app-test` on July 1, 2026, but passed when run in
  isolation.
- Fix the pre-existing Swift concurrency warnings in
  `app/DanCam/DanCam/Features/Home/HomeViewController.swift#stopLiveTickTimer` and
  `app/DanCam/DanCam/Features/Home/HomeViewController.swift#updateVisibleLiveElapsed`;
  timer/deinit paths call main-actor-isolated methods from synchronous nonisolated
  contexts.
