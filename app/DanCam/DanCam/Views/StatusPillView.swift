import UIKit

final class StatusPillView: UIView {
    enum BackgroundStyle {
        case material
        case tinted(UIColor)
    }

    private let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let stackView = UIStackView()
    private let dotView = UIView()
    private let captionLabel = UILabel()

    init(
        caption: String = "",
        dotColor: UIColor? = nil,
        backgroundStyle: BackgroundStyle = .material
    ) {
        super.init(frame: .zero)
        configureBaseView()
        configure(caption: caption, dotColor: dotColor, backgroundStyle: backgroundStyle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StatusPillView is programmatic.")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    func configure(
        caption: String,
        dotColor: UIColor? = nil,
        backgroundStyle: BackgroundStyle? = nil
    ) {
        captionLabel.text = caption
        accessibilityLabel = caption

        if let dotColor {
            dotView.isHidden = false
            dotView.backgroundColor = dotColor
        } else {
            dotView.isHidden = true
        }

        if let backgroundStyle {
            apply(backgroundStyle)
        }
    }

    func setCaptionCompressionResistancePriority(
        _ priority: UILayoutPriority,
        for axis: NSLayoutConstraint.Axis
    ) {
        captionLabel.setContentCompressionResistancePriority(priority, for: axis)
    }

    var captionForTesting: String? {
        captionLabel.text
    }

    var dotColorForTesting: UIColor? {
        dotView.isHidden ? nil : dotView.backgroundColor
    }

    private func configureBaseView() {
        isAccessibilityElement = true
        clipsToBounds = true
        layer.cornerCurve = .continuous
        directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 6,
            leading: 10,
            bottom: 6,
            trailing: 10
        )

        effectView.isUserInteractionEnabled = false
        effectView.translatesAutoresizingMaskIntoConstraints = false

        dotView.layer.cornerRadius = 3.5
        dotView.translatesAutoresizingMaskIntoConstraints = false

        captionLabel.font = .preferredFont(forTextStyle: .caption1)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.numberOfLines = 1

        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 6
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(dotView)
        stackView.addArrangedSubview(captionLabel)

        addSubview(effectView)
        addSubview(stackView)

        let stackTrailingConstraint = stackView.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor)
        stackTrailingConstraint.priority = UILayoutPriority(999)
        let stackBottomConstraint = stackView.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor)
        stackBottomConstraint.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            dotView.widthAnchor.constraint(equalToConstant: 7),
            dotView.heightAnchor.constraint(equalToConstant: 7),

            stackView.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stackTrailingConstraint,
            stackView.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            stackBottomConstraint,
        ])
    }

    private func apply(_ style: BackgroundStyle) {
        switch style {
        case .material:
            backgroundColor = .clear
            effectView.isHidden = false
        case .tinted(let color):
            backgroundColor = color
            effectView.isHidden = true
        }
    }
}
