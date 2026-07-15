# ADR: share clips as raw MP4 file URLs

- **Status:** Superseded by `30-2026-07-15-responsive-video-share-preparation.md`
- **Date:** 2026-07-10
- **Owner:** app
- **Related:** `15-2026-07-01-clip-export-share.md`;
  [app clips](../../../docs/design/app/clips.md)

## Context

ADR 15 established one system share sheet over the cached MP4 and, after physical-device
verification, settled on the classic
`UIActivityViewController(activityItems:applicationActivities:)` initializer over a
friendly-named APFS clone. The verified raw file-URL path offered Save Video, AirDrop,
and Save to Files, retained the video-frame QuickLook thumbnail, and completed real
transfers successfully.

A later hardening change wrapped that same URL in `ClipShareItemSource`, a
`UIActivityItemSource` that explicitly declared the movie UTType. Device verification
had not demanded the wrapper: the `.mp4` extension already supplied the type information
needed by the working destinations.

The wrapper caused a reproducible physical-device crash during share discovery. Two
device crash reports captured on 2026-07-10 show `EXC_BREAKPOINT (SIGTRAP)` with
termination indicator `Trace/BPT trap: 5` on `com.apple.root.default-qos`. The faulting
stack is `_dispatch_assert_queue_fail` -> `_swift_task_checkIsolatedSwift` ->
`_checkExpectedExecutor` ->
`@objc ClipShareItemSource.activityViewController(_:itemForActivityType:)`. The callback
entered the `@MainActor`-isolated wrapper from a non-main queue and failed Swift's
executor check.

## Decision

Supersede ADR 15 and remove `ClipShareItemSource`. Pass the friendly-named MP4 clone's
file URL directly to the classic activity-sheet initializer. Movie-type inference comes
from the `.mp4` extension, matching the device-verified implementation.

Carry forward the rest of ADR 15's corrected export design unchanged:

- Use one system share sheet over the cached MP4 file URL.
- Materialize a friendly-named APFS copy-on-write clone at
  `tmp/clip-share/<UUID>/<friendlyName>.mp4`, with the name produced by
  `Formatters.clipExportFilename(_:timeZone:)`.
- Use the classic `UIActivityViewController(activityItems:applicationActivities:)`
  initializer and anchor its popover through
  `popoverPresentationController?.sourceItem`.
- Remove each temporary directory from `completionWithItemsHandler`, with a
  `tearDown()` sweep as the safety net.
- If cloning fails, share the real cache URL when it still exists; otherwise self-heal
  through a fresh pull.
- Omit `LPLinkMetadata` so the system retains its QuickLook preview header.
- Keep `NSPhotoLibraryAddUsageDescription` for Save Video.
- Enable Share only while a cached MP4 is playing.

## Consequences

The share path no longer crosses the unnecessary Objective-C protocol/main-actor
boundary that crashed during activity discovery. It returns to the smaller path already
verified with Save Video, AirDrop, Save to Files, a friendly filename, and the QuickLook
video thumbnail on a physical device.

The app relies on the `.mp4` extension for movie-type inference. This is an observed,
tested system behavior for the destinations the product supports, not a speculative
fallback.

## Alternatives considered

- **Make `ClipShareItemSource` concurrency-safe.** Rejected: the wrapper provides no
  demonstrated product benefit, so preserving it would retain complexity solely to
  support speculative hardening.
- **Add another provider or metadata layer.** Rejected: both
  `UIActivityItemsConfiguration` with a lazy provider and the item-source wrapper caused
  device-only failures. The raw file URL is the simplest device-verified contract.
- **Build separate export actions for Photos, AirDrop, and Files.** Rejected: the system
  activity sheet already provides these destinations through one native surface.
