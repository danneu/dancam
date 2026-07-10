import Testing
@testable import DanCam

@MainActor
struct AppTransitionLogTests {
    @Test func heartbeatWithEqualStateLogsNoChange() {
        let state = onlineState(CameraSamples.world())

        #expect(
            AppFeature.transitionLog(
                action: .event(.heartbeat(tMs: 12_000)),
                old: state,
                new: state
            ) == .debug("action=event.heartbeat (no change)")
        )
    }

    @Test func tempChangeInvisibleToSummaryLogsSnapshotDiff() {
        let old = onlineState(CameraSamples.world(tempC: TempC(
            soc: TempReading(current: 51.5, max: 62.0)
        )))
        let newTemp = TempC(
            soc: TempReading(current: 52.0, max: 63.0)
        )
        let new = onlineState(CameraSamples.world(tempC: newTemp))

        #expect(
            AppFeature.transitionLog(
                action: .event(.tempChanged(newTemp)),
                old: old,
                new: new
            ) == .debug("action=event.tempChanged temp_soc_c=51.5->52.0 temp_soc_max_c=62.0->63.0")
        )
    }

    @Test func memChangeLogsMemAvailableDiff() {
        let oldMem = Mem(total: 1_000, available: 100, swapTotal: 10, swapUsed: 1)
        let newMem = Mem(total: 1_000, available: 200, swapTotal: 10, swapUsed: 1)
        let old = onlineState(CameraSamples.world(mem: oldMem))
        let new = onlineState(CameraSamples.world(mem: newMem))

        #expect(
            AppFeature.transitionLog(
                action: .event(.memChanged(total: 1_000, available: 200, swapTotal: 10, swapUsed: 1)),
                old: old,
                new: new
            ) == .debug("action=event.memChanged mem_available=100->200")
        )
    }

    @Test func summaryChangeLogsNoticeWithOldAndNewSummaries() {
        let old = AppFeature.State()
        let world = CameraSamples.world()
        let new = onlineState(world)

        #expect(
            AppFeature.transitionLog(
                action: .event(.snapshot(world)),
                old: old,
                new: new
            ) == .notice("action=event.snapshot \(old.logSummary) -> \(new.logSummary)")
        )
    }

    @Test func stateChangeInvisibleToSnapshotFallsBackToStateChanged() {
        let oldMem = Mem(total: 1_000, available: 100, swapTotal: 10, swapUsed: 1)
        let newMem = Mem(total: 1_000, available: 100, swapTotal: 10, swapUsed: 2)
        let old = onlineState(CameraSamples.world(mem: oldMem))
        let new = onlineState(CameraSamples.world(mem: newMem))

        #expect(
            AppFeature.transitionLog(
                action: .event(.memChanged(total: 1_000, available: 100, swapTotal: 10, swapUsed: 2)),
                old: old,
                new: new
            ) == .debug("action=event.memChanged (state changed)")
        )
    }

    @Test func timeSyncedLogsTimeSyncedDiff() {
        let old = onlineState(CameraSamples.world(time: TimeStatus(synced: false)))
        let new = onlineState(CameraSamples.world(time: TimeStatus(synced: true)))

        #expect(
            AppFeature.transitionLog(
                action: .event(.timeSynced(atMs: 1_000)),
                old: old,
                new: new
            ) == .debug("action=event.timeSynced time_synced=false->true")
        )
    }

    @Test func tokenDiffEmitsChangedValues() {
        #expect(
            AppFeature.tokenDiff(old: "a=1 b=2 c=3", new: "a=1 b=5 c=3")
                == "b=2->5"
        )
    }

    @Test func tokenDiffHandlesAppearingAndDisappearingKeys() {
        #expect(
            AppFeature.tokenDiff(old: "a=1 b=2", new: "a=1 c=9")
                == "c=absent->9 b=2->absent"
        )
    }

    @Test func tokenDiffOfEqualStringsIsEmpty() {
        #expect(AppFeature.tokenDiff(old: "a=1 b=2", new: "a=1 b=2") == "")
    }

    private func onlineState(_ world: World) -> AppFeature.State {
        var state = AppFeature.State()
        state.link = .online(world)
        return state
    }
}
