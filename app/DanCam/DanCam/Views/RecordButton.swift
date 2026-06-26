import UIKit

nonisolated enum RecordButtonTreatment: Equatable {
    case record
    case neutral
}

nonisolated enum RecordButtonStyle {
    static func from(
        _ state: RecordingFeature.State
    ) -> (
        title: String,
        systemImage: String?,
        isEnabled: Bool,
        showsActivityIndicator: Bool,
        treatment: RecordButtonTreatment
    ) {
        switch state {
        case .unknown:
            return ("Record", "record.circle", false, false, .record)
        case .idle, .failed:
            return ("Record", "record.circle", true, false, .record)
        case .starting:
            return ("Starting", nil, false, true, .record)
        case .recording:
            return ("Stop", "stop.fill", true, false, .neutral)
        case .stopping:
            return ("Stopping", nil, false, true, .neutral)
        }
    }
}

final class RecordButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RecordButton is programmatic.")
    }

    func apply(_ state: RecordingFeature.State) {
        let style = RecordButtonStyle.from(state)
        var configuration = UIButton.Configuration.filled()
        configuration.title = style.title
        if let systemImage = style.systemImage {
            configuration.image = UIImage(systemName: systemImage)
        } else {
            configuration.image = nil
        }
        configuration.imagePadding = 8
        configuration.cornerStyle = .capsule
        switch style.treatment {
        case .record:
            configuration.baseBackgroundColor = .systemRed
            configuration.baseForegroundColor = .white
        case .neutral:
            configuration.baseBackgroundColor = .systemGray5
            configuration.baseForegroundColor = .systemRed
        }
        configuration.showsActivityIndicator = style.showsActivityIndicator
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
        accessibilityLabel = accessibilityLabel(for: state)
    }

    private func accessibilityLabel(for state: RecordingFeature.State) -> String {
        switch state {
        case .recording:
            return "Stop recording"
        case .starting:
            return "Starting recording"
        case .stopping:
            return "Stopping recording"
        case .unknown, .idle, .failed:
            return "Start recording"
        }
    }
}
