import Foundation

enum IncidentsFeature {
    nonisolated struct OpenSegmentAnchor: Equatable, Sendable {
        var recordingID: RecordingID
        var seq: Int
        var seedDurMs: UInt64
        var observedAt: ContinuousClock.Instant
    }

    nonisolated struct State: Equatable, Sendable {
        var incidents: [IncidentRecord] = []
        var openSegmentAnchor: OpenSegmentAnchor?
        var isPressFeedbackVisible = false
        var persistenceFailed = false
        var hasRequestedProvisionalAuth = false
        var pendingRecord: IncidentRecord?

        func canPress(world: World?) -> Bool {
            guard let world,
                  world.recorder.phase.claimsRecording,
                  let bootTag = world.bootTag,
                  let segment = world.recorder.currentSegment,
                  let openSegmentAnchor,
                  openSegmentAnchor.recordingID == RecordingID(
                      bootTag: bootTag,
                      session: world.recorder.session
                  ),
                  openSegmentAnchor.seq == segment.id else { return false }
            return isPressFeedbackVisible == false && pendingRecord == nil
        }
    }

    enum Action: Equatable {
        case worldObserved(World?)
        case pressTapped
        case createResponded(IncidentRecord, success: Bool)
        case cooldownFinished
        case persistenceAlertDismissed
        case reconcile
    }

    private static let cooldownID = "incident-press-cooldown"

    static func reduce(
        state: inout State,
        action: Action,
        world: World?,
        dependencies: AppDependencies
    ) -> Effect<Action> {
        switch action {
        case .worldObserved(let world):
            updateAnchor(state: &state, world: world, now: dependencies.continuousNow())
            return .none

        case .pressTapped:
            guard state.canPress(world: world),
                  let anchor = state.openSegmentAnchor else { return .none }

            let now = dependencies.continuousNow()
            let elapsed = anchor.observedAt.duration(to: now)
            let elapsedMs = max(0, elapsed.milliseconds)
            let markAge = anchor.seedDurMs.addingReportingOverflow(UInt64(elapsedMs))
            let pressedAtMs = UInt64(max(0, dependencies.wallNow().timeIntervalSince1970 * 1_000))
            let record = IncidentRecord(
                id: dependencies.uuid(),
                pressedAtMs: pressedAtMs,
                recordingID: anchor.recordingID,
                markSeq: anchor.seq,
                markAgeMs: markAge.overflow ? .max : markAge.partialValue
            )
            state.pendingRecord = record
            state.isPressFeedbackVisible = true
            state.persistenceFailed = false

            return .run { send in
                do {
                    try await dependencies.incidentStore.create(record)
                    await send(.createResponded(record, success: true))
                } catch is CancellationError {
                    return
                } catch {
                    await send(.createResponded(record, success: false))
                }
            }

        case .createResponded(let record, success: true):
            guard state.pendingRecord?.id == record.id else { return .none }
            state.pendingRecord = nil
            state.incidents.append(record)

            let shouldRequestAuth = state.hasRequestedProvisionalAuth == false
            state.hasRequestedProvisionalAuth = true
            return .merge([
                .run { send in
                    if shouldRequestAuth {
                        await dependencies.incidentNotifier.requestProvisionalAuth()
                    }
                    await dependencies.incidentNotifier.scheduleNudge(record.id, .seconds(180))
                    await send(.reconcile)
                },
                .run(id: cooldownID, cancelInFlight: true) { send in
                    await dependencies.sleep(.seconds(3))
                    guard Task.isCancelled == false else { return }
                    await send(.cooldownFinished)
                },
            ])

        case .createResponded(let record, success: false):
            guard state.pendingRecord?.id == record.id else { return .none }
            state.pendingRecord = nil
            state.isPressFeedbackVisible = false
            state.persistenceFailed = true
            return .none

        case .cooldownFinished:
            state.isPressFeedbackVisible = false
            return .none

        case .persistenceAlertDismissed:
            state.persistenceFailed = false
            return .none

        case .reconcile:
            return .none
        }
    }

    private static func updateAnchor(
        state: inout State,
        world: World?,
        now: ContinuousClock.Instant
    ) {
        guard let world,
              world.recorder.phase.claimsRecording,
              let bootTag = world.bootTag,
              let segment = world.recorder.currentSegment else {
            state.openSegmentAnchor = nil
            return
        }

        let recordingID = RecordingID(bootTag: bootTag, session: world.recorder.session)
        if state.openSegmentAnchor?.recordingID == recordingID,
           state.openSegmentAnchor?.seq == segment.id {
            return
        }
        state.openSegmentAnchor = OpenSegmentAnchor(
            recordingID: recordingID,
            seq: segment.id,
            seedDurMs: segment.durMs ?? 0,
            observedAt: now
        )
    }
}

private extension Duration {
    var milliseconds: Int64 {
        let components = self.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000)
        guard seconds.overflow == false else { return seconds.partialValue }
        return seconds.partialValue + components.attoseconds / 1_000_000_000_000_000
    }
}
