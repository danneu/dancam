import UIKit

final class RecordButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RecordButton is programmatic.")
    }

    func apply(_ state: RecordingFeature.State) {
        let style = RecordButtonStyle.from(state)
        var configuration = UIButton.Configuration.filled()
        configuration.title = style.title
        configuration.image = UIImage(systemName: style.systemImage)
        configuration.imagePadding = 8
        configuration.cornerStyle = .capsule
        configuration.titleLineBreakMode = .byTruncatingTail

        switch style.treatment {
        case .record:
            configuration.baseBackgroundColor = .systemRed
            configuration.baseForegroundColor = .white
        case .neutral:
            configuration.baseBackgroundColor = .systemGray5
            configuration.baseForegroundColor = .systemRed
        }

        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .headline)
            return outgoing
        }
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 12,
            leading: 24,
            bottom: 12,
            trailing: 24
        )

        self.configuration = configuration
        titleLabel?.adjustsFontForContentSizeCategory = true
        isEnabled = style.isEnabled
        accessibilityLabel = style.accessibilityLabel
    }
}
