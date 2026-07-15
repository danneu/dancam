# Plan: ideal background and event recovery fixes

## Summary

Keep snapshot-first SSE with no event backlog. Land four independently tested commits:
process-scoped ownership, honest suspended freshness, typed clip cursors, and
authoritative paged clip recovery. No Pi runtime behavior or wire-contract changes.

## Commit 1 -- `refactor(app): move domain runtime above UI scenes`

- Add a `@MainActor AppRuntime`, owned by `AppDelegate`, that creates the live
  dependencies and sole `AppStore`.
- Track active scene session identifiers. The first activation sends
  `.streamStarted` and `.foregrounded`; the last deactivation sends `.backgrounded`
  and `.streamStopped`. Duplicate activation/deactivation is idempotent.
- Make `SceneDelegate` UI-only: borrow the runtime store/dependencies, construct tabs,
  activate in `sceneWillEnterForeground`, and deactivate in both background and
  disconnect callbacks.
- Remove stream startup from `willConnectTo`, eliminating the redundant cancel-and-
  restart of the SSE stream on cold launch.
- Preserve per-scene visible-preview resume while allowing future phone and CarPlay
  scenes to share one domain runtime.
- Update `docs/design/app/architecture.md` so its body describes the process-owned
  runtime and UI-only scenes in present tense, replacing the former scene-scoped root
  design. Append a dated entry under `## Decision log` recording why the ownership moved:
  CarPlay may launch the app directly into the background with only a
  `CPTemplateApplicationScene` and no phone window scene, so `AppDelegate` must create
  the runtime independently of every `SceneDelegate`; lazy initialization by the first
  phone scene is invalid. Record too that background and disconnect callbacks may both
  arrive for one scene, requiring idempotent deactivation, while disconnect is not
  guaranteed at process termination, so deactivation owns no durable work and gates
  only process-ephemeral stream/freshness state. The existing CarPlay page already
  delegates root lifecycle to the architecture page; update it only if implementation
  changes that boundary. Update the roadmap in the same commit. Keep `app/AGENTS.md`
  lean and change it only if an always-on constraint or its design-page index changes;
  this runtime detail is expected to require no `app/AGENTS.md` edit.
- Test zero-consumer startup, duplicate callbacks, two simultaneous consumers,
  last-consumer shutdown, reactivation, and SSE cancellation using controllable
  streams/signals.

## Commit 2 -- `fix(app): suspend live state outside active scenes`

- Replace `Link.connecting` with freshness-preserving states:
  - `suspended(last: World?)`
  - `connecting(last: World?)`
  - `online(World)`
  - `offline(last: World?)`
- Initialize as suspended. On the last scene deactivation, move every `Link` state --
  including connecting and offline -- to `suspended(last: link.world)`, reset recording
  control to unknown, cancel commands/timers, and make `onlineWorld` unavailable
  immediately.
- Foreground activation always moves `suspended(last:)` to `connecting(last:)` while
  retaining stale display facts. While active, offline retries remain offline until the
  replacement snapshot so the existing reconnect recovery edge stays intact.
- Map suspended UI to a neutral "Paused" state; recorder projections remain
  frozen/last-known until the snapshot restores live truth.
- Guard record commands on a fresh online world.
- Add foreground state to incident reconciliation: an already-active pull may use its
  existing UIKit background-task grace, but queued pulls do not start until
  foregrounding resumes reconciliation.
- Update `docs/design/app/connection.md` so its body describes the suspended,
  connecting, online, and offline freshness lifecycle and foreground-gated incident
  reconciliation in present tense. Update
  `docs/design/app/architecture.md#Event-folded world` to keep its embedded `Link`
  model and freshness rules consistent. Append a dated entry under `## Decision log`
  in the connection page recording why the earlier stale-online background scope was
  replaced by explicit suspension, then update the roadmap. Keep `app/AGENTS.md` lean
  and change it only if an always-on constraint or its design-page index changes; this
  behavior is expected to require no `app/AGENTS.md` edit.
- Test all `Link` projections, background-to-foreground transitions, no stale incident
  reconciliation, command cancellation, frozen UI projections, active-pull grace,
  queued-pull pause/resume, fresh-snapshot restoration, and specifically
  `offline(last:) -> suspended(last:) -> connecting(last:)` across background and
  foreground. Add a parameterized suspended/connecting/offline x idle/recording test
  that sends `.recordTapped`, proves state does not change, and proves the recording
  client is never called for either the start or stop route.

## Commit 3 -- `refactor: type clip cursors`

- Introduce `ClipCursor`, a `UInt32`-backed `Codable`, `Comparable`, `Sendable` value.
  Decode `next_cursor` only from the Pi's canonical decimal string; reject negative,
  nonnumeric, noncanonical, and greater-than-`UInt32.max` values with
  `DecodingError.dataCorrupted`. Use `ClipCursor?` at the `ClipsResponse` decoding
  boundary and throughout `ClipsClient`, feature state/actions, coverage goals, URL
  query encoding, and incident coverage.
- Preserve the existing request ordering, page merging, incident pagination handshake,
  UI cancellation, and recovery behavior. The only intentional behavior change is that
  an invalid wire cursor now fails decoding instead of degrading to catalog end.
- Pin the producer side in `raspi/service/src/clips.rs#mod tests` with a test asserting
  every emitted non-null `next_cursor` is the canonical decimal rendering of its `u32`
  sequence: it parses back to the same value and equals that value's `to_string()`.
  This is a producer test only; the response schema and Pi runtime behavior do not
  change.
- Test app decoding of valid boundary values and malformed, negative, noncanonical,
  and greater-than-`UInt32.max` cursors, plus existing pagination behavior through the
  typed client and feature APIs.

## Commit 4 -- `fix(app): reconcile clip pages after event gaps`

- Make `ClipsFeature` the sole owner of head/page sequencing. Its typed coverage state
  tracks the saved browse frontier, the fresh authoritative frontier for the current
  snapshot epoch, an optional incident-required boundary, user load-more demand, the
  current request cursor/generation, and paused/failed status. A fresh SSE snapshot
  grants an opaque epoch token; one central scheduler starts work only while that token
  is present, the process is active, the page state is not failed, and no request is in
  flight.
- Define a numeric browse frontier `.cursor(F)` to mean that IDs `>= F` have been
  incorporated and IDs `< F` remain unseen; `.end` means the catalog was loaded to its
  end. Keep this browsing frontier separate from the temporary cursor used to walk
  recovery pages.
- On every new SSE snapshot, preserve rendered clips and the saved browse frontier,
  cancel/replace stale list requests, establish a new coverage epoch with a head load,
  and walk downward until that saved frontier is authoritatively covered. A previously
  complete catalog walks to the new end. Every request and response carries that epoch
  token as well as its request generation.
- In the same `AppFeature` reducer transition that handles `.streamFailed`,
  `.heartbeatTimedOut`, or process suspension, revoke the clip epoch before making the
  fresh world unavailable, cancel/retire the in-flight list generation, and discard
  the fresh authoritative frontier and all incident-visible coverage from that epoch
  while preserving rendered rows, browse frontiers, and pending user/incident goals.
  Coverage publication is tagged with the epoch and incident reconciliation accepts it
  only while it matches `AppFeature`'s current fresh epoch. A response may merge clips,
  infer absence, advance a frontier, or publish coverage only when both its epoch token
  and generation still match; a late pre-gap response is otherwise ignored in full.
- Connecting and offline states have no clip epoch. Manual refresh may request stream
  reconnection and retain a refresh goal, while user paging and incident requirements
  retain their goals, but none may start a clip request until the replacement snapshot
  grants a new token. Manual refresh during an already-fresh epoch may replace the
  current list request with a new head request.
- Replace `IncidentPlannerCommand.page`, `IncidentsFeature.isPageRequestPending`, and
  `.pageRequested` with a pure minimum required coverage boundary. Incident planning
  publishes the lowest unresolved sequence it needs; `AppFeature` synchronously passes
  that value to `ClipsFeature`, which combines it with recovery and user browse demand.
  Only a user load-more request or an incident boundary may authorize moving the browse
  frontier below its saved value.
- Carry the requested upper cursor in every page response. The Pi response's actual
  authority is `[response.nextCursor, infinity)` for a head and
  `[response.nextCursor, requestedCursor)` for a page, with catalog end acting as zero.
  Intersect that interval with the currently authorized target before merging clips or
  inferring absence. Discard response clips below the target, never delete there, and
  retain the target itself as the browse cursor when a fixed-size response overshoots
  it. A separate recovery request cursor may advance below the saved cursor only while
  proving coverage; it never changes browsing state by itself.
- A user `loadMore` demand authorizes one full next page and advances the browse
  frontier to that page's validated cursor/end. An incident boundary authorizes only
  through that exact sequence; response overshoot below it is discarded. Gap recovery
  alone therefore never incorporates or advances into previously unseen history.
- Preserve `clip_finalized` facts observed during the current request epoch and the
  existing removal tombstones when applying authoritative absence. Publish only
  successfully established coverage from the still-current fresh epoch to incident
  reconciliation.
- On any head/page failure, settle the sole request, retain all goals, set typed failed
  status, and schedule nothing. Repeated incident requirements and UI load-more signals
  remain inert while failed. The existing heartbeat retry or manual refresh may clear
  the page failure and retain a replacement-head goal, but the scheduler resumes that
  goal only while a fresh epoch token exists; after a stream gap it waits for the
  replacement snapshot.
- Remove `ClipsFeature.onDisappear` and Home's disappearance dispatch. UI navigation
  never owns global request cancellation; only epoch revocation on process suspension,
  stream failure, or heartbeat timeout, plus an explicit replacement head request,
  cancels shared clip work. Revocation preserves rows, frontiers, and goals so the next
  fresh snapshot can restart them.
- Update `docs/design/app/clips.md` and `docs/design/app/incidents.md` so their bodies
  describe the single pagination owner, fresh-epoch authority, browse-frontier limits,
  failure pause, and incident coverage-boundary handshake in present tense. Append a
  dated entry under each page's `## Decision log`: clips records why pagination and
  authority are centralized and epoch-gated; incidents records why negative evidence
  consumes only current-epoch coverage published by that owner. Cross-link the two
  owning sections and update the roadmap. Keep `app/AGENTS.md` lean and change it only
  if an always-on constraint or its design-page index changes; this recovery detail is
  expected to require no `app/AGENTS.md` edit.
- Test missed head, middle-page, and oldest-first GC removals; arbitrary deletion gaps;
  saved-frontier stopping; fully loaded recovery; interruption/resume; concurrent
  finalize/removal races; and recording-detail preservation. Add focused cases for:
  one failed page producing exactly one request and no retry before heartbeat/manual
  restart; repeated incident coverage publication while failed; deletion-heavy head
  and final-page overshoot that neither merge nor authorize absence below the target;
  user and incident authorization of deeper coverage; Home disappearance while a
  signal-blocked shared recovery completes without cancellation. Add signal-controlled
  event-ordering tests proving that stream failure and heartbeat timeout retire a
  blocked pre-gap request, its late response cannot alter clips or publish incident
  coverage, and offline manual refresh issues no clip request until a replacement
  snapshot arrives and grants a new epoch.

## Interfaces and verification

- New internal API: `AppRuntime.activateScene(id:)` and `deactivateScene(id:)`.
- Changed internal models: expanded `Link` freshness states; `ClipCursor` replaces raw
  cursor strings; `ClipsResponse.nextCursor`, `ClipsClient.fetch`, list state/actions,
  and incident coverage use the typed cursor; clip page requests/responses carry their
  requested upper cursor, generation, and fresh-snapshot epoch token; incidents publish
  coverage requirements instead of pagination actions.
- Unchanged external API: `/v1/events`, `/v1/status`, `/v1/clips`, SSE IDs, and
  `Last-Event-ID` behavior.
- After each commit, run `just app-build`, `just app-test`, and `just docs-build`. For
  Commit 3 also run `just raspi-test` to pin the producing cursor format. Commit only
  the coherent change named by that section.
- Current baseline: `just docs-build` is the required design-page and link-validation
  gate during implementation. `just app-test` previously built successfully but the
  simulator worker failed to materialize, so final acceptance still requires a clean
  completed test run after resolving simulator state.

## Commit progress

- [x] 1. Move domain runtime above UI scenes
- [x] 2. Suspend live state outside active scenes
- [x] 3. Type clip cursors
- [x] 4. Reconcile clip pages after event gaps
