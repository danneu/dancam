# ADR: clip export share sheet

- **Status:** Superseded by `25-2026-07-10-clip-share-raw-file-url.md`
- **Date:** 2026-07-01
- **Owner:** app
- **Related:** [app clips](../../../docs/design/app/clips.md); `../../../docs/roadmap.md`
  (swoop `tide`)

## Correction 2026-07-01 (device-verified)

The core decision below still stands: one system share sheet over the cached MP4. Only
the construction mechanism changed, after the shipped version hung on a physical device.

**Symptom.** After a clip reached "Ready" and the Share button enabled, tapping Share
brought up the share sheet but it never became usable -- it stalled on "Preparing" and
swallowed interaction, so the app looked unresponsive.

**Load-bearing root cause.** The shipped path built the sheet via
`UIActivityViewController(activityItemsConfiguration:)` over a lazy
`NSItemProvider(contentsOf:)`. On device that combination produces a sheet that never
finishes preparing -- it hangs on "Preparing" and swallows interaction. There is no clean
distinguishing log signal for the failure. The run loop stayed alive throughout
(`event.heartbeat` / `event.tempChanged` reducer log lines kept flowing after the share
errors), so this was a stalled modal share UI, not a frozen main thread. The
`error fetching item for URL:...clip-....mp4 : (null)`,
`Only support loading options for CKShare and SWY types.`, and
`error fetching file provider domain for URL:... : (null)` log lines are all benign -- they
print for ordinary local file/text shares that work, including the fixed build, and are not
evidence of the failure.

**Corrected mechanism.** Share the cached MP4 through the classic
`UIActivityViewController(activityItems:applicationActivities:)` initializer over a real
**file URL**, matching the app's already-working share path in
`HealthViewController.swift#exportLogs`. Because the classic file path has no
`suggestedName` hook, materialize a friendly-named copy of the cache MP4 (an APFS
copy-on-write clone via `FileManager.copyItem`, instant and with an independent inode) at
`tmp/clip-share/<UUID>/<friendlyName>.mp4` and share that. Wrap that file URL in a minimal
`UIActivityItemSource` (`ClipShareItemSource`) that declares the movie UTType explicitly via
`dataTypeIdentifierForActivityType` -- belt-and-suspenders over the system inferring the type
from the `.mp4` extension alone -- so Save Video, AirDrop, and Save to Files are all offered.
It intentionally omits `activityViewControllerLinkMetadata` (no `LPLinkMetadata`), so the sheet
retains its auto-generated QuickLook preview header. Clean the per-share subdirectory up in
`completionWithItemsHandler`, with a `tearDown()` sweep as a safety net for the
killed-app / missed-handler case. If the clone fails, fall back to sharing the real cache
URL (ugly name) when it still exists, else return nil so the caller self-heals via a
re-pull.

**What this supersedes.** This promotes the "friendly-named temporary copy" already listed
under Consequences and Alternatives to the primary mechanism. It supersedes the
"`UIActivityItemsConfiguration(itemProviders:)` / `suggestedName`" construction described
in the Decision below, and the "Pass `NSItemProvider` raw ... Rejected" and "Hardlink or
copy the MP4 ... Rejected for now" alternatives.

## Context

The clip viewer can pull, remux, cache, and play a fast-start MP4, but the app has no
way to get that file off the phone. Swoop `tide` calls for Save-to-Photos and AirDrop
over the MP4, and the app clips design made the durable cached MP4 the playback artifact
and future export artifact.

iOS already provides a single native export surface for this: `UIActivityViewController`.
The system sheet can expose Save Video, AirDrop, Save to Files, and other user-chosen
destinations without the app designing separate export flows.

## Decision

Add one share button to the clip viewer navigation bar. The button is enabled only
while the viewer is playing a cached MP4, and disabled while pulling, preparing, or
failed.

On tap, share the current cached MP4 through `UIActivityViewController` using
`UIActivityItemsConfiguration(itemProviders:)` and an `NSItemProvider` created from
the cached file URL. Set `NSItemProvider.suggestedName` to a friendly export filename
so AirDrop and Files have a human-facing name without the app creating a temporary
copy.

Use `Formatters.clipExportFilename(_:timeZone:)` for that name:

- If `startMs` exists and `timeApproximate == false`, use a local date-stamped
  `Dashcam yyyy-MM-dd HH-mm-ss.mp4` name.
- Otherwise, use `Dashcam seg_NNNNN.mp4`.

This keeps evidence filenames honest: the app does not stamp a date onto a clip whose
time is not yet trustworthy. When swoop `moss` starts providing trusted clip times,
export names become date-stamped without changing the share flow.

Before creating the provider, validate that the current item URL exists and is not a
directory. `NSItemProvider(contentsOf:)` can still create a provider for a missing
`.mp4` path based on the extension, which would present a sheet that fails later if
iOS evicted the cache file. If the share tap finds that a playing cache file is gone,
self-heal by starting a fresh pull, matching the app clips design's requirement that
playback tolerate missing cached files.

Anchor the popover with `popoverPresentationController?.sourceItem = sender` so the
same controller is valid on iPad-style presentations.

Add `NSPhotoLibraryAddUsageDescription` because the system Save Video activity needs
the add-only Photos permission string.

## Consequences

Easy:

- One native sheet covers Save Video, AirDrop, Save to Files, and future share
  destinations.
- All clips share the same export behavior; incident and locked-clip automation can
  layer on later.
- There is no app-owned export temp file to create, copy, track, or delete.
- The cached fast-start MP4 remains the single playback and export artifact.

Hard or risky:

- The exact Save Video and AirDrop behavior depends on the system activity sheet and
  must be verified on simulator and device.
- `suggestedName` behavior is system-owned. If a destination app ignores it or adds a
  duplicate extension, the fallback is a friendly-named temporary copy of the cached
  MP4.
- A cache purge at tap time forces a re-pull instead of presenting immediately, so the
  user must tap share again once playback is ready.

## Alternatives considered

- **Dedicated Save-to-Photos button.** Rejected: it would duplicate the system share
  sheet and still leave AirDrop and Files as separate flows.
- **Auto-save incident clips.** Deferred to swoop `nova`; this change keeps export
  user-initiated and identical for every clip.
- **Share from the clip list.** Deferred: uncached clips need a pull-then-share flow
  and list-specific UI.
- **Hardlink or copy the MP4 to a friendly-named temp file.** Rejected for now:
  `NSItemProvider.suggestedName` provides the friendly name without app-owned temp
  lifecycle, copy fallback, or cleanup races.
- **Use `popoverPresentationController?.barButtonItem`.** Rejected: `sourceItem` is
  the current unified anchor API and accepts `UIBarButtonItem`.
- **Pass `NSItemProvider` raw in `activityItems: [Any]`.** Rejected:
  `UIActivityItemsConfiguration(itemProviders:)` is the first-class item-provider API.
