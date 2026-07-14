# Plan: Estimated recording capacity

## Summary

Add one Pi-provided `recording_capacity_bytes` fact and let the iPhone estimate
footage hours from freshly finalized clips. Do not expose configured bitrate or
make the Pi calculate retention duration.

The estimate appears in Settings after one normal clip from the current
connection is finalized. It resets on reconnect and future recording-quality
changes, preventing stale profiles from affecting the result.

## API and Pi changes

- Extend the complete nullable storage value in `/v1/status` / snapshot:

  ```json
  {
    "storage": {
      "used": 1000000000,
      "total": 112000000000,
      "recording_capacity_bytes": 104000000000
    }
  }
  ```

- Replace the flattened `storage_changed` payload with the same complete,
  nullable storage value:

  ```json
  {
    "type": "storage_changed",
    "storage": {
      "used": 1000000000,
      "total": 112000000000,
      "recording_capacity_bytes": 104000000000
    }
  }
  ```

  A failed probe emits `{"type":"storage_changed","storage":null}`. Both the
  Pi world and the iPhone fold this event as a direct replacement so live state
  converges from available storage to unavailable storage without a reconnect.

- Define `recording_capacity_bytes` as the maximum block pool writable by the
  non-root recorder, minus `DANCAM_GC_FLOOR_BYTES`:

  ```text
  service_writable_bytes =
      total_bytes - ((f_bfree - f_bavail) * block_size)

  recording_capacity_bytes =
      max(service_writable_bytes - gc_floor_bytes, 0)
  ```

- Parse the GC configuration once at startup and pass the same floor to
  telemetry and GC so they cannot disagree.
- Preserve current `used` and `total` semantics and their existing 64 MiB
  quantization. Keep `recording_capacity_bytes` exact so its value remains
  suitable for duration estimation.
- Use saturating arithmetic for unusual or deliberately impossible development
  configurations.
- Update the canonical event corpus and both Rust and Swift decoders. The new
  field is required because there are no compatibility obligations.
- Add a `just raspi-mock-retention` recipe using 30-second mock clips and a
  mock-only 162,432,000-byte capacity override, producing `About 23 hours`
  after one clip.

## iPhone estimator and Settings UI

- Add a pure retention estimator to root app state. It observes only live
  `clip_finalized` events received after the latest snapshot, not paginated or
  previously loaded clips.
- Accept samples with nonzero bytes and `dur_ms` between 25 and 35 seconds.
  Normalize every sample:

  ```text
  storage_bytes_per_second = clip.bytes * 1000 / clip.dur_ms
  ```

- Retain the maximum observed rate for the current estimator epoch. Calculate:

  ```text
  estimated_duration_ms =
      recording_capacity_bytes * 1000 / max_observed_bytes_per_second
  ```

  Use overflow-safe floating-point conversion and clamp before returning
  `UInt64`.
- Reset the estimator on every snapshot, disconnect, heartbeat timeout,
  background stream stop, and any future server-confirmed recording-profile
  change. Do not cache estimates across connections.
- Replace the Settings placeholder with an inset-grouped "Recording storage"
  section:
  - `Space for footage`: formatted `recording_capacity_bytes`
  - `Estimated footage`: `Calculating...`, `Unavailable`, `Not connected`, or
    `About 23 hours`
  - Footer: `Estimated at the current recording quality. When storage fills,
    DanCam replaces the oldest footage automatically.`
- Floor ready estimates to whole hours; below one hour, floor to whole minutes.
  Provide complete VoiceOver values and Dynamic Type support.
- Do not add a progress bar, current-footage duration, or time-until-eviction.
  Those require additional authoritative data and belong to later `kelp` work.
- Add capacity to structured diagnostic snapshots while keeping the existing
  Debug storage gauge behavior unchanged.

## Tests and documentation

- Rust tests:
  - Capacity arithmetic excludes root-reserved blocks and the GC floor.
  - Underflow and oversized floors produce zero.
  - Storage quantization buckets `used` and `total` while preserving exact
    capacity.
  - Snapshot and `storage_changed` carry the same complete nullable storage
    value.
  - An available-to-unavailable telemetry transition updates `World.storage`
    and emits `storage_changed` with `storage: null`.
  - The canonical event corpus round-trips.
- Swift Testing tests:
  - Corpus decoding requires the new field and the complete nullable
    `storage_changed` shape.
  - `storage_changed` with `storage: null` clears live storage and changes the
    estimate to unavailable while the connection remains online.
  - Short, missing-duration, and zero-byte clips are ignored.
  - The first eligible clip produces an estimate.
  - Rates are normalized by actual duration.
  - The maximum rate controls the estimate and smaller later clips cannot
    increase it.
  - Snapshot resets to calculating, and the existing parameterized disconnect
    cases cover stream failure, heartbeat timeout, and background stream stop.
  - Settings projections and duration formatting cover disconnected,
    unavailable, calculating, whole-hour, and sub-hour states.
  - The mock capacity and 30-second mock clip sample format as
    `About 23 hours`.
  - A Settings controller test verifies live store updates without testing
    layout structure.
- Validate with `just raspi-test`, `just raspi-check`, `just app-test`,
  `just app-build`, `just adr-check`, and a manual
  `just raspi-mock-retention` smoke test.
- Record the Pi capacity semantics in raspi ADR 22 and the app estimator / UI
  decision in app ADR 28. Update both side-specific `AGENTS.md` indexes, the
  event-contract README, and add completed retention subtasks under the
  still-open `kelp` roadmap entry.

## Assumptions

- `/data` remains dedicated to recording footage plus negligible DanCam state.
- Production keeps ring GC enabled; card diagnosis and formatting remain
  outside this slice.
- Future quality controls must reset the estimator only when the new profile is
  confirmed active.
- No bitrate field, profile identifier, persisted estimate, or
  backward-compatibility path is added.
