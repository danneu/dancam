# moss swoop: durable clip timestamps (segment fact stamping + per-boot time offset)

## Context

The Pi has no RTC, so its wall clock is garbage at boot; only CLOCK_BOOTTIME is
trustworthy. The camera records from recording start, and the phone syncs wall
time a few seconds into the drive -- after the first segments have already
opened. Today every clip is served with `start_ms: null` and
`time_approximate: true` (hardcoded), which makes footage weak as dashcam
evidence. The car cuts power without warning on every drive, so timestamps must
be durable across power cycles and the mechanism must be crash-safe.

Decision (made in discussion, from first principles): a derive-model --
**store measurements, not conclusions**.

- **Per-segment immutable facts live in the segment filename**:
  `seg_<seq>_<boottag>_<monoMs>.ts`, written once at segment open by the camera
  process. Nothing ever renames a stamped segment.
- **Per-boot interpretation lives in a tiny write-once offset file**:
  `<rec_dir>/time/<boot-uuid>.json`, written by a new `POST /v1/time` when the
  phone syncs. `offset_ms = epoch_ms - boottime_now_ms`.
- **Wall time is always derived at read time** (`start_ms = monoMs + offset`),
  never stored per segment. The moment the offset file lands, every segment of
  that boot -- past, future, and the one torn open by a power cut -- resolves.

Why this shape (vs stamping wall time into names, or a sidecar index): a power
cut can never permanently lose a knowable timestamp; the crash segment (the
evidence segment) derives correctly after reboot; facts are atomic with the
file (no index skew, no GC, self-describing SD card); and the offset machinery
is exactly what `nova`'s incident pre-sync holds need later. Precision is
bounded by the camera's segment-watcher poll (~0.25 s), so a single POST sync
suffices -- no RTT handshake (user-approved simplification of raspi ADR 02).

Scope (user-approved): the full moss swoop -- Pi storage, `POST /v1/time`, app
handshake, "time unverified" UI, real timestamps in the clips UI.

## Settled design

### Filename scheme (both forms valid forever)

- Stamped: `seg_<seq>_<boottag>_<monoMs>.ts`
  - `seq`: unchanged canon (zero-padded, min width 5, grows past 99999).
  - `boottag`: first 12 lowercase hex chars of the kernel boot UUID
    (`/proc/sys/kernel/random/boot_id`, dashes stripped).
  - `monoMs`: CLOCK_BOOTTIME ms at segment open, plain decimal, no padding.
  - Strict per-component round-trip parsing (reject aliases), keeping the
    existing Rust/Python lockstep discipline.
- Bare: `seg_<seq>.ts` = "facts unknown" -> `time_approximate: true` forever.
  It is the transient form ffmpeg creates before the watcher stamps it, the
  permanent form if power dies inside that ~0.25 s window, and what legacy
  files look like. Not a compat shim -- a live state of the system.

### Who stamps

camera.py's segment watcher (0.25 s poll, `camera.py#_watch_segment_events`).
ffmpeg's output pattern stays `seg_%05d.ts`; when `scan_once` detects a new
segment it captures CLOCK_BOOTTIME, renames bare -> stamped (fd-safe: ffmpeg
holds the fd and never re-opens by name), then emits `segment_opened`. Rename
failure logs and emits anyway (clip stays bare/approximate; never crash the
watcher). The fake driver mimics ffmpeg's write pattern -- bare names, a held
fd across the segment's life -- and rides the same watcher, so one stamp path
serves both drivers and gets exercised off-hardware. The camera stays dumb:
monotonic time and a boot tag are its own clocks, not wall time.

### Per-boot offset store (Rust service)

- `<rec_dir>/time/<full-boot-uuid>.json`:
  `{boot_id, offset_ms, source: "app", synced_at_mono_ms}`.
- CLOCK_BOOTTIME base for everything durable (NOT the EventHub `Instant` base:
  systemd `Restart=on-failure` can restart the service within a boot; boottime
  survives that, a process-relative clock does not).
- Write-once = frozen. Crash-safe write: tmp + fsync + rename + best-effort
  fsync(dir). "Already synced" means the file exists AND parses (a torn file
  must not brick the boot -- loader skips it, boot stays resyncable).
- Startup: load all offset files into a map keyed by boottag. A boottag prefix
  collision between two boots marks that tag unresolvable (approximate).
  Current-boot no-op detection keys on the full UUID.

### API and events

- `POST /v1/time`, body `{epoch_ms}`; hardened like other mutations
  (Content-Type + Idempotency-Key via the existing gate, Host allowlist is
  middleware). `epoch_ms` deserializes as `i64`; plausibility window: reject
  values outside `1_767_225_600_000 ..= 4_102_444_800_000` (2026-01-01Z ..
  2100-01-01Z) with 400 -- write-once means a garbage value would freeze a
  poisoned offset for the whole boot, so bounds-check before writing.
  Response: 200 `{"synced": true}`. Write-once makes replays naturally
  idempotent.
- Snapshot gains `time: {synced: bool}`; new `time_synced {at_ms}` event delta
  emitted on the false->true flip only (SSE contract: any world change emits a
  delta). Golden corpus fixtures updated on both sides.
- Clip listings and `clip_finalized` derive `start_ms`/`time_approximate`.
  `ClipsResponse.server_time_ms` (today: garbage `SystemTime` on an RTC-less
  Pi) becomes `Option<u64>`: derived wall when the current boot is synced,
  else null. This is a wire-breaking change and rides the same commit as the
  app's decode update.

### App handshake (stateless rule)

On every SSE `snapshot` (the existing once-per-connection seam in
`AppFeature.swift#reduce`, the `if case .snapshot` block): if `world.time` is
not synced (or nil), fire a `POST /v1/time` effect with the phone's epoch ms.
A failed POST schedules a short-delay retry rather than waiting for the next
snapshot (snapshots only arrive on reconnect, so a single early failure could
otherwise leave the whole drive unsynced while SSE stays healthy); the retry
loop ends the moment the world reports synced or the connection drops. No
boot_id comparison needed -- a
rebooted Pi presents `synced: false` and re-syncs automatically; a synced
same-boot reconnect skips; server-side write-once absorbs duplicates. On the
`time_synced` event: reload clips (pre-sync clips now carry real times). UI:
"Time unverified" status pill until synced; clip cells/viewer show created
time only when `startMs != nil && !timeApproximate` (the same gate
`Formatters.clipExportFilename` already uses, which needs no change).

## Implementation plan

Three commits, each independently green (`just raspi-test`, `just raspi-check`,
`just app-test`).

### Commit 1 -- `feat(raspi): stamp segment facts into filenames`

No wire change. Files: `raspi/service/Cargo.toml`, new
`raspi/service/src/clock.rs`, `raspi/service/src/recorder.rs`,
`raspi/service/src/clips.rs`, `raspi/service/src/events.rs`,
`raspi/service/src/backend.rs`, `raspi/camera/camera.py`, integration tests,
`raspi/README.md`, new ADR 15, notes in ADR 02/03, `docs/roadmap.md`.

**Rust:**

- `Cargo.toml`: rustix features `["fs", "time"]`.
- New `clock.rs`: `pub fn boottime_ms() -> u64` --
  `rustix::time::clock_gettime(ClockId::Boottime)` on Linux, `Monotonic`
  fallback elsewhere (cfg split; fallback is dev-only, recorded in ADR 15).
- `recorder.rs`: keep `segment_filename(seq)` (bare form -- it is the ffmpeg
  pattern and the rename source). Add:
  - `pub struct SegmentFacts { boot_tag: String, mono_ms: u64 }`
  - `pub struct ParsedSegment { seq: SegmentId, facts: Option<SegmentFacts> }`
  - `pub fn stamped_segment_filename(seq, &SegmentFacts) -> String`
  - `pub fn boot_tag(boot_id: &str) -> Option<String>` (strip dashes,
    lowercase, first 12 chars must be hex, else None -- handles test literals
    and the EventHub `"unknown"` default).
  - `parse_segment_filename` now returns `Option<ParsedSegment>`, accepts both
    forms, strictness via re-render round-trip equality (rejects mono leading
    zeros, tag case/length aliases).
- `clips.rs`: `segment_candidates` returns entries carrying
  `{seq, bytes, path, facts}` and dedupes same-seq preferring stamped. New
  `resolve_segment(rec_dir, seq)` (scan-based) replaces the
  `rec_dir.join(segment_filename(seq))` reconstruction in
  `clips.rs#serve_clip` (scan wrapped in `spawn_blocking`) and
  `clips.rs#clip_meta`. `clip_seq`/`max_clip_seq` parse both forms --
  **CRITICAL: if stamped names stopped parsing, the next `start_segment`
  would reset and ffmpeg would overwrite footage.**
- `events.rs#enrich_current_segment`: resolve by scan (the open segment may be
  bare or stamped when it runs).
- The finalize paths that call `clip_meta` (`camera/mod.rs#parse_stderr`
  and the mock writer in `backend.rs`) wrap the call in `spawn_blocking`,
  consistent with `list_clips`: the `resolve_segment` scan is new O(N)
  work per rollover, and the `ts_duration` read inside `clip_meta` was
  already blocking on the async event task -- one wrap fixes both.
- `backend.rs`: `MockBackend` stores a boot tag (set in `set_context` via
  `recorder::boot_tag`); `open_mock_segment` writes stamped names (bare
  fallback when the tag is underivable).

**camera.py (mirror the Rust canon, keep lockstep):**

- `SEGMENT_RE` -> `^seg_([0-9]+)(?:_([0-9a-f]{12})_([0-9]+))?\.ts$` plus the
  existing round-trip check; new `stamped_segment_filename`; `read_boot_tag()`
  (/proc, dash-strip, hex check; `secrets.token_hex(6)` fallback off-Linux);
  `mono_ms()` (`getattr(time, "CLOCK_BOOTTIME", None)` guard, monotonic
  fallback for `--fake` on macOS).
- `_watch_segment_events`/`scan_once`: per detected `segment_opened` seq,
  capture `mono_ms()` first, `os.rename(bare -> stamped)`, then emit; on
  rename failure log and emit anyway. `detect_segment_events` stays pure
  (parses both forms).
- Fake driver rides the watcher instead of emitting its own segment
  events: it writes bare names exactly like ffmpeg's output pattern,
  holds the fd open across the segment's life (write `FAKE_SEGMENT` in
  two chunks split at a 188-byte TS packet boundary -- one at open, one
  just before close-and-roll), and starts/stops the same
  `_watch_segment_events` thread the real driver already uses. This
  deletes the fake's duplicated `segment_opened`/`segment_closed`
  emission and puts the production stamp path (capture mono, rename
  under a live writer fd, emit) under `just raspi-test` -- otherwise
  that code would only ever run on real hardware.
- `run_self_test()`: stamped round-trips, alias rejections, stamped/mixed
  `detect_segment_events` cases; the exact ffmpeg arg-list assertion stays
  byte-identical (pattern unchanged).

**Tests:**

- recorder.rs: stamped round-trip past the five-digit boundary; stamped alias
  rejection; bare form parses with `facts: None`; `boot_tag` hex/None cases.
- clips.rs: `max_clip_seq` parses stamped names; `resolve_segment` prefers
  stamped over a bare duplicate; `read_finished_clips` dedupes same-seq.
- Integration: rewrite exact-name assertions in `tests/camera_process.rs` /
  `tests/mock_recording.rs` to seq-based helpers + assert new files match the
  stamped pattern; serve-by-id resolves a stamped segment; a mixed bare +
  stamped listing orders by seq; status enriches an open stamped segment.
  The existing `clip_finalized`/`/v1/clips` duration assertions in
  `tests/camera_process.rs` now run against segments that were renamed
  under a live writer fd, pinning that a stamped, previously-open segment
  still parses as valid TS with a plausible `dur_ms` -- the fd-safety
  premise behind the headline power-cut property, not just the name.
  Existing bare-fixture tests stay untouched (they now prove coexistence).

**Docs (same-change rule):**

- New `raspi/docs/design/15-2026-07-02-segment-fact-stamping-and-boot-offset.md`:
  records fact-stamping + write-once per-boot offset files + single-POST
  simplification. Supersedes/refines ADR 03's "Segment Identity And Time"
  storage (index.log facts -> filename facts; state.json boot-anchor table ->
  per-boot files; provisional->frozen -> freeze-at-first-sync) and ADR 02's
  RTT handshake + `{epoch_ms, tz, send_ts}` body. Explicitly answers ADR 03's
  alternatives-considered rejection of "wall-time filenames": this is a
  monotonic+boot stamp, wall stays derived, so that objection does not apply.
  Records accepted imprecision (~0.25 s stamp latency; single-POST sync) and
  the dev-only monotonic fallbacks. Also records the two capabilities
  write-once deliberately drops: GPS may no longer rebind a boot after
  freeze (ADR 03: "GPS is the deliberate override and may rebind a boot
  even after freeze"), and a first value that is wrong but inside the
  plausibility window can never be corrected (ADR 02's RTT refinement is
  gone) -- with the rationale: phone clocks are NTP-accurate, freezing
  protects evidence against a later bad write more than it costs in
  corrections, and a future GPS time source (`lark`) must revisit
  write-once explicitly via source priority rather than assume rebind.
- Dated `> **Note (2026-07-02):**` cross-refs inside ADR 02 and ADR 03
  (matching their existing dated-note practice).
- `docs/roadmap.md`: expand the moss one-liner into lime-style sub-checklist
  (Pi / App / Mock parity / Scope fence).
- `raspi/README.md` smoke test: segment listing/ffmpeg check becomes a glob;
  also fix the pre-existing drift where the smoke test sends
  `{"cmd":"start_recording"}` without `session_id`/`start_segment_index`
  (camera.py rejects that today).

### Commit 2 -- `feat(raspi): per-boot time offset store and POST /v1/time`

Files: new `raspi/service/src/time_sync.rs`, `lib.rs`, `recording.rs`,
`world.rs`, `events.rs`, `clips.rs`, `backend.rs`, `camera/mod.rs`,
`contract/events/`, new `tests/time.rs`, plus the app's passive decode
surface (required for per-commit greenness -- see below):
`Networking/Events/CameraEvent.swift` (enum case, `TimeStatus`,
`World.folding`), `Features/App/AppFeature.swift` (the exhaustive
`CameraEvent.logLabel` switch -- the new enum case does not compile
without it), `Networking/ClipsClient.swift`, and the touched app tests
(`CameraEventCorpusTests.swift`, `ClipsClientTests.swift`).

**TimeStore (`time_sync.rs`):**

- `TimeStore { dir, inner: Mutex<TimeState> }` -- one interior lock owns all
  mutable state (`TimeState {boot_id, by_tag: HashMap<String, TagOffset>,
  current: Option<OffsetRecord>}`); every method takes `&self`, so the
  `Arc<TimeStore>` shared across route/status/finalize paths needs no ad hoc
  external locking. `TagOffset::{Unique(i64), Ambiguous}`;
  `OffsetRecord {boot_id, offset_ms: i64, source, synced_at_mono_ms}`.
- API: `load(dir)` (skips torn/unparsable files), `in_memory()` (tests/stub),
  `set_boot_id`, `current_boot_synced()`, `offset_for_tag() -> Option<i64>`,
  `derived_wall_now_ms() -> Option<u64>`, `sync(epoch_ms: i64) -> SyncOutcome`.
- `sync` runs its whole check-then-persist-then-update sequence under the lock
  (the handler already wraps the call in `spawn_blocking`, so holding a std
  mutex across the short fsync'd write is fine); that lock is what makes
  "first offset wins" hold under concurrent first syncs.
- `offset_ms = epoch_ms - clock::boottime_ms() as i64` (no overflow possible:
  the route's plausibility window bounds `epoch_ms`). Persist via
  tmp + `sync_all` + rename + best-effort dir fsync.

**Plumbing** (mirrors `Backend::clip_durations` ownership -- the finalize
paths that build `clip_finalized` ClipMeta live in `camera/mod.rs#parse_stderr`
and the mock writer, which never see AppState):

- `Backend` trait gains `fn time_store(&self) -> Arc<TimeStore>` (default
  in-memory) and `fn mark_time_synced(&self) {}`.
- `MockBackend::recording_to` and `CameraProcess::spawn` create the store from
  `rec_dir.join("time")` and thread it to their finalize paths.
- `AppState::new`: fetch the store, `set_boot_id`, keep as a state field; seed
  `if time.current_boot_synced() { backend.mark_time_synced(); }` so a
  restarted already-synced service reports synced from the first snapshot.

**Route:**

- Promote `recording.rs#require_mutation_headers` to `pub(crate)`; new handler
  in `time_sync.rs` (`TimeSyncRequest {epoch_ms: i64}`); plausibility-window
  check -> 400; first sync writes the file (spawn_blocking) then
  `backend.mark_time_synced()`;
  an already-synced no-op still calls `mark_time_synced()` (heals a lagging
  World flag for free -- World emits only on the flip). Register
  `POST /v1/time` in `lib.rs#app`.

**World/events:**

- `World` gains `time_synced: bool`; `Input::TimeSynced` -> emit
  `Event::TimeSynced { at_ms }` only on false->true. `Snapshot` gains
  `time: TimeStatus { synced }` populated in `world.rs#World::snapshot`.
- Corpus: update `events.rs#canonical_events`/`canonical_name`; add
  `"time": {"synced": true}` to `contract/events/snapshot.json`; new
  `contract/events/time_synced.json`.

**Derivation:**

- `clip_meta` and `read_finished_clips` gain a `TimeStore` parameter:
  `start_ms = i64::try_from(facts.mono_ms).ok().and_then(|m|
  m.checked_add(offset)).filter(|ms| *ms >= 0)` -- checked all the way,
  because `mono_ms` comes from filename parsing (an unbounded decimal a
  corrupt name could inflate); overflow or a negative result degrades to
  `start_ms: None` / approximate rather than a fabricated clamp.
  `time_approximate = false` only when facts AND offset are both present and
  the derivation succeeds.
  Call sites in `camera/mod.rs` and `backend.rs` pass the backend's store, so
  `clip_finalized` events carry real `start_ms` once synced.
- `ClipsResponse.server_time_ms: Option<u64>` from `derived_wall_now_ms()`;
  delete the garbage `clips.rs#server_time_ms` SystemTime fn.

**App lockstep (decode-only, keeps `just app-test` green at this commit;
the corpus test would otherwise fail on the new fixture decoding `.unknown`):**

- `CameraEvent.timeSynced(atMs:)` decode case + `TimeStatus` struct; `World`
  gains `var time: TimeStatus? = nil` (explicit default spares
  `StatusClient.noop`/`CameraSamples` churn); `World.folding` sets synced on
  `.timeSynced`; the exhaustive event-label switch gains the case;
  `ClipsResponse.serverTimeMs: UInt64?` (and `ClipsClient.noop`'s literal
  becomes nil); corpus test literals updated; new `ClipsClientTests` case
  decodes `"server_time_ms": null` to `serverTimeMs == nil` (without it the
  suite could still pass against the old non-optional shape).

**Tests:**

- Unit (time_sync.rs): offset record round-trips through the file; load skips
  torn files; sync is write-once per boot; concurrent first syncs from
  multiple threads leave exactly one record and one offset file (first wins --
  the interior-lock regression test); ambiguous boottag resolves to None;
  `derived_wall_now_ms` requires current-boot sync. world.rs: flag flips once
  and projects into the snapshot. clips.rs: derives start_ms from facts +
  offset; stays approximate without either; degrades to approximate when the
  filename `mono_ms` would overflow the i64 derivation; cross-boot keying:
  with distinct offsets loaded for boots A and B and the current boot B, a
  boot-A-tagged segment derives via A's offset (value-asserted, so a bug
  that keyed on the current boot's offset fails the test), and with only
  boot B synced a boot-A segment stays approximate -- pins
  `offset_for_tag`, the boottag's reason for existing.
- Integration (new `tests/time.rs`): POST requires mutation headers; rejects
  epochs outside the plausibility window (below floor and above ceiling);
  first sync writes the offset file and emits `time_synced` (SSE: snapshot
  false -> POST -> `time_synced` frame -> fresh snapshot true); repeat sync is
  a no-op keeping the first offset; restart same boot loads the file and
  reports synced (two service instances over one rec dir with the same fixed
  UUID boot id -- this test, not the macOS mock loop, is what proves the
  restart property, since `lib.rs#fn resolve_boot_id` mints a fresh UUID per
  process off Linux); torn offset file is ignored and the boot resyncs.
- `tests/clips.rs`: clips derive start_ms after sync, and the same case
  asserts `server_time_ms` is non-null after sync (pins the derived-wall side
  of the `Option<u64>` wire contract, not just per-clip derivation); flip the
  existing `server_time_ms > 0` assertions to null for the unsynced case.
  `tests/status.rs`: snapshot carries
  `time.synced == false`. `tests/mock_recording.rs`: `clip_finalized` carries
  start_ms after sync.

### Commit 3 -- `feat(app): time-sync handshake and trusted clip times`

Files: new `Networking/TimeClient.swift`, `App/AppDependencies.swift`,
`Features/App/AppFeature.swift`, `Features/Home/HomeStatusPills.swift`,
`Features/Home/HomeViewController.swift`,
`Features/Home/ClipThumbnailCell.swift`,
`Features/ClipViewer/ClipViewerViewController.swift`,
`Support/Formatters.swift`, tests.

- `TimeClient`: struct-of-closures mirroring `RecordingClient.swift` exactly
  (`live(...)` with injectable `makeIdempotencyKey` plus an injectable
  `now: @Sendable () -> UInt64` epoch-ms clock defaulting to `Date()`-based,
  `.noop`). `sync()` takes no argument -- it reads `now()` at request-build
  time, so every attempt (first or retry) POSTs a fresh epoch by
  construction. POSTs `{"epoch_ms": n}` to `v1/time` with
  `Content-Type: application/json` + `Idempotency-Key`. Register in
  `AppDependencies` (`.noop` default in the test init, `.live` in the
  configuration init).
- `AppFeature.reduce`, inside the existing `if case .snapshot` block: when
  `state.link.world?.time?.synced != true`, append an effect
  `.run(id: timeSyncID, cancelInFlight: true)` -- a new static id beside
  `streamID`/`heartbeatID`/`reconnectID` -- calling
  `dependencies.time.sync()`, completing as a
  `.timeSyncResponded(success:)` action. On failure the reducer keeps the
  loop alive with a delayed retry under the same `timeSyncID` (mirroring
  `armReconnect`: sleep a few seconds via the existing injected
  `dependencies.sleep`, so tests run instantly, then send a retry action
  that re-enters the same fire logic). Lifecycle is owned by the effect
  system, the file's established idiom -- NOT by a state flag:
  `.streamStopped`, `.streamFailed`, and `.heartbeatTimedOut` add
  `.cancel(id: timeSyncID)` to the cancellations they already issue, and
  the `.timeSynced` event cancels it too. A disconnect thereby genuinely
  unschedules a pending retry sleep; a bool flag cannot revoke a
  scheduled sleep, so a stranded retry would fire after reconnect, pass
  the connected-and-unsynced guard, and duplicate the loop beside the
  fresh snapshot's attempt. No `timeSyncInFlight` state: only one
  snapshot arrives per connection, `cancelInFlight: true` collapses any
  overlap to a single live attempt, and the retry action still re-checks
  connected-and-unsynced as cheap idempotence, not as the correctness
  mechanism. Epoch freshness lives in TimeClient (the `now()` read at
  request-build time), keeping the reducer clock-free. New: on
  `.timeSynced` event, cancel `timeSyncID` and reload clips via the
  existing ClipsFeature load path (reuse `.load`; only add a silent
  variant if the loading flash proves jarring).
- "Time unverified" pill rides the ADR 17 selector projection
  (`app/docs/design/17-2026-07-02-selector-observation-and-view-state.md`),
  not a new observation: `HomeStatusPills` gains `timeUnverified: Bool`,
  computed in `HomeStatusPills.from` as false when `world` is nil
  (disconnected -- no pill) and `world.time?.synced != true` otherwise --
  with a world present this is the same predicate as the handshake, so a
  nil `time` can never mean "POST a sync" and "hide the warning" at once.
  Add the `StatusPillView` in `HomeViewController.configureStatusPills`
  and drive its visibility from `renderStatusPills`; the existing
  `store.observe(select: { HomeStatusPills.from($0.link.world) })`
  subscription picks up the new field for free because the projection is
  `Equatable`.
- Timestamp-only clip updates ride the existing diffable reconfigure
  path, untouched: after `time_synced` reloads clips, a clip with the
  same `id`/`etag` but new `startMs`/`timeApproximate` compares unequal
  as a `HomeRow`, so `HomeRowDiff.reconfiguredIDs` marks it and the
  snapshot's `reconfigureItems` refreshes the visible cell in place.
  `ClipThumbnailIdentity` stays `(id, etag)` -- the created-time subtitle
  must NOT enter thumbnail identity (a `startMs` flip would junk the
  painted thumbnail and refetch), and no `reloadData` fallback.
- `Formatters`: `clipCreatedTime(_:timeZone:) -> String?` gated on
  `startMs != nil && !timeApproximate`; wire into `ClipThumbnailCell`
  subtitle and the clip viewer caption. `seg_%05d.ts` titles stay (display
  strings built from the numeric id -- unaffected by on-disk naming).
- Tests (Swift Testing): AppFeatureTests -- unsynced snapshot fires the POST,
  synced snapshot skips, nil-time snapshot fires, failed sync schedules a
  retry that eventually succeeds, `timeSynced` cancels the loop (no
  further attempts once synced), failed sync -> disconnect (each of
  `.streamStopped` / `.streamFailed` / `.heartbeatTimedOut`) -> the
  pending retry never fires (cancellation, not a guard: completing the
  injected sleep produces no further attempts) and an unsynced reconnect
  snapshot starts exactly one fresh attempt, `timeSynced` refreshes clips
  (extend the private `dependencies(...)` helper with `time:`);
  TimeClientTests mirroring RecordingClientTests plus a freshness case (two
  `sync()` calls against an advancing injected `now` POST two different
  epochs); FormattersTests for the created-time gate; `HomeStatusPillsTests`
  covering `timeUnverified` for `world == nil` (false), `time == nil` and
  `synced == false` (both true), and `synced == true` (false), plus a
  `HomeViewControllerTests` render case that the pill's visibility follows
  the projection; a `HomeViewControllerTests` case where a reloaded clip
  with the same `id`/`etag` but new `startMs` reconfigures the visible row
  in place -- subtitle changes, the painted thumbnail survives, and no new
  thumbnail load starts; `CameraSamples` gains
  `time`/`startMs`/`timeApproximate` params.

## Edge cases (must hold at the end)

1. Bare/stamped coexistence: both parse; bare = approximate forever; no
   retroactive re-stamping.
2. `max_clip_seq` parses both forms (dedicated unit test + integration
   sentinel: existing footage is never overwritten after restart).
3. Open-segment resolution is scan-based: found bare (pre-stamp window or
   power-loss remnant) or stamped.
4. Duplicate same-seq bare + stamped: prefer stamped, dedupe in the scan --
   one ClipMeta per seq, deterministic serve.
5. Watcher rename vs its own next scan: stamped parses to the same seq;
   `prev_max` guards dedupe; rename precedes the emit; rename failure emits
   anyway.
6. Torn `time/` file: loader skips it; "synced" = exists AND parses; the boot
   stays resyncable.
7. Boottag prefix collision -> tag unresolvable -> approximate; no-op logic
   keys on the full UUID.
8. Epoch plausibility window (2026-01-01Z .. 2100-01-01Z) rejects garbage
   phone clocks before the write-once freeze can poison a boot; offset math
   in i64 with checked conversion/addition at derivation; overflow or a
   negative result degrades to approximate instead of clamping.
9. Portability: Rust Boottime/Monotonic cfg split; Python CLOCK_BOOTTIME
   getattr guard. On macOS the camera.py fake's random tag will not match the
   service's boot_id -- those segments stay approximate (fine; `just
   raspi-mock` uses the Rust mock writer, which shares the service's boot_id,
   so end-to-end derivation works on the Mac).
10. Non-UUID boot ids (test literals, "unknown" default): `boot_tag` returns
    None; writers fall back to bare names.

## Verification

1. Per commit: `just raspi-test` (includes the python3-gated camera_process
   integration test with the stamped fake) and `just raspi-check` (clippy
   `-D warnings`); `just app-test` for commits 2-3.
2. `python3 raspi/camera/camera.py --self-test` pins the two-form canon in
   lockstep with recorder.rs.
3. Mock loop end-to-end: `just raspi-mock`; `GET /v1/status | jq .time` ->
   `{"synced": false}`; start recording -> `.mock-rec/seg_00000_<tag>_<mono>.ts`
   appears; `GET /v1/clips` -> null `server_time_ms`, null `start_ms`;
   `curl -X POST /v1/time -H 'Content-Type: application/json'
   -H 'Idempotency-Key: t1' -d '{"epoch_ms": <now>}'` -> 200,
   `.mock-rec/time/<uuid>.json` appears, SSE emits `time_synced`;
   `GET /v1/clips` now shows derived `start_ms` and real `server_time_ms`;
   repeat POST -> offset unchanged. (Do not expect restart-stays-synced from
   the mock loop: off Linux `lib.rs#fn resolve_boot_id` mints a fresh UUID
   per process, so a restarted mock is a "new boot" by construction; that
   property is proven by the fixed-boot-id restart test in `tests/time.rs`
   and by the real-Pi check below.)
4. Manual app flow against the mock: simulator + `just raspi-mock` -> app
   auto-POSTs on snapshot, "Time unverified" pill clears on `time_synced`,
   clip rows gain created times; `rm -rf raspi/service/.mock-rec/time` +
   restart simulates a reboot -> app re-syncs on the next snapshot.
5. Real Pi: README smoke test as amended (stamped glob), then record -> sync
   from the app -> stamped names in `/var/lib/dancam/rec`, derived `start_ms`
   in `/v1/clips`; `sudo systemctl restart dancam` (same boot) -> first
   snapshot already synced; reboot flips the app back to unverified until the
   next handshake; power-cut mid-recording -> after reboot the torn segment
   still lists with a real `start_ms` (the headline property).
6. `just adr-check` after the docs commit.

## Commit progress

- [x] 1. feat(raspi): stamp segment facts into filenames
- [ ] 2. feat(raspi): per-boot time offset store and POST /v1/time
- [ ] 3. feat(app): time-sync handshake and trusted clip times
