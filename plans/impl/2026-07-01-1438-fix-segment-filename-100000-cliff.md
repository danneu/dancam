# Plan: harden the segment-filename seq convention (fix the 100000 cliff)

## Context

Recording produces MPEG-TS segments named `seg_{seq:05}.ts`, where `seq` is a
global monotonic `u32` (`SegmentId`). The review finding **LANE-E-01**
(`video-review.xegWVJ/05-pi-clip-serving.md#E-01`) identified a certain, silent
data-loss cliff at the 100000th cumulative segment:

- `{:05}` / `%05d` is a *minimum* width, so once `seq >= 100000` the producer
  writes 6-digit names (`seg_100000.ts`).
- Both parsers require *exactly* 5 digits and reject those names:
  - Rust `clips.rs#clip_seq` -- `if seq.len() != 5 || ...`
  - Python `camera.py` -- `SEGMENT_RE = ^seg_(\d{5})\.ts$`
- Consequences at the crossing (verified end to end):
  1. The Python watcher stops emitting `segment_opened`/`segment_closed`, so the
     recorder FSM floor (`recorder.rs#unpullable_floor`) freezes at 99999 and all
     6-digit footage becomes unlistable and unpullable (on disk, unreachable).
  2. On the next `start_recording`, next-seq is recomputed from on-disk filenames
     via `clips.rs#max_clip_seq` (`.map(|s| s.saturating_add(1)).unwrap_or(0)`,
     called from `backend.rs#start_recording` and `camera/mod.rs#start_recording`).
     Because 6-digit files are invisible to the parser, it returns 99999, so the
     next session starts at 100000 and ffmpeg's segment muxer reopens
     `seg_100000.ts`, **truncating existing footage**.

At 30 s/segment this is ~833 h cumulative (1-2 years of daily driving): far out,
but certain with use, and it violates two cross-cutting principles ("SD is the
source of truth", "recording must survive abrupt power loss" -- overwrite is data
loss).

**Root cause:** the render+parse filename convention is copy-pasted across ~8
sites in two languages with a brittle fixed-width assumption baked into the
parsers. The fix is to give the convention a single source of truth per language
and derive parsing from the renderer (its exact inverse), so the two can never
again disagree about width.

### Scope decisions (confirmed with Dan)

- **Harden the naming convention only.** Relaxing the parsers fully fixes the
  data loss for the entire pre-GC horizon. ADR 03's durable, fsync'd
  `high_water_seq` (next-seq that survives garbage collection) is **deferred to
  the storage coordinator**, recorded with a dated Note in ADR 03. Rationale: no
  GC exists today (segments accumulate forever), GC is far-off (behind the
  current `lime` swoop plus `kelp`/`moss`/`nova` and a deepening pass), the
  counter would be the crate's *first* durable state, and ADR 03 also reworks the
  on-disk layout to `segments/seg-<seq>.ts` -- so any persistence built now gets
  reworked. Even under the eventual oldest-first eviction, filename-scan next-seq
  stays correct on the common path (eviction deletes the *lowest* seqs, never the
  newest), so the durable counter is a GC-edge robustness layer, not part of this
  bug.
- **Keep `%05d` minimum width.** The renderer stays min-width (seqs past 99999
  just grow a digit), the parser accepts exactly what it emits, and the code
  sorts numerically (never lexically) -- so fixed width buys nothing functional here.
  Keeping `%05d` means no churn to the app's display sites or the many test
  fixtures, and the Pi files stay consistent with the app's existing `%05d`
  label. The width becomes a one-line constant in the new helper, trivially
  changeable later (e.g. when the coordinator reworks the layout).

## Approach

Centralize the convention into **one render helper + one parse helper per
language**, define parsing as the exact inverse of rendering (a name is valid
iff re-rendering its parsed seq reproduces it), and route every existing
render/parse site through the helpers. This makes the parser's accepted set
*precisely* the renderer's output domain -- no wider, no narrower.

The app (`HomeViewController.swift`, `ClipViewerViewController.swift`) renders
`seg_%05d.ts` for *display only* from a numeric `clip.id` it receives via JSON --
it never parses filenames or derives next-seq. With `%05d` retained, **the app
needs no changes** (it stays a third, display-only copy that already renders
6-digit ids correctly because `%05d` is min-width).

## Changes

### Rust -- `raspi/service/src/`

1. **Add helpers in `recorder.rs`** (the fundamental leaf module that owns
   `SegmentId`; every render/parse site already depends on it, so no dependency
   cycle):
   - `pub fn segment_filename(seq: SegmentId) -> String` -> `format!("seg_{seq:05}.ts")`
     (min-width; document that seqs past 99999 render wider and the parser accepts that).
   - `pub fn parse_segment_filename(name: &str) -> Option<SegmentId>` -- strip
     `seg_` prefix / `.ts` suffix, `digits.parse::<SegmentId>().ok()?`, then
     accept **iff `segment_filename(seq) == name`**. `parse::<SegmentId>()` alone
     rejects empty, non-digit, a leading `-`, and `u32` overflow -- but it
     *accepts* a leading `+` (`"+5".parse::<u32>() == Ok(5)`); the round-trip
     check is what rejects that alias (`segment_filename(5) == "seg_00005.ts" !=
     "seg_+5.ts"`). The round-trip makes the parser the exact inverse of the
     renderer: it rejects every name the renderer never emits -- short names
     (`seg_999.ts`), over-padded aliases (`seg_000005.ts`), the `+`-signed alias
     (`seg_+5.ts`), and anything beyond `u32` -- so they can never enter listings
     or drive `max_clip_seq`. No standalone width/len check is needed (it reuses
     `segment_filename`), so the contract cannot drift from the renderer.
   - Unit-test both directly in `recorder.rs`: render/parse round-trips for `0`,
     `5`, `99999`, `100000`, `u32::MAX`; and parse rejects `seg_999.ts`
     (under-width), `seg_000005.ts` (over-padded alias), `seg_+5.ts` (leading `+`
     that `parse` accepts but the round-trip rejects), `seg_.ts`, `seg_abc.ts`,
     wrong extension, and `seg_4294967296.ts` (overflow).

2. **Route the parse site through the helper:** rewrite `clips.rs#clip_seq` to
   `parse_segment_filename(path.file_name()?.to_str()?)` -- the `len() != 5` gate
   is gone.

3. **Route the 4 render sites through the helper** (replace each inline
   `format!("seg_{..:05}.ts")` with `segment_filename(..)`):
   - `clips.rs#serve_clip`, `clips.rs#clip_meta`
   - `events.rs#enrich_current_segment`
   - `backend.rs#open_mock_segment`

### Python -- `raspi/camera/camera.py`

Mirror the Rust contract exactly (same inverse-of-render parse + same `u32`
ceiling), behind a single width constant so the ffmpeg template, the fake driver,
and the parser cannot drift:

1. **Constants + render helpers:**
   - `SEGMENT_WIDTH = 5`; `U32_MAX = 0xFFFF_FFFF`
   - `def segment_filename(seq: int) -> str: return f"seg_{seq:0{SEGMENT_WIDTH}d}.ts"`
   - `def segment_ffmpeg_pattern() -> str: return f"seg_%0{SEGMENT_WIDTH}d.ts"`
     (ffmpeg needs the printf template, not a concrete name).
2. **Parse = inverse of render, with an explicit `u32` ceiling.** Python `int` is
   unbounded, so the ceiling must be explicit -- otherwise an oversized
   `seg_<huge>.ts` parses to a giant id and poisons watcher/event state (and the
   id then fails `u32` deserialization on the Rust event boundary):
   - `SEGMENT_RE = re.compile(r"^seg_([0-9]+)\.ts$")` (ASCII digits, mirroring
     Rust's `is_ascii_digit`; avoids Unicode-digit surprises from `\d`).
   - `def parse_segment_filename(name: str) -> int | None:` match `SEGMENT_RE`;
     `seq = int(group)`; return `None` if `seq > U32_MAX` or
     `segment_filename(seq) != name`; else `seq`.
   - `detect_segment_events` calls `parse_segment_filename(name)` and skips `None`
     (instead of `SEGMENT_RE.match` + raw `int(group)`), so the ceiling and
     round-trip guard the watcher.
3. **Use the helpers at the render sites:**
   - `recording_ffmpeg_output` -> `rec_dir / segment_ffmpeg_pattern()`
   - `FakeCameraDriver.start_recording` and `_recording_loop` ->
     `rec_dir / segment_filename(idx)`

### Optional secondary cleanup (only if it stays clean)

`events.rs#enrich_current_segment` re-implements `clips.rs#clip_meta`'s
"render name -> `metadata` -> `is_file` -> `duration_ms`" sequence inline. Once
both share `segment_filename`, consider having `enrich_current_segment` call
`clip_meta(rec_dir, id, Some(cache))`. Keep it out of the core change if it
forces awkward shape differences -- it is adjacent dedup, not the data-loss fix.

## Docs

- **ADR 03** (`raspi/docs/design/03-2026-06-23-storage-ring-buffer-incident-lock.md`):
  add a dated Note (mirroring the existing 2026-06-29 `ts_duration` note) stating
  that the interim flat `seg_{seq:05}.ts` naming was hardened so the parser accepts
  every name the renderer emits (round-trip inverse, removing the 5-digit cliff)
  ahead of the coordinator; that the durable `high_water_seq` next-seq
  witness and the `segments/seg-<seq>.ts` subdir layout remain coordinator work;
  and why deferral is safe (no GC yet; oldest-first eviction preserves the max
  seq on the common path). This satisfies the AGENTS.md "record the pivot in the
  same change" rule -- it is an interim-hardening note, not a supersede.
- No README change: its recording smoke-check reads clips with the
  `ls -lh ~/rec-smoke/seg_*.ts` glob and the `ffmpeg ... -i ~/rec-smoke/seg_00000.ts`
  example (seq 0, still valid under min-width). No app/Swift change (display-only,
  `%05d` retained).

## Tests

- **Rust unit (`clips.rs`):** three separate assertions so no fixture is inert
  and no test overclaims its coverage:
  - **Leave `max_clip_seq_uses_segment_filename_parser` unchanged** -- with
    `seg_999.ts` the only non-5-digit candidate and no 6-digit file present, its
    `Some(3)` assertion keeps under-width rejection load-bearing (accepting
    `seg_999` would flip it to `Some(999)`). Adding a 6-digit fixture *here* would
    make `seg_999` inert -- `100000` dominates the max whether `seg_999` parses or
    not -- so the 6-digit regression goes in its own tests below instead.
  - **Add `max_clip_seq_sees_six_digit_segments`** -- seed `seg_99999.ts` +
    `seg_100000.ts`, assert `max_clip_seq` returns `Some(100000)`. This pins the
    regression at the exact next-seq function on the data-loss path, in pure Rust
    (no python), independent of the integration test below.
  - **Add a `read_finished_clips` boundary case** -- seed `seg_99999.ts` +
    `seg_100000.ts` + `seg_999.ts` (junk), assert the listing ids are exactly
    `[100000, 99999]`. One test locks three things at the only point where
    lexical and numeric order diverge (`"seg_99999" > "seg_100000"` lexically but
    `99999 < 100000`): 6-digit files list, ordering is numeric-descending not
    lexical (guarding the "code sorts numerically, never lexically" premise that
    justifies keeping `%05d`), and under-width junk stays excluded.
- **Rust unit (`recorder.rs`):** the new helper tests above.
- **Python self-test (`camera.py#run_self_test`):** the
  `recording_ffmpeg_output(... 7)` assertion still expects `.../seg_%05d.ts`
  (width unchanged) -- keep it. **Add** (a) a `detect_segment_events` case
  crossing the boundary -- `detect_segment_events(99999, 99999, ["seg_99999.ts",
  "seg_100000.ts"])` -> closed 99999 / opened 100000; and (b) `parse_segment_filename`
  cases mirroring the Rust unit tests -- accepts `seg_100000.ts` -> 100000, and
  rejects `seg_999.ts`, `seg_000005.ts`, and the overflow `seg_4294967296.ts`
  (all -> `None`).
- **Integration -- no-overwrite at the crossing (the core regression):** add a
  test that drives the *public start path* so next-seq is derived from on-disk
  names via `max_clip_seq` -- the data-loss symptom is `start_recording`
  reopening an existing file. Primary, in `tests/camera_process.rs` (real
  `camera.py` fake driver): **model it on
  `supervisor_tracks_rollover_and_finalizes_last_segment_on_stop` (seed files
  before `CameraProcess::spawn`) plus
  `supervisor_confirms_start_stop_and_records_with_idle_preview_subscriber`
  (start via `backend.start_recording().await`) -- NOT
  `python_fake_contract_honors_start_segment_and_emits_lifecycle`.** That last
  test sends `start_recording` over raw stdin with an *explicit*
  `start_segment_index` (`send_start_command`) and never calls `max_clip_seq`, so
  a test copied from it would hardcode the start index, exercise none of the
  buggy derivation, and pass both pre- and post-fix. Concretely: seed a 5-digit
  anchor `seg_99999.ts` **and** `seg_100000.ts` with recognizable sentinel bytes
  *before* `CameraProcess::spawn`; do **not** pass a short `--fake-segment-secs`
  (so the opened segment is observed stably -- otherwise the old code's wrong
  start `100000` would roll forward into `100001` and mask the bug);
  `backend.start_recording().await`; then assert (i)
  `wait_for_current_segment(&backend, 100001)` (old code stays at `100000` and
  this times out) and (ii) `seg_100000.ts`'s bytes still equal the sentinel (old
  code's ffmpeg reopened and truncated it). The 5-digit anchor is what makes this
  reproduce the *actual* overwrite on the old code (old parser: max `99999` ->
  start `100000` -> truncates the sentinel), so assertion (ii) genuinely fails
  pre-fix rather than only catching a wrong start id. Add the same seed/assert
  via `tests/mock_recording.rs` (`MockBackend` also derives next-seq through
  `max_clip_seq` over its HTTP `/v1/recording/start` path) as a
  python3-independent backstop, since the `camera_process.rs` suite self-skips
  when python3 is absent. Construct it with a **long** `roll_interval`
  (`MockBackend::recording_to(rec_dir, Duration::from_secs(30))`) -- the mock's
  analogue of the "no short `--fake-segment-secs`" guard: `run_mock_recording_writer`
  advances `seq` once `roll_interval` elapses, so a short interval would let
  pre-fix `100000` roll into `100001` and satisfy assertion (i) (masking the bug),
  and a tiny one could skip past `100001` post-fix and flake. The test still runs
  sub-second -- it observes the opened segment right after start, well within the
  interval. For assertion (i), poll `/v1/status` (as the existing test does via
  `poll_status_for_segment`) and assert the first observed `current_segment.id` is
  `100001`. Note `open_mock_segment` opens with `create(true).append(true)` (not
  truncate like the Python fake), so pre-fix the reopened `seg_100000.ts` *grows*
  to sentinel+packets rather than being wiped -- the byte-equality assertion (ii)
  still catches it (grown bytes != the sentinel).
- **Integration -- unchanged literals:** existing `seg_0000N.ts` literals in
  `tests/camera_process.rs` / `tests/mock_recording.rs` stay valid (width
  unchanged); confirm they still pass.

## Verification

1. `just raspi-check` -- `cargo fmt --check` + `clippy -D warnings`.
2. `just raspi-test` -- runs all Rust unit + integration tests, and transitively
   `python3 camera.py --self-test` and the `--fake` driver via
   `tests/camera_process.rs` (self-skips if python3 is absent).
3. The crossing regression is covered automatically by the no-overwrite
   integration test above (`just raspi-test`), so no 100k-segment recording is
   needed. For a quick local spot-check, in a scratch dir `touch seg_99999.ts
   seg_100000.ts seg_100001.ts` and confirm `max_clip_seq` returns 100001 and
   `read_finished_clips` lists the 6-digit entries.
4. Sanity: `python3 camera.py --self-test` exits 0 with the new assertions.

## Out of scope / deferred (to the storage coordinator, ADR 03)

- Durable, fsync'd `high_water_seq` and `next_seq = max(witnesses) + 1`.
- Oldest-first ring-buffer GC / eviction and the `segments/seg-<seq>.ts` subdir
  layout (hyphenated, with `index.log`, `state.json`, `incidents/`).
- ETag-aliasing protection after GC (the durable counter is what closes it).
