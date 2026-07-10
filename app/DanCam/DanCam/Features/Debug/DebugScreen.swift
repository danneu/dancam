import Foundation

nonisolated enum DebugTint: Hashable {
    case neutral
    case warn
    case critical
}

nonisolated enum DebugValueID: Hashable {
    case recorderPhase
    case recorderSession
    case recorderSegment
    case recorderDetail
    case cameraState
    case socTemperature
    case cameraTemperature
    case storage
    case ram
    case swap
    case bootID
    case bootTag
    case uptime
    case time
}

nonisolated enum DebugGaugeID: Hashable {
    case storage
    case ram
    case swap
}

nonisolated enum DebugButtonID: Hashable {
    case exportLogs
}

nonisolated enum DebugRowID: Hashable {
    case banner
    case value(DebugValueID)
    case gauge(DebugGaugeID)
    case button(DebugButtonID)
    case exportError
}

nonisolated enum DebugRow: Equatable {
    case banner(String)
    case value(
        id: DebugValueID,
        label: String,
        value: String,
        tint: DebugTint,
        detail: String?,
        detailTint: DebugTint
    )
    case gauge(id: DebugGaugeID, title: String, detail: String, fraction: Double, tint: DebugTint)
    case button(DebugButtonID)
    case exportError(String)

    var id: DebugRowID {
        switch self {
        case .banner:
            .banner
        case .value(let id, _, _, _, _, _):
            .value(id)
        case .gauge(let id, _, _, _, _):
            .gauge(id)
        case .button(let id):
            .button(id)
        case .exportError:
            .exportError
        }
    }

    static func value(id: DebugValueID, label: String, value: String, tint: DebugTint) -> DebugRow {
        .value(id: id, label: label, value: value, tint: tint, detail: nil, detailTint: .neutral)
    }
}

nonisolated enum DebugSectionID: Hashable {
    case staleness
    case recorder
    case camera
    case storage
    case memory
    case system
    case actions
}

nonisolated struct DebugSection: Equatable {
    var id: DebugSectionID
    var title: String?
    var rows: [DebugRow]
}

enum DebugScreen {
    static func sections(
        for state: AppFeature.State,
        exportError: String? = nil
    ) -> [DebugSection] {
        let world = state.link.world
        var sections = [DebugSection]()

        if case .offline(last: .some) = state.link {
            sections.append(DebugSection(
                id: .staleness,
                title: nil,
                rows: [.banner("Not connected -- showing last known values")]
            ))
        }

        sections.append(DebugSection(
            id: .recorder,
            title: "Recorder",
            rows: recorderRows(truth: state.link.recorderTruth)
        ))
        sections.append(DebugSection(
            id: .camera,
            title: "Camera",
            rows: cameraRows(world: world)
        ))
        sections.append(DebugSection(
            id: .storage,
            title: "Storage",
            rows: storageRows(world: world)
        ))
        sections.append(DebugSection(
            id: .memory,
            title: "Memory",
            rows: memoryRows(world: world)
        ))
        sections.append(DebugSection(
            id: .system,
            title: "System",
            rows: systemRows(world: world)
        ))

        var actionRows: [DebugRow] = [.button(.exportLogs)]
        if let exportError {
            actionRows.append(.exportError(exportError))
        }
        sections.append(DebugSection(id: .actions, title: "Actions", rows: actionRows))

        return sections
    }

    private static func recorderRows(truth: RecorderTruth) -> [DebugRow] {
        let recorder: RecorderSnapshot?
        switch truth {
        case .live(let snapshot), .lastKnown(let snapshot):
            recorder = snapshot
        case .unknown:
            recorder = nil
        }

        guard let recorder else {
            return [
                .value(id: .recorderPhase, label: "Phase", value: "--", tint: .neutral),
                .value(id: .recorderSession, label: "Session", value: "--", tint: .neutral),
            ]
        }

        var rows: [DebugRow] = [
            .value(id: .recorderPhase, label: "Phase", value: recorder.phase.rawValue, tint: .neutral),
            .value(id: .recorderSession, label: "Session", value: "\(recorder.session)", tint: .neutral),
        ]

        if let segment = recorder.currentSegment {
            rows.append(.value(
                id: .recorderSegment,
                label: "Segment",
                value: "Segment #\(segment.id)",
                tint: .neutral
            ))
        }

        if recorder.phase == .error, let detail = recorder.detail {
            rows.append(.value(
                id: .recorderDetail,
                label: "Detail",
                value: detail,
                tint: .critical
            ))
        }

        return rows
    }

    private static func cameraRows(world: World?) -> [DebugRow] {
        [
            .value(
                id: .cameraState,
                label: "State",
                value: world?.cameraState.rawValue ?? "--",
                tint: .neutral
            ),
            tempRow(
                id: .socTemperature,
                label: "SoC temp",
                reading: world?.tempC.soc,
                warning: Formatters.socWarning
            ),
            tempRow(
                id: .cameraTemperature,
                label: "Camera temp",
                reading: world?.tempC.sensor,
                warning: Formatters.sensorWarning
            ),
        ]
    }

    private static func tempRow(
        id: DebugValueID,
        label: String,
        reading: TempReading?,
        warning: (Double?) -> TempWarning?
    ) -> DebugRow {
        .value(
            id: id,
            label: label,
            value: reading?.current.map { Formatters.temperature($0, precise: true) } ?? "--",
            tint: tempTint(warning(reading?.current)),
            detail: reading?.max.map { "(max \(Formatters.temperatureNumber($0)))" },
            detailTint: tempTint(warning(reading?.max))
        )
    }

    private static func storageRows(world: World?) -> [DebugRow] {
        guard let storage = world?.storage else {
            return [.value(id: .storage, label: "Storage", value: "--", tint: .neutral)]
        }

        let display = Formatters.storageDisplay(storage)
        return [.gauge(
            id: .storage,
            title: "Storage",
            detail: "\(Formatters.byteSize(storage.used)) of \(Formatters.byteSize(storage.total)) -- \(display.freeText) free",
            fraction: display.usedFraction,
            tint: .neutral
        )]
    }

    private static func memoryRows(world: World?) -> [DebugRow] {
        guard let mem = world?.mem,
              let ram = Formatters.memoryDisplay(mem)
        else {
            return [
                .value(id: .ram, label: "RAM", value: "--", tint: .neutral),
                .value(id: .swap, label: "Swap", value: "--", tint: .neutral),
            ]
        }

        var rows: [DebugRow] = [.gauge(
            id: .ram,
            title: "RAM",
            detail: ram.detailText,
            fraction: ram.usedFraction,
            tint: pressureTint(
                ram.usedFraction,
                warn: Formatters.memoryWarnThreshold,
                critical: Formatters.memoryCriticalThreshold
            )
        )]

        if let swap = Formatters.swapDisplay(mem) {
            rows.append(.gauge(
                id: .swap,
                title: "Swap",
                detail: swap.detailText,
                fraction: swap.usedFraction,
                tint: pressureTint(
                    swap.usedFraction,
                    warn: Formatters.swapWarnThreshold,
                    critical: Formatters.swapCriticalThreshold
                )
            ))
        } else {
            rows.append(.value(id: .swap, label: "Swap", value: "none", tint: .neutral))
        }

        return rows
    }

    private static func systemRows(world: World?) -> [DebugRow] {
        guard let world else {
            return [
                .value(id: .bootID, label: "Boot ID", value: "--", tint: .neutral),
                .value(id: .uptime, label: "Uptime", value: "--", tint: .neutral),
                .value(id: .time, label: "Time", value: "--", tint: .neutral),
            ]
        }

        var rows: [DebugRow] = [
            .value(id: .bootID, label: "Boot ID", value: world.bootId, tint: .neutral),
        ]
        if let bootTag = world.bootTag {
            rows.append(.value(id: .bootTag, label: "Boot tag", value: bootTag, tint: .neutral))
        }
        rows.append(.value(
            id: .uptime,
            label: "Uptime",
            value: Formatters.uptime(world.uptimeS),
            tint: .neutral
        ))

        if let time = world.time {
            rows.append(.value(
                id: .time,
                label: "Time",
                value: time.synced ? "synced" : "not synced",
                tint: time.synced ? .neutral : .warn
            ))
        } else {
            rows.append(.value(id: .time, label: "Time", value: "--", tint: .neutral))
        }

        return rows
    }

    private static func tempTint(_ warning: TempWarning?) -> DebugTint {
        switch warning {
        case .warn:
            .warn
        case .critical:
            .critical
        case nil:
            .neutral
        }
    }

    private static func pressureTint(
        _ fraction: Double,
        warn: Double,
        critical: Double
    ) -> DebugTint {
        if fraction >= critical {
            return .critical
        }
        if fraction >= warn {
            return .warn
        }
        return .neutral
    }
}
