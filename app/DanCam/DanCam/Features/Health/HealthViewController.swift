import UIKit

final class HealthViewController: UIViewController {
    private let dependencies: AppDependencies
    private let store: Store<HealthFeature.State, HealthFeature.Action, AppDependencies>
    private let appStore: AppStore
    private var observation: StoreObservation?
    private var connectionObservation: StoreObservation?
    private(set) var lastExportOutcome: Result<String, Error>?
    private var isManualRefreshing = false

    private let scrollView = UIScrollView()
    private let refreshControl = UIRefreshControl()
    private let statusLabel = UILabel()
    private let bootIdLabel = UILabel()
    private let uptimeLabel = UILabel()
    private let recordingLabel = UILabel()
    private let timeLabel = UILabel()
    private let telemetryHeaderLabel = UILabel()
    private let telemetryStack = UIStackView()
    private let errorLabel = UILabel()
    private let exportLogsButton = UIButton(type: .system)

    init(
        dependencies: AppDependencies,
        store appStore: AppStore
    ) {
        self.dependencies = dependencies
        store = Store(
            initialState: .idle,
            dependencies: dependencies,
            reduce: HealthFeature.reduce
        )
        self.appStore = appStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HealthViewController is programmatic.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Debug"
        view.backgroundColor = .systemBackground

        configureViews()
        observation = store.observe { [weak self] state in
            self?.render(state)
        }
        connectionObservation = appStore.observe(select: { HealthTelemetry.rows(for: $0.link.world) }) { [weak self] rows in
            self?.renderTelemetry(rows)
        }
        store.send(.onAppear)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    private func configureViews() {
        statusLabel.font = .preferredFont(forTextStyle: .title2)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0

        telemetryHeaderLabel.text = "Telemetry"
        telemetryHeaderLabel.font = .preferredFont(forTextStyle: .headline)
        telemetryHeaderLabel.adjustsFontForContentSizeCategory = true

        telemetryStack.axis = .vertical
        telemetryStack.spacing = 8
        telemetryStack.alignment = .fill

        for label in [bootIdLabel, uptimeLabel, recordingLabel, timeLabel, errorLabel] {
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }

        errorLabel.textColor = .systemRed

        exportLogsButton.setTitle("Export logs", for: .normal)
        exportLogsButton.addTarget(self, action: #selector(exportLogsTapped), for: .touchUpInside)

        refreshControl.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        scrollView.refreshControl = refreshControl
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [
            statusLabel,
            bootIdLabel,
            uptimeLabel,
            recordingLabel,
            timeLabel,
            telemetryHeaderLabel,
            telemetryStack,
            errorLabel,
            exportLogsButton,
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
        ])
    }

    private func render(_ state: HealthFeature.State) {
        if isManualRefreshing, state != .loading {
            refreshControl.endRefreshing()
            isManualRefreshing = false
        }

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

    private func renderTelemetry(_ rows: [TelemetryRow]) {
        for view in telemetryStack.arrangedSubviews {
            telemetryStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for row in rows {
            let label = UILabel()
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.text = "\(row.label): \(row.value)"
            telemetryStack.addArrangedSubview(label)
        }
    }

    @objc private func refreshPulled() {
        isManualRefreshing = true
        store.send(.reload)
        appStore.send(.reconnectStreamIfOffline)
    }

    @objc private func exportLogsTapped() {
        Task { [weak self] in
            await self?.exportLogs()
        }
    }

    func buildExportText() async -> Result<String, Error> {
        let result: Result<String, Error>

        do {
            let body = try await dependencies.logExporter.export(.seconds(600))
            result = .success("""
            DanCam log export
            App version: \(Self.appVersion)
            State snapshot: \(appStore.state.logSnapshot)

            \(body)
            """)
        } catch {
            result = .failure(error)
        }

        lastExportOutcome = result
        return result
    }

    func exportLogsForTesting() async {
        await exportLogs()
    }

    var errorText: String? {
        errorLabel.text
    }

    var isErrorVisible: Bool {
        errorLabel.isHidden == false
    }

    var isRefreshingForTesting: Bool {
        refreshControl.isRefreshing
    }

    var isManualRefreshingForTesting: Bool {
        isManualRefreshing
    }

    var statusTextForTesting: String? {
        statusLabel.text
    }

    func pullToRefreshForTesting() {
        refreshControl.beginRefreshing()
        refreshPulled()
    }

    private func exportLogs() async {
        switch await buildExportText() {
        case .success(let text):
            if errorLabel.text?.hasPrefix("Log export failed:") == true {
                errorLabel.isHidden = true
                errorLabel.text = nil
            }
            let activityController = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            present(activityController, animated: true)
        case .failure(let error):
            errorLabel.isHidden = false
            errorLabel.text = "Log export failed: \(error.localizedDescription)"
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }
}
