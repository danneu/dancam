import Foundation
import Testing
@testable import DanCam

struct HTTPRequestEncoderTests {
    @Test(.tags(.networking))
    func encodesGetWithHostPortAndHeaders() throws {
        let url = try #require(URL(string: "http://10.42.0.1:8080/v1/health?fresh=1"))

        let request = try HTTPRequestEncoder.get(
            url: url,
            extraHeaders: [("Connection", "close")]
        )

        #expect(String(decoding: request, as: UTF8.self) == """
        GET /v1/health?fresh=1 HTTP/1.1\r
        Host: 10.42.0.1:8080\r
        Connection: close\r
        \r

        """)
    }

    @Test(.tags(.networking))
    func omitsDefaultHTTPPortFromHostHeader() throws {
        let url = try #require(URL(string: "http://dancam.local/v1/health"))

        let request = try HTTPRequestEncoder.get(url: url)

        #expect(String(decoding: request, as: UTF8.self).contains("Host: dancam.local\r\n"))
    }
}
