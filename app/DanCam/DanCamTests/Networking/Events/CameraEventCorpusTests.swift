import Foundation
import Testing
@testable import DanCam

struct CameraEventCorpusTests {
    private let corpusStorageGeneration = "00000000-0000-4000-8000-000000000001"
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
        let cpuChanged = try decoder.decode(CameraEvent.self, from: Data(contentsOf: corpusURL("cpu_changed.json")))
        let commissioningChanged = try decoder.decode(
            CameraEvent.self,
            from: Data(contentsOf: corpusURL("commissioning_changed.json"))
        )

        #expect(snapshot == .snapshot(World(
            recorder: RecorderSnapshot(
                phase: .recording,
                session: 7,
                currentSegment: RecorderSegment(id: 43, durMs: 12_000),
                detail: nil
            ),
            cameraState: .running,
            recordingReadiness: .ready,
            bootId: "7f3a91c2-b0d4-4e15-b196-20e0416af749",
            bootTag: "7f3a91c2b0d4",
            uptimeS: 120,
            storage: Storage(
                used: 1_000_000_000,
                total: 32_000_000_000,
                recordingCapacityBytes: 29_000_000_000
            ),
            storageGeneration: corpusStorageGeneration,
            tempC: TempC(
                soc: TempReading(current: 51.5, max: 62.5),
                sensor: TempReading(max: 49.0)
            ),
            mem: Mem(total: 512_000_000, available: 256_000_000, swapTotal: 134_217_728, swapUsed: 0),
            cpu: CPU(cores: [
                CPUCore(id: 0, currentPct: 98, oneMinutePct: 74, fiveMinutePct: 52, fifteenMinutePct: 40),
                CPUCore(id: 2, currentPct: 12, oneMinutePct: 20, fiveMinutePct: 30, fifteenMinutePct: 35),
            ]),
            time: TimeStatus(synced: true),
            commissioning: .complete
        )))
        #expect(opened == .segmentOpened(session: 7, id: 43, atMs: 5_400))
        #expect(finalized == .clipFinalized(Clip(
            id: 42,
            storageGeneration: corpusStorageGeneration,
            startMs: nil,
            durMs: 30_000,
            bytes: 1_048_576,
            locked: false,
            etag: "\(corpusStorageGeneration)-42-1048576",
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
        #expect(cpuChanged == .cpuChanged(CPU(cores: [
            CPUCore(id: 0, currentPct: 98, oneMinutePct: 74, fiveMinutePct: 52, fifteenMinutePct: 40),
            CPUCore(id: 2, currentPct: nil, oneMinutePct: nil, fiveMinutePct: nil, fifteenMinutePct: nil),
        ])))
        #expect(commissioningChanged == .commissioningChanged(
            commissioning: Commissioning(
                state: .failed,
                reason: "data_partition_growth_failed"
            ),
            recordingReadiness: RecordingReadiness(
                ready: false,
                reason: .commissioningIncomplete
            )
        ))

        let cameraChanged = try decoder.decode(
            CameraEvent.self,
            from: Data(contentsOf: corpusURL("camera_state_changed.json"))
        )
        let storageChanged = try decoder.decode(
            CameraEvent.self,
            from: Data(contentsOf: corpusURL("storage_changed.json"))
        )
        #expect(cameraChanged == .cameraStateChanged(state: .running, recordingReadiness: .ready))
        #expect(storageChanged == .storageChanged(
            storage: Storage(
                used: 1_000_000_000,
                total: 32_000_000_000,
                recordingCapacityBytes: 29_000_000_000
            ),
            storageGeneration: corpusStorageGeneration,
            recordingReadiness: .ready
        ))

        let notReady = RecordingReadiness(
            ready: false,
            reason: .recordingStorageUnavailable
        )
        let initial = CameraSamples.world()
        let afterCamera = World.folding(
            initial,
            .cameraStateChanged(
                state: .restarting,
                recordingReadiness: RecordingReadiness(ready: false, reason: .cameraRestarting)
            )
        )
        #expect(afterCamera.cameraState == .restarting)
        #expect(afterCamera.recordingReadiness.reason == .cameraRestarting)

        let replacement = Storage(used: 4, total: 8, recordingCapacityBytes: 6)
        let afterStorage = World.folding(
            initial,
            .storageChanged(
                storage: replacement,
                storageGeneration: CameraSamples.storageGeneration,
                recordingReadiness: notReady
            )
        )
        #expect(afterStorage.storage == replacement)
        #expect(afterStorage.recordingReadiness == notReady)
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

    @Test(.tags(.networking))
    func storageRequiresRecordingCapacity() {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let data = Data("{\"type\":\"storage_changed\",\"storage\":{\"used\":1,\"total\":2},\"recording_readiness\":{\"ready\":true,\"reason\":null}}".utf8)

        #expect(throws: DecodingError.self) {
            try decoder.decode(CameraEvent.self, from: data)
        }
    }

    @Test(.tags(.networking))
    func readinessIsRequiredOnReadinessCarryingDeltas() {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        for data in [
            Data("{\"type\":\"camera_state_changed\",\"state\":\"running\"}".utf8),
            Data("{\"type\":\"storage_changed\",\"storage\":null}".utf8),
        ] {
            #expect(throws: DecodingError.self) {
                try decoder.decode(CameraEvent.self, from: data)
            }
        }
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
