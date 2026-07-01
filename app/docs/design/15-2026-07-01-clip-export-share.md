# ADR: clip export share sheet

- **Status:** Accepted
- **Date:** 2026-07-01
- **Owner:** app
- **Related:** `13-2026-07-01-durable-clip-cache.md`; `../../../docs/roadmap.md`
  (swoop `tide`)

## Context

The clip viewer can pull, remux, cache, and play a fast-start MP4, but the app has no
way to get that file off the phone. Swoop `tide` calls for Save-to-Photos and AirDrop
over the MP4, and ADR 13 made the durable cached MP4 the playback artifact and future
export artifact.

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
self-heal by starting a fresh pull, matching ADR 13's requirement that playback
tolerate missing cached files.

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
