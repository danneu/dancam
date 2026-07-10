import Foundation
import Testing
@testable import DanCam

struct CameraEventCorpusTests {
    @Test(.tags(.networking))
    func goldenCorpusDecodesWithoutUnknownEvents() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        for url in try corpusURLs() {
            let event = try decoder.decode(CameraEvent.self, from: Data(contentsOf: url))

            if case .unknown(let type) = event {
                Issue.record("Decoded \(url.lastPathComponent) as unknown event \(type).")
            }
        }
    }

    @Test(.tags(.networking))
    func decodesRepresentativeVariants() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let snapshot = try decoder.decode(
            CameraEvent.self,
            from: Data(contentsOf: corpusURL("snapshot.json"))
        )
        let opened = try decoder.decode(
            CameraEvent.self,
            from: Data(contentsOf: corpusURL("segment_opened.json"))
        )
        let finalized = try decoder.decode(
            CameraEvent.self,
            from: Data(contentsOf: corpusURL("clip_finalized.json"))
        )
        let removed = try decoder.decode(
            CameraEvent.self,
            from: Data(contentsOf: corpusURL("clip_removed.json"))
        )
        let timeSynced = try decoder.decode(
            CameraEvent.self,
            from: Data(contentsOf: corpusURL("time_synced.json"))
        )
        let tempChanged = try decoder.decode(
            CameraEvent.self,
            from: Data(contentsOf: corpusURL("temp_changed.json"))
        )

        #expect(snapshot == .snapshot(World(
            recorder: RecorderSnapshot(
                phase: .recording,
                session: 7,
                currentSegment: RecorderSegment(id: 43, durMs: 12_000),
                detail: nil
            ),
            cameraState: .running,
            bootId: "7f3a91c2-b0d4-4e15-b196-20e0416af749",
            bootTag: "7f3a91c2b0d4",
            uptimeS: 120,
            storage: Storage(used: 1_000_000_000, total: 32_000_000_000),
            tempC: TempC(
                soc: TempReading(current: 51.5, max: 62.5),
                sensor: TempReading(max: 49.0)
            ),
            mem: Mem(total: 512_000_000, available: 256_000_000, swapTotal: 134_217_728, swapUsed: 0),
            time: TimeStatus(synced: true)
        )))
        #expect(opened == .segmentOpened(session: 7, id: 43, atMs: 5_400))
        #expect(finalized == .clipFinalized(Clip(
            id: 42,
            startMs: nil,
            durMs: 30_000,
            bytes: 1_048_576,
            locked: false,
            etag: "42-1048576",
            timeApproximate: true,
            bootTag: "7f3a91c2b0d4",
            session: 7
        )))
        #expect(removed == .clipRemoved(id: 42))
        #expect(timeSynced == .timeSynced(atMs: 7_000))
        #expect(tempChanged == .tempChanged(TempC(
            soc: TempReading(current: 51.5, max: 62.5),
            sensor: TempReading(current: 43.5, max: 49.0)
        )))
    }

    @Test(.tags(.networking))
    func unknownTypeDecodesToUnknown() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let event = try decoder.decode(
            CameraEvent.self,
            from: Data("{\"type\":\"future_event\",\"value\":1}".utf8)
        )

        #expect(event == .unknown(type: "future_event"))
    }

    private func corpusURLs() throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(
                at: corpusDirectory(),
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func corpusURL(_ name: String) -> URL {
        corpusDirectory().appending(path: name)
    }

    private func corpusDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "contract")
            .appending(path: "events")
    }
}
