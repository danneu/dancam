import Foundation

nonisolated enum StoredIncident: Equatable, Sendable, Identifiable {
    case readable(record: IncidentRecord, directoryURL: URL)
    case unreadable(directoryName: String, directoryURL: URL)

    var id: String {
        switch self {
        case .readable(let record, _): record.id.uuidString
        case .unreadable(let directoryName, _): directoryName
        }
    }
}

nonisolated struct IncidentStore: Sendable {
    var list: @Sendable () async throws -> [StoredIncident]
    var create: @Sendable (IncidentRecord) async throws -> Void
    var update: @Sendable (IncidentRecord) async throws -> Void
    var delete: @Sendable (UUID) async throws -> Void
    var deleteUnreadable: @Sendable (String) async throws -> Void
    var directoryURL: @Sendable (UUID) -> URL

    static func live(rootDirectory: URL) -> IncidentStore {
        let store = LiveStore(rootDirectory: rootDirectory)
        return IncidentStore(
            list: { try await store.list() },
            create: { try await store.create($0) },
            update: { try await store.update($0) },
            delete: { try await store.delete($0) },
            deleteUnreadable: { try await store.deleteUnreadable(directoryName: $0) },
            directoryURL: { rootDirectory.appending(path: $0.uuidString, directoryHint: .isDirectory) }
        )
    }

    static let noop = IncidentStore(
        list: { [] },
        create: { _ in },
        update: { _ in },
        delete: { _ in },
        deleteUnreadable: { _ in },
        directoryURL: { URL(filePath: "/dev/null").appending(path: $0.uuidString) }
    )

    private actor LiveStore {
        let rootDirectory: URL

        init(rootDirectory: URL) {
            self.rootDirectory = rootDirectory
        }

        func list() throws -> [StoredIncident] {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            let directories = try fileManager.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            var incidents: [StoredIncident] = []
            for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    continue
                }
                removeStagingFiles(in: directory, fileManager: fileManager)

                do {
                    var record = try decodeRecord(in: directory)
                    if try reconcileArtifacts(record: &record, in: directory, fileManager: fileManager) {
                        try write(record, in: directory)
                    }
                    incidents.append(.readable(record: record, directoryURL: directory))
                } catch {
                    incidents.append(.unreadable(
                        directoryName: directory.lastPathComponent,
                        directoryURL: directory
                    ))
                }
            }
            return incidents
        }

        func create(_ record: IncidentRecord) throws {
            let directory = directoryURL(record.id)
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            do {
                try write(record, in: directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }

        func update(_ record: IncidentRecord) throws {
            let directory = directoryURL(record.id)
            guard FileManager.default.fileExists(atPath: directory.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try write(record, in: directory)
        }

        func delete(_ id: UUID) throws {
            let directory = directoryURL(id)
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            try FileManager.default.removeItem(at: directory)
        }

        func deleteUnreadable(directoryName: String) throws {
            guard directoryName.isEmpty == false,
                  directoryName != ".",
                  directoryName != "..",
                  directoryName.contains("/") == false else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let directory = rootDirectory.appending(path: directoryName, directoryHint: .isDirectory)
            guard directory.deletingLastPathComponent().standardizedFileURL == rootDirectory.standardizedFileURL,
                  FileManager.default.fileExists(atPath: directory.path) else { return }
            try FileManager.default.removeItem(at: directory)
        }

        private func directoryURL(_ id: UUID) -> URL {
            rootDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
        }

        private func decodeRecord(in directory: URL) throws -> IncidentRecord {
            let data = try Data(contentsOf: directory.appending(path: "incident.json"))
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(IncidentRecord.self, from: data)
        }

        private func write(_ record: IncidentRecord, in directory: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let data = try encoder.encode(record)
            try data.write(to: directory.appending(path: "incident.json"), options: .atomic)
        }

        private func removeStagingFiles(in directory: URL, fileManager: FileManager) {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { return }
            for file in files where file.lastPathComponent.hasSuffix(".part") {
                try? fileManager.removeItem(at: file)
            }
        }

        private func reconcileArtifacts(
            record: inout IncidentRecord,
            in directory: URL,
            fileManager: FileManager
        ) throws -> Bool {
            var changed = false
            for index in record.wanted.indices where record.wanted[index].state != .pulled {
                let seq = record.wanted[index].seq
                let stem = String(format: "seg_%05d", seq)
                let candidates = ["mp4", "ts"].map { directory.appending(path: "\(stem).\($0)") }
                guard let artifact = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
                    continue
                }
                let attributes = try fileManager.attributesOfItem(atPath: artifact.path)
                let bytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                record.wanted[index].markPulled(bytes: bytes)
                changed = true
            }
            return changed
        }
    }
}
