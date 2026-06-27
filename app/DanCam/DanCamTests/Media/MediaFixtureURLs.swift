import Foundation
import Testing

enum MediaFixtureURLs {
    static func seg00000TS() throws -> URL {
        let bundle = Bundle(for: MediaFixtureBundleToken.self)

        if let nestedURL = bundle.url(
            forResource: "seg_00000",
            withExtension: "ts",
            subdirectory: "Media/Fixtures"
        ) {
            return nestedURL
        }

        if let bundledURL = bundle.url(forResource: "seg_00000", withExtension: "ts") {
            return bundledURL
        }

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures")
            .appending(path: "seg_00000.ts")
        return try #require(FileManager.default.fileExists(atPath: sourceURL.path) ? sourceURL : nil)
    }
}

private final class MediaFixtureBundleToken {}
