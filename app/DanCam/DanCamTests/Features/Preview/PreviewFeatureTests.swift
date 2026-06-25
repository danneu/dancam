import Foundation
import Testing
@testable import DanCam

@MainActor
struct PreviewFeatureTests {
    @Test func onAppearConnectsAndStreamsFrame() async {
        let frame = PreviewFrame(sequence: 0, jpeg: Data("jpeg".utf8))
        let store = TestStore(
            initialState: PreviewFeature.State.idle,
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError("Health should not be called.") }),
                preview: PreviewClient(connect: {
                    AsyncThrowingStream { continuation in
                        continuation.yield(frame)
                        continuation.finish()
                    }
                })
            ),
            reduce: PreviewFeature.reduce
        )

        await store.send(.onAppear) {
            $0 = .connecting
        }
        await store.receive(.frameReceived(frame)) {
            $0 = .streaming(frame)
        }
        await store.receive(.streamFinished) {
            $0 = .stopped
        }
    }

    @Test func laterFramesReplaceEarlierFrames() async {
        let f0 = PreviewFrame(sequence: 0, jpeg: Data("zero".utf8))
        let f1 = PreviewFrame(sequence: 1, jpeg: Data("one".utf8))
        let store = TestStore(
            initialState: PreviewFeature.State.streaming(f0),
            dependencies: AppDependencies(health: HealthClient(fetch: { fatalError() })),
            reduce: PreviewFeature.reduce
        )

        await store.send(.frameReceived(f1)) {
            $0 = .streaming(f1)
        }
    }

    @Test func streamFailureMapsToFailedState() async {
        let store = TestStore(
            initialState: PreviewFeature.State.idle,
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                preview: PreviewClient(connect: {
                    AsyncThrowingStream { continuation in
                        continuation.finish(throwing: PreviewError.http(503))
                    }
                })
            ),
            reduce: PreviewFeature.reduce
        )

        await store.send(.startTapped) {
            $0 = .connecting
        }
        await store.receive(.streamFailed(.http(503))) {
            $0 = .failed("HTTP 503")
        }
    }

    @Test func stopTappedCancelsStreamAndLeavesStoppedState() async {
        let store = TestStore(
            initialState: PreviewFeature.State.idle,
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                preview: PreviewClient(connect: {
                    AsyncThrowingStream { _ in }
                })
            ),
            reduce: PreviewFeature.reduce
        )

        await store.send(.onAppear) {
            $0 = .connecting
        }
        await store.send(.stopTapped) {
            $0 = .stopped
        }
        await store.finishEffects()
        store.expectNoReceivedActions()
    }

    @Test func cancellationErrorSendsNoFailureAction() async {
        let store = TestStore(
            initialState: PreviewFeature.State.idle,
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
            $0 = .connecting
        }
        await store.finishEffects()

        #expect(store.state == .connecting)
        store.expectNoReceivedActions()
    }
}
