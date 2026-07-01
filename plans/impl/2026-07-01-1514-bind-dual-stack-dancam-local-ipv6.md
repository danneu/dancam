# Plan: bind the Pi service dual-stack so `dancam.local` IPv6 resolves

## Context

When the iPhone app pulls a clip from the Pi over `dancam.local`, the Xcode console
prints TCP `RST` + `nw_endpoint_flow_failed` noise against `[<global-v6>]:8080`
before the pull succeeds. Root cause is an advertise/listen mismatch, not an app bug:

- Stock Avahi on the Pi advertises `dancam.local` with **both** an A (IPv4) and an
  AAAA (IPv6 SLAAC) record.
- The service binds **IPv4-only**: `raspi/dancam.service` sets
  `DANCAM_BIND=0.0.0.0:8080`, and `0.0.0.0` is the IPv4 wildcard. Nothing owns
  IPv6:8080.

So iOS Happy Eyeballs resolves both families, tries IPv6 first, the Pi's kernel
answers `RST` (no listener), iOS falls back to IPv4, and the pull completes -- with a
burst of connection-failure logging on every request.

**Ideal fix (Option A): make the service honor what it advertises -- bind dual-stack.**
Serve one IPv6 wildcard socket (`[::]`) with `IPV6_V6ONLY` disabled, so it accepts
both IPv6 and IPv4-mapped clients. IPv6 connects instead of being refused; the RST
churn disappears; IPv4 (AP mode at `10.42.0.1`, loopback, tests) is unaffected. We
reject Option B (tell Avahi to stop publishing AAAA) because it *suppresses* a
capability to hide a symptom, and it would add new managed system state
(`avahi-daemon.conf` publish directives) rather than remove the actual defect.

Outcome: `dancam.local` works natively over IPv6 and IPv4; no client-side changes.

## Approach

Build the listen socket via the `socket2` crate so we can set `IPV6_V6ONLY=false`
explicitly (portable), instead of relying on the Linux `net.ipv6.bindv6only=0`
default -- which would work on the Pi but silently break the macOS dev task
(`raspi-mock-lan`), since macOS defaults `IPV6_V6ONLY=1`.

Put the socket builder in `lib.rs` as a `pub fn` (next to `app()`), route **all**
binds through it (v4 default, v6 wildcard alike -- it only flips the v6-only flag for
IPv6 addresses), and add a behavioral unit test that binds `[::]:0` and asserts an
IPv4 client is accepted. That locks the dual-stack property structure-insensitively.

### Two calls made here (flagged for veto at approval)

- **`main.rs` default stays `127.0.0.1:8080`** (IPv4 loopback). It is dev/test-only,
  produces no IPv6 noise on loopback, and changing it risks surprising local runs. The
  socket builder handles it as a plain v4 bind.
- **The `raspi-mock-lan` Justfile recipe also moves to `[::]:9000`.** It is the Mac
  dev-LAN path that hits the same Happy Eyeballs mismatch when reached by a dual-stack
  hostname; the `set_only_v6(false)` fix is what makes `[::]` work on macOS. Reaching
  the mock on port 9000 also requires the Host allowlist to key off the *bound* port
  (change 4) -- otherwise its `Host: ...:9000` header is rejected `421` under the
  hardcoded-8080 policy.

## Changes by area

### 1. Rust: socket builder + test -- `raspi/service/src/lib.rs`

Add a public helper beside `fn app` (anchor: `raspi/service/src/lib.rs#fn app`):

```rust
use socket2::{Domain, Protocol, Socket, Type};
use std::net::SocketAddr;

/// Build a listening TCP socket for `bind` (an `IP:port` literal). For an IPv6
/// wildcard this disables IPV6_V6ONLY so the socket also accepts IPv4-mapped
/// clients (dual-stack). Returns a blocking std listener; the caller adopts it
/// (set_nonblocking + TcpListener::from_std).
pub fn dual_stack_listener(bind: &str) -> std::io::Result<std::net::TcpListener> {
    let addr: SocketAddr = bind.parse().map_err(|e| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("invalid DANCAM_BIND {bind:?}: {e}"),
        )
    })?;
    let socket = Socket::new(Domain::for_address(addr), Type::STREAM, Some(Protocol::TCP))?;
    if addr.is_ipv6() {
        socket.set_only_v6(false)?; // accept IPv4-mapped too
    }
    socket.set_reuse_address(true)?; // match tokio's default; survive fast restarts
    socket.bind(&addr.into())?;
    socket.listen(1024)?;
    Ok(socket.into())
}
```

Add to the existing `#[cfg(test)] mod tests` in `lib.rs` a behavioral test (plain
`#[test]`, no runtime needed):

- `dual_stack_listener_accepts_ipv4_client`: bind `"[::]:0"`, read the port, spawn a
  thread doing `listener.accept()`, then `std::net::TcpStream::connect(("127.0.0.1", port))`
  and assert the connect + accept both succeed. (This is load-bearing on macOS, where a
  `[::]` bind without `set_only_v6(false)` would refuse the IPv4 client; on Linux it
  also guards against reverting to an IPv4-only wildcard.)
- Optionally a second assertion that `"127.0.0.1:0"` binds and accepts a `127.0.0.1`
  client -- guards the unchanged default path.

The `socket2` 0.6.4 API used here (`Socket::new`, `set_only_v6`, `set_reuse_address`,
`Domain::for_address`, `From<Socket> for std::net::TcpListener`) was confirmed against
the lock during review, together with the dual-stack behavior on this Mac (a `[::]`
socket with `IPV6_V6ONLY=0` accepts a `127.0.0.1` client as an IPv4-mapped peer).

### 2. Rust: dependency -- `raspi/service/Cargo.toml`

Add `socket2 = "0.6"` to `[dependencies]` (matches `Cargo.lock` 0.6.4; today it is
transitive via tokio only, so this is additive -- no new download).

### 3. Rust: adopt the socket -- `raspi/service/src/main.rs`

Replace the bind line (anchor: the `DANCAM_BIND` read + `TcpListener::bind`) with:

```rust
let bind = env::var("DANCAM_BIND").unwrap_or_else(|_| "127.0.0.1:8080".to_string());
let std_listener = dancam::dual_stack_listener(&bind)?;
std_listener.set_nonblocking(true)?; // required before from_std
let listener = TcpListener::from_std(std_listener)?;
let local_addr = listener.local_addr()?;
```

Add `dual_stack_listener` to the `use dancam::{...}` import group. `main()` already
returns `Box<dyn std::error::Error>`, which absorbs `io::Error` via `?` -- no
error-type change. Everything downstream (`axum::serve(listener, app(state))`,
graceful shutdown) is untouched: `axum::serve` still gets a `tokio::net::TcpListener`.

### 4. Host allowlist: key on the bound port, not a hardcoded 8080 -- `raspi/service/src/lib.rs` + `main.rs`

`HostPolicy` (anchor: `raspi/service/src/lib.rs#struct HostPolicy`) hardcodes
`service_port: 8080`, and `allows()` rejects a `Host` whose port != that constant
(existing test `host_policy_rejects_disallowed_hosts_and_wrong_ports` asserts
`!allows("10.42.0.1:9999")`). So **any non-8080 bind `421`s on ported `Host` headers**
-- including the mock recipe's own documented `curl http://127.0.0.1:9000/v1/health`
(`plans/impl/2026-06-24-mock-pi-health-service.md`), which `421`s under today's
allowlist. Moving the smoke/dev path to `[::]:9000` makes this bite, so key the
allowlist to the port the service actually bound:

- `lib.rs`: add `HostPolicy::new(service_port: u16) -> Self` (same allowlisted names,
  given port); `Default` delegates to `new(8080)`. Add
  `AppState::with_service_port(mut self, port: u16) -> Self` (mirrors `with_rec_dir`)
  that sets `host_policy = Arc::new(HostPolicy::new(port))`.
- `main.rs`: `local_addr` is already computed from the listener; after the match that
  builds `AppState`, thread it once (shadowing):
  `let state = state.with_service_port(local_addr.port());`.
- Test (in the existing `#[cfg(test)] mod tests`, plain `#[test]`): `HostPolicy::new(9000)`
  accepts `127.0.0.1:9000` and `dancam.local:9000` and rejects `127.0.0.1:8080` -- the
  inverse of the current wrong-port assertion. Existing 8080 tests stay green (`Default`
  is still 8080).

No behavior change on the Pi (it binds 8080, so `service_port` stays 8080); this only
un-breaks non-8080 binds (and a `:0` ephemeral bind now self-configures). `HostPolicy`
stays private -- the child `mod tests` can reach `HostPolicy::new` without exporting it.

### 5. Deployed bind -- `raspi/dancam.service`

Change `Environment=DANCAM_BIND=0.0.0.0:8080` -> `Environment=DANCAM_BIND=[::]:8080`
(anchor: `raspi/dancam.service#Environment=DANCAM_BIND`). Update the preceding comment
so it stops saying "loopback-only 127.0.0.1:8080 ... Bind all interfaces" in IPv4
terms: note it binds the dual-stack `[::]` wildcard (both families; the binary forces
`IPV6_V6ONLY` off) so the phone on the AP (IPv4) and the Mac on the LAN (IPv4 or IPv6
via `dancam.local`) all reach it. This file is rsync'd verbatim by `raspi/deploy.sh`,
so this edit *is* the deploy change -- no `deploy.sh` edit.

### 6. Dev LAN recipe -- `Justfile`

`raspi-mock-lan` recipe: `DANCAM_BIND=0.0.0.0:9000` -> `DANCAM_BIND=[::]:9000`
(anchor: the `raspi-mock-lan` recipe). Now dual-stack on macOS (change 1) and
loopback health-checkable because the allowlist keys on the bound port (change 4).

### 7. Docs in lockstep (required by root `AGENTS.md`)

- **`README.md`**, heading `## 7. Deploy and run the service`: in the fenced unit
  block, `Environment=DANCAM_BIND=0.0.0.0:8080` -> `[::]:8080`. The `dancam.local:8080`
  / `10.42.0.1:8080` verification `curl`s are address-family-agnostic and need no edit
  (they resolve to whatever the name/AP serve). No IPv4/IPv6 prose exists to change.
- **`raspi/AGENTS.md`**, `### Running`: update the sentence "It sets
  `DANCAM_BIND=0.0.0.0:8080` so the service listens on all interfaces" to the
  dual-stack `[::]:8080` value + phrasing.

### 8. Record the decision -- ADR 02 amendment

`raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md` (the transport ADR,
Accepted, raspi-owned) is currently silent on the listen socket. Per root `AGENTS.md`
("write the pivot down in the same change"), add an `Amended: 2026-07-01` status line
and a short "Listen socket" note: the service binds one dual-stack `[::]:8080` socket
with `IPV6_V6ONLY` off, accepting IPv6 and IPv4-mapped clients, to answer the AAAA
Avahi advertises for `dancam.local` and stop the Happy Eyeballs RST churn; the AP link
stays IPv4-only per ADR 06. Note the paired allowlist refinement (this ADR documents
the Host allowlist): it still gates by name (clients send `Host: dancam.local`) but now
keys the port check to the *actually-bound* port instead of a hardcoded 8080 -- no
behavior change on the Pi, where the bind is 8080. This is an amendment (adding
previously-unstated detail), not a supersession -- matching ADR 06's `Amended:`
precedent.

## Explicitly out of scope

- **Avahi / `raspi/ansible/site.yml`** -- unchanged. Option A needs no AAAA/publish
  tweak; the only managed Avahi setting (`allow-interfaces=wlan0`) is orthogonal.
- **`raspi/deploy.sh`** -- unchanged (ships the unit verbatim; its `localhost:8080`
  health probe still answers on a dual-stack socket).
- **`main.rs` default** (`127.0.0.1:8080`) -- unchanged (see Approach).
- **Reaching the mock by LAN name/IP** (e.g. a phone hitting `http://<mac>.local:9000`)
  stays gated by the Host allowlist -- that `Host` is not allowlisted, a separate design
  question. Change 4 only fixes the *port* dimension (loopback names on any bound port);
  the smoke test uses loopback hosts, which are allowlisted.
- **History/artifact files** (`plans/**`, `video-review.*/**`) -- append-only; not
  retro-edited.

## Verification

**Build + unit test (Mac dev):**
- `cd raspi/service && cargo test` (or the repo `just` task). Two new tests:
  `dual_stack_listener_accepts_ipv4_client` (load-bearing proof that `[::]` +
  `set_only_v6(false)` accepts an IPv4 client on macOS) and the `HostPolicy::new(9000)`
  port test (allowlist keys on the bound port). Existing tests unchanged (they drive
  `dancam::app` via `.oneshot`, never a socket).

**Local dual-stack smoke (Mac):**
- `DANCAM_BIND=[::]:9000 cargo run` (or `just raspi-mock-lan`), then in another shell:
  - `curl -4 -i http://127.0.0.1:9000/v1/health` -> `200` + `x-dancam-proto: 1`
  - `curl -6 -i http://[::1]:9000/v1/health` -> `200` + `x-dancam-proto: 1`
  Both succeeding on one process proves dual-stack. The `Host` headers are
  `127.0.0.1:9000` / `[::1]:9000`; these now pass because the allowlist keys on the
  bound port (change 4) and both names are allowlisted -- pre-change they would `421`.

**End-to-end on the Pi (the original repro):**
- Deploy: `just raspi-deploy` (or `./raspi/deploy.sh`); confirm the post-deploy
  `localhost` health probe passes.
- From the Mac:
  - `curl -6 -i http://dancam.local:8080/v1/health` -> `200` (previously connection
    refused / RST). Confirms IPv6 now serves and the `Host: dancam.local` allowlist
    passes over IPv6.
  - `curl -4 -i http://dancam.local:8080/v1/health` -> `200` (IPv4 still works).
- In the iPhone app, pull a clip while watching the Xcode console: the
  `tcp_input ... flags=[R.]` and `nw_endpoint_flow_failed ...:8080` lines are **gone**
  (IPv6 connects instead of being refused).

**AP-path regression (IPv4-only link, ADR 06):**
- On `dancam-dev` AP: `curl -i http://10.42.0.1:8080/v1/health` -> `200`. The
  dual-stack `[::]` socket accepts the IPv4-mapped connection; AP behavior unchanged.

## Commits

Two logical commits, in this order (the repo's "one coherent change per commit"):

1. **`fix(raspi): key the Host allowlist to the bound port`** -- change 4 only
   (`lib.rs` `HostPolicy::new` + `AppState::with_service_port` + port test; `main.rs`
   `with_service_port(local_addr.port())` wiring). Self-contained correctness fix: it
   repairs the *existing* mock recipe's documented `curl 127.0.0.1:9000/v1/health`,
   independent of IPv6.
2. **`fix(raspi): bind the service dual-stack so dancam.local IPv6 resolves`** --
   changes 1, 2, 3, 5, 6, 7, 8 (`socket2` dep + `dual_stack_listener` + its test +
   `main.rs` socket adoption + systemd unit + Justfile + README + `raspi/AGENTS.md` +
   ADR 02 amendment).

Order matters: commit 1 must land first so that when commit 2 flips `raspi-mock-lan`
to `[::]:9000`, its loopback health check already passes (port-keyed) rather than
`421`-ing in the intermediate state. Both `main.rs` edits are small and non-overlapping
(commit 1 adds the `with_service_port` wiring; commit 2 replaces the bind construction).

## Commit progress

- [x] 1. fix(raspi): key the Host allowlist to the bound port
- [x] 2. fix(raspi): bind the service dual-stack so dancam.local IPv6 resolves
