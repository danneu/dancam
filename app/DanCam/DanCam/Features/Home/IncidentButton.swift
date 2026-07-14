import UIKit

nonisolated enum IncidentButtonPresentation: Equatable, Sendable {
    case unavailable
    case armed(lockoutDeadline: ContinuousClock.Instant?, createInFlight: Bool)

    static func from(_ state: AppFeature.State, now: ContinuousClock.Instant) -> Self {
        guard let recordingID = state.incidents.captureRecordingID(
            world: state.link.onlineWorld
        ) else { return .unavailable }
        return .armed(
            lockoutDeadline: state.incidents.activeLockout(for: recordingID, now: now),
            createInFlight: state.incidents.pendingRecords[recordingID] != nil
        )
    }
}

final class IncidentButton: UIButton {
    private let continuousNow: @Sendable () -> ContinuousClock.Instant
    private var presentation: IncidentButtonPresentation = .unavailable
    private var tickTimer: Timer?

    init(
        frame: CGRect,
        continuousNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) {
        self.continuousNow = continuousNow
        super.init(frame: frame)
        accessibilityIdentifier = "incidentButton"
        titleLabel?.font = .preferredFont(forTextStyle: .headline)
        titleLabel?.adjustsFontForContentSizeCategory = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("IncidentButton is programmatic.")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let now = continuousNow()
        render(now: now)
        updateTickTimer(now: now)
    }

    isolated deinit {
        stopTickTimer()
    }

    func apply(_ presentation: IncidentButtonPresentation, now: ContinuousClock.Instant) {
        self.presentation = presentation
        render(now: now)
        updateTickTimer(now: now)
    }

    func tickForTesting(now: ContinuousClock.Instant) {
        tick(now: now)
    }

    var isTickTimerRunningForTesting: Bool {
        tickTimer != nil
    }

    private func render(now: ContinuousClock.Instant) {
        let title: String
        let systemImage: String
        switch presentation {
        case .unavailable:
            isEnabled = false
            title = "Save Incident"
            systemImage = "exclamationmark.triangle.fill"
            accessibilityLabel = "Save incident"
            accessibilityValue = nil

        case .armed(let deadline?, _) where now < deadline:
            let remaining = max(1, Int(ceil(now.duration(to: deadline).timeInterval)))
            isEnabled = false
            title = "Saving... \(remaining)s"
            systemImage = "arrow.triangle.2.circlepath"
            accessibilityLabel = "Saving incident"
            accessibilityValue = "\(remaining) seconds remaining"

        case .armed(_, createInFlight: true):
            isEnabled = false
            title = "Saving..."
            systemImage = "arrow.triangle.2.circlepath"
            accessibilityLabel = "Saving incident"
            accessibilityValue = nil

        case .armed:
            isEnabled = true
            title = "Save Incident"
            systemImage = "exclamationmark.triangle.fill"
            accessibilityLabel = "Save incident"
            accessibilityValue = nil
        }

        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: systemImage)
        configuration.imagePadding = 8
        configuration.cornerStyle = .large
        self.configuration = configuration
    }

    private func tick(now: ContinuousClock.Instant) {
        render(now: now)
        updateTickTimer(now: now)
    }

    private func updateTickTimer(now: ContinuousClock.Instant? = nil) {
        let sampledNow = now ?? continuousNow()
        guard case .armed(let deadline?, _) = presentation,
              sampledNow < deadline,
              window != nil else {
            stopTickTimer()
            return
        }
        guard tickTimer == nil else { return }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick(now: self.continuousNow())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTickTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }
}
