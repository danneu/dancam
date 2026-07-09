import Testing
@testable import DanCam

@MainActor
struct DebugScreenTests {
    @Test func onlineWorldRendersLiveSectionsAndRows() throws {
        var world = CameraSamples.world(
            phase: .starting,
            storage: Storage(used: 1_000, total: 4_000),
            tempC: TempC(soc: 51.2, sensor: 52.3),
            mem: Mem(total: 1_000_000, available: 400_000, swapTotal: 200_000, swapUsed: 100_000),
            uptimeS: 200_000,
            bootTag: "drive-7",
            time: TimeStatus(synced: true)
        )
        world = World.folding(world, .segmentOpened(session: 7, id: 24, atMs: 5_000))

        let sections = DebugScreen.sections(for: state(link: .online(world)))

        #expect(sections.map(\.id) == [.recorder, .camera, .storage, .memory, .system, .actions])
        #expect(try row(.value(.recorderPhase), in: sections) == .value(
            id: .recorderPhase,
            label: "Phase",
            value: "recording",
            tint: .neutral
        ))
        #expect(try row(.value(.recorderSession), in: sections) == .value(
            id: .recorderSession,
            label: "Session",
            value: "7",
            tint: .neutral
        ))
        #expect(try row(.value(.recorderSegment), in: sections) == .value(
            id: .recorderSegment,
            label: "Segment",
            value: "Segment #24",
            tint: .neutral
        ))
        #expect(try row(.gauge(.storage), in: sections) == .gauge(
            id: .storage,
            title: "Storage",
            detail: "1 KB of 4 KB -- 3 KB free",
            fraction: 0.25,
            tint: .neutral
        ))
        #expect(try row(.gauge(.ram), in: sections) == .gauge(
            id: .ram,
            title: "RAM",
            detail: "600 KB of 1 MB",
            fraction: 0.6,
            tint: .neutral
        ))
        #expect(try row(.gauge(.swap), in: sections) == .gauge(
            id: .swap,
            title: "Swap",
            detail: "100 KB of 200 KB",
            fraction: 0.5,
            tint: .warn
        ))
        #expect(try value(for: .bootID, in: sections) == "boot-123")
        #expect(try value(for: .bootTag, in: sections) == "drive-7")
        #expect(try value(for: .uptime, in: sections) == "2d 7h 33m")
        #expect(try value(for: .time, in: sections) == "synced")
        #expect(sections.flatMap(\.rows).contains { $0.id == .banner } == false)
    }

    @Test func offlineWorldPrependsStalenessBannerAndKeepsLastValues() throws {
        let world = CameraSamples.world(phase: .recording, uptimeS: 3_725)

        let sections = DebugScreen.sections(for: state(link: .offline(last: world)))

        #expect(sections.first == DebugSection(
            id: .staleness,
            title: nil,
            rows: [.banner("Not connected -- showing last known values")]
        ))
        #expect(try value(for: .recorderPhase, in: sections) == "recording")
        #expect(try value(for: .uptime, in: sections) == "1h 2m")
    }

    @Test func connectingWithoutWorldRendersPlaceholdersWithoutGauges() throws {
        let sections = DebugScreen.sections(for: state(link: .connecting))

        #expect(sections.flatMap(\.rows).contains { if case .gauge = $0 { true } else { false } } == false)
        #expect(try value(for: .recorderPhase, in: sections) == "--")
        #expect(try value(for: .cameraState, in: sections) == "--")
        #expect(try value(for: .storage, in: sections) == "--")
        #expect(try value(for: .ram, in: sections) == "--")
        #expect(try value(for: .swap, in: sections) == "--")
        #expect(try value(for: .bootID, in: sections) == "--")
        #expect(try value(for: .uptime, in: sections) == "--")
        #expect(try value(for: .time, in: sections) == "--")
    }

    @Test func onlineMissingTelemetryUsesPerFieldPlaceholders() throws {
        let world = CameraSamples.world(storage: nil, mem: nil, uptimeS: 45, time: nil)

        let sections = DebugScreen.sections(for: state(link: .online(world)))

        #expect(sections.flatMap(\.rows).contains { if case .gauge = $0 { true } else { false } } == false)
        #expect(try value(for: .storage, in: sections) == "--")
        #expect(try value(for: .ram, in: sections) == "--")
        #expect(try value(for: .swap, in: sections) == "--")
        #expect(try value(for: .time, in: sections) == "--")
        #expect(try tint(for: .time, in: sections) == .neutral)
        #expect(try value(for: .bootID, in: sections) == "boot-123")
        #expect(try value(for: .uptime, in: sections) == "45s")
        #expect(sections.flatMap(\.rows).contains { $0.id == .banner } == false)
    }

    @Test func zeroSwapRendersNoneWithoutGauge() throws {
        let world = CameraSamples.world(mem: Mem(total: 100, available: 25, swapTotal: 0, swapUsed: 10))

        let sections = DebugScreen.sections(for: state(link: .online(world)))

        #expect(try value(for: .swap, in: sections) == "none")
        #expect(sections.flatMap(\.rows).contains { $0.id == .gauge(.swap) } == false)
    }

    @Test func zeroMemoryTotalRendersPlaceholdersWithoutGauges() throws {
        let world = CameraSamples.world(mem: Mem(total: 0, available: 0, swapTotal: 100, swapUsed: 50))

        let sections = DebugScreen.sections(for: state(link: .online(world)))

        #expect(try value(for: .ram, in: sections) == "--")
        #expect(try value(for: .swap, in: sections) == "--")
        #expect(sections.flatMap(\.rows).contains { $0.id == .gauge(.ram) } == false)
        #expect(sections.flatMap(\.rows).contains { $0.id == .gauge(.swap) } == false)
    }

    @Test func heartbeatAndSnapshotKeepUptimeFresh() throws {
        let world = CameraSamples.world(
            phase: .recording,
            storage: Storage(used: 200, total: 1_000),
            tempC: TempC(soc: 40, sensor: 45),
            mem: Mem(total: 100, available: 40, swapTotal: 100, swapUsed: 25),
            uptimeS: 1
        )
        let heartbeatWorld = World.folding(world, .heartbeat(tMs: 200_000_000))
        var expected = world
        expected.uptimeS = 200_000

        #expect(heartbeatWorld == expected)
        #expect(try value(for: .uptime, in: DebugScreen.sections(for: state(link: .online(heartbeatWorld)))) == "2d 7h 33m")

        var snapshot = world
        snapshot.uptimeS = 3_725
        let snapshotWorld = World.folding(heartbeatWorld, .snapshot(snapshot))
        #expect(try value(for: .uptime, in: DebugScreen.sections(for: state(link: .online(snapshotWorld)))) == "1h 2m")
    }

    @Test func exportFailureIsCriticalAndClearsWhenNil() throws {
        let failed = DebugScreen.sections(
            for: state(link: .connecting),
            exportError: "Log export failed: Denied"
        )
        let clear = DebugScreen.sections(for: state(link: .connecting))

        #expect(try row(.exportError, in: failed) == .exportError("Log export failed: Denied"))
        #expect(clear.flatMap(\.rows).contains { $0.id == .exportError } == false)
    }

    @Test(arguments: [
        (used: UInt64(79), expected: DebugTint.neutral),
        (used: UInt64(80), expected: DebugTint.warn),
        (used: UInt64(89), expected: DebugTint.warn),
        (used: UInt64(90), expected: DebugTint.critical),
    ])
    func ramTintUsesInclusiveThresholds(used: UInt64, expected: DebugTint) throws {
        let world = CameraSamples.world(mem: Mem(total: 100, available: 100 - used, swapTotal: 0, swapUsed: 0))

        #expect(try gaugeTint(for: .ram, in: DebugScreen.sections(for: state(link: .online(world)))) == expected)
    }

    @Test(arguments: [
        (used: UInt64(49), expected: DebugTint.neutral),
        (used: UInt64(50), expected: DebugTint.warn),
        (used: UInt64(79), expected: DebugTint.warn),
        (used: UInt64(80), expected: DebugTint.critical),
    ])
    func swapTintUsesInclusiveSwapThresholds(used: UInt64, expected: DebugTint) throws {
        let world = CameraSamples.world(mem: Mem(total: 100, available: 100, swapTotal: 100, swapUsed: used))

        #expect(try gaugeTint(for: .swap, in: DebugScreen.sections(for: state(link: .online(world)))) == expected)
    }

    @Test func semanticTintsCoverStorageCameraTimeAndRecorderError() throws {
        let world = CameraSamples.world(
            phase: .error,
            detail: "camera process exited",
            storage: Storage(used: 97, total: 100),
            tempC: TempC(soc: 70, sensor: 50),
            mem: nil,
            time: TimeStatus(synced: false)
        )
        let warningSections = DebugScreen.sections(for: state(link: .online(world)))

        #expect(try gaugeTint(for: .storage, in: warningSections) == .neutral)
        #expect(try tint(for: .socTemperature, in: warningSections) == .neutral)
        #expect(try tint(for: .cameraTemperature, in: warningSections) == .warn)
        #expect(try tint(for: .time, in: warningSections) == .warn)
        #expect(try tint(for: .recorderDetail, in: warningSections) == .critical)

        var criticalWorld = world
        criticalWorld.tempC.sensor = 55
        #expect(try tint(
            for: .cameraTemperature,
            in: DebugScreen.sections(for: state(link: .online(criticalWorld)))
        ) == .critical)
    }

    private func state(link: Link) -> AppFeature.State {
        var state = AppFeature.State()
        state.link = link
        return state
    }

    private func row(_ id: DebugRowID, in sections: [DebugSection]) throws -> DebugRow {
        try #require(sections.flatMap(\.rows).first { $0.id == id })
    }

    private func value(for id: DebugValueID, in sections: [DebugSection]) throws -> String {
        guard case .value(_, _, let value, _) = try row(.value(id), in: sections) else {
            Issue.record("Expected value row for \(id).")
            return ""
        }
        return value
    }

    private func tint(for id: DebugValueID, in sections: [DebugSection]) throws -> DebugTint {
        guard case .value(_, _, _, let tint) = try row(.value(id), in: sections) else {
            Issue.record("Expected value row for \(id).")
            return .neutral
        }
        return tint
    }

    private func gaugeTint(for id: DebugGaugeID, in sections: [DebugSection]) throws -> DebugTint {
        guard case .gauge(_, _, _, _, let tint) = try row(.gauge(id), in: sections) else {
            Issue.record("Expected gauge row for \(id).")
            return .neutral
        }
        return tint
    }
}
