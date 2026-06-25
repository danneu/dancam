import Foundation
import Testing
@testable import DanCam

struct HTTPResponseHeadParserTests {
    @Test(.tags(.networking))
    func parsesHeadSplitAcrossReadsAndReturnsLeftoverBody() throws {
        var parser = HTTPResponseHeadParser()

        let first = Data("HTTP/1.1 200 OK\r\nContent-T".utf8)
        let second = Data("ype: application/json\r\nX-Test: yes\r\n\r\nbody".utf8)

        #expect(try parser.append(first) == .needsMoreData)

        let result = try parser.append(second)
        guard case .complete(let head, let leftoverBody) = result else {
            Issue.record("Expected complete response head.")
            return
        }

        #expect(head.statusCode == 200)
        #expect(head.reasonPhrase == "OK")
        #expect(head.headerValue("content-type") == "application/json")
        #expect(head.headerValue("X-Test") == "yes")
        #expect(leftoverBody == Data("body".utf8))
    }

    @Test(.tags(.networking))
    func malformedStatusLineThrows() {
        var parser = HTTPResponseHeadParser()

        #expect(throws: HTTPResponseHeadError.malformedResponse) {
            _ = try parser.append(Data("nope\r\n\r\n".utf8))
        }
    }

    @Test(.tags(.networking))
    func largeLeftoverBodyDoesNotCountAgainstHeadLimit() throws {
        var parser = HTTPResponseHeadParser(maxHeadBytes: 32)
        var response = Data("HTTP/1.1 200 OK\r\n\r\n".utf8)
        response.append(Data(repeating: 7, count: 128))

        let result = try parser.append(response)

        guard case .complete(let head, let leftoverBody) = result else {
            Issue.record("Expected complete response head.")
            return
        }

        #expect(head.statusCode == 200)
        #expect(leftoverBody == Data(repeating: 7, count: 128))
    }
}
