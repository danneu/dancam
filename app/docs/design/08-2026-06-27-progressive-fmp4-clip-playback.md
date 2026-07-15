# ADR: progressive fMP4 clip playback

- **Status:** Superseded by app/docs/design/13-2026-07-01-durable-clip-cache.md
- **Date:** 2026-06-27
- **Owner:** app
- **Related:** `app/docs/design/07-2026-06-26-on-device-clip-remux-playback.md`;
  the [transport boundary](../../../docs/design/boundary/transport.md);
  `raspi/docs/design/01-2026-06-22-crash-safe-recording.md`;
  `docs/roadmap.md` (swoop `lime` -- Watch recorded clips)

## Context

ADR 07 moved clip playback from a single-segment local TS HLS playlist to a
finished on-device MP4 remux. That fixed scrubbing, but it also made playback
strictly sequential: the app pulls the whole `.ts`, remuxes the whole `.ts` to
MP4, and only then starts `AVPlayer`.

On the 2026-06-26 real-Pi baseline, a current clip took about 9 seconds before
the first frame was watchable. That delay is visible to the user and will grow
on slower 2.4 GHz links. The Pi should still record crash-safe MPEG-TS and serve
raw clip bytes with `Range`; moving remux or streaming work to the Pi would add
CPU, storage churn, and failure modes to the recording unit.

The prior problem was not localhost HLS itself. It was the representation: one
large TS media segment with placeholder timing gives AVPlayer poor seek anchors.
The now-deleted `LoopbackHLSServer` from commit `b384759` already served
cleartext loopback HLS successfully in this app, so loopback transport and ATS
are not the blocker. This ADR narrows the new server to fragmented MP4 segments
with exact durations, and retains the finalized MP4 as the durable
representation.

## Decision

Generate fragmented MP4 while the `.ts` pull is still in progress and serve it
to AVPlayer through a local HLS EVENT playlist on loopback. When the pull
completes, always run the existing whole-file remuxer to produce a normal
front-`moov` MP4, then swap AVPlayer to that MP4 for precise scrubbing, cache,
and future export. The progressive path is additive: if it fails or never
produces a first playable fragment, the viewer falls back to today's
pull-then-remux path.

The progressive pipeline is:

1. `ClipPullClient` writes the incoming `.ts` bytes to a temp file and emits
   `.opened(fileURL:)`, `.progress(bytesWritten:)`, `.restarted`, and
   `.completed`.
2. The progressive segmenter reads only bytes known to be durable on disk,
   incrementally demuxes TS, assembles H.264 access units, and feeds an
   `AVAssetWriter` configured for HLS-compatible fragmented MP4.
3. The writer emits one initialization segment and media segments flushed only
   at IDR boundaries, so each media segment starts on a sync sample.
4. A viewer-scoped loopback HLS server exposes `p.m3u8`, `init.mp4`, and
   `segN.m4s` from 127.0.0.1 / `localhost`.
5. AVPlayer opens the local EVENT playlist as soon as the init segment and first
   media segment exist.
6. After the pull completes, the finalizer writes the durable MP4 and the viewer
   swaps to it, preserving playback time when possible.

Hard server and playback requirements:

- Bind **only** to loopback (127.0.0.1 / `localhost`); never `0.0.0.0`.
- Server lifetime **scoped to the viewer/session**; torn down on swap and on
  dismiss.
- Playlist `#EXTINF` durations come from **`AVAssetSegmentReport`**, not
  guessed.
- `flushSegment()` **only at IDR boundaries** (one segment per GOP, each
  starting on a sync sample).
- Once the full clip is available, **switch to / cache a normal finalized MP4**
  for scrubbing and export.
- **Write a new ADR** (08) superseding/amending ADR 07; do not quietly
  reintroduce the server. The ADR note must be narrow: the prior problem was
  single-segment TS HLS, not localhost HLS itself.

The HLS playlist is a single-rendition media playlist, not a master playlist.
While pulling it is `#EXT-X-PLAYLIST-TYPE:EVENT`; when segmentation finishes it
gets `#EXT-X-ENDLIST`. `#EXT-X-TARGETDURATION` is frozen when the first media
segment is appended and is never rewritten. If a later segment's reported
duration would round above that frozen target duration, the progressive attempt
fails and the finalized MP4 path continues. A missing, non-numeric, or
non-positive `AVAssetSegmentReport` duration is also a progressive failure; the
app never publishes a guessed `#EXTINF`.

All loopback server state is confined to one serial domain: playlist text, route
map, media segment indices, and finish state. The AVAssetWriter segment delegate
may fire off the segmenting thread, so it copies segment data and hands it to
the server's serial domain before publication. The blocking demux -> assemble
-> writer append pipeline runs on a separate dedicated serial `DispatchQueue`,
not on the MainActor, not on a Swift actor, and not in a detached task.

A `ClipPullEvent.restarted` is terminal for the progressive attempt. A
validator-changing HTTP 200 truncates and rewrites the temp TS file; an
append-only EVENT playlist cannot safely mix segments from two representations
or rewrite already-served media. The pull still continues from zero and the
always-on finalizer produces the durable MP4 from the corrected file.

The viewer owns AVPlayer and the state machine. The progressive segmenter emits
a local playlist URL, not an `AVPlayerItem`. Once the finalizer swaps to the
durable MP4, the viewer cancels the segmenter and ignores any late
`firstPlayableReady` event so a slow first GOP cannot reattach a torn-down
playlist over a good MP4.

## Consequences

Easy:

- First frame can arrive before the whole clip is downloaded and remuxed.
- AVPlayer still never talks to the Pi. It talks only to localhost media.
- The Pi remains unchanged: crash-safe TS recording, raw TS clip serving, and
  resumable `Range` pulls stay the source of truth.
- The durable artifact remains a normal MP4, preserving the ADR 07 direction for
  scrubbing and future export/share work.

Hard or risky:

- The app now owns a progressive media pipeline in addition to the finalizer:
  incremental TS demuxing, streaming H.264 assembly, fMP4 segmenting, local HLS
  serving, and viewer swap orchestration.
- AVAssetWriter segment callbacks and HTTP serving cross thread boundaries.
  Segment publication must be copied and serialized.
- Time-to-first-frame is bounded by the first GOP, because fMP4 segments are
  flushed only at IDR boundaries. If the Pi keyframe interval is too long, the
  better fix is the raspi keyframe-interval lever, not app-side sub-GOP slicing.
- The finalizer intentionally parses the TS a second time. That duplicates some
  CPU work, but keeps the durable MP4 on the already-tested whole-file path.
- 2026-06-30 update: the finalizer and progressive path now share the tolerant
  `IncrementalTSDemuxer` implementation. The finalizer tolerates power-cut
  truncation and mid-stream garbage, drops only sub-188-byte residual tails, and
  emits the trailing access unit as-is so the durable MP4 can play up to the
  cut. A blanket trailing-unit drop was rejected because clean clips have no
  reliable in-band "this was truncated" signal, so it would discard the last
  good frame of every clean clip. The deferred "single parse feeding both"
  alternative remains deferred; only the demux stage is unified, while the
  assemble/write passes stay independent.
- 2026-06-30 update: the shared `IncrementalTSDemuxer` is now fully fail-soft
  per packet, not just on alignment breaks and tail truncation. The parser is a
  total function (`processPacket -> PacketOutcome`); any sync-aligned per-packet
  anomaly is skipped rather than thrown, and `append` no longer throws.
  Recovery is PES-localized: exactly one PES is dropped per corruption event --
  normally the damaged frame, with complete neighbors (including the SPS/PPS
  carrier) preserved. **PES DTS ordering is the trust check** that closes the
  timestamp-value-corruption abort path: a marker-valid value flip leaves the
  header well-formed, so a one-frame-lookahead ordering check at the PES
  boundary is the only thing that can catch it. PES marker/prefix validation is
  kept only as a cheap syntax gate, and both assembler DTS guards
  (`StreamingH264AccessUnitAssembler` and the batch `assemble`) are left
  unchanged as defense-in-depth, since the demuxer now guarantees a monotonic
  PES DTS stream. One documented residual: a spike-up on the very first PES
  (before any baseline exists) may only ever keep the held frame, so it degrades
  toward first-frame-only, but it never aborts and still emits PES#0's SPS/PPS;
  relocating the trust check into the streaming assembler (where
  `latchParameterSets` precedes the DTS guard) is the recorded escape hatch that
  would make parameter-set survival unconditional. A small in-band downward DTS
  flip is the one case where lookahead-of-one may drop a good neighbor instead
  of the corrupt frame -- still exactly one PES, still monotonic, never an abort.
  Minimal dropped-packet telemetry was added (count + one-shot `.notice`).
  Pre-latch PAT/PMT corruption drops video only until the next good table: the
  table self-heals, the gap's video does not. Measured on the fixture, a corrupt
  initial PMT @376 re-latches at the next PMT @6392, the finalizer recovers a
  suffix from PES#3, and the streaming path recovers only at the next in-band
  SPS/PPS carrier (PES#250) -- bounded, not total loss, because this stream
  repeats SPS/PPS every 250 PES. Multi-packet-PSI reassembly and
  continuity-counter tracking stay deferred; the new `discardCurrentPES()` and
  `lastFinishedDTS` PES-lifecycle seams are what a continuity-counter check will
  reuse.
- 2026-06-30 update: both H.264 assemblers now **drop** any access unit whose DTS
  does not strictly increase, rather than throwing `ClipRemuxError.invalidH264` and
  failing the whole clip -- the last un-softened "one anomaly fails the clip" site.
  They share one primitive (`H264AccessUnitAssembler.strictlyIncreasingGap`): emit the
  held unit on a positive gap, drop and log-once otherwise. The batch `assemble` no
  longer pre-sorts packets by DTS; for an in-contract stream decode order already is
  DTS order (the fixture parity test proves it), and dropping the sort makes a backward
  step visible to the drop policy instead of silently reordering it into a single
  ~26.5h-duration sample. A 33-bit PTS/DTS wrap needs no special 2^33 arithmetic: it is
  one trigger of the generic discontinuity policy, so the durable finalizer and the
  progressive path both truncate at the discontinuity and stay consistent (the
  finalizer writes a valid MP4 up to the cut; the progressive playlist finalizes up to
  the cut on pull completion). The per-clip strictly-increasing-DTS contract this
  relies on is owned by `raspi/docs/design/01-2026-06-22-crash-safe-recording.md`.
- 2026-07-01 update: HTTP response writes are now non-blocking and event-driven. A
  response drains via an inline write on the serial queue, falling back to a
  per-connection `DispatchSource.makeWriteSource` **targeting that same serial queue**
  only when the socket send buffer is full; the client socket is never flipped to
  blocking. A slow or stuck loopback reader therefore can no longer stall segment
  publication, playlist updates, `checkForFailure`, or teardown, all of which share
  that one queue -- the blocking write was the lone exception to the file's otherwise
  non-blocking socket model. Because this adds a second fd-backed source per
  connection, the per-connection file descriptor is now closed only from each source's
  cancellation handler (read and write), once libdispatch has released the handle
  (`dispatch/source.h`); this removes the prior close-before-cancel-handler fd-reuse
  race that inline `Darwin.close` after `cancel()` risked. A broken client connection
  stays connection-local (it closes that connection, never fails the server).

- Progressive failures never touch the source TS, finalizer task, or durable MP4
  path. They only tear down the progressive item and local HLS resources.
- Segment durations are validated from `AVAssetSegmentReport`; invalid timing
  falls back rather than publishing a bad playlist.
- The server is viewer-scoped and deletes its temporary fMP4 work directory on
  swap, dismiss, or failure.
- Tests cover parser equivalence, segment duration publication, frozen target
  duration behavior, HTTP `GET`/`HEAD`/`Range`, non-blocking serving under loopback
  reader backpressure (large-body byte integrity, slow-drain byte integrity, and
  publication and teardown staying responsive while a reader stalls) with a broken
  client connection staying connection-local, progressive fallback paths, late
  first-playable suppression, and swap continuity.

## Alternatives considered

- **Resource-loader HLS.** Rejected: AVPlayer rejects raw HLS media segment bytes
  from `AVAssetResourceLoaderDelegate` with a custom-url redirect failure.
- **Single growing fMP4 resource loader.** Rejected: AVPlayer behavior is fragile
  when the final resource length is unknown and still growing.
- **`AVSampleBufferDisplayLayer`.** Rejected: it would bypass the AVPlayer
  transport and controls the viewer is built around, and it does not solve the
  handoff to a scrubbable MP4 surface.
- **Hand-rolled fMP4 box writer.** Deferred as an escape hatch. AVAssetWriter's
  HLS segmenting API is the planned path as long as device validation keeps
  producing playable fMP4.
- **Classic faststart MP4 for early play.** Rejected for progressive playback:
  front `moov` needs complete sample tables, which are not known while the TS is
  still downloading. Faststart remains correct for the finalized MP4.
- **Single parse feeding both progressive and final writers.** Deferred. It may
  remove duplicate parser work later, but the first version keeps the durable MP4
  independent of the newer progressive code.
- **Remux or segment on the Pi.** Rejected: the Pi must stay focused on safe
  recording and raw clip serving.
