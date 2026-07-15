You are the ORCHESTRATOR of a multi-agent review of dancam's video pipeline -- the
clip PULL -> REMUX -> PLAY path spanning the Pi (Rust) and the iPhone app (Swift/UIKit).
Goal: produce an actionable, severity-ranked punch list of correctness bugs, test gaps,
spec/Apple-guidance violations, over-engineering, and polish issues -- grounded in real
Apple documentation and the relevant wire specs wherever a claim can be checked. Fan out
one read-only subagent per lane; each writes its own findings file; then you compile a
single index.md that links them and synthesizes the top issues.

Do NOT modify product code. Everything you create lives under one throwaway scratch dir.

## Step 0 -- create the scratch dir
Run:
    REVIEW_DIR="$(mktemp -d "$(git rev-parse --show-toplevel)/video-review.XXXXXX")"
    REVIEW_REL="$(basename "$REVIEW_DIR")"   # repo-root-relative dir name, e.g. video-review.ab12CD
    printf '/video-review.*\n' >> "$(git rev-parse --git-dir)/info/exclude"
    echo "$REVIEW_DIR"
    echo "$REVIEW_REL"
Keep the absolute $REVIEW_DIR (you pass each subagent the exact path to write, and you write
$REVIEW_DIR/index.md at the end) and its basename $REVIEW_REL (you prefix it onto every lane
link inside index.md so the links resolve from the repo root -- see Step 2). (The exclude
line keeps the dir out of git status without touching the tracked .gitignore.)

## Step 1 -- fan out the lanes (ALL in one message, parallel)
Spawn the lanes below as general-purpose subagents (they must Write, WebSearch, WebFetch,
Bash, Read, Grep, Glob) in a SINGLE message so they run concurrently. Give each: (a) the
SHARED RUBRIC verbatim, (b) its lane row, (c) its exact output path $REVIEW_DIR/NN-slug.md,
(d) the return contract.

### SHARED RUBRIC (paste into every subagent verbatim)
You are a read-only reviewer of ONE lane of dancam's clip pull->remux->play pipeline. Read
the code first and follow it where it leads; confirm how it actually behaves before judging.
Stay in your lane; if you spot a cross-lane issue, jot it under a short "Cross-lane notes"
section for the orchestrator rather than chasing it.

Ground every checkable claim. When you assert something is wrong, fragile, or non-conforming,
back it with one of: the relevant Apple developer docs, the wire spec (RFC/ISO/ITU), or a
dancam ADR under */docs/design/. Use WebSearch + WebFetch to pull the actual doc/spec text;
if WebFetch is blocked (403/429/anti-bot/JS shell), fall back to WebSearch excerpts or
Chrome MCP. Quote or link the specific authority. Separate "violates documented Apple
guidance / the spec" from "my design judgment." Do not fabricate API names, tag names, or
behaviors -- if unsure, verify or mark it low-confidence.

Severity scale:
- S0 Critical -- loses/corrupts video, crashes, hangs/deadlocks, security (e.g. non-loopback
  bind, path traversal), or data loss.
- S1 High -- a real bug or clear spec/Apple-guidance violation that triggers under realistic
  conditions (mid-pull Wi-Fi drop, congested 2.4 GHz, power-cut-truncated TS, ETag change),
  or a missing test on a genuine risk path.
- S2 Medium -- correctness-adjacent fragility, notable complexity/over-engineering, or a
  polish/UX gap that degrades the experience.
- S3 Low -- nits, naming, small cleanups.

Write findings to the EXACT path given, ordered by severity (S0 first). Per finding (ASCII
only; no em dashes, straight quotes, "deg"/"4x"):

    ### [LANE-NN] Short title -- S0|S1|S2|S3
    - Category: correctness | concurrency | spec-compliance | testing | simplicity | polish | perf | security
    - Where: `path:line` plus a searchable `#symbol` or short quoted snippet
    - What: what the code does
    - Why it matters: realistic trigger and impact
    - Fix: single recommended action
    - Grounding: Apple doc / RFC / ISO / ITU / ADR link or quote -- or "design judgment, no external source"
    - Confidence: high|medium|low   Effort: S|M|L

(`path:line` is fine here -- this scratch dir is a throwaway artifact, not a durable doc --
but include a symbol or snippet so it survives edits.)

Begin the file with a one-paragraph Lane summary (what you reviewed, overall health, count
by severity), then the findings. Prefer high-signal findings over volume, but be exhaustive
on correctness, concurrency, and spec-compliance -- those are the point.

Return contract (your final message to the orchestrator, NOT prose for a human): the output
file path, the count of findings by severity, and a one-line title for each S0/S1 finding.
Nothing else.

### LANES

Lane A -- Clip pull & resumable transport (app)   ->  01-pull-transport.md
- Scope: the on-the-wire clip pull and HTTP/connection plumbing -- resumable ranged
  download, restart vs resume, connection liveness/timeouts, cancellation.
- Anchor files (follow if moved): app/DanCam/DanCam/Networking/Clips/ClipPullClient.swift;
  app/DanCam/DanCam/App/ConnectionResumable.swift; app/DanCam/DanCam/Networking/HTTP/
  (HTTPContentRange, HTTPRequestEncoder, HTTPResponseHead, HTTPBodyDecoder, NWByteStream,
  InterfacePinning, ContentType); Networking/ClipsClient.swift; ClipsResponse.swift.
  Authorities: the [app connection design](../docs/design/app/connection.md) and the
  [transport boundary](../docs/design/boundary/transport.md).
- Key questions: Is the Range/If-Range/Content-Range resume loop correct -- verify ETag
  before resuming, truncate/restart correctly on a validator change (HTTP 200), never
  corrupt the temp file by appending past a reset? Exact byte offsets, partial reads, EOF?
  Are liveness timeouts actually bounded on a stalled NWConnection (no infinite hang)?
  Cancellation/teardown leaks? Resume policy under repeated drops? Header/Content-Range
  parsing robustness.
- Authorities: RFC 9110 (Range Requests, If-Range, ETag, 206, 416, conditionals); Apple
  Network framework (NWConnection state/path, timeouts, NWProtocolTCP).

Lane B -- TS demux & H.264 access-unit assembly   ->  02-ts-h264-demux.md
- Scope: turning raw MPEG-TS bytes into H.264 access units -- the parsing core shared by
  progressive and finalized remux.
- Anchor files: app/DanCam/DanCam/Media/Remux/TSDemuxer.swift;
  H264AccessUnitAssembler.swift; DemuxedH264Clip.swift.
- Key questions: MPEG-TS correctness -- 188-byte sync, PID/PAT/PMT resolution, continuity
  counters, adaptation fields, PES headers, 33-bit PTS/DTS extraction and wraparound.
  Annex B NAL parsing (start-code scan, emulation-prevention bytes), access-unit boundary
  detection, SPS/PPS capture/reuse. CRUCIAL: behavior on truncated/corrupt TS (crash-safe
  recording guarantees power-cut tails) -- drop the partial trailing unit cleanly or emit
  garbage/crash? Off-by-one and bounds safety on every slice.
- Authorities: ISO/IEC 13818-1 (MPEG-2 TS); ITU-T H.264 (Annex B, NAL syntax, SPS/PPS);
  ISO/IEC 14496-15 (avcC); the [Pi recording design](../docs/design/pi/recording.md).

Lane C -- fMP4 segmentation & finalized remux (AVFoundation)  ->  03-fmp4-finalize-remux.md
- Scope: the AVAssetWriter paths -- progressive fragmented-MP4 generation and the finalized
  front-moov MP4.
- Anchor files: app/DanCam/DanCam/Media/Stream/FMP4Segmenter.swift;
  Media/Stream/ProgressiveSegmenter.swift; Media/Remux/ClipRemuxerEngine.swift;
  Media/ClipRemuxer.swift.
- Key questions: Is AVAssetWriter configured correctly for HLS fragmented MP4
  (output settings, outputFileTypeProfile, segment interval/manual flush,
  initialSegmentStartTime)? Are #EXTINF durations taken strictly from AVAssetSegmentReport
  (never guessed), with the frozen-target-duration / invalid-duration fallback honored?
  Segments flushed ONLY at IDR boundaries (one GOP per segment, each starting on a sync
  sample)? Correct CMSampleBuffer/CMFormatDescription/timing (timescale, PTS/DTS, sync-sample
  flags)? Is the finalized MP4 actually front-moov/faststart? Is the deliberate double-parse
  (progressive + finalizer) a real divergence risk or fine?
- Authorities: Apple AVFoundation (AVAssetWriter, AVAssetWriterInput, AVAssetSegmentReport,
  AVAssetWriterDelegate, AVOutputSettingsAssistant); Apple HLS authoring spec (fragmented
  MP4 / CMAF); CoreMedia (CMSampleBuffer, CMFormatDescription).

Lane D -- Loopback HLS server & AVPlayer swap     ->  04-loopback-hls-playback.md
- Scope: the viewer-scoped local HLS server and the AVPlayer state machine that plays
  progressive segments then swaps to the finalized MP4. Highest-concurrency, highest-LOC
  surface (server ~767 LOC, viewer ~683 LOC).
- Anchor files: app/DanCam/DanCam/Media/Stream/LoopbackMediaServer.swift;
  app/DanCam/DanCam/Features/ClipViewer/ClipViewerViewController.swift; handoff from
  Media/Stream/ProgressiveSegmenter.swift.
- Key questions: Is all server state truly confined to one serial domain, with AVAssetWriter
  delegate segment data copied before crossing threads (per ADR 08)? Any data races,
  ordering bugs, or deadlocks across demux queue / server queue / MainActor? Is the server
  bound ONLY to loopback (never 0.0.0.0)? EVENT-playlist correctness:
  #EXT-X-PLAYLIST-TYPE:EVENT, frozen #EXT-X-TARGETDURATION, #EXTINF, #EXT-X-ENDLIST,
  append-only discipline, GET/HEAD/Range serving of init.mp4 / segN.m4s. Swap correctness:
  preserve playback time, cancel the segmenter, suppress a late firstPlayableReady so a slow
  first GOP cannot reattach a torn-down playlist over a good MP4. Lifetime: server + temp dir
  deleted on swap/dismiss/failure; AVPlayer/AVPlayerItem KVO add/remove balance; retain
  cycles/leaks. Fallback when no first fragment ever arrives.
- Authorities: RFC 8216 + Apple HTTP Live Streaming authoring spec (EXT-X tags, EVENT
  playlists, fMP4); Apple AVFoundation (AVPlayer, AVPlayerItem, AVURLAsset, status /
  timeControlStatus observation).

Lane E -- Pi clip serving & duration (Rust)       ->  05-pi-clip-serving.md
- Scope: the server side of the pull -- clip listing, raw .ts serving with ranges,
  PTS-derived durations.
- Anchor files: raspi/service/src/clips.rs; raspi/service/src/ts_duration.rs;
  raspi/service/src/recording.rs.
- Key questions: Range correctness per RFC 9110 -- Accept-Ranges, Range -> 206/Content-Range,
  If-Range validator match, 416 + Content-Range: bytes */len on unsatisfiable, multi-range
  handling or explicit rejection, ETag stability ({seq}-{bytes}) and whether it can collide
  or change mid-pull. Is the open/active segment reliably excluded from listing AND fetch
  (never serve a still-being-written file)? {id} path safety (no traversal / arbitrary read).
  PTS duration math (maxPTS - minPTS) + frame_interval -- 33-bit wrap, discontinuities,
  single-frame/empty segments, cache invalidation. Error mapping and IO handling.
- Authorities: RFC 9110 (Range, conditional requests, status codes); ISO/IEC 13818-1
  (PTS); the [transport boundary](../docs/design/boundary/transport.md),
  [Pi storage](../docs/design/pi/storage.md), and the
  [Pi recording design](../docs/design/pi/recording.md).

Lane F -- Test coverage & quality (cross-cutting) ->  06-test-coverage.md
- Scope: audit existing tests around the whole pull->remux->play path; find the gaps that
  matter and the brittle tests that should change.
- Anchor files: app/DanCam/DanCamTests/Networking/Clips/, Networking/HTTP/, Media/Remux/,
  Media/Stream/, Media/ClipRemuxerTests.swift, Media/ProgressivePlaybackIntegrationTests.swift,
  Features/ClipViewer/, Features/Clips/; raspi/service/tests/clips.rs, recording.rs. Plus the
  code under test in the other lanes' anchors.
- Key questions: Do tests exercise the real risk surfaces -- mid-pull drop+resume,
  ETag-change restart/truncation, 416/unsatisfiable range, truncated/corrupt TS tails,
  progressive->finalized swap continuity, late-first-playable suppression, fMP4
  duration/fallback, PTS wrap? Audit on two axes: coverage of behavior the code HAS, and
  coverage of the CLAIMS the ADRs make. Only call for tests that are BEHAVIORAL and
  STRUCTURE-INSENSITIVE -- do not demand tests that pin internal structure or restate the
  implementation. Flag brittle/over-mocked tests that would pass real regressions through.
  Rank gaps by the risk they leave uncovered.
- Authorities: the plan-review rubric (behavioral, structure-insensitive tests); Swift
  Testing and Rust testing conventions; project AGENTS.md.

Lane G -- Simplicity, architecture & over-engineering ->  07-simplicity-architecture.md
- Scope: the headline worry -- the system is getting complicated. Judge whether the design
  earns its complexity and pitch concrete consolidations.
- Anchor files: the whole pipeline -- app/DanCam/DanCam/Media/**, Networking/Clips/**,
  Networking/HTTP/**, Features/ClipViewer/**, Features/Clips/**, and
  raspi/service/src/{clips,ts_duration,recording}.rs. Read ADRs 07 and 08 first.
- Key questions: Does the dual progressive+finalizer pipeline (TS parsed twice, two writer
  paths, a loopback server) carry its weight versus a simpler design, or is the complexity
  load-bearing for time-to-first-frame? Are the big units (767-line server, 683-line viewer)
  doing one job or several that should split -- or are there too many thin files that should
  merge? Duplicated logic across remux paths, leaky abstractions, wrong-altitude coupling
  between viewer/server/segmenter, dead or speculative code, misleading names. Repo stance is
  explicit: no users, no back-compat -- prefer "delete and replace" over layering. Pitch the
  simplest design that still hits progressive first-frame, with a concrete migration sketch
  and what it costs. Distinguish "simplify now" from "fine, leave it."
- Authorities: project AGENTS.md ("take the ideal solution", "delete don't layer"); ADRs
  07/08; general design judgment (cite where checkable).

## Step 2 -- compile index.md
After all subagents return, write $REVIEW_DIR/index.md (ASCII only):
1. Header: what this is, commit (git rev-parse --short HEAD) + date, one-line how-to-read.
2. Top issues across the whole pipeline: the ~10-15 highest-severity, DEDUPED across lanes
   (collapse the same root issue raised by two lanes; note which lanes raised it). Each:
   title, severity, link to the lane file + finding id, one-line why.
3. Per-lane table: lane | link to its file | counts S0/S1/S2/S3 | one-line health.
4. Cross-cutting themes: patterns recurring across lanes (e.g. truncated-TS handling,
   timeout discipline, resume test gaps).
5. Suggested order of attack: triage list (fix-now vs next vs nice-to-have), favoring
   low-effort S0/S1 first.
Link every lane file relative to the REPO ROOT, not to index.md itself: prefix each lane
filename with $REVIEW_REL (the scratch dir's basename), e.g.
`video-review.ab12CD/01-pull-transport.md`. Apply this to BOTH the markdown links (the
per-lane table and any footer) AND the inline finding references in the Top issues section
(e.g. [`video-review.ab12CD/02-ts-h264-demux.md`#B-01]). The reason: a follow-up agent is
launched per finding from the repo root, so a bare or `./`-relative name (which only
resolves from inside the scratch dir) would not find the file. Note this convention in the
index's how-to-read line. Print the absolute $REVIEW_DIR/index.md path as the final line of
your reply.

## Constraints
- Read-only on product code; write ONLY under $REVIEW_DIR.
- Launch all lane subagents in ONE message (parallel). They must be general-purpose
  (need Write + web).
- ASCII only per repo style ("--" not em dash, straight quotes, "deg"/"4x").
- If a subagent returns nothing or dies, note it in the index and continue; don't block the
  whole report on one lane.
