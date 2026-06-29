import Foundation
import Network

nonisolated enum NWByteStreamError: Error, Equatable {
    case missingHost
    case invalidPort
}

nonisolated enum NWByteStream {
    static func open(
        url: URL,
        request: Data,
        pinning: InterfacePinning
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

        try await start(connection: connection, lifecycle: lifecycle)
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

    private static func start(connection: NWConnection, lifecycle: NWConnectionLifecycle) async throws {
        let queue = DispatchQueue(label: "com.danneu.dancam.nw-byte-stream")

        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.stateUpdateHandler = nil
                        continuation.resume()
                    case .failed(let error):
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: error)
                    case .cancelled:
                        connection.stateUpdateHandler = nil
                        continuation.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }

                do {
                    try lifecycle.start(on: queue)
                } catch {
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            lifecycle.cancel()
        }
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
