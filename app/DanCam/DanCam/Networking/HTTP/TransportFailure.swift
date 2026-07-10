import Darwin
import Foundation
import Network

nonisolated enum TransportFailure: Error, Equatable, Sendable {
    case connectTimedOut
    case idleTimedOut
    case invalidEndpoint
    case network(reason: String)
    case unknown(debug: String)

    static func wrapping(_ error: Error) -> TransportFailure {
        if let failure = error as? TransportFailure {
            return failure
        }

        if let error = error as? NWByteStreamError {
            switch error {
            case .connectTimedOut:
                return .connectTimedOut
            case .receiveIdleTimedOut:
                return .idleTimedOut
            case .missingHost, .invalidPort:
                return .invalidEndpoint
            }
        }

        if let error = error as? NWError {
            switch error {
            case .posix(let code):
                return .network(reason: String(cString: strerror(code.rawValue)))
            case .dns:
                return .network(reason: "DNS lookup failed")
            case .tls:
                return .network(reason: "TLS error")
            default:
                return .unknown(debug: String(describing: error))
            }
        }

        return .unknown(debug: String(describing: error))
    }

    var displayMessage: String {
        switch self {
        case .connectTimedOut:
            "Can't reach the camera (timed out)."
        case .idleTimedOut:
            "Camera stopped responding."
        case .invalidEndpoint:
            "Camera address is invalid."
        case .network(let reason):
            "Can't reach the camera (\(reason))."
        case .unknown:
            "Can't reach the camera."
        }
    }

    var debugDetail: String? {
        switch self {
        case .network(let reason):
            reason
        case .unknown(let debug):
            debug
        case .connectTimedOut, .idleTimedOut, .invalidEndpoint:
            nil
        }
    }
}

extension TransportFailure: LocalizedError {
    var errorDescription: String? { displayMessage }
}
