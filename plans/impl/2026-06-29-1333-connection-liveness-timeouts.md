# Plan: connection-liveness timeouts (fix "stays Connected" hang)

## Context

A user walked ~1km from the Pi, opened the app, and the global connection strip
still read "Connected". Root cause, confirmed in source:

1. The app's global status is driven solely by whether `GET /v1/status` succeeds
   (`app/DanCam/DanCam/Features/Connection/ConnectionFeature.swift#fetchEffect`).
   There is no `NWPathMonitor`/reachability (deliberately rejected in ADR 04) -- the
   Pi answering `/v1/status` is the only liveness signal.
2. The transport is a hand-rolled `NWConnection`
   (`app/DanCam/DanCam/Networking/HTTP/NWByteStream.swift#start`). Live status polls
   are pinned to Wi-Fi with cellular prohibited. Off-network there is no satisfiable
   path, so `NWConnection` parks in `.waiting` -- which `start` ignores
   (`default: break`) -- and there is **no timeout anywhere**. The connect
   continuation never resumes, `status.fetch()` hangs forever, `.statusResponse`
   is never sent, `consecutiveFailures` never increments, and the strip never leaves
   its last value (`.connected`).
3. A second, rarer variant: if the Pi accepts the TCP connection (`.ready`) but then
   goes silent, `NWByteStream.receive` loops without an idle bound -- same hang,
   same stale "Connected".

Intended outcome: the global status must **never silently report "Connected" when it
is not**. Bound connection liveness so a dead or wedged link deterministically flips
the strip to "Not connected", while leaving the legitimately long-lived preview and
clip-pull *transfers* untouched.

Scope chosen by owner: **Complete (transport + monitor).**

## Approach (two complementary bounds at two altitudes)

### A. Connect-phase deadline in the transport (`NWByteStream`)

Bound only the time-to-`.ready` for every connection (all six clients route through
`NWByteStream.open`). A is the root-cause connect bound -- it removes the unbounded
`.waiting` hang at its origin -- and also fixes the same latent hang in the
preview/clip-pull connect path. It is *not* the only thing that fixes the reported
bug: B (below) is the testable, product-critical guarantee, and B alone already flips
the reported scenario (see Verification). A's unique value is bounding the *non-monitor*
connect paths (preview, clip-pull), which B does not cover.

- `app/DanCam/DanCam/Networking/HTTP/NWByteStream.swift`
  - Add `NWByteStreamError.connectTimedOut`.
  - Add a **required** `connectTimeout: Duration` parameter to `NWByteStream.open`
    and `NWByteStream.start` -- no transport-level default constant. The single source
    of the `2s` default is `AppConfiguration.defaultCameraAPIConnectTimeout` (below);
    every real caller is a `.live(...)` client that forwards the configured value, so
    a second transport-level literal would only be a "just in case" default that can
    silently drift out of sync. Omit it and require the argument (and avoid the reverse
    layering of having `NWByteStream` import `AppConfiguration`).
  - In `start`, define **one terminal-resume helper** that every terminal path calls
    -- `.ready`, `.failed`, `.cancelled`, and the deadline. It must, in order: guard
    `didResume == false` then set `didResume = true`; clear
    `connection.stateUpdateHandler = nil`; cancel the deadline `DispatchWorkItem`;
    then resume the continuation (with the outcome's error, or none for `.ready`).
    This matches the existing per-case cleanup (each current arm nils the handler
    before resuming) and guarantees the timeout path also nils the handler -- without
    it, a poll that times out off-network leaves the handler installed every cycle,
    retaining the connection/continuation. The deadline path additionally calls
    `lifecycle.cancel()` before resuming throwing `.connectTimedOut`.
  - Arm the deadline as a `DispatchWorkItem` via `queue.asyncAfter(...)` on the
    connection's existing serial `queue`. Because the connection's
    `stateUpdateHandler` and the work item both run on that one serial queue, a plain
    `var didResume` guard is race-free (no extra lock).
  - Leave `.waiting` in `default: break` -- the deadline is the policy; do not fail on
    the first transient `.waiting` (avoids false failures during a Wi-Fi blip). The
    existing `withTaskCancellationHandler { ... } onCancel: { lifecycle.cancel() }`
    stays, so `.stop`/cancel still tears the socket down.
  - Small `Duration` -> `DispatchTimeInterval` (milliseconds) conversion helper.

- Thread the timeout as configuration (mirror the `cameraAPIBaseURL` env pattern in
  `AppConfiguration`: an env key, a private validator that returns nil on bad input,
  and a default fallback):
  - `app/DanCam/DanCam/App/AppConfiguration.swift`: add
    `var cameraAPIConnectTimeout: Duration` with `defaultCameraAPIConnectTimeout =
    .seconds(2)` and env key `DANCAM_CONNECT_TIMEOUT_MS`. Parse via a
    `configuredDuration(fromMilliseconds:)` helper that accepts a positive integer
    string and falls back to the default on missing/empty/non-numeric/<= 0 input
    (same shape as `configuredURL(from:)`). Wire it into `live(environment:...)`.
  - Add a computed `var statusFetchTimeout: Duration { cameraAPIConnectTimeout +
    .seconds(1) }` on `AppConfiguration` -- the single source for the monitor bound,
    so the invariant "monitor timeout > connect deadline" holds for **any** override
    (the fixed-3s version broke it once `DANCAM_CONNECT_TIMEOUT_MS` exceeded 3s). The
    `+ .seconds(1)` is response slack (status response is tiny on a LAN).
  - `app/DanCam/DanCam/App/AppDependencies.swift#init(configuration:)`: pass
    `configuration.cameraAPIConnectTimeout` into each `.live(...)` client so the
    per-client `NWByteStream.open` thunk forwards it. The `.live(baseURL:pinning:)`
    factories (`StatusClient`, `HealthClient`, `ClipsClient`, `ClipPullClient`,
    `PreviewClient`, `RecordingClient`) gain a `connectTimeout` argument forwarded to
    the thunk. Pattern repeats once per client.

These compose with existing error funnels with no per-client logic change:
`connectTimedOut` -> `StatusClient.fetch`'s `catch` -> `StatusError.transport`;
-> `PreviewClient.produceFrames`'s `catch` -> `PreviewError.connectionFailed` ->
existing `PreviewFeature#scheduleReconnect` backoff; -> `ClipPullClient.runAttempt`'s
`catch` -> existing `.retry`.

### B. Whole-fetch timeout in the monitor (`ConnectionFeature.fetchEffect`)

Guarantee the one product-critical signal can never hang -- connect *or* post-connect
(wedged Pi) -- and give it a deterministic regression test. This is the piece unit
tests can drive (the transport layer in A is not unit-tested in this codebase).

- New injected seam, `app/DanCam/DanCam/App/AppDependencies.swift`:
  `var statusFetchTimeout: @Sendable () async throws -> Void`. It must be `throws` so
  cancellation propagates (see below). Wire it into **both** inits, with different
  defaults:
  - `init(configuration:)` (the `.live` path): default
    `{ try await Task.sleep(for: configuration.statusFetchTimeout) }` (derived =
    `cameraAPIConnectTimeout + 1s`, so it always exceeds the connect deadline and only
    bites a genuine post-connect stall, even under a `DANCAM_CONNECT_TIMEOUT_MS`
    override).
  - the manual `init(health:status:...)`: default to a **never-firing** closure
    `{ try await Task.sleep(for: .seconds(3600)) }`. This is load-bearing, not
    cosmetic. Eight test files build dependencies through this init (`AppFeatureTests`,
    `AppShellViewControllerTests`, `ClipsFeatureTests`, `RecordingFeatureTests`,
    `PreviewFeatureTests`, `ClipViewerViewControllerTests`, `HealthFeatureTests`,
    `ConnectionFeatureTests`), so omitting the default breaks their compilation -- and
    a default that fired instantly would be a *behavioral* break: `AppFeatureTests`
    drives a real `.connection(.start)` -> success seeding through `fetchWithTimeout`,
    so an instant timeout child would win the race and yield `.timedOut` instead of the
    seeded success. The never-firing default makes the fetch result always win,
    preserving today's behavior for every test that doesn't opt in.
- `ConnectionFeature.swift#fetchEffect`: replace the bare
  `try await dependencies.status.fetch()` with a private `fetchWithTimeout` that races
  the fetch against `statusFetchTimeout` using `withThrowingTaskGroup`, returning
  whichever finishes first and `cancelAll()` on the loser:
  - fetch child returns the response (or rethrows a real `StatusError`).
  - timeout child: `try await dependencies.statusFetchTimeout(); return .timedOut`.
    On normal expiry -> `.timedOut` -> throw `StatusError.timedOut`. On outer
    cancellation (`.stop`/`cancelInFlight`) the sleep throws `CancellationError`,
    which propagates and is swallowed by `fetchEffect`'s existing
    `catch is CancellationError { return }` -- so `.stop` never counts as a failure.
    (This is why the seam is `throws`, not `try?`: a swallowed cancel would otherwise
    be misreported as a timeout.)
  - On timeout, the fetch child is cancelled; `NWByteStream`'s `onCancel` tears down
    the socket.
- Add `StatusError.timedOut` to
  `app/DanCam/DanCam/Networking/StatusClient.swift#StatusError` (a named case, not a
  `.transport("...")` string, so the test asserts a symbol, not a literal). Update the
  exhaustive `StatusError.displayMessage` switch (and any other switch over
  `StatusError`).
- Keep the existing 3-strike fail-slow debounce (`failureThreshold = 3`) and 1500ms
  `pollInterval` unchanged -- ADR 04/05 deliberately chose fail-slow to avoid flapping
  on the congested 2.4 GHz link. Resulting detection latency off-network is
  ~`3 x (connectTimeout + pollInterval)` ~= 10s, which is acceptable for an ambient
  status strip and recorded in the ADR.

## ADR + docs

- New `app/docs/design/09-2026-06-29-connection-liveness-timeouts.md`, Status
  **Accepted**. One decision: "bound connection liveness with a transport connect
  deadline and a monitor whole-fetch timeout so the app never silently believes it is
  connected." Context = the bug above; Decision = A + B with starting values and the
  retained 3-strike debounce; Consequences = ~10s detection latency, all clients
  fail-fast on connect, preview/clip-pull feed existing backoff, one new injected
  dependency; Alternatives considered = `NWPathMonitor`/reachability (already rejected
  by ADR 04; restate), react to `.waiting` directly (rejected: transient, risks false
  failures), whole-request timeout in `HTTPRequestResponse.roundTrip` (rejected: needs
  a new injected clock to test, misses the decode phase, and the monitor level is the
  product-critical, testable altitude), URLSession `timeoutIntervalForRequest`
  (rejected: ADR 02 chose hand-rolled `NWConnection` for Wi-Fi interface pinning).
- This ADR **refines** ADR 02 (transport mechanics) and the monitor policy carried in
  the 04 -> 05 -> 06 chain; it **does not supersede** them (it reverses nothing:
  `/v1/status` stays the single source of truth, `NWPathMonitor` stays rejected, the
  3-strike debounce stays). Per the repo's established refinement-note practice, add a
  forward pointer to each refined-but-still-live ADR -- a pointer is not a rewrite and
  does not violate append-only. (Precedent: ADR 02 already carries inline
  `> **Note (date):**` pointers to ADRs 07 and 08, and ADR 07 carries one to ADR 08.)
  In the same change, add a brief note matching ADR 02's existing style -- e.g.
  `> **Note (2026-06-29):** refined by ADR 09 (connection-liveness timeouts) ...
  (tailored per target; the contract here is unchanged)` -- to:
  - **ADR 02** -- ADR 09 adds a connect deadline to its hand-rolled HTTP/1.1 client
    mechanics; the wire contract and pinning are unchanged.
  - **ADR 06** -- the live head of the monitor chain (it carries forward the fail-slow
    connection-truth decision); ADR 09 adds the monitor whole-fetch timeout and the new
    `StatusError.timedOut` case to that monitor.
  (No note on ADR 04/05: 05 is superseded by 06, and 06 is the live head a reader
  follows the chain to.)
- Repair the ADR index in `app/AGENTS.md#Design decisions (ADRs)`: the "Current:"
  list is already stale -- it stops at ADR 05, but `app/docs/design/` holds 06, 07,
  08 on disk. Bring it fully up to date through 09: correct ADR 05's note to
  "superseded by ADR 06", and add one-line entries for `06` (domain root store +
  scoped observation), `07` (on-device clip remux playback), `08` (progressive fMP4
  clip playback), and `09` (connection-liveness timeouts). Confirm exact slugs/status
  against the filenames in `app/docs/design/` when writing the lines.
- Run `just adr-check`.
- **No README change**: nothing here touches Pi provisioning or onboard state.

## Tests (Swift Testing + `TestStore`, matching `ConnectionFeatureTests`)

- New `ConnectionFeature` test "hung fetch flips to disconnected": inject a
  **cancellation-aware** hung `status.fetch` -- signal start via `AsyncSignal` then
  `try await Task.sleep(for: .seconds(3600))` (matching the existing
  `stopCancelsPollAndSendsNoFurtherActions` model) -- plus an instantly-returning
  `statusFetchTimeout: { }`. Drive `.poll` ->
  `receive(.statusResponse(.failure(.timedOut)))` three times; assert
  `connectivity == .disconnected` on the third. This is the structure-insensitive
  behavioral claim: *a fetch that never returns deterministically flips the global
  status to "Not connected" within the threshold.*
  - **Do not block the fetch on `AsyncSignal.wait()`**: it is a non-throwing
    `withCheckedContinuation` (see `AsyncStreamHelpers.swift#AsyncSignal`), so it does
    not observe cancellation. `fetchWithTimeout` relies on `status.fetch` honoring
    cancellation -- when the timeout child wins, `withThrowingTaskGroup` cancels the
    fetch child and *awaits* it, so a non-cancellable fetch would hang both the test
    and the live effect. `Task.sleep` throws on cancellation and unblocks cleanly;
    in production `NWByteStream` honors cancellation via its `onCancel` teardown.
- Add a `.stop`-cancels-the-timeout case. The naive
  `.stop -> finishEffects() -> expectNoReceivedActions()` shape is **not enough**
  here: `TestStore.cancelTask` (`TestStore.swift#cancelTask`) removes the effect task
  from `tasks` *before* `.cancel()`, so `finishEffects()` never awaits it -- a stuck
  child would be orphaned and the test would pass anyway. Instead, **instrument both
  mock children to acknowledge cancellation** and await those acks:
  - The `status.fetch` and `statusFetchTimeout` mocks each wrap their
    `try await Task.sleep(...)` so that on cancellation they record an ack (e.g.
    signal a per-child `AsyncSignal`, or set an actor flag, via a
    `catch { ack.signal(); throw }` or `withTaskCancellationHandler`).
  - Sequence: `.send(.start)` -> await both children started -> `.send(.stop)` ->
    **await both cancellation acks** (this is what actually proves both children
    unwound; a non-cancellation-aware child would hang the test here) ->
    `expectNoReceivedActions()` (proves `.stop` emitted no spurious
    `.statusResponse(.failure(.timedOut))`).
  - Behavioral claim: *on `.stop`, the in-flight status fetch and its timeout both
    unwind promptly and the effect emits nothing.*
- The manual-init never-firing default (in Approach B) already keeps the existing
  success/failure tests unaffected (the fetch result always wins; the timeout child is
  cancelled when the group returns), so no blanket change to
  `ConnectionFeatureTests.dependencies(queue:sleep:)` is required. That helper only
  needs an optional `statusFetchTimeout` parameter for the two new tests that drive it
  explicitly -- the hung-fetch test (instant `{ }`) and the `.stop` test (the
  instrumented, cancellation-acking closure) -- defaulting to the same never-firing
  closure so every other caller is untouched.
- `AppConfigurationTests` (the suite injects `environment:`/`infoDictionary:` into
  `AppConfiguration.live`): cover `cameraAPIConnectTimeout` and the derived
  `statusFetchTimeout` for three cases -- default (no env -> `2s` / `3s`), valid
  override (`DANCAM_CONNECT_TIMEOUT_MS=5000` -> `5s` / `6s`, proving the monitor bound
  scales and never clips a legal connect), and invalid fallback (e.g. `"abc"`, `"0"`,
  or negative -> default `2s` / `3s`).
- The connect deadline (A) has no unit test -- consistent with `NWByteStream` having
  no unit tests (always swapped via the `openByteStream` seam). It is covered by the
  manual/integration preview check below. An *automated* connect-deadline test would
  need a non-accepting local listener plus a real-`NWByteStream` seam; note an
  "accepts-then-stalls" listener would instead exercise the deferred receive-idle path
  (Out of scope), not the connect deadline. Both stay deferred along with the rest of
  the `NWByteStream` test harness rather than introducing a one-off integration rig now.

## Verification

- `just app-build` and `just app-test` (DanCamTests) green; new tests pass, existing
  `ConnectionFeatureTests` still pass.
- `just adr-check` passes (validates the new ADR filename/sequence).
- Manual/integration, **status strip (exercises B, the monitor)**: launch the app
  pointed at a non-routable host, e.g. `DANCAM_CAMERA_API_BASE_URL=http://10.255.255.1:8080`
  (the scheme override documented in `app/AGENTS.md#Build / run`), and confirm the
  status strip goes Connecting -> Not connected within ~10s instead of hanging.
  Repeat the original repro: connect to the Pi, then disable Wi-Fi, confirm the strip
  flips. Note this check alone does **not** prove the transport deadline (A): the
  monitor's own whole-fetch timeout would flip the strip even if A were broken.
- Manual/integration, **preview (exercises A in isolation)**: with the same
  non-routable host, open the live-preview screen. Preview has no monitor timeout and
  calls `NWByteStream.open` directly (`PreviewClient.swift#produceFrames`), so this
  isolates the connect deadline. Confirm the connect attempt fails within ~the connect
  deadline (`~2s`) into `PreviewError.connectionFailed` ->
  `PreviewFeature#scheduleReconnect` backoff (UI shows reconnecting, not a hung
  spinner) -- proving the shared `NWByteStream` change works for the non-monitor
  clients. (A is not unit-tested, consistent with `NWByteStream` having no unit
  tests; this manual check is its coverage.)

## Out of scope / deferred

- Tuning `failureThreshold`/`pollInterval` for faster detection (ADR 04 fail-slow
  decision stands; revisit separately if 10s feels too slow).
- A shared/general timeout utility: keep `fetchWithTimeout` private to
  `ConnectionFeature` until a second caller needs it.
- **Preview / clip-pull receive-idle (post-connect silence, Context variant 3).**
  Bounds A and B together close variant 3 only for the *monitor's* status fetch (via
  B's whole-fetch timeout). The preview and clip-pull receive loops
  (`PreviewClient#produceFrames`, `ClipPullClient#runAttempt`) `for try await chunk in
  byteStream` with no idle bound, so a TCP-alive-but-silent Pi can still freeze a
  preview or hang a pull indefinitely. This is a conscious deferral, not the reported
  bug: the intended outcome here is global *status* truth (which B fully delivers, and
  which is what drives the strip), and these are the "legitimately long-lived
  transfers" the Context says to leave untouched -- a naive receive-idle deadline risks
  false-killing a slow-but-alive 2.4 GHz transfer, so bounding them deserves its own
  decision (a rearmed-per-chunk idle timer in `NWByteStream.receive`, tuned for the
  link) rather than a rushed add here. Revisit if a silent-Pi preview/pull freeze is
  observed in practice.

## Implementation notes

- `NWByteStream.start` uses a small queue-affine `NWConnectionStartResolution` helper
  because Swift 6 rejects mutable locals captured by `NWConnection`'s sendable state
  callbacks. The helper preserves the plan's serial connection-queue race model:
  `setDeadline` runs before start, and every terminal `finish` call runs on the
  connection queue.
- The hung-fetch regression test makes the timeout closure wait for the mock fetch's
  start signal before returning. That keeps the test deterministic while preserving
  the intended behavior: the fetch body itself never waits on the non-cancellable
  `AsyncSignal` and still unwinds through cancellable `Task.sleep`.
