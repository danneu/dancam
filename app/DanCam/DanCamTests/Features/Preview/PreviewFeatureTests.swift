import Foundation
import Testing
@testable import DanCam

@MainActor
struct PreviewFeatureTests {
    @Test func onAppearConnectsAndStreamsFrame() async {
        let frame = PreviewFrame(sequence: 0, jpeg: Data("jpeg".utf8))
        let store = TestStore(
            initialState: PreviewFeature.State(),
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError("Health should not be called.") }),
                preview: PreviewClient(connect: {
                    AsyncThrowingStream { continuation in
                        continuation.yield(frame)
                        continuation.finish()
                    }
                }),
                sleep: { _ in }
            ),
            reduce: PreviewFeature.reduce
        )

        await store.send(.onAppear) {
            $0.phase = .connecting
        }
        await store.receive(.frameReceived(frame)) {
            $0.phase = .streaming(frame)
        }
        await store.receive(.streamFinished) {
            $0.phase = .stopped
            $0.reconnectAttempt = 1
        }
        await store.receive(.reconnect) {
            $0.phase = .connecting
        }
    }

    @Test func laterFramesReplaceEarlierFrames() async {
        let f0 = PreviewFrame(sequence: 0, jpeg: Data("zero".utf8))
        let f1 = PreviewFrame(sequence: 1, jpeg: Data("one".utf8))
        let store = TestStore(
            initialState: PreviewFeature.State(phase: .streaming(f0)),
            dependencies: AppDependencies(health: HealthClient(fetch: { fatalError() })),
            reduce: PreviewFeature.reduce
        )

        await store.send(.frameReceived(f1)) {
            $0.phase = .streaming(f1)
        }
    }

    @Test func streamFailureMapsToFailedState() async {
        let store = TestStore(
            initialState: PreviewFeature.State(),
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                preview: PreviewClient(connect: {
                    AsyncThrowingStream { continuation in
                        continuation.finish(throwing: PreviewError.http(503))
                    }
                }),
                sleep: { _ in }
            ),
            reduce: PreviewFeature.reduce
        )

        await store.send(.startTapped) {
            $0.phase = .connecting
        }
        await store.receive(.streamFailed(.http(503))) {
            $0.phase = .failed("HTTP 503")
            $0.reconnectAttempt = 1
        }
        await store.receive(.reconnect) {
            $0.phase = .connecting
        }
    }

    @Test func stopTappedCancelsStreamAndLeavesStoppedState() async {
        let store = TestStore(
            initialState: PreviewFeature.State(),
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                preview: PreviewClient(connect: {
                    AsyncThrowingStream { _ in }
                })
            ),
            reduce: PreviewFeature.reduce
        )

        await store.send(.onAppear) {
            $0.phase = .connecting
        }
        await store.send(.stopTapped) {
            $0.phase = .stopped
        }
        await store.finishEffects()
        store.expectNoReceivedActions()
    }

    @Test func cancellationErrorSendsNoFailureAction() async {
        let store = TestStore(
            initialState: PreviewFeature.State(),
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                preview: PreviewClient(connect: {
                    AsyncThrowingStream { continuation in
                        continuation.finish(throwing: CancellationError())
                    }
                })
            ),
            reduce: PreviewFeature.reduce
        )

        await store.send(.startTapped) {
            $0.phase = .connecting
        }
        await store.finishEffects()

        #expect(store.state.phase == .connecting)
        store.expectNoReceivedActions()
    }

    @Test func streamFailureSchedulesReconnect() async {
        let frame = PreviewFrame(sequence: 1, jpeg: Data("jpeg".utf8))
        let store = TestStore(
            initialState: PreviewFeature.State(),
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                preview: PreviewClient(connect: {
                    AsyncThrowingStream { _ in }
                }),
                sleep: { _ in }
            ),
            reduce: PreviewFeature.reduce
        )

        await store.send(.onAppear) {
            $0.phase = .connecting
        }
        await store.send(.streamFailed(.http(503))) {
            $0.phase = .failed("HTTP 503")
            $0.reconnectAttempt = 1
        }
        await store.receive(.reconnect) {
            $0.phase = .connecting
        }
        await store.send(.frameReceived(frame)) {
            $0.phase = .streaming(frame)
            $0.reconnectAttempt = 0
        }
    }

    @Test func streamFinishedSchedulesReconnect() async {
        let frame = PreviewFrame(sequence: 1, jpeg: Data("jpeg".utf8))
        let store = TestStore(
            initialState: PreviewFeature.State(),
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                preview: PreviewClient(connect: {
                    AsyncThrowingStream { _ in }
                }),
                sleep: { _ in }
            ),
            reduce: PreviewFeature.reduce
        )

        await store.send(.onAppear) {
            $0.phase = .connecting
        }
        await store.send(.streamFinished) {
            $0.phase = .stopped
            $0.reconnectAttempt = 1
        }
        await store.receive(.reconnect) {
            $0.phase = .connecting
        }
        await store.send(.frameReceived(frame)) {
            $0.phase = .streaming(frame)
            $0.reconnectAttempt = 0
        }
    }

    @Test func reconnectNowCancelsPendingBackoff() async {
        let sleepStarted = AsyncSignal()
        let releaseSleep = AsyncSignal()
        let store = TestStore(
            initialState: PreviewFeature.State(),
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                preview: PreviewClient(connect: {
                    AsyncThrowingStream { _ in }
                }),
                sleep: { _ in
                    await sleepStarted.signal()
                    await releaseSleep.wait()
                }
            ),
            reduce: PreviewFeature.reduce
        )

        await store.send(.onAppear) {
            $0.phase = .connecting
        }
        await store.send(.streamFailed(.http(503))) {
            $0.phase = .failed("HTTP 503")
            $0.reconnectAttempt = 1
        }
        await sleepStarted.wait()
        await store.send(.reconnectNow) {
            $0.phase = .connecting
            $0.reconnectAttempt = 0
        }
        await releaseSleep.signal()
        await store.send(.stopTapped) {
            $0.phase = .stopped
        }
        await store.finishEffects()

        store.expectNoReceivedActions()
    }
}
