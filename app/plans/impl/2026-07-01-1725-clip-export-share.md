# Plan: clip export / share (swoop `tide`)

## Context

The clip viewer can pull, remux, and play a clip, but there is no way to get the
`.mp4` off the phone. Swoop `tide` in `docs/roadmap.md` calls for "Save-to-Photos
and AirDrop UI over the `.mp4`," and ADR 13 (`app/docs/design/13-2026-07-01-durable-clip-cache.md`)
already designated the durable fast-start cache MP4 as "the export artifact for
swoop `tide`." So the artifact exists; this change is the UI + plumbing to share it.

We converged (in discussion) on the most iOS-native shape: a **single share button
that presents the system share sheet** (`UIActivityViewController`) over the cached
MP4. That one sheet delivers Save-to-Photos, AirDrop, and Save-to-Files together, so
"save to my phone" and "send to someone" collapse into one control -- both are
first-class, and behavior is identical for every clip (incident or not; `nova`/locked
clips are not special-cased here).

Repo state note (ADR number + what to commit). Max ADR on disk is now `14`
(`14-2026-07-01-structured-logging-and-export.md` landed as `736ab7b` since an earlier
draft of this plan, and is already indexed in `app/AGENTS.md`), so this change's ADR is
**15**. Treat this number the same way as the file set below -- a rule, not a cached
value: it has already drifted once (an earlier draft said `14`; an unrelated ADR then
took `14`), so at implementation time list `app/docs/design/`, take the next integer
above the current max, and do not trust the number written here. The `minutesSeconds`
zero-pad tweak that earlier drafts told you to preserve is now **committed** (`ef29918`),
so `Formatters.swift` is a clean committed base and this plan's formatter work is purely
additive on top of it (a new `clipExportFilename` function plus new `@Test`s) -- there
is no uncommitted formatter work to protect.

Commit rule -- deliberately a rule, not a working-tree snapshot, because this note has
gone stale every review round (and once mid-round) as unrelated fixes land as their own
commits. The export-share commit must contain **exactly this plan's file set and
nothing else**:
`app/DanCam/DanCam/Support/Formatters.swift`,
`app/DanCam/DanCam/Features/ClipViewer/ClipViewerViewController.swift`,
`app/DanCam/DanCam/Info.plist`, the new
`app/docs/design/15-2026-07-01-clip-export-share.md`, `app/AGENTS.md` (register ADR 15
in the ADR index), `docs/roadmap.md`, and the two test files
(`app/DanCam/DanCamTests/Support/FormattersTests.swift`,
`app/DanCam/DanCamTests/Features/ClipViewer/ClipViewerViewControllerTests.swift`).
As of this writing the tree carries no tracked modifications; the only non-plan paths
are untracked scratch (`app/plans/` -- this plan itself -- plus `personal-notes/` and
`prompts/`), which stay **out** of the commit. Because the tree churns between
sessions, re-run `git status` at commit time and `git add` only the files listed above
rather than trusting any snapshot here.

Design-review pivot (folded in): the friendly filename does **not** need an app-built
temp file. `NSItemProvider.suggestedName` is the documented mechanism for the name
that AirDrop / Files write the item under, so we share an `NSItemProvider` over the
existing cache file and set `suggestedName`. This deletes the `ClipShareItem`
dependency seam, its `AppDependencies` wiring, the temp-dir lifecycle, the async
teardown-cleanup race, the copy fallback, and a dedicated test suite -- a large net
simplification. See "Alternatives" in ADR 15.

## Decision

1. Share via the system share sheet (`UIActivityViewController`) over an
   `NSItemProvider` built from the cached fast-start MP4, with `suggestedName` set to a
   human-facing filename. One sheet delivers Save-to-Photos, AirDrop, and Save-to-Files.
   `suggestedName` is the documented friendly-name hook (AirDrop/Files write the
   provider's data under that name), so no app-managed temp file, hardlink, or copy is
   needed -- and thus no dependency seam and no `AppDependencies` change.
2. New pure helper `Formatters.clipExportFilename(_:timeZone:)`: a date-stamped name
   when the clip's time is trustworthy, else a neutral segment name. This is the
   "never stamp a time we can't trust" evidence rule, keyed off the data we already
   have. Used as the provider's `suggestedName`.
3. Clip viewer: one nav-bar share button, enabled only while playing; on tap, build
   the `NSItemProvider` from `currentItemURL`, wrap it in
   `UIActivityItemsConfiguration(itemProviders:)`, and present
   `UIActivityViewController(activityItemsConfiguration:)` -- the documented,
   first-class item-provider path (see the construction note below).
4. Add the `NSPhotoLibraryAddUsageDescription` Info.plist key (the sheet's built-in
   "Save Video" crashes without it).
5. ADR 15 (registered in the `app/AGENTS.md` ADR index) + check off roadmap `tide`.

## Correctness constraints (baked into the steps)

- **Build the provider from `currentItemURL`** (the remuxed fast-start MP4 in
  `Library/Caches`), never the pulled `.ts` (Photos rejects `.ts`; `NSItemProvider`
  infers the type from the source URL extension). On the live path `currentItemURL` is
  always a `ClipCache` MP4, so the source is correct.
- **Validate the file exists before promising it to the system.**
  `NSItemProvider(contentsOf:)` does **not** prove the file is there -- it returns a
  *non-nil* provider for a missing path and registers `public.mpeg-4` from the `.mp4`
  extension, so a cache file purged (iOS can evict `Library/Caches`) between `.playing`
  and the tap would present a sheet that only fails downstream. Guard that
  `currentItemURL` is set and exists as a non-directory file
  (`FileManager.default.fileExists(atPath:isDirectory:)`) before constructing the
  provider; also guard the not-playing case (the disabled button already prevents it).
  On a guard miss, never crash and never leave the enabled button inert: if
  `currentItemURL` is non-nil but the file is gone (the purge case), self-heal by
  re-pulling (`startPull()`) rather than silently no-op'ing -- this reuses the exact
  recovery ADR 13 mandates for a purged `Library/Caches` clip ("playback must tolerate
  a missing or unreadable cached file"; the viewer already self-heals a cache-hit
  playback failure the same way), so the button disables during the pull and re-enables
  at `.playing`. If `currentItemURL` is nil (not playing), present nothing. Never a dead
  control. (Keep the `NSItemProvider(contentsOf:)` optional guard too,
  belt-and-suspenders.)
- **No app-owned share artifact, so no teardown race.** Because we share an
  `NSItemProvider` over the durable cache file (not an app-created temp copy), there is
  nothing for the async KVO playback-failure path (`observePlayerItem` ->
  `handlePlayerItemFailed` -> `fail()`/`startPull()`, which can fire while the sheet is
  open) to delete mid-transfer. Do **not** add anything to `temporaryFiles`, and do
  **not** delete the cache file on sheet dismissal -- the cache is owned by `ClipCache`.
  (The system stages/copies the bytes itself at share time for AirDrop/Files/Photos;
  that copy is system-managed and lazy, not an app temp file.) This dissolves the P0
  cleanup race the first draft had to engineer around.
- **Set the popover anchor with `popoverPresentationController?.sourceItem = sender`**
  -- `UIActivityViewController` aborts on iPad/Catalyst without an anchor. `sourceItem`
  is the current unified anchor API (iOS 16+) and `UIBarButtonItem` conforms to
  `UIPopoverPresentationControllerSourceItem`, so it supersedes the older
  `barButtonItem`. Use `@objc func shareTapped(_ sender: UIBarButtonItem)` and pass
  the sender.
- **Create/configure the share button before the cache-hit `play()` in `viewDidLoad`.**
  The cache-hit path calls `play()` synchronously at the end of `viewDidLoad`, which
  sets `state = .playing` and runs `render`; the button must already exist so `render`
  can enable it. Default `isEnabled = false`.

## Files and changes

### Modify: `app/DanCam/DanCam/Support/Formatters.swift`
Add to the `Formatters` enum:

```swift
static func clipExportFilename(_ clip: Clip, timeZone: TimeZone = .current) -> String {
    if let startMs = clip.startMs, clip.timeApproximate == false {
        let date = Date(timeIntervalSince1970: Double(startMs) / 1000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")   // matches Formatters.temperature
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"           // colons are illegal in filenames
        return "Dashcam \(formatter.string(from: date)).mp4"
    }
    return String(format: "Dashcam seg_%05d.mp4", clip.id)     // %05d = min width; ids > 99999 are fine
}
```
The date branch is future-facing: `startMs` is nil until swoop `moss`, so today this
always yields the neutral name and auto-upgrades when trusted timestamps arrive. The
`timeZone` param exists for deterministic tests. The returned name includes the `.mp4`
extension; it is handed to `suggestedName` verbatim (see the device-verification note
on double extensions).

### Modify: `app/DanCam/DanCam/Features/ClipViewer/ClipViewerViewController.swift`
- Add stored `private let shareButton = UIBarButtonItem()`. (No `shareArtifactURL` --
  there is no app-owned artifact.)
- In `viewDidLoad`, after `configureViews()` and **before** the cache-lookup/`play`
  block, configure and install the button: `image = UIImage(systemName: "square.and.arrow.up")`,
  `style = .plain`, `target = self`, `action = #selector(shareTapped(_:))`,
  `accessibilityLabel = "Share clip"`, `isEnabled = false`, then
  `navigationItem.rightBarButtonItem = shareButton`.
- In `render(_:)`, set `shareButton.isEnabled`: `true` in `.playing`, `false` in
  `.pulling` / `.preparing` / `.failed`.
- Add:
  - `private func makeShareItemProvider() -> NSItemProvider?` -> guard `currentItemURL`;
    guard the file exists as a non-directory
    (`FileManager.default.fileExists(atPath: url.path, isDirectory:)`; see the
    file-validation constraint -- `NSItemProvider(contentsOf:)` alone would not catch a
    purged file); `NSItemProvider(contentsOf: url)` (still guard the optional nil); set
    `suggestedName = Formatters.clipExportFilename(clip)`; return it.
  - `@objc private func shareTapped(_ sender: UIBarButtonItem)` -> get
    `makeShareItemProvider()`. On nil, self-heal instead of no-op'ing: if
    `currentItemURL != nil` (cache purged between `.playing` and the tap) call
    `startPull()` and return -- the button disables during the pull and re-enables at
    `.playing`, so the user re-taps when ready (we intentionally do **not** queue a
    deferred auto-present, keeping the async surface flat); else `currentItemURL == nil`
    (not playing; the disabled button already prevents this) return with no action. On a
    non-nil provider, wrap it in
    `UIActivityItemsConfiguration(itemProviders: [provider])`; build
    `UIActivityViewController(activityItemsConfiguration: config)`; set
    `popoverPresentationController?.sourceItem = sender`; `present`. No
    `completionWithItemsHandler` cleanup is needed (nothing app-owned to remove).
    `startPull()` is safe here: the cache file is owned by `ClipCache` and is not in
    `temporaryFiles`, so the re-pull's `removeTemporaryFiles()` cannot delete it.
- No change to `tearDown()` (no artifact to clean).
- Add test hooks (mirror `retryForTesting()`): `var isShareButtonEnabled: Bool { shareButton.isEnabled }`,
  `func makeShareItemProviderForTesting() -> NSItemProvider? { makeShareItemProvider() }`,
  and `func shareTappedForTesting() { shareTapped(shareButton) }` (drives the guard-miss
  self-heal path without presenting a real sheet).

Construction note: use the documented item-provider path --
`UIActivityItemsConfiguration(itemProviders:)` +
`UIActivityViewController(activityItemsConfiguration:)` (available on the app's
deployment target). `NSItemProvider` does not conform to `UIActivityItemSource`, so
passing it raw in `activityItems: [Any]` relies on undocumented special-casing; the
configuration API is where the SDK gives item providers first-class support and is the
path most likely to surface Save Video / AirDrop correctly (the plan's main runtime
risk). The raw-`activityItems` form is rejected, not a fallback.

### Modify: `app/DanCam/DanCam/Info.plist`
Add alongside `NSLocalNetworkUsageDescription` (usage strings live in the file here,
not as `INFOPLIST_KEY_*`):
```xml
<key>NSPhotoLibraryAddUsageDescription</key>
<string>Save dashcam clips to your photo library.</string>
```

### New: `app/docs/design/15-2026-07-01-clip-export-share.md`
ADR (Title / Status: Accepted / Context / Decision / Consequences / Alternatives).
Record: single system share sheet over the cached MP4 via an `NSItemProvider` with
`suggestedName`; the `clipExportFilename` time-honesty rule (keyed on
`timeApproximate`/`startMs`, auto-upgrades at `moss`); the add-only Photos key;
`sourceItem` anchor; a purged-cache share tap that self-heals by re-pulling (consistent
with ADR 13's "tolerate a missing cached file" recovery); same behavior for all clips.
Alternatives considered and rejected/deferred: a dependency-injected `ClipShareItem`
seam that hardlinks/copies the cache MP4 to a friendly-named temp file (rejected --
`NSItemProvider.suggestedName` gives the friendly name with no app-managed temp
lifecycle, cleanup race, or copy fallback); a dedicated one-tap Save-to-Photos button;
auto-saving incident clips (deferred to `nova`); list context-menu / swipe share for
uncached clips (deferred); anchoring with `barButtonItem` (use `sourceItem`, the
current unified API); passing the `NSItemProvider` raw in `activityItems: [Any]`
(rejected -- relies on undocumented handling; `UIActivityItemsConfiguration` is the
first-class item-provider API).

### Modify: `app/AGENTS.md`
Add ADR 15 to the "Design decisions (ADRs)" index list, one line in the same style as
the existing entries (currently ending at `14-2026-07-01-structured-logging-and-export.md`):
`15-2026-07-01-clip-export-share.md` -- system share sheet over the cached MP4. Every
prior ADR is registered in this list, so a new ADR that is not adds an unindexed record.

### Modify: `docs/roadmap.md`
Change swoop `tide` from `- [ ]` to `- [x]`; note Save-to-Photos + AirDrop + Files
delivered, and that auto-save-incidents is deferred to `nova`.

## Tests (Swift Testing; match existing patterns)

- **`app/DanCam/DanCamTests/Support/FormattersTests.swift`** (table-driven, exact
  strings): date-stamp when `startMs` set and `timeApproximate == false` (fixed
  `timeZone`, exact string); fallback when `timeApproximate == true`; fallback when
  `startMs == nil`; id > 99999 not truncated.
- **`app/DanCam/DanCamTests/Features/ClipViewer/ClipViewerViewControllerTests.swift`**
  (no `makeController` change -- there is no injected dependency):
  - Button state: disabled while pulling (reuse `gatedPullClient`), enabled when
    playing (cache-hit path), disabled on failure.
  - Provider construction: `makeShareItemProviderForTesting()` returns nil before
    playing (no `currentItemURL`, no crash); on the cache-hit playing path (reuse the
    same setup as the button-enabled test, with a real on-disk cache file) it returns a
    non-nil provider whose `suggestedName == Formatters.clipExportFilename(clip)` and
    whose `registeredTypeIdentifiers` contain a movie type (a `public.movie`-conforming
    id such as `public.mpeg-4`, from the `.mp4` source URL).
  - Purged source (guards the file-existence check **and** the self-heal): reach
    `.playing` with `currentItemURL` pointing at a **missing** file (cache double whose
    `lookup` returns a nonexistent `.mp4` URL) and a `gatedPullClient` so a re-pull parks
    in `.pulling`. Assert (a) `makeShareItemProviderForTesting()` returns nil -- the
    regression test for the guard, since `NSItemProvider(contentsOf:)` alone returns a
    non-nil provider for a missing path; and (b) `shareTappedForTesting()` self-heals
    rather than going inert -- the viewer enters `.pulling` (share button disables / a
    pull is requested), proving the tap re-pulls a purged cache instead of dead-clicking.
    Assert (b) synchronously right after the tap: the KVO cache-hit self-heal would also
    `startPull()`, but it runs on a later `@MainActor` hop, and `startPull()` restarts
    idempotently, so the tap's own transition is what the assertion observes.
  - Test invariant: never drive a unit test into the `present` branch -- there is no
    window under `loadViewIfNeeded()`, so presenting a real `UIActivityViewController`
    would fail. `makeShareItemProviderForTesting()` is always safe (it builds the
    provider without presenting). `shareTappedForTesting()` is safe **only** on
    guard-miss paths, where `makeShareItemProvider()` returns nil and no sheet is
    constructed (as in the purged-source test above); do not call it on a happy path
    where a provider exists, since `shareTapped` would then reach `present`.
- **Removed:** the `ClipShareItemTests.swift` suite the first draft proposed -- there
  is no seam to test. The provider's copy-at-share-time is system behavior, not ours.

## Verification

1. `just app-test` -- all `DanCamTests` pass, including the button-state and
   provider-construction tests.
2. `just app-build` -- compiles for the simulator.
3. `just adr-check` -- ADR 15 passes format/sequence validation (14 is now taken by the
   structured-logging ADR).
4. Manual (simulator + device) -- **load-bearing**, since `suggestedName` / activity
   behavior can only be confirmed at runtime:
   a. Open a clip, wait for "Ready" (playing) -> the share button enables; during the
      pull it is disabled.
   b. Tap it: the sheet shows **Save Video**, **AirDrop**, and **Save to Files**
      (confirms the provider's movie type surfaces the movie activities).
   c. Tap **Save Video** -> first-run Photos add permission prompt -> clip lands in
      Photos and plays (confirms the Info.plist key and that the file-backed provider
      satisfies the Save-to-Photos activity -- the main pivot risk).
   d. AirDrop / Save to Files show the friendly `Dashcam seg_NNNNN.mp4` name with a
      single `.mp4` extension. (If the extension is doubled, drop `.mp4` from
      `clipExportFilename` -- the inferred type identifier already implies it.)
   Device needed for AirDrop and the real Photos save.

Recovery note: if (c) fails (Save Video absent or the save errors) with the provider,
the fallback is to share a plain file URL pointing at a friendly-named copy of the
cache MP4 (the most battle-tested Save-to-Photos path) -- still inline in the VC, no
DI seam. Prefer the provider; fall back only if verification demands it.

## Out of scope (deferred, with triggers)

- Auto-save incident/locked clips -> revisit at swoop `nova`.
- Share from the clip **list** (context menu / swipe) with pull-then-share for uncached
  clips -> later deepening pass.
- Real timestamped filenames land automatically when swoop `moss` sets trustworthy
  `startMs` (no code change needed here).
- Trim-before-share, batch/multi-select export, cloud share-link -> parked (icebox).
