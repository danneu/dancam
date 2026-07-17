import Foundation
import UIKit

nonisolated enum IncidentArtifactKind: String, Equatable, Sendable {
    case mp4
    case ts
}

nonisolated struct IncidentArtifactInstaller: Sendable {
    var install: @Sendable (
        _ sourceURL: URL,
        _ kind: IncidentArtifactKind,
        _ seq: Int,
        _ incidentIDs: [UUID]
    ) async throws -> [UUID: UInt64]
    var writeThumbnail: @Sendable (
        _ sourceURL: URL,
        _ kind: IncidentArtifactKind,
        _ seq: Int,
        _ incidentIDs: [UUID]
    ) async -> Void
    var writeThumbnailData: @Sendable (_ jpeg: Data, _ incidentIDs: [UUID]) async -> Void

    init(
        install: @escaping @Sendable (URL, IncidentArtifactKind, Int, [UUID]) async throws -> [UUID: UInt64],
        writeThumbnail: @escaping @Sendable (URL, IncidentArtifactKind, Int, [UUID]) async -> Void,
        writeThumbnailData: @escaping @Sendable (Data, [UUID]) async -> Void = { _, _ in }
    ) {
        self.install = install
        self.writeThumbnail = writeThumbnail
        self.writeThumbnailData = writeThumbnailData
    }

    static func live(directoryURL: @escaping @Sendable (UUID) -> URL) -> IncidentArtifactInstaller {
        IncidentArtifactInstaller(
            install: { sourceURL, kind, seq, incidentIDs in
                try await installArtifacts(
                    sourceURL: sourceURL,
                    kind: kind,
                    seq: seq,
                    incidentIDs: incidentIDs,
                    directoryURL: directoryURL
                )
            },
            writeThumbnail: { sourceURL, kind, seq, incidentIDs in
                await writeThumbnails(
                    sourceURL: sourceURL,
                    kind: kind,
                    seq: seq,
                    incidentIDs: incidentIDs,
                    directoryURL: directoryURL
                )
            },
            writeThumbnailData: { jpeg, incidentIDs in
                await writeThumbnailData(jpeg, incidentIDs: incidentIDs, directoryURL: directoryURL)
            }
        )
    }

    static let noop = IncidentArtifactInstaller(
        install: { sourceURL, _, _, incidentIDs in
            let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
            let bytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            return Dictionary(uniqueKeysWithValues: incidentIDs.map { ($0, bytes) })
        },
        writeThumbnail: { _, _, _, _ in },
        writeThumbnailData: { _, _ in }
    )

    @concurrent
    private static func installArtifacts(
        sourceURL: URL,
        kind: IncidentArtifactKind,
        seq: Int,
        incidentIDs: [UUID],
        directoryURL: @escaping @Sendable (UUID) -> URL
    ) async throws -> [UUID: UInt64] {
        let fileManager = FileManager.default
        var installed: [UUID: UInt64] = [:]

        for incidentID in incidentIDs {
            try Task.checkCancellation()
            let directory = directoryURL(incidentID)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let stem = String(format: "seg_%05d", seq)
            let destination = directory.appending(path: "\(stem).\(kind.rawValue)")

            if fileManager.fileExists(atPath: destination.path) == false {
                let staging = directory.appending(path: "\(stem).\(kind.rawValue).part")
                try? fileManager.removeItem(at: staging)
                do {
                    try fileManager.copyItem(at: sourceURL, to: staging)
                    try fileManager.moveItem(at: staging, to: destination)
                } catch {
                    try? fileManager.removeItem(at: staging)
                    throw error
                }
            }

            let attributes = try fileManager.attributesOfItem(atPath: destination.path)
            installed[incidentID] = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        }
        return installed
    }

    @concurrent
    private static func writeThumbnails(
        sourceURL: URL,
        kind: IncidentArtifactKind,
        seq: Int,
        incidentIDs: [UUID],
        directoryURL: @escaping @Sendable (UUID) -> URL
    ) async {
        guard incidentIDs.isEmpty == false else { return }

        do {
            let image: UIImage
            switch kind {
            case .ts:
                let handle = try FileHandle(forReadingFrom: sourceURL)
                defer { try? handle.close() }
                let prefix = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
                image = try await ThumbnailDecoder.firstFrameImage(
                    fromTSPrefix: prefix,
                    clipID: seq,
                    maxPixelSize: CGSize(width: 320, height: 180)
                )
            case .mp4:
                image = try await ThumbnailDecoder.firstFrameImage(
                    fromMP4: sourceURL,
                    maxPixelSize: CGSize(width: 320, height: 180)
                )
            }
            guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return }

            for incidentID in incidentIDs {
                try Task.checkCancellation()
                try jpeg.write(to: directoryURL(incidentID).appending(path: "thumb.jpg"), options: .atomic)
            }
        } catch {
            // A missing thumbnail is cosmetic and must never fail incident preservation.
        }
    }

    @concurrent
    private static func writeThumbnailData(
        _ jpeg: Data,
        incidentIDs: [UUID],
        directoryURL: @escaping @Sendable (UUID) -> URL
    ) async {
        for incidentID in incidentIDs {
            guard Task.isCancelled == false else { return }
            try? jpeg.write(
                to: directoryURL(incidentID).appending(path: "thumb.jpg"),
                options: .atomic
            )
        }
    }
}
