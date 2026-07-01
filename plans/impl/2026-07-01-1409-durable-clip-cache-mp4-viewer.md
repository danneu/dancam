# Plan: durable on-device clip cache; remux-to-MP4 as the sole playback path

## Context

Clip playback today runs two paths layered together (ADR 07 + ADR 08): a
progressive fMP4 pipeline (incremental demux -> streaming H.264 assembly ->
`AVAssetWriter` HLS segments -> a viewer-scoped loopback HTTP server) that paints
an early frame while the `.ts` pulls, and a whole-file remux-to-MP4 finalizer that
the viewer swaps to on completion. The progressive path also carries a fallback
state machine for when it fails.

We measured the finalizer's remux at **~50 ms** for a 30 s clip -- iOS 26.5 simulator,
fast-start on; on-device timing not yet confirmed (see Verification) -- not the ~9 s
ADR 08 feared (that 9 s was the **pull**, not the remux). That kills the reason the
progressive pipeline exists: it does not shorten the pull, it only paints frame 0 a
second early, and time-to-first-frame is bounded by the pull either way. Meanwhile
the finalized MP4 is thrown away per-viewer, so every re-open re-pulls and re-remuxes.

This change deletes the progressive/HLS pipeline entirely and makes pull -> remux ->
play the only path, backed by a **durable clip cache** so re-opens are instant and the
cached fast-start MP4 becomes the export artifact for swoop `tide`. Outcome: less code
(a whole media-serving subsystem and a loopback HTTP server disappear), instant replay,
and a bounded on-disk cache.

## Decisions locked (from brainstorm + review feedback)

- Cache home: **`Library/Caches/clips/`** (regenerable; the Pi SD is source of truth).
- Eviction: **mtime-LRU under a size budget** -- no persisted index; the directory is
  the index (`isCached` = file exists, size = file size, LRU = file `modificationDate`).
- Wait UX: **bare determinate progress bar**, then instant remux, then play. No poster,
  no progressive.
- Nav-away: **cancel the pull, drop the temp partial** (coordinator/viewer-lifetime, in
  `temporaryDirectory`; OS reaps it). In-session Retry re-pulls; the pull client's own
  ranged resume still covers transient drops within one attempt.
- On terminal pull failure: **error card + manual Retry** (Retry re-pulls; also a Back).
- **No "cached" badge** on the home list (opaque to the user; confirmed none exists today).

Two smaller calls made here (flagged for veto at approval):

- **Cache key = id + the resolved content etag of the pulled bytes**, encoded into the
  filename `clip-<id>-<etagToken>.mp4` (matches the roadmap's `lime` "pulled bytes named
  by id+etag"). The remux is a deterministic passthrough, so keying the remuxed MP4 by
  its source TS's entity tag is sound. This fixes a real staleness bug: Pi segment ids
  (`seg_00000`...) can be reused after an SD reformat / fresh Pi, and an id-only key would
  serve the old card's video on a cache hit.
  - **`insert` keys by the etag the bytes actually carry, not the pre-pull list etag.**
    A pull can hit a mid-transfer `200` (validator changed), truncate, and rewrite a
    different representation (`ClipPullClient#prepareBodyDecoder`, the `case 200` restart);
    it then finishes holding bytes whose validator != `clip.etag`. So the pull surfaces
    its final on-disk validator (see the `ClipPullResult` change in Changes-by-area 6) and
    `insert` keys by *that*.
  - **`lookup` keys by `clip.etag`** (the list value) as a pre-pull guess. When the two
    diverge (a changed clip), the stale-list lookup safely misses and re-pulls -- it never
    serves bytes under an etag they do not contain. Once the list row refreshes to the new
    etag, `lookup` hits the already-cached MP4.
  - **The two arrive in different wire-quotings of the same validator, so `etagToken`
    canonicalizes before encoding.** `clip.etag` is the raw unquoted `{seq}-{bytes}`, but
    `result.resolvedETag` is the Pi's **quoted** `ETag` (`ClipPullClient` inits `resumeETag`
    as `httpEntityTag(listETag)` = `"\(raw)"` and later copies the quoted `etag` header;
    `HTTPContentRange.swift#httpEntityTag`). A straight encode of each would hash `0-12345`
    (lookup) and `"0-12345"` (insert) to *different* filenames -- a miss on **every**
    happy-path re-open, silently defeating instant replay. So `etagToken` strips a leading
    `W/` and surrounding double quotes first, then encodes the inner value; both spellings
    of one validator collapse to a single token, while a genuinely different validator
    (`"0-99999"`) still diverges (preserving the miss-on-change semantics above).
- **Orchestration stays in the (simplified) `ClipViewerViewController`**, not a new
  extracted coordinator type -- matching today's shape and the existing VC test seams.
  `ClipCache` is the only new type.

## Architecture

New dependency seam `ClipCache`, mirroring `clipRemuxer` in `AppDependencies`
(struct of `@Sendable` closures, `.live` / `.noop`). Flow:

```
open clip
  hit:  clipCache.lookup(id, clip.etag) -> URL   -> play (touch mtime)
  miss: clipPull.pull(id, clip.etag) [progress]  -> clipRemuxer.remux(ts) [~50ms]
        -> clipCache.insert(id, result.resolvedETag, mp4) -> delete pulled TS -> play cached URL
pull/remux failure (pull exhausted / remux throws): -> .failed -> Retry re-pulls
playback failure (AVPlayerItem .failed):
  cache-hit play  -> self-heal: startPull() once (a purged/bad cache file re-pulls silently)
  post-remux play -> .failed (re-pull would reproduce the same bytes; surface it, no loop)
nav-away: cancel pull/remux task, delete temp TS/MP4 (cache file in clips/ untouched)
```

The remuxer keeps writing its MP4 to `temporaryDirectory` (unchanged;
`ClipRemuxerTests` stays green); `clipCache.insert` **moves** it into `clips/` (same
volume -> rename). That is the commit point -- nothing enters `clips/` until a clean
remux.

## Changes by area (stable anchors, not line numbers)

### 1. New `ClipCache` -- `app/DanCam/DanCam/Media/ClipCache.swift`

`nonisolated struct ClipCache` (struct-of-closures like `ClipRemuxer`):

**Directory contract:** `rootDirectory` **is** the clips directory itself (the live wiring
passes `<Caches>/clips`), never its parent. Every cache file, the per-id sweep, the
eviction scan, and the `.v<N>` sentinel live *directly* under `rootDirectory` -- the type
never nests a second `clips/` segment inside the root it is handed. Tests pass a bare temp
dir as `rootDirectory` and assert artifacts appear directly under it.

- `var lookup: @Sendable (_ clipID: Int, _ etag: String) -> URL?` -- computes
  `<rootDirectory>/clip-<clipID>-<etagToken>.mp4`; if it exists, stamp `modificationDate = now()`
  and return it; else `nil`. Called with `clip.etag` (the list value). A file iOS purged
  mid-session simply does not exist -> `nil` -> miss (no index to disagree).
- `var insert: @Sendable (_ clipID: Int, _ etag: String, _ source: URL) throws -> URL` --
  ensure `rootDirectory` exists + version sentinel; sweep any existing `clip-<clipID>-*.mp4`
  (stale-etag versions of this id); **move** (not copy) the source MP4 to
  `<rootDirectory>/clip-<clipID>-<etagToken>.mp4` -- the source is consumed, and the move is the
  commit point; stamp `modificationDate = now()`; evict; return the final URL. Called with
  `result.resolvedETag` (the etag the pulled bytes actually carry), so a mid-pull
  representation change is cached under the correct validator (see Decisions locked).
- `static func live(rootDirectory: URL, now: @Sendable () -> Date, maxBytes: Int = 500 * 1024 * 1024) -> ClipCache`
  -- the injectable seams the tests need (root dir + clock + budget).
- `static let noop` -- `lookup` returns `nil` (always miss); `insert` returns the source
  URL unchanged (passthrough). Default for tests that do not exercise the cache.

Internals (private, exercised through `.live`):

- **etagToken:** one private `etagToken(_ etag: String) -> String` that **canonicalizes
  then encodes**, and BOTH `lookup` and `insert` route through it. Canonicalize first:
  strip a leading `W/` and any surrounding double quotes (so the unquoted list `clip.etag`
  and the quoted `resolvedETag` for the same validator produce one token -- see Decisions
  locked); then produce a stable, filesystem-safe encoding of the inner value --
  percent-encode to `[A-Za-z0-9]` (or CryptoKit SHA256 hex). MUST be stable across
  launches: do **not** use Swift's `Hasher`/`hashValue` (per-process randomized).
- **Eviction:** on `insert`, sum sizes of `clip-*.mp4` in `rootDirectory`; while over `maxBytes`,
  delete the oldest `modificationDate` file, **excluding the just-inserted path** (hard
  guarantee it is never the victim). A single clip larger than the budget is kept
  (temporary over-budget). Because `lookup` touches mtime on a hit, a just-replayed clip
  is freshest and survives; in v1 there is one active viewer and no prefetch, so the only
  file that can race an insert is the one being inserted -- hence the explicit exclusion
  is sufficient (revisit with an explicit pin-set if prefetch/multi-viewer lands).
- **Version wipe:** a `<rootDirectory>/.v<N>` sentinel; on first op, if the current sentinel
  is absent, delete everything in `rootDirectory` and write it. Bumping the source constant `N`
  wipes the cache on next launch (insurance for a remux-output format change).

### 2. `AppDependencies` -- `app/DanCam/DanCam/App/AppDependencies.swift`

- Remove the `progressiveSegmenter` property (memberwise param, default, and
  `init(configuration:)` wiring).
- Add `clipCache: ClipCache = .noop` (memberwise, default `.noop`), wired in
  `init(configuration:)` to `.live(rootDirectory: <Caches>/clips, now: Date.init)`.

### 3. `ClipViewerViewController` rewrite -- `app/DanCam/DanCam/Features/ClipViewer/ClipViewerViewController.swift`

- Delete the top-of-file `ProgressiveAvailability` enum.
- Replace `ViewerState` (9 cases + `FallbackPhase`/`FallbackReason`/`FinalizeSource`/
  `ReadyInfo`) with:
  ```
  enum ViewerState: Equatable {
      case pulling(PullProgress)     // determinate bar; expected seeded from clip.bytes
      case preparing                 // remux in flight; full bar + "Preparing" label (never a frozen bare bar)
      case playing(URL)              // cache hit OR post-remux
      case failed(message: String)   // error card + Retry
  }
  ```
  Keep `PullProgress { bytesWritten: UInt64; expected: UInt64? }`.
- `viewDidLoad`: `if let url = deps.clipCache.lookup(clip.id, clip.etag) { play(url, source: .cacheHit) }`
  (hit, no pull) `else { startPull() }`.
- `startPull()`: iterate `deps.clipPull.pull(clip.id, clip.etag)`; on `.progress` update
  `.pulling`; on `.completed(result)` -> `.preparing` ->
  `let mp4 = try await deps.clipRemuxer.remux(result.fileURL, clip.id)` ->
  `let cached = try deps.clipCache.insert(clip.id, result.resolvedETag, mp4.fileURL)` ->
  delete `result.fileURL` (the pulled TS) -> `play(cached, source: .freshRemux)`. Record the
  pulled TS and the remuxed MP4 URLs in VC state as each is produced, so both the failure
  path and `tearDown()` can reclaim them. **On any thrown error (remux OR insert), delete
  whichever temp artifacts exist -- the pulled TS and, if remux got that far, the remuxed
  MP4 -- before entering `.failed(error.localizedDescription)`.** This closes the
  `insert`-throw leak: the MP4 is remuxed into `temporaryDirectory` but not yet moved into
  the cache, so it is orphaned unless cleaned. (On the happy path the TS is deleted and the
  MP4 is *moved out* by `insert`, so the cleanup finds nothing left.)
- Add a **Retry** button (shown only in `.failed`) wired to `retry()` -> `startPull()`;
  keep a Back/dismiss affordance.
- **Keep the `AVPlayerItem.status`-`.failed` observation** (`observePlayerItem`) the
  current VC already has, but route it by playback provenance instead of the deleted
  `isProgressive` flag. Track how the current `.playing` was entered via
  `play(url, source: .cacheHit | .freshRemux)` (a VC property, mirroring today's
  `currentItemIsProgressive`):
    - `.cacheHit` item failure (a purged or unopenable `Library/Caches` file -- the ADR's
      purge-tolerant case) -> **self-heal: `startPull()` once**, silently, no error card.
      The subsequent play is `.freshRemux`, so this cannot loop.
    - `.freshRemux` item failure -> `.failed(message:)` (a re-pull would deterministically
      reproduce the same bytes, so surface it with Retry rather than loop).
  Note: today the non-progressive branch of `handlePlayerItemFailed` is a silent no-op
  (`guard isProgressive else { return }`), so a failed MP4 already strands the viewer --
  this closes that gap, not just the new cache-hit one.
- Delete `startSegmenter`/`handleSegmenterEvent`/`handleProgressiveFailure`/the swap and
  first-playable-suppression logic and the segmenter task.
- `tearDown()` (from `viewWillDisappear` + isolated `deinit`): cancel the pull/remux task
  and delete the same tracked temp TS/MP4 artifacts (the shared cleanup the failure path
  uses); the `clips/` cache file is not in temp, so it survives.

### 4. Deletions (whole files)

- `app/DanCam/DanCam/Media/Stream/` -- entire folder: `LoopbackMediaServer.swift`,
  `FMP4Segmenter.swift`, `ProgressiveSegmenter.swift`.
- Tests: `DanCamTests/Media/Stream/LoopbackMediaServerTests.swift`,
  `DanCamTests/Media/Stream/FMP4SegmenterTests.swift`,
  `DanCamTests/Media/ProgressivePlaybackIntegrationTests.swift`.

### 5. Deletions (in-file / prune)

- `app/DanCam/DanCam/Media/Remux/H264AccessUnitAssembler.swift`: delete the
  `StreamingH264AccessUnitAssembler` struct **only**; keep the batch
  `H264AccessUnitAssembler` enum and its shared statics.
- `DanCamTests/Media/Remux/H264AccessUnitAssemblerTests.swift`: drop the 6
  `streaming...`/`assemblersTruncateAndAgreeAtDTSWrap` cases; keep the 5 batch cases.
- `DanCamTests/Media/Remux/TSDemuxerTests.swift`: drop the `streamingAccessUnits`/
  `assertStreamingStaysMonotonic` helpers and their call sites; keep demux/incremental
  coverage.
- `DanCamTests/Features/ClipViewer/ClipViewerViewControllerTests.swift`: drop all
  progressive/first-playable/fallback cases, the `ProgressiveSegmenter` fakes, and the
  `ProgressiveAvailability.decide` tests; keep and adapt the remux-path cases. Update the
  `makeController(...)` factories: drop `progressiveSegmenter`, add `clipCache`.

Everything else under `Media/Remux/` and `Media/ClipRemuxer.swift` is untouched. Keep
`shouldOptimizeForNetworkUse = true` (fast start) and `ClipRemuxerTests`' layout
assertions as-is -- we are not touching the flag.

### 6. `ClipPullClient`: surface the resolved etag (small change)

`producePull` already tracks `resumeETag` -- the validator of the bytes on disk, which
after a mid-pull `case 200` restart is the *new* representation's etag, not the list
etag. Thread it out so the cache can key by it:

- Add `var resolvedETag: String` to `ClipPullResult`, populated from the final
  `resumeETag` when the pull completes (`producePull`'s `.completed` yield).
- Nothing else in `ClipPullClient` changes: retry-by-progress, ranged resume, and the
  `temporaryDirectory` TS write are untouched.

### 7. Kept, unchanged

`Clip` model, `HomeViewController` (no badge), `TSDemuxer`/`IncrementalTSDemuxer`/
`TransportStreamH264Parser`, batch `H264AccessUnitAssembler`, `H264CoreMediaSamples`,
`ClipRemuxer`/`ClipRemuxerEngine`. `ClipPullClient`'s pull loop, resume, and file
handling are unchanged apart from the `ClipPullResult.resolvedETag` field (Changes 6).

## ADR + docs (same change)

- **New `app/docs/design/13-2026-07-01-durable-clip-cache.md`** (next free seq is 13):
  Status Accepted. Decision = delete the progressive/HLS pipeline; pull -> remux -> play
  is the sole viewer path; add the `Library/Caches` mtime-LRU clip cache (keyed by
  `clipID` + the resolved content etag of the pulled bytes, version sentinel,
  purge-tolerant); the cached fast-start MP4 is the `tide` export source. Record the
  cache-key rule explicitly: `insert` keys by the etag the pulled bytes carry (surfaced as
  `ClipPullResult.resolvedETag`, the Pi's quoted `ETag`), `lookup` by the list `clip.etag`
  (raw, unquoted); a single `etagToken` canonicalizes the wire-quoting (strip `W/` +
  quotes) so the same validator hits regardless of spelling, and on a genuinely divergent
  validator lookup safely misses -- never serve bytes under an etag they do not contain.
  Record the
  playback-failure rule: the playing state observes `AVPlayerItem` failure -- a cache-hit
  failure self-heals by re-pulling once, a post-remux failure surfaces (no loop).
  **State the assumptions** (carried from ADR 07): H.264-only, video-only (no audio), one
  finished segment per clip -- a future HEVC/audio change touches this exact path and needs
  a new ADR. Note the **~50 ms remux is a simulator measurement** (iOS 26.5, fast-start
  on); on-device confirmation is follow-up, and the decision holds even at 1-2 s.
  Alternatives-considered: keep progressive (rejected -- the ~50 ms remux removes the
  motivation; it never shortened the pull); persisted index (rejected -- mtime-LRU
  self-reconciles); cross-open partial resume (rejected -- marginal on a 5-9 s pull for a
  second on-disk lifecycle); id-only key (rejected -- id reuse across cards);
  skip-cache-on-restart (rejected -- keying by the resolved etag caches the changed clip
  correctly and replays once the list refreshes).
- **Edit `app/docs/design/08-...progressive-fmp4-clip-playback.md`**: set Status to
  `Superseded by app/docs/design/13-2026-07-01-durable-clip-cache.md` (append-only; do not
  rewrite the body).
- **Edit `app/docs/design/07-...on-device-clip-remux-playback.md`**: **append-only** --
  leave the body and the existing 2026-06-27 note verbatim; add a NEW dated note
  (2026-07-01) that affirms + extends it: ADR 08 and its 2026-06-27 caveat are superseded
  by ADR 13, remux-to-MP4 is again the sole viewer path, and the durable cache supersedes
  the "remux is currently temporary per viewer" consequence. (Do not rewrite the body's
  now-stale lines; the note carries the correction, per the repo's append-only ADR rule.)
- **Edit `app/AGENTS.md`** (living catalog, not append-only -- edit in place): in the
  "Design decisions (ADRs)" list, add the ADR 13 entry, annotate the ADR 08 entry as
  `superseded by ADR 13` (matching how the ADR 04/05 entries are annotated), and correct
  the ADR 02 one-line descriptor -- it still lists "loopback-HLS playback" as an app
  obligation, but playback is now the local cached MP4 with no loopback server.
- **Append a 2026-07-01 note to `app/docs/design/02-...app-pi-transport-and-api.md`**
  (append-only; leave the body and the prior 2026-06-26/06-27/06-29 notes verbatim): ADR 13
  supersedes the 2026-06-27 note (progressive fMP4 over a loopback HLS server) and the
  "Clip playback and export" subsection's loopback mechanism -- app-side playback is again
  the local passthrough MP4 played with `AVPlayer(url:)`, and the loopback server is
  deleted. The Pi wire contract (raw `.ts` with `Range`), Wi-Fi pinning, pull, time sync,
  and incident content stand unchanged.
- **`plans/wip/plan-the-ideal-refactor-kind-starfish.md`**: obsolete (its whole premise was
  keeping the loopback player as the durable player). Remove it as part of this change.
- **`docs/roadmap.md`** (`lime` swoop): the on-device clip-store bullet is (partly)
  realized -- update its status/wording. No README / Pi changes (app-only); the **raspi**
  transport ADR needs no change (the pull wire contract is unchanged; loopback was app-side
  only). The **app-side** ADR 02 is not exempt, though -- it carries the playback-mechanism
  note handled by the AGENTS.md + ADR 02 steps above.

## Test plan (behavioral, structure-insensitive)

`ClipCache` unit tests -- `DanCamTests/Media/ClipCacheTests.swift`, via
`ClipCache.live(rootDirectory: <temp>, now: <controllable>, maxBytes: <tiny>)`:

- **insert then lookup** returns the file **directly under the passed `rootDirectory`**
  (no nested `clips/`), named by id+etag; a second `lookup` hits.
- **quoted-vs-unquoted spelling of one validator HITS** (the canonicalization regression
  test): `insert(id, "\"0-12345\"", src)` (the quoted `resolvedETag` form) then
  `lookup(id, "0-12345")` (the unquoted `clip.etag` form) must **hit** -- this is the guard
  that instant replay actually fires on the happy path. Use realistic quoted/unquoted forms
  on the two sides, not one identical string (an identical string passes regardless of the
  quoting bug).
- **genuinely different validator MISSES** (the F1 wrong-serve guard): `insert(id, etagB, src)`
  then `lookup(id, etagA)` (a different validator) misses -- a clip cached under its resolved
  etag is never returned for a stale, non-matching list etag.
- **insert consumes (moves) the source**: after `insert` returns, the source URL no longer
  exists on disk (guards against a copy-based regression that would leak the temp MP4).
- **eviction over a tiny budget**: inserting past the budget evicts oldest-mtime first,
  the just-inserted file always survives, and a single clip larger than the budget is
  kept.
- **touch-on-hit protects a replay**: insert A then B; `lookup(A)`; insert C over budget;
  B (older, untouched) is evicted before A.
- **reconcile / robustness**: a pre-placed stray `clip-*.mp4` is discovered and counted;
  a purged/missing file makes `lookup` return `nil`; a version-sentinel bump wipes
  `rootDirectory` on the next op.

`ClipViewerViewController` tests -- adapt the existing suite with fake `clipCache`/
`clipPull`/`clipRemuxer` and the existing VC hooks (`currentPlayerItemURL`, `statusText`,
`progressFraction`, temp-cleanup):

- **cache hit** plays the looked-up URL with **no pull-client call** (inject a pull that
  fails if invoked).
- **miss -> pull -> remux -> insert -> play**: `insert` is called with the remux output,
  the pulled TS is deleted, and the player opens the **insert-returned cached URL**. Seed
  the fake `ClipPullResult.resolvedETag` to a value **distinct from `clip.etag`** and assert
  the fake cache's `insert` receives `result.resolvedETag`, **not** `clip.etag` -- this pins
  the VC-boundary half of the stale-list fix: `ClipPullClient` surfacing the final validator
  and `ClipCache` keying correctly are both moot if the VC forwards the list etag into
  `insert`, caching changed bytes under a stale key. A same-valued etag on both sides would
  pass regardless of the bug (the `ClipCacheTests` canonicalization case proves a different
  thing -- the cache collapsing wire-quotings -- and does not cover this wiring).
- **remux throws -> `.failed`** (no crash); **Retry** from `.failed` re-invokes the pull.
- **insert throws -> `.failed`, no leak**: pull and remux succeed, fake `clipCache.insert`
  throws; the viewer lands in `.failed` with **no player** (`currentPlayerItemURL` nil),
  **both** the pulled TS and the remuxed MP4 temp files are removed, and **Retry** starts a
  new pull. This is the arm that exercises the `insert`-throw cleanup above -- the only path
  that can strand a *remuxed MP4* in temp (the fake pull/remux place real temp files so
  their removal is observable via the existing temp-cleanup seam).
- **cache-hit playback failure self-heals**: inject `lookup` returning a nonexistent URL;
  the viewer must not strand -- after the item's `.failed` status it re-pulls (a pull-client
  call happens), rather than sitting on a dead player.
- **post-remux playback failure surfaces**: after a miss -> pull -> remux -> play whose
  item goes `.failed`, the viewer lands in `.failed` with a working Retry and does **not**
  auto-re-pull (proves no self-heal loop on freshly-remuxed bytes).
- **nav-away** during a gated pull cancels the pull task and cleans temp files.

Reuse, mostly: `ClipRemuxerTests` (fast-start layout, seek, image gen) stays as-is.
`ClipPullClientTests` (retry/resume/ranged) gains the `resolvedETag` field on its expected
`ClipPullResult`s plus two assertions: a normal completion carries
`resolvedETag == httpEntityTag(listETag)` (the **quoted** form -- not the raw list etag; the
pull always tracks the quoted validator), and a mid-pull `case 200` restart carries
`resolvedETag ==` the response's **new** quoted `etag` header (the F1 regression test on the
pull side).

## Verification

1. `just app-build` -- must compile; the progressive tests are deleted in the same change,
   so the test target builds (the three edited test files are the tight coupling points).
2. `just app-test` -- new `ClipCacheTests` + adapted `ClipViewerViewControllerTests` green;
   kept suites still green.
3. `just adr-check` -- ADR 13 filename/seq valid; ADR 08 marked superseded.
4. Manual (simulator + device): open a clip cold -> determinate bar -> plays; back out and
   re-open the same clip -> **instant** (cache hit, no bar); force a pull failure (Pi off)
   -> error card + Retry; confirm the app opens no loopback HTTP socket. **On-device,
   confirm the remux (`.preparing`) stays sub-second** (the ~50 ms figure is simulator-only
   so far); if it ever runs long, the "Preparing" label -- not a frozen bare bar -- must
   show work is happening.

## Deferred (not this change)

- Incident **poster/thumbnail** during the pull -- deferred `lime` work (generate + cache
  a poster from already-pulled bytes).
- **Prefetch / cache-warming** from the home list -- net-new deferred work hung off the
  `lime` clip-store bullet.
- Budget number (500 MB) is a tunable constant, not a fixed decision.

## Implementation notes

- `ClipCache` encodes the canonical etag as lowercase UTF-8 hex rather than percent
  escapes or CryptoKit SHA256; this keeps filenames stable, ASCII-only, dependency-free,
  and still distinct for different validators.

## Follow Up

- On a physical iPhone, confirm the viewer's "Preparing" remux phase stays sub-second for
  a 30 s clip; the current 50 ms remux measurement is simulator-only.
