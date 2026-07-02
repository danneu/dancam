# ADR: Request logging and log access

- **Status:** Accepted
- **Date:** 2026-07-01
- **Owner:** raspi
- **Related:** `02-2026-06-22-app-pi-transport-and-api.md` (API surface, including the
  deferred `/v1/logs` endpoint); `12-2026-06-30-watchdog-and-persistent-journal.md`
  (persistent journald makes request logs useful across reboots)

## Context

The service previously emitted lifecycle and error logs, but no HTTP access logs. A
request to `/v1/...` left no method/path/status/latency trail, and host-allowlist
`421 MISDIRECTED_REQUEST` rejections were silent. That made app/Pi correlation and
endpoint debugging unnecessarily hard from the journal.

Persistent journald is now available on the dev image, so stdout logs emitted by the
service survive reboots and are queryable with `journalctl -u dancam` over SSH. That is
the right access path today: it works even when the service is wedged or crashed, which
is when logs matter most.

## Decision

Add a Rust `from_fn` middleware that logs one structured request/response event per
HTTP request through the existing `tracing` stdout pipeline. The middleware:

- resolves a request id from a safe inbound `x-request-id` value, or generates a UUID;
- echoes the final request id in the response `x-request-id` header;
- opens a tracing span carrying `request_id`, `method`, and `path`;
- records one INFO access line with `status` and `latency_ms`; and
- is the outermost router layer, so normal handlers, router 404s, and host-allowlist
  421s all receive the same access log and response header.

Inbound request ids are accepted only when non-empty, at most 128 bytes, and limited to
ASCII letters, digits, `.`, `_`, and `-`. Unsafe values are ignored and replaced with a
generated UUID so clients cannot inject huge or garbage values into logs or response
headers.

The request-id span covers the access line and logs emitted while the handler future is
running. It does not cover logs emitted later by response-body streams, such as SSE or
MJPEG body work after the handler has returned. Instrumenting those streams would add
weight for little current payoff, so the contract is intentionally limited to the
access line plus handler-future logs.

Do not implement `GET /v1/logs` now. Journald-over-SSH is the current log-access path
until a non-SSH consumer exists, realistically the iPhone app needing in-app Pi logs.

Runtime verbosity is controlled by the existing `RUST_LOG` support in
`tracing_subscriber::fmt::init()`. With the current default features, it parses
`target=level` directives through a `Targets` filter, so `RUST_LOG=dancam=debug`
raises this crate without adding the heavier `env-filter` feature.

## Consequences

- A developer or agent can correlate an app request with Pi logs by capturing the
  response `x-request-id` and grepping `journalctl -u dancam` for that value.
- Host-allowlist rejections and router 404s are no longer silent.
- Streaming endpoints log time-to-response-ready, effectively time-to-first-byte, not
  full stream lifetime.
- There is still no in-process HTTP log surface. That keeps the service smaller and
  avoids a log path that disappears when the service itself is down.

## Alternatives considered

- **`tower-http` `TraceLayer` plus request-id layers.** Rejected: it adds
  `tower-http` and promotes `tower` to a normal dependency for behavior that matches
  the existing `axum::middleware::from_fn` style in this crate.
- **In-memory ring buffer plus `GET /v1/logs`.** Rejected: it dies with the process and
  is unavailable exactly when a crash or wedge makes logs most important.
- **`GET /v1/logs` backed by a `journalctl` subprocess.** Rejected: it is Linux-only,
  has poor macOS/mock parity, and spawns a subprocess per request for no current
  consumer.
- **Add the `tracing-subscriber` `env-filter` feature.** Rejected: the existing
  `Targets`-based `RUST_LOG` support already covers `target=level`, while
  `env-filter` would pull in span/field directive parsing and extra regex machinery
  that the grep-over-journald workflow does not need.
