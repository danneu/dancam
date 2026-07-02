# Plan: fix clip viewer player teardown on fullscreen

## Context

Fullscreening a clip is broken. On the iPhone 17 simulator the screen goes black
(the fullscreen backdrop) and then "crashes" straight back out of the viewer. On a
real iPhone 13 mini the video does go fullscreen, but its controls are dead (tapping
shows nothing), and on dismiss the inline player is gone (black, no controls). The
app does not actually crash -- the process stays alive the whole time (heartbeat
event lines keep ticking, no signal/stack trace).

### Root cause

`ClipViewerViewController` tears its player down on *every* disappearance:

- `viewWillDisappear(_:)` calls `tearDown()` -> `detachPlayer()`, which does
  `player = nil` and removes the child `AVPlayerViewController`
  (`ClipViewerViewController.swift#func detachPlayer`, called from the
  `viewWillDisappear` override).

The trap: when an **embedded** `AVPlayerViewController` enters fullscreen, AVKit runs
a full-screen presentation over the container, which fires `viewWillDisappear` on the
container (`ClipViewerViewController`). So the moment the user taps the fullscreen
button, `tearDown()` destroys the very player AVKit is mid-transition presenting.

Symptom mapping (one bug, both platforms):
- Simulator: the fullscreen presentation has its player yanked out from under it and
  collapses immediately -> "crashed back."
- Device: the fullscreen view stays up showing the last frame, but its controls are
  dead (the `AVPlayerViewController` was detached, `player == nil`); on dismiss the
  inline container is empty/black (child removed) -> "player is gone."
- The `screen=HomeViewController` log after fullscreen entry, the off-window
  `UITableView` layout warning, and the cancelled `VKCImageAnalyzerRequest` are all
  downstream churn from the botched transition, not the cause. The `(Fig)`/`VRP`/
  `FigApplicationStateMonitor` err lines are benign VideoToolbox/AVKit log noise
  (`err=-12900` is `kVTPropertyNotSupportedErr`), present during normal playback.

### Proof (external)

- WWDC 2019 session 503, "Delivering Intuitive Media Playback with AVKit": entering
  fullscreen from an embedded `AVPlayerViewController` is a presentation during which
  the parent view controller can be deallocated. Apple's explicit guidance is "Keep
  strong reference to embedded AVPlayerViewController when full screen" and to use the
  `AVPlayerViewControllerDelegate` fullscreen begin/end callbacks (with the transition
  coordinator's `isCancelled`) as the source of truth -- not appearance methods.
  https://developer.apple.com/videos/play/wwdc2019/503/
- `AVPlayerViewControllerDelegate` provides
  `playerViewController(_:willBeginFullScreenPresentationWithAnimationCoordinator:)`
  and `...willEndFullScreenPresentationWithAnimationCoordinator:` precisely because
  fullscreen is a presentation transition distinct from a real disappearance
  (iOS 12+). Apple docs + Apple Developer Forums thread 679992.
- Apple container-VC contract: `removeFromParent()` automatically calls
  `didMove(toParent: nil)` on the child, and `UINavigationController` drives this on
  pop -- so `didMove(toParent: nil)` reliably marks a real removal and does NOT fire
  during a fullscreen presentation. (Swift by Sundell "Child View Controllers";
  Apple `UIViewController` container docs.)

### Design intent it aligns with

ADR 13 (`13-2026-07-01-durable-clip-cache.md#Decision`) already says teardown is
scoped to real removal: "Navigating away cancels the pull/remux task and deletes temp
artifacts; committed cache files survive." No ADR ever contemplated fullscreen. This
change makes the code match that intent; per the root `AGENTS.md` "take the ideal
solution / write down the trap" stance, we record the fullscreen gotcha in the same
change.

## Approach

Re-scope teardown to fire on **actual removal**, and adopt the AVKit fullscreen
delegate for explicit fullscreen state + diagnostics.

### 1. Move teardown off `viewWillDisappear` -- `ClipViewerViewController.swift`

- Delete the `viewWillDisappear(_:)` override (its only job was `tearDown()`).
- Add:
  ```swift
  override func didMove(toParent parent: UIViewController?) {
      super.didMove(toParent: parent)
      if parent == nil { tearDown() }   // popped/removed for good; NOT fired on fullscreen
  }
  ```
- Keep the existing `isolated deinit { tearDown() }` as the backstop. `tearDown()` is
  already idempotent (nil-safe pauses, set-and-clear temp/artifact collections), so
  firing from both `didMove(toParent: nil)` and `deinit` is safe. This also fixes a
  latent bug: a *cancelled* interactive back-swipe no longer kills the player, because
  `didMove(toParent: nil)` only fires when the pop actually completes.

### 2. Adopt `AVPlayerViewControllerDelegate` -- `ClipViewerViewController.swift`

- In `play(_:source:)` (`ClipViewerViewController.swift#func play`), set
  `playerViewController.delegate = self` when wiring up the embedded controller
  (delegate is weak; ClipViewer owns the controller, no cycle).
- Conform to `AVPlayerViewControllerDelegate` and implement:
  ```swift
  func playerViewController(_ pvc: AVPlayerViewController,
      willBeginFullScreenPresentationWithAnimationCoordinator c: UIViewControllerTransitionCoordinator) {
      setFullScreen(true)
      c.animate(alongsideTransition: nil) { [weak self] ctx in
          if ctx.isCancelled { self?.setFullScreen(false) }
      }
  }
  func playerViewController(_ pvc: AVPlayerViewController,
      willEndFullScreenPresentationWithAnimationCoordinator c: UIViewControllerTransitionCoordinator) {
      c.animate(alongsideTransition: nil) { [weak self] ctx in
          if !ctx.isCancelled { self?.setFullScreen(false) }
      }
  }
  ```
- `setFullScreen(_:)` updates an `isPresentingFullScreen` flag and emits one
  `Log.playback.notice("clip_id=... phase=fullscreen state=enter|exit")` line
  (matches the app's greppable `clip_id=`/`phase=` logging convention;
  `app/AGENTS.md#Logging`). This is the diagnostics that were missing when we first
  triaged this bug -- there was no fullscreen-transition log line.
- Teardown correctness does not depend on this flag (didMove owns that); the delegate
  is the explicit, Apple-recommended fullscreen seam (observability now, PiP-ready
  later) and defense-in-depth.

### 3. Tests -- `ClipViewerViewControllerTests.swift`

The two teardown tests and two cleanup call-sites currently poke
`controller.viewWillDisappear(false)` on a parentless controller. Repoint them at the
new trigger and add behavioral regression coverage. All deterministic, window-free
(consistent with the existing `loadViewIfNeeded()` house style and `...ForTesting()`
seams).

- Replace the four `controller.viewWillDisappear(false)` calls with
  `controller.didMove(toParent: nil)` (a faithful, direct simulation of a nav pop's
  removal, mirroring how the suite already calls lifecycle methods directly):
  `viewWillDisappearCleansUpShareArtifacts` (rename ->
  `removalCleansUpShareArtifacts`), `navAwayDuringPullCancelsAndCleansTempFile`,
  and the end-of-test cleanup in `shareButtonIsDisabledWhilePulling` and
  `purgedCacheShareTapSelfHealsByPulling`. (These last two rely on teardown to cancel
  the gated pull so the gated remuxer's `Issue.record` never runs -- so the repoint is
  required, not cosmetic.)
- Add `disappearanceWithoutRemovalKeepsPlayer`: cache-hit play, create a share
  artifact, then `controller.viewWillDisappear(false)`; assert
  `hasEmbeddedPlayer == true`, `currentPlayerItemURL == cacheURL`, and the artifact
  directory still exists. Directly encodes "a disappearance that is not a removal
  (fullscreen) must not tear down" -- the regression test for this bug.
- Add `fullscreenRoundTripKeepsPlayer`: cache-hit play, then exercise the fullscreen
  enter/exit path via small `enterFullScreenForTesting()`/`exitFullScreenForTesting()`
  seams (calling the same internal `setFullScreen(_:)` the delegate uses); assert the
  player stays embedded through enter -> exit and `isPresentingFullScreen` toggles.
- Add `removalTearsDownPlayer`: cache-hit play, then `controller.didMove(toParent: nil)`;
  assert `hasEmbeddedPlayer == false` and `currentPlayerItemURL == nil` (the removal
  contract, now asserted on the player itself, not just temp files).
- `hasEmbeddedPlayer` (already on the VC, currently unused by tests) is the observable
  for player-survival assertions.

### 4. ADR amendment -- `app/docs/design/13-2026-07-01-durable-clip-cache.md`

Add a short clarifying note to the Decision/Consequences: teardown (cancel pull/remux,
delete temp artifacts, detach player) is scoped to **actual removal** -- pop /
dealloc via `didMove(toParent: nil)` + `deinit` -- and deliberately NOT to transient
disappearances. AVKit fullscreen fires the container's `viewWillDisappear`, so
tearing down there destroyed the player mid-fullscreen; the viewer adopts
`AVPlayerViewControllerDelegate` for explicit fullscreen state. Append-only note in
the same change, per the repo stance.

## Verification

- `just app-test` -- the updated + new `ClipViewerViewControllerTests` pass (Swift
  Testing unit suite). Confirms removal still cleans up temps/artifacts/pull and that
  a non-removal disappearance and a fullscreen round-trip preserve the player.
- Manual, both targets (iPhone 17 simulator + iPhone 13 mini device) via Xcode:
  1. Open a clip, let it play inline.
  2. Tap the player's fullscreen button -> video goes fullscreen **with working
     controls** (tap toggles controls, scrubber works); Xcode log shows
     `clip_id=... phase=fullscreen state=enter`.
  3. Tap Done -> returns to the inline player, still showing video with controls
     (not black); log shows `... phase=fullscreen state=exit`. No
     `viewer playing -> ...` regression, no re-pull.
  4. Tap Back -> returns to Home (`screen=HomeViewController`); teardown runs once.
  5. Re-open a clip, tap Back while the pull is still running -> pull cancels and the
     temp `.ts` is cleaned (existing nav-away behavior intact).
- Optional: run the `verify` skill to drive the fullscreen flow end-to-end.

## Alternatives considered (rejected)

- **Guard `viewWillDisappear` with `isMovingFromParent || isBeingDismissed`.** Fixes
  the bug and is ordering-independent, but both flags read `false` on the parentless
  controllers the unit suite uses, so the removal contract becomes untestable without
  standing up a `UIWindow` + nav stack (heavier, flakier, and the kind of
  structure-sensitive UIKit-plumbing test the repo avoids). `didMove(toParent:)` is
  directly and deterministically drivable.
- **Keep `viewWillDisappear` teardown but skip it while an `isInFullScreen` flag set
  by the delegate is true.** Depends on `willBeginFullScreenPresentation` firing
  before `viewWillDisappear`; that ordering is not guaranteed across iOS versions.
  `didMove`-based teardown is a state query, not a race.
