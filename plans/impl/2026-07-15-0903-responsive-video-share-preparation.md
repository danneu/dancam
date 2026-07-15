# Responsive Video Share Preparation

## Summary

Move share-file staging off `MainActor`, show an immediate inline spinner in place of
the Share icon, and keep playback, scrolling, and back navigation responsive. Apply
the same behavior to cached clips and incident MP4/TS segments while preserving the
device-verified raw-file-URL share sheet.

## Interfaces and Behavior

- Make the concurrency boundary explicit in this MainActor-by-default target:
  - `nonisolated struct SharePreparationRequest: Sendable` carries the source URL and
    suggested filename.
  - `nonisolated struct PreparedShareArtifact: Sendable` carries the share URL and
    optional owned directory.
  - `nonisolated enum SharePreparationError: Error, Equatable, Sendable` includes the
    typed `sourceUnavailable` outcome.
  - `nonisolated struct ShareArtifactPreparer: Sendable` exposes an async, `@Sendable`
    preparation closure through `AppDependencies`.
- Implement the live preparer with an `@concurrent` helper that validates the source,
  creates `tmp/video-share/<UUID>/`, and uses Darwin `clonefile` for a guaranteed
  copy-on-write clone with an independent inode.
- Define the live implementation through an internal factory accepting a staging root
  and async `@Sendable` clone operation. Production defaults use `tmp/video-share` and
  Darwin `clonefile`; tests inject a unique root and gated clone operation without
  changing shared process filesystem state.
- If cloning or staging fails but the source remains a regular file, share the
  original URL. If the source disappeared, return a typed unavailable result. Never
  fall back to an expensive byte-for-byte copy.
- Add a reusable `@MainActor` video-share coordinator that owns the preparation task,
  task-generation token, spinner state, share-sheet presentation, cancellation, and
  temporary-artifact cleanup.
- Keep the classic `UIActivityViewController(activityItems: [artifact.url], ...)`
  path, raw file URL, friendly filename, QuickLook preview, and popover `sourceItem`.
  Do not reintroduce `NSItemProvider` or `UIActivityItemSource`.

## Implementation Changes

- On Share:
  - Capture the source URL and formatted filename before suspension.
  - Immediately replace the Share icon with an accessible activity indicator labeled
    "Preparing video".
  - Disable Share, Delete, and incident row selection; leave playback, scrolling, and
    back navigation active.
  - Start one stored preparation task; ignore duplicate starts.
- After preparation:
  - Guard against cancellation and stale task tokens before presenting anything.
  - Keep the spinner visible through share-controller construction and presentation,
    then restore the Share icon when the sheet is ready.
  - Clean owned artifacts after share completion or cancellation, and clean late
    results that arrive after navigation or state changes.
- Navigating back, deleting, starting a clip re-pull, losing the selected incident
  row, or tearing down the controller cancels preparation. The preparer checks
  cancellation before and after cloning and removes any partial directory.
- If a cached clip disappears, retain the existing automatic re-pull behavior. If an
  incident artifact disappears, remove the stale selection and show:
  - Title: `Unable to Share Video`
  - Message: `The video file is no longer available.`
- Add `Log.share` boundaries for preparation start/outcome/duration, raw-URL fallback,
  cancellation, and share-sheet initialization duration.
- Add ADR 30 for responsive video-share preparation, mark ADR 25 superseded while
  carrying forward its raw-URL decisions, and update the app ADR/logging index.

## Test Plan

- Test the live preparer with temporary files:
  - Produces the requested friendly filename with identical bytes.
  - Clone and source can be modified or deleted independently.
  - Invalid staging falls back to the original regular-file URL.
  - Missing or directory sources report unavailable.
  - A gated clone is cancelled after directory creation and leaves no partial or owned
    directory.
- Use gated preparer dependencies in both controller suites to verify:
  - A tap returns immediately and shows the spinner while preparation remains
    suspended.
  - Duplicate preparation is prevented.
  - Delete and incident selection are disabled while playback, scrolling, and
    navigation remain available.
  - Success presents the prepared URL and restores controls.
  - Back navigation cancels and late completion cannot present a sheet.
  - Missing cached clips re-pull; missing incident files alert and clear selection.
  - A cache-hit playback failure during gated preparation starts the self-healing
    re-pull; releasing a late artifact produces no presentation and cleans its owned
    directory.
  - Removing the selected incident segment through store state during gated
    preparation cancels the request; releasing a late artifact produces no
    presentation and cleans its owned directory.
  - Temporary artifacts are removed after completion, cancellation, and teardown.
- Run `just app-test` and `just app-build`.
- On a physical iPhone, test a large cached clip plus incident MP4 and TS artifacts
  with Save Video, AirDrop, Save to Files, sheet cancellation, rapid repeat taps, back
  navigation during preparation, and VoiceOver. Confirm the spinner animates and the
  screen remains responsive before the sheet appears.

## Assumptions

- Both existing video-share surfaces are in scope.
- The progress treatment is an immediate inline spinner with no visible modal or
  percentage.
- Back navigation is the cancellation mechanism; the spinner itself is not tappable.
- No wire contract, persistence format, or share destination behavior changes.

## Follow Up

- Run the physical-iPhone share matrix in the Test Plan for large cached clips and
  incident MP4/TS artifacts, including share destinations, cancellation, rapid taps,
  back navigation, and VoiceOver responsiveness.
