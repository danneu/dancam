import Foundation
import Testing
@testable import DanCam

struct LogExporterTests {
    @Test func formatLogLinesRendersDiagnosticTokensInOrder() throws {
        let output = formatLogLines([
            LogLine(
                date: Date(timeIntervalSince1970: 0),
                category: "pull",
                level: .notice,
                composedMessage: "clip_id=42 phase=pull bytes=12"
            ),
            LogLine(
                date: Date(timeIntervalSince1970: 1),
                category: "remux",
                level: .error,
                composedMessage: "clip_id=42 phase=remux error=invalid"
            ),
        ])

        #expect(output.contains("[pull]"))
        #expect(output.contains("[notice]"))
        #expect(output.contains("clip_id=42 phase=pull"))
        #expect(output.contains("[remux]"))
        #expect(output.contains("[error]"))
        #expect(output.contains("phase=remux error=invalid"))

        let category = try #require(output.range(of: "[pull]"))
        let level = try #require(output.range(of: "[notice]"))
        let message = try #require(output.range(of: "clip_id=42 phase=pull"))
        #expect(category.lowerBound < level.lowerBound)
        #expect(level.lowerBound < message.lowerBound)
    }
}
