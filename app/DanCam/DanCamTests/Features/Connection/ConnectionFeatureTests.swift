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

    @Test func hungFetchFlipsToDisconnected() async {
        let fetchStarted = AsyncSignal()
        let store = TestStore(
            initialState: ConnectionFeature.State(connectivity: .connected),
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                status: StatusClient(fetch: {
                    await fetchStarted.signal()
                    try await Task.sleep(for: .seconds(3600))
                    return StatusResponse.sample(recording: false)
                }),
                sleep: { _ in },
                statusFetchTimeout: {
                    await fetchStarted.wait()
                }
            ),
            reduce: ConnectionFeature.reduce
        )

        await store.send(.poll)
        await store.receive(.statusResponse(.failure(.timedOut))) {
            $0.consecutiveFailures = 1
        }
        await store.receive(.poll)
        await store.receive(.statusResponse(.failure(.timedOut))) {
            $0.consecutiveFailures = 2
        }
        await store.receive(.poll)
        await store.receive(.statusResponse(.failure(.timedOut))) {
            $0.connectivity = .disconnected
            $0.consecutiveFailures = 3
        }
    }

    @Test func stopCancelsFetchAndTimeoutAndSendsNoFurtherActions() async {
        let fetchStarted = AsyncSignal()
        let timeoutStarted = AsyncSignal()
        let fetchCancelled = AsyncSignal()
        let timeoutCancelled = AsyncSignal()
        let store = TestStore(
            initialState: ConnectionFeature.State(),
            dependencies: AppDependencies(
                health: HealthClient(fetch: { fatalError() }),
                status: StatusClient(fetch: {
                    await fetchStarted.signal()
                    do {
                        try await Task.sleep(for: .seconds(3600))
                        return StatusResponse.sample(recording: false)
                    } catch {
                        await fetchCancelled.signal()
                        throw error
                    }
                }),
                statusFetchTimeout: {
                    await timeoutStarted.signal()
                    do {
                        try await Task.sleep(for: .seconds(3600))
                    } catch {
                        await timeoutCancelled.signal()
                        throw error
                    }
                }
            ),
            reduce: ConnectionFeature.reduce
        )

        await store.send(.start)
        await fetchStarted.wait()
        await timeoutStarted.wait()
        await store.send(.stop)
        await fetchCancelled.wait()
        await timeoutCancelled.wait()

        store.expectNoReceivedActions()
    }

    private func dependencies(
        queue: StatusFetchQueue,
        sleep: @escaping @Sendable (Duration) async -> Void,
        statusFetchTimeout: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(3600))
        }
    ) -> AppDependencies {
        AppDependencies(
            health: HealthClient(fetch: { fatalError() }),
            status: StatusClient(fetch: { try await queue.fetch() }),
            sleep: sleep,
            statusFetchTimeout: statusFetchTimeout
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
