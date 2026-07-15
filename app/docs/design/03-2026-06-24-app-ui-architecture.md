# ADR: app UI architecture

- **Status:** Accepted
- **Date:** 2026-06-24
- **Owner:** app
- **Related:** root `AGENTS.md`; `app/AGENTS.md`;
  [transport boundary](../../../docs/design/boundary/transport.md) (the hand-rolled
  client becomes effect handlers behind the dependency boundary)

## Context

The app is moving from planning into the first `oak` implementation slice: call the
mock Pi health endpoint and show the result. Before code lands, the app needs a UI and
state-management direction that fits the whole project.

The decisive force is unusual: **all development on this project is LLM-driven**.
LLMs are strongest with small, local, self-consistent code they can keep in context.
They are weakest when they must synthesize code against large external APIs that have
changed shape across versions. The architecture should optimize for testability,
traceability, and low API surface area.

Other forces point the same way:

- The app scope is narrow and well understood: a few screens, a socket client, a
  custom preview surface, playback, settings, and CarPlay templates.
- The hardest UI-adjacent surfaces are already UIKit-shaped: custom MJPEG frame
  rendering, AVPlayer plus loopback-HLS playback, and CarPlay's `CPTemplate` APIs.
- The project should be easy to reason about from an action log: what happened, what
  state changed, and which effect caused the next action.
- The generated Xcode project already enables approachable concurrency
  (`SWIFT_APPROACHABLE_CONCURRENCY = YES`) on all targets and main-actor default
  isolation on the app target (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).

Under those concurrency defaults, a main-actor-resident store is the path of least
friction. Plain async effect operations stay on the caller's actor unless code
explicitly offloads with `@concurrent`, so the action path can stay ordered and
main-actor-isolated without broad `Sendable` constraints.

## Decision

Use **UIKit, programmatic, with no SwiftUI and no app storyboard**.

Use a **bespoke minimal Elm Architecture (TEA)** owned in this repo:

- Reducers are pure functions:

  ```swift
  reduce(inout State, Action, Dependencies) -> Effect<Action>
  ```

- `Store<State, Action, Dependencies>` is a small `@MainActor` generic over a
  struct-of-closures dependency bag. The reusable core knows no concrete app
  dependency type.
- `Effect<Action>` is data: `.none`, `.run(id:cancelInFlight:operation:)`, and
  `.cancel(id:)`.
- Effects feed actions back through an async `send` callback. Reducers never call
  `send` directly.
- Dependencies are plain closures captured by effect operations. The dependency bag
  lives in the app layer, not in the architecture core.
- Tests use a hand-written generic `TestStore` plus focused Store runtime tests.

The architecture has **zero third-party dependencies**. That is a consequence of the
bespoke choice, not a project-wide dependency policy.

### Concurrency posture

The Store is `@MainActor`. Effect operations are ordinary async closures, so under the
project's approachable-concurrency settings they run on the caller's actor: the Store's
main actor. There is no cross-actor hop on the action path, and `Action`, `State`, and
dependency closures do not need blanket `Sendable` or `@Sendable` annotations.

Use `@concurrent` only for genuinely off-main work introduced later, such as MJPEG
frame decode or ranged clip pull. Adding it will also force the corresponding captures
and actions to satisfy `Sendable`, so it should be a deliberate local choice.

### Illustrative core sketch

This sketch shows the shape, not a frozen API:

```swift
enum Effect<Action> {
    case none
    case run(
        id: AnyHashable? = nil,
        cancelInFlight: Bool = false,
        operation: (_ send: (Action) async -> Void) async -> Void
    )
    case cancel(id: AnyHashable)
}

@MainActor
final class Store<State, Action, Dependencies> {
    typealias Reducer = (inout State, Action, Dependencies) -> Effect<Action>

    private var state: State
    private let dependencies: Dependencies
    private let reduce: Reducer

    func send(_ action: Action) {
        let effect = reduce(&state, action, dependencies)
        observe(state)
        execute(effect)
    }
}
```

Runtime details matter but stay small: `.run` tasks are tracked by internal monotonic
tokens, optional cancellation IDs map to those tokens, `cancelInFlight` cancels the
prior task for that ID before launching the next one, and task bodies capture the Store
weakly so long-running effects cannot retain a dead screen.

Tests assert reducers through the generic harness:

```swift
await store.send(.reload) { $0 = .loading }
await store.receive(.healthResponse(.success(response))) {
    $0 = .loaded(response)
}
```

## Consequences

Easy:

- Reducer behavior is directly unit-testable with stubbed dependency closures.
- The production effect runtime is small enough to test thoroughly.
- Action logging gives traceability through one `send(_:)` choke point.
- The `oak` URLSession health client can later be swapped for a pinned `NWConnection`
  client behind the same dependency closure.
- UIKit keeps the preview, playback, and CarPlay surfaces in their native framework.

Hard or risky:

- We own the effect runtime correctness: action serialization, id-keyed cancellation,
  reentrancy shape, task lifetime, and weak Store capture.
- UIKit has more per-screen boilerplate than SwiftUI.
- The main-actor-resident posture is simple for `oak`, but off-main work later must
  choose `@concurrent` and `Sendable` boundaries carefully.

Mitigations:

- Keep the architecture core tiny and standard.
- Test the Store runtime directly, not only reducers.
- Use Swift Testing for reducer and client tests.
- Review concurrency-sensitive changes against the Swift concurrency guidance before
  expanding the effect runtime.

Follow-ups outside this ADR:

- Persistence is a separate decision (SwiftData versus files).
- The pinned `NWConnection` client from the transport boundary plugs in behind the health
  client style dependency boundary during a later swoop.
- MJPEG preview decode and ranged clip pull are the first likely places to add
  deliberate off-main work.

2026-07-01 note: ADR 13 deletes the loopback-HLS playback surface named in the
context above. The architecture choice is unchanged: clip playback still uses
UIKit-hosted `AVPlayer`, now against a local cached MP4 instead of a loopback HLS
playlist.

## Alternatives considered

- **SwiftUI.** Rejected: its implicit observation and state model duplicates TEA's
  single-source-of-truth store, its current idioms churn across releases, and the
  app's hardest surfaces are UIKit-shaped anyway.
- **The Composable Architecture.** Rejected: its API has moved across several eras,
  including `Reducer`/`pullback`, `ReducerProtocol`, macro reducers, observable state,
  and changing view-store patterns. LLM-generated code commonly mixes those eras, which
  is a poor fit for an all-LLM workflow. Its effect and dependency ideas remain useful
  references.
- **Mobius.swift.** Rejected: it is a third-party dependency for a small TEA core we can
  own in roughly a few hundred lines. Its Init/Update/Effect model remains a useful
  reference.
- **ReSwift.** Rejected: it is stale enough to be a risky greenfield foundation.
- **MVVM, MVC, VIPER, or Clean Swift.** Rejected: side effects are not modeled as data
  and there is no single action stream, so testability and traceability are weaker.
- **An elaborate home-grown framework.** Rejected: the goal is a small, standard TEA
  implementation, not a novel app framework.
