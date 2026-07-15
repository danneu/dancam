# Plan: make Pi operational status and GC outcomes self-diagnosing

## Context

The first real-Pi validation of ring GC on 2026-07-11 succeeded: with a temporary
floor 8 MiB below available `/data` space, recording pressure caused IDs 0 and 1
to be evicted oldest-first in separate passes, the active segment survived, and
ordered `clip_removed` SSE events were emitted. The validation also exposed three
operational blind spots:

1. `raspi/deploy.sh` declares the service ready as soon as `/v1/health` answers.
   On the deployed Pi that happened about two seconds before the Picamera2 owner
   reached `camera_state=running`, so an immediate recording start returned 503.
2. The 503 log carried request id, path, status, and latency but not the rejection
   reason. `CameraBackend::start_recording` maps every non-running camera state to
   `BackendError::CameraOffline`, so `starting`, `restarting`, and genuinely
   `offline` are indistinguishable even in the response body.
3. `gc.rs#log_outcome` reports only `deleted=<count>`. Proving which IDs were
   deleted, whether space crossed the configured floor, and why backoff armed
   required correlating journal output, SSE, `df`, and `state.json` by hand.

The API does not need separate liveness and readiness routes. A valid successful
`GET /v1/status` response already proves the HTTP service is responding, and the
canonical snapshot is the right place to describe whether recording can start.
Remove `/v1/health`, keep `/v1/status` available during camera or storage failure,
and add top-level `recording_readiness` to the same snapshot shared by status and
the first `/v1/events` frame. Operational tools can then use one body for both
reachability and recording capability without creating another source of truth.

That endpoint cannot safely inherit the current unbounded filesystem behavior.
Snapshot construction awaits segment-duration enrichment, telemetry calls
`statvfs` synchronously, and the readiness witness adds more metadata calls on
the recording filesystem. A stalled `/data` must neither hang the sole status
endpoint nor leave a last-known-good `ready:true` visible. This plan therefore
puts status-critical filesystem observation behind one bounded, single-flight
path and treats timeout as unavailable evidence, not as permission to reuse a
healthy observation.

Planning the command-error taxonomy surfaced real command-ownership bugs. That
redesign landed through
`plans/impl/2026-07-14-2008-single-owner-camera-command-lifecycle.md` and raspi
ADR 23 (`raspi/docs/design/23-2026-07-14-single-owner-camera-command-lifecycle.md`),
satisfying the prerequisite for this plan's command-error commit.

No provisioning change is needed. The snapshot, error mapping, tracing fields,
and deploy behavior ship in the service, shared contract, app model, scripts, and
deploy artifacts already owned by the repo.

## Decisions

1. **`GET /v1/status` is the sole operational probe.** Remove `/v1/health` and
   do not introduce `/v1/live`, `/v1/ready`, `/v1/ping`, or another probe route.
   `/v1/status` returns 200 whenever the service can produce its canonical
   snapshot, including while the camera is starting, restarting, or offline,
   while recording storage is unavailable, and when its bounded filesystem
   observation times out. Those conditions are facts in the response body, not
   failures of the status request. A successful valid response itself proves HTTP
   reachability; do not add a redundant `http_server` field.
   This changes only the proposed operational probes. `/v1/events`, recording
   commands, preview, clip, and time endpoints remain.
2. **Recording readiness is a top-level canonical snapshot capability.** Add
   `recording_readiness` alongside `recorder`, `camera_state`, and `storage`:

   ```json
   {
     "recording_readiness": {
       "ready": false,
       "reason": "camera_starting"
     }
   }
   ```

   Ready serializes as `{ "ready": true, "reason": null }`. The complete
   non-null reason taxonomy is `camera_starting`, `camera_restarting`,
   `camera_offline`, and `recording_storage_unavailable`. Deterministic precedence
   is camera state first, then storage availability. `RecorderPhase::Error` is
   not a readiness reason because raspi ADR 23 deliberately permits a retry from
   recorder error. Readiness means the camera is running and the configured
   required recording mountpoint passes the same authoritative mount witness used
   by recording mutations. With no required mount configured, the storage
   predicate succeeds. Readiness is not nested under `recorder`: recorder state is
   lifecycle, while readiness is a derived capability spanning camera and storage.
   Time synchronization is not a predicate because recording is deliberately
   allowed before phone time sync.
3. **Status and events retain one source of truth.** Extend the shared Rust
   `Snapshot`; do not enrich only the status handler. `/v1/status` serializes that
   `Snapshot`, while the first SSE frame serializes the same value with only the
   event discriminator added. The root `contract/events` corpus remains the
   canonical wire boundary for both Rust and Swift.

   Keep readiness current through the existing world/event/telemetry flow, with
   one bounded filesystem boundary:

   - Add a read-only `StorageCoordinator` check that delegates to the exact
     required-mount witness used by mutations. Introduce an injectable
     `FilesystemObserver` in `AppState` that runs this witness, recording-disk
     usage, and optional current-segment resolution/duration behind one
     `spawn_blocking` lane with a single permit and a fixed internal one-second
     end-to-end deadline covering both permit acquisition and probe completion,
     shorter than the two-second telemetry cadence. This is an internal safety
     bound, not another deploy timeout setting.
   - The blocking closure owns the permit until it actually exits. Timing out an
     await does not release the lane or launch a replacement: subsequent startup,
     telemetry, status, or initial-SSE callers time out acquiring the same permit
     and cannot accumulate detached stuck blocking tasks. Probe results are
     applied only by a caller that completed within the deadline, so a late result
     from a timed-out closure cannot resurrect stale readiness.
   - Seed the observation through this boundary before the HTTP server begins
     serving. A successful witness seeds its boolean result; timeout or probe
     failure seeds unavailable and startup continues so status remains reachable.
     Do not wait for the first periodic telemetry tick and do not compute a
     one-off handler-only value.
   - Move recording-filesystem work off the async telemetry task. Re-run the
     bounded witness plus disk-usage observation on the existing two-second
     cadence so an external mount loss or recovery updates the world without a
     service restart. Timeout or probe failure publishes storage unavailable and
     readiness fails closed; it never retains the previous healthy witness.
     Camera lifecycle inputs recompute readiness immediately.
   - Build both `/v1/status` and the first `/v1/events` snapshot through one shared
     canonical-snapshot materialization path. It asks the same observer for a
     fresh storage witness/disk observation plus best-effort duration for the
     preliminarily sampled current segment, applies the storage observation
     through `World`, and only then acquires the final snapshot. The SSE variant
     performs its existing atomic snapshot-plus-subscription connection after
     that application, so an observation event is represented either in the
     first snapshot or as a later delta, never lost in between. If the observer
     or permit acquisition times out, it applies unavailable storage and a failed
     required-mount witness, then returns within the bound with current-segment
     `dur_ms:null`. If no required mount is configured, preserve Decision 2's
     successful readiness predicate even though disk usage and duration remain
     unavailable. If the recorder rolled to a different segment during
     observation, discard the mismatched duration as null. Thus request polling
     on the deployed required-mount configuration cannot report an earlier
     `ready:true` after the filesystem path has stalled, and neither status nor
     initial SSE can hang on duration enrichment.
   - Make the affected deltas atomic for clients: `camera_state_changed` carries
     both the new camera state and the corresponding full readiness replacement;
     `storage_changed` carries both the storage value and readiness replacement,
     and is emitted when either quantized storage or the derived readiness value
     changes. A mount observation masked by a higher-precedence camera reason is
     still retained in `World` but emits no redundant identical wire event; the
     next camera transition derives from the updated observation. Thus a fold
     never observes a new camera/storage fact paired with stale readiness.

   Add the readiness value to the Rust fixtures, root corpus snapshot plus the
   `camera_state_changed` and `storage_changed` bodies, the Swift `World` and event
   payload models, `CameraSamples`, decoders, and folding logic. This is a required
   contract field; no compatibility default or shim is needed.
4. **Command errors describe terminal command outcomes, not readiness.** Replace
   the single `CameraOffline` bucket with stable command-result codes: a sampled
   non-running `CameraState` maps to `camera_starting`, `camera_restarting`, or
   `camera_offline`; a `RecorderPhase::Error` observed after dispatch while the
   camera remains running maps to `recorder_failed`. Exhaustively map
   `TerminalFailure`: `Timeout` maps to `camera_command_timeout`; `Write`,
   `ChildError(String)`, `Exited`, and `Shutdown` map to
   `camera_command_channel` because in each case the command conversation ended
   without confirmation. Preserve `ChildError`'s child-provided detail in the
   envelope's human `message`. Command-queue/ack closure and child stdin flush
   failure also map to `camera_command_channel`; allocation/mount failure maps to
   `recording_storage_unavailable`. The overlapping camera/storage spellings are
   deliberate facts at two different boundaries: readiness says why a command
   should not be attempted now, while a command error says why an attempted
   operation failed. `recorder_failed`, `camera_command_channel`, and
   `camera_command_timeout` never become readiness reasons.
5. **Recording-command errors use one typed envelope.** Backend command failures
   return `{ "error": "<stable_code>", "message": "<human text>" }` with
   `application/json`. This plan does not reshape unrelated mutation-header or
   clip errors. Camera lifecycle, `recorder_failed`, and
   `recording_storage_unavailable` return 503; `camera_command_channel` returns
   500; `camera_command_timeout` returns 504. Only `camera_starting` and
   `camera_restarting` include `Retry-After: 1`. The recording handler logs the
   stable code, command, and sampled camera state inside the request-correlated
   span. Expected startup/restart rejection is `warn`; channel, storage, and
   unexpected offline failures retain appropriately loud logging.
6. **GC logs are derived from `GcPass`, never diagnostic re-probes.** Extend
   logging outcomes with one observation containing `floor_bytes: u64`,
   `avail_before: Option<u64>`, `avail_after: Option<u64>`, and the existing
   bounded deleted-ID vector. `Failed` also retains its `io::Error`.
   Availability remains optional because initial probe failure and blocking-task
   failure have no observation to report. Construct every field from values
   already used by `run_gc_pass`; never issue another `statvfs` call for logging.
7. **Healthy GC polling stays silent.** `AboveFloor` remains a silent unit
   outcome. Log eviction progress, exhaustion, probe failure, pass failure, and
   entry into backoff. Progress logs include `outcome`, `deleted_count`,
   `deleted_ids`, `avail_before`, `avail_after`, and `floor_bytes`; backoff logs
   also include `retry_after_s=30`. The ID list is bounded by
   `MAX_EVICTIONS_PER_BATCH`.
8. **Deploy uses two logical phases over one status body.** All shell consumers
   parse status with `python3 -c` and the standard-library `json` module; do not
   add `jq`, grep JSON text, or change provisioning. Phase 1 polls `/v1/status`
   until it receives a 200 body that parses as JSON and contains
   `recording_readiness.ready` as a JSON boolean. This is the shell validation
   boundary, not full canonical-snapshot schema validation. Phase 2 continues
   polling the same endpoint until that boolean is true. Reset-data and HDR use
   the identical parser and boolean requirement for their readiness waits. The
   parser must distinguish malformed/missing/non-boolean input, valid
   `ready:false`, and valid `ready:true` without shell evaluation of body content.
   The response that establishes phase 1 is also evaluated for phase 2, so one
   response may satisfy both immediately.
   Use independent bounds named `DANCAM_STATUS_TIMEOUT` and
   `DANCAM_RECORDING_READINESS_TIMEOUT`; the latter defaults to the former.
   Remove the unshipped `DANCAM_HEALTH_TIMEOUT`, `DANCAM_LIVE_TIMEOUT`, and
   `DANCAM_READY_TIMEOUT` names without aliases.

   Retain the last full valid status body throughout phase 2. On readiness
   timeout, print it and gather bounded best-effort service environment,
   `/data` mount, disk-space, and last-50-unit-log diagnostics. Do not make a
   redundant diagnostic status request: the retained canonical body is the
   evidence that selected the timeout. Every poll and diagnostic SSH operation
   has its own execution bound beneath the phase deadline, including an absolute
   local watchdog that terminates and reaps a connected but stalled remote
   command. Diagnostic failure cannot hide or indefinitely delay the primary
   timeout. Successful deploy notification means recording-ready.

## Verified code anchors

- `raspi/service/src/lib.rs#fn app` currently routes both `/v1/health` and
  `/v1/status`. `raspi/service/src/health.rs#fn health` owns the redundant health
  payload. `raspi/service/src/events.rs#fn status` already returns `Json<Snapshot>`
  without a readiness-dependent status code, and `#fn events` uses the same
  `Snapshot` for the stream's first event.
- `raspi/service/src/events.rs#Snapshot`, `raspi/service/src/world.rs#World`, and
  `raspi/service/src/event_hub.rs#EventHub` are the canonical state path.
  `CameraState` changes already enter `World` immediately. The telemetry loop
  already samples storage every two seconds and emits complete replacement
  `storage_changed` events.
- `raspi/service/src/events.rs#fn enrich_current_segment` currently awaits an
  unbounded `spawn_blocking` segment resolution/duration task for both status and
  initial SSE. `#fn spawn_telemetry` calls `sysfacts::disk_usage` synchronously on
  its async task. These are the filesystem paths the shared bounded observer must
  replace; merely wrapping each await in an independent timeout would still
  accumulate uncancelled blocking tasks after `/data` stalls.
- `raspi/service/src/storage.rs#StorageCoordinator` retains the optional required
  mountpoint, while `#fn ensure_required_mountpoint` is the authoritative witness
  used by recording mutations. The coordinator currently exposes no public
  read-only availability result over that witness.
- `contract/events/README.md#Event Rules` states that every SSE connection begins
  with a snapshot and `/v1/status` is its one-shot form. Rust
  `events.rs#fn events_match_the_golden_corpus` serializes and decodes the root
  fixtures. Swift
  `CameraEventCorpusTests#goldenCorpusDecodesWithoutUnknownEvents` decodes them;
  its representative-variant test asserts selected values but does not encode or
  round-trip `CameraEvent`.
- `app/DanCam/DanCam/Networking/Events/CameraEvent.swift#World` is the app's
  canonical folded model. Its `cameraStateChanged` and `storageChanged` cases
  currently replace only their direct fields, so both payloads and folds must
  take the matching readiness replacement.
- `raspi/service/src/camera/mod.rs#CameraBackend::start_recording` and
  `#stop_recording` collapse non-running lifecycle states to
  `BackendError::CameraOffline`. `#enum TerminalFailure` has exactly `Timeout`,
  `Write`, `ChildError(String)`, `Exited`, and `Shutdown`; today `ChildError`
  still becomes `CameraOffline`, while `Shutdown` becomes `Channel`.
  `TerminalFailure::Exited`'s behavioral recovery path is already pinned by
  `raspi/service/tests/camera_process.rs#child_exit_during_command_reconciles_before_ack_and_retry_recovers`.
- `raspi/service/src/backend.rs#BackendError` owns HTTP status/message mapping.
  Raspi ADR 23 owns the terminalize-before-ack semantics that make timeout and
  channel codes truthful.
- `raspi/service/src/gc.rs#run_gc_pass` already receives every availability value
  used for a decision and stores deleted IDs in `GcPass`; `#fn log_outcome`
  currently discards those details except for the count and combines
  `ReachedFloor` and `BatchCapped` in one log arm.
- Operational consumers to migrate atomically with health removal are:
  `raspi/deploy.sh`; Justfile `raspi-reset-data`; Justfile `raspi-ap`;
  `raspi/scripts/hdr-set.sh`; their hardware-free harnesses; generic service-test
  request fixtures; `raspi/README.md`; `raspi/AGENTS.md`; and present-tense
  `docs/roadmap.md` guidance. The app has no health-route consumer; app connection
  liveness remains SSE heartbeat presence.
- Current documentation records that need forward reconciliation are raspi ADR 02
  (the historical transport table), raspi ADR 06 (the AP reachability probe), and
  app ADR 23 (the claim that Pi operations retain `/v1/health`). Completed
  `pine`/`jet` roadmap prose, archived `plans/impl/*`, dated ADR validation logs,
  and unrelated WIP plans are point-in-time or pre-implementation material and
  remain intact, with forward notes added only to the active records named above.
- `raspi/service/tests/recording.rs#recording_start_and_stop_update_health_recording_flag`
  is not a generic GET fixture: it verifies command state through the old health
  payload and must move to `/v1/status`, asserting recorder phase after both start
  and stop.

## Commits

Order: **1 (reset-data extraction) -> 2 (bounded filesystem observation) -> 3
(canonical operational status) -> 4 (typed command errors) -> 5 (GC diagnostics)
-> 6 (two-phase deploy)**. Each commit leaves its affected build and tests green.
Commit 4's ownership prerequisite is already satisfied by raspi ADR 23 and its
implemented plan.

### Commit 1 -- `chore(raspi): extract raspi-reset-data remote body into a testable script`

Pure extraction, behavior unchanged for this commit: the script still polls the
existing `/v1/health` under `DANCAM_HEALTH_TIMEOUT`. Commit 3 performs the clean
status/readiness migration after the safety-critical shell behavior is visible to
a harness.

- Extract Justfile `raspi-reset-data`'s remote destructive-and-reload body into a
  standalone Pi-side script, paralleling `hdr-set.sh` and preserving the
  fail-closed mount guard plus run-on-every-exit-path restart.
- Add `raspi/scripts/reset-data-test.sh` using the existing temporary-PATH and
  stubbed-command harness pattern, plus `just raspi-reset-data-test`.

Behavioral tests:

- A successful wipe records and asserts the complete order: mount witness -> stop
  dancam -> delete recording contents -> restart dancam -> endpoint poll. It
  rejects deletion while the service is still running and polling before restart.
  Commit 3 changes the final operation to the `/v1/status` recording-readiness
  poll and preserves the same ordering assertion.
- Every mount-witness failure (`/data` absent, non-directory, same-device plain
  directory, or `stat` failure) aborts before stop or delete.
- Delete failure and signal interruption still run cleanup, restart dancam, retain
  the original nonzero exit status, and never report success.
- The post-restart wait is bounded, tolerates transient failures, announces
  success only when its predicate passes, and fails loudly on timeout.

Verification: `just raspi-reset-data-test`.

### Commit 2 -- `fix(raspi): bound operational filesystem observation`

Introduce the concurrency boundary without changing any route or wire-contract
shape. `/v1/health` still exists, and snapshots contain the same fields as before
this commit.

- Add the injectable, one-permit `FilesystemObserver` to `AppState` with the
  fixed one-second end-to-end deadline from Decision 3. The spawned blocking
  closure retains its permit until it actually exits, timed-out results are never
  applied late, and callers cannot launch a replacement while a stuck closure
  owns the lane.
- Move `disk_usage` off the async telemetry task and route it through the
  observer. A timeout updates the existing `storage` field to null rather than
  retaining its last successful value; the next bounded successful cadence
  restores it.
- Replace `events.rs#fn enrich_current_segment` with shared bounded status/initial
  SSE snapshot materialization through the observer. Preserve the current atomic
  SSE snapshot-plus-subscription ordering. Timeout returns the existing snapshot
  shape with current-segment `dur_ms:null`; a duration sampled for a segment that
  rolled before the final snapshot is discarded.
- Keep the observer capable of accepting an additional read-only mount-witness
  observation in Commit 3, but do not add readiness state, startup seeding, root
  corpus changes, Swift changes, route removal, or consumer migration here.

Behavioral tests:

- Status and the first SSE snapshot preserve their existing successful duration
  behavior when the injected probe completes.
- An injected probe that stalls proves status, initial SSE, and telemetry return
  or advance within the single one-second end-to-end bound. Snapshot duration and
  storage become null instead of hanging or retaining stale values.
- Repeated and concurrent requests while that probe remains stuck do not increase
  the entered blocking-probe count beyond one. Releasing the old closure cannot
  apply its timed-out result; only a subsequent bounded successful observation
  restores disk usage or duration.
- The JSON shape returned by `/v1/status` and the first `/v1/events` snapshot is
  unchanged, and existing status, event, request, and corpus tests remain green.

Verification: `just raspi-test` and `just raspi-build`.

### Commit 3 -- `feat: make recording readiness part of canonical status`

- Add accepted raspi ADR
  `24-2026-07-15-operational-status-and-recording-readiness.md`, recording
  `/v1/status` as the sole operational probe, top-level recording readiness and
  its reason precedence, the shared status/events world derivation, the bounded
  single-flight filesystem observation rule delivered by Commit 2, and the stable
  command-code boundary. Relate it to raspi ADRs 02, 10, and 23 rather than
  rewriting their original decisions.
- Delete the health route, handler/module, and response type. Keep
  `events.rs#fn status` unconditional: it returns 200 with the canonical snapshot
  whenever serialization succeeds, regardless of readiness.
- Add `RecordingReadiness` and its closed reason enum to the shared snapshot and
  derive it in `World` from `CameraState` plus the latest authoritative mount
  observation. Add the read-only coordinator witness to Commit 2's
  `FilesystemObserver` result; route startup seeding and the telemetry/status/SSE
  readiness refresh through its existing one-second bound as specified in
  Decision 3. Keep unrelated recording mutations on their existing authoritative
  synchronous witness path.
- Extend `camera_state_changed` and `storage_changed` with a complete
  `recording_readiness` replacement. Emit `storage_changed` when the mount
  observation changes the derived readiness even if quantized disk usage does
  not. Update world/hub event construction so snapshot and deltas use the same
  derivation.
- Update `contract/events/snapshot.json`, `camera_state_changed.json`, and
  `storage_changed.json`, plus `contract/events/README.md`, Rust fixture builders,
  and the Swift `World`, readiness/reason models, event payloads, folds, corpus
  decoding and representative-value assertions, inline event fixtures, and shared
  `CameraSamples` builders. Update directly affected app tests for the new
  required model field; do not add a default that could hide a missing wire value.
- Migrate every operational consumer to `/v1/status` in this commit:
  - Deploy's existing single reachability poll uses `python3 -c` with stdlib
    `json` to require a 200 JSON body whose `recording_readiness.ready` value is a
    boolean, and uses `DANCAM_STATUS_TIMEOUT`. Commit 6 adds the second logical
    phase. Add the initial hardware-free `deploy-test.sh` coverage for this parser
    and single-phase behavior; Commit 6 extends that harness for readiness and
    diagnostics.
  - The extracted reset-data script waits for
    `recording_readiness.ready == true` after restart and uses
    `DANCAM_RECORDING_READINESS_TIMEOUT`; its harness retains the full
    mount -> stop -> delete -> restart -> readiness-poll ordering assertion.
  - `hdr-set.sh` replaces the `camera_state=running` grep with the same
    `python3 -c` boolean parser for `recording_readiness.ready` from `/v1/status`,
    adopts `DANCAM_RECORDING_READINESS_TIMEOUT`, and updates `hdr-set-test.sh`.
  - Justfile `raspi-ap` prints `/v1/status` as the AP reachability URL.
  - Generic request-id, host-allowlist, and former health fixtures use
    `/v1/status`. The command-state recording test is renamed and asserts
    `/v1/status.recorder.phase == recording` after start and `idle` after stop.
  Remove `DANCAM_HEALTH_TIMEOUT` and never introduce the proposed
  `DANCAM_LIVE_TIMEOUT` or `DANCAM_READY_TIMEOUT`; no aliases remain.
- Reconcile current documentation atomically: update README/AGENTS operational
  commands, reset/HDR guidance, and timeout names; repoint `fern`'s present-tense
  roadmap guidance to the small canonical `/v1/status` probe; add dated forward
  notes to raspi ADR 02, raspi ADR 06, and app ADR 23. Preserve completed roadmap
  history, archived implementation plans, dated validation logs, and unrelated
  WIP plans; stale WIP plans are reconciled when they are refined for implementation.

Behavioral tests:

- `/v1/status` returns 200 and a structurally valid canonical snapshot while the
  camera is `Starting`, `Restarting`, or `Offline`, and while the configured mount
  witness fails. `/v1/health`, `/v1/live`, `/v1/ready`, and `/v1/ping` return 404.
- Ready serializes exactly as `ready:true, reason:null`. Each non-running camera
  state produces its exact reason. Running plus an unavailable required mount
  produces `recording_storage_unavailable`; camera reason wins over simultaneous
  storage failure. `RecorderPhase::Error` with running camera and valid storage is
  ready.
- The configured mount observation is seeded before the first status request;
  tests cover both a valid witness and a plain-directory failure without waiting
  for telemetry. Startup witness timeout continues serving with failed-closed
  readiness. Later loss, timeout, and recovery on the telemetry path update
  snapshot readiness, and timeout never preserves an earlier healthy witness.
- Extend Commit 2's injected stalled-probe tests with a configured required mount
  and startup seeding. Status and initial SSE remain responsive with
  `recording_readiness.ready == false`, reason
  `recording_storage_unavailable`, `storage:null`, and current-segment
  `dur_ms:null`; a later bounded successful refresh is required before readiness
  can become true again. A no-required-mount case separately asserts that a
  duration/disk timeout leaves readiness true while returning its nullable
  observations as null.
- Camera-state and mount-observation transitions emit one delta carrying the
  changed direct field plus matching readiness. A mount-only readiness transition
  emits `storage_changed` even when the quantized storage payload is unchanged.
  Rust world tests and Swift folding tests assert there is no stale pairing after
  either delta.
- The JSON value returned by `/v1/status` equals the first `/v1/events` snapshot
  after removing only the SSE `type` discriminator. Rust serialization and decode
  round-trip every updated corpus file. Swift decodes every file, asserts
  representative readiness values, and folds both readiness-carrying delta types
  to the expected canonical `World` without requiring `Encodable` conformance.
- Deploy, reset-data, and HDR harnesses exercise the stdlib `python3` parser with
  malformed JSON, missing/non-boolean readiness, `ready:false`, and `ready:true`.
  They tolerate transient status failures and succeed only on boolean true;
  reset-data pins the full safety ordering.

Verification: `just raspi-test`, `just raspi-build`, `just app-test`,
`just raspi-hdr-test`, `just raspi-reset-data-test`, the deploy parser harness,
`bash -n` for changed shell scripts, and `just adr-check`.

### Commit 4 -- `feat(raspi): return typed recording-command errors`

The command ownership semantics are already delivered by raspi ADR 23; this
commit names and serializes their terminal outcomes.

- Replace `BackendError::CameraOffline` and generic timeout/channel/storage wire
  text with the stable taxonomy from Decisions 4 and 5. Keep camera-only
  preflight: start from `RecorderPhase::Error` still dispatches, and no generic
  readiness classifier replaces terminal command outcomes.
- Return the JSON envelope and `Retry-After: 1` only for starting/restarting.
- Add one structured command-rejection event in `recording.rs`, where command
  context is known; do not duplicate it in `IntoResponse`.

Behavioral tests:

- A table exercises the real `CameraBackend` preflight for both start and stop
  under `Starting`, `Restarting`, and `Offline`, through the HTTP handlers. Assert
  status, JSON content type, exact stable code/message, and `Retry-After` policy.
- Table-test every stable backend code's HTTP status and header policy.
- A behavioral table drives all five post-dispatch `TerminalFailure` variants
  through the command/HTTP boundary: `Timeout` returns
  `camera_command_timeout`; `Write`, `ChildError`, `Exited`, and `Shutdown` each
  return `camera_command_channel`. The `ChildError` row asserts its injected child
  detail survives in the human `message`, not in the stable code. In-flight child
  exit retains the existing recovery assertion. A recorder failure after dispatch
  still returns `recorder_failed`, and no terminal outcome serializes an
  inappropriate camera lifecycle reason.
- A tracing capture drives a rejected start through HTTP and asserts event
  name/level plus structured `command`, `error_code`, and `camera_state` inside
  the existing request span, never formatted text.
- Existing successful start/stop tests remain green.

Verification: `just raspi-test` and `just raspi-build`.

### Commit 5 -- `feat(raspi): add decision-grade ring GC diagnostics`

- Reshape logging variants of `GcPass` around one observation record containing
  `floor_bytes`, optional before/after availability, and bounded ordered deleted
  IDs. `Failed` additionally retains its error. `AboveFloor` stays a silent unit
  variant.
- Construct the exact observation for every outcome from existing pass values:
  - `ReachedFloor`: initial and final are present, final is at or above floor,
    deleted is non-empty.
  - `BatchCapped`: initial and last are present, last is below floor, deleted
    length equals the batch cap.
  - `Exhausted` before delete: initial present, after absent, deleted empty;
    after progress: initial and last present, deleted non-empty.
  - `ProbeUnavailable` initially: both availability values absent, deleted empty;
    after progress: initial present, after absent, deleted non-empty.
  - `Failed` before delete: initial present, after absent, deleted empty. In-pass
    delete failure retains the last post-delete probe if any prior delete
    succeeded. Blocking-task/join failure has no availability and no deleted IDs.
- Emit progress fields for `ReachedFloor` and `BatchCapped`; emit the same evidence
  plus `retry_after_s` for exhausted/probe/failed backoff outcomes; retain
  `%error` for failure; emit nothing for `AboveFloor`.
- Keep backoff policy driven solely by the outcome variant. Document fields and
  useful `journalctl` examples in `raspi/AGENTS.md`.

Behavioral tests:

- Every pass test asserts complete initial/final availability, floor, ordered IDs,
  and outcome, including boundary values that select reached-floor versus
  batch-capped.
- Initial probe loss and post-delete probe loss have distinct shapes. Candidate
  scan/witness failure, in-pass delete failure, and blocking-task failure cannot
  construct phantom observations.
- Backoff tests remain green across reshaped variants.
- Table-driven tracing capture covers both `ReachedFloor` and `BatchCapped`,
  asserting their distinct `outcome` values and shared `deleted_count`,
  `deleted_ids`, `avail_before`, `avail_after`, and `floor_bytes` fields. It also
  covers exhausted, probe unavailable, and failed backoff classes with
  `retry_after_s`, plus the failed error field.
- A tracing regression asserts `AboveFloor` emits no GC outcome event.

Verification: `just raspi-test` and `just raspi-build`.

### Commit 6 -- `fix(raspi): wait for recording readiness after deploy`

- Refactor deploy's Commit 3 status poll into two explicit logical phases over
  `/v1/status`. Feed the valid body that completes phase 1 directly into phase 2
  before issuing another request.
- Wire deploy's readiness phase to the
  `DANCAM_RECORDING_READINESS_TIMEOUT` introduced in Commit 3, defaulting it to
  `DANCAM_STATUS_TIMEOUT` for deploy. Retain the last full valid status body
  throughout the readiness phase.
- On readiness timeout, print the retained body and run bounded best-effort
  `systemctl show dancam -p Environment`, `findmnt /data`, `df -B1 /data`, and
  `journalctl -u dancam -n 50 --no-pager`. Do not fetch status again.
- Route polls and diagnostics through one bounded-operation helper with an
  absolute local watchdog in addition to SSH connect/keepalive settings. It must
  terminate and reap a stalled child, return timeout, and allow later
  best-effort diagnostics within their own small bounds.
- Refactor `deploy.sh` into sourceable functions plus guarded `main` only as far
  as needed for hardware-free tests. Extend Commit 3's
  `raspi/scripts/deploy-test.sh` using the existing stubbed-command pattern. Keep
  build/install and normal CLI behavior.
- Update README/AGENTS deployment guidance with the two phases, literal timeout
  names, retained-status evidence, and bounded diagnostics. Success copy and the
  macOS notification say recording-ready.

Behavioral tests and verification:

- A malformed or unsuccessful status response does not complete phase 1. The
  first valid response completes reachability and is immediately evaluated for
  readiness; `ready:true` produces exactly one success notification without a
  redundant second request.
- Transient `ready:false` responses retain their full bodies while polling;
  eventual `ready:true` succeeds. Readiness timeout prints the final retained
  status and invokes environment, mount, space, and journal diagnostics, with no
  extra status fetch.
- A diagnostic failure does not replace the readiness error; exit stays nonzero
  and no success notification is emitted. A phase-1 timeout never enters
  readiness or diagnostics intended only for a valid-but-not-ready service.
- A connected poll or diagnostic that stalls is killed and reaped by its own
  operation bound. In the stalled-diagnostic case, a later sentinel diagnostic is
  still attempted after that timeout, the primary readiness timeout remains the
  final result, and the harness finishes nonzero within its deadline without a
  success notification.
- Run `bash -n raspi/deploy.sh raspi/scripts/deploy-test.sh`, the deploy harness,
  repo shell lint if present, `just raspi-test`, `just raspi-build`, and
  `just raspi-provision-lint`.
- Real Pi: `just raspi-deploy`; confirm one valid status establishes reachability,
  polling continues until `recording_readiness.ready` is true, and only then is
  success announced.
- Real Pi negative smoke: temporarily fail camera or mount readiness with a short
  `DANCAM_RECORDING_READINESS_TIMEOUT`; confirm the retained full status and
  bounded environment/mount/space/log evidence are printed, exit is nonzero, and
  readiness is not claimed. Restore normal state in the same session.

## Whole-plan acceptance

- `/v1/status` is the only operational probe and returns 200 with the canonical
  snapshot whenever the service can produce status. `/v1/health`, `/v1/live`,
  `/v1/ready`, and `/v1/ping` are absent; no `http_server` field exists.
- Top-level `recording_readiness` has exactly the agreed ready/null and four-reason
  taxonomy, camera-first precedence, retry-from-recorder-error behavior, and the
  authoritative recording-mount witness.
- `/v1/status` and the first `/v1/events` frame share one Rust snapshot. Startup,
  camera transitions, and mount loss/recovery keep readiness current; Rust and
  Swift fold the same corpus without a status-only enrichment path.
- Startup, telemetry, status, and initial SSE use one bounded, single-flight
  filesystem observer. A stalled probe cannot hang the operational endpoint,
  preserve `ready:true`, retain a stale duration, apply a late result, or
  accumulate blocking tasks under repeated polling.
- Every former operational health consumer uses `/v1/status`. Reset-data and HDR
  wait for recording readiness, while AP smoke uses status reachability. No old or
  proposed timeout alias remains. Point-in-time history remains intact.
- Deploy, reset-data, and HDR parse status with `python3 -c` plus stdlib `json`;
  they require valid JSON and a boolean `recording_readiness.ready`, reject
  malformed/missing/non-boolean values, and require no new provisioned package.
- Recording-command failures retain their separate typed terminal taxonomy and
  correlated structured rejection log. All five `TerminalFailure` variants have
  explicit mappings, and child-reported failure detail survives only in the human
  message.
- A GC progress entry alone identifies its distinct outcome, deleted IDs, floor,
  and observed availability. Backoff entries also identify retry delay, and the
  healthy two-second path stays silent.
- Deploy can satisfy both logical phases with one status response, never announces
  success before recording readiness, retains the selecting status body, and emits
  bounded diagnostics without a redundant status fetch. One stalled diagnostic
  does not prevent later best-effort evidence collection or replace the primary
  readiness failure.
- Reset-data behaviorally preserves mount witness -> stop -> delete -> restart ->
  recording-readiness poll ordering.
- No Ansible/provisioning artifact changes.

## Out of scope

- Changing SSE heartbeat semantics or using `/v1/status` polling as app connection
  truth; the app remains snapshot-first SSE with heartbeat liveness.
- Requiring time synchronization before recording.
- Adding another operational probe or a service-wide migration of unrelated error
  responses.
- Further changes to raspi ADR 23's implemented command-ownership lifecycle.
- Persisting GC history or exposing GC through a status field, API, or metric.
- Changing GC policy, floor behavior, eviction order, or backoff timing.
- Fixing mDNS/SSH host resolution or Pi time synchronization observed during the
  validation.

## Commit progress

- [x] 1. Extract raspi-reset-data remote body into a testable script
- [x] 2. Bound operational filesystem observation
- [x] 3. Make recording readiness part of canonical status
- [ ] 4. Return typed recording-command errors
- [ ] 5. Add decision-grade ring GC diagnostics
- [ ] 6. Wait for recording readiness after deploy
