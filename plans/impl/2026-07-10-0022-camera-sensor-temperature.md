# Plan: Surface camera sensor temperature end-to-end (Debug screen "Camera temp")

## Context

The iOS Debug screen has a "Camera temp" row that always shows `--`. The app side is
fully built (decode, fold, display, tint, warning pills at 50/55 C all handle a non-nil
`temp_c.sensor`), and the wire contract already carries `temp_c.sensor` as nullable.
The gap is entirely Pi-side: `raspi/service/src/events.rs#fn spawn_telemetry` hardcodes
`sensor: None`, and `raspi/camera/camera.py` never reads picamera2 metadata. The IMX708
does report its die temperature -- libcamera exposes `SensorTemperature` in per-frame
metadata, passed through by `CompletedRequest.get_metadata()`.

This completes work the docs explicitly deferred: roadmap fern's "sensor temperature
when Picamera2 metadata is surfaced" and ADR 02's "`temp_c.sensor` is present but null
until the Picamera2 owner surfaces sensor metadata."

## Design

**Camera facts are pushed by the camera owner; host facts stay polled by the service.**
camera.py samples the camera's latest `SensorTemperature` -- cached from a per-frame
Picamera2 callback, never a blocking capture (see Step 3) -- every 2 s and emits a new
stderr event `{"event":"sensor_temp","celsius":43.2}` (or `"celsius":null` when
unreadable). The
supervisor's `parse_stderr` drives a new `Input::SensorTemp` into the world, which
merges it into `temp_c.sensor` through the existing quantize(0.5 C)-and-diff path.
`Input::Telemetry` narrows to soc-only -- the hardcoded `sensor: None` disappears by
construction, not by replacement.

**Staleness is a world invariant, not supervisor choreography:** the world clears
`temp_c.sensor` whenever `CameraState` leaves `Running`. Every child-death path already
drives `Restarting`/`Offline`, so a dead camera reads `--` in the app instead of a
stale number, with no supervisor changes.

No change to the Rust `MockBackend` (its telemetry posture is "real host facts"; soc is
genuinely null on a Mac too). The `--fake` camera driver is the off-Pi full-pipeline
track and gets a deterministic synthetic temp.

## Steps (each compiles/tests green)

### 1. World + hub + backend: split TempC ownership (Rust)

- `raspi/service/src/world.rs`:
  - `Input::Telemetry`: replace `temp_c: TempC` with `soc_temp_c: Option<f32>`.
  - New `Input::SensorTemp { celsius: Option<f32> }` -> new `fn apply_sensor_temp`:
    ignore the sample unless `self.camera_state == CameraState::Running` (return no
    events) -- this makes "sensor is populated only while the camera is running" a total
    invariant enforced on every sample, not one merely restored on state transitions, so
    a sample that races ahead of a `Restarting`/`Offline` transition can never
    repopulate a stale reading. When running: quantize via existing `quantize_temp_value`,
    no-op if unchanged, else set `temp_c.sensor` and emit `Event::TempChanged` with the
    merged pair.
  - `apply_telemetry`: quantize soc only, preserve `temp_c.sensor`, emit merged pair
    on change. Delete now-unused `quantize_temp`.
  - `Input::CameraState` arm: after the state-change event, if new state is not
    `Running` and `temp_c.sensor.is_some()`, clear it and emit
    `TempChanged { soc, sensor: None }`.
- `raspi/service/src/event_hub.rs#fn update_telemetry`: signature to
  `(storage, soc_temp_c: Option<f32>, mem)`. No new hub method -- `parse_stderr`
  uses `drive_now` like every other child event.
- `raspi/service/src/backend.rs` trait + `MockBackend`, and
  `raspi/service/src/camera/mod.rs#CameraBackend`: `update_telemetry` to new signature.
- `raspi/service/src/events.rs#fn spawn_telemetry`: pass
  `crate::sysfacts::soc_temp_c()` directly.
- Tests (`world.rs`): rework the telemetry tests (`sample_temp()` becomes a soc value);
  new tests: first sensor sample emits + projects into snapshot; sub-quantum jitter
  (40.3 -> 40.4) emits nothing; bucket crossing emits merged pair with soc preserved;
  null-after-value emits cleared pair; sensor sample while `camera_state` is not
  `Running` (e.g. `Starting`) emits nothing and leaves snapshot sensor `None`; camera
  leaving `Running` clears sensor and emits `[CameraStateChanged, TempChanged]`;
  camera-state change with no sensor set emits no temp event. `event_hub.rs` concurrency
  test: `TempC::empty()` -> `soc_temp_c: None`.

### 2. Child protocol: `sensor_temp` stderr event (Rust)

- `raspi/service/src/camera/mod.rs#enum ChildEvent`: add
  `SensorTemp { celsius: Option<f32> }`, with `celsius` carrying
  `#[serde(deserialize_with = "required_nullable_f32")]` (a tiny free fn that just
  returns `Option::<f32>::deserialize(d)`). Correcting the earlier draft: a bare
  `Option<f32>` field is NOT required -- serde defaults a missing field to `None`
  without any `#[serde(default)]`, so `{"event":"sensor_temp"}` would silently clear the
  reading instead of being dropped. Pairing `deserialize_with` with NO `#[serde(default)]`
  suppresses that implicit `Option` default, so a missing `celsius` errors and falls to
  the logged-and-dropped `Err(_)` arm; present-null -> `None`; present-value -> `Some`.
  **Drop `Eq` from the derive** (f32 field); keep `PartialEq`.
- Make `parse_stderr`'s reader generic (`impl AsyncRead + Unpin + Send + 'static` in
  place of the concrete `ChildStderr`; the real `ChildStderr` call site still satisfies
  it) so the stderr->world path is unit-testable off an in-memory `Cursor`. The new arm
  drives `Input::SensorTemp { celsius: celsius.filter(|c| c.is_finite()) }`. The finite
  filter is load-bearing: serde_json yields a non-finite f32 from an in-range f64 literal
  like `1e39` (finite as f64, overflows the f32 cast to infinity), which must not reach
  the world.
- Tests:
  - Extend `child_event_parses_stderr_contract`: `sensor_temp` with a value -> `Some`,
    with `null` -> `None`, with `celsius` omitted -> `is_err()`, and with `1e39` ->
    `Some(_)` that is non-finite (documents why `parse_stderr` filters).
  - New `#[tokio::test]` that drives one line per `parse_stderr` call, each from its own
    `Cursor`, all sharing a single `Arc<EventHub>`. This is required because
    `parse_stderr` drains its reader to EOF before returning, so a single multi-line
    reader would expose only the final snapshot and leave the intermediate checkpoints
    unverified; separate calls against the shared hub let the test inspect the projected
    snapshot after each. Sequence: `{"event":"ready"}` (drives the world to `Running` so
    sensor samples are accepted), then `sensor_temp` `1e39` (assert `temp_c.sensor`
    null), then a real value (assert `Some`), then `null` (assert null again). This is
    behavioral (asserts the projection, not the filter expression) and fails if the
    finite filter is ever removed from the parse arm.

### 3. camera.py: sampler + both drivers + self-test

- Constants: `SENSOR_TEMP_INTERVAL_SECS = 2.0` (matches the service's 2 s telemetry
  tick) and `SENSOR_TEMP_JOIN_TIMEOUT = 1.0` (a safety bound on the graceful thread
  join). The sampler's read is a non-blocking cache lookup (see the `RealCameraDriver`
  bullet), so the join returns effectively instantly and the bound only guards a wedged
  interpreter. No read-timeout constant: the callback-cache design removes the blocking
  `capture_metadata` call from the telemetry path, so there is no in-flight camera read
  to time out or race. Fake sawtooth params (base 40.0, step 0.25, span 8.0).
- Pure helper `sensor_temp_payload(value)`: `None` for non-numeric (incl. `bool`) or
  non-`math.isfinite` values, else `float(value)` -- guards `json.dumps(nan)` emitting
  invalid JSON.
- Pure helper `fake_sensor_temp_c(sample_index)`: sawtooth 40.0 -> 48.0 in 0.25 steps,
  then wrap. At 2 s cadence it crosses a 0.5 C bucket every other sample, so
  `temp_changed` deltas visibly fire ~every 4 s in dev.
- `class SensorTempSampler` (near `InflightFlusher`, same injectable-collaborator
  style): ctor `(read, shutdown, interval, emit=emit_event)` over the driver's shared
  `shutdown` event (so stdin-EOF/crash halts it too, matching the preview loop); daemon
  thread `name="sensor-temp"`; samples once immediately, then
  `while not shutdown.wait(interval)`; each sample wrapped in `try/except Exception`
  -> emits `celsius=None` on failure so the wire reflects current knowledge; emits
  unconditionally every interval (world dedups). Exposes `start()` and `join(timeout)`
  (returns whether the thread stopped) so graceful teardown can signal and await it
  deterministically before the camera is torn down.
- `RealCameraDriver`: **read metadata from a per-frame callback, not a blocking
  capture.** In `start()`, before `picam2.start()`, install a `pre_callback` that -- per
  completed request -- caches `req.get_metadata().get("SensorTemperature")` into
  `self._latest_sensor_temp` (a single attribute write, atomic under the GIL). This reads
  metadata off the request non-destructively: it pops nothing from `completed_requests`
  and, unlike `capture_metadata(wait=...)`, never enqueues a Picamera2 `Job`. The
  sampler's injected `read` is then `lambda: self._latest_sensor_temp` -- an instant
  cache lookup with no camera I/O. (camera.py sets no `pre_callback`/`post_callback`
  today, so this is a clean addition.) Start the sampler in `start()` after
  `emit_event("ready")`. `shutdown_driver()` keeps a fixed teardown order: (1)
  `self.shutdown.set()` (halts the sampler loop, preview, and main loop); (2)
  `self.sensor_sampler.join(SENSOR_TEMP_JOIN_TIMEOUT)`, log a warning if still alive (now
  effectively instant since the read never blocks); (3) only then `stop_recording()`,
  `picam2.stop_encoder()`, `picam2.stop()`. This still inverts today's "set `shutdown`
  last" order (`shutdown_driver` currently sets it in a `finally` after `picam2.stop()`)
  for a clean thread join, but the cache read means there is no in-flight camera
  operation that could race `picam2.stop()` or leave a queued `Job` behind: the failure
  mode the `capture_metadata(wait=...)` design carried (a timed-out job stays in
  `_job_list` and `picam2.stop()` can block behind it -- the exact hazard the upstream
  `wait_cancel_test.py` cleans up with `cancel_all_and_flush()`) is designed out rather
  than mopped up.
- `FakeCameraDriver`: no Picamera2, so no callback -- `read` closes over a counter
  feeding `fake_sensor_temp_c` (also an instant, non-blocking read). Same teardown order
  in `shutdown_driver()`: `self.shutdown.set()`, join the sampler
  (`SENSOR_TEMP_JOIN_TIMEOUT`), then `stop_recording()` and join the preview thread. Both
  drivers share one sampler class and one teardown ordering contract.
- `run_self_test()` additions (plain asserts, house style): `sensor_temp_payload`
  table (float ok, int -> float, nan/inf/None/bool/str -> None);
  `fake_sensor_temp_c` values incl. wrap; sampler with capturing `emit` -- raising
  `read` emits null, value emits value, pre-set shutdown emits exactly once and exits;
  teardown ordering -- a sampler whose `read` blocks on a gate `threading.Event`
  (modelling a read still in progress when shutdown lands): start it, set `shutdown`,
  release the gate, then assert `join(SENSOR_TEMP_JOIN_TIMEOUT)` reports stopped and the
  thread is not alive (proves the signal-then-join teardown drains a mid-read sampler
  rather than abandoning it). Deterministic via the gate Event, no wall-clock sleeps.
- New integration test in `raspi/service/tests/camera_process.rs`:
  spawn `--fake`, wait for `Running`, poll snapshot until `temp_c.sensor ==
  Some(40.0)` (first fake sample is immediate and deterministic; add a
  `wait_for_sensor_temp` helper mirroring `wait_for_camera_state`), then kill/crash
  the child and assert sensor is null after `Restarting`.

### 4. Contract fixture: document the non-null shape

- `contract/events/temp_changed.json`: `"sensor": null` -> `"sensor": 43.5`
  (multiple of 0.5, honest to the quantized wire).
- `raspi/service/src/events.rs#fn canonical_events`: `Event::TempChanged` entry ->
  `sensor: Some(43.5)`. Snapshot entry and `snapshot.json` stay null so the corpus
  documents both shapes. Swift corpus test pins only snapshot.json values -- no app
  change (verified).

### 5. Docs (same change)

- `docs/roadmap.md` fern swoop: `Deepening:` bullet -- sensor temperature is now
  surfaced (camera owner samples metadata -> `sensor_temp` child event -> world-merged
  `temp_changed`/snapshot -> app Debug row).
- ADR 02 (`raspi/docs/design/02-...-app-pi-transport-and-api.md`), under the status
  section: append `> **Note (2026-07-09):**` -- `temp_c.sensor` now carries the
  quantized IMX708 `SensorTemperature` while the camera child is `running`, reverting
  to null otherwise (follows the file's existing dated-note convention).
- ADR 07 (`raspi/docs/design/07-...-picamera2-camera-owner.md`): append
  `## 2026-07-09 update: sensor temperature telemetry` (precedent: the 2026-06-30
  update section) -- stderr gains `sensor_temp`, ~2 s cadence, both drivers,
  sampled off the event loop from a cache the Picamera2 frame callback (`pre_callback`)
  fills with `SensorTemperature` -- no blocking `capture_metadata`, no per-sample camera
  `Job`. `celsius` is required-but-nullable
  (always present; null when unreadable; an omitted field is a protocol violation the
  supervisor logs and drops). Non-finite -> null. The sampler is signaled and joined
  before Picamera2 teardown, and the value dies with the child via the camera-state
  transition (sensor is projected only while `running`).
- `raspi/README.md` real-Pi verify: add `temp_c.sensor` to the `/v1/status` smoke
  check (human-facing verify steps move in the same change per convention).

## Verification

1. `just raspi-check` && `just raspi-test` (unit + golden corpus + new fake-track
   integration test); `python3 raspi/camera/camera.py --self-test`.
2. Off-Pi full pipeline: from `raspi/service/`,
   `DANCAM_BACKEND=camera DANCAM_CAMERA_CMD="python3 ../camera/camera.py --fake --rec-dir .fake-rec --preview-fps 10" cargo run`,
   then `curl -s localhost:8080/v1/status | jq .temp_c` -- expect `sensor` stepping
   through the 40.0 -> 48.0 sawtooth in 0.5 buckets. Point the app (Xcode sim) at it:
   Debug screen Camera temp shows the moving value; kill the python child and watch
   it flip to `--`.
3. `just app-test` -- no app source changes expected.
4. Real Pi: `just raspi-deploy`, then
   `curl -s http://dancam.local:8080/v1/status | jq .temp_c.sensor` (expect a real
   IMX708 reading), and the app Debug screen against the Pi.

## Follow Up

- Run the real-Pi check in `#Verification`: deploy to IMX708 hardware and confirm the
  status/app sensor value while running and its null projection during a child restart.
