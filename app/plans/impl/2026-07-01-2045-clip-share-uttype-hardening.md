# Plan: correct the benign clip-share log-line claim, then harden the UTType via UIActivityItemSource

## Context

Two follow-ups fall out of the on-device verification of the clip-share fix
(commit `af5d612`; promoted plan
`app/plans/impl/2026-07-01-1845-clip-share-device-hang.md`; ADR
`app/docs/design/15-2026-07-01-clip-export-share.md`). Both docs currently
describe the *fixed* build in ways the device evidence contradicts.

1. **The log-line diagnosis was wrong.** Both the impl plan and ADR 15 call
   `error fetching item for URL ... (null)` "the load-bearing failure" / "the
   real signal." But that exact line still prints on the *fixed* build while
   sharing works end to end (friendly `Dashcam seg_00027.mp4` name, QuickLook
   thumbnail, and real AirDrop / Files / Photos transfers were all observed on
   device). So the line is benign noise -- same bucket as the `CKShare/SWY` and
   file-provider-domain lines -- not evidence of the hang. Left uncorrected, the
   docs send the next reader chasing a share bug down a dead end. The actual
   diagnosis never had a clean distinguishing log signal; it rests on the
   differential (classic `activityItems:` path works, `activityItemsConfiguration:`
   + lazy provider path hangs) and on device behavior.

2. **Adopt the pre-designated UTType hardening.** The impl plan listed, as a
   recovery escalation "only if device verification demands it," wrapping the
   file URL in "a minimal `UIActivityItemSource` that returns the URL and
   declares the movie UTType via `dataTypeIdentifierForActivityType`." Device
   verification did *not* demand it -- the plain `.mp4` file URL already surfaces
   Save Video / AirDrop / Files. We adopt it anyway as belt-and-suspenders:
   declaring the UTType explicitly means the sheet no longer relies solely on the
   system inferring the type from the `.mp4` extension. Deliberately minimal --
   **no `LPLinkMetadata`** -- so the share sheet keeps its auto-generated
   QuickLook preview header (the video-frame thumbnail already seen on device)
   exactly as-is.

Non-goals: the ~5s first-tap share-sheet delay (QuickLook / daemon cold start,
outside our control, accepted as-is), a custom preview thumbnail, and a custom
sheet header / title (all would require `LPLinkMetadata`, explicitly out of
scope here).

This plan ships as **two commits**. Commit 1 is a standalone doc correction of
the mis-diagnosis; it leaves both docs internally consistent with what `af5d612`
actually shipped (no item source). Commit 2 adds the item-source code and the
doc edits that must match the new code.

## Commit 1: `docs(app): correct the benign clip-share log-line claim`

Prose only. Reclassify `error fetching item for URL ... (null)` from
"load-bearing signal" to benign noise in both docs. Do **not** touch the
item-source-related prose (ADR "Corrected mechanism", impl-plan Out-of-scope
bullet) -- those describe Commit 2's change and land with it. Quote the current
snippets so each edit is unambiguous.

### Modify: `app/plans/impl/2026-07-01-1845-clip-share-device-hang.md`

- Under `## Symptoms`, the **Load-bearing (the actual failure)** bullet: remove
  the `error fetching item for URL:...clip-26-....mp4 : (null)` sub-bullet
  ("appears twice. This is the sharing framework asking the item provider ...")
  from this bucket. The load-bearing symptom that remains is the behavioral one:
  "The share sheet is presented but stuck on 'Preparing' and swallows
  interaction."
- Move that `(null)` line into the **Benign noise (do NOT cite as evidence ...)**
  bucket, with a note that it also prints on the fixed build (observed on device
  while sharing worked end to end), so it does not distinguish the failure.
- Under `## Root cause`, in the sentence "On device, the
  `UIActivityViewController(activityItemsConfiguration:)` + lazy-provider path
  fails to vend the local file to the sheet -- that is exactly the
  `error fetching item for URL ... (null)` signal -- so the sheet never finishes
  preparing." remove the em-dash clause "-- that is exactly the
  `error fetching item for URL ... (null)` signal --". Add a short honest note
  that the failure had no clean distinguishing log line (the `(null)` line prints
  on the working build too); the diagnosis rests on the differential control plus
  device behavior, which the acceptance gate covers.
- Under `## Files and changes` -> the `### Amend:` ADR bullet: in the parenthetical
  "the load-bearing root cause (the ... path fails to vend the local file --
  `error fetching item for URL ... (null)` -- while the app run loop stays alive
  ...)" drop the `-- error fetching item for URL ... (null) --` citation and fold
  that line in with "the `CKShare/SWY` and file-provider-domain log lines are
  benign for local shares."
- Under `## Re-verification checklist`, the bullet "Confirm the log classification
  above: `error fetching item ... (null)` is the real signal; ... are benign for
  local shares." reword so `error fetching item ... (null)` joins the benign list
  and nothing is called "the real signal" -- state there is no clean distinguishing
  log signal; behavior is the signal.

Leave the two "load-bearing manual device step" references (Verification step 4
header and the `## Root cause` "only the load-bearing manual device step could"
sentence) untouched -- they are about the *step*, not the log line, and are
correct.

### Modify: `app/docs/design/15-2026-07-01-clip-export-share.md`

- In `## Correction 2026-07-01 (device-verified)`, the **Load-bearing root
  cause.** paragraph: remove the em-dash clause "-- the signal is
  `error fetching item for URL:...clip-....mp4 : (null)` in the device log --" so
  the sentence reads that on device the configuration + lazy-provider combination
  fails to produce a usable sheet, full stop. Then in the following sentence that
  lists the benign lines ("The `Only support loading options for CKShare and SWY
  types.` and `error fetching file provider domain for URL:... : (null)` log lines
  are benign ..."), add `error fetching item for URL ... : (null)` to that benign
  list and note these print for ordinary local shares that work, including the
  fixed build, so none is evidence of the failure.

Do **not** touch the **Corrected mechanism.** paragraph in this commit. The core
decision and Status line are unchanged; `just adr-check` still passes (amended in
place, not renumbered).

### Verification (Commit 1)

- Doc-only; no `just app-test` (nothing behavioral changed).
- `just adr-check` -- ADR 15 still passes format / sequence validation.

## Commit 2: `refactor(app): declare clip-share movie UTType via UIActivityItemSource`

Add the item source, its test, and the doc edits that must match the new code.

### Modify: `app/DanCam/DanCam/Features/ClipViewer/ClipViewerViewController.swift`

Add the import alongside the existing `AVKit` / `OSLog` / `UIKit`:

```swift
import UniformTypeIdentifiers
```

Add a small file-scope wrapper (internal, so the test can reach it via
`@testable import DanCam`). It returns the file URL for the placeholder and the
item, and declares the type from the file extension. It intentionally does *not*
implement `activityViewControllerLinkMetadata`, so the sheet keeps its
auto-generated QuickLook preview (no `LPLinkMetadata`). Place it at file scope
below the `ClipViewerViewController` class:

```swift
/// Wraps a clip's file URL for the share sheet so the movie UTType is declared
/// explicitly rather than inferred from the `.mp4` extension alone. Intentionally
/// omits `activityViewControllerLinkMetadata`: the sheet keeps its auto-generated
/// QuickLook preview header (no `LPLinkMetadata`).
@MainActor
final class ClipShareItemSource: NSObject, UIActivityItemSource {
    private let url: URL
    private let typeIdentifier: String

    init(url: URL) {
        self.url = url
        self.typeIdentifier = UTType(filenameExtension: url.pathExtension)?.identifier
            ?? UTType.mpeg4Movie.identifier
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        typeIdentifier
    }
}
```

The class is `@MainActor` to match the enclosing view controller and the test
suite; it holds only immutable `let`s, so the annotation adds no real isolation
cost. (`just app-build` in verification is the check that the `@objc`
`UIActivityItemSource` witnesses compile clean under strict concurrency.)

In `ClipViewerViewController.swift#shareTapped`, wrap the artifact URL in the
item source. The only change is the `activityItems` argument; the popover anchor
and the `completionWithItemsHandler` temp-dir cleanup keyed off
`artifact.temporaryDirectory` stay exactly as they are:

```swift
let activityViewController = UIActivityViewController(
    activityItems: [ClipShareItemSource(url: artifact.url)],
    applicationActivities: nil
)
```

Nothing else in the share path changes: `makeShareArtifact()`,
`shareArtifactDirectories`, the last-resort fallback, and `tearDown()` cleanup
are untouched. The exported file is still the friendly-named APFS clone; this
only hardens how its type is declared to the sheet.

### Modify: `app/DanCam/DanCamTests/Features/ClipViewer/ClipViewerViewControllerTests.swift`

Add one focused, structure-insensitive test for the wrapper. It needs no window
or `present` path (the documented no-`present` test invariant is preserved) --
it drives the `UIActivityItemSource` methods directly. Reuse the existing
`temporaryFile(extension:contents:)` helper; `UIKit` and `UniformTypeIdentifiers`
are already imported in this file.

```swift
@Test
func clipShareItemSourceDeclaresMovieTypeAndVendsTheURL() throws {
    let url = try temporaryFile(extension: "mp4", contents: Data([0x00]))
    defer { try? FileManager.default.removeItem(at: url) }

    let source = ClipShareItemSource(url: url)
    let host = UIActivityViewController(activityItems: [url], applicationActivities: nil)

    #expect(source.activityViewControllerPlaceholderItem(host) as? URL == url)
    #expect(source.activityViewController(host, itemForActivityType: nil) as? URL == url)

    let identifier = source.activityViewController(host, dataTypeIdentifierForActivityType: nil)
    #expect(UTType(identifier)?.conforms(to: .movie) == true)
}
```

This asserts the observable contract -- placeholder and item are the shared URL,
and the declared type conforms to `public.movie` -- without pinning the exact
identifier string, so it survives a `.mp4` -> other-movie-extension change. It is
the regression guard that the type declaration is not silently dropped.

No other test changes: the existing artifact / fallback / teardown / self-heal
tests already cover the share pipeline and are unaffected by wrapping the URL.

### Modify: `app/docs/design/15-2026-07-01-clip-export-share.md`

In the **Corrected mechanism.** paragraph, change the tail "The `.mp4` extension
gives the system the `public.movie`-conforming UTType, so Save Video, AirDrop,
and Save to Files are all offered without a `UIActivityItemSource`." to say the
file URL is wrapped in a minimal `UIActivityItemSource` that declares the movie
UTType explicitly (belt-and-suspenders over extension inference), and that it
intentionally omits `LPLinkMetadata` so the sheet retains its auto-generated
QuickLook preview header.

### Modify: `app/plans/impl/2026-07-01-1845-clip-share-device-hang.md`

Under `## Out of scope (deferred)`, the bullet "`UIActivityItemSource` with
explicit type / `LPLinkMetadata` -- only if device verification demands it
(recovery escalation above)." append a one-line forward pointer: the explicit-type
half was adopted proactively as hardening in a follow-up (see ADR 15 "Corrected
mechanism"); `LPLinkMetadata` remains out of scope. This keeps the historical
record honest without rewriting what `af5d612` actually shipped.

### Verification (Commit 2)

1. `just app-test` -- all `DanCamTests` pass, including the new
   `clipShareItemSourceDeclaresMovieTypeAndVendsTheURL`. The new test is
   behavioral and structure-insensitive and needs no window, honoring the suite's
   no-`present` invariant.
2. `just app-build` -- compiles for the simulator (confirms the `@MainActor`
   `UIActivityItemSource` conformance is clean under strict concurrency).
3. `just adr-check` -- ADR 15 still passes.
4. **Manual on a physical device** (the item source is a device-surface change;
   run from Xcode so the `dancam.local` camera host env var is set):
   a. Open a clip, wait for "Ready", tap Share -> the sheet still appears and is
      usable, still offering **Save Video**, **AirDrop**, and **Save to Files**
      (the explicit UTType must not have narrowed the activity list).
   b. The sheet header still shows the **video-frame thumbnail** and the friendly
      `Dashcam seg_NNNNN.mp4` name -- confirming the QuickLook preview is retained
      (no `LPLinkMetadata` regression).
   c. Complete one real **Save to Files** (or AirDrop) transfer -> the saved file
      opens and plays, confirming the item still vends the real bytes.

## Out of scope

- `LPLinkMetadata` / custom sheet header / custom preview thumbnail -- keeping the
  auto QuickLook header is the explicit choice here.
- `subjectForActivityType` / other optional `UIActivityItemSource` niceties.
- The ~5s first-tap delay (QuickLook / daemon cold start; accepted as-is).

## Commit progress
- [x] 1. docs(app): correct the benign clip-share log-line claim
- [ ] 2. refactor(app): declare clip-share movie UTType via UIActivityItemSource
