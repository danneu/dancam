# Plan: Service request/response logging with request IDs (journald)

## Context

The Pi service barely logs. Investigation of `raspi/service/` found ~27 `tracing`
call sites, all lifecycle/error events at INFO+ (bind address, shutdown,
camera-child relay, various errors). There is **no HTTP access logging at all** --
no method/path/status/latency per request, and `host_allowlist`'s `421` rejections
are entirely silent. A request hitting `/v1/...` leaves no trace, so a
misbehaving app or a flaky endpoint is undebuggable from the journal.

This change adds structured **request/response logging with a per-request request
id**, emitted through the existing `tracing` pipeline to stdout, which systemd
routes to journald. It lands well now because **persistent journald just shipped**
(commit `721701c`, ADR 12): these access logs survive reboots and are queryable
over SSH (`journalctl -u dancam`), which is exactly how a developer or an agent
debugs the Pi.

We are **deliberately not building `GET /v1/logs`** (sketched in the transport
ADR). journald-over-SSH already gives query/follow/level filtering and, unlike an
in-process HTTP endpoint, survives a wedged or crashed service -- the moment logs
matter most. An HTTP log endpoint is only warranted if a consumer that *cannot*
SSH (realistically the iPhone app) needs in-app Pi logs; nothing needs that today.
This decision is recorded in a new ADR and the transport ADR is annotated.

## Scope

- **In scope:** a hand-rolled `from_fn` access-log + request-id middleware in the
  Rust service; documenting the already-working `RUST_LOG` verbosity knob;
  header-contract tests; ADR 13 plus a deferred pointer on the transport ADR's
  `/v1/logs` line; small doc notes.
- **Non-goals:**
  - `GET /v1/logs` or any HTTP log surface (deferred -- see Context / ADR 13).
  - journald persistence / rotation / caps -- already done in ADR 12 (`721701c`).
    This plan touches **no ansible, no systemd unit, no `README` provisioning**.
  - Switching stdout to JSON, or a `tracing-journald` structured-field layer
    (grep over `journalctl` is the intended workflow; can revisit later).

## Implementation

### 1. Access-log + request-id middleware -- `raspi/service/src/lib.rs`

Add one middleware that mirrors the existing `raspi/service/src/lib.rs#proto_headers`
shape. It needs no `AppState`, so use plain `middleware::from_fn` (not
`from_fn_with_state`). It: (a) resolves a request id -- honoring a valid inbound
`x-request-id`, else generating a `uuid::Uuid::new_v4()`; (b) opens a `tracing`
span carrying `request_id`/`method`/`path` and runs the rest of the stack inside
it, so the one access line **and every log emitted from the handler future**
(synchronously, before the response is returned) inherit `request_id` -- logs
emitted later from a streaming response *body* are out of scope (see the streaming
note below); (c) logs a single INFO line with `status` + `latency_ms`;
(d) echoes `x-request-id` on the response for app<->Pi correlation.

Illustrative shape (final wording/field names to taste):

```rust
async fn request_trace(request: Request<Body>, next: Next) -> Response {
    let request_id = inbound_request_id(&request)   // valid x-request-id, else:
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let method = request.method().clone();
    let path = request.uri().path().to_owned();

    let span = tracing::info_span!("request", %request_id, %method, %path);
    let started = Instant::now();
    let mut response = async move {
        let response = next.run(request).await;
        tracing::info!(
            status = response.status().as_u16(),
            latency_ms = started.elapsed().as_millis() as u64,
            "response",
        );
        response
    }
    .instrument(span)
    .await;

    if let Ok(value) = HeaderValue::from_str(&request_id) {
        response
            .headers_mut()
            .insert(HeaderName::from_static("x-request-id"), value);
    }
    response
}
```

- **`inbound_request_id`**: accept the client's `x-request-id` only if it is
  non-empty, bounded (e.g. `<= 128` chars) and matches a safe charset
  (`[A-Za-z0-9._-]`); otherwise generate. This keeps a client from injecting a
  huge/garbage id into the logs and echo header.
- **New imports:** `use tracing::Instrument;` and `uuid::Uuid` (both already
  available -- `uuid` is a dependency with `v4`; `HeaderName`/`HeaderValue`/
  `Instant`/`Next` are already imported in `lib.rs`). No new crate.
- **Placement (outermost):** in `raspi/service/src/lib.rs#app`, `Router::layer`
  makes the **last** `.layer()` the outermost, so add `request_trace` *after*
  `proto_headers`:

  ```rust
  .layer(middleware::from_fn_with_state(state.clone(), host_allowlist))
  .layer(middleware::from_fn_with_state(state.clone(), proto_headers))
  .layer(middleware::from_fn(request_trace))   // outermost: wraps everything
  ```

  Flow becomes `request_trace -> proto_headers -> host_allowlist -> handler`, so
  latency covers the full stack and **even `421`/`404` responses get an access
  line and an `x-request-id` header** (fixes the silent-rejection gap).
- Streaming endpoints (`/v1/events` SSE, `/v1/preview/live.mjpeg`) log one access
  line at response-ready (time-to-first-byte); the header echo is harmless on
  streams. **Scope boundary:** `.instrument(span)` wraps only the handler future,
  so logs emitted from a response *body* stream after that future resolves -- e.g.
  the lag `tracing::warn!` in the SSE `updates` map in `raspi/service/src/events.rs`
  -- fire once the span has closed and will **not** carry `request_id`. Making them
  inherit it would mean instrumenting the body stream itself; not worth it now. The
  guarantee this middleware makes is: access line + handler-future logs, not
  streamed-body logs.
- Note for later (not now): if health/preview/SSE access lines get noisy, drop
  those paths to DEBUG with a path check. Keep v1 uniformly INFO.

### 2. Tests -- new `raspi/service/tests/request_id.rs`

Mirror the in-process `oneshot` header-assertion pattern from
`raspi/service/tests/health.rs#health_returns_wire_contract` (no new dev-deps;
`tower::ServiceExt` already dev-dep). Test the **observable header contract**, not
log strings (log-content assertions are structure-sensitive and brittle):

1. **Generates an id when absent:** GET `/v1/health` with a valid `Host` and no
   `x-request-id` -> response carries a non-empty `x-request-id`.
2. **Echoes a valid inbound id:** GET `/v1/health` with `x-request-id: corr-123`
   -> response `x-request-id == corr-123`.
3. **Present on a router 404:** GET `/v1/nope` (valid `Host`, `404`) -> still
   carries `x-request-id`, proving the middleware is outermost (mirrors
   `raspi/service/tests/health.rs#unknown_path_still_carries_proto_headers`).
4. **Present on a 421 host rejection:** GET `/v1/health` with a bad `Host` (e.g.
   `evil.example:8080`, or omit `Host`) -> `421 MISDIRECTED_REQUEST` **and** a
   non-empty `x-request-id`. This is the load-bearing case: it proves
   `request_trace` wraps `host_allowlist` (an *inner* middleware that
   short-circuits, not just the router fallback), closing the silent-rejection gap
   the Context calls out. Existing host tests
   (`raspi/service/tests/recording.rs#host_allowlist_rejects_missing_bad_and_wrong_port_hosts`)
   assert status only, so the header assertion is new coverage.
5. **Rejects an unsafe inbound id:** GET `/v1/health` with an over-long
   (`> 128`-char) or bad-charset `x-request-id` -> response `x-request-id` is a
   fresh generated id, not the client's -- locks the `inbound_request_id`
   validation (the log/header-injection guard). Promoted from optional to required:
   the validation is a deliberate hardening contract, so it needs a test that fails
   if someone drops it.

We intentionally do **not** assert that a log line was emitted or that a handler
log inherited `request_id`. Asserting the access line *is* feasible -- a
thread-scoped `tracing::subscriber::with_default` under a current-thread
`#[tokio::test]` captures events on the test thread, with no process-global state
and no cross-test interference. We skip it because the payoff is low: assertions
on `fmt` output are string/field-structure-sensitive and brittle, and hand-rolling
a capturing `Layer` to assert on fields isn't worth the weight. The header
contract is the stable testable surface.

### 3. ADR 13 + transport-ADR annotation

- **New** `raspi/docs/design/13-2026-07-01-request-logging-and-log-access.md`
  (next raspi seq after ADR 12; date `>= 2026-06-30`, so today is valid). Standard
  shape (Title / Status: Accepted / Context / Decision / Consequences /
  Alternatives). Records: structured req/res logging with request ids to journald;
  `x-request-id` honored+echoed for app<->Pi correlation; the request-id span
  covers the access line and handler-future logs but **not** response-body stream
  logs (SSE/MJPEG polled after the handler resolves) -- state this boundary so the
  ADR's promise matches the middleware; **`/v1/logs` deferred**,
  journald-over-SSH is the log-access path until a non-SSH consumer exists; and
  that runtime verbosity is already tunable via `RUST_LOG` (the default
  `fmt::init()` honors it through a `Targets` filter, `target=level` syntax), so
  no code change and no `env-filter` feature are needed. **Alternatives considered**
  (from the design discussion): tower-http `TraceLayer`+`SetRequestId` (rejected --
  adds `tower-http` and promotes `tower` to a normal dep for what the `from_fn`
  idiom already does); in-memory ring buffer + `/v1/logs` (rejected -- dies with
  the process, useless exactly when the service is wedged; journald is durable and
  already SSH-reachable); journald-via-`journalctl` subprocess for `/v1/logs`
  (rejected -- no macOS/mock parity, subprocess per request, Linux-only); adding
  `tracing-subscriber`'s `env-filter` feature for the verbosity knob (rejected --
  `RUST_LOG` already works via the default `Targets` filter; `env-filter` only adds
  span/field-directive syntax nobody needs under grep-over-journalctl, at the cost
  of pulling `matchers` + `regex-automata` into the cross-compiled Pi binary).
- **Edit** `raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md`: at the
  `/v1/logs?since=&level=` line (the "tail from the writable partition (ASCII)"
  entry under the `Status / control` group), add a deferred `> Note:` block --
  mirroring the neighboring `/v1/status` deferred notes -- stating `/v1/logs` is
  deferred, journald-over-SSH is the current path, and pointing to ADR 13. Append-
  only: do not delete the line.
- `just adr-check` must pass (seq/date/format).

### 4. Doc notes (small)

- `raspi/AGENTS.md`: add ADR 13 to the Design-decisions index (which `721701c`
  reconciled); one line under the logging/running note that the service emits
  structured req/res access logs with request ids to journald, correlate a request
  with `journalctl -u dancam` + grep on the request id; and that `RUST_LOG` already
  tunes verbosity at runtime with no rebuild (`RUST_LOG=dancam=debug`; `Targets`
  `target=level` syntax, no span/field directives).
- `README.md` section 7 ("Service management"): optional one-liner that req/res
  access lines now appear in `journalctl -u dancam -f`, filterable by request id,
  and that `RUST_LOG` (e.g. `RUST_LOG=dancam=debug` via `systemctl edit dancam`)
  raises verbosity over SSH without a rebuild. Not mandated (no
  provisioning/config/unit change), just helpful.

## Verification

1. **Unit/integration:** `just raspi-test` (new `request_id.rs` + existing suites
   green) and `just raspi-check` (fmt + `clippy --all-targets -D warnings`) --
   prefer the Justfile gates over raw `cargo` per `AGENTS.md#Conventions`.
2. **ADR:** `just adr-check`.
3. **Manual, mock backend:** run the service with `just raspi-mock` (mock backend
   on `127.0.0.1:8080`), then:
   - `curl -i http://localhost:8080/v1/health -H 'Host: localhost:8080'` -> response
     has an `x-request-id` header; stdout shows one INFO `request` line with
     `request_id`/`method`/`path`/`status`/`latency_ms`.
   - `curl -i http://localhost:8080/v1/health -H 'Host: localhost:8080' -H 'x-request-id: corr-abc'`
     -> response `x-request-id: corr-abc` and the log line's `request_id=corr-abc`.
   - A bad-Host request (`421`) and an unknown path (`404`) each still produce an
     access line + `x-request-id` (no longer silent).
   - Handler-future span inheritance (a handler's own `tracing` log carrying its
     request's `request_id`) is **not** manually gated under `just raspi-mock`
     today: the reachable mock handlers emit no per-request log on demand -- the
     only handler-future log sites (`clips::list_clips`, `events`'s
     `enrich_current_segment`) are unreachable `spawn_blocking` JoinError branches,
     and recorder/backend logs run in detached tasks outside the request span.
     Inheritance is a design property of the `.instrument(span)` wrap; the manual
     checks here stay on the access line and the `x-request-id` header. (The SSE
     lag `warn!` likewise won't carry the id -- the documented streaming boundary.)
   - `RUST_LOG=dancam=debug` raises the `dancam` crate to debug and unset defaults
     to info -- already works with the current `fmt::init()` (no rebuild, no
     `env-filter` feature); the check just confirms the behavior the doc note
     documents.
4. **On the Pi (optional, end-to-end):** after deploy, hit an endpoint from the app
   or `curl http://dancam.local:8080/v1/health`, then
   `ssh <user>@dancam.local 'journalctl -u dancam -n 50 --no-pager'` shows the
   access line; `journalctl -u dancam | grep <request_id>` shows the full request.

## Files touched

- EDIT `raspi/service/src/lib.rs` -- add `request_trace` middleware + helper; add
  as the outermost `.layer(middleware::from_fn(request_trace))` in `app`.
- NEW `raspi/service/tests/request_id.rs` -- header-contract tests.
- NEW `raspi/docs/design/13-2026-07-01-request-logging-and-log-access.md` -- ADR.
- EDIT `raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md` -- deferred
  `/v1/logs` pointer to ADR 13.
- EDIT `raspi/AGENTS.md` -- ADR 13 index entry + one-line logging note.
- EDIT `README.md` -- optional section-7 note (access logs + `RUST_LOG`).
