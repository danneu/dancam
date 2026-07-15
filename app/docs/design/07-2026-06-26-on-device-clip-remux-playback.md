# ADR: on-device clip remux playback

- **Status:** Accepted
- **Date:** 2026-06-26
- **Owner:** app
- **Related:** [transport boundary](../../../docs/design/boundary/transport.md);
  `app/docs/design/08-2026-06-27-progressive-fmp4-clip-playback.md`;
  `raspi/docs/design/01-2026-06-22-crash-safe-recording.md`;
  `docs/roadmap.md` (swoop `lime` -- Watch recorded clips)

> **Note (2026-06-27):** ADR 08 extends this decision. The finalized MP4 remains
> the durable playback artifact for scrubbing, cache, and future export, but it is
> no longer the only viewer playback path while a pull is in progress. The viewer
> may now serve progressive fMP4 fragments through a viewer-scoped loopback HLS
> server bound to 127.0.0.1 for early play, then swap to the finalized MP4 when
> remuxing completes. The rejected path here was single-segment TS HLS, not
> localhost HLS itself.

> **Note (2026-07-01):** ADR 13 supersedes ADR 08 and its 2026-06-27 caveat. Remux
> to MP4 is again the sole viewer playback path: pull the raw `.ts`, remux to a
> fast-start MP4, store it in the durable `Library/Caches/clips` cache, and play that
> local file directly with `AVPlayer(url:)`. The cache also supersedes this ADR's
> "remux is currently temporary per viewer" consequence; committed cache files survive
> viewer dismissal and become the future export artifact.

## Context

The app originally played a pulled clip by wrapping the finished `.ts` file in a
single-segment local HLS VOD playlist served from a loopback HTTP server. That proved
the first watch path, but it is the wrong playback representation: a single MPEG-TS
segment gives AVPlayer only a segment-level seek anchor, and the generated playlist
used a placeholder duration. Scrubbing could therefore stall while AVPlayer reloaded
and decoded from the start of the TS.

The Pi still needs MPEG-TS while recording because a car can cut power mid-write.
That crash-safety constraint applies on the camera unit, not after the app has pulled
a closed clip. On the phone, the playback copy can be represented as MP4 without
weakening the Pi recording format or the app<->Pi wire contract.

The first implementation gate tried to use `AVAssetExportSession` with
`AVAssetExportPresetPassthrough` for TS->MP4. The bundled `seg_00000.ts` fixture was
copied into the test bundle and then loaded through `AVURLAsset` with
`AVURLAssetOverrideMIMETypeKey: video/mp2t`; on the iOS 26.5 simulator the load failed
with `AVFoundationErrorDomain -11828` (`Cannot Open`, media format not supported,
failed dependency `assetProperty_Tracks`). Because the built-in path did not pass the
gate, the app owns a small fallback remuxer.

## Decision

After a clip pull completes, remux the local `.ts` file to a local `.mp4` file on the
iPhone and play the MP4 directly with `AVPlayer(url:)`. The remux is passthrough:
the app copies compressed H.264 samples and timing into MP4 without re-encoding.

Add a `ClipRemuxer` dependency seam to `AppDependencies`. Production uses
`ClipRemuxer.live`; tests can inject `.noop` or a custom implementation. The live
implementation:

- parses MPEG-TS packets, PAT, and PMT to find the H.264 PID;
- reassembles H.264 PES payloads and carries 90 kHz PTS/DTS through to the output;
- extracts SPS/PPS from Annex B NAL units and converts samples to AVCC length-prefixed
  format;
- writes MP4 with `AVAssetWriter` using compressed H.264 sample buffers and sync-sample
  attachments;
- cleans stale and partial remux outputs for the clip ID.

`ClipViewerViewController` now follows: pull -> "Preparing playback" -> remux -> direct
MP4 playback. It tracks the pulled TS and remuxed MP4 as temporary files and deletes
them when the viewer fails, is cancelled, or is dismissed. Cross-session clip caching is
still a later `lime` clip-store concern; this ADR only fixes the per-view playback
representation.

Delete the loopback playback stack (`LoopbackHLSServer`, `HLSPlaylist`,
`HTTPRangeRequest`) and its tests. The Pi still serves raw `.ts` bytes via
`GET /v1/clips/{id}`; it does not serve `.m3u8`, MP4, or playback-specific indexes.
AVPlayer still never talks to the Pi.

## Consequences

Easy:

- Scrubbing uses MP4 sample tables instead of a single-segment HLS boundary.
- The same MP4 file is the future precondition for save/share UI in swoop `tide`.
- The loopback HTTP server, playlist generator, and range parser disappear from the app.
- The Pi stays dumb: capture, store, and serve finished TS bytes.

Hard or risky:

- The app now owns a narrow media parser/writer surface: TS packet framing, PAT/PMT,
  PES PTS/DTS, Annex B NAL splitting, AVCC conversion, and CoreMedia sample-buffer
  construction.
- The current implementation is intentionally scoped to the recording facts we control:
  single H.264 video stream, no audio, inline SPS/PPS, and one finished segment per
  clip. Non-H.264, multiple video streams, audio, or timeline stitching should fail
  loudly until a new ADR broadens the format.
- The remux is currently temporary per viewer. Replaying a clip across sessions still
  re-pulls/remuxes until the `lime` clip store lands.

Mitigations:

- Unit tests cover TS fixture demuxing, invalid TS rejection, Annex B start-code
  parsing, SPS/PPS extraction, IDR detection, AUD access-unit splitting, output cleanup
  on failure, and end-to-end MP4 playability/seekability through `AVURLAsset` and
  `AVAssetImageGenerator`.
- The end-to-end remux test passed on both the iOS 26.5 simulator and the physical
  iPhone `Pelucho` on 2026-06-26.
- The parser is kept under `Media/Remux` and behind `ClipRemuxer`, not spread through
  UI code.

## Alternatives considered

- **Keep loopback HLS.** Rejected: it proved basic playback but not usable scrubbing for
  one-segment clips.
- **Use `AVAssetExportSession` passthrough.** Preferred if the gate had passed, but the
  bundled TS fixture failed to load as an `AVURLAsset` on the iOS 26.5 simulator with
  `AVFoundationErrorDomain -11828`, so it cannot be the implementation path.
- **Build byte-range multi-segment HLS locally.** Rejected: the app would still need TS
  indexing/parsing work, while keeping a loopback server and a separate export remux.
- **Remux on the Pi.** Rejected: the Pi's job remains recording safely and serving raw
  footage. Phone-side playback formats should not add Pi CPU, storage churn, or failure
  modes to the recording unit.
- **Use the hand-rolled demuxer as the first choice without a gate.** Rejected during
  planning: less code is better when the platform can do the work. The gate failed, so
  the hand-rolled implementation is accepted as the smallest reliable path now.
