# Plan: `lime` Pi-side `dur_ms` reporting (TS-PTS, exact + cached)

## Context

`lime` ("Watch recorded clips") is the current swoop. Its remaining open Pi task
(`docs/roadmap.md`, the `lime` swoop) is:

> **Pi:** report `dur_ms` cheaply -- ~30 s from the segment cadence, ffprobe only the
> final short segment if needed -- so rows show length now; `start_ms` and real
> provenance stay deferred to `moss`.

Today `GET /v1/clips` already carries a `dur_ms` field, but it is hardwired to
`null` (`raspi/service/src/clips.rs#read_finished_clips` sets `dur_ms: None`). The
app already decodes it (`app/.../Networking/ClipsResponse.swift` -> `Clip.durMs`),
so the only gap is the Pi producing a value. The browse list cannot otherwise know a
clip's length without pulling and remuxing the whole ~38 MB segment.

**Altitude chosen (over the roadmap's cheaper spec):** compute the *exact* duration
by reading each finished `.ts`'s first/last presentation timestamp (PTS) and cache
it per segment. This was picked deliberately over the byte-estimate/cadence-constant
heuristics because (per `AGENTS.md` "take the ideal solution"):

- It is exact for full / short / odd / power-cut-truncated segments alike.
- **Disk stays the single source of truth** -- duration is derived from the
  authoritative `.ts` bytes, not from cadence/bitrate constants duplicated out of
  `raspi/camera/camera.py` (which would silently drift).
- It is **not throwaway**: TS-PTS parsing is exactly the rebuild primitive the
  storage ADR already names (`raspi/docs/design/03-2026-06-23-storage-ring-buffer-incident-lock.md`,
  "parsing TS PTS for any segment missing a record"). Building it now is building a
  real piece of the eventual finalize-time index, not a stopgap to delete.
- Caching makes it cheap: a finished segment is immutable, so its duration is
  computed once (a bounded head+tail read) and reused on every subsequent poll.

`start_ms` and wall-clock provenance stay `null` / `time_approximate: true` --
deferred to `moss` (`POST /v1/time`) and the storage index, unchanged by this task.

## Why exact PTS works here

The recorder muxes with `-bsf:v setts=pts=N*DURATION:dts=N*DURATION` +
`-reset_timestamps 1` (`raspi/camera/camera.py#recording_ffmpeg_output`), so inside
each finished segment the video PTS increase linearly at a fixed frame interval. We
never assume the first PTS is 0 (the bundled `seg_00000.ts` actually starts at
~1.47 s); the duration is the span between first and last PTS *plus one final frame
interval*, in the 90 kHz TS clock:

    dur_ticks = (maxPTS - minPTS) + frame_interval

`frame_interval` is the smallest positive gap between consecutive (sorted) PTS in the
scanned region -- the per-frame presentation step, measured from the stream itself
(no fps/bitrate constant assumed), robust to B-frame reorder and to a GOP sliced at a
window edge. Adding it back counts the last access unit's own on-screen time, so the
reported length matches the clip's true wall length and matches the app's own
demuxer, which computes `max(pts + duration) - min(pts)`
(`app/.../Media/Remux/DemuxedH264Clip.swift#durationTicks`). Concretely the bundled
fixture's PTS span is 29.9667 s but its true duration is 30.0000 s -- the dropped
+1/30 s that both the app and `ffprobe` report. Bare `(maxPTS - minPTS)` would
under-report by exactly one frame, which is why "exact" requires the `+ frame_interval`.

## Approach

### 1. New module: `raspi/service/src/ts_duration.rs`

A small, pure MPEG-TS PTS reader plus a thin filesystem wrapper. Keep parsing pure
(operates on `&[u8]`) so it unit-tests without disk.

- `fn scan_pts_bounds(buf: &[u8]) -> Option<PtsSpan>` where
  `PtsSpan { min: u64, max: u64, frame_interval: u64 }`.
  Walk `buf` in 188-byte TS packets (sync byte `0x47`). For each packet with
  `payload_unit_start_indicator` set whose payload begins with a PES start code
  (`00 00 01`) and a video `stream_id` (`0xE0..=0xEF`) carrying `PTS_DTS_flags`,
  decode the 33-bit PTS (standard 5-byte marker-bit layout). Collect every PTS, then
  return `min`, `max`, and `frame_interval` = the smallest positive difference
  between consecutive sorted distinct PTS. Return `None` if no PTS were found;
  `frame_interval = 0` when only one distinct PTS was found (degenerate single-frame
  region -- `segment_duration_ms` then treats it as no duration; see below).
  - Skip the TS header (4 bytes) plus the adaptation field when `adaptation_field_control`
    indicates one is present, before looking for the PES start.
  - Min/max (not "last") plus the smallest-gap interval keep this robust to B-frame
    reorder.
  - No wraparound handling needed: a <=30 s segment stays far from the 33-bit wrap.
- `fn segment_duration_ms(path: &Path, bytes: u64) -> Option<u64>`
  Constants `HEAD_WINDOW = 256 KiB`, `TAIL_WINDOW = 512 KiB` (both >> the ~41 KB a
  frame costs at 10 Mbps, so each window holds several frames' PTS).
  - Small files (`bytes <= HEAD_WINDOW + TAIL_WINDOW`): read the whole file and run
    one `scan_pts_bounds`; use its `min`, `max`, `frame_interval` directly.
  - Large files: scan two packet-aligned windows.
    - Head: bytes `0 .. HEAD_WINDOW` (offset 0 is already packet-aligned).
    - Tail: start at `tail_off = ((bytes.saturating_sub(TAIL_WINDOW)) / 188) * 188`
      -- the packet boundary at-or-before `bytes - TAIL_WINDOW`, *not* the last
      packet boundary near EOF -- and read from `tail_off` to EOF.
    - Take `min` from the head scan, and `max` + `frame_interval` from the tail scan
      (the final access units -- the interval we add back is the genuine last-frame
      step). If the tail window yielded a single PTS, fall back to the head scan's
      `frame_interval` only (the per-frame step is uniform across a CBR segment, so
      borrowing just the interval is sound). If the tail scan found *no* PTS at all
      (no usable `max` -- a large all-garbage file, or a tail window that landed
      entirely in a corrupt region), return `None`. **Never borrow the head window's
      `max` on the large-file path:** the head covers only the first `HEAD_WINDOW`
      bytes (~0.2 s of video at 10 Mbps), so its `max` is an early-frame PTS, not the
      file's last -- using it would emit a confidently-wrong sub-second `dur_ms`,
      which is worse for the browse list than the `null` the app already renders
      gracefully. (Head `max` equals the file max only on the small/whole-file path,
      where the single scan covers the whole file.)
  - `dur_ms = ((max - min) + frame_interval) * 1000 / 90000`. Return `None` on parse
    failure or if `max <= min` (a single-frame region has no interval to infer).
  - Tolerate truncated tails (power-cut): a partial final packet just isn't counted;
    the last *complete* PES PTS wins.

### 2. Per-segment duration cache in `AppState`

A finished segment's duration never changes, so compute once and memoize.

- Add a field to `AppState` (`raspi/service/src/lib.rs#AppState`), e.g.
  `clip_durations: Arc<Mutex<HashMap<u32, (u64, Option<u64>)>>>` (key = seq, value =
  `(bytes, dur_ms)`), initialized empty in `AppState::new`. A newtype wrapper
  (`DurationCache`) with one method keeps `read_finished_clips` tidy:
  `fn duration_ms(&self, seq, path, bytes) -> Option<u64>` -- cache hit when the
  stored `bytes` matches (etag identity); otherwise call `segment_duration_ms`,
  store the result (including `None`, so unparseable/garbage files aren't re-read),
  and return it. Use `std::sync::Mutex` (work is synchronous fs I/O).

### 3. Wire into the listing

- `read_finished_clips` (`raspi/service/src/clips.rs`) gains a `&DurationCache`
  param. **Order matters: compute duration only for the segments that survive the
  `MAX_CLIPS` (500) truncation, not for every candidate on the card.** Today the
  function maps *all* candidates to `ClipMeta` and only *then* sorts by `id` desc and
  `truncate(MAX_CLIPS)`. Reorder so the cheap pass runs first: collect candidates as
  `(seq, bytes, path)` (the open-segment exclusion stays in this pass), sort by `seq`
  desc, `truncate(MAX_CLIPS)`, and only then `.map` the survivors to `ClipMeta`,
  setting `dur_ms: cache.duration_ms(seq, &path, bytes)`. The sort key is `id`, never
  duration, so the reorder is behavior-preserving for the returned rows. Without it,
  the first cold poll of a card holding more than 500 finished segments (there is no
  ring GC yet -- that is the deferred storage coordinator, so segments accumulate
  unbounded across drives) would do a head+tail read for *every* segment on the card,
  including the oldest ones truncated out of the response and never shown; the reorder
  bounds cold I/O to `<=500` reads (and the cache makes even that one-time).
- `list_clips` passes `&state.clip_durations`. Because the listing now does real
  per-file I/O on cold segments, run it under
  `tokio::task::spawn_blocking` (clone the `Arc<Path>` rec_dir and the cache `Arc`
  into the closure) so an SD-card read never stalls the async runtime. Steady-state
  polls are all cache hits -> no extra I/O.

### 4. Add the `raspi-check` gate to the root `Justfile`

The verification below leans on `just raspi-check` (fmt + clippy), but the `Justfile`
does not define it yet. Add a recipe alongside `raspi-build` / `raspi-test`, in their
`--manifest-path raspi/service/Cargo.toml` style, that runs fmt-check then clippy:
`cargo fmt --manifest-path raspi/service/Cargo.toml --check` followed by
`cargo clippy --manifest-path raspi/service/Cargo.toml --all-targets -- -D warnings`.
This is a one-off tooling add that lands in the same change so the verification gate
is real.

## Edge cases

- **Garbage / non-TS files** (test fixtures `b"zero"`, the `FakeCameraDriver`'s
  `b"fake segment\n"`): no sync/PES/PTS -> `None` -> `dur_ms: null`. The app already
  handles a null `durMs`.
- **Mock-for-clips path** (`just raspi-mock-clips`, `DANCAM_REC_DIR=assets/clips`):
  the committed `raspi/service/assets/clips/seg_00000.ts` is a real ~1 MB, full-30 s
  `.ts` (a low-bitrate fixture: ~1 MB of bytes spanning 30 s of video), so it parses
  to `dur_ms ~= 30000`. It is byte-identical to the app's demuxer fixture
  `app/.../DanCamTests/Media/Fixtures/seg_00000.ts`, whose `TSDemuxerTests` already
  asserts `~30 s`, so Pi and app agree on the same file. (This file is also why a
  byte-size estimate would be wrong: 1 MB of bytes, 30 s of video.)
- **Open segment**: already excluded from the list while recording
  (`read_finished_clips` drops the max seq), so the cache only ever sees immutable,
  fully-written files.
- **Truncated power-cut tail**: best-effort last-complete-PTS; never panics.

## Tests

New unit tests in `ts_duration.rs`:
- `scan_pts_bounds` on a hand-built buffer of three valid TS packets at PTS
  `0, 3000, 6000` (a 30 fps cadence: 3000 ticks = 1/30 s) returns
  `PtsSpan { min: 0, max: 6000, frame_interval: 3000 }`; `segment_duration_ms` on
  that buffer-as-file returns `Some(100)` -- i.e. `((6000 - 0) + 3000)/90 = 100 ms`,
  proving the final frame interval is counted (bare span would give the wrong 66 ms).
- Garbage bytes -> `None`; empty file -> `None`; a buffer whose only PTS packet is
  truncated mid-PES -> ignored; a single-PTS buffer -> `max == min` so
  `segment_duration_ms` returns `None` (no interval to infer).
- **Required** head/tail windowing path: build a buffer larger than
  `HEAD_WINDOW + TAIL_WINDOW` with video PTS only in the head region (`0, 3000,
  6000`) and the tail region (`T, T+3000, T+6000`), padded between with
  null/non-video packets. Assert `min == 0`, `max == T+6000`, `frame_interval ==
  3000`, and `segment_duration_ms == ((T+6000) + 3000)/90` ms -- proving the tail is
  read from `tail_off` (not EOF) and the head `min` survives the window split. Also
  assert two zero-PTS-tail variants on the large-file path, both -> `None`: (a) a
  same-size buffer of pure garbage (no PTS in either window), and (b) a buffer with
  valid PTS in the head region but pure garbage in the tail -- the intact-head /
  corrupt-tail case, which must *not* borrow the head's early-frame `max` and emit a
  bogus sub-second duration. (The existing small-garbage test only covers the
  whole-file path; variant (b) covers the branch the all-garbage test skips.)
- **Required** real-fixture parse: call `segment_duration_ms` on the committed
  `raspi/service/assets/clips/seg_00000.ts` (path built from
  `env!("CARGO_MANIFEST_DIR")`, `bytes` from its `fs::metadata` len) and assert the
  result is within ~100 ms of `30000`. The synthetic tests above prove the parser's
  logic on hand-built packets; this proves it against a real ffmpeg/Picamera2 TS
  layout (PAT/PMT, adaptation fields, real PES headers) -- the same ground-truth the
  app exercises in `TSDemuxerTests#demuxesBundledTransportStreamFixture`. The fixture
  (~989 KB) also exceeds `HEAD_WINDOW + TAIL_WINDOW` (768 KiB), so it traverses the
  windowed branch on real bytes, not the whole-file branch.
- **`DurationCache` per-key correctness** (a unit test where `DurationCache` lives):
  write two valid segments with *distinct* durations to temp files -- PTS `0, 3000`
  (`(3000 - 0) + 3000 = 6000` ticks -> `66 ms`) and `0, 3000, 6000` (`100 ms`) --
  then call `duration_ms(seq, path, bytes)` for each `seq` and assert each gets its
  own value (`66` and `100`), not the other's. This catches a `seq`-keying mixup or a
  `(bytes, dur_ms)` value-tuple transposition, which the single-non-null tests
  cannot. The hand-built TS buffers reuse `ts_duration.rs`'s packet builder (same
  crate). The memoization (I/O-avoidance) itself stays untested -- asserting a cache
  *hit* would be structure-sensitive.

Update existing tests:
- `raspi/service/src/clips.rs` unit tests (`read_finished_clips_*`): pass a fresh
  `DurationCache` to the new signature. Their tiny garbage payloads keep
  `dur_ms == None`, so existing field assertions still hold; no behavior change to
  assert there.
- `raspi/service/tests/clips.rs`:
  - `clips_route_lists_finished_clips_and_headers` writes garbage, so its existing
    `clips[0]["dur_ms"] == Value::Null` assertion **still passes** -- keep it as the
    "unparseable -> null" case.
  - Add a new route test that copies the committed real
    `raspi/service/assets/clips/seg_00000.ts` into the temp rec_dir and asserts the
    JSON row reports `dur_ms` within ~100 ms of `30000` (and `start_ms == null`,
    `time_approximate == true` unchanged), proving the field is populated end to end
    through the HTTP layer with a real PES/adaptation-field parse. Copy the real
    fixture rather than hand-building TS bytes here: `tests/clips.rs` is a separate
    crate and cannot reach `ts_duration.rs`'s packet builder, so synthesizing a
    segment would duplicate it across the crate boundary. Exact-value assertions
    (`== 100`, `== 66`) stay in the same-crate unit tests above.

Run with `just raspi-test` (and `just raspi-check` for fmt/clippy, added in step 4).

## Docs (land in the same change)

- **ADR 02** (`raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md`): update
  the `GET /v1/clips` "Note (2026-06-26)" that currently says `dur_ms` is null. Add a
  dated sub-note: `dur_ms` is now populated as an exact TS-PTS-derived duration
  (cached per segment); `start_ms`, `locked`, and non-approximate time provenance
  remain deferred. Note this realizes ADR 03's TS-PTS rebuild path.
- **ADR 03** (`raspi/docs/design/03-2026-06-23-storage-ring-buffer-incident-lock.md`):
  the plan's "not throwaway" altitude argument rests on ADR 03's rebuild step 2
  (`Index, Listing, And Rebuild`: "parsing TS PTS for any segment missing a record"),
  so that doc -- which *owns the primitive* -- must carry the breadcrumb, not just
  ADR 02. Add a dated note near that step recording that the TS-PTS parse is partially
  realized early as `raspi/service/src/ts_duration.rs`, currently the *primary*
  `dur_ms` source for the present flat-layout listing. Scope it explicitly: the module
  computes a duration *span* (`(maxPTS - minPTS) + frame_interval`), **not** the
  boot-anchored `mono_start_ms`/`mono_end_ms` the `index.log` finalize record stores,
  and it does **not** reconcile against `index.log`; both arrive with the storage
  coordinator, at which point this parse becomes the rebuild *fallback* ADR 03 already
  specifies (record present -> `mono_end_ms - mono_start_ms`; record missing -> parse
  TS PTS).
- **Roadmap** (`docs/roadmap.md`): check the `lime` "Pi: report `dur_ms`" box and
  reword it to record the pivot -- exact TS-PTS duration (cached), not the
  cadence-constant/ffprobe approach originally spitballed (a pivot that isn't written
  down is the next trap).
- No new ADR: this is ADR 03's own rebuild primitive realized early, so dated notes on
  ADR 02 (the wire-contract change) and ADR 03 (the primitive's breadcrumb) plus the
  roadmap update are the right footprint.

## Verification (end to end)

1. `just raspi-test` -- unit + route tests green, including the new exact-duration
   route test.
2. `just raspi-check` -- fmt + clippy clean.
3. Mock: `just raspi-mock-clips`, then `curl -s -H 'Host: localhost:8080'
   http://127.0.0.1:8080/v1/clips | jq '.clips[0]'` -> shows `dur_ms` ~= 30000 for
   the real sample (its true 30 s length, not null), matching `ffprobe`'s
   `30.000000`.
4. App against the mock (`just app-build` / run): clip rows still decode (the app
   already maps `dur_ms` -> `durMs`); confirm no decode regression. (UI *display* of
   duration is a separate `lime` task -- see below.)
5. Real Pi (when available): record >30 s then stop, pull `GET /v1/clips`, confirm
   full segments report ~30000 ms and the short final segment reports its true
   sub-30 s length.

## Out of scope / what's next

- **`start_ms` + wall-clock provenance** -> `moss`.
- **App: clip rows show duration + created time + poster** -> separate open `lime`
  task; the app already *decodes* `durMs`, this task only makes the Pi *send* it.
- **App: on-device clip store** (reuse pulled bytes, don't re-pull ~38 MB) -> the
  next task after this, per the original request.

## Implementation notes

- Adding `just raspi-check` surfaced an existing clippy `bool-comparison` lint in
  `raspi/service/src/recording.rs`; the implementation fixes that equivalent
  expression so the new gate is actually green.
