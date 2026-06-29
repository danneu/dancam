import Foundation
import Network

nonisolated enum NWByteStreamError: Error, Equatable {
    case missingHost
    case invalidPort
    case connectTimedOut
}

nonisolated enum NWByteStream {
    static func open(
        url: URL,
        request: Data,
        pinning: InterfacePinning,
        connectTimeout: Duration
    ) async throws -> AsyncThrowingStream<Data, Error> {
        guard let host = url.host else {
            throw NWByteStreamError.missingHost
        }
        guard let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? defaultPort(for: url.scheme))) else {
            throw NWByteStreamError.invalidPort
        }

        let parameters = NWParameters.tcp
        if pinning == .wifi {
            parameters.requiredInterfaceType = .wifi
            parameters.prohibitedInterfaceTypes = [.cellular]
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: parameters
        )
        let lifecycle = NWConnectionLifecycle(connection)

        try await start(connection: connection, lifecycle: lifecycle, connectTimeout: connectTimeout)
        try await send(request, on: connection, lifecycle: lifecycle)

        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in
                lifecycle.cancel()
            }

            receive(from: connection, continuation: continuation)
        }
    }

    private static func defaultPort(for scheme: String?) -> Int {
        switch scheme?.lowercased() {
        case "https":
            443
        default:
            80
        }
    }

    private static func start(
        connection: NWConnection,
        lifecycle: NWConnectionLifecycle,
        connectTimeout: Duration
    ) async throws {
        let queue = DispatchQueue(label: "com.danneu.dancam.nw-byte-stream")

        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resolution = NWConnectionStartResolution(
                    connection: connection,
                    continuation: continuation
                )

                let deadline = DispatchWorkItem {
                    lifecycle.cancel()
                    resolution.finish(.failure(NWByteStreamError.connectTimedOut))
                }
                resolution.setDeadline(deadline)
                queue.asyncAfter(
                    deadline: .now() + dispatchInterval(for: connectTimeout),
                    execute: deadline
                )

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        resolution.finish(.success(()))
                    case .failed(let error):
                        resolution.finish(.failure(error))
                    case .cancelled:
                        resolution.finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }

                do {
                    try lifecycle.start(on: queue)
                } catch {
                    queue.async {
                        resolution.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            lifecycle.cancel()
        }
    }

    private static func dispatchInterval(for duration: Duration) -> DispatchTimeInterval {
        let components = duration.components
        let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
        let attosecondMilliseconds = components.attoseconds / attosecondsPerMillisecond
        let roundedRemainder: Int64 = components.attoseconds % attosecondsPerMillisecond == 0 ? 0 : 1
        let totalMilliseconds = components.seconds * 1_000 + attosecondMilliseconds + roundedRemainder
        let cappedMilliseconds = min(max(totalMilliseconds, 1), Int64(Int.max))
        return .milliseconds(Int(cappedMilliseconds))
    }

    private static func send(
        _ data: Data,
        on connection: NWConnection,
        lifecycle: NWConnectionLifecycle
    ) async throws {
        do {
            try Task.checkCancellation()
        } catch {
            lifecycle.cancel()
            throw error
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        } onCancel: {
            lifecycle.cancel()
        }
    }

    private static func receive(
        from connection: NWConnection,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, data.isEmpty == false {
                continuation.yield(data)
            }

            if let error {
                continuation.finish(throwing: error)
            } else if isComplete {
                continuation.finish()
            } else {
                receive(from: connection, continuation: continuation)
            }
        }
    }
}

// Swift cannot express this queue affinity: setDeadline runs before start, and
// finish is called only on the connection queue.
nonisolated private final class NWConnectionStartResolution: @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Void, Error>
    private var didResume = false
    private var deadlineWorkItem: DispatchWorkItem?

    init(connection: NWConnection, continuation: CheckedContinuation<Void, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    func setDeadline(_ deadlineWorkItem: DispatchWorkItem) {
        self.deadlineWorkItem = deadlineWorkItem
    }

    func finish(_ result: Result<Void, Error>) {
        guard didResume == false else { return }
        didResume = true
        connection.stateUpdateHandler = nil
        deadlineWorkItem?.cancel()

        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

nonisolated private final class NWConnectionLifecycle: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var isStarted = false
    private var isCancelled = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start(on queue: DispatchQueue) throws {
        lock.lock()
        defer { lock.unlock() }

        if isCancelled {
            throw CancellationError()
        }

        isStarted = true
        connection.start(queue: queue)
    }

    func cancel() {
        let shouldCancel: Bool

        lock.lock()
        if isCancelled {
            shouldCancel = false
        } else {
            isCancelled = true
            shouldCancel = isStarted
        }
        lock.unlock()

        if shouldCancel {
            connection.cancel()
        }
    }
}
