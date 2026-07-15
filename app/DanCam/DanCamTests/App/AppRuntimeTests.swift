import Foundation
import Testing
@testable import DanCam

@MainActor
struct AppRuntimeTests {
    @Test func startsWithNoActiveConsumer() async {
        let probe = EventStreamProbe()
        _ = makeRuntime(probe: probe)

        await Task.yield()

        #expect(await probe.openCount == 0)
        #expect(await probe.terminationCount == 0)
    }

    @Test func duplicateAndOverlappingSceneCallbacksShareOneStream() async {
        let probe = EventStreamProbe()
        let actions = LifecycleActionLog()
        let runtime = makeRuntime(probe: probe, actions: actions)

        runtime.activateScene(id: "phone")
        await probe.waitForOpenCount(1)
        runtime.activateScene(id: "phone")
        runtime.activateScene(id: "carplay")

        #expect(actions.values == [.streamStarted, .foregrounded])
        #expect(await probe.openCount == 1)

        runtime.deactivateScene(id: "phone")
        runtime.deactivateScene(id: "phone")

        #expect(actions.values == [.streamStarted, .foregrounded])
        #expect(await probe.terminationCount == 0)

        runtime.deactivateScene(id: "carplay")
        await probe.waitForTerminationCount(1)

        #expect(actions.values == [
            .streamStarted,
            .foregrounded,
            .backgrounded,
            .streamStopped,
        ])
    }

    @Test func reactivationStartsAReplacementStream() async {
        let probe = EventStreamProbe()
        let actions = LifecycleActionLog()
        let runtime = makeRuntime(probe: probe, actions: actions)

        runtime.activateScene(id: "phone")
        await probe.waitForOpenCount(1)
        runtime.deactivateScene(id: "phone")
        await probe.waitForTerminationCount(1)

        runtime.activateScene(id: "phone")
        await probe.waitForOpenCount(2)

        #expect(actions.values == [
            .streamStarted,
            .foregrounded,
            .backgrounded,
            .streamStopped,
            .streamStarted,
            .foregrounded,
        ])

        runtime.deactivateScene(id: "phone")
        await probe.waitForTerminationCount(2)
    }

    private func makeRuntime(
        probe: EventStreamProbe,
        actions: LifecycleActionLog = LifecycleActionLog()
    ) -> AppRuntime {
        let dependencies = AppDependencies(
            events: probe.client,
            heartbeatTimeout: {
                try await Task.sleep(for: .seconds(3_600))
            }
        )
        return AppRuntime(
            dependencies: dependencies,
            onAction: actions.record,
            logsTransitions: false
        )
    }
}

@MainActor
private final class LifecycleActionLog {
    private(set) var values: [AppFeature.Action] = []

    func record(_ action: AppFeature.Action) {
        switch action {
        case .streamStarted, .streamStopped, .foregrounded, .backgrounded:
            values.append(action)
        default:
            break
        }
    }
}

private actor EventStreamProbe {
    private var openContinuations: [AsyncThrowingStream<CameraEvent, Error>.Continuation] = []
    private var terminations = 0
    private var openWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var terminationWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    nonisolated var client: EventsClient {
        EventsClient { [self] in
            let (stream, continuation) = AsyncThrowingStream.makeStream(
                of: CameraEvent.self,
                throwing: Error.self
            )
            continuation.onTermination = { [self] _ in
                Task { await didTerminate() }
            }
            Task { await didOpen(continuation) }
            return stream
        }
    }

    var openCount: Int { openContinuations.count }
    var terminationCount: Int { terminations }

    func waitForOpenCount(_ count: Int) async {
        guard openContinuations.count < count else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append((count, continuation))
        }
    }

    func waitForTerminationCount(_ count: Int) async {
        guard terminations < count else { return }
        await withCheckedContinuation { continuation in
            terminationWaiters.append((count, continuation))
        }
    }

    private func didOpen(_ continuation: AsyncThrowingStream<CameraEvent, Error>.Continuation) {
        openContinuations.append(continuation)
        resumeSatisfiedWaiters(&openWaiters, currentCount: openContinuations.count)
    }

    private func didTerminate() {
        terminations += 1
        resumeSatisfiedWaiters(&terminationWaiters, currentCount: terminations)
    }

    private func resumeSatisfiedWaiters(
        _ waiters: inout [(count: Int, continuation: CheckedContinuation<Void, Never>)],
        currentCount: Int
    ) {
        let satisfied = waiters.filter { $0.count <= currentCount }
        waiters.removeAll { $0.count <= currentCount }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }
}
