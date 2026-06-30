import Foundation

enum RecordingFeature {
    enum State: Equatable {
        case unknown
        case idle
        case starting
        case recording
        case stopping
        case failed(String)
    }

    enum Action: Equatable {
        case startTapped
        case stopTapped
        case recordingResponse(Result<Bool, RecordingError>)
        case recorderPhaseObserved(RecorderPhase)
    }

    static func reduce(
        state: inout State,
        action: Action,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        switch action {
        case .startTapped:
            state = .starting
            return .run(id: "recording", cancelInFlight: true) { send in
                do {
                    try await dependencies.recording.start()
                    guard Task.isCancelled == false else { return }
                    await send(.recordingResponse(.success(true)))
                } catch is CancellationError {
                    return
                } catch let error as URLError where error.code == .cancelled {
                    return
                } catch let error as RecordingError {
                    guard Task.isCancelled == false else { return }
                    await send(.recordingResponse(.failure(error)))
                } catch {
                    guard Task.isCancelled == false else { return }
                    await send(.recordingResponse(.failure(.transport(error.localizedDescription))))
                }
            }

        case .stopTapped:
            state = .stopping
            return .run(id: "recording", cancelInFlight: true) { send in
                do {
                    try await dependencies.recording.stop()
                    guard Task.isCancelled == false else { return }
                    await send(.recordingResponse(.success(false)))
                } catch is CancellationError {
                    return
                } catch let error as URLError where error.code == .cancelled {
                    return
                } catch let error as RecordingError {
                    guard Task.isCancelled == false else { return }
                    await send(.recordingResponse(.failure(error)))
                } catch {
                    guard Task.isCancelled == false else { return }
                    await send(.recordingResponse(.failure(.transport(error.localizedDescription))))
                }
            }

        case .recordingResponse(.success(true)):
            state = .recording
            return .none

        case .recordingResponse(.success(false)):
            state = .idle
            return .none

        case .recordingResponse(.failure(let error)):
            state = .failed(error.displayMessage)
            return .none

        case .recorderPhaseObserved(let phase):
            switch state {
            case .starting:
                switch phase {
                case .recording:
                    state = .recording
                case .error:
                    state = .failed("Recorder failed")
                case .idle, .starting, .stopping:
                    break
                }
            case .stopping:
                switch phase {
                case .idle:
                    state = .idle
                case .error:
                    state = .failed("Recorder failed")
                case .starting, .recording, .stopping:
                    break
                }
            case .unknown, .idle, .recording, .failed:
                switch phase {
                case .idle:
                    state = .idle
                case .starting:
                    state = .starting
                case .recording:
                    state = .recording
                case .stopping:
                    state = .stopping
                case .error:
                    state = .failed("Recorder failed")
                }
            }
            return .none
        }
    }
}
