import Foundation

enum PreviewFeature {
    enum State: Equatable {
        case idle
        case connecting
        case streaming(PreviewFrame)
        case stopped
        case failed(String)
    }

    enum Action: Equatable {
        case onAppear
        case startTapped
        case onDisappear
        case stopTapped
        case frameReceived(PreviewFrame)
        case streamFinished
        case streamFailed(PreviewError)
    }

    static func reduce(
        state: inout State,
        action: Action,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        switch action {
        case .onAppear, .startTapped:
            state = .connecting
            return .run(id: "preview", cancelInFlight: true) { send in
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

        case .onDisappear, .stopTapped:
            state = .stopped
            return .cancel(id: "preview")

        case .frameReceived(let frame):
            state = .streaming(frame)
            return .none

        case .streamFinished:
            state = .stopped
            return .none

        case .streamFailed(let error):
            state = .failed(error.displayMessage)
            return .none
        }
    }
}
