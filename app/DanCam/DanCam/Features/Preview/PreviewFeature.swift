import Foundation

enum PreviewFeature {
    struct State: Equatable {
        enum Phase: Equatable {
            case idle
            case connecting
            case streaming(PreviewFrame)
            case stopped
            case failed(String)
        }

        var phase: Phase = .idle
        var reconnectAttempt = 0
        var streamGeneration = 0
    }

    enum Action: Equatable {
        case onAppear
        case startTapped
        case onDisappear
        case stopTapped
        case reconnectNow
        case reconnect
        case frameReceived(PreviewFrame)
        case streamFinished
        case streamFailed(PreviewError)
    }

    private static let streamID = "preview"

    static func reduce(
        state: inout State,
        action: Action,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        switch action {
        case .onAppear, .startTapped, .reconnectNow:
            state.phase = .connecting
            state.reconnectAttempt = 0
            state.streamGeneration += 1
            return connectEffect(dependencies: dependencies)

        case .reconnect:
            state.phase = .connecting
            state.streamGeneration += 1
            return connectEffect(dependencies: dependencies)

        case .onDisappear, .stopTapped:
            state.phase = .stopped
            return .cancel(id: streamID)

        case .frameReceived(let frame):
            state.phase = .streaming(frame)
            state.reconnectAttempt = 0
            return .none

        case .streamFinished:
            state.phase = .stopped
            state.reconnectAttempt += 1
            return scheduleReconnect(attempt: state.reconnectAttempt, dependencies: dependencies)

        case .streamFailed(let error):
            state.phase = .failed(error.displayMessage)
            state.reconnectAttempt += 1
            return scheduleReconnect(attempt: state.reconnectAttempt, dependencies: dependencies)
        }
    }

    private static func connectEffect(dependencies: AppDependencies) -> Effect<Action> {
        .run(id: streamID, cancelInFlight: true) { send in
            do {
                for try await frame in dependencies.preview.connect() {
                    guard Task.isCancelled == false else { return }
                    await send(.frameReceived(frame))
                }

                guard Task.isCancelled == false else { return }
                await send(.streamFinished)
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .cancelled {
                return
            } catch let error as PreviewError {
                guard Task.isCancelled == false else { return }
                await send(.streamFailed(error))
            } catch {
                guard Task.isCancelled == false else { return }
                await send(.streamFailed(.connectionFailed(error.localizedDescription)))
            }
        }
    }

    private static func scheduleReconnect(
        attempt: Int,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        .run(id: streamID, cancelInFlight: true) { send in
            await dependencies.sleep(backoff(for: attempt))
            guard Task.isCancelled == false else { return }
            await send(.reconnect)
        }
    }

    private static func backoff(for attempt: Int) -> Duration {
        let cappedExponent = max(0, min(attempt - 1, 3))
        return .seconds(1 << cappedExponent)
    }
}
