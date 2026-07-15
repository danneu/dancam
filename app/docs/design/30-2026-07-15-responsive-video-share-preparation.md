# ADR: prepare video shares without blocking the main actor

- **Status:** Accepted
- **Date:** 2026-07-15
- **Owner:** app
- **Related:** `25-2026-07-10-clip-share-raw-file-url.md`;
  [phone-owned incidents](../../../docs/design/app/incidents.md)

## Context

Cached clips and phone-owned incident segments are shared from friendly-named temporary
files. Creating those files synchronously in a view controller blocks the main actor.
Large media can therefore delay the spinner, playback, scrolling, and back navigation
before the share sheet appears. `FileManager.copyItem` also does not state the required
performance contract: staging must never fall through to a full byte-for-byte copy.

ADR 25 established the physical-device-verified activity-sheet contract. Passing a raw
file URL to the classic `UIActivityViewController` initializer provides Save Video,
AirDrop, Save to Files, and the QuickLook video preview. Provider and item-source
wrappers caused device-only failures and remain inappropriate.

## Decision

Use one reusable video-share coordinator for cached clips and incident MP4/TS segments.
It immediately replaces the Share icon with an accessible inline spinner, disables only
destructive or conflicting actions, and owns a cancellable preparation task, stale-result
token, activity-sheet presentation, and temporary-artifact cleanup.

Perform filesystem staging through a nonisolated dependency. Its live implementation:

- validates that the source is a regular file;
- creates `tmp/video-share/<UUID>/`;
- uses Darwin `clonefile` for a copy-on-write clone with an independent inode;
- checks cancellation before and after cloning and removes partial directories;
- falls back to the original raw file URL if staging fails while the source remains;
- reports a typed unavailable result if the source disappears; and
- never performs a byte-for-byte fallback copy.

Keep the raw file-URL decisions from ADR 25: use the classic activity-controller
initializer, preserve the friendly filename and QuickLook preview, and anchor popovers
through `sourceItem`. Do not introduce `NSItemProvider` or `UIActivityItemSource`.

Cached-source disappearance starts the existing self-healing pull. Incident-source
disappearance clears the stale selection and presents an explicit unavailable alert.
Navigation, deletion, re-pull, selection loss, and controller teardown cancel preparation;
late artifacts are removed rather than presented.

## Consequences

Share taps provide immediate progress feedback while playback, scrolling, and navigation
remain responsive. Both video surfaces now share one lifecycle implementation and one
testable concurrency boundary. The staging path requires an Apple filesystem that supports
`clonefile`; failure remains safe because the original regular-file URL is shared directly.

Share preparation and activity-controller initialization gain a dedicated unified-log
category with boundary, outcome, fallback, cancellation, and duration events.

## Alternatives considered

- **Keep synchronous controller-local copies.** Rejected because media-sized filesystem
  work can block all main-actor interaction and duplicates lifecycle logic.
- **Use `FileManager.copyItem` off actor.** Rejected because it does not guarantee that a
  failed clone avoids a potentially expensive byte-for-byte copy.
- **Use an item provider or activity item source.** Rejected because it abandons the
  smaller raw-URL path verified on physical devices and reintroduces prior crash risk.
- **Show a modal progress screen.** Rejected because preparation has no useful percentage
  and should not block playback, scrolling, or back navigation.
