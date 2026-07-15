import Darwin
import Foundation

nonisolated struct SharePreparationRequest: Sendable {
    var sourceURL: URL
    var suggestedFilename: String
}

nonisolated struct PreparedShareArtifact: Sendable {
    var url: URL
    var ownedDirectory: URL?
}

nonisolated enum SharePreparationError: Error, Equatable, Sendable {
    case sourceUnavailable
}

nonisolated struct ShareArtifactPreparer: Sendable {
    typealias CloneOperation = @Sendable (URL, URL) async throws -> Void

    var prepare: @Sendable (SharePreparationRequest) async throws -> PreparedShareArtifact

    static func live(
        stagingRoot: URL = FileManager.default.temporaryDirectory
            .appending(path: "video-share", directoryHint: .isDirectory),
        clone: @escaping CloneOperation = cloneFile
    ) -> Self {
        Self { request in
            try await prepareLive(request, stagingRoot: stagingRoot, clone: clone)
        }
    }

    static let unavailable = Self { _ in
        throw SharePreparationError.sourceUnavailable
    }

    @concurrent
    private static func prepareLive(
        _ request: SharePreparationRequest,
        stagingRoot: URL,
        clone: CloneOperation
    ) async throws -> PreparedShareArtifact {
        try Task.checkCancellation()
        guard isRegularFile(request.sourceURL) else {
            throw SharePreparationError.sourceUnavailable
        }

        let directory = stagingRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let destination = directory.appending(path: request.suggestedFilename)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Task.checkCancellation()
            try await clone(request.sourceURL, destination)
            try Task.checkCancellation()
            return PreparedShareArtifact(url: destination, ownedDirectory: directory)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: directory)
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            guard isRegularFile(request.sourceURL) else {
                throw SharePreparationError.sourceUnavailable
            }
            return PreparedShareArtifact(url: request.sourceURL, ownedDirectory: nil)
        }
    }

    private static func cloneFile(source: URL, destination: URL) async throws {
        guard Darwin.clonefile(source.path, destination.path, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue == false
    }
}
