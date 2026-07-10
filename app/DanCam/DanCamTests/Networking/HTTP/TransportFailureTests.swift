import Foundation
import Network
import Testing
@testable import DanCam

struct TransportFailureTests {
    @Test(.tags(.networking), arguments: [
        (NWByteStreamError.connectTimedOut, TransportFailure.connectTimedOut),
        (NWByteStreamError.receiveIdleTimedOut, TransportFailure.idleTimedOut),
        (NWByteStreamError.missingHost, TransportFailure.invalidEndpoint),
        (NWByteStreamError.invalidPort, TransportFailure.invalidEndpoint),
    ])
    func wrappingMapsByteStreamErrors(
        error: NWByteStreamError,
        expected: TransportFailure
    ) {
        #expect(TransportFailure.wrapping(error) == expected)
    }

    @Test(.tags(.networking))
    func wrappingMapsCuratedNetworkErrors() {
        #expect(
            TransportFailure.wrapping(NWError.posix(.ECONNREFUSED))
                == .network(reason: "Connection refused")
        )
        #expect(
            TransportFailure.wrapping(NWError.dns(-65_537))
                == .network(reason: "DNS lookup failed")
        )
        #expect(
            TransportFailure.wrapping(NWError.tls(-9_807))
                == .network(reason: "TLS error")
        )
    }

    @Test(.tags(.networking))
    func wrappingPassesThroughExistingFailure() {
        let failure = TransportFailure.network(reason: "No route to host")

        #expect(TransportFailure.wrapping(failure) == failure)
    }

    @Test(.tags(.networking))
    func wrappingUnknownNWErrorUsesGenericCopy() {
        let failure = TransportFailure.wrapping(NWError.wifiAware(1))

        guard case .unknown = failure else {
            Issue.record("Expected the unclassified NWError to map to .unknown.")
            return
        }
        #expect(failure.displayMessage == "Can't reach the camera.")
    }

    @Test(.tags(.networking), arguments: [
        (TransportFailure.connectTimedOut, "Can't reach the camera (timed out)."),
        (TransportFailure.idleTimedOut, "Camera stopped responding."),
        (TransportFailure.invalidEndpoint, "Camera address is invalid."),
        (
            TransportFailure.network(reason: "Connection refused"),
            "Can't reach the camera (Connection refused)."
        ),
        (TransportFailure.unknown(debug: "raw detail"), "Can't reach the camera."),
    ])
    func displayMessageIsHumanReadable(
        failure: TransportFailure,
        expected: String
    ) {
        #expect(failure.displayMessage == expected)
        #expect(failure.localizedDescription == expected)
    }

    @Test(.tags(.networking))
    func arbitraryNSErrorNeverLeaksBridgeSludgeIntoDisplayCopy() {
        let failure = TransportFailure.wrapping(
            NSError(domain: "TransportFailureTests", code: 42)
        )

        guard case .unknown = failure else {
            Issue.record("Expected an arbitrary NSError to map to .unknown.")
            return
        }
        #expect(failure.displayMessage == "Can't reach the camera.")
        #expect(failure.displayMessage.contains("Error Domain") == false)
        #expect(failure.displayMessage.contains("Code=") == false)
    }

    @Test(.tags(.networking))
    func debugDetailKeepsOnlyCarriedDiagnosticContext() {
        #expect(TransportFailure.connectTimedOut.debugDetail == nil)
        #expect(TransportFailure.idleTimedOut.debugDetail == nil)
        #expect(TransportFailure.invalidEndpoint.debugDetail == nil)
        #expect(
            TransportFailure.network(reason: "Connection refused").debugDetail
                == "Connection refused"
        )
        #expect(TransportFailure.unknown(debug: "raw detail").debugDetail == "raw detail")
    }
}
