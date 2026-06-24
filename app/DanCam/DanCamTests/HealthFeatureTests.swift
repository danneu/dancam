import Foundation
import Testing
@testable import DanCam

@MainActor
struct HealthFeatureTests {
    @Test func onAppearLoadsHealthSuccessfully() async {
        let expected = HealthResponse(
            bootId: "boot-123",
            uptimeS: 42,
            recording: true,
            tMs: 123456789
        )
        let store = TestStore(
            initialState: HealthFeature.State.idle,
            dependencies: AppDependencies(health: HealthClient(fetch: { expected })),
            reduce: HealthFeature.reduce
        )

        await store.send(.onAppear) {
            $0 = .loading
        }
        await store.receive(.healthResponse(.success(expected))) {
            $0 = .loaded(expected)
        }
    }

    @Test func reloadMapsHealthErrorToFailedState() async {
        let store = TestStore(
            initialState: HealthFeature.State.idle,
            dependencies: AppDependencies(health: HealthClient(fetch: { throw HealthError.http(503) })),
            reduce: HealthFeature.reduce
        )

        await store.send(.reload) {
            $0 = .loading
        }
        await store.receive(.healthResponse(.failure(.http(503)))) {
            $0 = .failed("HTTP 503")
        }
    }

    @Test func cancellationErrorSendsNoActionAndLeavesLoadingState() async {
        let store = TestStore(
            initialState: HealthFeature.State.idle,
            dependencies: AppDependencies(health: HealthClient(fetch: { throw CancellationError() })),
            reduce: HealthFeature.reduce
        )

        await store.send(.reload) {
            $0 = .loading
        }
        await store.finishEffects()

        #expect(store.state == .loading)
        store.expectNoReceivedActions()
    }

    @Test func urlSessionCancellationSendsNoActionAndLeavesLoadingState() async {
        let store = TestStore(
            initialState: HealthFeature.State.idle,
            dependencies: AppDependencies(health: HealthClient(fetch: { throw URLError(.cancelled) })),
            reduce: HealthFeature.reduce
        )

        await store.send(.reload) {
            $0 = .loading
        }
        await store.finishEffects()

        #expect(store.state == .loading)
        store.expectNoReceivedActions()
    }
}
