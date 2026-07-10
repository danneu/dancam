# Plan: clips transport-error resilience (5 commits)

## Context

A transient clips-list fetch failure on the congested 2.4 GHz link produced a sticky,
unreadable Home banner: "Transport error: The operation couldn't be completed.
(DanCam.NWByteStreamError error 2.)". Diagnosis (verified against the Pi journal and
the simulator) found three compounding defects:

1. **Message**: `ClipsClient` stringifies transport errors via `error.localizedDescription`;
   `NWByteStreamError` has no `LocalizedError` conformance, so the NSError bridge emits
   sludge. The same `catch { .transport(error.localizedDescription) }` idiom is duplicated
   across seven clients (Clips, Recording, Time, ClipPrefix, ClipPull, plus
   `.connectionFailed(String)` in Events and Preview). The clips head status itself stores
   a pre-rendered `.failed(String)`, so once a failure is reduced the original error kind
   is lost -- which is also why nothing downstream can tell a transient flake from a
   permanent contract error.
2. **Stickiness**: the clips head fetch has no retry, and returning to the Home tab does
   not reload. One failed connect leaves `.failed` forever while the SSE link is healthy.
   A latent sibling: `.onDisappear` cancels an in-flight head fetch, stranding
   `status = .loading` forever.
3. **Fragility**: the 2s connect timeout admits only one TCP SYN retransmit (~1s); a single
   lost packet pair on a cold connection kills the request. Every request opens a cold
   connection (`Connection: close`).

Fixes land as five small, independently-green Conventional Commits. Run
`just app-test` (and `just app-build`) after each.

**Retry mechanism (the F1 pivot).** The clips retry is driven by the inbound SSE
`heartbeat`, not a separate timer. The Pi emits `heartbeat` every 2 seconds
(`raspi/service/src/main.rs#run` -> `spawn_heartbeat(..., Duration::from_secs(2))`), and
`AppFeature` already receives it as `.event(.heartbeat)` and re-arms the liveness timer on
every event. Using that pulse as the retry clock gives the same 2s cadence for free and
makes the retry inherit the stream's lifecycle exactly: no heartbeats arrive while the
stream is stopped/failed/timed-out or while the app is backgrounded, so there is no
independent timer to cancel and no way to re-arm a retry into a stopped app. This removes
the entire class of "retry fires after `.streamStopped`" races -- there is no retry ID,
retry action, sleep, or cancellation point to get wrong.

---

## Commit 1 -- `fix(app): replace stringly transport errors with typed human-readable failures`

### New type: `app/DanCam/DanCam/Networking/HTTP/TransportFailure.swift`

New file beside `NWByteStream.swift` (project uses synchronized root groups; no pbxproj
edit needed):

```swift
nonisolated enum TransportFailure: Error, Equatable, Sendable {
    case connectTimedOut
    case idleTimedOut
    case invalidEndpoint
    case network(reason: String)   // curated, user-safe phrase (e.g. "Connection refused")
    case unknown(debug: String)    // diagnostic detail only; NEVER shown to the user

    static func wrapping(_ error: Error) -> TransportFailure { ... }
    var displayMessage: String { ... }
    var debugDetail: String? { ... }   // for logging; nil unless we carried raw detail
}
extension TransportFailure: LocalizedError {
    var errorDescription: String? { displayMessage }
}
```

Two-case network split is deliberate (F3): only curated, OS-vetted phrases ever reach a
banner; arbitrary NSError text is quarantined in `.unknown(debug:)` and never rendered.

- `wrapping(_:)` mapping:
  - existing `TransportFailure` -> pass through.
  - `NWByteStreamError.connectTimedOut` -> `.connectTimedOut`; `.receiveIdleTimedOut` ->
    `.idleTimedOut`; `.missingHost`/`.invalidPort` -> `.invalidEndpoint`.
  - `NWError.posix(code)` -> `.network(reason: String(cString: strerror(code.rawValue)))`
    (bounded OS phrase set: "Connection refused", "No route to host", "Operation timed
    out", ...).
  - `NWError.dns` -> `.network(reason: "DNS lookup failed")`; `NWError.tls` ->
    `.network(reason: "TLS error")` (we serve `http://`, so TLS should never occur; mapped
    for safety).
  - `NWError` **plain `default` -> `.unknown(debug: String(describing: error))`**. This is
    the single robust catch for every remaining current-and-future case, including the SDK's
    Wi-Fi Aware case. We deliberately do NOT enumerate every `NWError` case by name, and we
    use a plain `default` -- NOT `@unknown default`: `NWError` is a non-frozen enum, so
    `@unknown default` still demands every *currently known* case be listed and emits a
    "switch must be exhaustive" warning if (e.g.) `.wifiAware` is omitted -- which would
    defeat the warning-clean, future-proof rationale. A plain `default` folds all
    non-posix/dns/tls cases (known and future) into one generic-but-safe branch, so the
    guarantee ("no bridge sludge, stable user text") holds for cases that do not exist yet,
    with no warning today.
  - anything else (non-`NWError`, non-`NWByteStreamError`) ->
    `.unknown(debug: String(describing: error))`.
- `displayMessage` wording:
  - `.connectTimedOut` -> "Can't reach the camera (timed out)."
  - `.idleTimedOut` -> "Camera stopped responding."
  - `.invalidEndpoint` -> "Camera address is invalid."
  - `.network(reason)` -> "Can't reach the camera (\(reason))."
  - `.unknown` -> "Can't reach the camera." (generic; the raw `debug` is NEVER interpolated
    into user copy).
- `debugDetail`: `.network(reason)` -> `reason`; `.unknown(debug)` -> `debug`; else `nil`.
  Available for logging; no consumer wired yet (kept so a future log line can surface the
  raw cause without changing the type).
- Wrapping stays at each client's catch boundary, NOT inside `NWByteStream` --
  `NWByteStreamError` remains the transport-layer error that `ClipPullClient`'s retry
  loop and `NWByteStreamTests` pattern-match.

### Retype all seven client error enums to `case transport(TransportFailure)`

Uniform idiom swap: catch-alls become `.transport(.wrapping(error))`; `displayMessage`
for the transport case becomes `failure.displayMessage` (drop the "Transport error: " /
"Connection failed: " / "Camera transfer failed: " prefixes -- developer taxonomy, not
user information). All enums stay `Equatable` (required: they're embedded in `Equatable`
`Action` enums). Keep the `catch let error as URLError where error.code == .cancelled`
sentinels ABOVE the wrapping catch-alls everywhere.

- `Networking/ClipsClient.swift#ClipsError` (2 catch sites)
- `Networking/RecordingClient.swift#RecordingError` (1)
- `Networking/TimeClient.swift#TimeSyncError` (1)
- `Networking/Clips/ClipPrefixClient.swift#ClipPrefixError` (2; no displayMessage exists)
- `Networking/Clips/ClipPullClient.swift#ClipPullError` (1; `errorDescription` transport
  case -> `failure.displayMessage`)
- `Networking/Events/EventsClient.swift#EventsError` -- delete `.connectionFailed(String)`,
  add `.transport(TransportFailure)`
- `Networking/Preview/PreviewClient.swift#PreviewError` -- same rename

Feature-layer catch-alls that construct `.transport(...)` from arbitrary errors, all
become `.transport(.wrapping(error))`:

- `Features/Clips/ClipsFeature.swift` -- `deleteEffect` and `fetchResult` catch-alls
- `Features/Recording/RecordingFeature.swift` -- both `.transport(...)` sites
- `Features/Preview/PreviewFeature.swift` -- `connectEffect` catch-all

### Carry the typed error in the clips head status

`ClipsFeature.State.Status.failed(String)` -> `.failed(ClipsError)`. The pre-rendered
string is itself a stringly error representation (this commit's whole thesis), and
retaining the typed error is what lets commit 2 tell a transient failure from a permanent
one without re-plumbing.

- `Features/Clips/ClipsFeature.swift`: both `state.status = .failed(error.displayMessage)`
  sites (head-fetch failure at `.clipsResponse(_, .failure)`, and delete failure at
  `.deleteResponse(_, .failure(let error))`) become `state.status = .failed(error)`.
- `Features/Home/HomeViewController.swift#updateClipsPresentation`: `case .failed(let
  message)` -> `case .failed(let error)` and pass `caption: error.displayMessage`.
- `Status` stays `Equatable` (`ClipsError` is `Equatable`).

Out of scope (deliberate): `.decoding` / `.malformedResponse` / `.encoding` keep their
strings -- developer-facing, not the sludge source.

### Tests (commit 1)

- New `DanCamTests/Networking/HTTP/TransportFailureTests.swift`: exercise EVERY public
  display branch, which is the F3 guarantee:
  - wrapping of both byte-stream deadlines; both endpoint errors;
    `NWError.posix(.ECONNREFUSED)` -> `.network(reason: "Connection refused")`;
    `NWError.dns(...)` -> `.network(reason: "DNS lookup failed")`; `NWError.tls(...)` ->
    `.network(reason: "TLS error")`; pass-through of an existing `TransportFailure`; an
    arbitrary `NSError` -> `.unknown` (generic copy).
  - **plain-`default` NWError branch**: wrap `NWError.wifiAware(...)` and assert it maps to
    `.unknown` (NOT `.network(reason:)`) with `displayMessage == "Can't reach the camera."`.
    This exercises the plain-`default` NWError route specifically -- distinct from the
    arbitrary-`NSError` route the sludge guard covers -- so a regression that special-cased
    `.wifiAware` into user-visible `.network(reason:)` copy would fail here. `.wifiAware` is
    available unconditionally at the iOS 26.5 deployment target (introduced iOS 26.0), so the
    test needs no `if #available` guard; construct it with any valid associated value.
  - pin the `displayMessage` string for `.connectTimedOut`, `.idleTimedOut`,
    `.invalidEndpoint`, a `.network(reason:)` case, and `.unknown`.
  - **sludge guard**: wrap an arbitrary `NSError(domain:code:)` and assert
    `displayMessage == "Can't reach the camera."` AND
    `displayMessage.contains("Error Domain") == false` and `.contains("Code=") == false`
    -- a behavioral encoding of "the NSError bridge text never reaches the banner."
- `DanCamTests/Networking/ClipsClientTests.swift`: add
  `fetchMapsByteStreamFailureToTypedTransportFailure` -- `openByteStream` throws
  `NWByteStreamError.connectTimedOut`, expect `.transport(.connectTimedOut)` (this
  branch was previously untested).
- `DanCamTests/Features/Home/HomeViewControllerTests.swift`: in
  `clipsFailurePresentationIsVisibleAndSuppressesEmptyState` and
  `manualRefreshSpinnerStaysUntilClipsReachTerminalStatus`, replace
  `.transport("No route")` with `.transport(.connectTimedOut)` and the expected banner
  string with `"Can't reach the camera (timed out)."`. (The failure-message hook still
  returns a `String`, so only the constructed error and expected copy change.)
- `DanCamTests/Features/Clips/ClipsFeatureTests.swift`: the `.failed("HTTP 503")` /
  `.failed("HTTP 500")` status assertions become `.failed(.http(503))` /
  `.failed(.http(500))` (status now carries the typed error).
- `DanCamTests/Networking/Events/EventsClientTests.swift#mapsByteStreamFailure` and
  `DanCamTests/Networking/Preview/PreviewClientTests.swift` -- update catch patterns
  from `.connectionFailed` to `.transport`.

---

## Commit 2 -- `fix(app): retry the clips head fetch on heartbeats while the camera is online`

The retry clock is the inbound `heartbeat`, not a timer (see Context -> "Retry
mechanism"). When a heartbeat arrives while the camera is online and the clips head is in
a **retryable** failure, kick one `.load`; a heartbeat that lands while a load is already
in flight does nothing (status is `.loading`, not `.failed`). No new action, effect ID,
sleep, cancellation point, or `logLabel` entry.

### Retryability (F2)

Not every failure should re-fetch every 2s. Add to `Networking/ClipsClient.swift`:

```swift
extension ClipsError {
    var isRetryable: Bool {
        switch self {
        case .transport: true
        case .http(let code): (500...599).contains(code)
        case .decoding: false
        }
    }
}
```

- **Retryable**: transport failures (link flake) and HTTP 5xx (Pi transiently
  overloaded/restarting).
- **Terminal**: HTTP 4xx (missing endpoint / bad request -- re-fetching yields the same
  4xx) and decoding errors (contract mismatch -- same bytes, same failure). These stay
  `.failed` until a fresh `snapshot` forces a `.load` (e.g. after a Pi restart) or the user
  pulls to refresh -- they never spin a GET every 2s.

This is exactly why commit 1 makes the status carry the typed `ClipsError`: the retry
decision reads the error kind straight off `state.clips.status`.

### Wiring in `Features/App/AppFeature.swift`

In the existing `case .event(let event):` branch, after `state.link.fold(event)`, append a
clips reload when a heartbeat lands on a retryable failure:

```swift
if case .heartbeat = event, shouldReloadClipsOnHeartbeat(state) {
    effects.append(
        ClipsFeature.reduce(state: &state.clips, action: .load, dependencies: dependencies)
            .map(Action.clips)
    )
}
```

```swift
private static func shouldReloadClipsOnHeartbeat(_ state: State) -> Bool {
    guard state.link.onlineWorld != nil else { return false }        // offline recovery is snapshot's job
    guard case .failed(let error) = state.clips.status else { return false }
    return error.isRetryable
}
```

Notes on why this is complete and safe:

- Gating on `heartbeat` only (not any event) keeps a bounded 2s cadence and avoids a
  delta-burst restarting the fetch faster than it can complete. `snapshot` and `timeSynced`
  already trigger an unconditional `.load` in this branch, so those recovery edges are
  unchanged; a heartbeat is the steady pulse in between.
- Gating on post-fold status covers BOTH failure sources uniformly -- a head-fetch failure
  and a delete failure both set `status = .failed`, and in both cases a healthy-link head
  reload is the correct recovery (it clears the stale banner and re-syncs the list). This
  is strictly better than special-casing head failures.
- `onlineWorld != nil` is guaranteed by the time heartbeats flow (the first frame is always
  `snapshot`), and folding a heartbeat never changes recorder phase, so the recording-phase
  effect at the bottom of the branch does not fire.
- No `logLabel` change: the heartbeat-triggered `.load` is reduced inline (like the
  snapshot/timeSynced reloads), so it is not a separately dispatched action -- the
  transition logs as `event.heartbeat` and the follow-up `clips.clipsResponse.*` as usual.

### Record the pivot in ADR 10 (same commit)

`app/docs/design/10-2026-06-29-event-folded-state-machines.md` owns the event-folded clips
behavior and currently states "heartbeat is liveness, and clips are folded by
`ClipsFeature`" and that "`heartbeat` ... do[es] not mutate `World`." Adding a heartbeat-
driven retry gives heartbeat a second, non-`World` job, so the pivot must be recorded in the
owning ADR (project rule: write the pivot down in the same change). Append a dated note to
ADR 10 (following its existing 2026-07-09 note precedent; ADR stays `Accepted`, body
unchanged) capturing:

- **Failure-only heartbeat retry.** While online, a `heartbeat` whose arrival finds the
  clips head status in a *retryable* `.failed` starts exactly one `/v1/clips` head `.load`;
  a heartbeat that lands mid-load does nothing. This does not mutate `World` (it is a
  `ClipsFeature` reload, consistent with "clips are folded by `ClipsFeature`") and composes
  with ADR 23's "heartbeat advances `World.uptimeS`" note.
- **Retryability classification.** Transport failures and HTTP 5xx are retryable; HTTP 4xx
  and decoding failures are terminal until a fresh `snapshot` or manual refresh.
- **Inherited stream lifecycle.** The retry clock is the inbound heartbeat, so it needs no
  independent timer/ID/cancellation: no heartbeats arrive while the stream is
  stopped/failed/timed-out or the app is backgrounded, which is what removes the
  "retry fires after `.streamStopped`" race class.

### Tests (commit 2, in `DanCamTests/Features/App/AppFeatureTests.swift`)

Use the file's existing private `dependencies(...)` factory and `ClipsFetchQueue`. No
`SleepGate` needed (no timer). Drive retries by sending `.event(.heartbeat)`. Use online,
time-synced worlds (`CameraSamples.world()` default) so `.event(.heartbeat)` neither
starts a time sync nor triggers an unrelated `.load`.

- `heartbeatReloadsClipsAfterRetryableFailureAndEventuallySucceeds` -- queue [failure(503),
  success]; snapshot -> clips `.failed(.http(503))`; `.event(.heartbeat)` -> clips `.load`
  (status `.loading`, `headEpoch` bumped) -> receive success -> `.idle`, `hasLoadedOnce`;
  `finishEffects()`, `expectNoReceivedActions()`.
- `heartbeatDoesNotReloadAfterTerminalHTTPFailure` -- queue [failure(404), success];
  snapshot -> `.failed(.http(404))`; `.event(.heartbeat)` -> assert clips status unchanged,
  `headEpoch` unchanged, and no second fetch dequeued (`expectNoReceivedActions()`). Then
  send a fresh `.event(.snapshot)` and assert it DOES `.load` and receives the queued
  `success` (-> `.idle`) -- proving terminal-until-snapshot, not terminal-forever. Queue the
  `success` alongside the 404 so the snapshot-triggered fetch has a result to `removeFirst()`
  (a lone-404 queue would `removeFirst()` on empty and trap).
- `heartbeatDoesNotReloadAfterDecodingFailure` -- queue [decoding-failure]; snapshot ->
  `.failed(.decoding(...))`; `.event(.heartbeat)` -> assert status/`headEpoch` unchanged and
  no fetch dequeued, proving decoding is terminal. No snapshot-recovery step here (that edge
  is proven once, in the 404 test above), so this test needs only the single queued failure
  and cannot drain an empty queue.
- `heartbeatDoesNotReloadWhenClipsHealthy` -- clips `.idle`; `.event(.heartbeat)` -> no
  `.load`, `headEpoch` unchanged.
- `heartbeatDoesNotReloadWhileClipsLoading` -- clips `.loading`; `.event(.heartbeat)` ->
  no second `.load`, `headEpoch` unchanged.
- `deleteFailureThenHeartbeatReloadsHead` -- online world, a retryable `.deleteResponse`
  failure sets `.failed`; `.event(.heartbeat)` -> head `.load` fires (documents the intended
  uniform recovery from a delete-failure banner).
- `heartbeatWhileOfflineDoesNotReloadClips` -- construct link `.connecting`/`.offline` with
  a retryable `.failed` status; `.event(.heartbeat)` -> no `.load` (the `onlineWorld` guard).
  This is a defensive guard test; in practice no heartbeat arrives while offline.

Note the loop terminates naturally: each retry is one heartbeat -> at most one `.load`, and
`finishEffects()` only awaits the single in-flight fetch, so no test can spin.

---

## Commit 3 -- `fix(app): keep clips head fetch alive across Home disappear`

`Features/Clips/ClipsFeature.swift#reduce`, `.onDisappear` case becomes:

```swift
case .onDisappear:
    state.isPaging = false
    return .cancel(id: pageID)
```

The head fetch (`fetchID`) now survives tab switches: it is a one-shot JSON GET whose
result belongs to global state; cancelling it stranded `status = .loading` forever.
Paging stays cancelled (scroll-driven, view-local demand). Interplay with commit 2 is
intended: a fetch that fails off-screen sets a retryable `.failed`, and the next heartbeat
self-heals it.

Interaction with app background (the F1 concern, now benign): if the surviving fetch fails
after the app backgrounds, `.streamStopped` has already stopped the stream, so no heartbeat
arrives and no retry is scheduled -- the status just sits at `.failed` until the app
foregrounds, at which point `.streamStarted` -> `snapshot` reloads. A single fetch that was
already in flight may finish in the background and set state once; that is harmless (the
process is being torn down and re-foreground reloads). No head-fetch cancellation on
`.streamStopped` is added: with the heartbeat clock there is nothing to re-arm, so the
cancellation would only suppress one benign, already-issued GET.

### Tests (commit 3, in `DanCamTests/Features/Clips/ClipsFeatureTests.swift`)

- Delete `onDisappearCancelsInFlightFetch` -- it would now HANG (the parked 60s fetch
  is no longer moved to `canceledTasks`, so `finishEffects()` awaits it).
- Add `headFetchSurvivesDisappearAndItsResponseStillApplies` -- gate the fetch on
  signals; `.load` -> `.onDisappear` -> release -> receive the success response and
  assert it applies (`.idle`, `hasLoadedOnce`).
- Add `onDisappearCancelsInFlightPaging` -- `nextCursor` set, parked fetch;
  `.loadMore` -> `.onDisappear` (`isPaging = false`) -> `finishCanceledEffects()` ->
  `expectNoReceivedActions()`.
- Verify-only: `HomeViewControllerTests.manualRefreshSpinnerEndsWhenHomeDisappears`
  needs no change (spinner reset is view-local; the uncancelled parked task lingers on
  a live Store, which tests never await).

---

## Commit 4 -- `fix(app): raise camera API connect timeout to 4s`

- `App/AppConfiguration.swift`: `defaultCameraAPIConnectTimeout` `.seconds(2)` ->
  `.seconds(4)`. Fans out uniformly via `AppDependencies(configuration:)` to all seven
  clients -- intended (they all face the same hostile link). `DANCAM_CONNECT_TIMEOUT_MS`
  override path untouched. Commit body: TCP retransmits a lost SYN at ~1s then ~3s
  cumulative; 2s admits one retransmit, 4s admits two. Still below the 6s heartbeat
  timeout.
- `DanCamTests/App/AppConfigurationTests.swift`: update the two assertions pinning
  `.seconds(2)` (`defaultConfigurationUsesDancamLocalFallback`,
  `invalidConnectTimeoutOverridesFallBackToDefault`) to `.seconds(4)`.
- `app/docs/design/09-2026-06-29-connection-liveness-timeouts.md` states "The default
  connect timeout is 2 seconds" -- add a dated note (the file has a 2026-06-30 note
  precedent) recording the 2s -> 4s pivot and rationale; invariants (override path,
  heartbeat-first liveness) unchanged.

---

## Commit 5 -- `docs(roadmap): add icebox swoop for persistent camera connections`

`docs/roadmap.md#Icebox`, new entry; codename `moor` (verified unused). Format matches
existing entries (`- [ ] **Swoop \`moor\` -- Persistent camera connections.**`, 6-space
continuation indent, `--` dashes, ASCII, ends with parked-until rationale): reuse a
kept-alive HTTP/1.1 connection per plane instead of `Connection: close` per request;
removes per-request SYN exposure on the congested link. Open questions: connection
ownership, staleness detection after Wi-Fi drops, Pi's per-connection serve model.
Parked until per-request connects measurably hurt again -- the 4s deadline plus the
heartbeat-driven auto-retry already absorb one-off SYN loss.

---

## Verification

After each commit: `just app-build` and `just app-test` (full suite green).

End-to-end after commit 2 (or all five), in the simulator against the real Pi:

1. Launch the app with the Pi up; confirm clips load.
2. Simulate the incident: stop the Pi service mid-session (`ssh dancam.local sudo
   systemctl stop dancam` or equivalent) right after a snapshot, wait for a clips
   failure banner, restart the service. The banner should now clear itself within a
   few seconds of the link recovering (snapshot reload) -- and if only the clips fetch
   flakes while SSE stays up, the next heartbeat (<= ~2s) clears it without any user
   action.
3. Confirm the banner text is the human string (e.g. "Can't reach the camera (timed
   out).") -- never the NSError bridge text.
4. Tab away from Home mid-load and return: no stranded loading state, list settles.

## Commit progress

- [x] 1. Replace stringly transport errors with typed human-readable failures
- [x] 2. Retry the clips head fetch on heartbeats while the camera is online
- [ ] 3. Keep clips head fetch alive across Home disappear
- [ ] 4. Raise camera API connect timeout to 4s
- [ ] 5. Add icebox swoop for persistent camera connections
