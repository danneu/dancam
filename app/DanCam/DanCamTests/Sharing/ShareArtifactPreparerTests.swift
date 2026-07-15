import Foundation
import Testing
@testable import DanCam

struct ShareArtifactPreparerTests {
    @Test func preparesFriendlyCloneWithIndependentSourceAndDestination() async throws {
        let root = temporaryDirectory()
        let source = root.appending(path: "source.mp4")
        let staging = root.appending(path: "staging", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x01, 0x02]).write(to: source)

        let artifact = try await ShareArtifactPreparer.live(stagingRoot: staging).prepare(
            SharePreparationRequest(sourceURL: source, suggestedFilename: "Friendly Video.mp4")
        )
        let directory = try #require(artifact.ownedDirectory)

        #expect(artifact.url.lastPathComponent == "Friendly Video.mp4")
        #expect(try Data(contentsOf: artifact.url) == Data([0x01, 0x02]))

        try Data([0x03]).write(to: source)
        #expect(try Data(contentsOf: artifact.url) == Data([0x01, 0x02]))
        try Data([0x04]).write(to: artifact.url)
        #expect(try Data(contentsOf: artifact.url) == Data([0x04]))
        #expect(try Data(contentsOf: source) == Data([0x03]))
        try FileManager.default.removeItem(at: source)
        #expect(try Data(contentsOf: artifact.url) == Data([0x04]))
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func invalidStagingFallsBackToRegularSource() async throws {
        let root = temporaryDirectory()
        let source = root.appending(path: "source.mp4")
        let blocker = root.appending(path: "blocker")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x01]).write(to: source)
        try Data().write(to: blocker)

        let artifact = try await ShareArtifactPreparer.live(stagingRoot: blocker).prepare(
            SharePreparationRequest(sourceURL: source, suggestedFilename: "Friendly.mp4")
        )

        #expect(artifact.url == source)
        #expect(artifact.ownedDirectory == nil)
    }

    @Test(arguments: [MissingSourceKind.missing, .directory])
    func nonFileSourceIsUnavailable(kind: MissingSourceKind) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source")
        if kind == .directory {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        }

        await #expect(throws: SharePreparationError.sourceUnavailable) {
            try await ShareArtifactPreparer.live(stagingRoot: root.appending(path: "staging")).prepare(
                SharePreparationRequest(sourceURL: source, suggestedFilename: "Friendly.mp4")
            )
        }
    }

    @Test func cancellationAfterDirectoryCreationRemovesPartialDirectory() async throws {
        let root = temporaryDirectory()
        let source = root.appending(path: "source.mp4")
        let staging = root.appending(path: "staging", directoryHint: .isDirectory)
        let cloneStarted = AsyncSignal()
        let allowClone = AsyncSignal()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x01]).write(to: source)

        let preparer = ShareArtifactPreparer.live(stagingRoot: staging) { source, destination in
            await cloneStarted.signal()
            await allowClone.wait()
            try Data(contentsOf: source).write(to: destination)
        }
        let task = Task {
            try await preparer.prepare(
                SharePreparationRequest(sourceURL: source, suggestedFilename: "Friendly.mp4")
            )
        }

        await cloneStarted.wait()
        task.cancel()
        await allowClone.signal()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        #expect(children.isEmpty)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "dancam-share-preparer-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

enum MissingSourceKind: Sendable {
    case missing
    case directory
}
