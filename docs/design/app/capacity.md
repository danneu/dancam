# App recording-capacity estimate

Settings translates recorder-writable bytes into a conservative estimate of how much
footage the current recording quality can retain. The estimate belongs to the phone:
the Pi reports its usable byte pool, while freshly finalized clips reveal the actual
stored byte rate.

[Pi telemetry](../pi/telemetry.md) owns `recording_capacity_bytes`, including filesystem
reserves and the shared garbage-collection floor. [App architecture](architecture.md)
owns snapshot-first event folding. This page owns sampling, connection-epoch reset,
duration calculation, and Settings presentation.

## Connection-epoch estimator

`AppFeature.State` owns a pure `RetentionEstimator`. It observes only live
`clip_finalized` events received after the latest event-stream snapshot. Loaded and
paginated clip lists do not contribute because they may describe an older recording
profile or connection epoch.

A qualifying sample has a nonzero byte count and a duration from 25 through 35 seconds,
inclusive. The estimator converts it to bytes per second and retains the maximum rate
seen in the epoch. A later low-complexity segment can therefore make no more optimistic
promise than the highest observed storage rate.

The estimate is:

```text
floor(recording_capacity_bytes * 1000 / max_bytes_per_second)
```

The calculation uses finite floating-point intermediates and clamps a result at
`UInt64.max`. Zero capacity is a valid ready estimate of zero duration.

Every snapshot, stream failure or stop, and heartbeat timeout resets the sample. The
estimate is never persisted. A future server-confirmed recording-profile change must
use this same reset seam rather than carrying a stale rate forward.

## Settings presentation

Settings renders one inset-grouped "Recording storage" section with:

- **Space for footage:** the Pi's recorder-writable capacity; and
- **Estimated footage:** the conservative duration at the current observed quality.

Both rows distinguish Not connected, Unavailable, and Calculating states. A storage
probe failure while the link remains online produces Unavailable; it does not force a
disconnect. Once a sample exists, duration is floored to whole hours, or to whole
minutes below one hour, and displayed as "About ...". Cells support Dynamic Type and
complete accessibility values.

The UI does not claim current footage duration, time until eviction, or a percentage
full. The wire contract does not provide the recording history needed to make those
claims trustworthy.

## Testing obligations

Estimator tests cover sample bounds, missing and zero inputs, normalization, maximum-
rate retention, epoch reset, zero capacity, and overflow clamping. Reducer and Settings
tests cover live-event sampling, every reset path, unavailable storage, calculating and
ready projections, floor formatting, and observation.

## Decision log

### 2026-07-14: Estimate retention from freshly finalized clips

(absorbed from app ADR 28, 2026-07-14)

Raw card capacity did not answer the user's question: how many hours fit at the current
quality? Configured bitrate was only an input, while finalized segment bytes and
duration measured the complete stored output. Historical estimates could become stale
after a reconnect, quality change, or connection to another camera unit.

The app therefore paired Pi-provided recorder-writable capacity with one epoch of live
ordinary segment samples. Keeping the maximum rate made the result conservative and
allowed one normal finalized segment to produce a useful estimate without expanding
the wire contract.

Persisting a rolling rate was rejected because camera-unit and profile invalidation
would be harder to trust than resampling. Averaging was rejected because a transient
low-complexity segment could increase the advertised duration. Clip-list history was
rejected because paginated and historical clips can belong to another epoch or
recording profile.
