# Group clips into recordings, not boots

## Context

Today the app batches clips into "drives" keyed by Pi boot (`boot_tag`). One boot can
contain several distinct recording runs (manual stop/start today; CarPlay auto
start/stop in the `reef`/`sage` swoops will make this the norm), and all their clips
collapse into a single drive card. The fix: the browse unit becomes a **recording** --
a contiguous run of capture -- identified by the pair `(boot_tag, session)`, where
`session` (`raspi/service/src/recorder.rs#SessionId`, u64) is a per-recording
discriminator, `>= 1`, that is **durable across a same-boot service restart**. The
recording model strictly generalizes the boot model: an untouched ignition-switched
boot has exactly one session, so grouping is unchanged in the common case.

**Why "recording," not "drive."** A *recording* is an observable fact: one contiguous
capture run, bounded by a start and a stop the system actually witnesses and stamps into
`(boot_tag, session)`. A *drive* or *trip* is a real-world notion the unit cannot
observe -- it has no ignition signal, odometer, or GPS trip boundary -- and a single
drive may contain zero, one, or many recordings (manual stop/start, a CarPlay auto
start/stop, or a mid-trip power blip and service restart each split one drive into
several). Because the only boundary the app can see is the recording, that is the browse
unit and the product vocabulary; calling a group of clips a "drive" would falsely assert
trip semantics the system never captured. This is the domain rule the rename below
enforces -- and the reason recording boundaries must never be treated as trip boundaries.

**Session must derive from durable storage, not an in-process counter.** The FSM today
increments `session` from a process-local field (`RecorderState::new` seeds it to 0,
`start` does `saturating_add(1)`), so after a systemd restart within the same boot the
next recording is session 1 again -- under the same `boot_tag` -- and two unrelated
recordings merge. That defeats the whole durability claim precisely during crash
recovery. So this plan re-sources `session` from the durably reserved **start
segment**: `RecorderState::start` computes `session = u64::from(start_segment) + 1`. The
start segment already comes from the storage coordinator's high-water witness
(`raspi/service/src/storage.rs#reserve_start_segment`, ADR 16), which is fsync-durable
and strictly increasing across service restarts and reboots -- and, with the Commit 1
fail-closed fix below, refuses to allocate past the `u32` seq ceiling rather than
wrapping -- so it never reissues a session within a rec dir's lifetime. No new counter
file, manifest, or crash window.

Session already rides the live events (`recording_started`, `segment_opened`,
snapshot `recorder.session`) and is already in scope at both segment-stamping sites;
it is just never persisted. The raspi change is two parts: (1) re-source `session` from
the durable start segment (above) so the identity survives a same-boot restart, and
(2) stamp it into segment filenames (the crash-safe fact store). Then lift it onto
`ClipMeta`/the wire and re-key the app's grouping, attribution, and detail screens from
`bootTag` to the pair.

Settled design points:

- **Filename identity, no manifest.** Extends ADR 15's fact-stamping; grouping stays
  reconstructible from a directory listing, survives power loss by construction.
- **Durable identity, no new state.** `session` derives from the storage coordinator's
  already-durable start-segment reservation (`start_segment + 1`, ADR 16 witness), so
  `(boot_tag, session)` survives a same-boot service restart without a session counter
  file, sidecar, or manifest.
- **No legacy parse.** The old 3-part stamped form is rejected outright (repo stance:
  no compat shims). Old dev files become invisible to scanners; wipe them manually.
- **Facts are all-or-nothing.** A stamped name carries boot_tag + session + monoMs
  together; bare `seg_<seq>.ts` carries none.
- **Pi stays dumb.** No grouping endpoint; per-clip identity is all the server owes.
  Grouping remains a pure app-side view fold.
- **UI vocabulary becomes "Recording".** This change also retires the "Drive" domain
  noun across the active tree -- types, enum cases, helpers, user-visible labels, tests,
  living docs (roadmap, AGENTS indexes, contract README) -- all move to "Recording"
  (full mapping and intentional survivors in Commit 3's "Retire the 'Drive' domain
  noun" block). `session` survives only as the low-level persisted/wire discriminator;
  `Recording`/`RecordingID` is the app/domain noun that pairs `boot_tag` with it. No
  gap-between-cards annotation (iceboxed).

## Filename grammar (goes verbatim into raspi ADR 20)

```text
Bare:    seg_<seq>.ts
Stamped: seg_<seq>_<boottag>_<sess>_<monoMs>.ts
```

- `seq` -- decimal u32, zero-padded to a minimum of 5 digits, grows wider past 99999.
  A `u32::MAX` seq is a valid *parse* (the last legal segment). Start allocation
  (`reserve_start_segment`) **fails closed** at the ceiling rather than reissuing the id,
  so seq -- and the session derived from it -- never reissues (Commit 1). Within a
  recording, the two writers this project controls -- the Rust mock and the Python fake
  driver -- also fail closed at `u32::MAX` rather than advancing past it. The real-camera
  path delegates segment numbering to ffmpeg, whose `segment_start_number` is a signed int
  (`0..=INT_MAX`) that bounds only the *starting* number, not rollover. ffmpeg documents
  no post-`INT_MAX` numbering behavior; a local probe of the tested build was *observed* to
  keep counting into wrapped/negative names rather than stopping or failing closed, but
  that is an unspecified, build-dependent implementation detail, not a contract. Reaching
  `INT_MAX` at 30 s segments is millennia out, beyond any device lifetime, so post-`INT_MAX`
  numbering sits outside the supported-lifetime contract -- the real path carries no runtime
  guard, an honest boundary, not a runtime ceiling and not a no-write guarantee across the
  full `u32` range.
- `boottag` -- exactly 12 lowercase hex chars (kernel boot UUID, dashes stripped). Unchanged.
- `sess` -- the recorder session id (u64), plain decimal, unpadded, no larger than
  `u64::MAX` (the parser rejects an oversized value; both implementations bound it --
  see Commit 1). By construction `sess >= 1`: it is `start_segment + 1` from the
  durably reserved start segment (`start_segment >= 0`), computed in
  `RecorderState::start`. Documented invariant, not a parser `>= 1` special case.
- `monoMs` -- CLOCK_BOOTTIME ms at first observation of the open segment. Unchanged.
- Parser canon unchanged in philosophy: a name is valid iff re-rendering the parsed
  fields reproduces it byte-for-byte (rejects leading-zero/signed sess and mono,
  uppercase/short/long tags, non-round-trip seq) **and every numeric field is in range**
  (`seq <= u32::MAX`, `sess` and `monoMs <= u64::MAX`). Byte-for-byte round-trip alone
  is not enough: Python ints are unbounded, so an oversized `sess`/`monoMs` re-renders
  identically yet Rust's `u64` scan would drop it -- both parsers must reject it to stay
  byte-identical. 3-part names fail the part-count match and are rejected.

## Commit 1 -- `feat(raspi): stamp recorder session into segment filenames`

Raspi-internal; `ClipMeta` untouched, all raspi tests green at this commit.

**`raspi/service/src/recorder.rs`**
- **Re-source the session (the durability fix).** `RecorderState::start` sets
  `self.session = u64::from(start_segment) + 1` instead of `saturating_add(1)` on an
  in-process field; drop the counter semantics (the field is now recomputed per start,
  not carried across starts). `start_segment` is the durable, monotonic high-water
  reservation (ADR 16), so a same-boot restart cannot reissue session 1. Idle still
  reads session 0 from `new()`; `start` overwrites it. Nothing downstream changes: the
  value still flows out via `Event::RecordingStarting { session }` and the
  `session_id`/`start_segment_index` camera command, which already sit side by side at
  both call sites (`backend.rs#start`, `camera/mod.rs`).
- `SegmentFacts` gains `pub session: SessionId` between `boot_tag` and `mono_ms`
  (field order mirrors the filename); doc-comment the `>= 1` / `start_segment + 1`
  invariant.
- `stamped_segment_filename` renders 4 parts.
- `parse_segment_filename`: the 3-element match arm becomes
  `[seq_digits, boot_tag, session_digits, mono_digits]`; parse `session_digits` as
  `u64` (`.parse::<u64>().ok()?` rejects `> u64::MAX`) and keep the exact round-trip
  guard. 3-part bodies fall to `_ => None`.
- Tests:
  - `start_seeds_session_phase_and_unpullable_floor` now expects
    `start(43) -> Some(44)` / `snapshot.session == 44` (the other FSM tests thread the
    returned `session` symbolically and are unaffected).
  - Add `session_derives_from_start_segment_not_an_in_process_counter`: two *fresh*
    `RecorderState::new()` instances -- simulating a service restart -- reserving at
    start segments 0 then a higher value produce *different* sessions (1, then
    `start_segment + 1`), proving fresh state does not reset the discriminator to 1.
  - Update `stamped_segment_filename_round_trips_past_the_five_digit_boundary`
    (literals become e.g. `seg_00000_abc123def456_7_987654321.ts`; add a `u64::MAX`
    session round-trip). Re-derive the alias lists in
    `stamped_segment_filename_rejects_non_rendered_aliases` and
    `parse_segment_filename_rejects_non_rendered_aliases` for 4 parts; add the old
    3-part form as an explicit reject (the no-legacy pin) **and** an oversized-`sess`
    (`seg_00005_abc123def456_18446744073709551616_7.ts`) and oversized-`monoMs`
    (`..._18446744073709551616.ts`) name as explicit rejects -- the overflow pin: these
    round-trip textually but exceed `u64`, so the range guard, not just re-render, must
    drop them.

**`raspi/service/src/storage.rs`** (make start allocation strictly monotonic -- the
no-reissue fix)
- Today `next_start_segment` chooses `max(witness, scan).saturating_add(1)`, so once a
  `u32::MAX` seq exists (as the witness value or an on-disk file) it returns `u32::MAX`
  *again* -- reissuing the start id, and therefore the derived session, and minting a
  same-seq stamped twin. That silently contradicts ADR 20's no-reissue guarantee.
- Change `next_start_segment` to **fail closed** when `max(witness, scan) == u32::MAX`:
  return an `InvalidData` error instead of a duplicate id. It runs before
  `persist_witness`/`commit` inside `reserve_start_segment`, so failing there mutates no
  state and surfaces through the existing HTTP-start fail-closed path (500 "storage
  allocation failed", recorder stays idle) -- the same path the corrupt-witness case
  already uses.
- Tests (`storage.rs`): `allocate_start_segment` fails closed on witness exhaustion
  (`high_water_seq == u32::MAX`) and on a max-valued scan (a `seg_<u32::MAX>.ts` file is
  the scan max); a witness/scan at `u32::MAX - 1` still allocates `u32::MAX` (the last
  legal id) and any further start then fails closed. Integration
  (`tests/mock_recording.rs`): `writer_mock_start_fails_closed_when_segment_ids_are_exhausted`
  -- seed the witness at `u32::MAX`, POST start, expect 500 "storage allocation failed",
  recorder idle, no segments written (mirrors
  `writer_mock_start_fails_closed_when_witness_is_corrupt`).

**`raspi/service/src/backend.rs`**
- `open_mock_segment` gains a `session: u64` param feeding the `SegmentFacts` literal;
  both call sites in `run_mock_recording_writer` pass the in-scope
  `MockRecordingContext.session`.
- **Rollover fail-closed at the seq ceiling.** The rollover advance
  `seq = seq.saturating_add(1)` in `run_mock_recording_writer` reissues `u32::MAX` once
  the ceiling is reached, and `open_mock_segment` (a fresh `mono_ms` each call) would
  then mint a *second* stamped file at the same seq -- a same-seq twin inside one
  session. Guard the advance: when `seq == u32::MAX`, drive
  `Input::Fail { detail: "mock recording exhausted segment ids at u32::MAX" }` and
  return instead of reopening the id or emitting `SegmentRollover`, mirroring the
  loop's existing IO-failure arms. This is the within-recording complement to the
  start-allocation fail-closed in `storage.rs` above (start refuses to *reserve* past
  the ceiling; rollover refuses to *advance* past it). Test
  (`tests/mock_recording.rs`): `writer_mock_start_at_ceiling_fails_closed_on_rollover`
  -- seed the witness/scan max at `u32::MAX - 1` so start reserves `u32::MAX` (the last
  legal id -- allocation succeeds), POST start, let one roll interval elapse, then
  assert the recorder is Failed, exactly one `seg_<u32::MAX>_<tag>_<sess>_<mono>.ts`
  exists (no same-seq twin, no out-of-range file), and no second
  `segment_opened`/`SegmentRollover` was emitted -- the rollover complement to
  `writer_mock_start_fails_closed_when_segment_ids_are_exhausted` (the start guard at
  witness == `u32::MAX`).

**Test-helper `SegmentFacts` literals gain `session`** (mechanical, same pattern):
`clips.rs#stamped_name_with_mono`, `storage.rs` test helper `stamped_name`, and the
integration helpers in `tests/clips.rs`, `tests/status.rs`, `tests/mock_recording.rs`.

**Strengthen the stamping guards** to assert the stamped *session value*, not just
facts-present: `tests/mock_recording.rs#assert_new_segments_are_stamped` and
`tests/camera_process.rs#assert_new_segments_are_stamped` take expected
`(seq, session)` pairs. The camera-process supervisor test performs two immediate
start/stop runs (segments `[0, 1]`), so it is the end-to-end proof that two same-boot
recordings stamp *distinct* sessions: run 1 reserves start segment 0 (session 1), run 2
reserves the next segment (start segment 1, session 2). Assert each run's stamped
session equals its `start_segment + 1` and that the two differ -- via that formula, not
hardcoded literals (they are 1 and 2 here only because each run writes a single
segment). The raw-protocol test still expects its commanded `session_id` 99: it drives
the camera process directly (`send_start_command(.., 99, 5)`), bypassing the FSM
derivation, and is unaffected.

**Durability regression (the crux).** Add a test in `tests/mock_recording.rs` that
simulates a full same-boot service restart at the real composition seam. Build the first
`StorageCoordinator` + `MockBackend` + `AppState` (with the fixed `BOOT_ID` const), drive
one recording, then **drop all three** and construct a *brand-new*
`StorageCoordinator::new(same rec_dir)` + `MockBackend` + `AppState` against the same
recording directory and the *same* explicit `BOOT_ID`, and drive a second recording.
Assert the second recording stamps `session != 1` (specifically `start_segment + 1 > 1`,
where `start_segment` lands past run 1's segments), so a same-boot restart no longer
merges recordings. Reusing the *same* coordinator would not do: it would leave the
reconstruct-witness-from-disk seam untested, so the test must pass only because a freshly
rebuilt coordinator re-reads the witness and feeds the correct reservation into a fresh
`RecorderState` (whose in-process session counter has reset to 0). This is the
integration counterpart to the storage-only `restarted`-coordinator unit test in
`storage.rs` (`allocate_start_segment` off a rebuilt coordinator against the same dir),
extending it across the coordinator->recorder boundary.

**`raspi/camera/camera.py`** (second stamping implementation, must stay byte-identical)
- Add `U64_MAX = 0xFFFF_FFFF_FFFF_FFFF` alongside the existing `U32_MAX`.
- `SEGMENT_RE` -> `r"^seg_([0-9]+)(?:_([0-9a-f]{12})_([0-9]+)_([0-9]+))?\.ts$"`
  (group 2 stays the tag, so `resolve_segment_path`'s group(2) check is untouched).
- `stamped_segment_filename` and `stamp_segment` gain a `session_id` param in filename
  order; `parse_segment_filename` reads groups 2/3/4 all-or-nothing and, alongside the
  existing `seq > U32_MAX` guard, **rejects `session > U64_MAX` and `mono_ms > U64_MAX`**
  before re-rendering (the current parser bounds neither -- oversized `monoMs` is a
  pre-existing divergence from Rust's `u64` scan that this byte-identical grammar
  closes here). Bounding before re-render is what keeps an oversized field from
  round-tripping.
- `watch_segment_events`'s inner `scan_once` passes its already-in-scope `session_id`
  to `stamp_segment`.
- **Rollover fail-closed at the seq ceiling (fake driver).** `_recording_loop` advances
  with `new = self.current_segment_index + 1`; Python ints are unbounded, so at
  `U32_MAX` it opens `seg_4294967296.ts` -- an out-of-range name `parse_segment_filename`
  rejects, so the segment is silently dropped from the event stream and the scanner.
  Guard the advance (a small `next_segment_index(seq) -> int | None` helper keeps it
  self-testable): at `current_segment_index == U32_MAX`, stop recording and
  `emit_event("error", detail="segment ids exhausted at u32::MAX")` instead of opening
  the overflow file. (`RealCameraDriver` delegates numbering to ffmpeg, whose
  `segment_start_number` is a signed int (`0..=INT_MAX`) bounding only the starting number,
  not rollover -- post-`INT_MAX` numbering is unspecified (a probe of the tested build was
  observed to wrap into negative names rather than fail closed, but that is a build-dependent
  detail, not a documented contract). Reaching `INT_MAX` at 30 s segments is millennia out,
  beyond any device lifetime, so post-`INT_MAX` behavior is outside the supported lifetime
  rather than a runtime ceiling; the real path gets no runtime guard and none is promised.
  No watcher net: a post-hoc directory scan could only report an overflow file *after*
  ffmpeg had already written it, and would key to the wrong value anyway (`u32::MAX`, while
  ffmpeg's start-number limit is the lower `INT_MAX` and its post-`INT_MAX` numbering is
  unspecified), so it delivers no prevention. See the grammar's honest-boundary note.)
- **Behavioral coverage of the fake-driver guard**
  (`tests/camera_process.rs#supervisor_fake_driver_fails_closed_at_seq_ceiling`):
  unit-testing `next_segment_index` alone proves the arithmetic but not that
  `_recording_loop` shuts recording down, writes no overflow file, and emits the error the
  Rust supervisor turns into a failed recorder. Make it a **supervisor-level** test so it
  verifies the whole end-to-end failure contract (child `error` -> `CameraProcess`
  `Input::Fail` -> `RecorderPhase::Error`), not just the child's stderr: driving the fake
  process directly (as `python_fake_contract_honors_start_segment_and_emits_lifecycle`
  does) would still pass if `CameraProcess` stopped translating child errors into
  `Input::Fail`, leaving that contract unverified. Model it on
  `supervisor_tracks_rollover_and_finalizes_last_segment_on_stop` (seed a scan-max file,
  spawn the real `--fake` child with a short `--fake-segment-secs` via `CameraProcess::spawn`
  behind `AppState`, drive through the supervisor): seed the witness/scan max at
  `u32::MAX - 1` so `reserve_start_segment` returns `u32::MAX` (the last legal id -- start
  succeeds), `wait_for_current_segment(&backend, u32::MAX)`, then let one roll interval
  elapse and `wait_for_recorder_phase(&backend, RecorderPhase::Error)` (the
  `supervisor_marks_child_restarting_after_crash` precedent). Then inspect raw directory
  names (raw `fs::read_dir`, not the `segment_ids` helper, which parses names and so filters
  an overflow file out): exactly one `seg_<u32::MAX>_<tag>_<sess>_<mono>.ts` exists and no
  `seg_4294967296.ts` was created -- the end-to-end proof that the ceiling rollover drives
  the recorder to Error and neither duplicated nor overflowed the id. This is the fake-driver
  counterpart to the Rust mock's `writer_mock_start_at_ceiling_fails_closed_on_rollover`.
- `run_self_test`: update stamped literals to 4-part, re-derive the reject list, add
  the old 3-part literal as a reject, add oversized-`session` and oversized-`monoMs`
  literals as rejects (mirroring the Rust overflow-reject cases so both self-tests pin
  the same bound), and add the two ceiling cases pinning the guard's arithmetic:
  `next_segment_index(U32_MAX) is None` (rollover fails closed) while
  `next_segment_index(U32_MAX - 1) == U32_MAX` (the last legal advance). The
  recorder-goes-to-Error and no-overflow-file behavior is covered by the supervisor-level
  `tests/camera_process.rs` behavioral test above, not the self-test.

**New ADR `raspi/docs/design/20-2026-07-09-recording-session-in-segment-filenames.md`**
- Context: one boot holds many recordings; session (ADR 10) lived only in a
  process-local counter, so it reset on a same-boot service restart and never reached
  the durable facts; filenames are the only crash-safe fact store.
- Decision: owns the full grammar above going forward. **Session is sourced from the
  durably reserved start segment (`start_segment + 1`, ADR 16 witness), not a
  process-local counter** -- this is what makes `(boot_tag, session)` survive a
  same-boot restart. For that derivation to never reissue, **start-segment allocation
  fails closed at the `u32` ceiling** (ADR 16 refinement below): at `max == u32::MAX` it
  returns an error instead of reissuing the id, so no seq -- and no session derived from
  one -- is ever reissued. Within a recording, the two writers this project controls (the
  Rust mock and the Python fake driver) likewise fail closed at `u32::MAX` rather than
  advancing. The real-camera path delegates numbering to ffmpeg, whose
  `segment_start_number` is a signed-int start-number limit (`0..=INT_MAX`) that bounds only
  the starting number, not rollover, with post-`INT_MAX` numbering left unspecified (a
  build-dependent implementation detail, not a documented contract) rather than pinned;
  reaching `INT_MAX` at 30 s segments lies millennia beyond any device lifetime, so
  post-`INT_MAX` numbering is documented as outside the supported lifetime -- not a runtime
  ceiling and not covered by a no-write guarantee across the full `u32` range. 3-part form rejected, no compat parse; both parsers bound numeric fields
  to their integer types (`u32` seq, `u64` sess/mono).
- Consequences: a recording is reconstructible from the SD card alone and survives a
  service restart mid-boot; facts all-or-nothing; session 0 never appears by
  construction (`start_segment >= 0`); same-seq stamped twins across sessions cannot
  occur (start allocation is strictly monotonic and fails closed at the `u32` ceiling --
  the ADR 16 refinement below -- never repeating an id), and a within-recording rollover
  in the writers we control likewise fails closed at the ceiling rather than minting a
  same-seq twin, so `clips.rs#dedupe_candidates` is unchanged; pre-change stamped dev
  files invalidated
  (dev-only, wiped).
- Alternatives: session sidecar/counter file (adds a crash/skew window this avoids by
  reusing the existing durable witness); encoding session in seq ranges (aliasing);
  accepting both filename forms (two canons, contradicts no-shim stance).
- **ADR bookkeeping -- scoped supersession, not whole-file.** ADR 20 supersedes only the
  decisions it actually changes and does not re-own subsystems it leaves untouched
  (scoped supersession matches repo precedent: raspi ADR 02 "Superseded (thumbnails) by
  app ADR 16", ADR 13 "Superseded, for request-id format only"):
  - **ADR 10 stays `Accepted`** (still owns FSM phases, floor, event guards, SSE
    framing). Add a scoped note on its `session` bullet: the "monotonic per-boot session
    id, starting at 0" definition is superseded, *for the session id only*, by ADR 20
    -- session is now `start_segment + 1`, durable across a same-boot restart.
  - **ADR 15 stays `Accepted`** -- it remains the normative home for its still-active
    decisions: bare-form semantics, watcher rename/emit, write-once per-boot offset
    durability + boottag-collision + torn-file recovery, `/v1/time` bounds, read-time
    `start_ms = monoMs + offset_ms` resolution, and the snapshot/event time contract.
    Add a scoped note: *only* its segment filename grammar and Rust/Python parser canon
    are superseded by ADR 20 (session field added; overflow bound). ADR 20 does **not**
    restate the offset/time model -- it references ADR 15 as the live owner and merely
    defines the `monoMs` field that model consumes, unchanged. (This replaces the
    earlier plan step of marking ADR 15 whole-file `Superseded`, which would have
    orphaned its offset/time decisions.)
  - **ADR 16 stays `Accepted`** -- it still owns the storage coordinator, the durable
    `high_water_seq` witness, write-ahead-delete, and corrupt-witness fail-closed. Add a
    scoped note: its allocation rule (Decision step 3, `next =
    max(high_water_seq, max_file_seq).saturating_add(1)`) is superseded by ADR 20 *for
    the ceiling case only* -- at `max == u32::MAX` allocation fails closed instead of
    returning a duplicate id, so start-segment reservation (and the session derived from
    it) is strictly monotonic and never reissues. ADR 20 needs this because it now
    sources recording identity from that reservation; the append-only scoped note keeps
    ADR 16 the live owner of everything else.

**Index update.** Add ADR 20 to `raspi/AGENTS.md`'s "Design decisions (ADRs)" list in
its one-line-per-ADR form. The index currently stops at ADR 18, so also backfill the
missing ADR 19 (`19-2026-07-08-inflight-segment-durability-and-boot-scrub.md`) entry --
this brings it through ADR 20.

**Operator cleanup (not committed):** clear the untracked old-format dev artifacts.
`git clean -fdX raspi/service/assets/clips` removes *every* git-ignored stamped clip
(all 61 old 3-part `seg_NNNNN_<tag>_<mono>.ts` files -- a narrow `seg_0000*_*.ts` glob
would catch only `seg_00000`-`seg_00009`, missing segments 10-60 -- plus any ignored
`assets/clips/state/` / `assets/clips/time/` subdirs) while preserving the tracked bare
`assets/clips/seg_00000.ts` (git-tracked, so `-X` leaves it). Then remove the scratch
dirs outside that path -- `.mock-rec-investigate/` and any `.mock-rec*` -- and wipe the
physical Pi's rec dir if it holds old-format footage.

## Commit 2 -- `feat(contract): carry recorder session on finished clips`

The lockstep wire change: Rust serializes, the fixture pins, Swift decodes -- one
commit because the shared corpus (`contract/events/`) gates both test suites.

**Raspi**
- `raspi/service/src/clips.rs#ClipMeta` gains `pub session: Option<u64>` after
  `boot_tag`; `clips.rs#clip_meta_from_candidate` lifts `facts.session` next to the
  existing `boot_tag` lift (single construction point).
- Extend `read_finished_clips_reports_boot_tag_for_stamped_segments_only` to assert
  `session` Some-for-stamped / None-for-bare.
- `events.rs` corpus literal for `ClipFinalized` gains `session: Some(7)` (matches the
  snapshot fixture's recorder session 7); `world.rs` test helper `clip(id:)` gains
  `session: None`.
- `tests/events.rs#rollover_clip_is_pullable_when_clip_finalized_is_observed`: assert
  the finalized JSON carries `"session": 1`.

**Contract**
- `contract/events/clip_finalized.json`: add `"session": 7` after `"boot_tag"`.
- `contract/events/README.md`: replace the drive-identity rule with: a recording is
  identified by (`boot_tag`, `session`); finished clips carry both as nullable fields
  (present together for stamped, both null for bare); the snapshot pairs top-level
  `boot_tag` with `recorder.session` to name the recording being written.

**App**
- `app/DanCam/DanCam/Networking/ClipsResponse.swift#Clip`: add
  `var session: UInt64? = nil` after `bootTag` (defaulted -- all memberwise callers
  keep compiling; `.convertFromSnakeCase` needs no CodingKeys for `session`).
  `CameraEvent.swift` needs no change (`clip_finalized` decodes via `Clip(from:)`).
- `DanCamTests/Support/CameraSamples.swift#clip` factory gains a defaulted `session`
  param; `ClipsClientTests` add decode-present/decode-absent assertions;
  `CameraEventCorpusTests#decodesRepresentativeVariants`'s `clipFinalized` literal
  gains `session: 7`.

## Commit 3 -- `feat(app): group and attribute clips by recording, not boot`

**Retire the "Drive" domain noun (rename in place, no compat aliases).** This commit
also completes the vocabulary change: every active-tree symbol, label, and living-doc
line that named the browse unit a "Drive" becomes "Recording". Rename in place -- no
typealias, no deprecated shim (repo stance). Core mapping (the detailed bullets below
already use the new names):

| Drive (old) | Recording (new) |
| --- | --- |
| `DriveGroup` | `RecordingGroup` |
| `HomeRow.drive(DriveGroup)` | `HomeRow.recording(RecordingGroup)` |
| `HomeRowID.drive(bootTag:occurrence:)` | `HomeRowID.recording(recording:occurrence:)` |
| `RecordingDrive` (+ the `recordingDrive` var/param) | `RecordingAttribution` (+ `recordingAttribution`) |
| `coalescedDriveRows` / `driveOccurrenceCounts` | `coalescedRecordingRows` / `recordingOccurrenceCounts` |
| `DriveDetailState` / `tailKeepsDriveIndeterminate` | `RecordingDetailState` / `tailKeepsRecordingIndeterminate` |
| `DriveDetailViewController` (+ private `DriveDetailSection`/`DriveDetailRow`) | `RecordingDetailViewController` (+ `RecordingDetailSection`/`RecordingDetailRow`) |
| `Features/DriveDetail/` (dir + both source files, and the `DanCamTests/Features/DriveDetail/` test dir) | `Features/RecordingDetail/` (+ `DanCamTests/Features/RecordingDetail/`) |
| `Formatters.driveCardTitle` / `driveCardSubtitle` | `recordingCardTitle` / `recordingCardSubtitle` |
| `HomeViewController.driveThumbnailCellForTesting(bootTag:)` | `recordingThumbnailCellForTesting(recording:)` |
| user-visible `"Drive"` labels (3 literal sites: `Formatters.driveCardTitle` fallback, `RecordingDetailViewController` nav title + section header) | `"Recording"` |
| test doubles `DriveFetchSpy` / `ParkedDriveFetchSpy` / `DriveDeleteSpy` / `DriveLoaderProbe`, helper `requireDrive`, and `...Drive...` test-function names | `Recording...` equivalents |

`session` is untouched -- it stays the low-level persisted/wire discriminator;
`Recording`/`RecordingID` is the app/domain noun. ADR 24 (below) owns "Recording" as
both the product vocabulary and the domain model.

**Intentional survivors (documented, not renamed).** After the rename, re-sweep the
active tree (`git grep -ni drive -- app docs contract`) and confirm the only remaining
hits are these -- none of which is the obsolete browse-unit concept:
- **Append-only ADRs keep their original wording.** App ADRs
  `19-...-drive-grouped-clip-browsing.md` and
  `20-...-live-recording-surfaces-and-drive-attribution.md` (filenames + bodies; only
  their Status gains the supersession marker), app ADR
  `21-...-status-strip-recording-pill.md` (Accepted -- its "drive card"/"drive detail"
  surface references are the historical record; the surface rename is noted in ADR 24,
  not by rewriting 21), and raspi ADR `02-...-app-pi-transport-and-api.md` (Accepted --
  its "drive identity"/"drive attribution" prose is the historical decision; the live
  wire description lives in `contract/events/README.md`, updated in Commit 2). The
  `app/AGENTS.md` index lines for ADRs 19/20 likewise keep their "drive" summaries and
  only gain `superseded by ADR 24`. Per the repo's append-only-ADR convention, accepted
  ADRs are not rewritten to chase terminology.
- **Generic/verb/physical uses.** `docs/roadmap.md`'s "**Driving Task** template"
  (Apple CarPlay proper noun), "drive-only" power note (physical car electrics), and
  "Drive the API from that UI" (verb); `AppFeatureTests.swift#commandPhaseEventsDriveNonCommandingClientOverlay`
  ("drive" as a verb); and the raspi FSM `drive()`/`drive_now` methods,
  `FakeCameraDriver`/`RealCameraDriver`, and the pervasive "driven"/"drives" ADR prose,
  none of which name the browse unit.

**New identity type**, co-located with `Clip` in
`app/DanCam/DanCam/Networking/ClipsResponse.swift`:

```swift
nonisolated struct RecordingID: Hashable, Sendable {
    var bootTag: String
    var session: UInt64
}

extension Clip {
    /// Non-nil only when the clip carries both stamped facts (all-or-nothing on the wire).
    nonisolated var recordingID: RecordingID? {
        guard let bootTag, let session else { return nil }
        return RecordingID(bootTag: bootTag, session: session)
    }
}
```

**Re-key and rename the grouping core** -- `app/DanCam/DanCam/Features/Home/HomeSections.swift`:
- `DriveGroup` -> `RecordingGroup`; its `bootTag: String` field -> `recordingID: RecordingID`;
  its `recording: RecordingDrive.Freshness?` field -> `recording: RecordingAttribution.Freshness?`.
- `HomeRow.drive(DriveGroup)` -> `HomeRow.recording(RecordingGroup)`.
- `coalescedDriveRows` -> `coalescedRecordingRows`: seed on `firstClip.recordingID`,
  contiguity test `clip.recordingID == recordingID`, `driveOccurrenceCounts` renamed
  `recordingOccurrenceCounts` and re-typed `[RecordingID: Int]` (also in
  `composeSections`, whose `recordingDrive:` param -> `recordingAttribution:`), REC
  attribution `recordingID == recordingAttribution?.id && occurrence == 0`.
- `Features/Home/HomeRowDiff.swift#HomeRowID`: `.drive(bootTag:occurrence:)` ->
  `.recording(recording: RecordingID, occurrence: Int)`.
- `Features/Home/HomeViewController.swift`: the `recordingDrive` stored property ->
  `recordingAttribution`, `HomeRow.id`, the recording-tap push (which now constructs a
  `RecordingDetailViewController`), and `driveThumbnailCellForTesting(bootTag:)` ->
  `recordingThumbnailCellForTesting(recording:)`, all re-keyed to `RecordingID`.

**Live attribution** -- `app/DanCam/DanCam/Features/Recording/LiveRecordingStatus.swift`:
- `RecordingDrive` -> `RecordingAttribution`, and it becomes `{ id: RecordingID, freshness: Freshness }`.
- `RecordingAttribution.from(status:worldBootTag:)` gains `recorder: RecorderTruth`
  (already on `LiveRecordingInputs`, derived from the same `state.link` as
  `worldBootTag` -- preserves ADR 20's one-projection coherence constraint; do NOT add
  a second observation). `.live(segment)` takes `segment.sessionId`; `.pending` guards
  `case .live(let snapshot) = recorder` and takes `snapshot.session` (defensive nil
  otherwise; `shouldShowPending` already guarantees live).

**Recording detail** -- `app/DanCam/DanCam/Features/RecordingDetail/` (renamed from
`Features/DriveDetail/`; both source files and their private
`DriveDetailSection`/`DriveDetailRow` enums move to the `RecordingDetail...` names):
- `DriveDetailState` -> `RecordingDetailState`: `bootTag` -> `recordingID: RecordingID`;
  filter `$0.recordingID == recordingID`; `tailKeepsDriveIndeterminate` ->
  `tailKeepsRecordingIndeterminate`, returns true on a nil-facts tail, false on any
  different non-nil `RecordingID` -- same-boot different-session now correctly stops
  pagination.
- `DriveDetailViewController` -> `RecordingDetailViewController`; its `init` takes
  `recordingID:`; the live-row gate becomes `RecordingAttribution.from(...)?.id ==
  recordingID`, so viewing an older session of the currently-recording boot shows no
  live row, and the empty-recording pop gate inherits the right behavior unchanged. Its
  nav title and section-header `"Drive"` fallbacks become `"Recording"`.

**Test updates** (mechanical re-key + rename, same pattern across files): helpers gain
`session: UInt64 = 7` (matching `CameraSamples.world`'s recorder session 7 so
attribution tests keep pairing); `.drive(bootTag:occurrence:)` /
`RecordingDrive(bootTag:freshness:)` / `DriveGroup(bootTag:...)` literals become the
renamed `.recording(...)` / `RecordingAttribution(...)` / `RecordingGroup(...)`,
`RecordingID`-keyed; the `requireDrive` helper -> `requireRecording`, the
`DriveFetchSpy` / `ParkedDriveFetchSpy` / `DriveDeleteSpy` / `DriveLoaderProbe` doubles
-> `Recording...` names, and `== "Drive"` expectations -> `== "Recording"`. Rename
`...Drive...` test-function names to their recording meaning (behavioral descriptions,
e.g. `filtersTargetDriveAndKeepsNewestFirstOrder` ->
`filtersTargetRecordingAndKeepsNewestFirstOrder`) -- do not add tests that only pin the
new symbol names. Representative files: `HomeSectionsTests`, `HomeRowDiffTests`,
`HomeViewControllerTests`, `RecordingDetailStateTests` (renamed dir + file),
`RecordingDetailViewControllerTests` (renamed), `ClipThumbnailCellTests`,
`FormattersTests` (the `driveCardTitle`/`driveCardSubtitle` cases), `LiveRecordingStatusTests`.
`StatusStrip`/`ThumbnailLoader` tests unaffected (verify compile).

**New behavioral tests**:
- `HomeSectionsTests`: same bootTag, two sessions -> two recording cards (each
  occurrence 0 of its own RecordingID); occurrence counting is per-RecordingID across a midnight
  span; REC marker attaches only to the recording session's occurrence-0 card (absent
  from the same boot's other session and from occurrence 1).
- `HomeSectionsTests` **partial identity**: a clip with non-nil `bootTag` but nil
  `session` (`recordingID == nil`) stays an ordinary finished row -- never grouped,
  never coalesced with an adjacent stamped clip of the same bootTag -- pinning the
  all-or-nothing degrade the ADR promises. This needs a `CameraSamples`/helper path
  that leaves `session` nil (the shared helpers default it to 7), so it is the one case
  the defaulted grouping helpers cannot already reach.
- `RecordingDetailStateTests`: (a) the `recordingID` filter keeps only the requested
  recording -- given a loaded page mixing the requested `RecordingID` with same-boot,
  different-session clips, `state.clips` contains *only* the requested `RecordingID`
  (the `bootTag` -> `recordingID` filter change; existing filter tests distinguish only
  different boot tags, so they do not cover this); (b) pagination stops when the oldest
  loaded clip is same boot, different session (even with a next cursor); nil-facts tail
  still pages.
- `RecordingDetailViewControllerTests`: viewing an older session of the recording boot
  shows no live row.
- `LiveRecordingStatusTests`: pending derives session from the live recorder snapshot;
  ticking/frozen derive from `LiveSegment.sessionId`.

Skip as low-value/structure-sensitive: standalone `RecordingID` equality test
(compiler-derived) and re-testing unchanged rendering. The `Clip.recordingID`
nil-session path is *not* skipped -- its behavior is pinned by the `HomeSectionsTests`
partial-identity case above (a standalone two-line-guard unit test stays skipped, but
the observable degrade is now covered).

**New ADR
`app/docs/design/24-2026-07-09-recording-grouped-clip-browsing-and-attribution.md`**
(22 tab navigation and 23 debug-tab telemetry are already taken):
- Context: ADRs 19/20 keyed on "a drive is a boot"; one boot can hold several
  recordings; the wire now carries clip `session`. The domain rule that forces the
  rename: a *recording* is an observable contiguous capture run (a witnessed
  start..stop, stamped `(boot_tag, session)`), whereas a *drive*/*trip* is not
  observable -- the unit has no ignition, odometer, or GPS trip signal -- and one drive
  may hold zero, one, or many recordings. Naming a clip group a "drive" would assert
  trip boundaries the system never captured, so the product must not; it names the unit
  a recording.
- Decision: browse unit is a recording, `RecordingID(bootTag, session)`; all ADR 19/20
  mechanics carry forward re-keyed (coalescing, occurrences, representative thumbnail,
  detail-over-root-store, conservative nil-tail pagination, REC on occurrence 0, one
  coherent `LiveRecordingInputs` projection). **"Recording" is now both the product
  vocabulary and the domain model**: the UI says "Recording", and the code names the
  unit `Recording`/`RecordingID`/`RecordingGroup`/`RecordingAttribution`/`RecordingDetail*`
  -- the obsolete "Drive" noun is retired from the active tree (full symbol mapping in
  the Commit 3 rename block). `session` remains the low-level persisted/wire
  discriminator only.
- Consequences: two recordings in one boot are two cards/details; REC moves to the new
  card on restart; stale-server clips with `boot_tag` but no `session` degrade to
  ungrouped rows (no special case); gap-between-cards annotation deliberately
  deferred. Recording boundaries are **not** trip boundaries -- a future feature must
  not reconstruct drive/trip semantics from them (one trip may span many recordings or,
  during a stop, none); trip grouping, if ever wanted, needs its own observable signal
  (GPS/ignition), not a fold over recording edges.
- Mark app ADRs 19 and 20 `Superseded by 24-...`. Do not rewrite or rename those
  historical files -- they are append-only and keep their "drive" wording and filenames;
  only their Status line gains the marker. ADR 24 explicitly records that it also
  retires the "Drive" vocabulary going forward and that it renames the "drive card" /
  "drive detail" surfaces ADR 21 refers to (21 stays `Accepted` and is not rewritten --
  the strip is identity-agnostic, and accepted ADRs are not edited to chase
  terminology; the surface rename is captured here in 24).
- **Index update.** Add ADR 24 to `app/AGENTS.md`'s "Design decisions (ADRs)" list
  (currently ends at ADR 23) in the file's one-line-per-ADR form, and mark ADRs 19 and
  20 `superseded by ADR 24` in their existing index lines (matching the index's existing
  convention -- e.g. ADR 04 "superseded by ADR 05").

**Roadmap**: reword the completed `sift` sub-items in `docs/roadmap.md` ("Group clips
by drive using a boottag", and "Attribute the active recording to its drive ... a REC
marker on the recording drive's card, and a live row atop that drive's detail") to the
recording vocabulary -- clips group by *recording*, REC marks the recording's card,
live row atop the recording's detail (same change, updated record). Leave the unrelated
generic uses untouched: the `sage` swoop's "**Driving Task** template" (Apple CarPlay
proper noun), the "drive-only" power note (physical car electrics), and "Drive the API
from that UI" (verb).

## Edge cases (handled by design, verify in review)

- Session 0 never reaches a filename; parser stays the exact inverse of the renderer
  (no `>= 1` parser rule).
- Same-boot service restart yields a *distinct* session by construction: `start_segment`
  is drawn from the durable high-water witness (ADR 16, refined to fail closed at the
  `u32` ceiling), so the post-restart recording's `start_segment + 1` is strictly greater
  than any prior session in the rec dir -- no merge, no reissued session 1.
- Same-seq stamped twins across sessions impossible: start allocation is strictly
  monotonic and fails closed at the `u32` ceiling rather than repeating an id (Commit 1
  storage change), so no two starts ever reserve the same seq. Bare+stamped same-seq
  during the rename window remains the only dedupe case, logic unchanged.
- Seq ceiling within a recording: in the writers this project controls (the Rust mock
  and the Python fake driver), a recording that reaches `seq == u32::MAX` fails closed on
  the next rollover rather than reissuing or overflowing the id -- the recorder goes to
  Failed; no same-seq twin or out-of-range file is written. The real-camera path has no
  such guard: ffmpeg's `segment_start_number` is a signed-int start-number limit
  (`0..=INT_MAX`), not a rollover ceiling -- post-`INT_MAX` numbering is unspecified (a
  probe of the tested build was observed to wrap into negative names rather than fail
  closed, but that is a build-dependent detail, not a documented contract), but reaching
  `INT_MAX` at 30 s segments is millennia beyond device lifetime, so post-`INT_MAX`
  behavior is outside the supported lifetime, deliberately left unguarded (grammar
  honest-boundary note). Together with the start-allocation guard, the id line
  never reissues (Commit 1).
- `HomeRowID` stability: RecordingID derives from immutable clip facts; REC freshness
  flips mutate only the `RecordingGroup.recording` payload -> reconfigure, never an
  identity change.

## Verification

Per commit:
- Commit 1: `just raspi-test` (includes the Python-driven `tests/camera_process.rs`
  end-to-end stamping guard), `just raspi-check`, the camera self-test
  (`raspi/camera/camera.py#run_self_test`), `just adr-check`.
- Commit 2: `just raspi-test`, `just raspi-check`, `just app-test`.
- Commit 3: `just app-test`, `just app-lint`, `just adr-check`.

End-to-end mock check (after commit 3):
1. `rm -rf raspi/service/.mock-rec`, then `just raspi-mock`.
2. Drive two recordings: POST `/v1/recording/start`, wait ~12s (5s segments), POST
   `/v1/recording/stop`, repeat; then
   `curl -s 'http://127.0.0.1:8080/v1/clips' | jq '.clips[] | {id, boot_tag, session}'`
   -- expect one boot_tag with two *distinct* sessions: run 1 is session 1 (start
   segment 0), run 2 is session `N+1` where `N` is run 2's first seq (past run 1's
   segments), so **not** necessarily 2. Filenames are 4-part
   `seg_00000_<tag>_1_<mono>.ts` ... for run 1 and `seg_000NN_<tag>_<N+1>_<mono>.ts` ...
   for run 2, in `raspi/service/.mock-rec`; every stamped segment carries its run's
   `start_segment + 1`.
3. Run DanCam in the simulator against the mock: Home shows two Recording cards for the
   one boot. Start a third recording and wait through its first segment rollover (~5s,
   one segment) before checking the UI -- Home cards derive only from *finished* clips
   (`HomeSections.swift#coalescedRecordingRows` builds a card from `.finished` rows and
   attaches REC to occurrence 0), so the new recording shows no card until its first
   rollover finalizes a clip. Once that first clip lands: a third card appears with the
   REC pill (only on the new card); tap the recording card -> live row at top; tap an
   older-session card -> no live row.
4. Storage-witness spot-check (run *after* the step 3 UI check, so relaunching the mock
   does not perturb the two-card / one-boot state that step 3 expects): with `.mock-rec`
   now holding the earlier recordings, kill and relaunch `just raspi-mock` against the
   same dir, drive one more recording, and confirm its session is greater than every
   prior run's (the next reserved start segment + 1) -- the durable witness keeps
   climbing across a process restart. This does *not* prove the *same-boot* case on
   macOS: `lib.rs#resolve_boot_id` mints a fresh UUID per process off-Pi, so the
   relaunched mock carries a *different* boot_tag. The same-boot no-reissue guarantee is
   owned by the fixed-`BOOT_ID` durability regression above (`tests/mock_recording.rs`),
   which is the authoritative proof; this manual step is only a witness-monotonicity
   sanity check.

## Implementation notes

### Commit 1

- **Session-literal fan-out the plan did not enumerate.** Re-sourcing `session` to
  `start_segment + 1` changed the value the FSM assigns for a given start, so every test
  that hardcoded `session: 1` downstream of `StartCommand { start_segment: 43 }` (or fed a
  recorder event with a stale session) had to be re-derived, or its segment/rollover event
  would be dropped by the session guard and the test would fail (or silently assert the
  wrong phase). Beyond the recorder.rs cases the plan called out, that meant:
  `src/world.rs` FSM tests (12 literals, all `1 -> 44`), `src/event_hub.rs`
  `connect_after_drive_sees_event_in_snapshot_not_receiver` (`1 -> 44`), and the
  `StubBackend` recorder-event doubles `recording_segment` / `failed_after_roll` in
  `tests/clips.rs` and `recording_segment` in `tests/status.rs`, all re-derived to
  `start_segment + 1` (via `u64::from(id) + 1` so they track the start rather than a
  literal). Mechanical, no behavior change beyond the new session value.
- **Mock rollover ceiling-guard placement.** In `run_mock_recording_writer` the guard sits
  after the last-legal (`u32::MAX`) segment is flushed/finalized but before the seq
  advance, so that segment is durably synced before the recorder fails closed -- matching
  the "no data loss on the last legal segment" intent.
- **`detect_segment_events` self-test names.** The camera.py self-test case that fed
  stamped duplicates was updated to the 4-part form; the old 3-part names now parse to
  `None`, so left unchanged the case would have passed for the wrong reason (invalid parse)
  instead of exercising the stamped-parse + same-seq dedup path it is meant to cover.

## Follow Up

- **Operator cleanup (manual, not committed) -- do after landing Commit 1.** Clear the
  untracked old-format dev artifacts so scanners stop seeing invalid 3-part names:
  `git clean -fdX raspi/service/assets/clips` (removes all 61 old `seg_NNNNN_<tag>_<mono>.ts`
  files plus any ignored `assets/clips/state|time` subdirs; the tracked bare
  `assets/clips/seg_00000.ts` is preserved). Then remove the scratch dirs outside that path
  (`.mock-rec-investigate/`, any `.mock-rec*`) and wipe the physical Pi's rec dir if it
  holds old-format footage.

## Commit progress
- [x] 1. feat(raspi): stamp recorder session into segment filenames
- [ ] 2. feat(contract): carry recorder session on finished clips
- [ ] 3. feat(app): group and attribute clips by recording, not boot
