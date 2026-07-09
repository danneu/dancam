import UIKit

final class StatusStripView: UIView {
    private let connectionPill = StatusPillView()
    private let recordingPill = StatusPillView()
    private let separatorView = UIView()

    private var recordingPillTrailingConstraint: NSLayoutConstraint!
    private var recordingPillSpacingConstraint: NSLayoutConstraint!
    private var hairlineHeight: CGFloat { 1 / max(traitCollection.displayScale, 1) }
    private lazy var separatorHeightConstraint =
        separatorView.heightAnchor.constraint(equalToConstant: hairlineHeight)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureBaseView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StatusStripView is programmatic.")
    }

    func configure(
        connection: StripCoordination.ConnectionPill,
        recording: StripCoordination.RecordingPill?
    ) {
        configureConnectionPill(connection)
        configureRecordingPill(recording)
    }

    private func configureConnectionPill(_ presentation: StripCoordination.ConnectionPill) {
        let dotColor: UIColor
        let backgroundStyle: StatusPillView.BackgroundStyle

        switch presentation.tone {
        case .neutral:
            dotColor = .secondaryLabel
            backgroundStyle = .material
        case .positive:
            dotColor = .systemGreen
            backgroundStyle = .material
        case .negative:
            dotColor = .systemRed
            backgroundStyle = .tinted(UIColor.systemRed.withAlphaComponent(0.16))
        }

        connectionPill.configure(
            caption: presentation.caption,
            dotColor: dotColor,
            backgroundStyle: backgroundStyle
        )
    }

    private func configureRecordingPill(_ presentation: StripCoordination.RecordingPill?) {
        guard let presentation else {
            recordingPill.isHidden = true
            recordingPillTrailingConstraint.isActive = false
            recordingPillSpacingConstraint.isActive = false
            return
        }

        recordingPill.isHidden = false
        recordingPillTrailingConstraint.isActive = true
        recordingPillSpacingConstraint.isActive = true

        switch presentation {
        case .live:
            recordingPill.configure(
                caption: "REC",
                dotColor: .systemRed,
                backgroundStyle: .material
            )
            recordingPill.accessibilityLabel = "Recording"
        case .lastKnown:
            recordingPill.configure(
                caption: "REC",
                dotColor: .systemGray,
                backgroundStyle: .material
            )
            recordingPill.accessibilityLabel = "Last known recording"
        case .idle:
            recordingPill.configure(
                caption: "Not recording",
                dotColor: .secondaryLabel,
                backgroundStyle: .material
            )
        }
    }

    private func configureBaseView() {
        isUserInteractionEnabled = false
        backgroundColor = .systemBackground

        connectionPill.translatesAutoresizingMaskIntoConstraints = false
        recordingPill.translatesAutoresizingMaskIntoConstraints = false
        recordingPill.isHidden = true
        recordingPill.setCaptionCompressionResistancePriority(.defaultLow, for: .horizontal)

        separatorView.backgroundColor = .separator
        separatorView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(connectionPill)
        addSubview(recordingPill)
        addSubview(separatorView)

        let minimumPillHeight = connectionPill.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        minimumPillHeight.priority = .defaultLow
        recordingPillTrailingConstraint = recordingPill.trailingAnchor.constraint(
            equalTo: safeAreaLayoutGuide.trailingAnchor,
            constant: -16
        )
        recordingPillSpacingConstraint = recordingPill.leadingAnchor.constraint(
            greaterThanOrEqualTo: connectionPill.trailingAnchor,
            constant: 8
        )

        NSLayoutConstraint.activate([
            connectionPill.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            connectionPill.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 6),
            connectionPill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            connectionPill.trailingAnchor.constraint(
                lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor,
                constant: -16
            ),
            minimumPillHeight,

            recordingPill.centerYAnchor.constraint(equalTo: connectionPill.centerYAnchor),

            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorView.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorHeightConstraint,
        ])

        registerForTraitChanges([UITraitDisplayScale.self]) { (view: Self, _) in
            view.separatorHeightConstraint.constant = view.hairlineHeight
        }
    }

    var connectionPillForTesting: StatusPillView {
        connectionPill
    }

    var recordingPillForTesting: StatusPillView {
        recordingPill
    }

    var isRecordingPillVisibleForTesting: Bool {
        recordingPill.isHidden == false
    }
}
