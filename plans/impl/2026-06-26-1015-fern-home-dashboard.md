# Plan: Swoop `fern` -- Home camera dashboard

## Context

`jet` landed concurrent preview + recording control and was validated on real
hardware. The app, however, still **roots at `HealthViewController`**, which pushes
`PreviewViewController`; the live camera is behind a health/check screen, and the
only Pi facts the app reads come from `/v1/health` (a liveness probe). There is no
way to see finished recordings.

`fern` makes the **app's first screen the operational dashboard**: live preview on
top, recording state + one Start/Stop control with it, and a read-only list of
finished `.ts` segments below. That UI drives two new, minimal Pi endpoints --
`GET /v1/status` (dashboard facts) and `GET /v1/clips` (finished-segment metadata) --
while `/v1/health` stays small and boring. Polling is the baseline; SSE is deferred.

The endpoints are a deliberate **subset** of the surface already named in ADR 02
(`02-2026-06-22-app-pi-transport-and-api.md`). The storage coordinator, time-sync,
and incident layers that back the ADR's fuller field set do not exist yet, so `fern`
ships only the fields it can compute cheaply and correctly today. Additive JSON
fields are non-breaking (ADR 02 versioning rule), so the wire contract itself is not
changed -- but a partial first cut must be *documented*, not left implicit: `fern`
appends an append-only implementation note to ADR 02 recording exactly which
`/v1/status` and `/v1/clips` fields it ships now and which are deferred, so a later
agent or client cannot mistake an omitted-but-accepted field for an oversight.

Outcome: open the app -> see the camera, control recording, and watch finished
clips accumulate, all against a real (or mock) Pi.

---

## Scope

In:
- Live preview is the first screen (no health screen in front of it).
- Recording state + one Start/Stop control on that screen.
- Read-only list of finished `seg_NNNNN.ts` segments below preview.
- `GET /v1/status` (pragmatic subset) and `GET /v1/clips` (cheap listing).
- Polling. Mock-Pi path stays fully exercisable on the Mac.
- Health demoted to a Debug screen reachable from a nav-bar button.

Out (see Deferrals): playback, thumbnails, selection, pull/download, local HLS,
export (`lime`); SD detect/format (`kelp`); GPS overlay (`lark`); SSE `/v1/events`;
CarPlay UI; real clip timestamps/durations; sensor temperature.

---

## API schemas

Vocabulary follows ADR 02/03: endpoint is `clips` (not "segments"); clip `id` is the
integer `seq`. Both routes are registered in `raspi/service/src/lib.rs::app()` and
inherit the existing `host_allowlist` + `proto_headers` middleware (so every response
already carries `X-Dancam-Proto: 1` and `X-Dancam-Boot-Id`). All JSON is snake_case
via `#[serde(rename_all = "snake_case")]`, matching `health.rs`.

### `GET /v1/status`

```jsonc
{
  "recording": false,
  "camera_state": "running",          // reuse status::CameraState (starting|running|restarting|offline)
  "boot_id": "3f1c0e7a-...",
  "uptime_s": 1234,                    // service-start uptime, same source as /v1/health
  "storage": { "used": 12345678, "total": 9876543210 } | null,   // bytes; null if statvfs fails
  "temp_c": { "soc": 51.2, "sensor": null },                     // soc null if unavailable; sensor always null in fern
  "mem":     { "total": 536870912, "available": 209715200, "swap_total": 0, "swap_used": 0 } | null  // bytes (/proc/meminfo kB * 1024); null off-Linux
}
```

- `recording`, `camera_state`: from the existing `Backend::status()` (the `Status`
  struct already carries both). No backend change.
- `boot_id`, `uptime_s`: from `AppState` (same as `health.rs`). Intentionally
  overlaps `/v1/health`; that is fine. **Do not grow `/v1/health`.**
- `storage`: `statvfs` on `rec_dir`. Works cross-platform, but `null` whenever the
  path does not exist -- and the **default** `rec_dir` (`/home/dan/rec`) does not exist
  on macOS, so the Mac default yields `storage: null`. Pointing `DANCAM_REC_DIR` at a
  real folder (as the human checkpoints do) makes it report that volume -- a fine
  non-null exercise. `null` on any error.
- `temp_c.soc`: Linux read of `/sys/class/thermal/thermal_zone0/temp` (millidegC ->
  f32). `null` off-Linux / on error. `temp_c.sensor`: always `null` in `fern`
  (Picamera2 metadata not surfaced yet -- documented deferral).
- `mem`: parse `/proc/meminfo` (`MemTotal`, `MemAvailable`, `SwapTotal`,
  `SwapFree` -> `swap_used = total - free`). `/proc/meminfo` reports values in **kB**,
  so `parse_meminfo` multiplies every field by 1024 and emits **bytes** -- the same
  unit as `storage`, so the app's `Mem` model never has to reconcile two scales. `null`
  off-Linux.

Deliberately **omitted** (deferred, land with storage/time-sync/incident layers):
ADR 02's `since`, `current_segment_id`, storage `locked/oldest_ts/newest_ts`,
`encode_active`, `time_synced`, `last_incident_id`. Subset is forward-compatible.

### `GET /v1/clips`

```jsonc
{
  "clips": [
    { "id": 7, "start_ms": null, "dur_ms": null, "bytes": 39123456,
      "locked": false, "etag": "7-39123456", "time_approximate": true }
  ],
  "server_time_ms": 1719338400000,
  "next_cursor": null
}
```

- Scan `rec_dir` (flat) for `seg_(\d{5})\.ts` -- the **actual** naming written by
  `raspi/camera/camera.py` (`SEGMENT_RE = ^seg_(\d{5})\.ts$`, ffmpeg
  `-segment_time 30`). (Note: ADR 03's `seg-<seq>.ts` + `segments/` subdir is a
  *future* layout, not what `jet` shipped -- match the real flat `seg_NNNNN.ts`.)
- **Finished rule:** exclude the open segment. The open segment is the highest
  `seq` **iff** `recording == true` (ffmpeg is still writing it). If not recording,
  all segments are finished. Pure rule: `finished = seq < max_seq OR not recording`.
  `recording` comes from `Backend::status().recording`.
- Per-clip fields are cheap: `id` = seq (int), `bytes` = `metadata().len()`,
  `etag` = `"{seq}-{bytes}"` (matches ADR 03's `<seq>-<bytes>`, forward-compatible
  for `lime` ranged pull). `locked` = `false` (no incident layer). `time_approximate`
  = `true` (no time sync). `start_ms`/`dur_ms` = `null` (real values need TS PTS
  parsing + a wall clock; not cheap -> deferred per the roadmap's "when cheap").
- Order newest-first (descending `seq`) for display; cap at the most recent 500 and
  `log` if truncated (no paging in `fern`; `next_cursor` always `null`).
- `server_time_ms`: `SystemTime` epoch ms (like `health.t_ms`).
- Missing/unreadable `rec_dir` -> `{ "clips": [], "server_time_ms": ..., "next_cursor": null }`
  (graceful; this is the default Mac mock path).

---

## Raspi implementation (`raspi/service/`)

Add `rec_dir` to shared state, two handlers, and one sysfacts module.

1. **`AppState` gains `rec_dir: Arc<Path>`** (`src/lib.rs`). Keep `AppState::new`
   signature unchanged **and pure**: it defaults `rec_dir` to the plain constant
   `/home/dan/rec` (matching `camera/mod.rs`'s default) -- it does **not** read the
   environment, so `tests/status.rs`/`tests/clips.rs` stay deterministic. Add a
   `with_rec_dir(self, PathBuf) -> Self` builder so existing tests and `main.rs` stay
   green and `tests/clips.rs` can point at a temp dir. `main.rs` reads `DANCAM_REC_DIR`
   **once** and passes it via `with_rec_dir`. Do **not** also try to thread that one
   value into `CameraConfig`: `CameraConfig::from_env()` re-reads `DANCAM_REC_DIR`
   itself (harmless -- same value) and its `DANCAM_CAMERA_CMD` override replaces the
   whole command, bypassing `--rec-dir` entirely (`camera/mod.rs:47-67`), so "thread
   one value into both" cannot actually prevent drift without a new
   `CameraConfig::new(rec_dir, ...)` constructor -- out of scope for `fern`. The
   status/clips `rec_dir` is sourced on its own in `main.rs`.

2. **`src/sysfacts.rs`** (new): host-fact readers, each returning `Option`, with the
   reads split from the parsing so the parsers are host-independent and unit-tested:
   - `soc_temp_c() -> Option<f32>` + `parse_thermal(&str) -> Option<f32>`
   - `mem_info() -> Option<MemInfo>` + `parse_meminfo(&str) -> Option<MemInfo>`
   - `disk_usage(&Path) -> Option<DiskUsage>` via `statvfs`.
   Linux-only reads behind `#[cfg(target_os = "linux")]`; off-Linux returns `None`
   (except `disk_usage`, which is portable and may return real Mac stats).
   **Dependency:** add `rustix = { version = "0.38", features = ["fs"] }` for a safe
   `statvfs` wrapper (good musl support; avoids `unsafe`/`libc`). Confirm at impl
   time; `libc::statvfs` is the fallback.

3. **`GET /v1/status`** (`src/status.rs`, alongside the existing domain `Status`):
   add `StatusResponse` + `pub async fn status(State<AppState>) -> Json<StatusResponse>`.
   Maps `backend.status()` + `AppState` + `sysfacts::*` into the schema above.

4. **`GET /v1/clips`** (`src/clips.rs`, new): `ClipMeta`, `ClipsResponse`, a pure
   `read_finished_clips(rec_dir: &Path, recording: bool) -> Vec<ClipMeta>` (scan,
   parse seq, apply finished rule, sort desc, cap), and
   `pub async fn list_clips(State<AppState>) -> Json<ClipsResponse>`.

5. **Register routes** in `lib.rs::app()`:
   `.route("/v1/status", get(status::status))` and
   `.route("/v1/clips", get(clips::list_clips))`; add `mod clips; mod sysfacts;`.

6. **Append a `fern` implementation note to ADR 02**
   (`raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md`), reusing the file's
   established append-only `> **Note (date):**` blockquote convention (the same shape
   used for its 2026-06-23 editorial pass) at the *Status / control* + *Clips* endpoint
   section. The note states: the accepted decision (the full contract) is unchanged;
   `fern` ships the `/v1/status` and `/v1/clips` subsets defined above; it lists the
   deferred fields (`since`, `current_segment_id`, storage `locked/oldest_ts/newest_ts`,
   `encode_active`, `time_synced`, `last_incident_id`; clip `start_ms`/`dur_ms`/real
   `locked`/`time_approximate`; `temp_c.sensor`); and records that the omissions are
   intentional, pending the storage/time-sync/incident layers. This is a content-only
   note (no new file, no rename), so `just adr-check` is unaffected, but it must land in
   the same change as the endpoints (project "write the decision down" rule).

No `Backend` trait change is needed: status facts are host-level (not backend-level),
and clips read the filesystem + `Backend::status().recording`. This keeps the
MockBackend path working on the Mac unchanged.

### Mock-Pi behavior (Mac dev)
`DANCAM_BACKEND=mock` (default) keeps preview + recording mocked. `/v1/status` returns
real `recording`/`camera_state` from `MockBackend`, real-or-null storage, and `null`
temp/mem off-Linux. `/v1/clips` scans `DANCAM_REC_DIR`; point it at a folder of fake
`seg_00000.ts`... files to populate the list (`recording` still drives open-segment
exclusion). Empty/missing dir -> empty list.

---

## App implementation (`app/DanCam/DanCam/`)

Chosen structure (ideal split): **`HomeViewController` is the composition root**;
**`PreviewViewController` is slimmed to a reusable live-video surface** and embedded
as a child VC; the Start/Stop control + `recordingStore` move into `Home`. Health is
demoted to a Debug screen. All pieces reuse the existing `Store`/`Effect`/`Feature`
pattern and the `.live`/`.noop` client idiom.

### New networking clients (mirror `HealthClient` exactly)
- **`Networking/StatusClient.swift`** + `StatusResponse.swift` (Codable, snake_case via
  `CodingKeys`/`convertFromSnakeCase`). `var fetch: @Sendable () async throws ->
  StatusResponse`, `static func live(baseURL:pinning:[openByteStream:])`, throwing
  `StatusError.{http,transport,decoding}`. Models: `StatusResponse { recording,
  cameraState, bootId, uptimeS, storage: Storage?, tempC: TempC, mem: Mem? }` with
  `Storage{used,total}`, `TempC{soc: Double?, sensor: Double?}`, `Mem{total,available,
  swapTotal,swapUsed}`.
- **`Networking/ClipsClient.swift`** + `ClipsResponse.swift`. `var fetch: @Sendable ()
  async throws -> ClipsResponse`. Models: `ClipsResponse { clips: [Clip], serverTimeMs,
  nextCursor: String? }`, `Clip { id: Int, startMs: Int?, durMs: Int?, bytes: Int,
  locked: Bool, etag: String, timeApproximate: Bool }`.
- **`AppDependencies`**: add `var status: StatusClient` and `var clips: ClipsClient`;
  wire `.live(...)` in the `init(configuration:)` path and add params (with `.noop`
  defaults) to the test `init(health:preview:recording:...)`. Add `static let noop`
  to both clients for tests.

### New features (reducers + stores)
- **`Features/Status/StatusFeature.swift`**: `State` = `idle | loading | loaded(StatusResponse)
  | failed(String)`; `Action` = `onAppear | onDisappear | poll | statusResponse(Result<...>)`.
  Polls `/v1/status` while visible via a **self-rescheduling effect** (testable, no
  internal infinite loop). Both phases -- the in-flight fetch and the inter-poll sleep --
  run under a **single cancellable effect id `"status-poll"`**, so one cancel tears down
  whichever phase is live and the loop cannot resurrect itself:
  - `onAppear` is an **immediate poll** (reduces exactly like `.poll`): set `loading`
    only on the first load from `idle`, then run `.run(id:"status-poll",
    cancelInFlight:true){ send in let r = Result(of: deps.status.fetch);
    if !Task.isCancelled { await send(.statusResponse(r)) } }`. The cancellation guard
    before `send` ensures a fetch cancelled by `onDisappear` cannot deliver a late action.
  - `.statusResponse` updates state **in place** -- `.loaded` on success, `.failed` on
    failure (it does not reset to `loading` on repoll, avoiding flicker) -- then, **on
    either branch**, schedules the next tick under the **same id**:
    `.run(id:"status-poll", cancelInFlight:true){ send in try? await deps.sleep(1.5s);
    if !Task.isCancelled { await send(.poll) } }`. A failed fetch must **not** stop the
    loop: on this slow, congested 2.4 GHz link (root `AGENTS.md`; ADR 02) dropped
    requests are expected, so the failure branch reschedules exactly like success and
    the dashboard self-heals on the next tick. The shape to avoid is a `.failure` case
    that returns `.none` -- that freezes polling until the user leaves and returns.
  - `.poll` re-runs the fetch effect (same id), refreshing in place.
  - `onDisappear` -> `.cancel(id:"status-poll")`, cancelling an in-flight fetch *or* a
    pending sleep; the fetch is cancelled before `send`, so no later `.statusResponse`
    arrives and no `.poll` is rescheduled.
  Add an injectable `var sleep: @Sendable (Duration) async -> Void` to `AppDependencies`
  (default `Task.sleep`); tests inject an immediate stub.
- **`Features/Clips/ClipsFeature.swift`**: `State` = `idle | loading | loaded([Clip])
  | failed(String)`; `Action` = `onAppear | onDisappear | poll | refresh |
  clipsResponse(Result<...>)`. **Polls while visible** at a slow cadence (~10 s, vs
  status's ~1.5 s -- clips change far less often) using the **same self-rescheduling
  effect shape as `StatusFeature`** under a single cancellable id `"clips-poll"`:
  `onAppear` does an immediate fetch; `.clipsResponse` reschedules `.poll` after the
  slow sleep **on both success and failure** (a dropped request must not freeze the
  list -- same resilience rule as `StatusFeature`); `onDisappear` ->
  `.cancel(id:"clips-poll")` with the same cancellation-guarded sends. `.refresh` is an out-of-band immediate fetch that `Home`
  fires on a recording-stop transition (so the formerly-open segment shows up within
  seconds rather than waiting up to ~10 s); it runs under the same `"clips-poll"` id so
  it folds into the cycle instead of racing a second timer. Reuses `deps.sleep` /
  `deps.clips.fetch`.
- **`Features/Recording/RecordingFeature.swift`** (modify): **reseed from `/v1/status`
  instead of `/v1/health`** -- replace the `health.fetch()` effect with `status.fetch()`
  and the `.healthResponse(Result<HealthResponse,HealthError>)` action with
  `.statusResponse(Result<StatusResponse,StatusError>)`, reading `.recording`. This
  removes `/v1/health` from the product path. Start/Stop logic via `RecordingClient`
  is unchanged.

### View layer
- **`Features/Home/HomeViewController.swift`** (new root): owns `recordingStore`,
  `statusStore`, `clipsStore`; lays out `[status header] / [embedded preview] /
  [Start/Stop] / [clips table]`. Adds `PreviewViewController` via child-VC containment
  (`addChild` / `didMove(toParent:)`); appearance callbacks forward automatically so
  the preview's existing `viewWillAppear/Disappear` stream lifecycle keeps working.
  `Home` drives the status/clips visibility lifecycle: forward its own
  `viewWillAppear/Disappear` to `statusStore` and `clipsStore` as `.onAppear`/
  `.onDisappear` so both polls start/stop with the screen.
  Status header renders `camera_state`, `temp_c.soc`, `storage used/total`, `mem`
  (nulls render as "--"). Clips table is a read-only `UITableView` of
  `seg_{id} - {bytes}` rows. Nav-bar **Debug** button pushes `HealthViewController`.
  On each `recordingStore` change, `Home` calls the pure helper below and sends
  `clipsStore.send(.refresh)` exactly when it returns `true` -- keeping the
  stop->refresh coordination out of the UIKit observer and under test.
- **`Features/Home/HomeCoordination.swift`** (new, pure/stateless): encodes the
  cross-store coordination as a unit-testable function instead of inline VC-observer
  logic. `static func shouldRefreshClips(from previous: RecordingFeature.State,
  to next: RecordingFeature.State) -> Bool` returns `true` **exactly** on a
  recording-stop transition -- `next == .idle` and `previous` was `.recording` or
  `.stopping` (the moment the formerly-open segment becomes finished) -- and `false`
  for every other transition. `HomeViewController` keeps the last observed recording
  state and calls this on each change, firing at most one `.refresh` per stop.
- **`Features/Preview/PreviewViewController.swift`** (slim): keep `store`
  (`previewStore`) + decode pipeline (`PreviewDecodeState`, `Task.detached` decode) +
  image view + the appear/disappear stream lifecycle (`viewWillAppear`/`Disappear` ->
  `.onAppear`/`.onDisappear`). It has **two** control sets today, handled separately:
  (1) **Move to `Home`** the recording control -- `recordingStore`, the `recordButton`,
  and the REC indicator (`PreviewViewController.swift:13-17,81-82,105-109,233-242`); they
  become `Home`'s single Start/Stop control. (2) **Remove** the preview stream's own
  `startButton`/`stopButton` (`:11-12,75-79,100-103,225-231`): they are vestigial for an
  always-on dashboard, since `PreviewFeature.onAppear` auto-connects and `onDisappear`
  tears down (`PreviewFeature.swift:28,52`). What remains is a pure live-video surface
  (image view + status label) that connects on appear and disconnects on disappear.
- **`App/SceneDelegate.swift`**: root becomes
  `UINavigationController(rootViewController: HomeViewController(dependencies: .live))`.
- `HealthFeature` / `HealthViewController` / `HealthClient`: keep as the Debug screen
  (no longer root). `HealthClient` stays for that screen + liveness. **Drop** the
  now-redundant "Live preview" button (`previewButton`,
  `HealthViewController.swift:61-62,122-127`): with preview embedded in `Home`, a second
  preview surface behind Debug is dead weight; Health keeps only its liveness fields +
  Reload.

---

## Tests

Only behavioral, structure-insensitive assertions (request line + decoded model;
state transitions; pure-function outputs).

### Raspi (`just raspi-test`)
- `sysfacts.rs` unit tests: `parse_meminfo`, `parse_thermal` with fixture strings
  (host-independent; cover well-formed, missing-field, and garbage input).
- `tests/status.rs` (new): `oneshot GET /v1/status` with a `MockBackend` `AppState`.
  Assert `recording`, `camera_state`, `boot_id`, `uptime_s` present and well-typed;
  `temp_c.sensor` is `null`; `storage`/`temp_c.soc`/`mem` are present-or-null (don't
  assert host-specific values). Assert `x-dancam-proto` / `x-dancam-boot-id` headers.
- `tests/clips.rs` (new): build a temp `rec_dir` with `seg_00000.ts`/`seg_00001.ts`/
  `seg_00002.ts` (use a stub `Backend` with a settable `status().recording`, per the
  existing `tests/preview.rs` stub pattern). Cases: (a) `recording=false` -> 3 clips,
  newest-first ids `[2,1,0]`, correct `bytes`/`etag`; (b) `recording=true` -> seq 2
  excluded; (c) missing dir -> empty `clips`; (d) `recording=true` with a **single**
  segment (open == newest == oldest) -> empty `clips`, pinning the `seq < max_seq`
  boundary at its edge. Assert `next_cursor` null and `server_time_ms` present. Prefer
  a pure `read_finished_clips` test for the rules plus one route test for
  wiring/headers.

### App (`just app-test`, Swift Testing + `TestStore`)
- `StatusClientTests`: feed canned `/v1/status` JSON via mocked `openByteStream`
  (reuse `MJPEGWireBuilder` + `RequestCapture`); assert request line
  `GET /v1/status HTTP/1.1` + `Host`, and decoded `StatusResponse` (incl.
  `tempC.sensor == nil`, `storage`, `mem`).
- `ClipsClientTests`: canned `/v1/clips` JSON -> assert `GET /v1/clips` request line
  and decoded `ClipsResponse` (ids, bytes, etag, `startMs == nil`, `timeApproximate`).
- `StatusFeatureTests`: `onAppear` -> `loading` -> **immediate** fetch ->
  `statusResponse(.success)` -> `loaded` and schedules `.poll`; drive one cycle with an
  immediate `sleep` stub (receive `.poll` -> `.statusResponse`, state refreshed in
  place). Add a **failure-recovery** case: stub the fetch to fail once, assert
  `.statusResponse(.failure)` -> `.failed` **and** that a `.poll` is still scheduled,
  then drive one recovery cycle with the immediate `sleep` stub (next fetch succeeds ->
  `.loaded`) -- proving a transient error does not freeze the loop. Add a
  **disappear-during-poll** case: send `.onAppear`, then `.onDisappear` before the fetch
  resolves, and assert no later `.statusResponse`/`.poll` is received
  (`expectNoReceivedActions`) -- guards the single-id cancellation + send guard.
- `ClipsFeatureTests`: `onAppear` -> immediate fetch -> `clipsResponse(.success([...]))`
  populates rows and schedules the next `.poll`; drive one poll cycle with an immediate
  `sleep` stub; `.refresh` triggers an immediate fetch; `onDisappear` cancels and no
  later action is received; failure path -> `failed` **and still schedules the next
  `.poll`** (same resilience assertion as `StatusFeature`: drive one recovery cycle to a
  successful `loaded`).
- `HomeCoordinationTests`: table-drive `shouldRefreshClips(from:to:)` -- `true` on
  `.recording -> .idle` and `.stopping -> .idle`; `false` on `.idle -> .idle`,
  `.starting -> .recording`, `.recording -> .failed`, and a repeated `.idle`. Guards
  "refresh fires exactly once, and only on a real stop."
- `RecordingFeatureTests` (update): the three tests that currently await
  `.healthResponse` -- `onAppearSeedsRecordingStateFromHealth`,
  `startTappedStartsRecordingThenRefreshesHealth`,
  `stopTappedStopsRecordingThenRefreshesHealth` (`RecordingFeatureTests.swift:21,43,65`)
  -- swap the seeded/refresh stub to `StatusClient` and the awaited action to
  `.statusResponse`, asserting recording on/off is seeded from `status.recording`. The
  **state transitions** (`starting -> recording`, `stopping -> idle`, seed `-> recording`)
  are identical; only the awaited action and the injected client change. They cannot stay
  literally unchanged: all three route through one shared `refreshHealth` path
  (`RecordingFeature.swift:38,59,95-128`), so removing `.healthResponse` changes the
  action each emits. (The two tests that never await `.healthResponse` --
  `recordingFailureMapsToFailedState`, `cancellationSendsNoActionAndLeavesStartingState`
  -- are unaffected.)
- Preview decode tests unchanged (pipeline did not move).

---

## Commit slices

Conventional Commits; raspi first (unblocks app). Each slice is independently green.

1. `feat(raspi): add sysfacts module (soc temp, mem, disk)` -- `sysfacts.rs` +
   `rustix` dep + parser unit tests.
2. `feat(raspi): add GET /v1/status dashboard endpoint` -- `StatusResponse` + handler
   + route; plumb `rec_dir` into `AppState` (+ `with_rec_dir`, read once in `main`);
   `tests/status.rs`.
3. `feat(raspi): add GET /v1/clips finished-segment listing` -- `clips.rs` + route +
   `tests/clips.rs`. Now that both endpoints exist, append the `fern` subset/
   deferred-fields note to ADR 02 (raspi step 6 above). (Can be split into a trailing
   `docs(raspi): note fern status/clips subset in ADR 02` commit if a feat+docs mix is
   unwanted.)
4. `feat(app): add StatusClient and ClipsClient` -- clients + response models +
   `AppDependencies` wiring + client tests.
5. `feat(app): add StatusFeature + ClipsFeature polling` -- both reducers + stores,
   each self-rescheduling under a single cancellable poll id (status ~1.5 s, clips
   ~10 s + stop-refresh), injectable `sleep` in `AppDependencies`, reducer tests
   (incl. disappear-during-poll).
6. `refactor(app): seed RecordingFeature from /v1/status` -- swap health->status seed;
   update `RecordingFeatureTests`.
7. `feat(app): make home dashboard the root screen` -- new `HomeViewController`
   (owns recording/status/clips, embeds slimmed `PreviewViewController`, forwards
   appear/disappear to the polls), `HomeCoordination` helper + test (clips refresh on
   recording-stop), slim `PreviewViewController` (move the recording control to `Home`,
   drop the vestigial stream Start/Stop buttons), `SceneDelegate` root, Health demoted
   to a Debug button (and its now-redundant "Live preview" button removed).
8. `docs: mark fern subtasks complete in roadmap` -- tick the `fern` checkboxes
   (folds in the existing uncommitted roadmap edit; stage that path explicitly).

This planning change commits separately as `docs: plan fern home dashboard`.

Note: working tree has unrelated dirty/untracked files (`.claude/settings.local.json`,
`.gitignore`, `DanCam.xcscheme`, `plans/wip/*`, `references/`). **Stage explicit paths
only; never `git add .`.**

`fern` adds no new ADR and renames none -- it appends a content-only implementation
note to ADR 02 (slice 3) documenting the shipped subset and deferred fields. Since
`just adr-check` validates filenames/sequence, appending content leaves it unaffected;
run it only if a future change adds or renames an ADR.

---

## Human checkpoints

- **After slices 1-3 (raspi):** `just raspi-test` green. Manual: `just raspi-run`
  with `DANCAM_REC_DIR` pointed at a folder of fake `seg_*.ts`; `curl -H 'Host:
  localhost' localhost:8080/v1/status` and `.../v1/clips`. Dan eyeballs JSON shapes
  (storage/mem/temp null-vs-present, open-segment exclusion while "recording").
- **After slices 4-7 (app):** `just app-test` green. Run in the simulator against the
  mock Pi (`DANCAM_CAMERA_API_BASE_URL=http://127.0.0.1:8080`). Confirm: preview is
  the first screen, Start/Stop works, status header updates ~every 1.5s, clips list
  shows the fake segments, Debug button reaches Health. Dan confirms UX.
- **Real Pi smoke:** `just raspi-deploy`; confirm `/v1/status` shows real SoC temp +
  storage + mem, `/v1/clips` lists real `seg_*.ts`, the open segment is excluded
  while recording and appears after stop. Dan records a short clip and sees a new row.

---

## Verification gate

- `just raspi-test`
- `just app-test`
- `just adr-check` -- only if an ADR is added/renamed (none planned).
- Manual app run against the mock Pi (above).
- Real-Pi smoke (above), since `/v1/status` storage/temp and `/v1/clips` listing
  depend on actual rec-dir files and host facts.

---

## Explicitly deferred

- **`lime`:** clip playback, thumbnails, selection, ranged pull/download, local HLS,
  export. `fern`'s clip list is read-only; `etag` is emitted now so `lime` can do
  resumable pulls.
- **`kelp`:** SD detect / format / storage health.
- **`lark` (icebox):** GPS-driven overlay.
- **SSE `/v1/events`:** polling chosen. Revisit only if the dashboard or the later
  CarPlay status panel feels laggy or expensive under polling.
- **ADR 02 status fields not yet backed by infra:** `since`, `current_segment_id`,
  storage `locked/oldest_ts/newest_ts`, `encode_active`, `time_synced`,
  `last_incident_id` -- land with the storage coordinator + `POST /v1/time`.
- **Clip `start_ms`/`dur_ms` (real), `locked`, real `time_approximate`:** land with
  storage + time-sync.
- **`temp_c.sensor`:** land when `camera.py` surfaces Picamera2 sensor metadata over
  its stderr event channel (follow-up; nullable now, not a blocker).
- **CarPlay status panel:** `fern` produces the `/v1/status` facts it will consume;
  no CarPlay UI is built here.
- **Health screen:** demoted to Debug, not removed.

## Implementation notes

- Used `rustix` 1.x with the `fs` feature for `statvfs`; Cargo resolved `rustix`
  1.1.4, preserving the safe-wrapper intent while avoiding `unsafe`/`libc`.
