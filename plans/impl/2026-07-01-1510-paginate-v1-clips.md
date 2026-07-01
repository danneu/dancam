# Plan: paginate `/v1/clips` so older footage is reachable

## Context

The Pi clip listing (`raspi/service/src/clips.rs#read_finished_clips`) sorts
finished segments newest-first, hard-truncates to `MAX_CLIPS = 500`, and
`list_clips` always returns `next_cursor: None`. Past the newest 500 segments
there is no way to page: on a flat layout that accumulates `seg_NNNNN.ts` with no
eviction yet, more than 500 finished segments appear after ~4h of continuous
recording, and from that point the older footage sits on the card but is
unreachable through the API. The truncation is silent to the client (a
server-side `tracing::warn!` only). For a dashcam, older context is exactly what a
user goes looking for after the fact, so this undercuts swoop `lime` ("Watch
recorded clips"), whose browse surface is the home "Recent clips" list.

The wire contract already defines the fix. ADR 02
(`raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md`, the **Clips**
section) specifies `GET /v1/clips?from=&to=&limit=&cursor=&order=` returning
`next_cursor`; ADR 03
(`raspi/docs/design/03-2026-06-23-storage-ring-buffer-incident-lock.md#Index,
Listing, And Rebuild`) specifies `listClips(... cursor ...)` that "pages by
`seq`". The `fern` note in ADR 02 recorded `next_cursor:null` as an interim
simplification; this change realizes the cursor.

**Outcome:** the Pi serves the listing in descending-`seq` pages with a real
`next_cursor`, and the app's home clip list lazily pages older clips in as you
scroll. End-to-end, all footage on the card becomes reachable.

This is the source of finding E-02 in `video-review.xegWVJ/05-pi-clip-serving.md`.

## Design: keyset pagination by descending `seq`

- **Cursor is keyset, not offset.** A page returns the newest `limit` segments
  with `seq < cursor` (cursor absent = newest page). `next_cursor` is the lowest
  `seq` on the page when older segments remain, else null. This is stable under
  the two concurrent mutations that happen here: new segments finalize at higher
  `seq` (they only ever appear above the first page, governed by the recorder
  floor), and bottom-end GC just yields fewer rows on later pages -- neither
  skips nor duplicates across a page boundary, because the boundary is a `seq`
  value, not a positional offset. An offset cursor would double-show or skip rows
  whenever the head grew between requests; keyset must be used.
- **`limit` becomes a per-page bound, not a ceiling on what exists.** Default
  `DEFAULT_LIMIT = 100`, hard cap `MAX_LIMIT = 100` -- deliberately equal. The app
  is the sole client and never sends `limit`, so it always pages at the default;
  bulk / old-footage access is meant to be filter-first (`from`/`to`, deferred to
  `moss`) and the scrollable home list is the recent-clips / interim browse path,
  so no legitimate client requests more than the default. `MAX_LIMIT` therefore
  exists only to clamp an untrusted `?limit=`; a larger ceiling would be unused
  headroom whose sole effect is letting one request amplify the cold-cache scan
  below. The limit bounds that scan: `read_finished_clips` calls
  `DurationCache::duration_ms` per returned clip, each an uncached synchronous SD
  read (`raspi/service/src/ts_duration.rs#segment_pts_span`), so a 100-row page is
  strictly cheaper on first paint than today's `MAX_CLIPS = 500` truncation, and
  capping at the default holds the worst case to that same modest size instead of
  a 5x-larger one. (If a future consumer ever needs bigger pages, `MAX_LIMIT` is
  the single number to raise.)
- **Scope line:** implement `limit` + `cursor` (descending `seq`) now. `from`/`to`
  window filtering needs resolved wall-clock time (swoop `moss`) and `order=asc`
  has no consumer, so both stay deferred -- but because ADR 02 advertises them, the
  handler **explicitly rejects them with `400`** rather than ignoring them (axum's
  `Query` silently drops unmodeled params and would return a full unfiltered
  descending page -- a dangerous false success for a footage-lookup query). This
  change fills in the time-independent subset and fails loud on the rest.

## Pi changes (`raspi/service/`)

The mock Pi is the same Rust service running `MockBackend`
(`Justfile#raspi-mock`), served by the same `clips::list_clips` ->
`read_finished_clips` path, so this single change covers both mock and real Pi --
nothing separate to mirror.

1. **`src/clips.rs#list_clips`** -- add an axum `Query` extractor (the first in
   the service; `serde` derive is already a dependency). Model **every** param ADR
   02 advertises so none is silently dropped:
   `#[derive(serde::Deserialize)] struct ClipsQuery { limit: Option<usize>,
   cursor: Option<String>, from: Option<String>, to: Option<String>, order:
   Option<String> }` and take `Query<ClipsQuery>` (`from`/`to` are presence-detect
   strings for now; they become typed ms with real filtering in `moss`). The
   handler:
   - Rejects (`400`) any advertised-but-unimplemented param rather than ignoring
     it, so a footage-lookup client never gets a silent unfiltered page: `from` or
     `to` present -> `400`; `order` present and not `"desc"` -> `400` (absent or
     `order=desc` is the only accepted behavior).
   - Parses `cursor` to a `SegmentId` (`u32`); a malformed cursor -> `400`.
   - Resolves the page size through a small **pure** `resolve_limit(Option<usize>)
     -> usize` helper (`unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT)`) -- HTTP-layer
     policy kept in one unit-testable function.
   - Reads the floor once (`state.backend.unpullable_from()`, a cheap in-memory
     read) and hands floor + cursor + resolved limit into the blocking scan.

   Return type becomes `Result<Json<ClipsResponse>, StatusCode>` (axum `StatusCode`
   is `IntoResponse`; `BAD_REQUEST` covers all rejections above). Set `next_cursor`
   from the returned boundary (`seq.to_string()`).

2. **`src/clips.rs#read_finished_clips`** -- add `cursor: Option<SegmentId>` and
   `limit: usize` params; return `(Vec<ClipMeta>, Option<SegmentId>)`. After the
   existing floor filter, also keep `seq < cursor` when present; sort descending
   (unchanged); compute `has_more = candidates.len() > limit`; `truncate(limit)`;
   the next boundary is the last (lowest) `seq` on the page when `has_more`, else
   `None`. Map to `ClipMeta` as today (durations computed only for the page).
   Replace `const MAX_CLIPS` with `DEFAULT_LIMIT` / `MAX_LIMIT`.

3. **No router signature change** -- `src/lib.rs#app` keeps
   `.route("/v1/clips", get(clips::list_clips))`; axum injects the new `Query`
   extractor automatically.

Note (efficiency, intentionally not addressed now): each page still
`read_dir`s + sorts the whole rec dir; only the duration work is bounded by
`limit`. That matches the existing interim approach; ADR 03's in-memory sorted
index is the eventual optimization and is out of scope for the flat layout.

## App changes (`app/DanCam/DanCam/`)

`Clip.id` *is* the segment `seq`, and `ClipsFeature.merged(existing:incoming:)`
already dedupes by `id` and re-sorts descending, so an older (lower-`id`) page
appended through the same merge sinks to the bottom while live `clip_finalized`
clips rise to the top -- no special-casing.

1. **`Networking/ClipsClient.swift`** -- change `fetch` to
   `@Sendable (_ cursor: String?) async throws -> ClipsResponse`. In `live`, when
   `cursor != nil`, build the URL with
   `baseURL.appending(path: "v1/clips").appending(queryItems: [URLQueryItem(name:
   "cursor", value: cursor)])`; with no cursor keep the bare path. The query flows
   to the request line automatically via
   `Networking/HTTP/HTTPRequestEncoder.swift#requestPath` (already appends a URL's
   query) -- no transport changes. Update `noop`. The client sends only `cursor`;
   it relies on the server's `DEFAULT_LIMIT`.

2. **`Features/Clips/ClipsFeature.swift`**
   - **State:** add `var nextCursor: String?`, `var isPaging = false`, and
     `var loadEpoch = 0` (a monotonic pagination-frontier generation).
   - **Action:** add `case loadMore` and `case pageResponse(epoch: Int,
     Result<ClipsResponse, ClipsError>)` -- the response carries the epoch it was
     issued under so a superseded page is discarded instead of moving the cursor.
   - **Pagination-frontier rule (the subtle part -- must stay gapless across
     reconnects):** the Pi keeps recording while the app is offline, so a
     reconnect's head load can return brand-new newest clips that do not connect to
     a pre-gap deep cursor. *Preserving* that cursor would skip the middle (e.g.
     cursor `401`, clips `501..700` finalize offline, reconnect head returns
     `700..601`; a preserved `401` makes `loadMore` jump to `<401` and `501..600`
     are never fetched). So **every successful head load resets the frontier**, and
     stale page responses are dropped:
     - `.clipsResponse(.success(r))` (any head load -- `.load`/`.refresh`,
       including every reconnect snapshot): `state.clips = merged(existing,
       r.clips)`; `status = .idle`; set `state.nextCursor = r.nextCursor`
       **unconditionally**; `state.loadEpoch += 1`; `state.isPaging = false`; and
       emit `.cancel(id: "clips-page")` to abandon any in-flight older-page fetch.
       `merged` keeps the already-accumulated older clips visible; the reset cursor
       means a later `loadMore` re-walks from the new head down and `merged` dedupes
       the overlap. The redundant re-fetch is bounded by how far the user had
       scrolled and happens lazily only as they scroll back through it -- the cost
       the earlier "preserve the deep cursor" idea tried to save, traded back for
       correctness.
     - `.loadMore`: `guard let cursor = state.nextCursor, !state.isPaging else {
       return .none }`; set `isPaging = true`; run a page fetch under a *distinct*
       effect id `"clips-page"` (must not share `"clips-fetch"`, whose
       `cancelInFlight: true` would otherwise cancel an in-flight head load and vice
       versa), capturing `state.loadEpoch` and threading it into `pageResponse`.
     - `.pageResponse(epoch, .success(r))`: `guard epoch == state.loadEpoch else {
       return .none }` -- a head load has since reset the frontier, so discard this
       stale page and do **not** touch `nextCursor`. Otherwise `state.clips =
       merged(existing, r.clips)`; `state.nextCursor = r.nextCursor`;
       `state.isPaging = false`.
     - `.pageResponse(epoch, .failure)`: `guard epoch == state.loadEpoch else {
       return .none }`; else `state.isPaging = false` (keep the list; next scroll
       retries).
     - `.onDisappear`: cancel both `"clips-fetch"` and `"clips-page"`; reset
       `state.isPaging = false`.
   - Division of guards: `isPaging` prevents *overlapping* page fetches; the
     `"clips-page"` cancel stops the in-flight fetch on a head load; `loadEpoch` is
     the deterministic backstop for the response race the cancel cannot win (a page
     task that already completed and enqueued its `pageResponse` before the cancel
     -- the epoch check drops it so it cannot overwrite the fresh head cursor).
     Generalize `fetchEffect` to take the cursor; add a sibling
     `pageEffect(cursor:epoch:)`.

3. **`Features/Home/HomeViewController.swift`** -- add
   `tableView(_:willDisplay:forRowAt:)` (the delegate already conforms to
   `UITableViewDelegate`; no scroll hook exists yet). When the row about to display
   is within the last few rows and is a `.finished` `HomeRow` (the live row is
   always index 0, skip it), `store.send(.clips(.loadMore))`. `AppFeature.reduce`'s
   `.clips(let action)` arm forwards it to `ClipsFeature.reduce`; the reducer guard
   makes repeated sends cheap no-ops. The home "Recent clips" list thus becomes a
   lazy-paging browse; a dedicated full-screen browse with date sections stays a
   future deepening (out of scope).

Note (pre-existing, not introduced here): the app never removes clips from the
list (`merged` only adds/updates), so a GC'd older clip can linger as a stale row
and 404 on pull (already handled by the pull client). Listing-driven pruning is
out of scope.

## Docs (same change -- ADR discipline is append-only)

- **ADR 02** `02-2026-06-22-app-pi-transport-and-api.md` (**Clips** section):
  append a dated note recording that the listing now realizes descending-`seq`
  cursor pagination (`limit` + `cursor` + populated `next_cursor`), and that the
  still-deferred `from`/`to`/`order` params are **rejected with `400`** (not
  silently ignored) until `moss` implements wall-clock filtering. Do not rewrite
  the `fern` `next_cursor:null` note; supersede it with the new note.
- **ADR 03** `03-2026-06-23-storage-ring-buffer-incident-lock.md#Index, Listing,
  And Rebuild`: add a short note (mirroring the existing 2026-06-29 `dur_ms` note)
  that the seq-cursor paging is realized early for the interim flat layout, with
  the whole-dir scan-and-sort still standing in for the in-memory index.
- **Roadmap** `docs/roadmap.md` (swoop `lime`): add an item for "Pi paginates
  `/v1/clips` by descending `seq`; app pages older clips in on scroll."
- **README:** no change (nothing about Pi provisioning / onboard state changes).

## Tests

**Pi unit (`src/clips.rs` `mod tests`):**
- `read_finished_clips` (via `read_finished_clips_for_test`, extended to pass an
  already-resolved `cursor`/`limit`; existing call sites pass `None` / a limit
  above the fixture count) -- tests use resolved limits only, no clamp policy here:
  - A page returns at most `limit`, newest-first, with the next boundary = the
    lowest `seq` returned when more remain.
  - Following the returned boundary yields the strictly-older page with no overlap
    and no gap; the union over pages covers every finished segment exactly once.
  - The terminal page returns a `None` boundary.
  - Keyset stability: writing a new higher-`seq` segment does not shift a page
    fetched with a fixed cursor.
  - The floor still excludes the open/reserved tail on every page.
- `resolve_limit` (pure, no files) -- the clamp matrix lives here: `None ->
  DEFAULT_LIMIT` (100), `Some(0) -> 1`, `Some(MAX_LIMIT + 1) -> MAX_LIMIT`
  (101 -> 100), an in-range value (e.g. `Some(50)`) passes through. `DEFAULT_LIMIT`
  and `MAX_LIMIT` are equal, so the `None` and `MAX_LIMIT + 1` cases both resolve to
  100 but through different branches (`unwrap_or` default vs `.clamp` upper bound),
  so both stay meaningful. The upper clamp is not worth proving at the route -- it
  would need >`MAX_LIMIT` (101) fixture files for a single assertion -- so it is
  proved here as a unit instead.

**Pi integration (`tests/clips.rs`,** `StubBackend` + `oneshot`, `Host` header,
`response_json`):
- `GET /v1/clips?limit=2` on a >2-file dir returns 2 newest and a non-null
  `next_cursor`; `GET /v1/clips?cursor=<that>` returns the next 2; the final page
  has `next_cursor: null`.
- `?limit=0` clamps to 1 (returns a single newest clip) -- the route honors
  `resolve_limit`'s lower bound end-to-end.
- Rejections, all `400`: malformed `?cursor=abc`; `?limit=abc` (axum Query parse);
  `?from=0`; `?to=0`; `?order=asc`. `?order=desc` is accepted (`200`, default
  behavior).
- The existing two `next_cursor == Null` assertions stay valid for a small dir
  (< `DEFAULT_LIMIT` files -> single page), so the no-pagination path is unchanged.

**App (`DanCamTests`,** Swift Testing + `TestStore`; extend
`Support/CameraSamples.swift#clipsResponse` to take a `nextCursor`):
- `ClipsClientTests`: split the exact-request-line assertion into a no-cursor case
  (`GET /v1/clips HTTP/1.1`) and a with-cursor case
  (`GET /v1/clips?cursor=42 HTTP/1.1`); keep the decode case asserting
  `nextCursor`. Update the `fetch()` call sites for the new signature.
- `ClipsFeatureTests`: initial `.load` seeds `nextCursor`; `loadMore` fetches the
  next page, appends older clips, advances `nextCursor`, and a terminal page nils
  it; `loadMore` is a no-op when `nextCursor == nil` or `isPaging`.
  - **Reconnect-gap test (replaces the dropped "head load preserves cursor"
    test):** load the head and `loadMore` down to a deep cursor, then deliver a
    fresh head load whose newest clips are higher than anything seen (clips that
    finalized during an offline gap). Assert the frontier resets to the new head's
    `nextCursor` and that the next `loadMore` fetches the *missing middle* page
    (no skipped seqs), with `merged` deduping the overlap.
  - **Stale-page test:** start a `loadMore`, deliver a head load before its
    `pageResponse`, then deliver the now stale-epoch `pageResponse`; assert it is
    discarded and `nextCursor` keeps the head value.
  - Update the two `ClipsClient(fetch:)` stub closures and `ClipsFetchQueue` for
    the cursor arg.
- `AppFeatureTests`: update the two `ClipsClient(fetch:)` stubs for the new
  signature; add a `.clips(.loadMore)` path assertion.

## Verification (end-to-end against the mock)

1. `just raspi-mock` (writes real `seg_NNNNN.ts` via `MockBackend`); let it
   accumulate, or pre-seed `DANCAM_REC_DIR` with > `DEFAULT_LIMIT` dummy segments.
2. `curl -s 'http://127.0.0.1:8080/v1/clips?limit=5'` -> 5 newest, non-null
   `next_cursor` (if the `host_allowlist` middleware returns `421`, resend with the
   `Host` header it expects -- the integration tests use `localhost:8080`).
   Re-`curl` with `?cursor=<next_cursor>` and walk pages to the end (final page null
   cursor); confirm the union covers every `seg_*.ts` on disk and pages do not
   overlap. Confirm the `400`s (`?cursor=abc`, `?from=0`, `?order=asc`) and that
   `?limit=0` returns exactly one clip.
3. `just raspi-test` (or the crate's `cargo test`) for the Rust unit + integration
   tests.
4. App: run the unit tests (`just app-test` / Xcode). Then run the app against the
   mock with > `DEFAULT_LIMIT` segments, scroll the home "Recent clips" list to the
   bottom, and confirm older clips page in (and tap-to-play still works on a paged
   clip). Then exercise the reconnect gap with the mock left **running** (it keeps
   writing a new `seg_*.ts` every `DANCAM_MOCK_SEGMENT_SECS`): scroll deep, then
   force the *app* to drop and re-establish its link to the Pi -- interrupt the
   app's connection (simulator network toggle, or background then foreground) long
   enough that several new higher-`seq` segments finalize during the offline window
   -- so the reconnect snapshot fires a fresh head load. Confirm the already-loaded
   clips stay visible and continued scrolling fills the new middle with no skipped
   segments.

## Out of scope / deferred

- `from`/`to` wall-clock window *filtering* and `order=asc` *behavior* (-> `moss` /
  no consumer); the params are modeled and `400`-rejected now, just not implemented.
- ADR 03's in-memory sorted segment index (the whole-dir scan-per-page stays).
- A dedicated full-screen clips-browse UI with date sections / jump-to-date.
- Listing-driven pruning of GC'd clips from the app's in-memory list.
- The sibling findings in the same review lane (E-01 seq width, E-03 IO->404,
  E-04 PTS wrap, E-05 416 vs 200, E-06 listing TOCTOU, E-07 duration cache) -- each
  is its own change.
