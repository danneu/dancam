# ADR: Recording session in segment filenames

- **Status:** Accepted
- **Date:** 2026-07-09
- **Owner:** raspi
- **Related:** `10-2026-06-30-recorder-fsm-and-events-sse.md` (session id, FSM phases,
  floor, event guards -- session-id definition scoped-superseded here);
  `15-2026-07-02-segment-fact-stamping-and-boot-offset.md` (segment filename grammar and
  Rust/Python parser canon -- scoped-superseded here; still owns the offset/time model);
  `16-2026-07-02-storage-coordinator-segment-id-witness.md` (durable `high_water_seq`
  witness and start-segment allocation -- allocation ceiling scoped-superseded here)

## Context

The app batches clips into groups keyed by Pi boot (`boot_tag`). But one boot can hold
several distinct recording runs -- a manual stop/start, a CarPlay auto start/stop, or a
mid-boot service restart after a power blip -- and today they all collapse into one
group. The browse unit should be a **recording**: one contiguous capture run, identified
by the pair `(boot_tag, session)`, where `session` is the recorder's per-recording
discriminator (ADR 10).

Two problems block that. First, `session` (ADR 10) lived only in a process-local counter
seeded to 0 and incremented on each start, so after a same-boot systemd restart the next
recording is session 1 again -- under the same `boot_tag` -- and two unrelated recordings
merge, precisely during crash recovery. Second, `session` rides the live events but is
never persisted, so it never reaches the crash-safe fact store. Segment filenames are
that store (ADR 15): a recording must be reconstructible from a directory listing alone,
by construction, surviving power loss.

## Decision

Extend ADR 15's fact-stamping to carry `session`. The stamped filename grammar becomes:

```text
Bare:    seg_<seq>.ts
Stamped: seg_<seq>_<boottag>_<sess>_<monoMs>.ts
```

- `seq` -- decimal u32, zero-padded to a minimum of 5 digits, growing wider past 99999.
  `u32::MAX` is a valid *parse* (the last legal segment). Start allocation refuses to
  reissue it (below), so seq -- and the session derived from it -- never reissues.
- `boottag` -- exactly 12 lowercase hex chars (kernel boot UUID, dashes stripped).
  Unchanged from ADR 15.
- `sess` -- the recorder session id (u64), plain decimal, unpadded. `sess >= 1` by
  construction: it is `start_segment + 1` from the durably reserved start segment
  (`start_segment >= 0`). A documented invariant, not a parser special case.
- `monoMs` -- `CLOCK_BOOTTIME` ms at first observation of the open segment. Unchanged
  from ADR 15; ADR 15 remains the live owner of the offset/time model this field feeds.
- Parser canon (unchanged in philosophy): a name is valid iff re-rendering the parsed
  fields reproduces it byte-for-byte **and** every numeric field is in range
  (`seq <= u32::MAX`, `sess` and `monoMs <= u64::MAX`). Byte-for-byte round-trip alone is
  not enough: Python ints are unbounded, so an oversized `sess`/`monoMs` re-renders
  identically yet Rust's `u64` scan would drop it -- both parsers bound the field before
  re-rendering to stay byte-identical. The old 3-part form fails the part-count match and
  is rejected outright; there is no legacy parse.

**Session is sourced from the durably reserved start segment, not a process-local
counter.** `RecorderState::start` computes `session = start_segment + 1`, where
`start_segment` is the storage coordinator's monotonic `high_water_seq` witness (ADR 16),
fsync-durable and strictly increasing across service restarts and reboots. This is what
makes `(boot_tag, session)` survive a same-boot service restart: a fresh `RecorderState`
whose in-process session field has reset to 0 still gets the correct discriminator from
the rebuilt coordinator's witness. No new counter file, sidecar, manifest, or crash
window -- the identity reuses state that is already durable.

**For that derivation to never reissue, start-segment allocation fails closed at the
`u32` ceiling** (an ADR 16 refinement): when `max(high_water_seq, max_file_seq) ==
u32::MAX`, allocation returns an error instead of reissuing the id, so no seq -- and no
session derived from one -- is ever reissued. `u32::MAX` itself is the last legal
reservation; the next start fails. This surfaces through the existing HTTP-start
fail-closed path (500 "storage allocation failed", recorder stays idle).

**Within a recording, the two writers this project controls -- the Rust mock and the
Python fake driver -- likewise fail closed at `u32::MAX`** rather than advancing past it
on rollover, which would mint a same-seq stamped twin (a fresh `monoMs`) inside one
session. The recorder goes to Error; no twin or out-of-range file is written.

The real-camera path delegates segment numbering to ffmpeg, whose `segment_start_number`
is a signed int (`0..=INT_MAX`) that bounds only the *starting* number, not rollover.
ffmpeg documents no post-`INT_MAX` numbering behavior; a local probe of the tested build
was *observed* to keep counting into wrapped/negative names rather than stopping, but
that is an unspecified, build-dependent implementation detail, not a contract. Reaching
`INT_MAX` at 30 s segments is millennia out, beyond any device lifetime, so post-`INT_MAX`
numbering sits outside the supported-lifetime contract -- the real path carries no runtime
guard, an honest boundary, not a runtime ceiling and not a no-write guarantee across the
full `u32` range.

The Pi stays dumb: per-clip identity is all the server owes. There is no grouping
endpoint; folding clips into recordings is a pure app-side view (a later app ADR).

## Consequences

- A recording is reconstructible from the SD card alone and survives a service restart
  mid-boot: the post-restart recording's `start_segment + 1` is strictly greater than any
  prior session in the rec dir, so no merge and no reissued session 1.
- Facts stay all-or-nothing: a stamped name carries `boot_tag + session + monoMs`
  together; a bare `seg_<seq>.ts` carries none.
- `session` 0 never appears in a filename by construction (`start_segment >= 0`).
- Same-seq stamped twins across sessions cannot occur: start allocation is strictly
  monotonic and fails closed at the `u32` ceiling (never repeating an id), and a
  within-recording rollover in the writers we control likewise fails closed at the
  ceiling. So `clips.rs#dedupe_candidates` is unchanged -- the only dedupe case remains a
  bare+stamped same-seq pair during the stamping-rename window.
- Pre-change stamped dev files (the old 3-part form) become invisible to scanners and
  must be wiped manually. Dev-only; there are no shipped releases.

## Alternatives considered

- **A session sidecar / counter file.** Rejected. It adds a crash/skew window this avoids
  by reusing the existing durable witness.
- **Encoding session in seq ranges.** Rejected -- it aliases the seq id.
- **Accepting both the 3-part and 4-part filename forms.** Rejected: two canons, and it
  contradicts the repo's no-compat-shim stance.

## ADR bookkeeping -- scoped supersession

ADR 20 supersedes only the decisions it actually changes and does not re-own subsystems
it leaves untouched (scoped supersession matches repo precedent: raspi ADR 02 "Superseded
(thumbnails) by app ADR 16", ADR 13 "Superseded, for request-id format only"):

- **ADR 10 stays `Accepted`** -- it still owns FSM phases, floor, event guards, and SSE
  framing. Only its `session` definition ("monotonic per-boot session id, starting at 0")
  is superseded here: session is now `start_segment + 1`, durable across a same-boot
  restart.
- **ADR 15 stays `Accepted`** -- it remains the normative home for bare-form semantics,
  the watcher rename/emit, write-once per-boot offset durability, boottag-collision and
  torn-file recovery, `/v1/time` bounds, and the read-time `start_ms = monoMs + offset_ms`
  resolution. Only its segment filename grammar and Rust/Python parser canon are
  superseded here (the `session` field added; the `u64` overflow bound). ADR 20 does not
  restate the offset/time model -- it references ADR 15 as the live owner and merely
  defines the `monoMs` field that model consumes, unchanged.
- **ADR 16 stays `Accepted`** -- it still owns the storage coordinator, the durable
  `high_water_seq` witness, write-ahead-delete, and corrupt-witness fail-closed. Only its
  allocation rule (Decision step 3, `next = max(high_water_seq, max_file_seq)
  .saturating_add(1)`) is superseded here, and only for the ceiling case: at `max ==
  u32::MAX` allocation fails closed instead of returning a duplicate id, so start-segment
  reservation -- and the session derived from it -- is strictly monotonic and never
  reissues.
