# App video sharing

The app shares already-local video through one native system activity sheet. Cached
clip MP4s and phone-owned incident MP4 or TS segments use the same preparation and
presentation lifecycle; the app does not build separate Save Video, AirDrop, or Save
to Files flows.

[App clips](clips.md) owns how a Pi clip becomes a durable cached MP4.
[Phone-owned incidents](incidents.md) owns local incident artifacts and their
selection UI. This page owns export naming, temporary share artifacts, responsive
preparation, activity-sheet presentation, and cleanup.

## Share surfaces and filenames

The clip viewer enables Share only while its cached MP4 is playing. A missing cached
file starts the existing pull and remux path again instead of presenting a broken
sheet. The incident detail screen enables Share after the user selects a locally
installed MP4 or raw TS segment. There is no stitched incident export; each selected
segment is shared independently.

Clip exports use `Formatters.clipExportFilename`:

- a clip with a trustworthy resolved start date becomes
  `Dashcam yyyy-MM-dd HH-mm-ss.mp4` in the user's local time zone; and
- a clip without trustworthy time becomes `Dashcam seg_NNNNN.mp4`.

Incident filenames include the phone-recorded press time, segment sequence, and the
artifact's real extension. The app never invents a trustworthy clip date from an
approximate timestamp.

`NSPhotoLibraryAddUsageDescription` is present because the system Save Video activity
needs add-only Photos permission.

## Responsive preparation

`VideoShareCoordinator` owns one preparation task per presenting screen. A tap
immediately replaces the Share icon with an accessible "Preparing video" spinner.
Playback, scrolling, and back navigation remain responsive; only actions that conflict
with the selected artifact are disabled. A second tap cannot start duplicate work.

Filesystem work crosses a nonisolated `ShareArtifactPreparer` dependency. The live
implementation:

- accepts only an existing regular file;
- creates `tmp/video-share/<UUID>/<friendly-name>`;
- uses Darwin `clonefile` to make a copy-on-write clone with an independent inode;
- checks cancellation before and after cloning;
- removes partial directories on cancellation or failure;
- falls back to the original regular-file URL when staging fails; and
- reports the source as unavailable when it disappears.

There is deliberately no byte-for-byte copy fallback. A filesystem that cannot clone
the media still gets a responsive raw-URL share, while a media-sized copy can never
block or consume temporary space unexpectedly.

## Activity sheet contract

The coordinator passes the prepared file URL directly to the classic
`UIActivityViewController(activityItems:applicationActivities:)` initializer. The
file extension supplies type information. The popover is anchored through
`popoverPresentationController.sourceItem` so the same presentation works in
iPad-style environments.

Do not wrap the URL in `NSItemProvider`, `UIActivityItemsConfiguration`, or
`UIActivityItemSource`, and do not add `LPLinkMetadata`. For MP4 clips, the raw file
URL is the physical-device-verified contract: it offers Save Video, AirDrop, and Save
to Files, keeps the system QuickLook preview, and avoids the device-only hangs and
executor crash caused by the provider paths. Raw incident TS files use the same
presentation lifecycle but naturally expose only destinations that accept that file
type.

## Cancellation, recovery, and cleanup

Popping the screen, controller teardown, deletion, a new pull, or selection loss
cancels preparation. A generation token rejects late results; any late owned directory
is removed instead of being presented. Once the activity sheet finishes, its owned
directory is removed. Raw-URL fallbacks are never deleted by the share coordinator.

If a cached clip disappears, the viewer starts a fresh pull so the screen self-heals.
If an incident artifact disappears, the detail screen clears its stale selection and
presents an explicit unavailable alert. Incident deletion and clip deletion cancel
preparation before mutating their owning data.

The `share` unified-log category records preparation boundaries, cloned versus raw-URL
outcomes, cancellation, unavailability, sheet initialization, and duration. See
[app logging](logging.md) for level and export policy.

## Testing obligations

Share behavior is covered at observable boundaries:

- preparer tests cover regular-file validation, clone independence, raw-URL fallback,
  cancellation, and partial-directory cleanup;
- clip-viewer and incident-detail tests exercise the coordinator seam for immediate
  progress, duplicate suppression, conflicting controls, source-specific recovery,
  lifecycle cancellation, stale-result cleanup, friendly names, presentation, and
  completion cleanup.

Native activity destinations and QuickLook behavior remain physical-device checks;
unit tests do not lock down private activity-sheet structure.

## Decision log

### 2026-07-01: Use one system share sheet over the cached MP4

(absorbed from app ADR 15, 2026-07-01)

The durable fast-start MP4 cache was already the playback artifact and natural export
artifact. `UIActivityViewController` could expose Save Video, AirDrop, Save to Files,
and future user-selected destinations without separate app-owned export flows. Share
was therefore added to the clip viewer only when playback had a ready cached file,
with time-honest friendly filenames and a fresh pull when the cache disappeared.

A dedicated Photos button was rejected because it would duplicate the system sheet
and still leave AirDrop and Files unsolved. Automatic incident export and list-level
sharing were deferred because they needed different product and pull lifecycles.
`sourceItem` was chosen over the older bar-button-specific popover property as the
unified anchor API.

The first construction used a lazy `NSItemProvider` through
`UIActivityItemsConfiguration` so `suggestedName` could avoid a temporary file. That
choice did not survive device verification.

### 2026-07-01: Replace the provider sheet after a device-only hang

(absorbed from the 2026-07-01 device-verification amendment to app ADR 15)

On a physical device, the provider-backed sheet stalled forever on "Preparing" and
swallowed interaction even though the app run loop stayed alive. No log line uniquely
identified the failure: item-fetch, CKShare/SWY, and file-provider-domain messages also
appeared during successful ordinary shares and were reclassified as benign noise.

The share path moved to the classic activity-controller initializer over a real file
URL, matching the already-working log-export share. A friendly-named APFS clone under a
per-share temporary directory restored destination filenames while completion cleanup
and teardown handled normal and missed callbacks. Clone failure fell back to the cache
URL, and a missing cache returned to the pull path.

The earlier provider construction and its claim of needing no temporary lifecycle
were abandoned. The observed stuck sheet, not a diagnostic log pattern, remains the
useful regression signal.

### 2026-07-01: The item-source hardening did not pan out

(absorbed from the 2026-07-01 item-source amendment to app ADR 15)

The working file URL was briefly wrapped in `ClipShareItemSource` to declare the movie
UTType explicitly. This was speculative belt-and-suspenders hardening: the `.mp4`
extension had already produced the required activities on a device. The wrapper
omitted link metadata so QuickLook could keep generating the preview header.

The wrapper later proved harmful and supplied no demonstrated product benefit. Its
history is retained because it explains why adding an apparently harmless type or
metadata abstraction around the raw URL requires new device evidence.

### 2026-07-10: Return to raw file URLs after an executor crash

(absorbed from app ADR 25, 2026-07-10)

Two physical-device crash reports showed the Objective-C item-source callback arriving
on a default-QoS queue and trapping in Swift's expected-executor check against the
`@MainActor` wrapper. Removing `ClipShareItemSource` returned the app to the smaller
file-URL path already verified with real Save Video, AirDrop, Files, friendly names,
and the QuickLook thumbnail.

Making the wrapper concurrency-safe was rejected because the wrapper had no observed
value. Another provider or metadata layer was rejected because both provider families
had now caused device-only failures. Separate destination actions remained unnecessary
because the native sheet already supplied them.

### 2026-07-15: Prepare share artifacts off the main actor

(absorbed from app ADR 30, 2026-07-15)

Friendly temporary files were still being created synchronously in view controllers.
Large media could delay the spinner, playback, scrolling, and back navigation, while
`FileManager.copyItem` did not guarantee that staging would remain copy-on-write.

The app introduced one reusable coordinator for clip and incident shares, a
nonisolated preparation dependency, cancellable generation-checked work, and
`clonefile` as the explicit performance contract. The raw source remains the safe
fallback, so clone failure does not become share failure. Preparation has no meaningful
percentage, making an inline spinner more honest and less disruptive than a modal
progress screen.

Synchronous controller-local copies were rejected because they block interaction and
duplicate lifecycle code. Off-actor `FileManager.copyItem` was rejected because it can
fall through to a full copy. Provider and item-source paths remained rejected because
they discard the device-verified raw-URL contract.
