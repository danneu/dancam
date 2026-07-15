# ADR: structured logging and in-app log export

- **Status:** Accepted
- **Date:** 2026-07-01
- **Owner:** app
- **Related:** [app architecture](../../../docs/design/app/architecture.md) (action log);
  `../../../AGENTS.md` (repo conventions)

## Context

Dan often debugs the app by copying Xcode logs into an LLM. For that to work, logs
need to reconstruct state: the visible screen, the connection and heartbeat state,
and where each clip is in the pull -> remux -> playback pipeline.

The app already used Apple unified logging in a few media-path files, but important
state changes were silent. The reducer, connection event stream, clip pull retry
loop, remux boundary, playback state machine, and navigation stack did not leave a
coherent diagnostic trail.

The project also needs an in-car path when Xcode is not attached. iOS exposes recent
current-process unified logs through `OSLogStore`, so the app can export its own
diagnostic window from the Debug screen without adding a logging dependency.

## Decision

Stay on Apple's `os.Logger` and unified logging.

Add one app-owned `Log` namespace with subsystem `com.danneu.dancam` and category
loggers for reducer, pull, remux, transport parsing, playback, and navigation.
Categories are greppable diagnostic tags, not ownership boundaries.

Use a level ladder that matches export behavior:

- `.error` for genuine failures.
- `.notice` for state transitions and pipeline boundaries that must survive into log
  exports.
- `.info` for useful live detail that is not required in an export.
- `.debug` for hot paths, no-op transitions, and optional detail.

Diagnostic values default to `privacy: .public`. The planned values are clip ids,
byte counts, phases, states, and timings; redacting them would make exported logs far
less useful. Future emit sites that introduce sensitive values must opt those values
back into private privacy explicitly.

Use `clip_id=<Int>` as the cross-pipeline correlation field. This keeps pull, remux,
playback, and cache-adjacent lines joinable without introducing a `ClipID` type in
this logging change.

Add an optional transition-log closure to `Store.send(_:)`. The reusable store stays
generic and silent by default; the live app store injects `AppFeature.logTransition`,
where action and state rendering can remain app-specific.

Known limitation: sub-reducers invoked inline from `AppFeature.reduce`, such as the
clips and recording reducers inside the `.event` case, do not pass through
`Store.send(_:)` as child actions. Their resulting root state delta is still visible
in the transition line, but those child actions are not logged as separate reducer
events.

Add a `LogExporter` dependency backed by `OSLogStore(scope: .currentProcessIdentifier)`
and expose it from the Debug screen as "Export logs". The exported text includes an
app/version header, the current `AppFeature.State.logSnapshot`, and recent
current-process log lines formatted in timestamp/category/level/message order.

`OSLogStore(scope: .currentProcessIdentifier)` has important caveats:

- It reads only the current process. It is not a crash log, and it cannot recover logs
  from a previous app launch.
- `.info` and `.debug` are live/in-memory diagnostics and can be absent from exports.
  Any line that an export must contain belongs at `.notice` or higher.

## Consequences

Easy:

- Xcode, Console.app, `log stream`, and in-app export all use the same native log
  system.
- State-reconstruction lines are emitted at the reducer and pipeline boundaries,
  where the app already knows the action, phase, clip id, and terminal outcome.
- The app keeps zero third-party dependencies for logging.
- Tests can exercise the generic store seam and the pure export formatter without
  depending on live OS logging I/O.

Hard or risky:

- Unified logging is not a durable crash-forensics store. A crash or app restart can
  lose the pre-crash current-process window.
- Level choice is load-bearing. An export-critical line logged at `.info` or `.debug`
  may be missing from a shared export.
- The reducer hook is a root-store transition hook, not a complete per-sub-reducer
  action audit.
- Public diagnostic values are intentional, so future log lines must be reviewed
  before adding user-entered text, file paths, network secrets, or personally
  sensitive values.

## Alternatives considered

- **Apple `os.Logger` / OSLog.** Chosen: already in use, dependency-free, native to
  Xcode and Console.app, and exportable through `OSLogStore`.
- **apple/swift-log.** Rejected: it adds indirection for server-side portability this
  single iOS target does not need.
- **Pulse.** Rejected: its on-device inspector and networking capture are more
  machinery than the current debug workflow needs.
- **CocoaLumberjack.** Rejected: a mature file logging stack, but not worth the
  dependency and second logging model while unified logging covers the current need.
