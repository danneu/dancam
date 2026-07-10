# Fix: share-button crash -- remove the belt-and-suspenders UIActivityItemSource wrapper

## Context

Tapping the share button in the clip viewer crashes the app.

The share path had a known-good shape. Commit `af5d612` ("share clips via the
classic activity sheet over a file URL") shares a friendly-named APFS clone of the
cached MP4 via the classic
`UIActivityViewController(activityItems:applicationActivities:)` initializer over a
plain file URL. That build was **device-verified**: the impl plan
(`app/plans/impl/2026-07-01-2045-clip-share-uttype-hardening.md`) and ADR 15 record
Save Video / AirDrop / Save to Files, the friendly `Dashcam ....mp4` name, and the
QuickLook video-frame thumbnail all observed on a physical device -- with **no**
`UIActivityItemSource`.

Commit `8c4b113` then wrapped that same file URL in `ClipShareItemSource`, a
`UIActivityItemSource` that declares the movie UTType explicitly. Its own plan is
explicit that this was **not** demanded by device verification -- "the plain `.mp4`
file URL already surfaces Save Video / AirDrop / Files. We adopt it anyway as
belt-and-suspenders." That is precisely the "add a shim just in case" move
`AGENTS.md` forbids ("never preserve an old shape, keep a deprecated path, or add a
compatibility shim 'just in case'"). Its only observed effect since has been this
crash.

Because the wrapper is the last thing added to a previously device-verified path and
provides no demonstrated benefit, the ideal fix is not to make the wrapper's
isolation correct -- it is to **delete the wrapper and return to the device-verified
raw file-URL path**. This is smaller, removes the whole `@objc`/actor-isolation
boundary that the wrapper introduced, and follows the repo's delete-and-replace
stance. It stops the crash regardless of the exact executor/threading mechanism.

**On the mechanism (deliberately not load-bearing).** The wrapper is annotated
`@MainActor` (`ClipViewerViewController.swift#ClipShareItemSource`), and the target
builds Swift 6 with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Apple documents the
`UIActivityItemSource` methods as **main-thread callbacks**
([UIActivityItemSource](https://developer.apple.com/documentation/uikit/uiactivityitemsource?language=_7)),
so the earlier "UIKit invokes the `@objc` witness off the main thread and trips a
main-actor executor assertion" hypothesis is *not* a reliable explanation and is
deliberately dropped here. This plan does not attribute a mechanism at all: the
implementer must **capture the actual crash log first** (Xcode crash navigator /
device console) so the real failing frame and assertion/exception text -- not a
guess -- go into the record. If the crash log implicates something outside the share
path, stop -- the premise here is wrong. Either way the fix (deleting the wrapper and
its `@objc`/actor boundary entirely) does not depend on which mechanism the log
shows.

## Change 1: revert the share tap to the raw file URL and delete the wrapper

File: `app/DanCam/DanCam/Features/ClipViewer/ClipViewerViewController.swift`

- In `shareTapped(_:)`, restore the classic form -- share `artifact.url` directly
  (it is already the friendly-named clone produced by `makeShareArtifact()`):

  ```swift
  let activityViewController = UIActivityViewController(
      activityItems: [artifact.url],
      applicationActivities: nil
  )
  ```

  Everything else in `shareTapped` stays: the popover `sourceItem` anchor, and the
  `completionWithItemsHandler` temp-dir cleanup keyed off `artifact.temporaryDirectory`.

- Delete the entire `ClipShareItemSource` class (file-scope, below the view
  controller).
- Delete `import UniformTypeIdentifiers` (line 4): `UTType` is used *only* by the
  wrapper in this file (verified -- no other `UTType`/`UniformTypeIdentifiers`
  reference in `ClipViewerViewController.swift`).

`makeShareArtifact()`, `shareArtifactDirectories`, the clone/last-resort fallback,
and the `tearDown()` sweep are untouched -- the exported artifact is still the
friendly-named APFS clone. Save Video / AirDrop / Files come from the `.mp4`
extension's inferred `public.movie` UTType, exactly as device-verified in `af5d612`.

## Change 2: delete the wrapper's unit test

File: `app/DanCam/DanCamTests/Features/ClipViewer/ClipViewerViewControllerTests.swift`

- Delete `clipShareItemSourceDeclaresMovieTypeAndVendsTheURL` (it exercises the
  now-deleted class).
- Keep `import UniformTypeIdentifiers` -- it is still used by
  `cacheHitShareArtifactClonesCacheWithFriendlyMovieName`, which asserts the clone's
  extension conforms to `.movie` (the real, structure-insensitive guard that the
  export still vends a movie file).
- Keep every other share test unchanged: `makeShareArtifactForTesting` clone,
  `cloneFailureFallsBackToCacheURL`, `removalCleansUpShareArtifacts`,
  `purgedCacheShareTapSelfHealsByPulling`, and the share-button enable/disable
  tests. None reference the wrapper; together they still cover the artifact
  lifecycle and the self-heal-on-purge path.

No new test is added. The prior plan's proposed off-main detached-task test (and its
`nonisolated(unsafe) let host` line, which the reviewer correctly flagged as an
unnecessary-annotation warning) is moot -- there is no wrapper left to guard, and
the coverage it would have provided is against a class that no longer exists. (Note:
`just app-lint` builds only the app target, not `DanCamTests`, so it would not have
caught that test-side warning anyway.)

## Change 3: amend the record

The wrapper appears in the docs; a pivot that is not written down is the next trap.
Per `AGENTS.md#Design decisions` the ADR history is append-only ("to change a
decision, write a new ADR and mark the old one `Superseded by ...`; never silently
rewrite it"), so this reverses via a new ADR rather than an in-place edit.

- **New ADR `app/docs/design/25-2026-07-10-clip-share-raw-file-url.md`** (25 is the
  next app-side seq -- current highest is `24-...`). Status `Accepted`; `Related:` back
  to ADR 15 and ADR 13. It supersedes ADR 15 and:
  - Carries forward every still-valid ADR 15 export decision unchanged: one system
    share sheet over the cached MP4 **file URL**; the friendly-named APFS
    copy-on-write clone at `tmp/clip-share/<UUID>/<friendlyName>.mp4` via
    `Formatters.clipExportFilename(_:timeZone:)`; the classic
    `UIActivityViewController(activityItems:applicationActivities:)` initializer over a
    real file URL; `popoverPresentationController?.sourceItem` anchor;
    `completionWithItemsHandler` cleanup plus `tearDown()` sweep; clone-failure
    fallback to the real cache URL then self-heal-via-re-pull; `LPLinkMetadata`
    omitted so the QuickLook preview header is retained; `NSPhotoLibraryAddUsageDescription`
    for Save Video; and the share-button enable-only-while-playing rule.
  - Records the single change: the belt-and-suspenders `ClipShareItemSource`
    `UIActivityItemSource` wrapper (added in `8c4b113`) is removed. Rationale: it was
    proactive explicit-UTType hardening that device verification never demanded (the
    `.mp4` extension's inferred `public.movie` type already surfaced Save Video /
    AirDrop / Files in `af5d612`), and its only observed effect was a share-button
    crash. Movie-type inference now comes from the `.mp4` extension, as originally
    device-verified. Include the captured crash log's failing frame / assertion text
    (from Verification step 1) as the evidence.
- **Amend ADR `app/docs/design/15-2026-07-01-clip-export-share.md`** -- change only its
  `Status` line to `Superseded by 25-2026-07-10-clip-share-raw-file-url.md`. Do not
  rewrite its body (append-only history: its "Correction 2026-07-01" and the wrapper
  it described stay as the record of what was accepted then).
- **Update the ADR index in `app/AGENTS.md`** (the `docs/design/` "Current:" list):
  add the `25-...` entry, and mark the `15-2026-07-01-clip-export-share.md` line
  `-- superseded by ADR 25`, matching the existing superseded-entry style (e.g. ADR
  04/05/19/20).

- **`app/plans/impl/2026-07-01-2045-clip-share-uttype-hardening.md`** -- this is the
  historical record of an implemented change; do not rewrite its body. Add a short
  header note that Commit 2's `ClipShareItemSource` was later reverted (see ADR 25
  and this plan), so a reader does not resurrect it.
- **`app/plans/impl/2026-07-01-1845-clip-share-device-hang.md`** -- its "Out of
  scope (deferred)" forward-pointer to the `UIActivityItemSource` escalation is now
  stale; append a one-line note that the escalation was tried and reverted.

## Verification

1. **Confirm the cause first.** Reproduce the crash on the current build, capture the
   crash log, and record the failing frame + assertion text in the ADR correction /
   commit body. This is the evidence the prior fix lacked.
2. `just app-test` -- all `DanCamTests` pass; the deleted wrapper test is gone and no
   other share test regresses.
3. `just app-build` / `just app-lint` -- app target compiles clean, no new warnings.
4. **End-to-end. Simulator is a smoke test only; the device is the acceptance gate.**
   The simulator does not reproduce every activity destination or system-service
   surface (AirDrop and some Save destinations are device-only), so it cannot certify
   destination availability -- see
   [Apple's simulator-vs-device guidance](https://developer.apple.com/documentation/xcode/testing-in-simulator-versus-testing-on-hardware-devices).
   Run against `just raspi-mock` (or the real Pi from Xcode with the `dancam.local`
   host set), open a clip, wait for "Ready", tap Share.
   - **Simulator (smoke):** the sheet must present and be usable -- no crash, no stuck
     "Preparing" -- and the `tmp/clip-share/<uuid>` scratch dir must be cleaned up on
     cancel/complete (no accumulation). Destination availability is *not* asserted here.
   - **Physical device (acceptance):** the sheet still offers **Save Video**,
     **AirDrop**, and **Save to Files**, still shows the video-frame QuickLook
     thumbnail and the friendly `Dashcam ....mp4` name; complete one real Save to
     Files (or AirDrop) transfer and confirm the saved file plays; confirm the scratch
     dir is cleaned up. This device pass also re-confirms the existing-behavior claims
     inherited from the raw-URL implementation (`af5d612`).
