import UIKit

final class HealthViewController: UIViewController {
    private let store: Store<HealthFeature.State, HealthFeature.Action, AppDependencies>
    private var observation: StoreObservation?

    private let statusLabel = UILabel()
    private let bootIdLabel = UILabel()
    private let uptimeLabel = UILabel()
    private let recordingLabel = UILabel()
    private let timeLabel = UILabel()
    private let errorLabel = UILabel()
    private let reloadButton = UIButton(type: .system)

    init(dependencies: AppDependencies) {
        store = Store(
            initialState: .idle,
            dependencies: dependencies,
            reduce: HealthFeature.reduce
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HealthViewController is programmatic.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "DanCam"
        view.backgroundColor = .systemBackground

        configureViews()
        observation = store.observe { [weak self] state in
            self?.render(state)
        }
        store.send(.onAppear)
    }

    private func configureViews() {
        statusLabel.font = .preferredFont(forTextStyle: .title2)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0

        for label in [bootIdLabel, uptimeLabel, recordingLabel, timeLabel, errorLabel] {
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }

        errorLabel.textColor = .systemRed

        reloadButton.setTitle("Reload", for: .normal)
        reloadButton.addTarget(self, action: #selector(reloadTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            statusLabel,
            bootIdLabel,
            uptimeLabel,
            recordingLabel,
            timeLabel,
            errorLabel,
            reloadButton,
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
        ])
    }

    private func render(_ state: HealthFeature.State) {
        reloadButton.isEnabled = state != .loading
        errorLabel.isHidden = true
        errorLabel.text = nil

        switch state {
        case .idle:
            statusLabel.text = "Idle"
            renderFields(response: nil)
        case .loading:
            statusLabel.text = "Loading health..."
            renderFields(response: nil)
        case .loaded(let response):
            statusLabel.text = "Connected"
            renderFields(response: response)
        case .failed(let message):
            statusLabel.text = "Unable to reach camera"
            renderFields(response: nil)
            errorLabel.isHidden = false
            errorLabel.text = message
        }
    }

    private func renderFields(response: HealthResponse?) {
        bootIdLabel.text = "Boot ID: \(response?.bootId ?? "--")"
        uptimeLabel.text = "Uptime: \(response.map { "\($0.uptimeS) s" } ?? "--")"
        recordingLabel.text = "Recording: \(response.map { $0.recording ? "yes" : "no" } ?? "--")"
        timeLabel.text = "Pi time: \(response.map { "\($0.tMs) ms" } ?? "--")"
    }

    @objc private func reloadTapped() {
        store.send(.reload)
    }
}
