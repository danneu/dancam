# Plan: local clip-file failures are terminal, not crashing/retried

## Context

Code-review finding A-01 (`video-review.xegWVJ/01-pull-transport.md`) flagged that
`ClipPullClient.writeDecodedChunks` appends each decoded body chunk with the
unlabeled `fileHandle.write(decodedChunk)`. That binds to the **deprecated
non-throwing** `FileHandle.write(_:)`, which reports a write error (disk full,
I/O error, revoked sandbox) by raising an Objective-C `NSException` -- not a Swift
`Error`. On a clip-hoarding phone hitting `ENOSPC` mid-pull, that exception bypasses
every Swift `do/catch` in `producePull`, so the app **SIGABRTs**, leaking the open
`FileHandle` and the partial temp file.

Verification (`/verify-issue`) confirmed the crash and surfaced two things that
turn this from a one-liner into a small, coherent pivot:

1. **The finding's proposed bare one-liner is not enough.** A plain
   `try fileHandle.write(contentsOf:)` throws a `CocoaError`/`NSError`, which in
   `runAttempt`'s catch ladder falls through to the **bare `catch` -> `.retry`**
   (it is not `CancellationError`/`HTTPResponseHeadError`/`HTTPBodyDecodingError`/
   `ClipPullError`). So a disk-full would be mis-treated as a rideable transport
   drop: ~6 pointless reconnects to the Pi over the congested 2.4 GHz link, ending
   as a misleading `exhausted(.consecutiveStalls)` ("repeated reconnects without
   progress") -- not the clean `.file` error the finding wanted.
2. **Same root cause hits two more sites.** The `truncate(atOffset:)` /
   `seek(toOffset:)` on the validator-change `200` restart path already use the
   throwing API, but their errors funnel into that **same bare `.retry`** catch and
   end as the same misleading exhaustion. All three are *local temp-file* failures
   that reconnecting can never fix.

**Intended outcome:** any failure to write/truncate/seek/close the local temp file
ends the pull as a terminal `ClipPullError.file` -- no crash, no leaked handle, no
pointless reconnect storm, and a partial-temp-file cleanup that actually runs. The
finalizing `close()` is included deliberately: `close(2)` can surface a deferred
write/storage error the individual writes did not, so a clip must not report
`.completed` if its final close failed. Plus a deprecation-cleanup sweep of the
remaining `FileHandle.closeFile()` calls on the already-failing / teardown paths.

## Decisions (locked with the user)

- **Fix scope: every local file op.** Map `write` + `truncate` + `seek` + the
  finalizing `close` failures to terminal `ClipPullError.file` via one small helper
  -- consistent "a local file failure ends the pull" semantics, including the close
  that can report a deferred write error.
- **Test rigor: no new seam.** There is no existing seam to force a local file
  failure (the output `FileHandle` is created internally; only `openByteStream`/
  `sleep` are injectable). Adding one would thread a closure/abstraction through
  `live -> producePull -> runAttempt -> writeDecodedChunks` purely for a rare path.
  Instead, **document the invariant** in the helper's doc comment. The terminal
  rethrow path is already exercised by existing `ClipPullError` tests (e.g.
  `malformedResponse`), and the deprecated `write(_:)` emits a **compiler warning**
  that guards against silently regressing the call.

## Change 1 -- correctness fix (`fix(app)`)

All in `app/DanCam/DanCam/Networking/Clips/ClipPullClient.swift`.

**a. Add one private helper** that maps any local file-op failure to terminal
`.file`, documenting the invariant:

```swift
/// Run a local temp-file operation, mapping any failure to a terminal
/// `ClipPullError.file`. A write/truncate/seek/close failure (disk full, I/O
/// error, revoked sandbox -- close can surface a deferred write error) is NOT a
/// transport drop -- reconnecting and resuming cannot fix local storage -- so it
/// must end the pull, not re-enter the resume loop.
/// Routing it through `.file` lands it in `runAttempt`'s terminal `ClipPullError`
/// catch instead of the bare `.retry` catch that rides out network drops.
private static func mappingLocalFileErrors<T>(
    _ context: String, _ body: () throws -> T
) throws -> T {
    do { return try body() }
    catch { throw ClipPullError.file("\(context): \(error.localizedDescription)") }
}
```

**b. Body write** in `writeDecodedChunks` -- replace the deprecated non-throwing
call with the throwing API inside the helper:

```swift
try mappingLocalFileErrors("write clip body") {
    try fileHandle.write(contentsOf: decodedChunk)
}
```

**c. Restart truncate/seek** in `prepareBodyDecoder` `case 200:` -- wrap the existing
throwing calls so their failure is terminal `.file` instead of bare `.retry`:

```swift
try mappingLocalFileErrors("reset clip file for restart") {
    try fileHandle.truncate(atOffset: 0)
    try fileHandle.seek(toOffset: 0)
}
```

**d. Generalize `ClipPullError.file`'s user-facing text** (its `LocalizedError`
case) from `"Could not prepare clip file: ..."` to cover write failures too, e.g.
`"Could not save clip file: \(message)"`. No test asserts this string; existing
`.file` throws in `prepareOutputURL` ("Missing output URL.", "Could not create ...")
still read correctly.

**e. Finalize close on the success path** -- the `close` after the attempt loop is the
last local file op, and `close(2)` can report a deferred write/storage error. Make it
terminal too: clear the stored handle first (so the `catch` cleanup never double-closes),
run the throwing `close()` through the helper, and mark the output kept only after a
clean close -- so a close failure deletes the partial file like any other terminal
local-file failure. This replaces the success-path `outputHandle.closeFile()`:

```swift
fileHandle = nil
try mappingLocalFileErrors("close clip file") { try outputHandle.close() }
shouldKeepOutput = true
```

**Why this lands terminally (no new code needed downstream):** a `ClipPullError.file`
thrown from the write/truncate/seek sites propagates out of the `for try await` loop /
`prepareBodyDecoder` into `runAttempt`'s `catch let error as ClipPullError { throw error }`
(terminal), then into `producePull`'s `catch let error as ClipPullError`. The finalize
close throws directly inside `producePull`'s own `do` block (after the loop), so it lands
in that same `catch` straight away. Either way `producePull` calls
`continuation.finish(throwing:)` and runs the cleanup (close handle via `try?` -- a no-op
once the handle is nil'd, delete the partial temp file since `shouldKeepOutput` is still
`false`). This reuses the exact path `malformedResponse` already takes.

## Change 2 -- deprecation cleanup (`refactor(app)`)

Replace the remaining `FileHandle.closeFile()` calls -- the ones on **already-failing
or teardown paths** (the success-path finalize close is handled terminally in Change 1)
-- with the throwing `close()`, swallowed with `try?`:

- `ClipPullClient.swift`: the three `catch` blocks (`CancellationError`, `ClipPullError`,
  generic) -> `try? fileHandle?.close()`.
- `ProgressiveSegmenter.swift`: the `cancel()` and `fail(_:)` teardown paths -> `try?
  fileHandle?.close()`.

`try?` is correct here for path-specific reasons, not a blanket "close can't fail": the
`ClipPullClient` `catch` blocks are already tearing down a failed/cancelled pull, so a
close error is moot and must not mask the real error passed to `finish(throwing:)`;
`ProgressiveSegmenter` holds a **read** handle (no buffered writes, so close cannot
surface a write/storage error) and both sites are teardown that must not mask the error
they report. All run in **non-throwing** contexts. This removes the last
NSException-raising FileHandle API and is behavior-preserving on every path the tests
exercise (these closes succeed).

## ADR update (in Change 1's commit)

Amend `app/docs/design/12-2026-06-30-bounded-resilient-clip-pull.md`: its Decision
section lays out the retry-vs-terminal taxonomy but never classifies local file-op
failures (the write was an uncatchable crash; truncate/seek were unconsidered). Add
one bullet to that taxonomy: *a local temp-file failure (write/truncate/seek, or the
finalizing close that can report a deferred write error -- disk full, I/O error, revoked
sandbox) is terminal `ClipPullError.file`, never a retry, because reconnecting cannot fix
local storage.* This is an additive clarification of
a previously-uncovered case, recorded in the same change per the repo's "a pivot that
isn't written down is the next trap" rule -- not a reversal, so no supersede.

No README change: app-only, no Pi provisioning/onboard-state impact.

## Critical files

- `app/DanCam/DanCam/Networking/Clips/ClipPullClient.swift` -- helper; four
  helper-wrapped local-file ops (`writeDecodedChunks` write, `prepareBodyDecoder`
  `case 200:` truncate/seek, success-path finalize close); `.file` text; the three
  `catch`-block `closeFile()` sites (cleanup sweep).
- `app/DanCam/DanCam/Media/Stream/ProgressiveSegmenter.swift` -- two `closeFile()`
  sites (`cancel`, `fail`).
- `app/docs/design/12-2026-06-30-bounded-resilient-clip-pull.md` -- taxonomy bullet.

## Commit plan

1. `fix(app): make clip-pull local file failures terminal` -- Change 1 (helper +
   write/truncate/seek + finalize close) + ADR update.
2. `refactor(app): replace deprecated FileHandle.closeFile() with throwing close()`
   -- Change 2 (the teardown/cleanup closes only).

## Verification

- **Build is the primary guard.** `just` build the app target (or
  `xcodebuild`/Xcode). Confirm it compiles with **zero deprecation warnings** for
  `FileHandle.write(_:)` / `closeFile()` -- their absence is the regression signal,
  since both are deprecated and would warn if reintroduced.
- **Run the existing suite** (`ClipPullClientTests`, `ProgressiveSegmenter`/clip
  tests). All 16 `ClipPullClientTests` must still pass unchanged: the success paths
  (write, validator-change truncate/seek, and the finalize close -- which succeeds in
  tests, so `.completed` is emitted exactly as before) are unaffected, and the
  `restartsAndTracksTheNewValidatorWhenItChanges` /
  `restartedPrecedesPostTruncationProgress...` cases prove truncate/seek still work
  on the happy restart path. No new test is added (per the locked decision).
- **Inspection check of the funnel:** confirm by reading that a `ClipPullError.file`
  thrown from the helper reaches `runAttempt`'s `catch let error as ClipPullError`
  (terminal) and `producePull`'s `.file` cleanup -- the same path the existing
  `malformedResponse` tests already cover end to end.
- **Optional manual smoke (not required):** the disk-full path is the rare condition
  this fixes; it is impractical to simulate on-device without a seam (intentionally
  out of scope), and the behavior is type-guaranteed by the funnel above.

## Out of scope

- No injectable file-writer seam / `FileHandle` abstraction (the explicit
  no-new-seam decision).
- A-02..A-07 from the same review lane (separate findings).
- Cross-launch temp-file cleanup (A-06; ADR 12 already scopes it out).

## Commit progress
- [x] 1. fix(app): make clip-pull local file failures terminal
- [ ] 2. refactor(app): replace deprecated FileHandle.closeFile() with throwing close()
