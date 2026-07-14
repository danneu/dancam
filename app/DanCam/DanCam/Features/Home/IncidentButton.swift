import UIKit

nonisolated struct IncidentButtonPresentation: Equatable, Sendable {
    var isEnabled: Bool
    var isShowingFeedback: Bool

    static func from(_ state: AppFeature.State) -> Self {
        Self(
            isEnabled: state.incidents.canPress(world: state.link.onlineWorld),
            isShowingFeedback: state.incidents.pendingIncidentCount > 0
        )
    }
}

final class IncidentButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "incidentButton"
        titleLabel?.font = .preferredFont(forTextStyle: .headline)
        titleLabel?.adjustsFontForContentSizeCategory = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("IncidentButton is programmatic.")
    }

    func apply(_ presentation: IncidentButtonPresentation) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = presentation.isShowingFeedback ? "Saving..." : "Save Incident"
        configuration.image = UIImage(
            systemName: presentation.isShowingFeedback
                ? "arrow.triangle.2.circlepath"
                : "exclamationmark.triangle.fill"
        )
        configuration.imagePadding = 8
        configuration.cornerStyle = .large
        self.configuration = configuration
        isEnabled = presentation.isEnabled
        accessibilityLabel = presentation.isShowingFeedback ? "Saving incident" : "Save incident"
    }
}
