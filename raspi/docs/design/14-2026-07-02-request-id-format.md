# ADR: Request id format

- **Status:** Accepted
- **Date:** 2026-07-02
- **Owner:** raspi
- **Related:** `13-2026-07-01-request-logging-and-log-access.md` (request logging
  middleware, safe inbound `x-request-id` handling, and journald log-access path)

## Context

ADR 13 added request/response access logs and an `x-request-id` response header so app
requests can be correlated with Pi journal lines. It specified a generated UUID v4
fallback when the client does not send a safe inbound request id.

Those UUIDs are correct but visually expensive in `journalctl -u dancam` output. A
typical generated id is 36 characters, so it dominates the access line even though the
main local debugging use case is reading one service's journal in time order.

The service already starts one `AppState` per process. The deployed systemd unit can
restart that process more often than the Pi reboots: `Restart=on-failure`, deploy-time
`systemctl restart dancam`, and manual restarts all create a new service invocation
inside the same boot.

## Decision

For Pi-generated fallback request ids, use a per-process `AtomicU64` counter stored on
`AppState`.

The counter is initialized to `1` when `AppState::new` builds the service state. The
request tracing middleware uses `fetch_add(1, Ordering::Relaxed)` and stringifies the
pre-add value, so the first generated id is `1`, then `2`, `3`, and so on. `Relaxed`
ordering is sufficient because the requirement is a unique, roughly monotonic sequence
for one process, not synchronization of other memory.

The generated value is echoed in the `x-request-id` response header and carried in the
request tracing span. Safe inbound `x-request-id` values are still honored and echoed
unchanged; unsafe inbound values are ignored and receive a generated counter value.

## Consequences

- Access lines are shorter and easier to scan.
- Seeing generated id `1` in time-ordered logs is a visible service-start marker.
- The marker appears on reboot and on any service restart within a boot, including
  `Restart=on-failure`, deploy-time `systemctl restart dancam`, and manual restarts.
- A captured generated id is unique only within one service invocation. A blind grep
  for a value such as `x-request-id: 42` across a persistent journal can find multiple
  runs.
- Disambiguate repeated ids by time proximity plus the neighboring reset marker, or
  scope the journal query to one systemd invocation with
  `_SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value dancam)`.
- `journalctl -b` narrows to one boot but not to one service invocation, and the
  `x-dancam-boot-id` response header likewise does not distinguish restarts within a
  boot.

## Alternatives considered

- **Keep UUID v4.** Correct and globally unique, but noisy at 36 characters per access
  line.
- **Short random token.** Shorter and low collision risk, but it has no ordering and no
  reset marker.
- **Boot- or invocation-prefixed counter, such as `af49-42`.** More unique across
  service runs, but longer than the plain counter. The current debugging workflow
  favors the shortest readable id and accepts per-run-only uniqueness.
