# ADR: client-side clip thumbnails

- **Status:** Accepted
- **Date:** 2026-07-01
- **Owner:** app
- **Related:** supersedes the thumbnail portions of `../../../raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md`
  (the `GET /v1/clips/{id}/thumb` endpoint) and
  [Pi storage](../../../docs/design/pi/storage.md)
  (the cached `seg-<seq>.jpg` first-keyframe thumbnails and `openThumb`); builds on
  `13-2026-07-01-durable-clip-cache.md` (the cached MP4 is the free tier) and reuses the
  HTTP primitives from `12-2026-06-30-bounded-resilient-clip-pull.md`;
  `../../../docs/roadmap.md` (swoop `lime`).

## Context

The Home clip list renders each finished clip as a plain text row. We want a first-frame
thumbnail on every row so the list is scannable at a glance.

The recorded Pi API design already specced a server-side answer: a
`GET /v1/clips/{id}/thumb` endpoint backed by a cached `seg-<seq>.jpg` first-keyframe
thumbnail per segment, generated off the storage coordinator and regenerable on miss
(raspi ADR 02 and the Pi storage design). Those were best guesses written before hardware;
the roadmap left a
scope-fence note to revisit if an iPhone-side approach replaced the Pi endpoint.

Deciding this now, with real code, the client-side approach is clearly better.

## Decision

Generate thumbnails **on the iPhone**, not the Pi. Do **not** build the Pi `/thumb`
endpoint or the cached `seg-<seq>.jpg` thumbnails.

A view-driven, injected `ThumbnailLoader` service resolves each row's first-frame image
through a cache-first, three-tier pipeline, keyed by `(clip.id, canonicalized clip.etag)`:

1. **In-memory** (`NSCache`) hit -> return immediately.
2. **Disk thumb cache** hit (`thumb-<id>-<token>.jpg`, its own `Caches/thumbnails/` root)
   -> decode + return.
3. **Free tier:** if the clip's full MP4 is already cached (the clip was watched -- ADR 13),
   decode its first frame with `AVAssetImageGenerator`. **No network.**
4. **Prefix tier (network):** ranged `GET` the first ~2 MB of `v1/clips/{id}`, **validating
   the response `ETag` octet-equals `httpEntityTag(clip.etag)`** before use, remux the
   prefix, and decode the first frame.

Tiers 3/4 persist the result to the disk + memory caches. Work is visibility-scoped
(driven by `cellForRow` + prefetch look-ahead, cancelled when Home goes offscreen or a row
scrolls away), single-flighted by `(id, etag)`, and bounded to `maxConcurrent = 3` around
the network/decode tiers so a 500-clip list cannot stampede the shared 2.4 GHz link.

### Why client-side

- **SD I/O / wear.** Caching `seg.jpg` on the Pi adds small-file writes and metadata churn
  to the exact card we protect for crash-safe recording. Client-side does **zero Pi
  writes** -- it only ranged-*reads* a small prefix of the already-stored `.ts` (reads do
  not wear NAND), and once a thumbnail is cached on the phone the clip is never re-pulled,
  so steady-state Pi read load trends to zero.
- **Keep the Pi dumb.** No new Pi dependency -- no ffmpeg route, no image crate, no
  thumbnail regeneration path in the storage coordinator.
- **Faithful frame.** The true 1080p 16:9 first frame, decoded on the phone where iteration
  is fast.
- **Bandwidth is small.** Only the first I-frame is needed. At 1080p30 / 10 Mbps / 1 s GOP
  that is a few hundred KB; we fetch a fixed ~2 MB prefix (one GOP + margin, single
  round-trip) -- about 5% of the ~38 MB clip, once per clip, then cached forever. Clips the
  user already watched cost **0 bytes** (decoded from the cached MP4).

### Validator guard

The prefix bytes must be *proven* to belong to the `(id, etag)` the cache is keyed on before
they are decoded or cached: `id` alone is not the cache identity -- `etag` (`{seq}-{bytes}`)
is the representation boundary, and a stale list row could otherwise cache the wrong frame
under a key a later correct pull then trusts. `fetchPrefix` therefore sends a plain ranged
`GET` (never `If-Range`, whose mismatch returns a full `200` and defeats the point) and
requires the response `ETag` to octet-equal `httpEntityTag(expectedETag)` (and, for a `206`,
that the range starts at byte 0). A missing or mismatched validator throws; the cell keeps
its placeholder and nothing is cached.

## Consequences

Easy:

- Zero Pi writes and no new Pi code; the Pi stays a dumb capture/serve unit.
- Watched clips are free (free tier), and every generated thumbnail is cached on disk, so
  relaunch shows thumbnails instantly.
- The prefix client reuses the existing HTTP primitives (`HTTPRequestEncoder`,
  `NWByteStream`, `HTTPResponseHeadParser`, `HTTPBodyDecoder`) and the remux/decode path
  already proven for clip playback.

Hard or risky:

- Not-yet-watched clips cost one ~2 MB ranged read each (retried once at ~4 MB on a decode
  failure, then a placeholder). This is bounded by `maxConcurrent` and visibility scoping,
  but it does put transient read load on the Pi and the shared link during first browse.
- Thumbnail decode + remux runs on the device (off-main via `@concurrent`); a very long
  list scrolled fast leans on the concurrency gate + single-flight + prefetch cancellation
  to stay honest.

## Alternatives considered

- **Pi-generated `GET /v1/clips/{id}/thumb` + cached `seg-<seq>.jpg` (the recorded ADR 02/03
  design).** Rejected: it writes small files to the crash-safety card, adds a Pi
  image/ffmpeg dependency and a regeneration path, and buys nothing the client-side pipeline
  does not already give -- the phone has (or cheaply fetches) the bytes and decodes the true
  frame itself. Superseded by this ADR.
- **256 KB probe + conditional extend** to cut typical prefix bytes ~4x. Deferred: the fixed
  2 MB single round-trip is simpler and a 256 KB probe cannot hold a 1080p IDR; revisit if
  first-browse bandwidth becomes a problem.
- **Eager warming after a clip pull.** Deferred: the free-tier ordering already makes a
  watched clip's thumbnail cheap on next display, with no extra state.
