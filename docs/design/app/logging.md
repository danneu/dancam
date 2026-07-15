# App diagnostics and log export

DanCam uses Apple unified logging as its single diagnostic stream. Logs are designed
to reconstruct the visible screen, connection and heartbeat state, and each media
pipeline boundary both in Xcode and from an in-car export when Xcode is not attached.
Xcode, Console.app, `log stream`, and the Debug export all consume that same native
stream.

[App architecture](architecture.md) owns the generic store and root transition model.
[App browsing](browsing.md) owns the Debug screen that exposes export. This page owns
the `Log` namespace, categories, level and privacy policy, correlation fields, and the
current-process export contract.

## Namespace and categories

All app loggers use subsystem `com.danneu.dancam`. The app-owned `Log` namespace
currently exposes these greppable category tags:

- `reducer` for root actions and state transitions;
- `pull` and `remux` for clip acquisition and conversion;
- `ts-demux` and `h264-au` for media-parser detail;
- `playback` for viewer state;
- `nav` for tab and screen changes;
- `incident` for durable incident evidence and reconciliation; and
- `share` for video-share preparation and presentation.

Categories are diagnostic tags, not ownership boundaries. New pipelines add a
category only when it gives exported logs a useful stable filter.

## Levels, privacy, and correlation

Use the unified-log levels according to export value:

- `.error` for genuine failures;
- `.notice` for state transitions and pipeline boundaries that must survive into an
  export;
- `.info` for useful live detail that is not required in an export; and
- `.debug` for hot paths, no-op transitions, and optional detail.

`.notice` and higher are export-critical. `.info` and `.debug` can be absent from an
in-app export even when they were visible live.

Diagnostic values default to `privacy: .public` because clip identifiers, byte counts,
phases, states, and timings are needed to reconstruct behavior. Any new user-entered
text, path, network secret, or personally sensitive value must opt back into private
privacy explicitly.

Clip pull, remux, playback, and cache-adjacent lines use `clip_id=<Int>` as their shared
correlation field. Incident logs add `incident_id=<UUID>` when the incident identity is
needed.

## Reducer transition trail

`Store.send` accepts an optional transition closure. The reusable store is silent by
default; the live `AppStore` injects `AppFeature.logTransition`. A root action that
changes the summary emits a notice with the before and after phases. Other state
changes emit a debug token diff, and a no-op emits debug detail.

Reducers called inline from `AppFeature.reduce` do not pass through `Store.send` as
separate child actions. Their root-state delta is visible in the parent transition,
but the transition trail is not a complete per-sub-reducer action audit.

## In-app export

The Debug action exports the most recent 10 minutes from
`OSLogStore(scope: .currentProcessIdentifier)`, filtered to the DanCam subsystem. The
text begins with the app version and current `AppFeature.State.logSnapshot`, followed
by log lines in timestamp, category, level, and composed-message order. The system
activity sheet shares the resulting text. Export failure appears as an inline critical
Debug row and clears after a later success.

The exporter reads only the current process. It is not a crash log and cannot recover
the previous launch's window. A crash or restart can therefore lose the most useful
pre-crash lines. This limitation is why level choice is load-bearing, but it does not
turn unified logging into a durable forensic store.

## Testing obligations

Store tests cover the optional transition seam, and root transition tests cover
summary, token-diff, and no-op rendering. Exporter tests cover stable line ordering and
diagnostic fields without depending on live OS logging I/O. Debug controller tests
cover the version/state header, requested window, inline failure, and recovery after
success.

## Decision log

### 2026-07-01: Use unified logging and current-process export

(absorbed from app ADR 14, 2026-07-01)

Debugging often meant copying Xcode output into an LLM, but the existing sparse media
logs could not reconstruct screen, link, heartbeat, pull, remux, playback, and
navigation state. The app also needed an in-car path when Xcode was absent.

Apple's `os.Logger` was already in use, native to Xcode and Console.app, free of a
third-party dependency, and readable for the current process through `OSLogStore`.
The app standardized one namespace, greppable categories, public diagnostic fields,
`clip_id` correlation, and a level ladder that reserves notice for export-critical
boundaries. A generic optional store hook kept the reusable runtime silent while the
app supplied domain-specific action and state rendering.

`apple/swift-log` was rejected because server portability added indirection without
value for one iOS target. Pulse offered more on-device inspection and network capture
than the workflow needed. CocoaLumberjack would have introduced a second file-logging
model while unified logging already covered live tools and current-process export.

The accepted tradeoff is that exports are not durable crash forensics, public values
require review as logs evolve, and inline child reductions appear only as root deltas.
