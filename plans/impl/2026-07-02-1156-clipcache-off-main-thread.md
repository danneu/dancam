# Plan: Move ClipCache off the main thread (fix the clip-viewer freeze)

## Context

Opening a clip -- and the moment right after a clip finishes downloading -- can freeze the
whole app for up to a couple of seconds. The freeze ends when the console prints
`Gesture: System gesture gate timed out.` That log line is a symptom, not the cause: it is
UIKit's system-gesture gate giving up after the main thread failed to service a touch within
its ~1-3s timeout. The main thread is blocked.

Root cause: `ClipCache` is the one dependency in the app that runs its work **synchronously on
the caller's thread**, and its caller is the `@MainActor` clip viewer.

- `Media/ClipCache.swift#ClipCache` exposes synchronous closures
  `lookup: @Sendable (Int, String) -> URL?` and `insert: @Sendable (Int, String, URL) throws -> URL`.
- `Features/ClipViewer/ClipViewerViewController.swift#viewDidLoad` calls `clipCache.lookup(...)`
  synchronously during the push transition. `lookup` runs `ensureCurrentVersion`, which on a
  cache-version bump **enumerates and deletes the entire cache directory** on the main thread.
- `Features/ClipViewer/ClipViewerViewController.swift#prepareAndPlay` calls `clipCache.insert(...)`
  synchronously right after every download. `insert` runs `sweepClipVersions` + `moveItem` +
  `evictIfNeeded`, and `evictIfNeeded` enumerates the whole cache dir, `attributesOfItem`s every
  file, sorts, and deletes down to the 500 MB budget. Near budget this is hundreds of ms to
  seconds of main-thread stall -- and it gets worse as the cache fills.

Every other heavy dependency (`ClipRemuxer`, `ClipPullClient`, `ThumbnailLoader`, `LogExporter`)
already runs off-main. `ClipCache` is the lone exception. This plan brings it in line.

Intended outcome: no main-thread filesystem work in the cache path; the clip viewer opens and
finishes downloads without freezing, verifiable by opening a clip with a full cache.

There is also a latent correctness hazard the current shape masks: `lookup` is *already* called
concurrently off-main from `ThumbnailLoader.Loader.generate` while the clip viewer calls
`lookup`/`insert` on main. A version-sentinel wipe or eviction can interleave with a concurrent
`moveItem`, and `evictIfNeeded`'s `removeItem` of an already-moved file throws and fails the whole
insert. Serializing the cache (below) closes this too.

## Approach

Mirror the existing `Media/ThumbnailLoader.swift` pattern: keep `ClipCache` a `nonisolated struct`
facade of `@Sendable` closures for DI/testing, but make the closures `async` and back `.live` with
an internal `actor`. The actor gives us both requirements at once: its executor is off the main
thread (fixes the freeze) and it is serial (closes the interleaving hazard). Do **not** use a bare
`Task.detached` per call -- that fixes off-main but leaves the operations unserialized, which is
the transient/dumb version.

### 1. `ClipCache` -> actor-backed async facade (`Media/ClipCache.swift`)

- Change the facade closures to:
  - `var lookup: @Sendable (_ clipID: Int, _ etag: String) async -> URL?`
  - `var insert: @Sendable (_ clipID: Int, _ etag: String, _ source: URL) async throws -> URL`
- Introduce `private actor Store` holding `let rootDirectory`, `let now`, `let maxBytes`, with
  instance methods `lookup(...) -> URL?` and `insert(...) throws -> URL` whose bodies are the
  current `lookup`/`insert` closure bodies verbatim.
- Keep the existing helpers (`cacheURL`, `ensureCurrentVersion`, `sweepClipVersions`,
  `evictIfNeeded`, `cacheEntries`, `stamp`) as `nonisolated static` functions taking their inputs
  as parameters (they already are) -- the actor methods call them. No logic change to the FS work.
- `.live(rootDirectory:now:maxBytes:)` builds one `Store` and forwards:
  `lookup = { id, etag in await store.lookup(id, etag) }`,
  `insert = { id, etag, src in try await store.insert(id, etag, src) }`.
- `.noop` stays the direct-closure init; its closures just become `async` (bodies unchanged:
  `lookup: { _, _ in nil }`, `insert: { _, _, source in source }`).
- Keep `now` a construction-time `@Sendable () -> Date` captured by the `Store` -- the eviction/stamp
  tests advance time by reconstructing the cache, so this preserves their timing model.

### 2. Thread `async` through `ThumbnailLoader` (`Media/ThumbnailLoader.swift`)

`ThumbnailLoader.live` passes `clipCache.lookup` into the loader, and `Loader.generate` (already
`@concurrent`, off-main) calls it. Propagate the `async`:

- `Loader.clipCacheLookup` property type -> `@Sendable (Int, String) async -> URL?`.
- `ThumbnailLoader.init` designated-init `clipCacheLookup:` parameter type -> same.
- In `Loader.generate`: `if let mp4URL = await clipCacheLookup(clip.id, clip.etag)`.
- `ThumbnailLoader.live` wiring (`clipCacheLookup: clipCache.lookup`) is unchanged -- it now passes
  the async closure.

### 3. Clip-viewer call sites (`Features/ClipViewer/ClipViewerViewController.swift`)

- `prepareAndPlay(_:)` is already `async throws`: change the insert to
  `let cachedURL = try await dependencies.clipCache.insert(clip.id, result.resolvedETag, remuxedResult.fileURL)`.
- `viewDidLoad` is synchronous and cannot `await`. Move the cache-first branch into a cancellable
  Task, reusing the existing `pullTask` machinery. Keep `startPull()`'s reset **synchronous** -- do
  not move `removeTemporaryFiles(); detachPlayer(); state = .pulling(...)` behind a task boundary,
  or a teardown that cancels `pullTask` before the task's first run would still let the cancelled
  task resurrect viewer state and start a pull (Swift cancellation is cooperative, and those
  synchronous mutations run before `runPullRemuxCacheAndPlay`'s first `checkCancellation`).
  Concretely:
  - `startPull()` stays **exactly as today**: it synchronously does
    `pullTask?.cancel(); pullTask = nil; removeTemporaryFiles(); detachPlayer(); state = .pulling(...)`
    and only then schedules `pullTask = Task { [weak self] in await self?.runPullRemuxCacheAndPlay() }`.
    It already is the shared "reset synchronously, then pull" helper; retry and both self-heal paths
    keep calling it and keep force-pulling (bypassing the cache), unchanged. (No `resetAndPull()`
    extraction -- that was the source of the stranding bug.)
  - Add `private func loadFromCacheThenPlayOrPull() async`:
    `if let url = await dependencies.clipCache.lookup(clip.id, clip.etag) { guard !Task.isCancelled else { return }; play(url, source: .cacheHit); return }; guard !Task.isCancelled else { return }; startPull()`.
    The `guard !Task.isCancelled` immediately before `startPull()` closes the teardown-during-lookup
    window: the guard and the synchronous `startPull()` run with no intervening suspension on the
    main actor, so a concurrent teardown cannot interleave between them (the only suspension point is
    the `await lookup`, which the guard covers). When the miss path calls `startPull()` from inside
    the very task `pullTask` points at, `startPull()`'s leading `pullTask?.cancel()` cancels this
    already-finishing task and immediately replaces it with a fresh pull task -- harmless, since
    nothing runs in the outer task after `startPull()` returns.
  - `viewDidLoad`: after `configureViews()/configureShareButton()`, set a neutral initial state
    (`state = .preparing`) so the screen is not blank during the sub-frame lookup, then
    `pullTask = Task { [weak self] in await self?.loadFromCacheThenPlayOrPull() }`.
  - Cancellation/teardown is unchanged: `tearDown()`, `didMove(toParent:)`, and the `isolated deinit`
    already cancel `pullTask`.

Behavioral note: the cache hit now resolves on a Task after `viewDidLoad` returns instead of inline.
This is inherent (you cannot await in a sync `viewDidLoad`) and is the correct trade -- a
sub-millisecond off-main stat replaces a possibly-multi-second main-thread stall. It only affects
test observation ordering (below), not user-visible behavior beyond removing the freeze.

## Tests to update

All churn is mechanical; the async conversion forces `await` and shifts a few synchronous
assertions to the existing poll helper.

- `DanCamTests/Media/ClipCacheTests.swift` -- add `await` to every `lookup`/`insert` call (~20).
  Tests are already non-`@MainActor` structs, so make the test funcs `async`. No behavior change.
- `DanCamTests/Media/ThumbnailCacheTests.swift#usesItsOwnRootAndLeavesTheClipCacheUntouched` --
  `await` the one `insert`/`lookup` pair.
- `DanCamTests/Media/ThumbnailLoaderTests.swift` -- the injected `clipCacheLookup:` fake closures
  (and the `makeLoader` helper default) become `async` to match the new parameter type.
- `DanCamTests/Features/ClipViewer/ClipViewerViewControllerTests.swift` -- the ~11 tests that build
  a fake `ClipCache(lookup:insert:)` (and the `movingCache` helper): make those closures `async`.
  Switch the cache-hit assertions that currently run synchronously right after
  `loadViewIfNeeded()` (e.g. `#cacheHitPlaysLookedUpURLWithoutPulling`, `#cacheHitEnablesShareButton`,
  `#disappearanceWithoutRemovalKeepsPlayer`, `#fullscreenRoundTripKeepsPlayer`,
  `#removalTearsDownPlayer`, and the share-artifact/self-heal cache-hit tests) to
  `try await waitUntil { controller.currentPlayerItemURL == cacheURL }`. The helper already exists at
  `ClipViewerViewControllerTests.swift#waitUntil`; the tests that go through the pull path already
  use it, so this is applying the same idiom to the cache-hit path.
- `DanCamTests/App/AppShellViewControllerTests.swift` uses `.noop` and only needs to compile against
  the new signature.

## Tests to add (lock the fix, not just the compile)

The mechanical `await` churn above proves nothing about *where* the cache work runs. An
implementation that made `ClipCache` async but kept the FileManager work on the caller's (main)
actor, or used un-serialized `Task.detached` per call, would still compile and pass every updated
test above while preserving the freeze or the interleaving race. Add two behavioral regression tests
to `DanCamTests/Media/ClipCacheTests.swift` that fail on those wrong shapes:

- **Off-main execution (locks the freeze fix).** Build a `.live` cache whose `now` closure records
  `Thread.isMainThread` at the moment it is invoked (`now` runs inside `insert`, and inside the
  file-exists branch of `lookup`, on the cache's own executor). From a `@MainActor` test,
  `await cache.insert(...)` and `#expect` the recorded value is `false`. This fails on the buggy
  "async but still on the caller's main actor" shape and passes for any off-main backing (actor or
  detached). It directly encodes the fix's contract: no cache FileManager work on the main thread.
- **Serialization under concurrency (locks the interleaving hazard).** Probe non-overlap *directly*
  through the `now` seam rather than relying on a filesystem race to surface. Back `now` with a
  shared, lock-guarded probe: on each invocation acquire the lock, increment an `active` count,
  record `peak = max(peak, active)`, release; hold the critical section briefly (a few ms) so any
  genuinely concurrent operation is caught inside its own `now` window; then acquire, decrement,
  release. `insert` calls `now` exactly once inside the cache's critical section, so drive N
  concurrent `insert`s of distinct clips (each from its own temp source file) via `withTaskGroup`
  and assert **`peak == 1`** as the primary check. A serial actor serializes those critical sections
  deterministically -> `peak == 1` always: its `insert`/`lookup` methods have no internal `await`,
  so each runs atomically and two `now` windows can never overlap -- this never false-fails on the
  serialized implementation. An un-serialized `Task.detached` implementation runs two `now` windows
  at once -> `peak >= 2` -> fail. Keep `maxBytes` small so `evictIfNeeded` runs on each insert, and
  keep the outcome checks (no operation throws; settled cache within budget and version-consistent)
  as secondary assertions. (The probe surfaces overlap on a multi-core executor -- the Apple Silicon
  dev/CI target; it detects real parallelism rather than manufacturing it.)

## Docs to update

- `app/docs/design/13-2026-07-01-durable-clip-cache.md` (Status: Accepted) -- add an in-place dated
  note (matching the ADR 07 / ADR 03 in-place-note convention). The ADR is silent on threading, so
  this is an accuracy addition, not a reversal -- per the root `AGENTS.md#Design decisions (ADRs)`
  convention, amend in place rather than supersede. The note records that `ClipCache.lookup`/`insert`
  are `async` and run their FileManager work (directory enumeration, stale-etag sweep, moves,
  mtime-LRU eviction, version-sentinel wipe) off the main thread on a serial actor, because the
  caller (`ClipViewerViewController`) is `@MainActor`; and that the serial actor also removes the
  interleaving hazard between concurrent thumbnail lookups and clip-viewer insert/version-wipe.
- No other docs need edits: ADR 07, ADR 12, `app/AGENTS.md`, and `docs/roadmap.md` describe the
  cache only behaviorally and make no threading claim (audited).

## Out of scope (call out, do not fix here)

- The other synchronous `FileManager` calls on the `@MainActor` viewer -- `makeShareArtifact`
  (APFS clone, effectively instant) and `removeTemporaryFiles`/`removeTemporaryFile` (delete a
  couple of temp files, some from `isolated deinit` where `await` is not possible). These are
  bounded and are not the freeze; folding them in would widen scope and complicate teardown. Note
  them for a later focused pass if profiling ever flags them.
- The secondary gesture-gate suspects raised during diagnosis (AVPlayerViewController nested in a
  `UIScrollView`; debugger-attached artifacts). Verification below will confirm whether the
  ClipCache fix alone eliminates the freeze; if a residual freeze remains on a specific gesture,
  open a separate investigation.

## Verification

1. `just app-test` from the repo root -- all suites green, including `ClipCacheTests` (the
   mechanical `await` churn plus the two added regression tests), `ThumbnailLoaderTests`, and
   `ClipViewerViewControllerTests`.
2. End-to-end in the simulator/device via the `run` skill: open several clips so the cache fills
   toward the 500 MB budget, then open another clip. Before the fix this stalls and logs
   `System gesture gate timed out`; after, the viewer opens smoothly and a download finishing does
   not freeze the UI. Confirm no `System gesture gate timed out` in the console during these flows.
3. Optional confirmation of off-main execution: pause in the debugger during a large-cache open, or
   run the Instruments "Hangs" template, and confirm Thread 1 (main) is not inside `ClipCache`
   FileManager calls (`evictIfNeeded`/`ensureCurrentVersion`).
