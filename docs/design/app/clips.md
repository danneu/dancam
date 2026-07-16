# App clip pull, playback, cache, and thumbnails

The app turns finished MPEG-TS segments on the camera into durable, scrubbable local
MP4 files. Pulling is resumable and bounded by progress, remuxing is passthrough and
fail-soft against crash-damaged input, and playback always uses one cached local file.
Clip-list thumbnails use the same phone-owned media path without adding writes or
image-generation work to the Pi.

The [transport boundary](../boundary/transport.md) owns the HTTP range contract and
the Pi's raw-TS serving behavior. [Pi recording](../pi/recording.md) owns the on-card
MPEG-TS format and timestamp invariants. [App connection](connection.md) owns the
shared socket deadlines. This page owns the app-side pull policy, remuxer, playback
cache, viewer lifecycle, and thumbnail generation.

## Authoritative clip-list recovery

`ClipsFeature` is the sole owner of clip-list sequencing. A fresh SSE snapshot grants
one opaque coverage epoch and starts a head request. The feature preserves rendered
rows and the saved browse frontier while it walks the response cursor chain far enough
to cover that frontier authoritatively. If browsing had already reached catalog end,
recovery walks to the new end. Stream failure, heartbeat timeout, or process suspension
revokes the epoch and retires the single in-flight generation before live world state
becomes unavailable. Connecting and offline states cannot issue clip-list requests.

A numeric browse frontier `F` means IDs at or above `F` have been incorporated and
IDs below it remain unseen; catalog end is a separate state. Recovery uses a temporary
cursor and never advances the browse frontier by itself. Only one user load-more demand
may authorize a full page below the saved frontier. An incident requirement authorizes
coverage only through its exact sequence; see [incident coverage planning](incidents.md#coverage-planning).

Each response is accepted only when its epoch, generation, and requested upper cursor
match the current request. A head is authoritative from its returned cursor through
the newest ID. A page is authoritative from its returned cursor up to, but excluding,
its requested cursor. The feature intersects that interval with the authorized target,
discarding overshoot clips and negative evidence below the target. Current-epoch
`clip_finalized` facts and removal tombstones win over stale list contents.

One central scheduler runs only with a fresh epoch, no in-flight request, and no page
failure. A failed head or page settles once, retains refresh, browse, and incident
goals, and pauses. A retryable heartbeat or manual refresh retains a replacement-head
goal; it resumes immediately in a fresh epoch or waits for the next snapshot after a
gap. UI navigation has no authority to cancel this process-global work.

## Raw clip boundary

The Pi remains the footage source of truth and serves one finished segment as raw
`video/mp2t` bytes from `GET /v1/clips/{id}`. It does not serve MP4, HLS playlists,
playback indexes, or thumbnails. AVPlayer never talks to the camera.

One clip is one finished, H.264-only, video-only segment. The remux path still converts
exactly one segment into one independently durable MP4 and does not support audio, HEVC,
or multiple video tracks. Incident detail may derive an ephemeral composition from
several completed MP4 artifacts for unified playback, but it does not broaden the remux
format, persist a stitched artifact, or change clip-viewer playback. Broadening those
media assumptions requires a deliberate design change on both the recording and playback
sides.

## Resumable clip pull

`ClipPullClient` streams each clip into a temporary `.ts` file. Its public event stream
reports the opened file, byte progress, representation restarts, and a completed result
that includes the validator associated with the final bytes.

The first attempt sends a plain `GET`. Once bytes are on disk, later attempts request
`Range: bytes=<offset>-` with `If-Range` set to the current quoted ETag. A `206` is
accepted only when `Content-Range` starts at the exact on-disk byte count, reaches the
representation end, and agrees with the already-known total length. A `416` completes
only when the app already has the entire expected file.

A ranged request may receive `200` when the representation changed. The app accepts
that restart only when the response carries a new ETag. It truncates and seeks the
temporary file to byte zero, replaces the resume validator, emits `.restarted`, and
writes the new representation. A ranged `200` with the same or missing validator is
malformed and terminal; accepting it would permit an endless truncate-rewrite loop
that looked like forward progress.

The completed `ClipPullResult.resolvedETag` begins with the list validator and tracks
any validator change accepted from a response. It is therefore not necessarily the ETag
from the list row that opened the viewer. Downstream cache insert must use this resolved
value so restarted bytes cannot be filed under a stale identity.

### Progress-bounded retry

Retry budget follows decoded body-byte progress rather than raw attempt count:

- a connect failure, empty drop, receive-idle timeout before body bytes, or HTTP 503
  increments the consecutive-stall count;
- an attempt that writes any body bytes resets the consecutive-stall count, even when
  it later drops or times out;
- backoff is based on consecutive stalls, beginning at 250 ms and capping at 4 seconds;
- six consecutive no-progress reconnects exhaust the normal budget; and
- a separate guard stops once reconnects exceed the default ceiling of 256, bounding a
  pathological peer that advances by tiny amounts forever.

Only `503 Service Unavailable` is a rideable HTTP status. The Pi uses it for a present
but temporarily unreadable segment. `404`, every other 5xx response, malformed HTTP,
invalid range metadata, and local filesystem failures are terminal. Write, truncate,
seek, and final close failures map to `ClipPullError.file`; reconnecting cannot repair
local storage. Cancellation and every terminal failure delete the partial temp file.

`ClipPullError` carries localized messages for HTTP, malformed response, file,
transport, consecutive-stall exhaustion, and total-reconnect exhaustion. The viewer
renders those domain messages directly. Cross-viewer and cross-launch partial-file
resume are deliberately absent; validators and temporary TS bytes live only for one
pull invocation.

## Passthrough TS-to-MP4 remux

After a pull completes, `ClipRemuxer` converts the temporary MPEG-TS file into a
fast-start MP4 on the phone without re-encoding. The worker runs off the main actor and
is exposed through an injected dependency seam.

The live remuxer:

- parses 188-byte transport packets, PAT, and PMT to find the H.264 PID;
- reassembles PES payloads while carrying 90 kHz PTS and DTS;
- extracts Annex B SPS/PPS and H.264 access units;
- drops leading pictures until the first decodable keyframe;
- converts samples to AVCC length-prefixed form;
- writes compressed samples through `AVAssetWriter`, including sync-sample
  attachments; and
- enables `shouldOptimizeForNetworkUse` so the normal MP4 metadata precedes media
  data for local playback and later sharing.

The app owns this narrow parser because `AVAssetExportSession` passthrough could not
open the real TS fixture on the iOS simulator. The Pi keeps recording crash-resilient
TS; phone-only playback representation does not add CPU, storage churn, or another
failure mode to the camera unit.

### Damage tolerance

The demuxer is incremental and fail-soft. It resynchronizes after mid-stream garbage,
drops a residual tail shorter than one 188-byte packet, and emits the trailing PES
payload as-is so a power-cut segment can play up to the cut. Sync-aligned packet
anomalies are
represented as total-function outcomes and skipped rather than thrown. Recovery is
PES-localized: adaptation or header damage discards at most the affected in-flight
PES while preserving complete neighbors.

PES DTS ordering is the trust check for marker-valid timestamp corruption. A
one-frame lookahead keeps the emitted PES stream monotonic, distinguishing a spike in
the held frame from a dip in the candidate when a prior baseline exists. PAT and PMT
damage before initial latch loses video until the next good table; the table can
self-heal, but the skipped interval cannot be reconstructed. Multi-packet PSI
reassembly and continuity-counter validation are not implemented.

The H.264 assembler also requires strictly increasing DTS as defense in depth. It
does not sort packets by DTS. An equal or backward access unit, including a 33-bit
timestamp wrap, is dropped; a sustained discontinuity therefore yields a valid MP4
up to the break instead of aborting the whole clip or manufacturing a multi-hour
sample gap. Clean input emits its final access unit because there is no reliable
in-band signal that distinguishes a clean ending from every possible truncated tail.

Remux failure or cancellation deletes stale and partial MP4 outputs. The remuxer's
accepted format remains intentionally narrow and fails loudly when it cannot find
the required H.264 parameter sets, a keyframe, or usable access units.

## Durable MP4 cache

Playback has exactly one representation: a committed MP4 under
`Library/Caches/clips/`, opened directly with `AVPlayer(url:)`. A cache hit avoids both
the roughly 38 MB pull and the remux. A cache miss follows:

1. pull raw TS;
2. show a short preparing phase;
3. remux to a fast-start MP4;
4. move the MP4 into the cache under the pull's resolved validator; and
5. play that cached file.

Cache identity is `(clip id, canonical ETag)`, encoded as
`clip-<id>-<etagToken>.mp4`. `etagToken` strips an optional `W/` prefix and surrounding
quotes before filename encoding, so the raw list spelling and quoted HTTP spelling of
one validator hit the same file. A genuinely different validator misses, preventing a
reused clip id after an SD reformat or fresh Pi from showing stale footage.

The cache directory is its own index:

- file existence answers lookup;
- size contributes to the byte budget;
- modification date is the LRU signal and is touched on a hit;
- insert removes old-validator MP4s for the same clip id;
- eviction removes oldest entries until the default 500 MB budget is met, while
  preserving the just-inserted file even when one clip alone exceeds the budget; and
- a version sentinel wipes the regenerable directory on the next operation after a
  source-version change.

The cache is regenerable because the Pi SD card is the primary footage store. The
500 MB limit is a tunable default, not a product commitment.
Filesystem work runs behind a serial actor so directory enumeration, stale-version
sweeps, moves, modification-date updates, eviction, and version wipes stay off the
main actor and cannot interleave with thumbnail lookups or concurrent inserts.

## Clip viewer lifecycle

The viewer is a `@MainActor` UIKit controller with four visible phases: pulling,
preparing, playing, and failed. The initial asynchronous cache lookup, unknown-size
pulls, and preparing phase show an indeterminate spinner. Known-size pull progress
alone uses the determinate progress bar, and animation begins only after first layout.
Playing hides progress rather than displaying a misleading full bar.

Terminal pull, remux, or cache-insert failures render an error card with Retry. The
viewer observes `AVPlayerItem.status`. Failure from a cache-hit file self-heals once by
starting a fresh pull, covering an OS-purged or unreadable cache entry. Playback
failure from a newly remuxed file surfaces normally rather than looping over the same
source bytes.

Work is cancelled only when the viewer is actually removed: `didMove(toParent: nil)`
or deinitialization cancels pull/remux, deletes temporary artifacts, cancels share
preparation, and detaches the embedded player. A transient `viewWillDisappear` does
not tear down playback because AVKit fullscreen causes that callback. Explicit
`AVPlayerViewControllerDelegate` transitions record fullscreen entry and exit without
destroying the player.

Committed cache files outlive viewer dismissal. Temporary TS and pre-insert MP4 files
do not. The cached MP4 is also the source artifact for the app's separate sharing
flow.

## Client-side thumbnails

The phone generates first-frame thumbnails. The Pi has no `/thumb` route, JPEG cache,
ffmpeg thumbnail process, or thumbnail write path on the crash-safety SD card.

`ThumbnailLoader` is view-driven and injected. Each `(clip id, canonical ETag)` follows
a cache-first pipeline:

1. return an in-memory `NSCache` image;
2. decode `thumb-<id>-<etagToken>.jpg` from `Caches/thumbnails/`;
3. if the full clip MP4 is cached, decode its first frame with no network traffic; or
4. fetch a bounded TS prefix and remux/decode its first frame.

Generated images are persisted as JPEG and returned from memory on later requests.
The thumbnail cache has its own version sentinel, modification-date LRU, and 64 MB
default budget; it never shares a root with the MP4 cache because each store owns its
own namespace and version wipe.

The prefix tier sends a plain ranged `GET` for bytes starting at zero, never
`If-Range`. It accepts only `200` or `206` with a wire ETag exactly equal to
`httpEntityTag(clip.etag)`; a `206` must also start at byte zero. A missing or changed
validator returns no image and caches nothing, preventing stale row metadata from
poisoning a trusted `(id, etag)` cache key.

The default read is 2 MB, roughly one GOP plus margin. A decode failure, but not a
fetch or validator failure, retries once with 4 MB. A second decode failure leaves the
cell placeholder. Prefix work uses the same HTTP and shared byte-stream primitives as
full pulls but is a separate client because it intentionally stops before whole-file
completion.

Loads are single-flighted per identity and bounded to three concurrent generation
jobs across cached-MP4 decode and network-prefix tiers. Cell loads and prefetches carry
independent interest tokens. An entry cancelled while queued and no longer visible or
prefetched is dropped before it consumes a permit or network bytes; once running, it
finishes and warms the cache. Decode and remux work run off the main actor.

Client-side generation keeps Pi writes at zero, makes already-watched clips free, and
limits first-browse bandwidth to a small fraction of a full segment. It accepts
transient phone CPU and Pi read load in exchange for keeping image policy and cache
lifecycle out of the recorder.

## Testing obligations

Behavioral coverage protects the boundaries that can corrupt footage or mislead the
viewer:

- pull tests cover progress, exact range resume, 503 ride-through, connect and stream
  drops, receive-idle timeouts before and after progress, both exhaustion budgets,
  validator-changing restarts, malformed `200`/`206` responses, terminal statuses,
  and resolved-ETag reporting;
- demux and remux tests cover fixture playability and fast-start layout, chunk-boundary
  invariance, truncated and garbage-damaged TS, sync-aligned packet corruption,
  PAT/PMT recovery, timestamp anomalies, first-keyframe recovery, DTS discontinuity,
  and partial-output cleanup;
- cache tests cover ETag canonicalization, move semantics, stale-version misses,
  touch-on-hit LRU, budget eviction, version-sentinel reconciliation, off-main file
  work, and serialized concurrent inserts;
- viewer tests cover cache hit and miss paths, honest progress modes, resolved-ETag
  insertion, cleanup and Retry on failures, one-shot cache self-heal, non-removal
  disappearance, fullscreen round trips, and removal teardown; and
- thumbnail tests cover disk and cached-MP4 hits, exact prefix validation, single
  flight, bounded concurrency, interest cancellation, 2 MB to 4 MB decode retry,
  cache isolation, ETag canonicalization, and failure without cache poisoning.
- clip-list tests cover head and middle-page gaps, oldest-first deletion, arbitrary
  holes, saved-frontier and catalog-end recovery, response overshoot, user and incident
  authorization, failure pause, epoch interruption, finalize/removal races, late
  responses, and Home disappearance during shared recovery.

## Decision log

### 2026-07-15: Centralize pagination behind fresh coverage epochs

Head refresh, UI paging, and incident paging previously drove separate request paths.
That let a cursor response from before an SSE gap mutate the post-gap catalog, let view
disappearance cancel domain work, and treated a successful head page as authority over
history it had not covered. The app now gives clip-list sequencing to one scheduler,
tags every request with the current snapshot epoch and generation, and separates the
durable browse frontier from the cursor used to prove recovery coverage.

Refreshing only the head was rejected because missed middle-page removals remain
invisible. Letting recovery merge every page it traverses was rejected because it
silently expands browsing into unseen history. Epoch-gated interval authority keeps
positive and negative evidence tied to one coherent snapshot while explicit user and
incident goals define the only permitted lower bounds.

### 2026-06-26: Remux pulled TS into MP4 on the phone

(absorbed from app ADR 07 and its amendments, 2026-06-26)

The first viewer wrapped a finished TS file in a one-segment local HLS playlist. That
proved playback, but a placeholder duration and one segment-level seek anchor made
scrubbing stall while AVPlayer reloaded and decoded from the start. The Pi needed to
keep crash-safe MPEG-TS, but that constraint did not require the phone's closed
playback copy to remain TS.

The preferred platform gate was `AVAssetExportSession` with passthrough. The bundled
`seg_00000.ts` fixture, loaded with the MPEG-TS MIME override, failed on the iOS 26.5
simulator with `AVFoundationErrorDomain -11828` before tracks could load. The app
therefore accepted a narrow parser/writer behind `ClipRemuxer`: copy compressed H.264
samples and timing into MP4 without re-encoding, then play the local MP4 directly.
The end-to-end fixture produced playable, seekable output on simulator and a physical
iPhone.

Keeping one-segment TS HLS was rejected because it preserved poor seek behavior.
Byte-range multi-segment HLS was rejected because it required indexing work while
retaining a loopback server and a separate export remux. Pi-side remux was rejected
because playback formats should not consume recorder CPU, storage, or reliability.
Choosing the hand-rolled demuxer without first testing the platform was rejected; the
fallback became justified only after the platform gate failed.

The decision initially treated TS and MP4 as viewer-scoped temporary files. A 2026-06-27
caveat temporarily allowed progressive fMP4 playback, then the durable-cache decision
on 2026-07-01 removed that caveat and made cached MP4 the sole path again.

### 2026-06-27: Try progressive fMP4 playback during the pull

(absorbed from dead app ADR 08, 2026-06-27)

A real-Pi clip took about 9 seconds to become watchable, and that delay was initially
attributed to the sequential pull-then-remux pipeline. The experiment kept the normal
final MP4 but added an early path: incrementally demux durable TS bytes, emit fMP4
segments at IDR boundaries, publish exact `AVAssetSegmentReport` durations through a
viewer-scoped loopback HLS EVENT playlist, and swap to the final fast-start MP4 while
preserving playback time.

The server was constrained to loopback, one serial state domain, append-only media,
a target duration frozen at the first segment, and failure rather than guessed or
invalid durations. A validator-changing pull restart killed only the progressive
attempt because already-served media could not be rewritten safely. Progressive
failure never touched the TS pull or finalizer, and late first-playable events were
ignored after the final MP4 swap. Blocking demux, assembly, and writer appends ran on
a dedicated serial queue rather than the main actor or the server's state domain.

This path made first frame depend on the first GOP and added incremental assembly,
fMP4 segmenting, HTTP serving, thread-boundary publication, fallback, and player-swap
machinery. Resource-loader HLS was rejected after AVPlayer redirect failure. A single
growing fMP4 resource was rejected because final length was unknown. A sample-buffer
display layer was rejected because it bypassed the AVPlayer controls and did not solve
handoff. Classic fast-start MP4 could not start early because its complete sample
tables were not yet known. A hand-written box writer and a single parse feeding both
writers were deferred. Pi-side segmentation remained rejected.

The experiment did not pan out. Measurement later showed that Wi-Fi pull dominated
the 9 seconds while whole-file passthrough remux took about 50 ms on the simulator.
The second playback stack bought only an early frame during a still-required pull and
made repeat viewing no faster. The 2026-07-01 cache decision deleted the segmenter,
loopback server, streaming assembler, fallback, and swap state machine.

### 2026-06-30: Make final remux tolerate power-cut TS

(absorbed from the 2026-06-30 amendment to app ADR 08)

Power loss can leave the last TS segment unaligned or with a partial final PES. The
whole-file finalizer adopted the progressive path's incremental demuxer so mid-stream
garbage and a sub-packet tail no longer made the entire clip unplayable. It emits the
last assembled access unit as-is. Blanket trailing-unit removal was rejected because
clean clips carry no dependable in-band truncation marker; it would discard the last
good frame of every normal clip.

At the time, sharing only the demux stage meant the progressive and final writers
still parsed and assembled independently. That duplication disappeared when the
progressive path was deleted, but the tolerant finalizer survived.

### 2026-06-30: Make TS packet parsing fail-soft

(absorbed from the 2026-06-30 amendment to app ADR 08)

Resynchronization and tail tolerance still allowed one sync-aligned packet anomaly to
throw from the demuxer and lose the whole clip. The parser became a total function:
every packet produces parsed or skipped, and a skip localizes recovery to one PES.
PES marker and prefix checks remain cheap syntax gates, while one-frame-lookahead DTS
ordering catches a value-bit corruption that leaves marker syntax valid.

The design accepts imperfect attribution at the edge. A first-PES upward timestamp
spike has no trusted baseline; keeping the held frame avoids total loss and preserves
its SPS/PPS, but may degrade toward first-frame-only. A small downward flip can cause
lookahead to drop a good neighbor rather than the corrupt frame. Both cases remain
bounded to one PES, monotonic, and nonfatal. Initial PAT/PMT corruption loses data until
the next good table. In the measured fixture, a corrupt initial PMT at byte 376 relatched
at byte 6392; the batch finalizer recovered from PES 3, while the now-deleted streaming
path had to wait until the next in-band SPS/PPS carrier at PES 250.

One-shot notice telemetry records packet drops. Multi-packet PSI assembly and
continuity-counter checking were deferred; the PES discard and last-finished-DTS seams
were retained as their future recovery hooks.

### 2026-06-30: Degrade at DTS discontinuities

(absorbed from the 2026-06-30 amendment to app ADR 08)

The remaining assembler throw sites still failed a whole clip on an equal or backward
DTS. The batch assembler also sorted by DTS, which could hide a 33-bit wrap and create
one roughly 26.5-hour sample gap. Both then-current assemblers adopted one primitive:
emit the held access unit only across a positive DTS gap, otherwise drop and log once.
Removing the sort exposed discontinuities to that policy. Isolated corruption is
skipped; a sustained reset truncates at the break and leaves a valid artifact.

Special 33-bit wrap arithmetic was rejected because the recorder promises strictly
increasing DTS within one clip. A wrap is therefore one instance of the general
discontinuity policy, not an alternate timeline to stitch in the player.

### 2026-06-30: Bound clip retries by progress

(absorbed from app ADR 12, 2026-06-30)

The first resumable pull counted total attempts. A flaky link could advance on every
reconnect, exhaust a small fixed ceiling near completion, delete the temp file, and
force another byte-zero pull. Socket receive idleness had already moved into the
shared byte stream, so clip policy needed to distinguish a stalled attempt from a
useful but interrupted attempt.

Reconnect accounting moved to decoded body-byte progress, with typed exhaustion for
consecutive stalls and a separate generous runaway ceiling. Backoff follows the stall
counter so a progressing link does not accumulate long delays. Local file errors are
terminal, including final close where deferred I/O failure can surface. Ranged `200`
responses became valid only for a proven validator change.

A fixed attempt budget was rejected because resume is normal on the 2.4 GHz link.
Inferring progress from final file offsets was rejected because a valid representation
restart can write bytes yet end below its starting offset. A clip-local idle timer was
rejected because `NWByteStream` can cancel the real connection once for every client.
Persisting partial files after exhaustion was rejected without a cross-viewer validator
and lifecycle design.

A server that invents a new validator on every reconnect can still force repeated
byte-zero restarts. The app cannot prove intent from the wire, so the total-reconnect
ceiling is the final bound on that case.

### 2026-07-01: Ride through only temporary clip-serve failures

(absorbed from the 2026-07-01 amendment to app ADR 12)

The Pi uses HTTP 503 when a segment exists but is temporarily unreadable. Clip pull
treats only that status as a no-progress retry, so a transient failure resumes while a
persistent one exhausts the existing stall budget. `404` still means gone or not
pullable, and other 5xx responses remain genuine or permanent failures that must not
be hidden behind generic stall exhaustion.

### 2026-07-01: Keep the dead loopback server nonblocking

(absorbed from the 2026-07-01 amendment to dead app ADR 08)

Before the progressive stack was deleted, its loopback server synchronously wrote an
entire HTTP response while holding the same serial queue that owned publication,
playlist updates, failure checks, and teardown. A slow reader could park that queue.
The server was corrected to flush inline while writable and arm a same-queue dispatch
write source only on backpressure. Read and write sources closed their shared file
descriptor only from cancellation handlers, after libdispatch released it, avoiding a
close-before-handler descriptor-reuse race. A broken client remained connection-local.

This implementation is historical, but its rationale records why any future local
media server must not couple its state machine to reader drain speed.

### 2026-07-01: Replace progressive playback with a durable MP4 cache

(absorbed from app ADR 13, 2026-07-01)

The progressive design attacked the wrong delay. A 30-second clip's approximately
9-second time to first frame was almost entirely its Wi-Fi pull; whole-file remux was
about 50 ms on the simulator. Even if a physical phone took 1-2 seconds, the pull would
remain the dominant wait. Meanwhile every reopened clip repeated the expensive pull
because the final MP4 was temporary. Caching the artifact solved the larger user problem
and permitted one playback path.

The app deleted progressive fMP4/HLS and committed fast-start MP4s under
`Library/Caches/clips/`. Identity includes both clip id and validator. Insert uses the
pull's resolved ETag, not the possibly stale list value, and one canonicalizer makes
raw, weak, and quoted spellings agree. Filesystem truth replaced a separate index;
mtime became LRU, cache hits touch it, old validators are swept, a version sentinel
handles format changes, and a just-inserted over-budget clip survives eviction.

The viewer gained removal-scoped cancellation, one-shot cache playback self-heal, and
an error/Retry path. The cached MP4 became the common playback and future sharing
artifact.

Keeping progressive playback was rejected because cheap remux removed its motivation
and it never shortened the pull. A persistent cache index was rejected because the
directory self-reconciles after OS purge. Cross-viewer partial-pull resume was deferred
as another disk lifecycle for a roughly 5-9-second operation. Id-only cache keys were
rejected because ids can be reused. Skipping cache after a validator restart was
rejected because the resolved validator safely names the changed bytes.

### 2026-07-01: Generate browse thumbnails on the phone

(absorbed from app ADR 16, 2026-07-01)

The early Pi design proposed `GET /v1/clips/{id}/thumb` backed by cached
`seg-<seq>.jpg` files. With real app and hardware paths available, that meant adding
small-file writes and metadata churn to the crash-safety card, an image dependency and
regeneration path to the Pi, and contract surface the phone did not need.

The app instead adopted the memory, disk-JPEG, cached-MP4, and bounded-prefix tiers in
the current body. A watched clip costs no network bytes; a new clip reads about 2 MB,
roughly 5 percent of the normal 38 MB segment, once and then caches the result. Exact
ETag validation protects the cache identity, and the phone decodes the recorded 16:9
frame rather than a separate Pi-generated representation. Work is view-scoped,
single-flighted, cancelable before it begins, and capped at three concurrent generation
jobs.

Pi-generated JPEGs were rejected because they write to the protected card and make the
recorder own image policy. Bounded prefix reads add transient SD and link load but do
not add NAND writes, and steady-state Pi reads trend to zero after phone caching. A
256 KB probe followed by conditional extension was deferred because one 2 MB request is
simpler and a small probe may not contain a 1080p IDR. Eager thumbnail warming after a
full pull was deferred because the cached-MP4 tier already makes the next visible request
cheap without new coordination state.

### 2026-07-02: Scope viewer teardown to actual removal

(absorbed from the 2026-07-02 amendment to app ADR 13)

Using `viewWillDisappear` for cleanup destroyed the embedded player when AVKit entered
fullscreen. Teardown moved to removal and deinitialization, while the player controller
delegate records explicit fullscreen transitions. Transient disappearance now
preserves playback without weakening cleanup when navigation actually removes the
viewer.

### 2026-07-02: Move clip-cache filesystem work off the main actor

(absorbed from the 2026-07-02 amendment to app ADR 13)

The viewer is main-actor isolated, but directory enumeration, stale-ETag sweeps, moves,
LRU eviction, and version wipes can block. `ClipCache.lookup` and `insert` became async
and the live store moved behind a serial actor. The actor also prevents cache insert,
thumbnail lookup, and version-wipe filesystem operations from interleaving.

### 2026-07-02: Keep wait-state progress honest

(absorbed from the 2026-07-02 amendment to app ADR 13)

A determinate bar is meaningful only when total pull bytes are known. The cache-lookup
window, unknown-length pull, and remux/cache preparation now use an indeterminate
spinner. Known-length pulling uses the bar, animation waits for initial layout, and the
playing state hides it. The cache-lookup window remains stateless setup rather than a
new viewer-domain phase, so a cache hit transitions directly from no state to playing.
