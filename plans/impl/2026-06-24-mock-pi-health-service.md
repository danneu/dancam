# Plan: swoop `oak` mock-Pi half -- stand up the Pi service with `GET /v1/health`

## Context

This is the **first real code in the repo**. Today `raspi/` is only `AGENTS.md`
plus ADRs; there is no build. Swoop `oak` ("Bring-up + mock", the foundation for
everything below) has two parallel tracks: the real Pi firmware and a **mock Pi**
("a small fake local server with canned status + sample frames/clips") so app work
never blocks on hardware. This plan builds the **mock-Pi half on the Mac**, while the
Pi hardware ships.

Crucially this is **not throwaway**: per the service-language ADR the mock Pi and the
real Pi are the **same Rust binary at different maturity**. This step is the skeleton
of the real service. Later swoops swap canned data for real camera/storage/AP behind a
seam instead of rewriting, and grow `/v1/preview`, `/v1/recording`, `/v1/clips`, and
SSE `/v1/events` onto the same router.

Goal of this step: an axum service that answers `GET /v1/health` with a canned 200
JSON, runnable and curl-able on macOS.

### Decisions locked (from ADRs + user)

- The **transport/API ADR is `Accepted`** (`2026-06-22-app-pi-transport-and-api.md`,
  line 3) -- the wire contract is settled; build on it directly.
- The **service-language ADR is `Proposed`** (`2026-06-23-service-language-rust.md`,
  line 3). **Decision: flip it to `Accepted` first**, as a one-line `docs(raspi):`
  commit, before code lands on it. (Flipping the Status line is the documented ADR
  lifecycle -- Proposed | Accepted | ... -- not a forbidden silent rewrite; only
  changing the *decision content* would require a superseding ADR.)
- **Bind default `127.0.0.1:8080`**, overridable by `DANCAM_BIND`. The transport ADR
  never states a port -- it writes `http://<pi>/v1/...` (implying 80) against the
  `192.168.4.1` / `dancam.local` gateway. Port 80 is privileged on macOS, so the Mac
  dev default is `:8080`; the real Pi sets `DANCAM_BIND=0.0.0.0:80` later via its
  systemd unit. The wire contract (port 80 on the Pi) is preserved by config, not code.
- **Crate lives at `raspi/service/`**, package/binary name `dancam` (matches the
  `dancam.service` systemd unit and `systemctl restart dancam` in `raspi/AGENTS.md`).
  `raspi/` stays a container so `provisioning/` (deploy.sh, systemd unit, AP configs)
  and camera bring-up tooling can sit beside `service/` later.

## File layout (after this step)

```
raspi/service/
  Cargo.toml          # package "dancam"; [lib] + [[bin]]; deps below
  Cargo.lock          # committed (this crate produces a binary)
  src/
    main.rs           # thin runner: init tracing, build AppState, dancam::app(state),
                      #   bind DANCAM_BIND (default 127.0.0.1:8080), serve w/ graceful shutdown (SIGINT+SIGTERM)
    lib.rs            # app(AppState)->Router; AppState; resolve_boot_id()/parse_boot_id(); proto-header layer; mod decls
    backend.rs        # THE MOCK/REAL SEAM: `Backend` trait + `MockBackend`
    health.rs         # `HealthResponse` + `health` handler
  tests/
    health.rs         # integration test locking the /v1/health wire contract
```

Lib + bin split is deliberate: `app()` lives in the lib so `tests/health.rs` can build
the router and exercise it with `tower`'s `oneshot` (no socket bind). Each future
endpoint becomes a new `src/<name>.rs` (handler + response types) mounted in `app()`;
each future subsystem becomes a method on `Backend`. `.gitignore` (repo root) gains a
Rust section: `/raspi/service/target/` (do **not** ignore `Cargo.lock`).

Scaffold command (creates the dir): `cargo new raspi/service --name dancam --vcs none`
(`--vcs none` keeps Cargo from nesting a git repo / writing its own `.gitignore`; we
centralize ignores in the root file).

## Dependencies (Cargo.toml)

Lean and justified; the 512 MB target is runtime RAM (binary-size trimming via
`default-features = false` is a later lever, noted but not done now). Time needs **no**
crate -- `std::time` covers `uptime_s` and `t_ms`, so no `chrono`.

```toml
[dependencies]
axum = "0.8"                                             # web framework named by the ADR; default features cover routing + Json
tokio = { version = "1", features = ["rt-multi-thread", "macros", "net", "signal"] }
                                                         # macros=#[tokio::main]; net=listener; signal=graceful shutdown on SIGINT+SIGTERM (systemd stops via SIGTERM)
serde = { version = "1", features = ["derive"] }         # derive Serialize for response types
uuid = { version = "1", features = ["v4"] }              # boot_id fallback (UUID v4) when /proc/sys/kernel/random/boot_id is unavailable (macOS/mock)
tracing = "0.1"                                          # idiomatic axum logging; grows into request tracing + /v1/logs
tracing-subscriber = "0.3"

[dev-dependencies]
tower = { version = "0.5", features = ["util"] }         # ServiceExt::oneshot for the router test
http-body-util = "0.1"                                   # collect the response body in the test
serde_json = "1"                                         # parse the body in the test (also becomes a direct dep when we hand-build JSON)
```

`edition = "2021"` (max toolchain compatibility for zigbuild/cross later; 2024 is fine
if preferred). `serde_json` is pulled transitively by axum's Json at runtime; it's
listed only as a dev-dep for now and promoted to a direct dep when an endpoint
hand-builds JSON (e.g. an error envelope).

## Health response schema (aligned to the Accepted transport ADR)

ADR line 112: `GET /v1/health -- tiny liveness {boot_id, uptime_s, recording, t_ms}. (Unauth.)`
ADR lines 89-91 (conventions): every response carries `X-Dancam-Proto: 1` and
`X-Dancam-Boot-Id`.

```rust
// health.rs
#[derive(serde::Serialize)]
pub struct HealthResponse {
    pub boot_id: String,   // host boot identity: kernel boot UUID on Linux, UUID v4 fallback on macOS/mock (see resolve_boot_id below)
    pub uptime_s: u64,     // whole seconds since process start (started.elapsed())
    pub recording: bool,   // from Backend::recording() -- canned `false` today
    pub t_ms: u64,         // wall-clock epoch ms (SystemTime::now; duration_since(UNIX_EPOCH).map(..).unwrap_or(0) -- never panic on a pre-1970 clock); real Pi: approximate pre time-sync
}

pub async fn health(State(s): State<AppState>) -> axum::Json<HealthResponse> { /* fill from state */ }
```

Field names are snake_case == the Rust field names, so no serde renames. Example body:

```json
{"boot_id":"3f1c0e7a-...","uptime_s":12,"recording":false,"t_ms":1750636800000}
```

Plus headers on every response: `x-dancam-proto: 1`, `x-dancam-boot-id: 3f1c0e7a-...`.
The header boot-id and the body `boot_id` are the **same value**, sourced once from
`AppState` (single source of truth).

**boot_id provenance.** A small `resolve_boot_id()` (in `lib.rs`) computes it once at
startup and stores it in `AppState`: on Linux it reads `/proc/sys/kernel/random/boot_id`
(the **kernel boot UUID** -- the canonical `boot_id` per the storage ADR, line 118,
"also exposed as `X-Dancam-Boot-Id`"); on macOS/mock it falls back to
`uuid::Uuid::new_v4()`. Same UUID wire shape either way. This matters for fidelity: the
kernel boot id is **stable across service restarts** within one boot and changes only on a
real reboot -- exactly what the app's reconnect / `boot_id`-change detection keys on
(transport ADR line 313). A per-process UUID would make every `systemctl restart` look
like a reboot. (On Mac the fallback is per-process; acceptable for the mock.)

**Trim the procfs read (latent Pi-only bug).** `/proc/sys/kernel/random/boot_id` returns
the UUID with a **trailing newline**, and `http::HeaderValue::from_str` rejects `\n` (a
control char) -- so building `X-Dancam-Boot-Id` from the raw value would fail on **every
response** on the real Pi (a panic if `unwrap`ed, a silently dropped header otherwise),
violating the every-response rule. The Mac UUID-v4 fallback has no newline, so the bug
would pass green on the dev host and surface only on hardware. Guard it now: factor the
parse into a pure `parse_boot_id(raw: &str) -> String` that trims, and have
`resolve_boot_id()` run the file contents through it. A host-independent unit test
(`parse_boot_id("3f1c...\n") == "3f1c..."`) locks the trim without needing `/proc`.

**Proto headers as a router-wide layer** (so all endpoints -- and unknown paths -- inherit them):
`app()` registers the `/v1/health` route, then applies
`axum::middleware::from_fn_with_state(state, ...)` via `Router::layer`, setting
`X-Dancam-Proto: 1` and `X-Dancam-Boot-Id` (from `AppState`) on every response. Using
`.layer()` (**not `.route_layer()`**) is the load-bearing choice for the ADR's "every
response carries..." convention: `.layer()` runs the middleware even on requests that
match no route and fall through to axum's **built-in default 404**, so unknown paths
inherit the headers with **no explicit fallback needed**. `.route_layer()` is the opposite
-- it runs only on matched routes (its documented purpose is to *avoid* turning a `404`
into, e.g., a `401`), so switching to it would silently strip the headers off 404s. One
ordering caveat does hold: `.layer()` only wraps routes registered **before** the call, so
register all routes first, then `.layer(...)`, then `.with_state(...)`. The unknown-path
test below guards against an accidental switch to `route_layer`.

## The mock/real seam (what is canned vs. real)

The seam is a trait in `backend.rs`. Host/process facts are real even in the mock:
`uptime_s` and `t_ms` come from the OS clock, and `boot_id` from `resolve_boot_id()`
(kernel boot UUID on Linux, UUID v4 fallback on Mac -- see above), so none of these are
canned or behind the trait. The only health field that needs a backend is `recording`, so
the trait starts with one method and grows (it is the first slice of the ADR's
`GET /v1/status`).

```rust
// backend.rs -- THE MOCK/REAL SEAM.
// Canned data today (MockBackend). The real Pi (swoop `oak` real half) provides a
// hardware-backed impl of this same trait without touching the HTTP layer. The trait
// grows methods as swoops deepen: status(), storage(), temp_c(), preview(), clips(), ...
pub trait Backend: Send + Sync + 'static {
    fn recording(&self) -> bool;
}

pub struct MockBackend;
impl Backend for MockBackend {
    fn recording(&self) -> bool { false }   // canned
}
```

```rust
// lib.rs
#[derive(Clone)]
pub struct AppState {
    pub boot_id: std::sync::Arc<str>,        // cheap to clone into handler + middleware
    pub started: std::time::Instant,
    pub backend: std::sync::Arc<dyn Backend>,
}
pub fn app(state: AppState) -> Router { /* /v1/health route, then proto-header .layer (covers built-in 404), then with_state */ }
```

Selection of mock vs. real is **not built now**: `main` wires `MockBackend`
unconditionally. When the real backend lands it's a one-line change (a `#[cfg(...)]`
or `DANCAM_BACKEND` env switch); the mock stays for Mac dev and app testing. Naming it
`MockBackend` and isolating it in `backend.rs` makes "what is canned" obvious.

## Run + curl (macOS)

```sh
cd raspi/service
cargo run                                   # logs: listening on 127.0.0.1:8080
# in another shell:
curl -i http://127.0.0.1:8080/v1/health     # 200; see headers + JSON body
curl -s http://127.0.0.1:8080/v1/health | jq   # pretty (optional)
DANCAM_BIND=0.0.0.0:9000 cargo run          # env override (e.g. to reach from a phone on the LAN)
```

Expected `curl -i`: `HTTP/1.1 200 OK`, `content-type: application/json`,
`x-dancam-proto: 1`, `x-dancam-boot-id: <uuid>`, body as above.

## Tests

Integration tests in `tests/health.rs` lock observable wire-contract behavior
(structure-insensitive): build `dancam::app(AppState` with `MockBackend)` and drive it
via `tower`'s `oneshot` (no socket bind). Two cases:

- **`GET /v1/health`:** status `200`; header `x-dancam-proto == "1"` and
  `x-dancam-boot-id` present; body parses and has `boot_id` (== the header), `uptime_s`
  (u64), `recording == false`, `t_ms > 0`.
- **Unknown path (`GET /v1/nope`):** status `404`, and the response **still** carries
  `x-dancam-proto: 1` and `x-dancam-boot-id` -- proves the proto-header `.layer` covers the
  built-in 404, not just matched routes (the ADR's every-response rule), and would fail if
  someone switched the layer to `route_layer`.

Plus one **unit test** in `lib.rs` (`#[cfg(test)]`) for `parse_boot_id`: assert
`parse_boot_id("3f1c0e7a-...\n") == "3f1c0e7a-..."` and that an already-clean value is
unchanged. It is host-independent -- it exercises the newline-trim behavior without
reading `/proc` -- so it catches the Pi-only `X-Dancam-Boot-Id` bug from the Mac dev host.

Run with `cargo test`. (Repo Conventional-Commit types don't include `test`, so these
tests ship inside the `feat` commit that adds the endpoint -- the feature and the tests
that lock it are one coherent change.)

## Commit breakdown (Conventional Commits, scope `raspi`)

1. **`docs(raspi): accept the Pi service-language ADR`**
   One-line edit to `raspi/docs/design/2026-06-23-service-language-rust.md`:
   `- **Status:** Proposed` -> `- **Status:** Accepted`. Gates landing code on it.

2. **`chore(raspi): scaffold the Pi service Cargo project`**
   `cargo new raspi/service --name dancam --vcs none`; fill `Cargo.toml` deps; add the
   Rust section to the root `.gitignore` (`/raspi/service/target/`); commit `Cargo.lock`;
   minimal runnable `main.rs` (reads `DANCAM_BIND` default `127.0.0.1:8080`, serves an
   empty `Router`, tracing init, graceful shutdown on SIGINT+SIGTERM). Verifiable: builds, runs, logs the
   bind address (curl returns 404 -- no routes yet).

3. **`feat(raspi): serve GET /v1/health`**
   Introduce `lib.rs` (`app()` + `AppState` + `resolve_boot_id()`/`parse_boot_id()` +
   proto-header `.layer`), `backend.rs` (`Backend` + `MockBackend` seam), `health.rs`
   (`HealthResponse` + handler); mount `/v1/health`; point `main.rs` at `dancam::app(...)`;
   add `tests/health.rs` (health + unknown-path cases), the `parse_boot_id` unit test, +
   dev-deps. Verifiable: `curl`
   returns the 200 JSON + headers, an unknown path returns 404 *with* the proto headers,
   and `cargo test` passes.

Commits 2 and 3 can be squashed into one `feat(raspi): scaffold service + serve GET /v1/health`
if a single foundational commit is preferred; the split keeps the cargo-init boilerplate
reviewable apart from the first endpoint.

## Out of scope (later swoops / deepening passes -- noted, not built here)

Cross-compile to aarch64 musl (`cargo-zigbuild`/`cross`), the systemd unit + `deploy.sh`,
read-only root, hostapd/dnsmasq AP, Bonjour `_dancam._tcp` advertisement, the transport
ADR's HTTP security hardening (Host allowlist + `421`, Sec-Fetch/Origin, no CORS),
real `rpicam-vid` capture, MJPEG preview, recording control, clip pull + SD storage, SSE
events, and the other `/v1` endpoints (`status`, `capabilities`, `time`, ...). Each grows
onto this skeleton: a new `src/<name>.rs` route and/or a new `Backend` method.

## Verification (end to end)

1. `cd raspi/service && cargo build` -- compiles clean (no cross-compile; Mac host).
2. `cargo run` -- logs `listening on 127.0.0.1:8080` and stays up.
3. `curl -i http://127.0.0.1:8080/v1/health` -- `200`, `content-type: application/json`,
   `x-dancam-proto: 1`, `x-dancam-boot-id: <uuid>`; body has `boot_id`/`uptime_s`/
   `recording:false`/`t_ms`; confirm body `boot_id` == `x-dancam-boot-id` header; run
   twice and confirm `uptime_s` increases.
4. `curl -i http://127.0.0.1:8080/v1/nope` -- `404`, and the response still carries
   `x-dancam-proto: 1` + `x-dancam-boot-id` (the every-response rule holds on unknown paths).
5. `DANCAM_BIND=0.0.0.0:9000 cargo run` then `curl -s http://127.0.0.1:9000/v1/health`
   -- env override works.
6. `cargo test` -- the `/v1/health` + unknown-path contract tests pass.
