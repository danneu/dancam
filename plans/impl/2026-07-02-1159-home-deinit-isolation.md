# Plan: Fix main-actor-isolation warnings in `HomeViewController.deinit`

## Context

`just app-lint` surfaces two warnings, both in `HomeViewController.deinit`:

```
HomeViewController.swift:169:9: warning: call to main actor-isolated instance method 'stopLiveTickTimer()' in a synchronous nonisolated context
HomeViewController.swift:170:9: warning: call to main actor-isolated instance method 'cancelAllPrefetches()' in a synchronous nonisolated context
```

The module builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (Swift 6 mode),
so `HomeViewController` and its methods are MainActor-isolated. A `deinit`, however,
is **always nonisolated** -- deallocation can happen on any thread, so the compiler
cannot assume the main actor. Calling the two MainActor-isolated helpers
(`stopLiveTickTimer()`, `cancelAllPrefetches()`) from that nonisolated context is the
warning.

This is not merely compiler noise. `stopLiveTickTimer()` calls `Timer.invalidate()`,
which per Apple's docs **must be sent from the thread on which the timer was installed**
(the main thread here). If `deinit` ever runs off-main, invalidating the timer there is
a latent correctness bug, not just a diagnostic. So the fix needs to make the cleanup
genuinely run on the main actor -- not just silence the warning.

## Fix

Mark the deinitializer `isolated deinit` (Swift's SE-0371, "isolated synchronous
deinit"):

```swift
// app/DanCam/DanCam/Features/Home/HomeViewController.swift
isolated deinit {
    stopLiveTickTimer()
    cancelAllPrefetches()
}
```

`isolated deinit` isolates the deinit body to the class's actor (MainActor). If the
final release happens on the main actor the body runs synchronously; if it happens
off-main, the runtime hops the body onto the main actor before running it (memory is
freed after). Both cleanup calls then run where they must:

- `Timer.invalidate()` gets its required main-thread execution (the real fix).
- `PrefetchHandle.cancel()` is already nonisolated-safe (`ThumbnailLoader.swift#struct PrefetchHandle`
  wraps a `@Sendable () -> Void`), so running it on main is harmless.

**This is the established convention in this codebase**, not a new pattern:
`ClipViewerViewController` already uses `isolated deinit { tearDown() }`
(`app/DanCam/DanCam/Features/ClipViewer/ClipViewerViewController.swift#isolated deinit`).
The fix makes `HomeViewController` consistent with its sibling.

**Availability:** none of the usual back-deployment concern applies -- the app targets
`IPHONEOS_DEPLOYMENT_TARGET = 26.5`, well past the runtime that ships SE-0371 support.

### Scope

Exactly one line changes (`deinit` -> `isolated deinit`). No behavior change to the
cleanup itself; the method bodies are untouched. A repo-wide check found only two
`deinit`s in the app target -- this one and the already-correct `ClipViewerViewController`
-- so there is no wider sweep to do.

## Alternatives considered (rejected)

- **`MainActor.assumeIsolated { ... }` inside a plain `deinit`.** Wrong and dangerous:
  `assumeIsolated` *asserts* it is already on the main actor and traps at runtime if
  `deinit` runs off-main. Deinit isolation is not guaranteed, so this can crash. (The
  existing `MainActor.assumeIsolated` in the live-tick timer closure is fine because a
  main-run-loop timer is documented to fire on the main thread; `deinit` has no such
  guarantee.)
- **Hop manually via `DispatchQueue.main.async { ... }` from a nonisolated deinit.**
  Strictly worse than the native mechanism: reintroduces GCD, and capturing `self` in a
  deinit to defer work is a footgun. `isolated deinit` does the same hop, correctly, with
  no capture.
- **Drop the deinit cleanup and rely only on `viewWillDisappear`.** Rejected: the deinit
  is a legitimate backstop. The live-tick `Timer` is retained by the run loop (its closure
  only weakly captures `self`), so a VC torn down without a balanced `viewWillDisappear`
  would leave the timer firing every second forever. Keep the backstop; just make it
  isolation-correct.

## Verification

1. `just app-lint` -- the two `HomeViewController.swift` warnings are gone and the clean
   build reports 0 warnings.
2. Confirm no new warnings/errors were introduced by the same clean build.
