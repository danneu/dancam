# Plan: client-side first-frame thumbnails for the home clip list

## Context

The home screen clip list (`app/DanCam/DanCam/Features/Home/HomeViewController.swift`)
renders each finished clip as a plain text row (`seg_NNNNN.ts` + `MM:SS - <bytes>`),
with no visual. We want a first-frame thumbnail on every clip row so the list is
scannable at a glance.

**Approach decision (settled with the user):** generate thumbnails **on the iPhone**,
not the Pi. The Pi API design already specs a `GET /v1/clips/{id}/thumb` endpoint plus
cached `seg-<seq>.jpg` first-keyframe thumbnails (raspi ADRs
`02-2026-06-22-app-pi-transport-and-api.md`, `03-2026-06-23-storage-ring-buffer-incident-lock.md`),
but we are **deliberately not building that**, because:

- **SD I/O / wear:** caching `seg.jpg` on the Pi adds small-file writes + metadata churn
  to the exact card we protect for crash-safe recording. Client-side does **zero Pi
  writes** -- it only ranged-*reads* a small prefix of the already-stored `.ts` (reads
  don't wear NAND), and once a thumbnail is cached on the phone the clip is never
  re-pulled, so steady-state Pi read load trends to zero.
- **Keep the Pi dumb / faithful frame:** the true 1080p 16:9 first frame, decoded on the
  phone where iteration is fast, with no new Pi dependency (no ffmpeg route, no image crate).

**How little data the phone needs:** only the first I-frame. At 1080p30 / 10 Mbps / 1 s
GOP, that is a few hundred KB; we fetch a fixed ~2 MB prefix (one GOP + margin, single
round-trip) -- about 5% of the ~38 MB clip, once per clip, then cached forever. Clips the
user has already watched cost **0 bytes** (decoded from the cached MP4).

This pivot from the recorded Pi-side design must be written down (see "ADR" below).

## Design overview

A view-driven, injected `ThumbnailLoader` service (ephemeral media stays out of the
reducer -- `app/AGENTS.md`: "Footage itself is pulled on demand and stored as files, not
in the store"; precedent: `Features/ClipViewer/ClipViewerViewController.swift` drives
`dependencies.clipPull/clipRemuxer/clipCache` directly). The loader resolves a thumbnail
through a **cache-first, three-tier** pipeline and hands a ready `UIImage` to a custom cell.

Resolution order for `thumbnail(for: clip)` (keyed by `clip.id` + canonicalized `clip.etag`):

1. **In-memory** (`NSCache`) hit -> return immediately (no flicker, no work).
2. **Disk thumb cache** hit (`thumb-<id>-<token>.jpg`) -> load + decode -> return.
3. **Free tier:** `clipCache.lookup(id, etag)` -> if the full MP4 is cached (clip already
   watched), `AVAssetImageGenerator` on it -> **no network**. (This ordering is what makes
   watched clips free -- no eager warming needed.)
4. **Prefix tier (network):** ranged GET the first ~2 MB of `v1/clips/{id}`, **validating the
   response `ETag` octet-equals `httpEntityTag(clip.etag)`** before use (see `ClipPrefixClient`
   below) -> remux prefix -> decode first frame.

Tiers 3/4 write the result to the disk thumb cache and memory cache before returning.

## New components

All under `app/DanCam/DanCam/`, following the struct-of-`@Sendable`-closures DI mold
(`.live`/`.noop`) used by `ClipsClient`, `ClipCache`, etc. **Isolation is explicit.** The target sets
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` with `SWIFT_APPROACHABLE_CONCURRENCY = YES`, so an
un-annotated type is MainActor-isolated and even a `nonisolated async` helper still runs on the
*caller's* actor by default. Every new non-UI service/helper here is therefore declared
**`nonisolated`** (as `ClipsClient`, `ClipCache`, `ClipRemuxerEngine`, `TSDemuxer` already are), and
the decode/image-processing entry points are marked **`@concurrent`** so remux + `AVAssetImageGenerator`
+ `byPreparingForDisplay` actually leave the caller's actor (the loader actor) for the concurrent
pool -- without it the plan's "off-main decode" is not guaranteed. (`ClipRemuxerEngine.remux` already
self-detaches via `Task.detached(priority: .userInitiated)`; `@concurrent` extends that same off-main
discipline to the AVFoundation decode + downscale.)

- **`Networking/Clips/ClipPrefixClient.swift`** -- `nonisolated struct ClipPrefixClient: Sendable`
  with `var fetchPrefix: @Sendable (_ clipID: Int, _ expectedETag: String, _ byteLimit: Int) async throws -> Data`.
  The existing `ClipPullClient` **cannot** be reused: its resume path hard-asserts
  tail-to-EOF (`parsed.end + 1 == parsed.total`) and whole-file completion. Instead build a
  small bounded ranged-GET from existing internal HTTP primitives:
  `Networking/HTTP/HTTPRequestEncoder#get(url:extraHeaders:)` with
  `[("Range","bytes=0-\(byteLimit-1)"),("Connection","close")]`, `Networking/HTTP/NWByteStream#open`,
  `HTTPResponseHeadParser`, `HTTPBodyDecoder`. Accept **200 or 206**; accumulate body and
  **early-break** when `body.count >= byteLimit` (then stop iterating -> `NWByteStream`
  `onTermination` closes the connection). URL shape: `baseURL.appending(path: "v1/clips/\(clipID)")`.
  `.live(baseURL:pinning:connectTimeout:receiveIdleTimeout:)` mirrors `ClipsClient`; expose an
  injectable `openByteStream` seam (like `ClipPullClient.live(openByteStream:)`) for tests.
  - **Validator guard (prove the bytes belong to this `(id, etag)`).** The thumb cache is keyed
    by `(id, canonicalized etag)`, so the prefix bytes must be *proven* to be that exact
    representation before we decode or cache them. `id` alone is not the cache identity -- `etag`
    (`{seq}-{bytes}`) is the representation boundary, and a stale list row (an `id` the phone still
    pairs with an out-of-date validator) could otherwise cache the wrong frame under a key a later
    correct pull then trusts. The Pi never reuses a `seq` -- it is a single global monotonic segment
    ID, kept non-aliasing precisely so an immutable `ETag` is never reused (raspi ADR
    `03-2026-06-23-storage-ring-buffer-incident-lock.md`, "Segment Identity And Time") -- so this
    guard defends the *app's* `(id, etag)` boundary against a stale client-side validator, not
    against Pi-side id reuse. The endpoint
    contract already promises `ETag` + `Accept-Ranges` + `Content-Range` (raspi ADR
    `02-2026-06-22-app-pi-transport-and-api.md`, the `GET /v1/clips/{id}` line), and
    `ClipPullClient` already relies on the same `ETag` as its `If-Range` validator. So
    `fetchPrefix` requires: the response carries an `ETag` whose trimmed value **octet-equals
    `httpEntityTag(expectedETag)`** -- wrap only the *raw* expected etag (the list's
    `{seq}-{bytes}`) and compare it against the already-quoted wire `ETag`, exactly as
    `ClipPullClient` does (`resumeETag = httpEntityTag(listETag)`, then reuses the raw response
    `ETag` verbatim). `httpEntityTag` unconditionally adds quotes (`"\"\(raw)\""`,
    `Networking/HTTP/HTTPContentRange.swift#httpEntityTag`), so it must be applied to the raw
    side *only* -- applied to the already-quoted response header it double-wraps (`""7-10""` vs
    the wire `"7-10"`) and would reject every valid response. And for a **206**,
    `HTTPContentRange.parse(contentRange)` succeeds with `start == 0`. A missing or mismatched
    `ETag`, or a 206 that does not start at byte 0, **throws** (caller falls back to the
    placeholder and nothing is cached). Do *not* send `If-Range` -- a validator mismatch there
    returns a full-file `200`, defeating the point; instead send a plain ranged `GET` and
    validate the returned `ETag`.

- **`Media/ThumbnailDecoder.swift`** -- `nonisolated enum ThumbnailDecoder` (a caseless namespace
  like `ClipRemuxerEngine`) with two **`@concurrent`** async funcs returning a downscaled,
  display-ready `UIImage` -- `@concurrent` so the remux + `AVAssetImageGenerator` + downscale run on
  the concurrent pool, off whatever actor (the loader actor) awaits them:
  - `firstFrameImage(fromTSPrefix data: Data, clipID: Int, maxPixelSize: CGSize) async throws -> UIImage`
    -- write `data` to a temp `.ts`, call `Media/Remux/ClipRemuxerEngine#remux(sourceURL:outputURL:clipID:)`
    (its real signature takes `clipID: Int`, which scopes the remux's temp handling and its `clip_id=`
    structured logs; NOT `ClipRemuxer.live` -- that sweeps the `clip-<id>-` temp namespace and would
    collide with playback MP4s; use our own `thumb-\(clipID)-\(UUID()).mp4` output), then
    `AVAssetImageGenerator.image(at: .zero)`. The remuxer is fail-soft on a truncated prefix
    by design (`TSDemuxer` doc: "emits the final truncated PES as-is"); a complete first IDR
    always yields a valid frame. Set `appliesPreferredTrackTransform = true`,
    `requestedTimeToleranceBefore/After = .zero`, and `maximumSize = maxPixelSize` (decode +
    downscale in one step). Clean up temp files in `defer`.
  - `firstFrameImage(fromMP4 url: URL, maxPixelSize: CGSize) async throws -> UIImage`
    -- same `AVAssetImageGenerator` step for the free tier.
  - Call `byPreparingForDisplay()` before returning -- it runs off the caller's actor because the
    enclosing func is `@concurrent` (the same off-main goal `PreviewViewController` reaches via
    `Task.detached`).
  This reuses the exact path proven by `DanCamTests/Media/ClipRemuxerTests.swift#liveRemuxesTruncatedTransportStreamToPlayableMP4`.

- **`Media/ThumbnailCache.swift`** -- `nonisolated struct ThumbnailCache: Sendable` mirroring
  `Media/ClipCache.swift#ClipCache` (`lookup`/`insert` closures, `.live(rootDirectory:now:maxBytes:)`,
  `.noop`), but keyed `thumb-<id>-<token>.jpg` under a **separate root** (`Caches/thumbnails/`).
  Separate root is mandatory: `ClipCache`'s version sentinel wipes its whole root on bump and
  its eviction/sweep hardcode `clip-`/`.mp4`. Own version sentinel, own LRU-by-mtime, small
  budget (`maxBytes` ~64 MB; 500 clips x ~10 KB is trivial). Reuse the same etag
  canonicalization as `ClipCache#etagToken` (extract a shared `nonisolated` helper, e.g.
  `Media/CacheKey.swift#etagToken`, or duplicate the ~10 lines).

- **Concurrency gate, owned by the loader actor (not a standalone semaphore).** The cap on
  concurrent tier-3/4 generations lives *inside* the `ThumbnailLoader` actor as a small internal
  helper it mutates synchronously on its own executor: a permit count (`maxConcurrent`), a FIFO of
  parked generations, and each entry's `queued`/`running` state. Granting a permit and flipping the
  waiting entry `queued -> running` are therefore **one uninterruptible step on the single actor** --
  there is no separate semaphore actor whose grant could be observed (by a concurrent cancel) before
  the entry is marked `running`. Acquisition is **cancellation-aware**, built as the standard
  async-semaphore shape: the parked generation suspends in `withCheckedThrowingContinuation`
  (awaiting a permit) *wrapped* in `withTaskCancellationHandler`. On cancel the handler hops back to
  the loader actor, removes the entry from the FIFO, and **resumes its continuation by throwing
  `CancellationError`** -- so the parked task *finishes* (unwinds) rather than hanging, its
  entry-lifecycle cleanup runs (the registry entry is removed), and only the post-acquisition body
  (network + decode) never runs. The continuation is thus resumed exactly once (a permit granted, or
  a throw on cancel); the cancelled-while-`queued` generation is **never granted a permit**, so a
  cancelled `PrefetchHandle` drops still-queued work before it costs any bytes (see guardrails)
  without leaking a hung continuation. A generation already flipped to `running` is past the cancel
  point. (An earlier draft used a standalone actor `AsyncSemaphore` plus a `permitAcquired`
  mirror flag on the entry; that mirrored one actor's state into another and let a cancel observe
  `permitAcquired == false` for work already granted a permit. Folding the gate into the loader actor
  dissolves the mirror.)

- **`Media/ThumbnailLoader.swift`** -- the orchestrator facade
  `nonisolated struct ThumbnailLoader: Sendable`:
  - `var thumbnail: @Sendable (_ clip: Clip) async -> UIImage?` (nil on failure -> cell keeps placeholder)
  - `var prefetch: @Sendable (_ clip: Clip) -> PrefetchHandle` (fire-and-forget warm; joins
    single-flight; returns a **cancellable handle** the caller stores and later cancels)
  - a nested `nonisolated struct PrefetchHandle: Sendable` wrapping the started prefetch's cancel action
    (`func cancel()`); it captures the request's `(id, etag)` and its own registration `Task`, so
    cancelling it is always identity-correct regardless of any later list reload. `.noop`'s handle
    is inert. (There is **no** `cancelPrefetch(clipID)` -- cancellation rides the handle, not a
    re-derived id; see below for why.)
  - `.live(baseURL:pinning:connectTimeout:receiveIdleTimeout:clipCache:thumbnailsRootDirectory:now:maxConcurrent:prefixByteLimit:)`
    builds the real `ClipPrefixClient` + `ThumbnailCache` internally and closes over the passed
    `clipCache` (free tier). `.noop` returns nil / inert handles.
  - Backed by an internal `actor` holding the `NSCache`, a single-flight registry, and the
    concurrency gate above. Each registry entry is keyed by `(id, etag)` and tracks its in-flight
    `Task<UIImage?, Never>`, an explicit **`queued`/`running` state** (the entry starts `queued`; the
    gate flips it to `running` on the *same* actor step that grants its permit, before the generation
    task is resumed -- so the transition is atomic with the grant, never a flag mirrored from a second
    actor), and **interest as two idempotent token sets**, not counters: `strongTokens` (live
    `thumbnail(_:)` awaiters) and `prefetchTokens` (outstanding prefetch handles). A fresh unique
    token is minted per call. **Interest-withdrawal is uniform across both token kinds:** whenever a
    token is withdrawn -- a cancelled `thumbnail(_:)` strong awaiter *or* a cancelled `PrefetchHandle`
    -- if that withdrawal leaves **both** `strongTokens` and `prefetchTokens` empty while the entry is
    still `queued`, the entry is cancelled and removed from the gate's FIFO before it is granted a
    permit (no network, no decode); an entry already flipped to `running` is past the cancel point and
    finishes, populating the cache. This is one rule, not a prefetch-only special case -- it is
    exactly what makes the controller's offscreen quieting (`viewWillDisappear` and
    `didEndDisplaying`, below) actually relieve the link: `cancelLoad()` cancels a cell's `loadTask`,
    whose cancellation withdraws that strong token, dropping a still-`queued` entry the same way a
    cancelled prefetch handle does.
    - `thumbnail(_:)` inserts a unique strong token (creating the entry task or joining an existing
      one), awaits the shared task, and **removes that same token** on the way out. It wraps the
      await in `withTaskCancellationHandler` so a cell whose `loadTask` is cancelled -- in
      `prepareForReuse`, in `cancelLoad()` (offscreen, via `viewWillDisappear`/`didEndDisplaying`), or
      by a case-(b) identity swap -- withdraws its strong token promptly; by the uniform
      interest-withdrawal rule above, a withdrawal that empties both token sets while the entry is
      still `queued` drops that queued entry, which is what lets offscreen quieting actually relieve
      the link rather than merely detach a waiter. Because both the normal-exit path and the cancel
      handler remove the *same* token from a `Set`, a doubly-signalled waiter (cancel fires, yet
      `Task<_, Never>.value` does not throw so the body still resumes and also removes) is idempotent
      -- it can never drive a *still-present* visible waiter's interest to empty. (A bare count
      double-decrements here; a token set does not.)
    - `prefetch(_:)` mints a prefetch token and returns a `PrefetchHandle`. Its registration runs on
      the actor and, if not already cancelled (`Task.isCancelled` checked at entry -- see next),
      inserts the token and creates the entry task if absent.
    - `PrefetchHandle.cancel()` cancels its registration `Task` (synchronous, monotonic) **and**
      withdraws its prefetch token; the entry task is cancelled **only if `strongTokens` and
      `prefetchTokens` are now both empty and the entry is still `queued`** (never yet flipped to
      `running`) -- the same uniform interest-withdrawal rule the strong path obeys -- so it is
      removed from the gate's queue before it is ever granted a permit (its continuation resumed by a
      thrown `CancellationError`, per the gate above), and no network or decode runs. Riding the registration `Task`'s own cancel flag (checked at registration entry
      and when a permit is granted) is what makes cancellation **order-independent**: a cancel that
      lands *before* registration runs warms nothing, so there is no reliance on a separate async
      cancel message arriving after `prefetch`. An entry already flipped to `running` finishes and
      populates the cache; a `thumbnail(_:)` that arrives after a prefetch was cancelled starts a
      fresh generation (a cancelled/`nil` task is never handed back as a hit).
    - **Entry lifecycle (no poisoned keys).** When an entry's task finishes -- success, failure, or
      cancellation -- the entry is removed from the single-flight registry on the actor. A success
      was already written to the memory + disk caches, so the next request is a cache hit; a failure
      or cancellation leaves *nothing* to rejoin, so the next `thumbnail(_:)` for that key starts a
      fresh generation. That is what makes "a cancelled/`nil` task is never handed back as a hit"
      true: the never-throwing `Task<UIImage?, Never>` can yield `nil`, but a `nil` is never parked
      in the registry to be served to a later caller. The prefix tier itself retries once inside the
      one shared task -- `fetchPrefix(2 MB)` -> decode, and on a decode failure `fetchPrefix(4 MB)`
      -> decode, then give up with `nil` (per the sizing guardrail).
    Provide an internal designated init taking injected collaborators (prefix client, thumb cache,
    clip-cache lookup, decode closures, `maxConcurrent`) so tests fake them. The TS-prefix decode
    closure takes the clip's `id` (the loader already keys entries on it) and threads it into
    `firstFrameImage(fromTSPrefix:clipID:maxPixelSize:)`, so the remux temp file + `clip_id=` logs stay
    clip-scoped. The gate covers only tiers 3/4 (decode/network), not cache hits.

## Modified files

- **`App/AppDependencies.swift`** -- add one field `var thumbnailLoader: ThumbnailLoader`,
  default `.noop` in the memberwise (test) init, and wire `.live(...)` in `init(configuration:)`
  passing the existing `clipCache`, `cameraAPIBaseURL`/pinning/timeouts, and
  `Caches/thumbnails` as the root -- mirroring the `clipPull`/`clipCache` wiring block.
  (`ThumbnailCache`/`ClipPrefixClient` stay internal to the loader; tested directly, not via deps.)

- **`Features/Home/HomeViewController.swift`**:
  - New custom cell **`Features/Home/ClipThumbnailCell.swift`** modeled on the existing
    `LiveClipCell` (programmatic, `configureViews()` + `layoutMarginsGuide` stack, unavailable
    `init?(coder:)`): a leading `UIImageView` (fixed ~80x45 pt, 16:9, `cornerRadius`,
    `contentMode = .scaleAspectFill`, `clipsToBounds`) + the title/subtitle labels (reuse
    `Support/Formatters.swift#clipMetadata` and the `seg_%05d.ts` title). The cell's UI identity is a
    small `nonisolated Equatable` **`ClipThumbnailIdentity(id, etag)`** -- the *same* `(id, etag)` the
    loader, cache, and prefetch handles key on, not `clip.id` alone -- so "am I still showing the clip
    this result was generated for" is asked against the exact representation boundary the result was
    generated against. `configure(clip:loader:)` is a **single-task state machine** holding exactly
    one `loadTask` handle, so the reconfigure churn (`renderRows()`'s full `reloadData()` on every
    clips/connection update -- which first routes each visible cell through `prepareForReuse`, clearing
    its identity, so `configure` re-runs against a *cleared* cell and takes path (b) -- and
    `viewWillAppear`'s **in-place** visible-row reconfigure, which skips `prepareForReuse` so `configure`
    re-runs against the cell's *retained* identity and takes the path-(a) no-op) can never
    stack a second load on a cell: **(a)** same identity -- if a `loadTask` is already in flight *or* the
    image is already painted -> **no-op** (keep the painted thumbnail, never flash), so repeated
    same-identity `configure` starts *one* load and never orphans a running task -- an orphaned task
    would keep its strong token and keep pinning the loader entry, defeating offscreen cancellation; but
    if a prior load already finished **`nil`** *or was cancelled by `cancelLoad()`* (handle cleared,
    nothing painted) -> start one fresh **retry** load (a persistent miss just retries on the next
    `renderRows()` reload or `viewWillAppear` in-place reconfigure, cheap because resolution is
    cache-first and single-flighted -- never a stampede);
    **(b)** a *different* identity (a reused cell, or a same-`id`/new-`etag` update) -> **cancel the
    in-flight `loadTask`**, set the new identity, reset to the placeholder, and start exactly one new
    `loadTask` that awaits `loader.thumbnail(clip)`. Each load also captures a monotonic **load token**
    -- a bare `Int` counter the cell bumps immediately before it assigns *any* new `loadTask` (both the
    case-(b) new load and the case-(a) `nil`-retry), **and** in `cancelLoad()` before it nils the handle,
    so the token always names the single currently-live load attempt. It is orthogonal to the identity
    guard below (which keys on `(id, etag)` for the *apply* decision; the token governs only handle
    ownership). On the way out (success or `nil`) the task applies its image **only if the cell
    still shows that identity** and **clears the `loadTask` handle only if its captured token is still
    current** -- only the currently-owned load may null the handle. This matters because the completion
    runs on the MainActor *after* the `await`, so a cancelled prior load can resume after a newer
    `loadTask` was installed -- whether by a different-identity case-(b) swap **or** by a same-identity
    `cancelLoad()` (Home offscreen) followed by a retry on return. An unconditional clear there would
    null the *new* task's handle, and the next same-identity `configure` would then see no in-flight
    task and start a third, orphaned load -- the strong-waiter leak the state machine exists to prevent.
    Because the token advances on every assignment *and* in `cancelLoad()`, a cancelled task's captured
    token is already stale by the time it resumes, so it can neither null a fresh handle nor be mistaken
    for the live attempt (it may still *paint*, which is identity-gated and correct -- see `cancelLoad()`
    below). Guarding the
    clear on the load token keeps a stale completion from touching a handle it no longer owns, so a
    later same-identity `configure` starts a fresh load only when none is running *and* nothing is
    painted (i.e. a prior load finished `nil`). The
    apply-if-still-current check is an extracted `nonisolated` cell-scope generation guard struct that
    stores the current `ClipThumbnailIdentity`, borrowing the struct-extraction + unit-test shape of
    `Features/Preview/PreviewViewController.swift#PreviewDecodeState` but discriminating on the
    `(id, etag)` identity rather than a bare counter (unit-tested -- see Tests). A `cancelLoad()`
    **advances the load token**, then cancels and clears the `loadTask` **without clearing the shown
    image or the stored identity** (the cell still shows this clip; a load already flipped to `running`
    that resolves anyway carries this same identity and still *paints* the correct frame -- painting is
    identity-gated -- while the token bump ensures that stale completion can no longer *null* the handle
    of a same-identity retry started on return), so the controller can quiet a still-loading cell when
    Home goes offscreen without wiping a thumbnail it already painted. `prepareForReuse` calls
    `cancelLoad()`, clears the stored identity, and resets to the placeholder (a reused cell is about
    to show a different clip, and a late result from the prior clip must not match).
  - Register the cell under a new reuse id; rewrite `configureFinishedCell` to dequeue it and
    call `configure(clip:, loader: dependencies.thumbnailLoader)`. Bump `estimatedRowHeight`.
  - Adopt `UITableViewDataSourcePrefetching` (not currently used anywhere): set
    `clipsTableView.prefetchDataSource = self`. Keep a `[IndexPath: ThumbnailLoader.PrefetchHandle]`
    map on the controller. `prefetchRowsAt` -> for each `.finished` row, **first cancel any handle
    already stored at that index path (cancel-before-replace)**, then call `loader.prefetch(clip)`
    and store the returned handle (cache-warming look-ahead). Cancel-before-replace is load-bearing:
    a `PrefetchHandle` is a value type with no `deinit`, so silently overwriting a map slot would
    orphan the prior handle's prefetch token -- it would never be withdrawn, so it would keep pinning
    that entry and defeat a later cancel. `cancelPrefetchingForRowsAt` -> cancel + remove the
    **stored handle** for each index path -- never re-derive a clip id from the current `rows` (a
    reload can shift `rows`, so an index -> clip lookup would cancel the wrong clip; the stored handle
    already carries the correct `(id, etag)`). Because `renderRows()` does a full `reloadData()` on
    every clips/connection update, also cancel + clear all outstanding handles there: the index keys
    are now stale, any still-wanted row is re-requested by the next `prefetchRowsAt`/`cellForRow`, and
    cancelling only bites still-queued (pre-permit) warms -- post-permit warms finish and cache
    regardless. Cancellation targets the exact work `prefetch` started, not a freshly looked-up id.
  - **Thumbnail work is scoped to Home's on-screen lifetime, hung off the controller's existing
    lifecycle hooks.** `viewWillDisappear` (already present) additionally cancels + clears every
    outstanding prefetch handle and calls `cancelLoad()` on each visible `ClipThumbnailCell`, so
    pushing Home offscreen -- e.g. into `ClipViewerViewController`, which then pulls a full ~38 MB
    clip -- stops thumbnail work from holding the shared 2.4 GHz link behind that foreground pull
    (the concrete form of the guardrails' "yield to a foreground clip pull"). Additionally implement
    **`tableView(_:didEndDisplaying:forRowAt:)`** to call `cancelLoad()` on the departing
    `ClipThumbnailCell` the instant a row leaves the visible area: `prepareForReuse` fires only on
    *re-dequeue*, so without this a row scrolled offscreen but not yet reused keeps its `loadTask`
    (and strong token) live, and `viewWillDisappear`'s visible-only sweep would miss those reuse-pool
    cells -- a small, pool-bounded leak in the "no queued work during a foreground pull" guarantee. It
    also tightens visibility-scoping during ordinary fast scroll: a scrolled-past row drops its
    still-`queued` entry (per the uniform interest-withdrawal rule) immediately instead of waiting for
    reuse, and a scroll-back re-requests it cache-first. `deinit` (already
    present) repeats the handle cleanup so a dismissed Home leaves no prefetch work running.
    `viewWillAppear` (already present) re-requests visible rows by **reconfiguring the visible
    `ClipThumbnailCell`s in place** -- walk `clipsTableView.indexPathsForVisibleRows` and, for each
    `.finished` row, call `configure(clip:loader:)` on the existing `clipsTableView.cellForRow(at:)`
    cell (the same in-place visible-cell-update shape `updateVisibleLiveElapsed()` already uses for the
    live row) -- **not** a `reloadData()`. A `reloadData()` here would return even the visible cells to
    the reuse pool and re-dequeue them, firing `prepareForReuse` (which clears identity + resets to the
    placeholder) *before* `configure` runs, so every already-painted cell would take the
    different-identity path (b), blank to the placeholder, and start an avoidable cache-hit reload --
    a visible flash on a return where nothing changed. Reconfiguring in place skips `prepareForReuse`,
    so a cell that already painted its thumbnail hits the same-identity **no-op** (case (a): keeps the
    image, no flash, no load) and a cell whose load was cancelled on the way out (placeholder shown,
    identity retained, handle cleared by `cancelLoad()`) takes the same-identity **retry** and reloads
    once, cache-first. `reloadData()` stays reserved for actual row-model changes in `renderRows()`.
    Cancel-on-disappear only drops still-queued (pre-permit) loads -- a load past its permit finishes
    and caches regardless (per the out-of-scope note) -- so at worst a couple of pre-permit rows
    re-fetch on return.

- **Docs & ADR pivot** (a pivot that isn't written down is the next trap -- `AGENTS.md#Working stance`):
  - Add app ADR **`app/docs/design/16-2026-07-01-client-side-clip-thumbnails.md`** (next seq is 16 --
    `14-2026-07-01-structured-logging-and-export.md` and `15-2026-07-01-clip-export-share.md` already
    exist; confirm with `just adr-check`) recording the client-side decision, its rationale (Pi SD I/O,
    dumb Pi, faithful frame, bandwidth math), and the considered-and-rejected Pi `/thumb` alternative.
  - Add a short "Superseded (thumbnails) by app ADR 16" note on the thumbnail sections of raspi ADRs
    `02-...-app-pi-transport-and-api.md` (the `/v1/clips/{id}/thumb` line) and
    `03-...-storage-ring-buffer-incident-lock.md` (the `seg-<seq>.jpg` / `openThumb` sections).
  - Add ADR 16 to the "Current:" list under `app/AGENTS.md#Design decisions (ADRs)`.
  - Repoint `docs/roadmap.md` so it no longer prescribes the rejected Pi endpoint: in **Swoop
    `lime`**, the "placeholder poster / generate and cache a real poster from any clip already
    pulled" item is the free tier this plan implements *and extends* (we also cover not-yet-pulled
    clips via the prefix tier) -- point it at ADR 16; resolve the `lime` scope-fence conditional
    ("If the iPhone-poster approach replaces ADR 02's Pi-generated `/thumb` ...") to state that it
    does, per ADR 16; and drop/repoint the **"Later / deepening passes"** `server-side browse
    thumbnails (GET /v1/clips/{id}/thumb ...)` item, since client-side now covers the not-yet-pulled
    case without Pi work.

## Concurrency, cancellation & sizing (the stampede guardrails)

The list can hold up to 500 clips; a naive "generate all on load" would stampede the 2.4 GHz
link (shared with live preview) and the Pi's read I/O. Rules:

- **Visibility-scoped, never list-scoped.** Work is driven by `cellForRow` (visible rows) +
  prefetch look-ahead only. Every clips update does a full `reloadData()`, so `cellForRow` runs
  often -- kept cheap by the memory cache + single-flight. Visibility means *view* visibility too:
  when Home leaves the screen the controller cancels its look-ahead handles and quiets cell loads
  (visible cells on `viewWillDisappear`, and any row that scrolled offscreen already shed its load on
  `didEndDisplaying`; see `HomeViewController` above), so still-`queued` thumbnail work is dropped
  (its interest withdrawn, per the uniform rule) and stops holding the link behind a foreground clip
  pull (loads already past a permit finish and cache); on return,
  `viewWillAppear` reconfigures the visible cells *in place* (not a `reloadData()`, so no
  `prepareForReuse` blanks them first) and cache-first resolution repaints generated thumbnails
  instantly, without a placeholder flash.
- **Single-flight:** concurrent/repeat requests for the same `(id, etag)` share one task
  (prevents the prefetch-then-willDisplay double fetch). A generation that has flipped to `running`
  (been granted a permit) runs to completion and populates the cache (only ~2 MB, wanted again on
  scroll-back); an awaiting cell that gets reused just drops its result via the generation guard.
- **Prefetch cancellation actually relieves the link (not just a flag).** This is what keeps
  "visibility-scoped" honest under fast scroll: without it, scrolling that prefetches then
  abandons rows would queue their 2 MB/4 MB GETs behind the cap-3 gate and warm far past the
  visible/prefetched window. A prefetch-only entry (`prefetchTokens` non-empty, `strongTokens`
  empty) that is still **`queued`** for a permit is cancelled outright when its `PrefetchHandle` is
  cancelled -- removed from the gate's wait queue on the loader actor before it touches the network
  or decoder. A `thumbnail(_:)` strong token pins the entry, so a genuinely-visible row's in-flight
  work is never cancelled; and an entry already flipped to `running` is past the cancel point and
  finishes (cheap, and its result is cached).
- **Bounded concurrency:** `maxConcurrent = 3` around tiers 3/4. One cap protects the Wi-Fi
  link, the Pi's read I/O, and the device. (Future: yield to a foreground clip pull.)
- **Prefix size:** fixed `prefixByteLimit = 2 MB` (one GOP + margin -> single round-trip, no
  probe/extend state machine; 256 KB alone can't hold a 1080p IDR). On decode failure, retry once
  at ~4 MB, then give up (placeholder). Future optimization: 256 KB probe + conditional extend.
- **Thumbnail render size:** `maxPixelSize = 240x135 px` -- the 80x45 pt cell image at **3x**
  Retina (the scale of every current iPhone), so thumbnails stay crisp instead of the ~2x (192x108)
  under-sample that renders soft on 3x screens. JPEG ~8-16 KB each, still trivial against the ~64 MB
  cache budget. (Future nicety: derive the size from the configuring cell's
  `traitCollection.displayScale` so 2x devices store less; a flat 3x is a few KB of slack, not worth
  the plumbing now.)

## Tests (Swift Testing, `import Testing` + `@testable import DanCam`)

Mirror the source tree under `DanCamTests/`. Behavioral, structure-insensitive:

- `Media/ThumbnailCacheTests.swift` -- mirror `ClipCacheTests` (temp dir, injected `now`,
  `defer` cleanup): insert moves to `thumb-<id>-<token>.jpg`; lookup hit touches mtime; LRU
  eviction by `maxBytes`; version-sentinel isolation; does not touch the clip-cache root.
- `Networking/Clips/ClipPrefixClientTests.swift` -- inject a fake `openByteStream`, passing a
  **raw** `expectedETag` (`7-10`) while the canned responses carry the **quoted wire** `ETag`
  (`"7-10"`) -- so the suite pins the wrap-one-side rule: a canned 206 (wire `ETag` `"7-10"`,
  `Content-Range` starting at 0, `Content-Length = N`) returns exactly N bytes and stops; a 200
  whole-file body > N with the same wire `ETag` early-breaks at N (no hang); non-2xx throws.
  **Bounded request contract:** capture the emitted request through the injected `openByteStream`
  seam (exactly as `ClipPullClientTests` capture theirs via a request actor) and assert it is a
  single `GET /v1/clips/{id}` carrying `Range: bytes=0-\(byteLimit-1)` and `Connection: close` and
  **no `If-Range`** -- so an implementation that omitted the `Range`, sent the wrong byte window, or
  added an `If-Range` (which would let a validator mismatch return a full `200`) fails here instead
  of silently passing the canned-response cases.
  **Validator guard:** a response whose wire `ETag` is a *different* quoted value (`"8-10"`) throws
  (nothing returned); a 206 whose `Content-Range` does not start at 0 throws; a response missing
  `ETag` throws. (A regression that double-wrapped the response side would fail the two success
  cases, not just the mismatch case.)
- `Media/ThumbnailDecoderTests.swift` -- cover **both** decoder entry points against the real
  `DanCamTests/Media/Fixtures/seg_00000.ts` fixture (320x180). Both must be pinned here: the loader
  tests fake the decode closures, so a broken decoder ships green unless the real thing is exercised
  directly.
  - **Prefix tier (`fromTSPrefix`):** take the fixture (via `MediaFixtureURLs#seg00000TS`), slice a
    `data.prefix(...)`, assert `firstFrameImage(fromTSPrefix:clipID:maxPixelSize:)` (passing any
    `clipID`) returns a non-nil image downscaled to `maxPixelSize`. Template:
    `ClipRemuxerTests#liveRemuxesTruncatedTransportStreamToPlayableMP4` (truncated `.ts` input).
  - **Free tier (`fromMP4`):** first remux the whole fixture to a temp `.mp4` via
    `ClipRemuxerEngine#remux(sourceURL:outputURL:clipID:)` (the same engine the decoder uses; `defer`
    cleanup), then assert `firstFrameImage(fromMP4:maxPixelSize:)` on that URL returns a non-nil image
    downscaled to `maxPixelSize`. Template for the fixture-to-playable-MP4 step:
    `ClipRemuxerTests#liveRemuxesTransportStreamFixtureToPlayableMP4`. This pins the free-tier
    (watched-clip) decoder that the loader's faked decode closures leave uncovered -- without it a
    broken `fromMP4` path ships green while every already-watched clip silently falls back to a
    placeholder (or skips the downscale).
- `Media/ThumbnailLoaderTests.swift` -- with faked collaborators and an actor/`AsyncSignal`-style
  coordinator for deterministic sequencing:
  - **Tier routing:** disk-cache hit skips clip cache + prefix; free-tier (clipCache returns MP4)
    skips prefix; neither -> prefix invoked; the prefix tier passes `clip.etag` through to
    `fetchPrefix`, and a fake that throws on etag mismatch yields `nil` with nothing cached.
  - **Single-flight:** two concurrent `thumbnail(clip)` calls trigger exactly one underlying fetch
    (fetch counter == 1); a second call after completion is a memory hit (count stays 1);
    failure -> `nil`.
  - **Bounded concurrency:** with a decode/prefix collaborator that blocks on a signal and
    records peak concurrent entries, launching `N > maxConcurrent` *distinct* misses shows peak
    concurrency `== maxConcurrent` (no stampede) and all complete once released (no deadlock).
  - **Permit release on failure:** a generation that throws still lets a subsequent distinct
    miss acquire a permit and run -- proving the permit is released on the failure path, not leaked.
  - **Prefetch cancellation (handle-based):** with the gate saturated (all permits in use), `prefetch(clip)` then
    `handle.cancel()` leaves that key's prefix/decode fetch count at **0** (queued work dropped
    before any network); a `handle.cancel()` issued *before* the prefetch registration runs also
    yields fetch count **0** (order-independent); but when a `thumbnail(clip)` has joined the same
    entry, `handle.cancel()` does *not* cancel and the generation still completes. **Two prefetch
    handles for the same key are independent:** cancelling one leaves the entry queued (the other's
    token still pins it), cancelling both drops it (fetch count **0**) -- the invariant that makes
    the controller's cancel-before-replace and clear-all-handles-on-disappear correct instead of
    orphaning a token.
  - **Strong-waiter interest is cancel-safe:** two concurrent `thumbnail(clip)` awaiters join one
    entry; cancelling *one* of them does **not** unpin the entry -- the second still completes and
    caches, and the redundant release of the cancelled waiter (cancel handler *and* resumed body
    both firing) does not drop the surviving waiter's interest -- the idempotent-token
    guarantee; a bare count would let the entry cancel out from under the still-visible row.
  - **Strong cancellation drops a last-interest queued entry (uniform withdrawal):** the complement
    of the previous test -- with the gate saturated so the entry stays `queued`, a *single*
    `thumbnail(clip)` is the only interest; cancelling that awaiting task drops the entry, so its
    key's prefix/decode fetch count stays **0** (no permit ever granted -- the parked continuation
    resumes by throwing, so nothing hangs), and a *later* `thumbnail(clip)` for the same key starts a
    fresh generation (fetch count increments). Pins that the interest-empty-while-queued cancellation
    rule fires on the **strong** path too, not only via `PrefetchHandle.cancel()` -- the loader-level
    guarantee behind `viewWillDisappear`/`didEndDisplaying` quieting visible-cell loads.
  - **Prefix retry then cache:** a miss whose 2 MB prefix fails to decode triggers a second
    `fetchPrefix` at ~4 MB; the 4 MB decode succeeds, the result is cached, and a later
    `thumbnail(clip)` for the same key is a memory hit (the fetch count does not climb past the one
    retry). Pins "retry once at ~4 MB" and that the retry's success is cached, not re-fetched.
  - **Failure and cancellation leave no poisoned key:** a generation that ends in `nil` (both the
    2 MB and 4 MB decodes fail) removes the entry, so a *later* `thumbnail(clip)` for the same key
    starts a fresh generation (fetch count increments) rather than re-joining a completed `nil` task;
    the analogous cancelled-prefetch case (a queued `prefetch` cancelled to fetch count 0, then a
    `thumbnail(clip)` for the same key) likewise re-fetches from scratch. Pins that neither a failed
    nor a cancelled task is cached or handed back as a hit.
- `Features/Home/ClipThumbnailCellTests.swift` (**MainActor**) -- drive the real cell with a fake
  `ThumbnailLoader` whose `thumbnail` closure counts invocations and parks on a signal: repeated
  `configure` with the *same* identity starts **one** load (call count stays 1, no orphaned task);
  `configure` with a *different* identity cancels the first cell task (the parked first call observes
  `CancellationError` / `Task.isCancelled`) and starts exactly one new load; a **successful** load paints
  the image and clears its handle, yet a later same-identity `configure` is a **no-op** (the painted image
  keeps it from reloading -- call count stays 1), whereas a **`nil`** load clears its handle *without*
  painting, so a later same-identity `configure` **does** start exactly one fresh retry (call count goes
  to 2) -- proving success and failure diverge on the painted-image check, not on the handle alone.
  **Stale-clear guard:** keep the
  first (identity A) load parked, `configure` to identity B (cancelling A's cell task and starting B's
  load), then release A so its completion runs *after* B's `loadTask` is installed -- A's stale
  completion must **not** null B's handle, so a repeated `configure` for identity B (still parked)
  starts **no third load** (total load count stays 2). **`cancelLoad()` ownership:** `configure(A)`
  (load 1, parked), `cancelLoad()` (advances the token, cancels + clears the handle, keeps identity A),
  then `configure(A)` again -> a same-identity **retry** (load 2, parked); release load 1's stale
  completion *after* load 2 is installed -- because `cancelLoad()` advanced the token, load 1 no longer
  owns the handle and **must not** null load 2, so a further `configure(A)` starts **no third load**
  (count stays 2). Pins the single-task state machine and the load-token ownership check -- advanced on
  every `loadTask` assignment **and** in `cancelLoad()` -- that stop an orphaned load from pinning a
  loader entry past offscreen cancellation.
- **Required:** extract the cell's generation guard as a `nonisolated struct` (borrowing the
  struct-extraction + test shape of `Features/Preview/PreviewViewController.swift#PreviewDecodeState`,
  but keyed on `ClipThumbnailIdentity(id, etag)` rather than a bare counter) and unit-test it like
  `DanCamTests/Features/Preview/PreviewDecodeStateTests.swift`: a result carrying the currently-shown
  identity is applied; a result carrying a superseded identity is dropped, covering **both** a
  different-`id` reuse **and** a same-`id`/different-`etag` reconfiguration (identity `(7,"7-100")`
  in flight, the cell reconfigured to `(7,"7-200")`, the `(7,"7-100")` result dropped) -- proving
  the guard keys on the whole `(id, etag)`, not `id` alone. This is the load-bearing guard against a
  recycled or re-represented cell painting the wrong clip's thumbnail -- the loader tests can't
  observe it, so it must be covered here.
- `Features/Home/HomeViewControllerTests.swift` (**MainActor**) -- controller-level testing is an
  established pattern here (`App/AppShellViewControllerTests.swift`,
  `Features/ClipViewer/ClipViewerViewControllerTests.swift`,
  `Features/Health/HealthViewControllerTests.swift`), so the load-bearing prefetch glue and the two
  offscreen-quieting hooks are a coverage gap, not a testability dismissal. Drive the real controller
  with a fake `ThumbnailLoader` whose `prefetch` returns a `PrefetchHandle` wrapping a per-`(id, etag)`
  recording cancel closure (each handle records whether `cancel()` fired), and whose `thumbnail`
  closure parks on a signal and records observed cancellation (the parked-closure shape
  `ClipThumbnailCellTests` uses). Assert the glue *behaviorally*, through observable cancels
  -- not by reaching into the private handle map: (1) **cancel-before-replace** -- `prefetchRowsAt`
  twice for the same index path cancels the first handle before storing the second; (2) **explicit
  cancel** -- `cancelPrefetchingForRowsAt` cancels the stored handle for those paths; (3)
  **clear-all-on-reload** -- driving a clips update (which does a full `renderRows()` reload) cancels
  *every* outstanding handle; (4) **clear-all-on-disappear** -- `viewWillDisappear` cancels every
  outstanding handle. Those four are observable via the fake's per-key cancel counters and
  structure-insensitive (they assert the guarantee -- orphaned prefetch work is always cancelled --
  not the reload mechanism). Two further assertions pin the `cancelLoad()` offscreen-quieting hooks --
  strong-load glue the four prefetch assertions never touch, so deleting either hook would silently
  revert offscreen quieting while all four prefetch assertions still pass: (5) **quiet-on-disappear**
  -- with a visible `ClipThumbnailCell`'s load parked, `viewWillDisappear` drives that parked
  `thumbnail(_:)` call to observe cancellation (the cell's `cancelLoad()` fired); (6)
  **quiet-on-scroll-off** -- with a cell's load parked, `tableView(_:didEndDisplaying:forRowAt:)` for
  that row drives the same. Both are behavioral (the guarantee is "the in-flight load observes
  cancellation," not any internal state) and structure-insensitive. Without this suite a regression
  that orphaned a prefetch handle, or deleted either `cancelLoad()` hook, would pin a loader entry or
  leave a queued load running behind a foreground pull, and nothing would fail.

Use the `swift-concurrency-pro` and `swift-testing-pro` skills while implementing (per `app/AGENTS.md`).

## Verification

- **Unit:** `just app-test` (Swift Testing suite, iPhone 17 / iOS 26.5 sim). All new suites green.
- **Build:** `just app-build`.
- **Manual, end-to-end:** `just raspi-mock-clips` to serve a sample clip on `/v1/clips`, then run
  the app (Cmd-R into the iOS 26.5 sim, scheme `DanCam`, `DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080`).
  Expect: rows show a placeholder then fill with a first-frame thumbnail; scrolling loads lazily
  without jank; relaunch shows thumbnails instantly (disk cache); killing the mock leaves
  placeholders with no crash. Push into a clip mid-load and straight back: **no new or queued**
  thumbnail work runs while the clip pull is in progress (on `viewWillDisappear` Home cancels its
  look-ahead handles and quiets visible-cell loads; if you *scroll* first, the rows that left the
  viewport already shed their loads via `didEndDisplaying`, so no queued strong work survives into the
  pull); at most the generations already flipped to
  `running` (up to `maxConcurrent`) finish and cache, so those -- not a fresh stampede -- are the
  only thumbnail pulls that can briefly share the link with the foreground clip pull. On return the
  list shows its already-generated thumbnails **without a placeholder flash** (the visible rows are
  reconfigured in place, not via `reloadData()`), filling any stragglers from cache.
  - **Ranged clip bytes -- already served by the mock (confirmed).** `just raspi-mock-clips` runs the
    *real* Rust service (`cd raspi/service && DANCAM_REC_DIR=assets/clips cargo run`) against
    `raspi/service/assets/clips/`, which ships a real ~1.0 MB `seg_00000.ts`, and
    `raspi/service/src/clips.rs#serve_clip` already implements ranged `GET /v1/clips/{id}`
    (206 `PARTIAL_CONTENT`, `Content-Range`, `ETag` = `{seq}-{bytes}`, `If-Range`). So the prefix pull
    works end-to-end against the mock with no extra mock work; because the fixture (~1.0 MB) is smaller
    than the 2 MB prefix, the ranged GET simply returns the whole clip, which still decodes to a first
    frame. (Earlier drafts hedged that the mock "might only serve the listing" -- it serves ranged
    bytes.)

## Out of scope / future

- Pi `/v1/clips/{id}/thumb` endpoint (explicitly rejected -- see ADR 16).
- 256 KB probe + conditional extend to cut typical prefix bytes ~4x.
- Eager thumbnail warming after a clip pull (the free-tier ordering already makes watched clips
  cheap on next display).
- Cancelling generations already flipped to `running` (past their permit -- in-flight
  network/decode): those finish and populate the cache -- acceptable at 2 MB / cap 3. (Cancelling
  still-`queued` prefetch-only work with no strong (`thumbnail`) waiter **is** in scope -- see the
  guardrails.)
- A live-row thumbnail (the `.live` recording row keeps its REC pill).

## Implementation notes

- **`ThumbnailImage` wrapper instead of a bare `UIImage?`.** The plan specced
  `thumbnail: (Clip) async -> UIImage?`, but a memory-cache hit returns a *shared* (not
  disconnected) `UIImage`, which `sending UIImage` cannot express across the loader
  actor -> MainActor boundary. Introduced `nonisolated struct ThumbnailImage: @unchecked
  Sendable { let image: UIImage }` as the currency type; the decode closures still return
  `sending UIImage` (fresh values), and `NSCache` stores `UIImage` directly. The cell
  consumes `ThumbnailImage.image`.
- **`ThumbnailCache.insert` takes `Data`, not a source `URL`.** Unlike `ClipCache` (which
  moves an already-on-disk pulled file), a thumbnail is generated in memory, so `insert`
  writes the encoded JPEG bytes directly.
- **Decoder uses default `AVAssetImageGenerator` time tolerances, not `.zero`.** The plan
  specced `requestedTimeToleranceBefore/After = .zero`, but a remuxed clip's first frame
  does not always sit at exactly PTS 0, so a zero-tolerance request at `.zero` fails with
  AVFoundation -11832 ("Cannot Open"). Default (infinite) tolerances return the sync sample
  nearest `.zero` -- the first frame -- matching the proven `ClipRemuxerTests` decode path.
  `maximumSize` (the downscale) is unchanged.
- **Loader helper types are `nonisolated`.** `ThumbnailKey`, `ThumbnailEntry`, and
  `GenerationState` must be `nonisolated` so their conformances/mutations are usable inside
  the (non-MainActor) `Loader` actor; the target otherwise defaults un-annotated types to
  MainActor isolation.
- **Two read-only cell test seams.** `ClipThumbnailCell` exposes `displayedImageForTesting`
  and `isLoadingForTesting` so the single-task state-machine tests can wait on the paint and
  handle-clear events deterministically (mirrors the test accessors on
  `ClipViewerViewController`).
