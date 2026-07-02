import UIKit

final class ConnectionStatusStripView: UIView {
    private let pill = StatusPillView()
    private let separatorView = UIView()

    private var hairlineHeight: CGFloat { 1 / max(traitCollection.displayScale, 1) }
    private lazy var separatorHeightConstraint =
        separatorView.heightAnchor.constraint(equalToConstant: hairlineHeight)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureBaseView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConnectionStatusStripView is programmatic.")
    }

    func configure(_ presentation: ConnectionCoordination.StripPresentation) {
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

        pill.configure(
            caption: presentation.caption,
            dotColor: dotColor,
            backgroundStyle: backgroundStyle
        )
    }

    private func configureBaseView() {
        isUserInteractionEnabled = false
        backgroundColor = .systemBackground

        pill.translatesAutoresizingMaskIntoConstraints = false

        separatorView.backgroundColor = .separator
        separatorView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(pill)
        addSubview(separatorView)

        let minimumPillHeight = pill.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
        minimumPillHeight.priority = .defaultLow

        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            pill.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 6),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            minimumPillHeight,

            separatorView.leadingAnchor.constraint(equalTo: leadingAnchor),
            separatorView.trailingAnchor.constraint(equalTo: trailingAnchor),
            separatorView.bottomAnchor.constraint(equalTo: bottomAnchor),
            separatorHeightConstraint,
        ])

        registerForTraitChanges([UITraitDisplayScale.self]) { (view: Self, _) in
            view.separatorHeightConstraint.constant = view.hairlineHeight
        }
    }
}
