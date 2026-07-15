import Testing
@testable import DanCam

struct LinkTests {
    @Test func snapshotMovesAnyLinkOnline() {
        let world = CameraSamples.world(phase: .recording)

        var connecting = Link.connecting
        connecting.fold(.snapshot(world))
        #expect(connecting == .online(world))

        var offline = Link.offline(last: CameraSamples.world(phase: .idle))
        offline.fold(.snapshot(world))
        #expect(offline == .online(world))
    }

    @Test func deltasFoldOnlyWhileOnline() {
        let world = CameraSamples.world(storage: nil)

        var online = Link.online(world)
        online.fold(.storageChanged(storage: Storage(used: 10, total: 20, recordingCapacityBytes: 15), recordingReadiness: .ready))
        #expect(online.world?.storage == Storage(used: 10, total: 20, recordingCapacityBytes: 15))

        var connecting = Link.connecting
        connecting.fold(.storageChanged(storage: Storage(used: 10, total: 20, recordingCapacityBytes: 15), recordingReadiness: .ready))
        #expect(connecting == .connecting)

        var offline = Link.offline(last: world)
        offline.fold(.storageChanged(storage: Storage(used: 10, total: 20, recordingCapacityBytes: 15), recordingReadiness: .ready))
        #expect(offline == .offline(last: world))
    }

    @Test func recorderOrderingPreservesOpenSegment() {
        let world = CameraSamples.world(
            phase: .starting,
            currentSegment: nil
        )
        var link = Link.online(world)

        link.fold(.segmentOpened(session: 7, id: 43, atMs: 5_400))
        #expect(link.world?.recorder.phase == .recording)
        #expect(link.world?.recorder.currentSegment == RecorderSegment(id: 43, durMs: nil))

        link.fold(.recordingStarted(session: 7, atMs: 5_200))
        #expect(link.world?.recorder.phase == .recording)
        #expect(link.world?.recorder.currentSegment == RecorderSegment(id: 43, durMs: nil))
    }

    @Test func stopAndFailureClearCurrentSegment() {
        let world = CameraSamples.world(
            phase: .recording,
            currentSegment: RecorderSegment(id: 43, durMs: nil)
        )
        var stopped = Link.online(world)
        stopped.fold(.recordingStopping(session: 7, atMs: 60_000))
        #expect(stopped.world?.recorder.phase == .stopping)
        stopped.fold(.recordingStopped(session: 7, atMs: 62_000))
        #expect(stopped.world?.recorder.phase == .idle)
        #expect(stopped.world?.recorder.currentSegment == nil)

        var failed = Link.online(world)
        failed.fold(.recorderFailed(session: 7, detail: "camera process exited", atMs: 9_400))
        #expect(failed.world?.recorder.phase == .error)
        #expect(failed.world?.recorder.detail == "camera process exited")
        #expect(failed.world?.recorder.currentSegment == nil)
    }

    @Test func unknownEventIsWorldNoOp() {
        let world = CameraSamples.world(phase: .recording)
        var link = Link.online(world)

        link.fold(.unknown(type: "future_event"))

        #expect(link == .online(world))
    }

    @Test func heartbeatAdvancesOnlyUptimeWhileOnline() {
        let world = CameraSamples.world(
            phase: .recording,
            storage: Storage(used: 200, total: 1_000),
            tempC: TempC(
                soc: TempReading(current: 40, max: 42),
                sensor: TempReading(current: 45, max: 47)
            ),
            mem: Mem(total: 100, available: 50, swapTotal: 100, swapUsed: 25),
            uptimeS: 1
        )
        var link = Link.online(world)

        link.fold(.heartbeat(tMs: 12_000))

        var expected = world
        expected.uptimeS = 12
        #expect(link == .online(expected))
    }

    @Test func wentOfflineCarriesLastWorld() {
        let world = CameraSamples.world(phase: .recording)
        var link = Link.online(world)

        link.wentOffline()

        #expect(link == .offline(last: world))
    }

    @Test func recorderTruthReflectsLinkFreshness() {
        let world = CameraSamples.world(phase: .recording)

        #expect(Link.online(world).recorderTruth == .live(world.recorder))
        #expect(Link.offline(last: world).recorderTruth == .lastKnown(world.recorder))
        #expect(Link.offline(last: nil).recorderTruth == .unknown)
        #expect(Link.connecting.recorderTruth == .unknown)
    }
}
