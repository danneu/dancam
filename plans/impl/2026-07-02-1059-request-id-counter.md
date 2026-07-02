# Plan: Pi request-id as a per-process incrementing integer

## Context

The Pi service (`raspi/service/`) stamps every HTTP request/response with an
`x-request-id` for app/Pi log correlation (ADR 13). When the client does not supply a
safe inbound id, the service generates a **UUID v4** -- e.g.
`3f1c0e7a-8f3b-4e15-b196-20e0416af749` (36 chars) -- on every access line. That is
visually noisy in `journalctl -u dancam` output.

We are switching the Pi-generated fallback to a **plain incrementing integer** that
resets on each service start: `1`, `2`, `3`, .... This makes access lines far shorter,
and the counter dropping back to `1` becomes a visible **service-start marker** when
reading the journal in time order.

Accepted trade-off (chosen deliberately): the id is unique only **within a single
service invocation**, which is narrower than a boot. `Restart=on-failure` /
`RestartSec=2` (see `raspi/dancam.service`), a `deploy.sh` `systemctl restart dancam`,
or a manual restart all reset the counter *without* a reboot, so one `_BOOT_ID` can
contain many `x-request-id: 1`s. A blind grep of a captured id (e.g. `x-request-id: 42`)
across a persistent journal can therefore return several hits. Disambiguate by time
proximity plus the neighboring reset marker, or scope to one service run with journald's
per-invocation `_SYSTEMD_INVOCATION_ID`
(`journalctl _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value dancam)`).
Note `journalctl -b` narrows to a boot but *not* to a single run within it, and the
`x-dancam-boot-id` response header likewise does not distinguish restarts within a boot.

Scope note: only the **Pi-generated fallback** changes. Client-supplied safe
`x-request-id` values are still honored and echoed unchanged (`is_safe_request_id`
already accepts digits, so no validation change). The `uuid` crate stays a dependency --
`resolve_boot_id()` still uses it as a non-Linux fallback.

## Changes

### 1. Counter on `AppState` -- `raspi/service/src/lib.rs`

- **Imports:** add `atomic::{AtomicU64, Ordering}` to the existing `std::sync` group.
- **`AppState` struct (`lib.rs#struct AppState`):** add field
  `request_seq: Arc<AtomicU64>`. Behind `Arc` so `AppState`'s `#[derive(Clone)]` /
  router clones share one counter.
- **`AppState::new` (`lib.rs#impl AppState`):** initialize
  `request_seq: Arc::new(AtomicU64::new(1))`. `fetch_add` returns the pre-add value, so
  the first request is `1`. One `AppState` is built per process (`main.rs`), so the
  counter resets on each service start -- reboot, deploy, or `systemctl restart`.

### 2. Middleware uses the counter -- `raspi/service/src/lib.rs`

- **`request_trace` (`lib.rs#async fn request_trace`):** switch to a state-carrying
  middleware. Add `State(state): State<AppState>` as the first parameter (extractors
  precede `Request`/`Next` in axum). Replace the fallback
  `.unwrap_or_else(|| uuid::Uuid::new_v4().to_string())` with
  `.unwrap_or_else(|| state.request_seq.fetch_add(1, Ordering::Relaxed).to_string())`.
  `Relaxed` is sufficient -- we need a unique, roughly monotonic sequence, not
  cross-thread memory ordering. Everything else (span fields, header echo) is unchanged.
- **Router wiring (`lib.rs#fn app`):** change
  `.layer(middleware::from_fn(request_trace))` to
  `.layer(middleware::from_fn_with_state(state.clone(), request_trace))`. Keep it as the
  last `.layer(...)` before `.with_state(state)` so it stays the **outermost** layer
  (ADR 13 requires 404s and host-allowlist 421s to get the access log + header).

### 3. Tests -- `raspi/service/tests/request_id.rs`

- Tighten `assert_generated_request_id`: a generated id is now all ASCII digits -- add
  `assert!(request_id.bytes().all(|b| b.is_ascii_digit()))` (keep the existing
  non-empty / <=128 / safe-chars checks).
- Add a determinism test: build one router from a fresh `state()`, issue two requests
  via `app.clone().oneshot(...)` (`Router` is `Clone`; the shared `Arc<AtomicU64>` means
  clones advance the same counter), and assert the generated ids are `"1"` then `"2"`.
- Unchanged and still valid: `echoes_valid_inbound_request_id` (inbound honored),
  `rejects_unsafe_inbound_request_id`, `unknown_path_still_carries_request_id`,
  `host_rejection_still_carries_request_id`.

### 4. New ADR -- `raspi/docs/design/14-2026-07-02-request-id-format.md`

The id format is a sub-decision of the bundled ADR 13; per the append-only convention
(and one-decision-per-file), record the change as a new ADR that supersedes **only the
request-id-format part** of ADR 13 (ADR 13's middleware / `/v1/logs` deferral /
`RUST_LOG` decisions still hold). Standard shape (Title / Status: Accepted / Context /
Decision / Consequences / Alternatives considered):

- **Decision:** Pi-generated fallback is a **per-process** `AtomicU64` counter
  (`AppState.request_seq`, init 1, `fetch_add(1, Relaxed)`), echoed in the
  `x-request-id` header and the tracing span; inbound safe ids still honored.
- **Consequences:** shorter access lines; the reset to `1` is a visible **service-start**
  marker in time-ordered reads (fires on reboot *and* on `Restart=on-failure`, deploy, or
  `systemctl restart` -- see `raspi/dancam.service`); a captured id is unique only within
  one service invocation, so a blind cross-run grep can collide. Disambiguate by time
  proximity + the reset marker, or by journald's per-invocation `_SYSTEMD_INVOCATION_ID`;
  `journalctl -b` and the `x-dancam-boot-id` header do **not** separate restarts within a
  boot.
- **Alternatives considered:** keep UUID (noisy, 36 chars); short random token (short +
  low collision risk but no ordering, still stateless); boot- or invocation-prefixed
  counter e.g. `af49-42` (unique across runs but longer). Rejected in favor of the
  shortest, most readable option, accepting per-run-only uniqueness.

**ADR 13 append-only edit:** at ADR 13's generated-UUID references (the `or generates a
UUID` Decision bullet, and the `replaced with a generated UUID` rationale), add an inline
note -- e.g. `Superseded (request-id format) by 14-2026-07-02-request-id-format.md; the
generated fallback is now a per-process counter` -- without deleting the original text.
Leave ADR 13's Status as `Accepted` (only the id-format sub-decision changed).

### 5. Doc touch-ups (describe current behavior)

- **`README.md`** section 7 (search `Request/response access lines appear`): note that
  Pi-generated ids are a per-process counter that resets on each service start, and that
  a blind grep of a captured id is scoped to one run with journald's
  `_SYSTEMD_INVOCATION_ID` (not `journalctl -b`, which only narrows to a boot).
- **`raspi/AGENTS.md`**:
  - (search `x-request-id` for app/Pi correlation) one-line clarification that the
    Pi-generated id is a per-process incrementing counter (resets on service start).
  - add `14-2026-07-02-request-id-format.md` to the `## Design decisions (ADRs)`
    "Current:" index (the list currently ends at ADR 13), with a one-line summary.
- **Do not touch** `raspi/docs/design/02-...` UUID mentions -- those are the incident
  `idempotency_key`, unrelated to request-id.

## Verification

- `just raspi-test` -- all `tests/request_id.rs` cases pass, including the new
  first-request-is-`1`, second-is-`2` determinism test.
- `just raspi-check` -- `cargo fmt --check` + `clippy -D warnings` clean (confirms the
  new imports/fields are used and formatted).
- `just adr-check` -- validates ADR 14's `{seq}-YYYY-MM-DD-{slug}` filename/sequence.
- Manual smoke (`just raspi-mock`, then in another shell
  `curl -sD - localhost:8080/v1/health -o /dev/null | grep -i x-request-id`): first call
  returns `x-request-id: 1`, second `2`, ...; supplying `-H 'x-request-id: corr-9'`
  echoes `corr-9` unchanged; restarting `raspi-mock` resets the next id to `1` (the
  service-start marker).

## Commit

Single logical change, e.g. `feat(raspi): shorten request ids to a per-process counter`
(code + tests + ADR 14 + ADR 13 append-only note + README + AGENTS.md together, per the
"pivot that isn't written down is the next trap" rule).
