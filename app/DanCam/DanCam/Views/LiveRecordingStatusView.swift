import UIKit

final class LiveRecordingStatusView: UIView {
    private let titleLabel = UILabel()
    private let elapsedLabel = UILabel()
    private let recBadge = StatusPillView(caption: "REC", dotColor: .systemRed)
    private let clock = ContinuousClock()

    private var status: LiveRecordingStatus = .none
    private var tickTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LiveRecordingStatusView is programmatic.")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateTickTimer()
    }

    isolated deinit {
        stopTickTimer()
    }

    func configure(status: LiveRecordingStatus, now: ContinuousClock.Instant) {
        self.status = status

        switch status {
        case .none:
            accessibilityLabel = nil
        case .pending:
            titleLabel.text = "Starting..."
            elapsedLabel.text = Formatters.countUpDuration(0)
            configureBadge(color: .systemRed)
            accessibilityLabel = "Starting recording"
        case .live(let segment):
            titleLabel.text = String(format: "seg_%05d.ts", segment.id)
            switch segment.elapsed {
            case .ticking:
                configureBadge(color: .systemRed)
            case .frozen:
                configureBadge(color: .systemGray)
            }
            updateElapsed(segment: segment, now: now)
        }

        updateTickTimer()
    }

    func tickForTesting(now: ContinuousClock.Instant? = nil) {
        tick(now: now ?? clock.now)
    }

    private func tick(now: ContinuousClock.Instant) {
        guard case .live(let segment) = status,
              segment.isTicking else {
            return
        }

        updateElapsed(segment: segment, now: now)
    }

    var titleTextForTesting: String? {
        titleLabel.text
    }

    var elapsedTextForTesting: String? {
        elapsedLabel.text
    }

    var recBadgeForTesting: StatusPillView {
        recBadge
    }

    var isTickTimerRunningForTesting: Bool {
        tickTimer != nil
    }

    private func configureViews() {
        isAccessibilityElement = true
        directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 11,
            leading: 0,
            bottom: 11,
            trailing: 0
        )

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingMiddle

        let elapsedBaseFont = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .regular
        )
        elapsedLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: elapsedBaseFont)
        elapsedLabel.adjustsFontForContentSizeCategory = true
        elapsedLabel.textColor = .secondaryLabel
        elapsedLabel.textAlignment = .right
        elapsedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        configureBadge(color: .systemRed)
        recBadge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [titleLabel, recBadge, elapsedLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
        ])
    }

    private func configureBadge(color: UIColor) {
        recBadge.configure(
            caption: "REC",
            dotColor: color,
            backgroundStyle: .tinted(color.withAlphaComponent(0.14))
        )
    }

    private func updateElapsed(segment: LiveSegment, now: ContinuousClock.Instant) {
        switch segment.elapsed {
        case .ticking:
            elapsedLabel.text = Formatters.countUpDuration(segment.elapsedDurMs(at: now))
            accessibilityLabel = "\(titleLabel.text ?? ""), recording, \(elapsedLabel.text ?? "")"
        case .frozen(let durMs):
            elapsedLabel.text = Formatters.approximateDuration(durMs)
            accessibilityLabel = "\(titleLabel.text ?? ""), last known recording, \(elapsedLabel.text ?? "")"
        }
    }

    private func updateTickTimer() {
        guard case .live(let segment) = status,
              segment.isTicking,
              window != nil else {
            stopTickTimer()
            return
        }

        guard tickTimer == nil else { return }

        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick(now: self.clock.now)
            }
        }
    }

    private func stopTickTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }
}

final class LiveRecordingCell: UITableViewCell {
    private let statusView = LiveRecordingStatusView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LiveRecordingCell is programmatic.")
    }

    func configure(status: LiveRecordingStatus, now: ContinuousClock.Instant) {
        statusView.configure(status: status, now: now)
    }

    var statusViewForTesting: LiveRecordingStatusView {
        statusView
    }

    private func configureViews() {
        selectionStyle = .none
        statusView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusView)

        NSLayoutConstraint.activate([
            statusView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            statusView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            statusView.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            statusView.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }
}
