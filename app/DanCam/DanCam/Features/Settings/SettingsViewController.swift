import UIKit

nonisolated struct RecordingStorageProjection: Equatable {
    var capacity: String
    var capacityAccessibilityValue: String
    var estimate: String
    var estimateAccessibilityValue: String

    static func project(_ state: AppFeature.State) -> Self {
        guard case .online(let world) = state.link else {
            return Self(
                capacity: "Not connected",
                capacityAccessibilityValue: "Not connected",
                estimate: "Not connected",
                estimateAccessibilityValue: "Not connected"
            )
        }
        guard let storage = world.storage else {
            return Self(
                capacity: "Unavailable",
                capacityAccessibilityValue: "Unavailable",
                estimate: "Unavailable",
                estimateAccessibilityValue: "Unavailable"
            )
        }

        let capacity = Formatters.byteSize(storage.recordingCapacityBytes)
        guard let duration = state.retentionEstimator.estimatedDurationMs(
            capacityBytes: storage.recordingCapacityBytes
        ) else {
            return Self(
                capacity: capacity,
                capacityAccessibilityValue: capacity,
                estimate: "Calculating...",
                estimateAccessibilityValue: "Calculating"
            )
        }
        let estimate = Formatters.estimatedFootage(duration)
        return Self(
            capacity: capacity,
            capacityAccessibilityValue: capacity,
            estimate: estimate.display,
            estimateAccessibilityValue: estimate.accessibility
        )
    }
}

nonisolated struct CameraSetupProjection: Equatable {
    var status: String

    static func project(_ state: AppFeature.State) -> Self {
        guard let world = state.link.onlineWorld else { return Self(status: "Not connected") }
        switch world.commissioning.state {
        case .preparing:
            return Self(status: "Preparing camera...")
        case .complete:
            return Self(status: "Ready")
        case .failed:
            let reason = world.commissioning.reason ?? "commissioning_failed"
            return Self(status: "Setup failed: \(reason.replacingOccurrences(of: "_", with: " "))")
        }
    }
}

final class SettingsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let store: AppStore
    private let onboarding: OnboardingClient
    private var observation: StoreObservation?
    private var setupObservation: StoreObservation?
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private(set) var renderedProjection: RecordingStorageProjection?

    init(dependencies: AppDependencies, store: AppStore) {
        self.store = store
        onboarding = dependencies.onboarding
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsViewController is programmatic.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = "Settings"
        view.backgroundColor = .systemGroupedBackground

        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        observation = store.observe(select: RecordingStorageProjection.project) { [weak self] projection in
            self?.renderedProjection = projection
            self?.tableView.reloadData()
        }
        setupObservation = store.observe(select: CameraSetupProjection.project) { [weak self] _ in
            self?.tableView.reloadData()
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 2 : 2
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Camera setup" : "Recording storage"
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 1 else { return "Scan the QR generated when this camera card was flashed." }
        return "Estimated at the current recording quality. When storage fills, DanCam replaces the oldest footage automatically."
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "settings-row")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "settings-row")
        let projection = renderedProjection ?? RecordingStorageProjection.project(store.state)
        cell.accessibilityLabel = nil
        cell.accessibilityValue = nil
        cell.accessibilityHint = nil
        cell.accessoryType = .none
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        if indexPath.section == 0, indexPath.row == 0 {
            content.text = "Add Camera"
            content.image = UIImage(systemName: "qrcode.viewfinder")
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            cell.accessibilityHint = "Opens the setup QR scanner"
        } else if indexPath.section == 0 {
            content.text = "Setup status"
            content.secondaryText = CameraSetupProjection.project(store.state).status
            cell.selectionStyle = .none
            cell.accessoryType = .none
        } else if indexPath.row == 0 {
            content.text = "Space for footage"
            content.secondaryText = projection.capacity
            cell.accessibilityLabel = "Space for footage"
            cell.accessibilityValue = projection.capacityAccessibilityValue
            cell.accessoryType = .none
        } else {
            content.text = "Estimated footage"
            content.secondaryText = projection.estimate
            cell.accessibilityLabel = "Estimated footage"
            cell.accessibilityValue = projection.estimateAccessibilityValue
        }
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        cell.contentConfiguration = content
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath == IndexPath(row: 0, section: 0) else { return }
        navigationController?.pushViewController(
            AddCameraViewController(onboarding: onboarding),
            animated: true
        )
    }
}
