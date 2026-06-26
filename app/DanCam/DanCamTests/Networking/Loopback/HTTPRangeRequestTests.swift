import Foundation
import Testing
@testable import DanCam

struct HTTPRangeRequestTests {
    @Test(.tags(.networking))
    func parsesRequestLineAndHeaders() throws {
        let request = """
        GET /segment.ts HTTP/1.1\r
        Host: 127.0.0.1:49152\r
        Range: bytes=0-1\r
        \r

        """

        let line = try #require(HTTPRangeRequest.requestLine(from: request))

        #expect(line == HTTPRequestLine(method: "GET", path: "/segment.ts"))
        #expect(HTTPRangeRequest.headerValue("range", in: request) == "bytes=0-1")
        #expect(HTTPRangeRequest.headerValue("missing", in: request) == nil)
    }

    @Test(.tags(.networking))
    func resolvesByteRangesAgainstTotalSize() {
        #expect(HTTPRangeRequest.resolveRange(nil, totalSize: 100) == .full)
        #expect(
            HTTPRangeRequest.resolveRange("bytes=0-1", totalSize: 100)
                == .partial(HTTPByteRange(start: 0, end: 1))
        )
        #expect(
            HTTPRangeRequest.resolveRange("bytes=10-", totalSize: 100)
                == .partial(HTTPByteRange(start: 10, end: 99))
        )
        #expect(
            HTTPRangeRequest.resolveRange("bytes=-10", totalSize: 100)
                == .partial(HTTPByteRange(start: 90, end: 99))
        )
        #expect(HTTPRangeRequest.resolveRange("bytes=100-", totalSize: 100) == .unsatisfiable)
    }

    @Test(.tags(.networking))
    func responseHeadsCarryLengthsRangesAndClose() {
        let range = HTTPByteRange(start: 10, end: 19)

        #expect(String(decoding: HTTPRangeRequest.okHead(
            contentLength: 30,
            contentType: "video/mp2t"
        ), as: UTF8.self) == """
        HTTP/1.1 200 OK\r
        Content-Type: video/mp2t\r
        Content-Length: 30\r
        Accept-Ranges: bytes\r
        Connection: close\r
        \r

        """)

        #expect(String(decoding: HTTPRangeRequest.partialContentHead(
            range: range,
            totalSize: 100,
            contentType: "video/mp2t"
        ), as: UTF8.self) == """
        HTTP/1.1 206 Partial Content\r
        Content-Type: video/mp2t\r
        Content-Length: 10\r
        Content-Range: bytes 10-19/100\r
        Accept-Ranges: bytes\r
        Connection: close\r
        \r

        """)

        #expect(String(decoding: HTTPRangeRequest.rangeNotSatisfiableHead(
            totalSize: 100
        ), as: UTF8.self) == """
        HTTP/1.1 416 Range Not Satisfiable\r
        Content-Length: 0\r
        Content-Range: bytes */100\r
        Connection: close\r
        \r

        """)
    }
}
