# Plan: on-device MPEG-TS -> MP4 remux for clip playback

## Context

Scrubbing a pulled clip in `ClipViewerViewController` freezes. Root cause: the clip is
a single MPEG-TS segment, and the app plays it by wrapping it in a **single-segment HLS
VOD playlist** served from a loopback HTTP server (`Networking/Loopback/`). HLS seeks at
segment granularity, so a one-segment playlist exposes exactly one seek anchor (time 0);
MPEG-TS carries no time->byte index, so every scrub forces a reload/redecode from the
start. The declared duration is also a placeholder (`clip.durMs ?? 30_000`), which makes
the scrub bar's time->position math wrong. Together: the player buffers indefinitely =
freeze.

TS is the *recording* container purely for crash-safety (truncation tolerance on abrupt
car power loss -- see `raspi/docs/design/01-2026-06-22-crash-safe-recording.md`). That
constraint applies only while the Pi is writing. A pulled clip is a finished, closed file
on the phone -- nothing left to corrupt -- so the phone is free to represent it however it
likes for viewing.

**Decision:** after the pull completes, remux the `.ts` into a local `.mp4` (passthrough /
stream-copy, no re-encode) and hand that `file://` URL straight to `AVPlayer`. MP4's `moov`
sample table is the time->byte index TS lacks, so AVPlayer scrubs natively and exactly.
Delete the loopback HLS stack entirely. The same `.mp4` is what a future "Save to Photos"
button (roadmap swoop `tide`) needs, so the remux is built once and serves both playback
and export.

This promotes MP4 remux from "export-only, spike-gated" (its status in ADR 02 today) to
the playback path, and retires loopback HLS -- a real decision change recorded as a new
ADR.

### Remux engine: built-in passthrough export first, hand-rolled demuxer only as fallback

The earlier draft of this plan assumed AVFoundation cannot read a `.ts` file at all and
committed to a hand-rolled TS/H.264 demuxer + `AVAssetWriter`. That premise is now in
doubt and must be tested before we build anything:

- The codebase's stated reason for the loopback server is narrower than "AVFoundation
  can't read TS": ADR 02 says *AVPlayer requires HLS over http(s), not `file://`* -- a
  claim about **AVPlayer playback of a playlist**, not about whether the **export/read
  pipeline** can demux a `.ts`. The crash-safe ADR's "iOS plays TS through HLS, not as a
  standalone file" is an assumption that was never empirically tested against
  `AVAssetExportSession`.
- A reviewer spike opened `raspi/service/assets/clips/seg_00000.ts` with `AVURLAsset` and
  exported it to a playable MP4 via `AVAssetExportSession` passthrough. (Platform of that
  spike is unstated -- see the caveat below.)
- SDK check (iPhoneOS 26.5): `AVAssetExportPresetPassthrough` and the modern async
  `export(to:as:)` are available on iOS; the deprecated `exportAsynchronously` is replaced by
  `export(to:as:)` / `states(updateInterval:)`. Note `export(to:as:)` does NOT itself honor Task
  cancellation -- it needs an explicit `withTaskCancellationHandler` -> `cancelExport()` bridge
  (see the Step 0 mechanism and the live-engine Cancellation requirement).

So the **primary path is the built-in `AVAssetExportSession` passthrough remux**, which (if
it works on-target) deletes the entire hand-rolled parser/writer surface (PAT/PMT, PES,
PTS/DTS, Annex-B->AVCC, sync-sample attachments, CoreMedia memory ownership) and lets the
SDK own the muxing, including correct `stss`/`ctts` for scrubbing.

**Critical caveat -- the gate must run on a physical iPhone, not just macOS/simulator.**
iOS has historically had narrower container support than macOS, and the simulator shares
much of the Mac media stack. A green result on macOS or the simulator is **necessary but
not sufficient**. The hand-rolled demuxer (fully specified in the Fallback appendix below)
is retained only as the contingency if the on-device gate fails.

> Decision-conflict to surface: an earlier `AskUserQuestion` chose "hand-rolled Swift"
> for the demuxer. That choice was made under the now-questioned premise that AVFoundation
> cannot read `.ts` at all. The gate below settles the premise empirically; if the built-in
> export passthrough is green on device, it supersedes the hand-rolled choice (strictly
> less code/risk). Confirm with the user when the gate result is in.

## Recording facts (ground truth)

From `raspi/camera/camera.py`: `H264Encoder(bitrate=10_000_000, repeat=True, iperiod=30)`
+ `FfmpegOutput(audio=False)`, MPEG-TS. So: **H.264 video only, NO audio, single video PID,
inline SPS/PPS repeated at every IDR (`repeat=True`), keyframe every 30 frames, ~30 s /
~38 MB segments.** Probing the repo fixture `raspi/service/assets/clips/seg_00000.ts`
confirmed **B-frames are present** (`has_b_frames=2`, real IBBBP order, PES in decode order
with `DTS < PTS`) -- relevant to the fallback engine (it must carry DTS through) and a good
stressor for the built-in export gate too.

## Step 0 -- the gate (decides the whole engine)

Before building anything, validate the built-in passthrough export on the real targets.

**Mechanism (primary path):**
```swift
let asset = AVURLAsset(url: tsURL)
// observe: asset.load(.isPlayable), asset.loadTracks(withMediaType: .video)
let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
// confirm session != nil and session.supportedFileTypes contains .mp4
// export(to:as:) does NOT honor Task cancellation on its own -- bridge it explicitly:
try await withTaskCancellationHandler {
    try await session.export(to: mp4URL, as: .mp4)        // async (NOT cancellation-aware)
} onCancel: {
    session.cancelExport()                                // single-fire guarded -- see Cancellation
}
```

**Run the gate on BOTH:** (a) the iOS Simulator (iPhone 17, iOS 26.5, via `just app-test`)
and (b) a physical iPhone. With BOTH the tracked fixture `seg_00000.ts` AND a real Pi
capture (`seg_*.ts` pulled off the Pi -- real Broadcom encoder SPS/PPS placement, B-pyramid
depth, `-reset_timestamps` timeline; the ffmpeg fixture is only an approximation).

**Assert (on the produced `mp4URL` via `AVURLAsset`):**
1. `try await asset.load(.isPlayable) == true`; exactly one video track; duration within
   0.5 s of the source.
2. The export was genuinely passthrough (no re-encode): it completed under the passthrough
   preset (which FAILS rather than transcodes on incompatibility) and the output track is
   H.264. Do NOT gate on wall-clock time -- log elapsed as a gate observation (not a pass/fail
   assertion). A timing threshold like "sub-second" can falsely reject a valid export on a
   loaded device, and the tracked fixture is ~1 MB, not a 38 MB real segment, so absolute
   numbers are not comparable anyway. Engine choice is from the functional checks (export
   succeeded, file type `.mp4`, sync metadata correct, decode works), never from speed.
3. **Sync-sample correctness (real scrubbing metadata, not just frame extraction).** Seed the
   walk at the track's actual first sample with
   `AVAssetTrack.makeSampleCursorAtFirstSampleInDecodeOrder()` (iOS 16+; guard `nil` -- the asset
   may not vend cursors; if so, fall back to assertion 4 only and note it). Do NOT seed at
   `makeSampleCursor(presentationTimeStamp: .zero)`: probing the tracked fixture shows its
   presentation timeline starts at PTS 1.466667 s, not 0 (min PTS overall == min PTS keyframe;
   decode-order frame 0 is the IDR at 1.4667 s), so a `.zero` seed lands before the first sample
   and asserting "(t=0)" would false-fail -- and since this assertion also runs in the automated
   `ClipRemuxerTests` happy path, that false-fail would block `just app-test`, not just the manual
   gate. **Discover the sync structure by walking the cursor -- do NOT hard-code timestamps.** The
   recorded GOP is every 30 frames, but the fixture's frame rate / GOP phase is not guaranteed to
   land a keyframe on any particular boundary, so fixed times would falsely fail. Step the cursor
   forward across the track, collecting per sample its presentation time,
   `currentSampleSyncInfo.sampleIsFullSync`, and the dependency pair
   `currentSampleDependencyInfo.sampleIndicatesWhetherItDependsOnOthers` +
   `.sampleDependsOnOthers`, then assert on the discovered set:
   - the first sample in decode order is full-sync (it is the IDR -- assert on decode-order
     position, NOT an absolute timestamp);
   - the full-sync set is non-empty and recurs (more than one keyframe across the ~30 s clip --
     the `stss` table is genuinely populated, not just sample 0);
   - at least one sample is NOT full-sync and reports dependency info that is BOTH valid AND
     dependent: `sampleIndicatesWhetherItDependsOnOthers == true` AND `sampleDependsOnOthers
     == true`. The validity flag matters -- `sampleDependsOnOthers` is only meaningful when
     `sampleIndicatesWhetherItDependsOnOthers` is true; reading the value alone would be
     semantically loose and could falsely fail on an asset that does not vend dependency
     detail. (Non-keyframes being correctly marked dependent is what a single-segment HLS
     playlist lacked.)
   Assert the structure, never specific timestamps -- this stays correct across frame rate,
   GOP phase, and B-pyramid depth.
4. A zero-tolerance `AVAssetImageGenerator` (`requestedTimeToleranceBefore/After = .zero`)
   returns a decodable frame at the track's temporal midpoint derived from the asset/track's
   reported `timeRange` (`start + duration/2`), NOT a hard-coded 15 s -- the imported timeline may
   be rebased or carry an edit list reflecting the 1.4667 s start. (Proves decodable random
   access; assertion 3 proves the metadata is right. Keep both.)
5. **(Manual device gate only) Real cancellation behavior.** Start a passthrough export of a real
   ~38 MB segment and cancel the surrounding Task mid-flight (through the
   `withTaskCancellationHandler` bridge). Make the verdict unambiguous by defining the observable:
   log a timestamp at the cancel and at the `await`'s return, and require ALL THREE of -- (a) the
   `await` THROWS (a `CancellationError` / export error, NOT normal completion); (b) it returns
   within a small bound of the cancel (pick a concrete ceiling well under the export's own run
   time, e.g. one second, when running the gate); (c) no partial `.mp4` is left on disk. This
   separates the three outcomes cleanly: a fast throw within the bound = green; a crash = red; the
   export ignoring `cancelExport()` and running to completion, or hanging past the bound = red --
   so a tester cannot misread "still going" as "working." This is the only check that the primary
   engine's `cancelExport()` actually works on-device; it is not deterministically unit-testable
   with the sub-second fixture export, so it lives here, not in `ClipRemuxerTests`.

**Decision:** if the gate is green on the physical iPhone, implement the live remuxer with
`AVAssetExportSession` passthrough and DO NOT build the hand-rolled engine. If the gate
fails on device (asset not playable / export fails / re-encodes / sync metadata wrong),
fall back to the hand-rolled engine in the appendix. Either way the `ClipRemuxer` seam,
viewer rewiring, loopback deletion, lifecycle, and docs below are unchanged.

**Gate artifact (sequencing).** Step 0 is the FIRST code written, before any `ClipRemuxer`
engine exists. Add a tiny gate test `DanCamTests/Media/ClipRemuxerGateTests.swift` (a scratch
harness is fine) that calls `AVAssetExportSession` passthrough (through the explicit
`withTaskCancellationHandler` -> `cancelExport()` bridge) INLINE (not via `ClipRemuxer`, which
isn't built yet) plus the four inline assertions (1-4) against the fixture, and run it under
`just app-test` (simulator) and a manual build to a connected iPhone (where assertion 5, the
real cancel observation, is checked). Once the gate settles
the engine, this file is kept and renamed/folded into the final
`DanCamTests/Media/ClipRemuxerTests.swift` (now calling `ClipRemuxer.live`); if the gate fails
on device, it stays as the documented red result while the fallback engine is built. This
removes the earlier ambiguity where Step 0 referenced `ClipRemuxerTests` before the
implementation sequence created it.

> Optional observation during the gate (possible future simplification, not this change):
> note whether `AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(tsURL)))` plays AND
> seeks the `.ts` directly on device. If it does, playback could skip remux entirely and
> remux only for Save-to-Photos. We still plan "remux -> play mp4" because the mp4 is
> needed for export regardless and is known-seekable; record the observation for `lime`/`tide`.

## Architecture

### Dependency seam (unchanged across both engine choices)

`ClipRemuxer` as a struct-of-`@Sendable`-closures, matching `ClipPullClient` / `ClipsClient`:

```swift
nonisolated struct ClipRemuxer: Sendable {
    // tsURL: a closed .ts in temp. Writes a passthrough .mp4 to mp4URL. No re-encode.
    // Observes Task cancellation (stops work and throws). Temp-file hygiene -- deleting the
    // .ts and any partial .mp4 -- is the caller's orchestration wrapper, NOT this closure,
    // so it is uniform across engines and testable without the real (un-cancellably-fast) export.
    var remux: @Sendable (_ tsURL: URL, _ mp4URL: URL) async throws -> Void
    static let live = ClipRemuxer { ts, mp4 in try await remuxPassthrough(ts, to: mp4) }
    static let noop = ClipRemuxer { _, _ in }
}

// Explicitly OFF the main actor. The app target sets SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
// and SWIFT_APPROACHABLE_CONCURRENCY = YES (-> NonisolatedNonsendingByDefault / SE-0461), under
// which a plain `nonisolated async` function RUNS ON THE CALLER'S ACTOR. The viewer awaits from
// the main actor, so without `@concurrent` the export (and the fallback's parse/write loop)
// would execute on main. `@concurrent` hops to the generic executor while STAYING in the
// structured-concurrency tree -- so the viewer's `pullTask.cancel()` still propagates into it.
@concurrent func remuxPassthrough(_ tsURL: URL, to mp4URL: URL) async throws { /* ... */ }
```

Wire into `App/AppDependencies.swift#AppDependencies` exactly like the other clients:
struct field `var remux: ClipRemuxer` (next to `clipPull`); test `init(...)` gains
`remux: ClipRemuxer = .noop` + `self.remux = remux` (keeps the test init total so every
existing reducer suite compiles unchanged); production `init(configuration:)` sets
`remux = .live`. Source under `app/DanCam/DanCam/Media/ClipRemuxer.swift`.

### Primary `live` implementation (gate green)

A thin wrapper over `AVAssetExportSession` passthrough as shown in Step 0. Requirements:
- **Off-main, explicitly.** Do NOT rely on `async` to leave the main actor -- under this
  target's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + `SWIFT_APPROACHABLE_CONCURRENCY = YES`
  (SE-0461), a `nonisolated async` function runs on the caller's actor, which is main. Mark the
  engine entry point `@concurrent` (as in the seam sketch above) so it hops to the generic
  executor. Prefer `@concurrent` over the codebase's `Task.detached` idiom (`ClipPullClient` /
  `PreviewClient`) here specifically because `@concurrent` keeps the function inside structured
  concurrency, so the viewer's `pullTask.cancel()` still propagates into the remux -- a detached
  task would sever that and force a manual cancellation wire. Both the built-in export and the
  fallback parse/write path go through this `@concurrent` entry point.
- **Cancellation (explicit bridge -- `export(to:as:)` does NOT honor Task cancellation):**
  contrary to an earlier assumption, `export(to:as:)` does not stop when its surrounding Task is
  cancelled -- it runs to completion (wasted work + delayed cleanup), with reports of a crash on
  cancel on some devices. Wrap it the SAME way the Fallback appendix wraps its writer:
  `withTaskCancellationHandler { try await session.export(...) } onCancel: { session.cancelExport() }`.
  Guard it: `onCancel` can fire more than once and can race normal completion, so use a single-fire
  flag so `cancelExport()` and the success path cannot double-act. (The `@concurrent` entry point
  delivers the viewer's `pullTask.cancel()` into this structured task; the handler is what turns
  that into `cancelExport()`.) The live closure does NOT delete files -- partial cleanup stays in
  the orchestration wrapper, uniform across engines. This bridge is NOT deterministically
  unit-testable with the sub-second fixture export, so its real stop-on-cancel behavior is a manual
  device-gate observation (Step 0 assertion 5), not a `ClipRemuxerTests` case.
- Map failure to a typed `ClipRemuxError` (export failed / not exportable / unsupported file
  type), carrying `session.error` where present.

### Partial-cleanup orchestration wrapper (testable seam)

A small async helper owns ALL temp hygiene around any `ClipRemuxer`, so cleanup is one
codepath regardless of engine and is deterministically testable:
- `defer`-delete the input `.ts` on EVERY exit (success, throw, or cancel);
- on throw/cancel, delete the partial `.mp4` at `mp4URL` before rethrowing;
- **after the remux returns, do a final `try Task.checkCancellation()` BEFORE returning
  success**; if it throws, treat it exactly like a cancel -- delete the now-COMPLETE `.mp4`
  (and the `.ts`) and rethrow. This covers the ordering where the export finishes right as
  cancellation lands -- possibly AFTER the viewer's `tearDown` already ran -- so the wrapper, not
  the viewer, deletes the just-written `.mp4` that would otherwise be orphaned;
- on success (the final check passed, no cancellation pending), leave the `.mp4` in place for the
  viewer.

**Why this is enough (no layer-2 apparatus).** The viewer assigns BOTH `self.tsURL` and
`self.mp4URL` UP FRONT -- before awaiting the remux -- because it derives both paths
deterministically (it swaps `.ts`->`.mp4` itself). So `tearDown` ALWAYS knows both paths and
deletes both unconditionally (`try? removeItem`, a no-op on a missing file), regardless of when a
dismissal lands relative to the remux. That dissolves the earlier "resume-hop" race entirely:
there is no window where a complete `.mp4` exists whose path the viewer does not already hold, so
no caller-side "take ownership / relinquish" recheck is needed. The wrapper's final check above is
still required for the one ordering it uniquely covers (export completes AFTER `tearDown` already
ran -- the wrapper deletes the just-written file). The viewer's only post-await job is a single
`try Task.checkCancellation()` guarding the `AVPlayer` build, so a dismissed viewer never proceeds
to playback.

`ClipViewerViewController` calls this wrapper, never `remux` directly. Because the cleanup
guarantee lives here (not inside the fast live export), the deterministic cancellation/cleanup
tests (below) drive this wrapper with an injected `ClipRemuxer` double and verify the guarantee
against OUR code rather than the un-cancellably-fast real export. (The wrapper owns "delete `.ts`
on any exit, delete partial `.mp4` on failure, delete the complete `.mp4` if cancelled at its
final check"; `tearDown` is the backstop that deletes both known paths -- see File lifecycle.)

### ClipViewerViewController rewiring

`Features/ClipViewer/ClipViewerViewController.swift`. The existing flow already does
pull -> `Task.checkCancellation()` -> `startPlayback(from:)`. Rewrite `startPlayback` to
remux first, then play a local MP4:

- **Remove:** the `server: LoopbackHLSServer?` property; the `durationSeconds` /
  `clip.durMs ?? 30_000` placeholder; the `LoopbackHLSServer` construction, `server.start()`,
  and `AVPlayer(url: baseURL.appending(path: "index.m3u8"))`; the `await server.stop()` block
  in `tearDown()` (teardown becomes fully synchronous -- better for `isolated deinit`).
- **Add:** `private var tsURL: URL?` and `private var mp4URL: URL?`, both assigned UP FRONT -- as
  the FIRST statements of the `.completed` case body, synchronously on the main actor the instant
  the event arrives, before the post-loop `try Task.checkCancellation()` and before awaiting the
  remux -- so `tearDown` always knows both paths to delete and the viewer owns both temp files from
  that point on. This ordering is load-bearing: `ClipPullClient.producePull` sets
  `shouldKeepOutput = true` (committing to keep the `.ts`; its own `catch is CancellationError`
  then will NOT delete it) immediately BEFORE it yields `.completed`, so claiming the path in the
  same synchronous step that receives the event leaves no cancellation checkpoint between the
  producer relinquishing the `.ts` and the viewer taking ownership.
- **New flow:** show `statusLabel.text = "Preparing video"`; in the `.completed` case body, as its
  FIRST statements, assign `self.tsURL` from the completed pull, derive the `.mp4` path by swapping
  the extension (`tsURL.deletingPathExtension().appendingPathExtension("mp4")`, preserving the
  `clip-<id>-<uuid>` prefix), sweep stale `clip-<id>-*.mp4`, and assign `self.mp4URL` -- ALL
  synchronously, before the post-loop `try Task.checkCancellation()` and before the await, so
  `tearDown` knows both paths no matter when a dismissal lands. Then call the
  partial-cleanup orchestration wrapper around `dependencies.remux.remux(tsURL, mp4URL)` (unlabeled
  args -- the closure is declared `(_ tsURL: URL, _ mp4URL: URL)`, matching the house idiom
  `dependencies.clipPull.pull(clip.id, clip.etag)`; it is `@concurrent`, so the actual remux runs
  off main while the viewer stays responsive). The wrapper deletes the `.ts` on EVERY exit, the
  partial `.mp4` on throw/cancel, and does its final cancellation check. After the await, the
  viewer's ONLY job is a single `try Task.checkCancellation()` guarding playback -- if it throws
  (dismissed mid-remux), bail without building the player (teardown already owns deletion of both
  known paths). Otherwise: `AVPlayer(url: mp4URL)`; attach the existing `AVPlayerViewController`
  unchanged; `play()`.
- **Cancellation + cleanup:** `pullTask?.cancel()` in `tearDown()` cancels the task awaiting the
  remux; the live remuxer's explicit `withTaskCancellationHandler` bridge calls `cancelExport()`
  (see Primary `live` implementation), and the orchestration wrapper deletes the `.ts` and any
  partial `.mp4`. `tearDown()` then deletes BOTH known paths unconditionally -- `try? removeItem`
  on `self.tsURL` and `self.mp4URL` (no-op on a missing file) -- which also reclaims the retained
  success `.mp4` once the player is torn down. (A future save/export flow is the one case that
  would guard the `.mp4` delete; there is none in this change, so teardown deletes it
  unconditionally -- that guard is the seam `tide`'s Save button will hook.) Net: a viewer session
  leaves no temp `.ts` or `.mp4` behind whether it completes or is dismissed mid-remux -- modulo
  the one irreducible boundary residual documented under File lifecycle (a `.completed` buffered
  but dropped on a cancelled stream before the viewer's loop delivers it, so the path is never
  learned; the next same-clip pull's sweep reaps it). Teardown
  stays synchronous (`try?` removeItem, no `await`) -- good for `isolated deinit`. The cleanup is
  covered by deterministic tests (below), not by inspection.

`ClipViewerViewController` is the ONLY caller of the loopback stack (verified).

### File lifecycle

Both files live in `FileManager.default.temporaryDirectory`, and the viewer OWNS both temp
URLs once the pull reaches `.completed` -- it is responsible for deleting both.
- Input `.ts` (`clip-<id>-<uuid>.ts`, produced by `ClipPullClient`): ownership transfers to
  the viewer at `.completed`. `ClipPullClient.producePull` sets `shouldKeepOutput = true`
  (committing to keep the `.ts`; its own `catch is CancellationError` then will NOT delete it)
  immediately BEFORE yielding `.completed`, so the viewer must claim the path the moment it
  receives the event -- it assigns `self.tsURL` as the first statement of the `.completed` case
  body, before any later `try Task.checkCancellation()`, so no in-body checkpoint can fire between
  the producer relinquishing the file and the viewer claiming it. The viewer (via the orchestration
  wrapper) then deletes the `.ts` on **any** remux exit -- success, failure, OR cancellation -- not
  only on success. (Deleting only on success, as an earlier draft did, leaked the completed `.ts`
  whenever the remux threw or the viewer was dismissed mid-remux.)
  **One irreducible boundary residual:** if the `pullTask` is cancelled after the producer
  committed and yielded `.completed` but BEFORE the `for try await` loop delivers that buffered
  event -- the loop's top-of-iteration `try Task.checkCancellation()` throws first, so the
  `.completed` case body never runs and the viewer never learns the random-UUID path -- the
  committed `.ts` is orphaned. It is a bounded stale temp file (~38 MB), never a correctness or
  UX bug, and the next same-clip pull's `prepareOutputURL` `*.ts` sweep reaps it, exactly as it
  reaps crash-orphans.
- Output `.mp4` (`clip-<id>-<uuid>.mp4`): the viewer sweeps stale `clip-<id>-*.mp4` before
  writing (mirroring `ClipPullClient.prepareOutputURL`'s `*.ts` sweep -- symmetric, non-
  overlapping by extension), and retains it only for **the current viewer session** (it is the
  seekable file `AVPlayer` plays, and the future Save-to-Photos precondition). `tearDown`
  deletes the `.mp4` UNLESS an active save/export flow owns it -- there is no such flow in this
  change, so teardown deletes it unconditionally; the "unless owned" guard is the seam `tide`
  will hook. The pre-write sweep stays as a backstop for files orphaned by a crash (or by the
  buffered-`.completed` boundary residual noted above), but the steady-state path is deterministic
  teardown deletion, so a viewer session leaves no temp `.ts` or `.mp4` behind except that one
  bounded residual.
- This change does NOT implement replay-without-re-pull caching -- the viewer flow still
  always pulls on open. Real id+etag caching (reuse across sessions, size cap) is owned by
  `lime`'s "on-device clip store" roadmap item. The ADR/roadmap must not promise caching here.

## Tests (Swift Testing: `@Test` / `#expect` / `#require`)

Primary-path tests (gate green):
- `DanCamTests/Media/ClipRemuxerTests.swift`:
  - **happy path (live, real export):** `ClipRemuxer.live.remux(fixtureTS, tmpMp4)` (unlabeled
    args, matching the `(_ tsURL: URL, _ mp4URL: URL)` closure) then the Step 0 asset assertions
    (isPlayable, one video track, duration tolerance, the discovered `AVSampleCursor` sync-sample
    metadata assertion, and the zero-tolerance midpoint frame). No cancellation here -- the live
    export is too fast to cancel reliably, so cancelling it would race.
  - **cancellation + partial cleanup (deterministic, NOT live):** the live export is too fast
    to cancel reliably, so drive cancellation through the orchestration wrapper with an
    INJECTED `ClipRemuxer` test double whose closure writes a partial `.mp4` to `mp4URL`, SIGNALS
    the test (a continuation / `AsyncStream` handshake) that the partial is on disk and it has
    reached its suspension point, then suspends until cancelled (`withTaskCancellationHandler`)
    and throws. Start it in a `Task`, **await the "partial written + suspended" signal, THEN
    cancel** -- without the handshake the cancel can land before the partial is written, so the
    test would pass on `CancellationError` alone without ever proving partial cleanup. `#expect`
    `CancellationError`; assert the wrapper removed both the partial `.mp4` AND the `.ts`. This
    verifies OUR cleanup guarantee deterministically (the cleanup lives in the wrapper, not in
    the un-cancellably-fast real export).
  - **success-after-cancel handoff -- wrapper final check (deterministic):** the regression test
    for the wrapper's leak window ("remux succeeded, but dismissal was already pending at the
    wrapper's final check"). Inject a `ClipRemuxer` double that writes a COMPLETE `.mp4`, signals
    the test it is written, then awaits a "proceed" signal and returns success WITHOUT observing
    cancellation. The test awaits "written", cancels the surrounding `Task`, sends "proceed"; the
    double returns success into the wrapper, whose final `try Task.checkCancellation()` now fires
    on the cancelled task -- so it deletes the complete `.mp4` (and the `.ts`) and throws.
    `#expect` `CancellationError`; assert BOTH temp files are gone. (The two-way handshake makes
    it deterministic; a naive success-leaves-`.mp4` wrapper would leak the complete file here.)
  - **`.ts` cleanup-on-failure (deterministic):** inject a `ClipRemuxer` that throws
    immediately (no suspend, no partial); run the wrapper and assert the `.ts` is deleted even
    though the remux failed. Covers the "delete `.ts` on any exit" rule with a synchronous
    throw, so no timing race.
- Fixture: reuse `raspi/service/assets/clips/seg_00000.ts` via the existing
  `#filePath`-relative idiom (`PreviewClientTests` already reaches `raspi/service/assets/`
  this way). First confirm the fixture is single-video-track; else commit a trimmed
  single-track copy under `DanCamTests/Media/Fixtures/`.
- The Step 0 simulator run IS the happy-path test (seeded as `ClipRemuxerGateTests`, then
  folded into `ClipRemuxerTests` -- see Step 0 "Gate artifact"); the device run is manual
  (build to a connected iPhone, run the same target).

Do NOT unit-test `AVPlayer`/`AVPlayerViewController` UI or scrubbing UX (manual/on-device).
The `ClipRemuxer.noop` default keeps `AppDependencies`' test init total so existing suites
compile unchanged.

Fallback-path tests (only if the hand-rolled engine is built): the parse-layer unit tests
listed in the appendix.

## Docs / ADR / roadmap (same change, per the working stance)

- **New ADR** `app/docs/design/07-2026-06-26-on-device-clip-remux-playback.md` (Title /
  Status Accepted / Context / Decision / Consequences / Alternatives). Decision: replace
  loopback-HLS playback with an on-device passthrough `.ts`->`.mp4` remux played via
  `AVPlayer(url: mp4)`; **primary implementation is `AVAssetExportSession` passthrough**
  (gate-validated on device), with a hand-rolled TS demuxer as the documented fallback;
  delete the loopback stack; introduce `ClipRemuxer`. Note the playback fix is the real
  `moov`/`stss` index, and that this change does not add cross-session clip caching (left to
  `lime`'s clip store). Supersedes ONLY the "Clip playback / export" subsection of app ADR
  02 (ADR 02 stays Accepted; expressed via the dated note, not a Status flip). Alternatives:
  keep loopback HLS (not seekable); byte-range multi-segment HLS (still needs a TS parser,
  leaves the loopback server + a separate export remux); remux on the Pi (Pi stays dumb;
  `.ts` is the crash-safe format); hand-rolled demuxer as primary (more code/risk than the
  built-in export if the gate is green -- kept as fallback).
- **Dated note** at the top of `app/docs/design/02-2026-06-22-app-pi-transport-and-api.md`
  pointing to ADR 07: playback now remuxes the pulled `.ts` to a local `.mp4` (passthrough)
  and plays it directly; the loopback HLS server / playlist / range parser are deleted; the
  export-only framing of the remux is superseded. Transport/pull/auth content stands.
- **Dated note** at the top of `raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md`:
  app-side playback realization superseded by app ADR 07; the wire contract is UNCHANGED (Pi
  still serves raw `.ts` via `GET /v1/clips/{id}`, no `.m3u8`); the "AVPlayer never talks to
  the Pi" invariant holds (it reads a local file).
- **Dated note** at the top of `raspi/docs/design/01-2026-06-22-crash-safe-recording.md`:
  the Consequences phrase "iOS plays TS through HLS ... remux to MP4 only for export" is
  updated by app ADR 07 (phone now remuxes for BOTH playback and export); `.ts` recording
  format, segmentation, and crash-safety layers are UNCHANGED.
- **Roadmap** `docs/roadmap.md`: in swoop `lime`, replace the checked download-then-play
  `[x]` item (single-segment VOD `.m3u8` over the pulled `.ts`) with a remux-based playback
  item, and retarget the spike-first bullet's "plays via loopback HLS" to "remuxes to a
  playable, seekable `.mp4` (validated on a physical iPhone)". In swoop `tide`, note the
  TS->MP4 remux moved forward into `lime`, leaving `tide` as just the share UI
  (Save-to-Photos button + AirDrop) over the `.mp4` `lime` already produces.
- Plain ASCII throughout; reference stable anchors, not line numbers. Run `just adr-check`
  (07 is contiguous, date >= ADR 06) and `just app-test` green.

## Implementation sequence

0. **Gate (Step 0), FIRST code written.** Add `DanCamTests/Media/ClipRemuxerGateTests.swift`
   (inline `AVAssetExportSession` passthrough wrapped in the explicit cancellation bridge +
   inline assertions 1-4; assertion 5 is the manual device cancel observation; no `ClipRemuxer`
   yet) and run it on the simulator AND a physical iPhone, both fixtures. This decides the engine.
   Cheap; do it first.
1. **Engine + cleanup wrapper:**
   - Gate green -> implement `Media/ClipRemuxer.swift` `live` over `AVAssetExportSession`
     passthrough (cancellation via the explicit `withTaskCancellationHandler` -> `cancelExport()`
     bridge), plus the partial-cleanup orchestration wrapper (deletes the `.ts` on any exit, the
     partial `.mp4` on throw/cancel). (Small.)
   - Gate red on device -> build the hand-rolled engine from the Fallback appendix instead
     (same wrapper still owns cleanup).
2. **Service + wiring:** wire `var remux: ClipRemuxer` into `AppDependencies` (field,
   test-init `.noop`, production `.live`); fold `ClipRemuxerGateTests` into
   `DanCamTests/Media/ClipRemuxerTests.swift` (now calling `ClipRemuxer.live`) and add the three
   deterministic injected-driver cleanup tests (cancel+partial cleanup, success-after-cancel
   handoff at the wrapper's final check, `.ts` cleanup-on-failure).
3. **Rewire `ClipViewerViewController`:** pull -> "Preparing video" -> off-main remux via the
   cleanup wrapper -> `AVPlayer(url: mp4)`; drop `server` + loopback usage + `durMs`
   placeholder; assign `tsURL` + `mp4URL` UP FRONT (before the remux await); `tearDown` deletes
   both known paths; apply the file-lifecycle policy; the deterministic cleanup/cancellation
   tests pass.
4. **Delete the loopback stack:** `Networking/Loopback/{LoopbackHLSServer,HLSPlaylist,
   HTTPRangeRequest}.swift` + `DanCamTests/Networking/Loopback/{HLSPlaylistTests,
   HTTPRangeRequestTests}.swift` (folder-synced -> they vanish). One stray doc reference to fix in
   the same change: `Networking/HTTP/HTTPContentRange.swift` (kept -- `ClipPullClient` uses it)
   has a comment naming the loopback `HTTPRangeRequest` as its request/server-side counterpart;
   reword it to describe `HTTPContentRange` as the response-side `Content-Range` parser the
   resumable pull uses, with no mention of the deleted symbol. No other source refs to the
   loopback types (verified).
5. **Docs:** ADR 07 + the three dated notes + roadmap edits; `just adr-check` + `just app-test`.

Rationale: gate before engine (it picks the engine), engine before service (service wraps
it), service before rewire (rewire needs the dependency), rewire before delete (the build
never lacks a player path), docs land with the code.

## Verification

- `just app-test` green (the happy-path remux/seek test incl. the discovered sync-sample
  metadata assertion, plus the three deterministic injected-driver cleanup/cancellation tests).
- **Physical-iPhone gate green** (the necessary-and-sufficient proof that AVFoundation can
  read the real Pi `.ts` and produce a seekable mp4 on-target).
- `just adr-check` green.
- On device: open a clip in the viewer, confirm it plays, then **scrub** -- the bug is fixed
  when the scrubber lands at arbitrary positions and the frame updates (the behavior that
  froze before). Best confirmed on a real pulled Pi clip.

## Out of scope / future

The "Save to Photos" button is swoop `tide`, not this change. This plan only ensures its
precondition exists: a real on-disk `.mp4` file URL, retained on the view controller. When
it lands, add `NSPhotoLibraryAddUsageDescription` to `Info.plist` (do NOT add it now -- an
unused permission string is a review flag) and call
`PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: mp4URL)`.

---

## Appendix: hand-rolled TS demuxer (FALLBACK ONLY -- build only if the Step 0 device gate fails)

Pure-Swift TS demuxer feeding `AVAssetWriter` passthrough. AVFoundation has no public
"AVAssetReader over a `.ts`" guarantee, so this path hand-parses the container and feeds
compressed samples to `AVAssetWriter`. Only needed if the built-in export cannot read the
Pi's `.ts` on-device.

```
app/DanCam/DanCam/Media/Remux/
  TSDemuxer.swift               // Foundation-only: 188-byte packets -> PAT/PMT -> per-PID PES
  H264AccessUnitAssembler.swift // Foundation-only: PES header (PTS/DTS) + Annex-B NAL split
  DemuxedH264Clip.swift         // Foundation-only: AccessUnit / parameter-set value types
  ClipRemuxerEngine.swift       // AVFoundation: CoreMedia + AVAssetWriter passthrough
```

Pure parse layer imports only `Foundation` (unit-testable on bytes); index by integer
offsets over `Data(contentsOf:options:.mappedIfSafe)` + `withUnsafeBytes` -- never
`Data.range(of:)` in the per-packet/per-NAL hot loop (~202k packets). Follow the byte-parser
idiom in `Networking/Preview/MultipartMJPEGParser.swift`.

Key engine notes:
- **TS demux:** real PAT->PMT walk to resolve the video PID; select `stream_type 0x1B`
  (H.264); throw on `>1` video PID or non-H.264 (loud, not silent). Adaptation-field +
  continuity-counter handling; tolerate CC gaps (log, don't fail). PES reassembly PUSI-to-PUSI.
- **PES / timing:** parse `PTS_DTS_flags`; decode 33-bit 90 kHz timestamps with marker bits;
  PTS-only -> `dts = pts`; rebase both by `firstPES.dts` so the session starts at 0. One PES =
  one access unit (verified); AUD-boundary split behind a single `accessUnits(from:)` seam.
- **B-frames / DTS:** PES arrive in decode order = the order `AVAssetWriter` wants. Each
  sample carries both PTS and DTS; writer derives `ctts`/`stts`. Never collapse DTS to PTS.
- **The critical correctness detail:** `AVAssetWriter` passthrough does NOT find keyframes
  itself -- set `kCMSampleAttachmentKey_NotSync = true` on every non-keyframe sample so the
  `stss` table is correct. Omit it and there's no scrubbing (the same bug in MP4 form). The
  Step 0 `AVSampleCursor` sync-sample assertion catches this.
- **AVAssetWriter passthrough:** `CMVideoFormatDescriptionCreateFromH264ParameterSets` (first
  SPS/PPS, NALUnitHeaderLength 4); Annex-B -> AVCC (4-byte big-endian length prefix);
  `CMBlockBufferCreateWithMemoryBlock` owning memory via `kCFAllocatorMalloc` (no dangling
  `Data` pointer); `CMSampleBufferCreateReady` with `CMSampleTimingInfo`;
  `AVAssetWriterInput(mediaType:.video, outputSettings: nil, sourceFormatHint:)`,
  `expectsMediaDataInRealTime = false`, `startSession(atSourceTime: .zero)`, drive appends via
  `requestMediaDataWhenReady(on:)` honoring `isReadyForMoreMediaData`, bridge to async with a
  checked continuation resumed in `finishWriting`. `shouldOptimizeForNetworkUse = false`.
- **Cancellation (explicit bridge -- do NOT read `Task.isCancelled` in the append callback):**
  `requestMediaDataWhenReady(on:)` runs the append loop from a Dispatch callback OUTSIDE the
  awaiting Swift task, so `Task.isCancelled` / `Task.checkCancellation()` read there see the
  callback's (absent) task context -- they report `false` even after the viewer's task is
  cancelled, and the writer would run to completion after dismissal. Bridge cancellation
  explicitly instead: wrap the write in `withTaskCancellationHandler`; its `onCancel` closure
  sets a synchronized `isCancelled` flag (a lock-protected bool, e.g. `OSAllocatedUnfairLock`)
  and calls `writer.cancelWriting()`. The append callback reads that SHARED flag between samples
  (never `Task.isCancelled`) and, if set, stops appending and bails. Resume the checked
  continuation through a single-resume guard (a synchronized "already resumed" bool) so the
  cancel path and the normal `finishWriting` path cannot double-resume; the cancel path resumes
  by throwing `CancellationError`. (The `@concurrent` entry point is what delivers the viewer's
  `pullTask.cancel()` to THIS task; `withTaskCancellationHandler` is what carries it from the
  task into the Dispatch callback -- the two compose, neither alone is enough.) The engine does
  NOT delete files -- partial `.mp4` and `.ts` cleanup stays the shared orchestration wrapper's
  job (same as the built-in engine). But note the wrapper's cleanup tests use injected doubles
  and do NOT exercise this bridge, so the real append loop's prompt-stop-on-cancel needs its own
  engine-level test (below); the file-hygiene guarantee around it is still the wrapper's.
- **Robustness:** drop a truncated final access unit and succeed; `.missingParameterSets` if
  the first IDR has no SPS/PPS; write to a temp `mp4URL` (the wrapper deletes the partial on
  any throw). Typed `ClipRemuxError` (Equatable), mirroring `ClipPullError`.
- **Performance:** map the file; integer parse is low-single-digit ms; passthrough write
  dominated by ~900 `append` calls; runs on the shared `@concurrent` entry point (off main),
  not via `Task.detached` (keeps cancellation propagation). Expect well under 1 s, but timing
  is not a gate -- see Step 0.

Fallback tests: `DanCamTests/Media/Remux/TSDemuxerTests.swift` (PAT/PMT, single-PID,
multi/unsupported throws, PES reassembly on crafted bytes) and
`H264AccessUnitAssemblerTests.swift` (PTS/DTS decode incl. PTS-only, rebasing, NAL split,
`isKeyframe`, access-unit count/order, >=1 AU with `pts != dts`), plus the same end-to-end
`ClipRemuxerTests` assertions. Plus a **fallback-engine cancellation test**
(`ClipRemuxerEngineTests.swift`) that exercises the explicit bridge the wrapper's injected-double
tests cannot reach: structure the engine's append loop behind a small driver seam -- a
`nextSample()` source, an `append(_:) -> Bool` sink, and the shared `isCancelled` flag -- so a
test can substitute a fake sink that drives appends step by step and cancel the surrounding task
mid-stream. Assert the loop reads the SHARED flag (not `Task.isCancelled`), stops PROMPTLY after
the in-flight sample rather than at end-of-stream, calls `cancelWriting()`, throws
`CancellationError`, and did NOT append all ~900 samples. (This driver seam is a design
requirement of the fallback engine, not test-only scaffolding: it is what makes the cancellation
bridge verifiable without a real `AVAssetWriter` callback.)

## Implementation notes

- `AVAssetExportSession` passthrough did not pass the gate: after bundling
  `seg_00000.ts` into `DanCamTests.xctest`, `AVURLAsset` still failed on the iOS 26.5
  simulator with `AVFoundationErrorDomain -11828` / "This media format is not
  supported" for `assetProperty_Tracks`. The implementation therefore uses the fallback
  Swift TS/H.264 demuxer feeding `AVAssetWriter`.
- The TS fixture is committed under `app/DanCam/DanCamTests/Media/Fixtures/` and
  explicitly copied as a test resource because physical iPhone tests cannot read the
  Mac source path behind `#filePath`.
- The fallback engine uses a synchronous `AVAssetWriterInput.append` loop inside an
  explicitly cancellable detached worker instead of `requestMediaDataWhenReady(on:)`.
  This keeps the writer off the main actor while propagating parent cancellation into
  the worker task; viewer tests cover TS/MP4 cleanup on failure, success, and
  cancellation-after-remux handoff.
- The remuxer seam owns MP4 output selection as `remux(sourceURL, clipID) ->
  ClipRemuxResult` instead of taking a caller-supplied output URL. That keeps stale MP4
  sweeping and partial-output cleanup with the live remuxer, while
  `ClipViewerViewController` tracks both returned temp files for session teardown.
- The MP4 writer sets both `kCMSampleAttachmentKey_NotSync` and
  `kCMSampleAttachmentKey_DependsOnOthers`; the live remux test now walks an
  `AVSampleCursor` to verify recurring sync samples and dependent non-key samples.

## Follow Up

- Run the remaining `lime` real-Pi spike with a current pulled ~38 MB `seg_*.ts`: time
  the pull over `dancam-dev`, open it in the viewer on a physical iPhone, and scrub the
  remuxed MP4 manually. The committed tests verify the bundled fixture on the simulator
  and on `Pelucho`, but they do not replace the real-Pi pull/scrub check.
