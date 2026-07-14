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

final class SettingsViewController: UIViewController, UITableViewDataSource {
    private let store: AppStore
    private var observation: StoreObservation?
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private(set) var renderedProjection: RecordingStorageProjection?

    init(dependencies: AppDependencies, store: AppStore) {
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
        view.backgroundColor = .systemGroupedBackground

        tableView.dataSource = self
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
    }

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 2 }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Recording storage"
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Estimated at the current recording quality. When storage fills, DanCam replaces the oldest footage automatically."
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "recording-storage")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "recording-storage")
        let projection = renderedProjection ?? RecordingStorageProjection.project(store.state)
        var content = cell.defaultContentConfiguration()
        if indexPath.row == 0 {
            content.text = "Space for footage"
            content.secondaryText = projection.capacity
            cell.accessibilityLabel = "Space for footage"
            cell.accessibilityValue = projection.capacityAccessibilityValue
        } else {
            content.text = "Estimated footage"
            content.secondaryText = projection.estimate
            cell.accessibilityLabel = "Estimated footage"
            cell.accessibilityValue = projection.estimateAccessibilityValue
        }
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }
}
