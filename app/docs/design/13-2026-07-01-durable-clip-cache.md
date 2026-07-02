# ADR: durable clip cache and MP4-only viewer playback

- **Status:** Accepted
- **Date:** 2026-07-01
- **Owner:** app
- **Related:** `app/docs/design/02-2026-06-22-app-pi-transport-and-api.md`;
  `app/docs/design/07-2026-06-26-on-device-clip-remux-playback.md`;
  `app/docs/design/08-2026-06-27-progressive-fmp4-clip-playback.md`;
  `docs/roadmap.md` (swoop `lime` -- Watch recorded clips; swoop `tide` -- Export /
  share)

## Context

ADR 08 added a progressive fMP4/HLS path so the viewer could paint a first frame
while a clip pull was still running, then swap to the finalized MP4 from ADR 07.
That path carried substantial app-side machinery: incremental demuxing, streaming
H.264 access-unit assembly, fMP4 segmenting, a viewer-scoped loopback HTTP server,
progressive failure fallback, and player-item swap logic.

The measurement that motivated ADR 08 was misattributed. A 30 second clip took about
9 seconds to become watchable on the 2026-06-26 real-Pi baseline, but that delay was
the Wi-Fi pull, not the remux. The whole-file passthrough remux measured about 50 ms
on the iOS 26.5 simulator with fast-start enabled. On-device timing still needs a
fresh confirmation, but the decision holds even if device remux is 1-2 seconds:
pulling the bytes remains the visible wait, and the progressive path only buys an
early first frame at the cost of a second playback stack.

The per-viewer finalized MP4 was also temporary, so reopening the same clip re-pulled
and re-remuxed the same bytes. That is the larger user-facing problem now that remux
is cheap.

## Decision

Delete the progressive fMP4/HLS playback path. The viewer has one playback path:
pull the Pi's raw `.ts`, remux it to a fast-start passthrough MP4, commit that MP4 to
a durable on-device cache, and play the cached local file with `AVPlayer(url:)`.

Add `ClipCache` as an app dependency seam. Production stores files under
`Library/Caches/clips/`; tests can inject a noop or a temporary root. The cache is
regenerable because the Pi SD card remains the source of truth.

Cache files are keyed by clip id plus the entity tag of the bytes they contain:
`clip-<id>-<etagToken>.mp4`. `lookup` is called with the list row's raw `clip.etag`;
`insert` is called with `ClipPullResult.resolvedETag`, the final validator carried by
the pulled bytes. This matters when a ranged pull receives a mid-transfer `200` and
rewrites the file from a new representation: the cache stores the MP4 under the new
validator, not under the stale list etag.

The two validators can use different wire spellings for the same value. The list etag
is raw and unquoted; the pull result tracks the Pi's quoted `ETag` header. A single
`etagToken` canonicalizes both spellings by stripping a leading `W/` and surrounding
double quotes before encoding. The same validator therefore hits regardless of
quoting, while a genuinely different validator misses and cannot serve old bytes for
a reused clip id.

The cache directory is its own index:

- file existence answers `isCached`;
- file size feeds a total byte budget;
- `modificationDate` is the LRU signal;
- cache hits touch `modificationDate`;
- insert sweeps stale-etag files for the same clip id;
- eviction deletes oldest cache files until under budget, excluding the just-inserted
  file so a single over-budget clip is still kept;
- a `.v<N>` sentinel wipes the directory on the next cache operation when the source
  version changes.

Viewer states collapse to pulling progress, preparing, playing, and failed. Navigating
away cancels the pull/remux task and deletes temp artifacts; committed cache files
survive. Terminal pull/remux/cache-insert failures show an error card with Retry.

Clip viewer teardown is scoped to actual removal: pop/removal via
`didMove(toParent: nil)` and `deinit` cancel pull/remux work, delete temp artifacts,
delete share clones, and detach the embedded player. Transient disappearances do not
tear down the viewer. AVKit fullscreen from an embedded `AVPlayerViewController`
fires the container's `viewWillDisappear`, so tying teardown to disappearance
destroys the player mid-fullscreen. The viewer uses `AVPlayerViewControllerDelegate`
for explicit fullscreen enter/exit state and diagnostics instead.

The viewer still observes `AVPlayerItem.status`. A cache-hit playback failure self-heals
once by re-pulling, covering a purged or unreadable `Library/Caches` file. A post-remux
playback failure surfaces as failed instead of looping, because re-pulling the same
bytes would reproduce the same artifact.

The cached fast-start MP4 is the export artifact for swoop `tide`.

Format assumptions remain the narrow ADR 07 scope: H.264-only, video-only, no audio,
and one finished segment per clip. HEVC, audio, multi-track clips, or timeline stitching
must come with a new ADR for this path.

## Consequences

Easy:

- Reopening a cached clip is instant and does not spend another 38 MB pull.
- The app loses the loopback HTTP server, local HLS playlist, fMP4 segmenter,
  streaming H.264 assembler, and progressive fallback state machine.
- Playback and future export share one MP4 artifact.
- The Pi wire contract is unchanged: it still serves raw `.ts` bytes with `Range`.

Hard or risky:

- The viewer no longer paints an early first frame while the pull is still running.
  The wait UI must therefore stay honest: determinate pull progress, then a short
  "Preparing" phase.
- Cache correctness depends on forwarding the pull's resolved validator into
  `ClipCache.insert`, not the list etag.
- `Library/Caches` may be purged by the OS, so lookup must be filesystem-based and
  playback must tolerate a missing or unreadable cached file.
- The 500 MB budget is a tunable default, not a product commitment.

Mitigations:

- `ClipCache` tests cover direct-root storage, quote canonicalization, different-etag
  misses, move semantics, mtime-LRU eviction, touch-on-hit, stray-file reconciliation,
  missing-file lookup, and version-sentinel wipe.
- Viewer tests cover cache hits without pull, miss -> pull -> remux -> insert -> play,
  forwarding `resolvedETag`, temp cleanup on remux/cache failures and nav-away, Retry,
  playback-failure routing, non-removal disappearance preserving the player, fullscreen
  round-trip state, and removal detaching the player.
- `ClipPullClient` tests pin that normal completion reports the quoted list validator
  and a mid-pull representation restart reports the new quoted response `ETag`.

## Alternatives considered

- **Keep progressive fMP4/HLS.** Rejected: the cheap remux removes its motivation, and
  it never shortened the pull.
- **Persist a cache index.** Rejected: the directory already contains all needed state,
  and filesystem truth self-reconciles after OS cache purges.
- **Resume partial pulls across viewer opens.** Rejected for now: it creates another
  on-disk lifecycle for marginal value on a roughly 5-9 second pull.
- **Key only by clip id.** Rejected: segment ids can be reused after an SD reformat or
  fresh Pi, which would serve stale video.
- **Skip cache on validator restart.** Rejected: keying by the resolved etag caches
  the changed representation correctly and replays it once the list refreshes.
