# Plan: disable AVKit paused-frame video analysis in the clip viewer

## Context

During clip fullscreen/paused playback, the Xcode console fills with Apple system
analyzer noise coming from AVKit's built-in video frame analysis (the VisionKit /
Live Text path), for example:

- `Visual isTranslatable: NO; reason: observation failure: noObservations`
- `verify_image_parameters: invalid image bits/pixel or bytes/row.`
- `VKCImageAnalyzerRequest ... Request was canceled`

`AVPlayerViewController.allowsVideoFrameAnalysis` defaults to `true`, so when media
is paused AVKit tries to find text, subjects, people, and codes in the frame. A
dashcam clip viewer needs none of that -- no Live Text, subject lift, visual lookup,
or QR/code detection. Setting the flag to `false` is the blunt, single switch that
turns the whole analyzer path off (cleaner than enumerating `videoFrameAnalysisTypes`).

Intended outcome: keep clip playback (including fullscreen enter/exit and pause/play)
working exactly as today, while the analyzer log noise is suppressed. It may not
silence every AVKit/media log during fullscreen transitions, but it removes the
VisionKit-analyzer source shown above.

The `AVPlayerViewController` is created once, in
`app/DanCam/DanCam/Features/ClipViewer/ClipViewerViewController.swift#play(_:source:)`,
which is the only playback construction site (covers both the `.cacheHit` and
`.freshRemux` paths). The deployment target is iOS 26.5 and the flag is iOS 16+, so
no `#available` guard is needed.

## Change (one file)

File: `app/DanCam/DanCam/Features/ClipViewer/ClipViewerViewController.swift`
Anchor: `#play(_:source:)` (search for `private func play(_ url: URL, source: PlaybackSource)`)

Insert the assignment immediately after the existing `playerViewController.delegate = self`
line, with a short ASCII comment explaining the why (per the docs decision below the
comment is the only durable record).

Before:

```swift
        let playerViewController = AVPlayerViewController()
        playerViewController.player = player
        playerViewController.delegate = self
        playerViewController.view.translatesAutoresizingMaskIntoConstraints = false
```

After:

```swift
        let playerViewController = AVPlayerViewController()
        playerViewController.player = player
        playerViewController.delegate = self
        // Dashcam clips don't need Live Text, subject lift, visual lookup, or code
        // detection; turning off AVKit's paused-frame analysis also quiets the system
        // VisionKit analyzer log noise (VKCImageAnalyzerRequest / verify_image_parameters
        // / "Visual isTranslatable"). Default is true; flag is iOS 16+, target is 26.5.
        playerViewController.allowsVideoFrameAnalysis = false
        playerViewController.view.translatesAutoresizingMaskIntoConstraints = false
```

Notes:
- Match the file's existing style: bare assignment (no `#available` guard), inline
  `//` explanatory comment, plain ASCII, straight quotes.
- One creation site means this single line covers every playback path.

## Tests

Skip -- no new test. Decision confirmed with the user: this is a trivial static
property assignment. The existing Swift Testing suite
(`app/DanCam/DanCamTests/Features/ClipViewer/ClipViewerViewControllerTests.swift`)
already exercises the cache-hit and fresh-remux playback paths end to end; it must
still compile and pass unchanged, which `just app-test` verifies. Do not add a
test-only seam for this flag.

## Docs

No ADR. Decision confirmed with the user: this is a local, reversible playback-config
detail, below the one-decision-per-file ADR bar (it changes no playback path, wire
contract, cache design, or clip format scope). The explanatory code comment at the
call site (above) is the record. ADR 13
(`app/docs/design/13-2026-07-01-durable-clip-cache.md#Decision`) remains the governing
clip-playback ADR and is not edited.

## Verification

Automated gate (required):

- `just app-test` -- runs the DanCam Swift Testing unit suite on the pinned simulator
  (`OS=26.5, iPhone 17`). This also compiles the app + tests, so it doubles as the
  build check. Confirm the existing ClipViewer tests still pass. (`just app-build` is
  available for a faster compile-only pass, but is not separately required.)

Manual verification (behavior + log noise):

1. Run the app in the simulator (or on device) and open a clip in the clip viewer.
2. Enter fullscreen, then exit; pause, then play. Confirm playback still works and
   the fullscreen enter/exit transitions behave as before.
3. Watch the raw Xcode debug console (unfiltered) during the paused/fullscreen frames
   and confirm the analyzer lines (`Visual isTranslatable`, `verify_image_parameters`,
   `VKCImageAnalyzerRequest ... canceled`) are gone or clearly reduced.
   - Note: these come from Apple system subsystems, not `com.danneu.dancam`, so
     `just app-logs` (which filters to our subsystem) will NOT show them -- use the
     Xcode console or Console.app without the subsystem filter.

## Commit

One small Conventional Commit, staging only the single source file:

```
fix(app): disable clip frame analysis
```

Body (optional, one line): note that AVKit paused-frame video analysis is turned off
to remove VisionKit analyzer log noise in the clip viewer.

Do not stage or touch the unrelated dirty files in the working tree
(`.claude/settings.local.json`, `.gitignore`, `personal-notes/`,
`prompts/fable-repo-review.md`).
