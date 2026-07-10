import UIKit

final class SettingsViewController: UIViewController {
    private let dependencies: AppDependencies
    private let store: AppStore

    init(dependencies: AppDependencies, store: AppStore) {
        self.dependencies = dependencies
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsViewController is programmatic.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = "Settings"
        view.backgroundColor = .systemBackground

        // TODO: Real Settings screen (recording controls, resolution, retention, time sync).
        let placeholderLabel = UILabel()
        placeholderLabel.text = "Settings coming soon"
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .secondaryLabel
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])
    }
}
