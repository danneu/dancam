import Foundation

actor AsyncSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isSignaled { return }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        isSignaled = true
        let currentWaiters = waiters
        waiters.removeAll()

        for waiter in currentWaiters {
            waiter.resume()
        }
    }

    func hasSignaled() -> Bool {
        isSignaled
    }
}

actor RequestCapture {
    private var requests: [Data] = []

    func append(_ request: Data) {
        requests.append(request)
    }

    func values() -> [Data] {
        requests
    }
}

enum AsyncStreamHelpers {
    static func byteStream(_ chunks: [Data]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    static func failingByteStream(_ error: Error) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }

    /// Yields the chunks, then finishes by throwing -- a mid-transfer link drop.
    static func droppingByteStream(
        _ chunks: [Data],
        error: Error = URLError(.networkConnectionLost)
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish(throwing: error)
        }
    }
}
