# Plan: fix the clip-share device hang (swoop `tide` follow-up)

## Context

The clip share feature shipped (commit `295f37e`, "feat(app): share cached clips
from viewer") and is broken on a physical device: after a clip reaches "Ready"
(playing) and the Share button enables, tapping it makes the app appear
unresponsive and nothing shareable happens.

This is not a surprise regression -- it is the exact runtime risk the original work
called out. ADR 15 (`app/docs/design/15-2026-07-01-clip-export-share.md`) lists under
Consequences that "the exact Save Video and AirDrop behavior depends on the system
activity sheet and must be verified on simulator and device," and the implemented
plan (`app/plans/impl/2026-07-01-1725-clip-export-share.md`) pre-designated the
recovery: "share a plain file URL pointing at a friendly-named copy of the cache MP4
(the most battle-tested Save-to-Photos path)." The risk fired on device; this plan is
that pre-planned recovery, hardened.

Goal: make Save to Photos, AirDrop, and Save to Files actually work on device from the
clip viewer, while keeping the friendly export filename and the existing purged-cache
self-heal -- and keep the fix unit-testable so it cannot silently regress.

## Symptoms (so a reviewer can re-verify)

Reproduce: open a clip, wait for "Ready", tap Share. Observed: the app becomes
unresponsive (the share sheet comes up but never becomes usable). Device log excerpt,
classified:

- **Load-bearing (the actual failure):**
  - The share sheet is presented but stuck on "Preparing" and swallows interaction. This
    behavior is the only reliable signal -- there is no distinguishing log line (see the
    benign-noise bucket below).
- **Evidence it is a stuck sheet, not a hard deadlock:** `action=event.heartbeat` /
  `action=event.tempChanged` reducer log lines keep appearing *after* the share errors.
  Those are main-actor-dispatched SSE events; their continued flow proves the main
  thread is alive. So "unresponsive" == a modally presented share UI that never finished
  preparing, not a frozen run loop.
- **Benign noise (do NOT cite as evidence -- these print for working local shares too):**
  - `error fetching item for URL:...clip-....mp4 : (null)` -- appears twice per share.
    Despite the wording, this is benign: the *fixed* build (which shares end to end --
    friendly name, thumbnail, real AirDrop / Files / Photos transfers) prints the same
    line on device. So it does not distinguish the failure. (An earlier read of this bug
    treated it as the load-bearing signal; device verification of the fix disproved that.)
  - `Only support loading options for CKShare and SWY types.` -- the sheet's
    collaboration / "Shared With You" type probe; emitted for ordinary file/text shares
    that work. (An earlier read of this bug leaned on this line via an Apple forum
    thread; that thread overstates it. Corrected here.)
  - `error fetching file provider domain for URL:... : (null)` -- a file in our own
    sandbox (`Library/Caches`) has no File Provider domain, so this "fails" with null
    for every local share.
  - `Failed to request default share mode ... Code=-10814`, `Failed to locate container
    app bundle record ...`, `could not find answer for domain 8 ... canmaplsdatabase ...
    Code=-54` -- standard LaunchServices / sandbox chatter a third-party app triggers on
    every on-device share sheet.

## Root cause (so a reviewer can re-verify)

The shipped share path in `ClipViewerViewController.swift#shareTapped` builds the sheet
via the configuration initializer over a lazy item provider:

```swift
let configuration = UIActivityItemsConfiguration(itemProviders: [provider])
let activityViewController = UIActivityViewController(activityItemsConfiguration: configuration)
```

where `provider` comes from `ClipViewerViewController.swift#makeShareItemProvider` as
`NSItemProvider(contentsOf: url)` with `suggestedName` set. `NSItemProvider(contentsOf:)`
registers a *lazy* file representation (the bytes are vended on demand via
`loadFileRepresentation` / file coordination). On device, the
`UIActivityViewController(activityItemsConfiguration:)` + lazy-provider path produces a
sheet that never finishes preparing. The failure has no clean distinguishing log line
(the `error fetching item for URL ... (null)` line prints on the working build too, so it
is benign); the diagnosis rests on the differential control below plus device behavior,
which the acceptance gate confirms.

Differential control in this repo: `HealthViewController.swift#exportLogs` shares via
the classic `UIActivityViewController(activityItems:applicationActivities:)` initializer
and works on the same device, same daemon, same radios. The clip viewer is the only
place in the app that deviated to the `activityItemsConfiguration:` initializer (grep
confirms these APIs appear only in `ClipViewerViewController.swift` and
`HealthViewController.swift`; `UIActivityItemSource` is unused).

Honest caveat for the reviewer: that control is confounded -- Health shares a `String`,
not a file URL. So the in-repo proof is "classic + text works," and "classic + file URL
works on this device" is inferred from it being the canonical iOS file-share recipe, not
yet observed. The fix removes *both* suspect elements (the configuration wrapper and the
lazy provider), and device verification (below) is the acceptance gate.

Why automated tests did not catch it: by design no unit test drives the `present`
branch (there is no window under `loadViewIfNeeded()`), so `just app-test` cannot
exercise the failing call; only the load-bearing manual device step could, and it ran
after merge rather than before.

## Decision (the fix)

Share the cached MP4 as a real **file URL** through the classic
`UIActivityViewController(activityItems:applicationActivities:)` initializer -- aligning
the clip viewer with the app's already-working share path in `HealthViewController`. A
plain `.mp4` file URL is what surfaces the movie activities: the system derives the
UTType from the extension (`mp4` -> `public.mpeg-4`, which conforms to `public.movie`),
so Save Video (`saveToCameraRoll`), AirDrop, and Save to Files are all offered; no
`UIActivityItemSource` / explicit `dataTypeIdentifierForActivityType` is needed.

Because a file URL's export name comes from the file's own `lastPathComponent` (there is
no `suggestedName` hook on the classic file path), materialize a friendly-named copy of
the cached MP4 and share that. On iOS/APFS, `FileManager.copyItem` is a copy-on-write
clone (`clonefile`): instant, no real byte copy, and an independent inode -- so it is
also decoupled from cache churn (a re-pull's `ClipCache.insert` move cannot pull bytes
out from under an in-flight transfer). No hardlink primitive is introduced.

Keep everything else that was correct: the Share button enabled only while `.playing`;
the pre-share existence guard; the purged-cache self-heal (re-pull) on a guard miss; the
`popoverPresentationController?.sourceItem = sender` anchor; and the
`NSPhotoLibraryAddUsageDescription` Info.plist key (gates Save Video only).

## Correctness constraints (baked into the steps)

- **Per-share UUID subdirectory, not a fixed path.** Put the artifact at
  `temporaryDirectory/clip-share/<UUID>/<friendlyName>.mp4`, mirroring the house pattern
  in `ClipPullClient.swift#prepareOutputURL` / `ClipRemuxer.swift#prepareOutputURL`. The
  UUID parent is invisible to destinations (they read `lastPathComponent`). This is
  collision-proof at runtime and, critically, in the parallel Swift Testing suite -- a
  fixed dir would let two tests delete each other's artifact.
- **Cleanup must never touch the cache dir, and must be parallel-safe.** Only ever remove
  subdirectories this instance created. Track them in a per-instance `Set<URL>`
  (`shareArtifactDirectories`). `completionWithItemsHandler` deletes that one share's own
  subdir from disk (only when an artifact was actually created -- never in the last-resort
  branch below); it captures just the subdir `URL` (a `Sendable` value) and touches no
  view-controller state, so it compiles with no main-actor hop and stays correct under
  strict concurrency. `tearDown()` is the sole point that empties the set: it removes every
  tracked subdir and clears the set -- a harmless no-op re-`removeItem` for any the handler
  already deleted, and the real cleanup for the killed-app / missed-handler case. (So the
  handler never mutates the set; the set holds at most one entry per share taken during a
  single viewing and is emptied on teardown -- it does not grow unbounded, which is why an
  untrack-on-completion hop is not worth adding.) Do not blanket-sweep the shared
  `clip-share/` parent (that would race parallel tests and other viewers).
- **Close the last-resort TOCTOU.** If the clone fails (e.g. a purge races between the
  existence guard and the copy), fall back to sharing the real cache URL directly (works,
  just an ugly name) -- but only after re-confirming the cache file still exists. If it is
  gone, return nil so the caller self-heals via `startPull()`. This prevents handing the
  sheet a path that no longer exists (which would reproduce the original stuck sheet).
- **Build synchronously in the tap handler, then present in the same run-loop turn.** The
  work is a `stat` + `createDirectory` + `clonefile` -- all O(1), microseconds; there is
  no 37 MB byte copy on device. Do not dispatch to a background queue (an async hop opens
  a present-after-await teardown window for no benefit).
- **Artifact stays outside `temporaryFiles` and outside `ClipCache`.** The KVO
  playback-failure path (`observePlayerItem` -> `handlePlayerItemFailed` ->
  `fail()`/`startPull()` -> `removeTemporaryFiles()`) must not be able to delete it
  mid-transfer, and the cache remains owned by `ClipCache`. (On iPhone the share sheet is
  a non-fullscreen presentation, so the presenter does not receive `viewWillDisappear`
  while sharing; `tearDown()` does not run mid-share.)

## Files and changes

### Modify: `app/DanCam/DanCam/Features/ClipViewer/ClipViewerViewController.swift`

Remove `import`-level and code use of `UIActivityItemsConfiguration` /
`NSItemProvider`. Replace the provider machinery with a file-URL artifact.

Add stored state alongside `temporaryFiles`:

```swift
private var shareArtifactDirectories: Set<URL> = []

// Root for the per-share clone subdirectories. Internal (not private) with a single
// default so a test can point it at a regular file, forcing the clone below to fail and
// exercising the last-resort fallback -- no DI seam through AppDependencies.
var shareScratchDirectory = FileManager.default.temporaryDirectory
    .appending(path: "clip-share", directoryHint: .isDirectory)
```

Rewrite `shareTapped` and replace `makeShareItemProvider` with an artifact builder:

```swift
@objc private func shareTapped(_ sender: UIBarButtonItem) {
    guard let artifact = makeShareArtifact() else {
        if currentItemURL != nil {
            startPull()   // cache purged between .playing and the tap -> self-heal (ADR 13)
        }
        return
    }

    let activityViewController = UIActivityViewController(
        activityItems: [artifact.url],
        applicationActivities: nil
    )
    activityViewController.popoverPresentationController?.sourceItem = sender
    if let directory = artifact.temporaryDirectory {
        activityViewController.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: directory)
        }
    }
    present(activityViewController, animated: true)
}

private struct ShareArtifact {
    let url: URL
    let temporaryDirectory: URL?   // non-nil only when we created a clone to clean up
}

private func makeShareArtifact() -> ShareArtifact? {
    guard let cacheURL = currentItemURL, fileExistsAsFile(cacheURL) else { return nil }

    let subdirectory = shareScratchDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let destination = subdirectory.appending(path: Formatters.clipExportFilename(clip))

    do {
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: cacheURL, to: destination)  // APFS COW clone: instant, independent inode
        shareArtifactDirectories.insert(subdirectory)
        return ShareArtifact(url: destination, temporaryDirectory: subdirectory)
    } catch {
        try? FileManager.default.removeItem(at: subdirectory)
        // Last resort: share the real cache file (ugly name) rather than fail -- but only
        // if it still exists; if it was purged in the TOCTOU window, self-heal instead.
        return fileExistsAsFile(cacheURL) ? ShareArtifact(url: cacheURL, temporaryDirectory: nil) : nil
    }
}

private func fileExistsAsFile(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && isDirectory.boolValue == false
}
```

Extend `tearDown()` to release any still-tracked artifact dirs:

```swift
private func removeShareArtifactDirectories() {
    for directory in shareArtifactDirectories {
        try? FileManager.default.removeItem(at: directory)
    }
    shareArtifactDirectories.removeAll()
}
```
Call it from `tearDown()` next to `removeTemporaryFiles()`.

Update the test hook: replace `makeShareItemProviderForTesting() -> NSItemProvider?`
with a hook that returns the whole artifact, not just its URL, so a test can tell the
clone path from the last-resort fallback and clean up only what it owns:

```swift
func makeShareArtifactForTesting() -> (url: URL, temporaryDirectory: URL?)? {
    guard let artifact = makeShareArtifact() else { return nil }
    return (artifact.url, artifact.temporaryDirectory)
}
```

(Return a tuple rather than the `private struct ShareArtifact` so the private type stays
private.) Keep `shareTappedForTesting()` and `isShareButtonEnabled` unchanged. No change to
`render` (button still enabled only in `.playing`) or to `configureShareButton`.

### Modify: `app/DanCam/DanCamTests/Features/ClipViewer/ClipViewerViewControllerTests.swift`

Point the provider tests at the new hook and assert the artifact directly. Every new or
renamed test uses the tuple hook and cleans up only the `temporaryDirectory` it owns --
never `deletingLastPathComponent()` of a possibly-cache URL (blast-radius note below):

- Rename `shareItemProviderIsNilBeforePlaying` -> `shareArtifactIsNilBeforePlaying`;
  assert `controller.makeShareArtifactForTesting() == nil` (comparing the optional tuple
  to `nil` is legal without `Equatable`).
- Replace `cacheHitShareProviderUsesCachedMP4SuggestedNameAndMovieType` with a
  behavioral, structure-insensitive artifact test on the cache-hit playing path (reuse
  the existing `temporaryFile(extension:contents:)` helper and inline `ClipCache`
  double):

  ```swift
  let artifact = try #require(controller.makeShareArtifactForTesting())
  defer { if let dir = artifact.temporaryDirectory { try? FileManager.default.removeItem(at: dir) } }
  #expect(artifact.url.lastPathComponent == Formatters.clipExportFilename(clip))
  #expect(FileManager.default.fileExists(atPath: artifact.url.path))
  #expect(try Data(contentsOf: artifact.url) == Data([0x02]))        // clone carries the cache bytes
  #expect(UTType(filenameExtension: artifact.url.pathExtension)?.conforms(to: .movie) == true)
  ```
  (`UniformTypeIdentifiers` is already imported in this test file.) This is a real
  regression test for the shared artifact -- name, backing bytes, and movie-type
  eligibility -- which the old provider assertion could not meaningfully cover on device.
  Cleaning up `artifact.temporaryDirectory` (nil-guarded) rather than
  `artifact.url.deletingLastPathComponent()` is deliberate: on the clone path the URL's
  parent is the disposable per-share UUID subdir, but the fallback returns the cache URL,
  whose parent is a shared directory (the cache dir; in tests the process temp root) -- and
  a `defer` (which runs even when an assertion fails) that deleted it would nuke unrelated
  fixtures.
- Add `cloneFailureFallsBackToCacheURL` -- covers the last-resort branch, which is the
  plan's own named defense against a re-introduced stuck sheet. Stand up the same
  cache-hit playing controller (so `cacheURL` is a real temp `.mp4`), then force the clone
  to fail deterministically and race-free by pointing the scratch root at a regular file,
  so `createDirectory` throws `ENOTDIR`:

  ```swift
  let blocker = try temporaryFile(extension: "blocker", contents: Data())  // a file, not a dir
  defer { try? FileManager.default.removeItem(at: blocker) }
  controller.shareScratchDirectory = blocker
  let artifact = try #require(controller.makeShareArtifactForTesting())
  #expect(artifact.url == cacheURL)             // shared the real cache file, ugly name and all
  #expect(artifact.temporaryDirectory == nil)   // nothing owned -> handler skips, defer skips
  ```
  The sibling "cache also purged in the TOCTOU window -> return nil -> self-heal" sub-case
  is intentionally left uncovered: forcing the cache file to vanish between the two
  `fileExistsAsFile` checks needs a filesystem-race hook heavier than this bug warrants. It
  is flagged here so it is a known gap, not a silent one -- device step 4 and the existing
  `purgedCacheShareTapSelfHealsByPulling` already cover the guard-miss self-heal that
  matters in practice.
- Add `viewWillDisappearCleansUpShareArtifacts` -- covers the `tearDown()` cleanup wiring.
  Obtain a clone-path artifact via the hook, then drive the suite's existing teardown entry
  point:

  ```swift
  let artifact = try #require(controller.makeShareArtifactForTesting())
  let directory = try #require(artifact.temporaryDirectory)
  defer { try? FileManager.default.removeItem(at: directory) }   // safety net if the assert fails
  #expect(FileManager.default.fileExists(atPath: directory.path))

  controller.viewWillDisappear(false)                            // house pattern -> tearDown()

  #expect(FileManager.default.fileExists(atPath: directory.path) == false)
  ```
  This fails if `removeShareArtifactDirectories()` is ever dropped from `tearDown()`.
- In `purgedCacheShareTapSelfHealsByPulling`, change the one
  `makeShareItemProviderForTesting()` assertion to `makeShareArtifactForTesting() == nil`
  (still expected nil); the self-heal assertions via `shareTappedForTesting()` are
  unchanged.
- Button-state tests (`shareButtonIsDisabledWhilePulling`, `cacheHitEnablesShareButton`,
  the disabled-on-failure assertion in `remuxFailureShowsErrorAndRetryStartsANewPull`)
  are unchanged.

### Amend: `app/docs/design/15-2026-07-01-clip-export-share.md`

The core decision (one system share sheet over the cached MP4) stands; only the
construction mechanism is corrected. Keep append-only history: do not rewrite the
existing body -- add a prominent correction and re-point the Status line.

- Status line -> `- **Status:** Accepted (amended 2026-07-01: construction corrected
  after device verification -- see "Correction 2026-07-01")`.
- Insert a `## Correction 2026-07-01 (device-verified)` section immediately after the
  metadata block and before `## Context`, recording: the symptom (share tap hangs the
  sheet on device); the load-bearing root cause (the
  `UIActivityViewController(activityItemsConfiguration:)` + lazy `NSItemProvider(contentsOf:)`
  path produces a sheet that never finishes preparing, while the app run loop stays alive,
  and the `error fetching item ... (null)`, `CKShare/SWY`, and file-provider-domain log
  lines are all benign for local shares -- they print on the fixed build too); the
  corrected mechanism (classic
  `UIActivityViewController(activityItems:)` over a friendly-named APFS-clone of the cache
  MP4 in `tmp/clip-share/<UUID>/`, cleaned up in `completionWithItemsHandler` plus a
  `tearDown` safety net); and an explicit note that this promotes the "friendly-named
  temporary copy" already listed under Consequences/Alternatives to the primary
  mechanism, superseding the "use `UIActivityItemsConfiguration(itemProviders:)` /
  `suggestedName`" construction details and the "Pass `NSItemProvider` raw ... Rejected"
  and "Hardlink or copy ... Rejected for now" alternatives.

(Decided -- amend in place, not a new ADR 16. Root `AGENTS.md` explicitly permits "amend
or supersede" on a pivot; the only bar is "never *silently* rewrite," which a dated,
prominently placed Correction section plus a re-pointed Status line clears. Amending keeps
one coherent record for an hours-old decision whose core -- one system share sheet over
the cached MP4 -- still stands.)

### No change needed (call out to keep the commit tight)

- `app/DanCam/DanCam/Support/Formatters.swift` -- `clipExportFilename` is reused verbatim
  as the artifact filename; the plan's date-honesty behavior is unchanged.
- `app/DanCam/DanCam/Info.plist` -- `NSPhotoLibraryAddUsageDescription` still required for
  Save Video; keep it.
- `app/AGENTS.md` -- no new ADR (amending 15), so the ADR index is unchanged.
- `docs/roadmap.md` -- swoop `tide` stays `- [x]`; this restores it to genuinely done.

## Tests (Swift Testing)

- `just app-test` must pass, including the rewritten artifact test, the two new tests
  (`cloneFailureFallsBackToCacheURL`, `viewWillDisappearCleansUpShareArtifacts`), and the
  updated purged-source self-heal test.
- The artifact test asserts behavior (friendly name, real file, cache-backed bytes,
  movie UTType) rather than the removed provider internals -- structure-insensitive and
  parallel-safe (each call materializes into its own UUID subdir and cleans it up).
- Coverage now spans all three reachable artifact outcomes: the clone path (artifact
  test), the last-resort cache-URL fallback (`cloneFailureFallsBackToCacheURL`, via the
  injectable `shareScratchDirectory`), and the guard-miss self-heal
  (`purgedCacheShareTapSelfHealsByPulling`) -- plus the `tearDown()` cleanup wiring
  (`viewWillDisappearCleansUpShareArtifacts`). The only uncovered branch is
  clone-fails-then-cache-also-purged -> nil, documented as a known gap in the test-file
  section (it needs a filesystem-race hook heavier than the bug warrants).

## Verification

1. `just app-test` -- all `DanCamTests` pass.
2. `just app-build` -- compiles for the simulator.
3. `just adr-check` -- ADR 15 still passes format/sequence validation (amended, not
   renumbered).
4. **Manual on a physical device (load-bearing -- this is a device-only bug, and the
   in-repo control is classic+text, so classic+file-URL must be observed here):**
   a. Open a clip, wait for "Ready" -> Share enables; during the pull it is disabled.
   b. Tap Share -> the sheet appears promptly and is usable (no hang), showing **Save
      Video**, **AirDrop**, and **Save to Files**.
   c. Save Video -> first-run Photos add-permission prompt -> the clip lands in Photos and
      plays.
   d. Actually complete one **Save to Files** and one **AirDrop** transfer (do not just
      read the sheet): each shows the friendly `Dashcam seg_00026.mp4` name with a single
      `.mp4` extension, and the saved / received file then opens and plays on the
      destination. Completing real transfers -- not just eyeballing the name -- is what
      proves the artifact survives the whole share, i.e. `tearDown()` does not delete it
      mid-transfer (the premise behind "the share sheet is a non-fullscreen presentation,
      so the presenter gets no `viewWillDisappear` while sharing").
   e. Complete or cancel the sheet a few times -> confirm `tmp/clip-share/` does not
      accumulate leftover subdirectories. Read this together with step d: an empty
      `clip-share/` only means "clean" if step d's transfers genuinely completed -- on its
      own it would also read green if the artifact were deleted mid-transfer and the share
      had silently failed.

   Recovery escalation (only if step b/c surprises us -- Save Video absent or the sheet
   still misbehaves): wrap the file URL in a minimal `UIActivityItemSource` that returns
   the URL and declares the movie UTType via `dataTypeIdentifierForActivityType`. Still
   inline in the VC, no dependency seam. Not expected to be needed for a typed `.mp4`
   file URL.

## Re-verification checklist for the reviewer

- Confirm the shipped failing path: `ClipViewerViewController.swift#shareTapped` uses
  `UIActivityViewController(activityItemsConfiguration:)` over
  `ClipViewerViewController.swift#makeShareItemProvider`'s lazy `NSItemProvider(contentsOf:)`.
- Confirm the differential control: `HealthViewController.swift#exportLogs` uses the
  classic `activityItems:` initializer and works; note it shares text, so the control is
  confounded (the fix's file-URL path is the acceptance-gated part).
- Confirm no unit test reaches `present` (the documented test invariant), so `just
  app-test` could not have caught this -- only device step 4 could.
- Confirm the log classification above: there is no clean distinguishing log signal for
  the failure -- `error fetching item ... (null)`, `Only support loading options for
  CKShare and SWY types`, `error fetching file provider domain ... (null)`, and the
  LaunchServices `-10814` / `canmaplsdatabase` `-54` lines are all benign for local shares
  (they print on the fixed build too); the stuck-sheet behavior is the signal.
- Confirm the app was not hard-deadlocked: `action=event.heartbeat` lines continue after
  the share errors in the provided log.

## Out of scope (deferred)

- `UIActivityItemSource` with explicit type / `LPLinkMetadata` -- only if device
  verification demands it (recovery escalation above). Update: the explicit-type
  half was adopted proactively as hardening in a follow-up (see ADR 15 "Corrected
  mechanism"); `LPLinkMetadata` remains out of scope.
- Share from the clip list (pull-then-share for uncached clips) -- later deepening pass.
- Date-stamped export names arrive automatically when swoop `moss` sets trustworthy
  `startMs` (no code change here; `clipExportFilename` already branches on it).
