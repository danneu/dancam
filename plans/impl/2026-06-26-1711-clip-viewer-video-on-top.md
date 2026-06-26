# Plan: Move video to top of clip viewer, status/progress below

## Context

The clip viewer page (`ClipViewerViewController`) currently stacks the UI as:
status label ("Ready") -> progress bar -> result label ("38.5 MB - 6.7 s - 46
Mbps") -> video player. Because the player sits last and the stack is pinned to
the bottom safe area, the player ends up at the bottom of the screen with a large
empty gap above it (visible in the screenshot: "Ready" near the top, then a void,
then the progress/result/player clustered at the bottom).

The desired layout is the conventional one: **video at the top of the page, with
the status/progress/result info directly underneath it.**

## Change

Single file: `app/DanCam/DanCam/Features/ClipViewer/ClipViewerViewController.swift`,
in `configureViews()`.

1. **Reorder the stack's arranged subviews** so the player is first:
   `[playerContainerView, statusLabel, progressView, resultLabel]`
   (was `[statusLabel, progressView, resultLabel, playerContainerView]`).

2. **Wrap the stack in a scroll view** instead of pinning it directly to the root
   view's safe area, reusing the established `HealthViewController` pattern
   (`HealthViewController.configureViews`): a `UIScrollView` pinned to the safe
   area, with the stack pinned to the scroll view's `contentLayoutGuide` on all
   four edges and `stack.widthAnchor == scrollView.frameLayoutGuide.widthAnchor`.

   Add a `private let scrollView = UIScrollView()` property and rewrite the layout
   block as:
   ```swift
   scrollView.translatesAutoresizingMaskIntoConstraints = false
   view.addSubview(scrollView)
   scrollView.addSubview(stack)

   NSLayoutConstraint.activate([
       scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
       scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
       scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
       scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

       stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
       stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
       stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
       stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
       stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),

       playerContainerView.heightAnchor.constraint(equalTo: playerContainerView.widthAnchor, multiplier: 0.75),
   ])
   ```

   Why a scroll view rather than the original `bottom <= safeArea.bottom` root
   stack: the app declares iPhone landscape support
   (`project.pbxproj#INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone`), and
   the player keeps a width-derived 4:3 height while the labels use dynamic type.
   In landscape or at large accessibility text sizes the reordered content can
   exceed the safe-area height; a plain top-pinned stack would clip the
   status/progress area or break a required constraint. The scroll view gives the
   content an overflow path while still hugging the top (content shorter than the
   frame simply does not scroll), preserving the intended "video on top, status
   directly below" layout in the common portrait case.

No other changes. The player's 4:3 aspect-ratio height constraint and all
pull/playback logic stay as-is; the player view is still added into
`playerContainerView` exactly as before.

## Verification

- Build and run the app in the iOS Simulator (`just` task / Xcode), navigate into
  a clip from the clips list, and confirm the AVPlayer renders at the top of the
  page with "Ready" / progress bar / "<size> - <secs> - <Mbps>" stacked directly
  below it, and no large gap between the video and the status text.
- Confirm during an in-progress pull the progress bar still animates and the
  status label updates beneath the (initially black) player area.
- **Rotate to landscape** and confirm the content remains valid (no clipped
  status area, no Auto Layout constraint-break warnings in the console; it may
  scroll, which is acceptable).
- **Set a large dynamic type / accessibility text size** (Simulator: Settings or
  the Environment Overrides) and confirm the labels grow and the page scrolls
  rather than clipping or breaking layout.
