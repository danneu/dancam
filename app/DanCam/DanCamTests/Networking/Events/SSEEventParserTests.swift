import Foundation
import Testing
@testable import DanCam

struct SSEEventParserTests {
    @Test(.tags(.networking))
    func parsesSingleDataFrame() {
        var parser = SSEEventParser()

        let events = parser.append(Data("id: 1\ndata: {\"type\":\"heartbeat\",\"t_ms\":1}\n\n".utf8))

        #expect(events == [Data("{\"type\":\"heartbeat\",\"t_ms\":1}".utf8)])
    }

    @Test(.tags(.networking))
    func ignoresCommentsAndNonDataFields() {
        var parser = SSEEventParser()

        let events = parser.append(Data(": comment\nevent: ignored\nid: 2\ndata: payload\n\n".utf8))

        #expect(events == [Data("payload".utf8)])
    }

    @Test(.tags(.networking))
    func joinsMultiLineDataWithNewline() {
        var parser = SSEEventParser()

        let events = parser.append(Data("data: one\r\ndata: two\r\n\r\n".utf8))

        #expect(events == [Data("one\ntwo".utf8)])
    }

    @Test(.tags(.networking))
    func frameCanBeSplitAcrossChunks() {
        var parser = SSEEventParser()

        #expect(parser.append(Data("data: par".utf8)).isEmpty)
        #expect(parser.append(Data("tial\n\n".utf8)) == [Data("partial".utf8)])
    }

    @Test(.tags(.networking))
    func loneCarriageReturnTerminatesLine() {
        var parser = SSEEventParser()

        let events = parser.append(Data("data: payload\r\r".utf8))

        #expect(events == [Data("payload".utf8)])
    }
}
