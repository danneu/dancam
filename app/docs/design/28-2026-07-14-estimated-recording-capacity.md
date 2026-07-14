# ADR: Estimate recording retention from finalized clips

- **Status:** Accepted
- **Date:** 2026-07-14
- **Owner:** app
- **Related:** raspi ADR 22 (recorder-writable capacity); app ADR 10
  (snapshot-first event folding); `docs/roadmap.md#Swoop kelp -- SD card management`

## Context

Card byte capacity is meaningful but does not answer the product question: how
many hours of footage fit at the current recording quality? Configured bitrate is
only an input, while finalized clip bytes and duration measure the complete stored
output. A persisted historical rate could be stale after reconnect, a quality
change, or a different camera unit.

## Decision

Root app state owns a pure, connection-epoch retention estimator. It observes only
live `clip_finalized` events after the latest snapshot. It ignores loaded or
paginated clip lists and samples outside 25-35 seconds, missing durations, and
zero-byte clips.

Each sample is normalized to bytes per second. The estimator retains the maximum
rate observed in the epoch so a smaller later clip cannot make the promise more
optimistic. It multiplies Pi-provided `recording_capacity_bytes` by the inverse
rate with overflow-safe floating-point conversion, then floors display output to
whole hours or, below one hour, whole minutes.

Every snapshot, disconnect, heartbeat timeout, and background stream stop resets
the estimator. A future server-confirmed recording-profile change must use the
same reset seam. Estimates are never persisted across connections.

Settings renders an inset-grouped Recording storage section with capacity,
estimated footage, explicit disconnected/unavailable/calculating states, Dynamic
Type, and complete accessibility values. It does not show current-footage duration,
time until eviction, or a progress bar because the API does not authorize those
claims.

## Consequences

- One ordinary finalized segment produces a useful estimate without adding bitrate
  to the wire contract.
- The estimate is deliberately conservative within each live epoch and deliberately
  unavailable until a fresh qualifying sample exists.
- Reconnects briefly return Settings to "Calculating...", avoiding stale quality
  profiles.
- Storage probe failure changes the online presentation to "Unavailable" without
  forcing a disconnect.

## Alternatives considered

- **Persist a rolling bitrate estimate.** Rejected because invalidation across
  camera units and quality changes is harder to make trustworthy than resampling
  one 30-second clip.
- **Average samples.** Rejected because a transient low-complexity clip could
  increase the advertised duration; the maximum observed rate is conservative.
- **Estimate from clip-list history.** Rejected because paginated and historical
  clips can belong to another recording profile or epoch.
