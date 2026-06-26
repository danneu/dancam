import Foundation
import Testing
@testable import DanCam

@MainActor
struct StatusFeatureTests {
    @Test func onAppearFetchesStatusAndPollsAgain() async {
        let first = StatusResponse.sample(recording: false, uptimeS: 1)
        let second = StatusResponse.sample(recording: true, uptimeS: 2)
        let queue = StatusFetchQueue([.success(first), .success(second)])
        let store = TestStore(
            initialState: StatusFeature.State.idle,
            dependencies: dependencies(queue: queue, sleep: { _ in }),
            reduce: StatusFeature.reduce
        )

        await store.send(.onAppear) {
            $0 = .loading
        }
        await store.receive(.statusResponse(.success(first))) {
            $0 = .loaded(first)
        }
        await store.receive(.poll)
        await store.receive(.statusResponse(.success(second))) {
            $0 = .loaded(second)
        }
    }

    @Test func failureStillSchedulesRecoveryPoll() async {
        let recovered = StatusResponse.sample(recording: true, uptimeS: 2)
        let queue = StatusFetchQueue([.failure(.http(503)), .success(recovered)])
        let store = TestStore(
            initialState: StatusFeature.State.idle,
            dependencies: dependencies(queue: queue, sleep: { _ in }),
            reduce: StatusFeature.reduce
        )

        await store.send(.onAppear) {
            $0 = .loading
        }
        await store.receive(.statusResponse(.failure(.http(503)))) {
            $0 = .failed("HTTP 503")
        }
        await store.receive(.poll)
        await store.receive(.statusResponse(.success(recovered))) {
            $0 = .loaded(recovered)
        }
    }

    @Test func onDisappearCancelsInFlightFetch() async {
        let started = AsyncSignal()
        let store = TestStore(
            initialState: StatusFeature.State.idle,
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                status: StatusClient(fetch: {
                    await started.signal()
                    try await Task.sleep(for: .seconds(60))
                    return StatusResponse.sample(recording: false)
                })
            ),
            reduce: StatusFeature.reduce
        )

        await store.send(.onAppear) {
            $0 = .loading
        }
        await started.wait()
        await store.send(.onDisappear)
        await store.finishEffects()

        store.expectNoReceivedActions()
    }

    private func dependencies(
        queue: StatusFetchQueue,
        sleep: @escaping @Sendable (Duration) async -> Void
    ) -> AppDependencies {
        AppDependencies(
            health: HealthClient(fetch: { fatalError() }),
            status: StatusClient(fetch: { try await queue.fetch() }),
            sleep: sleep
        )
    }
}

private actor StatusFetchQueue {
    private var results: [Result<StatusResponse, StatusError>]

    init(_ results: [Result<StatusResponse, StatusError>]) {
        self.results = results
    }

    func fetch() throws -> StatusResponse {
        switch results.removeFirst() {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }
}

private extension StatusResponse {
    static func sample(recording: Bool, uptimeS: UInt64 = 1) -> StatusResponse {
        StatusResponse(
            recording: recording,
            cameraState: .running,
            bootId: "boot-123",
            uptimeS: uptimeS,
            storage: Storage(used: 100, total: 1000),
            tempC: TempC(soc: nil, sensor: nil),
            mem: nil
        )
    }
}
