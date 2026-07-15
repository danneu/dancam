# ADR: Recorder-writable capacity telemetry

- **Status:** Accepted
- **Date:** 2026-07-14
- **Owner:** raspi
- **Related:** raspi ADR 18 (dedicated `/data` partition); [Pi storage](../../../docs/design/pi/storage.md)
  (`DANCAM_GC_FLOOR_BYTES` ring policy); app ADR 28 (retention estimate)

## Context

The Settings screen needs an honest estimate of how much footage the recording
ring can hold. Filesystem `total` is not that value: ext4 may reserve blocks for
root, and ring GC deliberately preserves a non-root-writable free-space floor.
Configured encoder bitrate is also not a reliable observation of actual segment
size.

The Pi already samples `statvfs` for storage telemetry and separately parses the
GC floor. Independent parsing or a Pi-computed duration could let telemetry and
deletion policy disagree.

## Decision

Storage telemetry adds required `recording_capacity_bytes`, defined as:

```text
service_writable_bytes =
    total_bytes - ((f_bfree - f_bavail) * block_size)

recording_capacity_bytes =
    max(service_writable_bytes - gc_floor_bytes, 0)
```

Startup parses `DANCAM_GC_FLOOR_BYTES` once and passes the same value to telemetry
and GC. Arithmetic saturates for impossible development configurations. Existing
`used` and `total` values remain quantized to 64 MiB buckets; capacity remains
exact because the app uses it in duration arithmetic.

`storage_changed` carries the same complete nullable `storage` value as a
snapshot. Probe failure emits `storage: null`, and clients replace their storage
slice directly. The mock backend alone accepts a deterministic capacity override
for retention UI smoke tests; production capacity always comes from `statvfs`.

## Consequences

- The app can estimate retention without learning configured bitrate or GC policy.
- Snapshot and delta storage shapes cannot drift, and an online client can converge
  from available telemetry to unavailable telemetry.
- Capacity describes the maximum recorder-writable pool, not current free space or
  time until the next eviction.
- Changing recording quality does not change capacity; it changes the app-observed
  consumption rate.

## Alternatives considered

- **Expose configured bitrate.** Rejected because actual muxed clip sizes are the
  relevant observation and codec configuration is not storage authority.
- **Have the Pi report hours.** Rejected because the Pi would need to own a bitrate
  profile or sampling policy that belongs in the app product state.
- **Use `f_bavail` as capacity.** Rejected because it is current free space, so the
  displayed retention would shrink as the ring fills even though old footage is
  replaceable.
