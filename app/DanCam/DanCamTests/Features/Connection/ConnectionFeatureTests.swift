import Foundation
import Testing
@testable import DanCam

@MainActor
struct ConnectionFeatureTests {
    @Test func successFlipsToConnectedAndSchedulesPoll() async {
        let response = StatusResponse.sample(recording: false)
        let next = StatusResponse.sample(recording: true, uptimeS: 2)
        let queue = StatusFetchQueue([.success(response), .success(next)])
        let store = TestStore(
            initialState: ConnectionFeature.State(),
            dependencies: dependencies(queue: queue, sleep: { _ in }),
            reduce: ConnectionFeature.reduce
        )

        await store.send(.start)
        await store.receive(.statusResponse(.success(response))) {
            $0.connectivity = .connected
            $0.lastStatus = response
            $0.consecutiveFailures = 0
        }
        await store.receive(.poll)
    }

    @Test func staysConnectedUntilThirdFailure() async {
        let queue = StatusFetchQueue([
            .failure(.http(503)),
            .failure(.transport("lost")),
            .failure(.decoding("bad")),
        ])
        let store = TestStore(
            initialState: ConnectionFeature.State(connectivity: .connected),
            dependencies: dependencies(queue: queue, sleep: { _ in }),
            reduce: ConnectionFeature.reduce
        )

        await store.send(.poll)
        await store.receive(.statusResponse(.failure(.http(503)))) {
            $0.consecutiveFailures = 1
        }
        await store.receive(.poll)
        await store.receive(.statusResponse(.failure(.transport("lost")))) {
            $0.consecutiveFailures = 2
        }
        await store.receive(.poll)
        await store.receive(.statusResponse(.failure(.decoding("bad")))) {
            $0.connectivity = .disconnected
            $0.consecutiveFailures = 3
        }
    }

    @Test func singleSuccessResetsCounterAndRecovers() async {
        let recovered = StatusResponse.sample(recording: true)
        let queue = StatusFetchQueue([
            .failure(.http(503)),
            .failure(.http(503)),
            .failure(.http(503)),
            .success(recovered),
        ])
        let store = TestStore(
            initialState: ConnectionFeature.State(connectivity: .connected),
            dependencies: dependencies(queue: queue, sleep: { _ in }),
            reduce: ConnectionFeature.reduce
        )

        await store.send(.poll)
        await store.receive(.statusResponse(.failure(.http(503)))) {
            $0.consecutiveFailures = 1
        }
        await store.receive(.poll)
        await store.receive(.statusResponse(.failure(.http(503)))) {
            $0.consecutiveFailures = 2
        }
        await store.receive(.poll)
        await store.receive(.statusResponse(.failure(.http(503)))) {
            $0.connectivity = .disconnected
            $0.consecutiveFailures = 3
        }
        await store.receive(.poll)
        await store.receive(.statusResponse(.success(recovered))) {
            $0.connectivity = .connected
            $0.consecutiveFailures = 0
            $0.lastStatus = recovered
        }
    }

    @Test func lastStatusRetainedAcrossFailures() async {
        let response = StatusResponse.sample(recording: false)
        let queue = StatusFetchQueue([
            .success(response),
            .failure(.http(503)),
        ])
        let store = TestStore(
            initialState: ConnectionFeature.State(),
            dependencies: dependencies(queue: queue, sleep: { _ in }),
            reduce: ConnectionFeature.reduce
        )

        await store.send(.start)
        await store.receive(.statusResponse(.success(response))) {
            $0.connectivity = .connected
            $0.lastStatus = response
        }
        await store.receive(.poll)
        await store.receive(.statusResponse(.failure(.http(503)))) {
            $0.consecutiveFailures = 1
        }

        #expect(store.state.lastStatus == response)
        #expect(store.state.connectivity == .connected)
    }

    @Test func stopCancelsPollAndSendsNoFurtherActions() async {
        let started = AsyncSignal()
        let store = TestStore(
            initialState: ConnectionFeature.State(),
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                status: StatusClient(fetch: {
                    await started.signal()
                    try await Task.sleep(for: .seconds(60))
                    return StatusResponse.sample(recording: false)
                })
            ),
            reduce: ConnectionFeature.reduce
        )

        await store.send(.start)
        await started.wait()
        await store.send(.stop)
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
