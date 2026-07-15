import AVKit
import UIKit

nonisolated struct IncidentArtifactRow: Equatable, Sendable, Identifiable {
    var seq: Int
    var durationMs: UInt64?
    var bytes: UInt64
    var kind: IncidentArtifactKind
    var url: URL

    var id: Int { seq }
    var isPlayable: Bool { kind == .mp4 }
}

@MainActor
final class IncidentDetailViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let dependencies: AppDependencies
    private let store: AppStore
    private let incidentID: UUID
    private let sharePresentation: VideoSharePresentation?
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let playerContainer = UIView()
    private let shareButton = UIBarButtonItem()
    private let deleteButton = UIBarButtonItem()
    private var observation: StoreObservation?
    private var record: IncidentRecord?
    private var rows: [IncidentArtifactRow] = []
    private var selectedRow: IncidentArtifactRow?
    private var playerViewController: AVPlayerViewController?
    var exportTimeZone = TimeZone.current
    private var shareCoordinator: VideoShareCoordinator?

    init(
        dependencies: AppDependencies,
        store: AppStore,
        incidentID: UUID,
        sharePresentation: VideoSharePresentation? = nil
    ) {
        self.dependencies = dependencies
        self.store = store
        self.incidentID = incidentID
        self.sharePresentation = sharePresentation
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("IncidentDetailViewController is programmatic.") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        configureNavigation()
        configureTable()
        configureShareCoordinator()
        let incidentID = incidentID
        observation = store.observe(select: { $0.incidents.incidents.first(where: { $0.id == incidentID }) }) {
            [weak self] record in
            self?.render(record)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil {
            shareCoordinator?.cancel()
        }
    }

    isolated deinit {
        shareCoordinator?.cancel()
    }

    private func configureNavigation() {
        shareButton.image = UIImage(systemName: "square.and.arrow.up")
        shareButton.target = self
        shareButton.action = #selector(shareTapped)
        shareButton.accessibilityLabel = "Share segment"
        shareButton.isEnabled = false
        deleteButton.image = UIImage(systemName: "trash")
        deleteButton.style = .plain
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.tintColor = .systemRed
        deleteButton.accessibilityLabel = "Delete incident"
        navigationItem.rightBarButtonItems = [shareButton, deleteButton]
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        playerContainer.backgroundColor = .black
        playerContainer.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 240)
        tableView.tableHeaderView = playerContainer
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureShareCoordinator() {
        shareCoordinator = VideoShareCoordinator(
            preparer: dependencies.shareArtifactPreparer,
            presenter: self,
            shareButton: shareButton,
            presentation: sharePresentation,
            preparingChanged: { [weak self] preparing in
                self?.setSharePreparationControls(preparing: preparing)
            },
            sourceUnavailable: { [weak self] in
                self?.handleShareSourceUnavailable()
            }
        )
    }

    private func render(_ record: IncidentRecord?) {
        guard let record else {
            navigationController?.popViewController(animated: true)
            return
        }
        self.record = record
        navigationItem.title = Formatters.incidentPressedAt(
            Date(timeIntervalSince1970: Double(record.pressedAtMs) / 1_000)
        )
        rows = artifactRows(record: record)
        if let selected = selectedRow, rows.contains(where: { $0.id == selected.id }) == false {
            shareCoordinator?.cancel()
            selectedRow = nil
            shareButton.isEnabled = false
            detachPlayer()
        }
        tableView.reloadData()
    }

    private func artifactRows(record: IncidentRecord) -> [IncidentArtifactRow] {
        let directory = dependencies.incidentStore.directoryURL(record.id)
        return record.wanted.compactMap { segment in
            guard segment.state == .pulled else { return nil }
            let stem = String(format: "seg_%05d", segment.seq)
            for kind in [IncidentArtifactKind.mp4, .ts] {
                let url = directory.appending(path: "\(stem).\(kind.rawValue)")
                if FileManager.default.fileExists(atPath: url.path) {
                    return IncidentArtifactRow(
                        seq: segment.seq,
                        durationMs: segment.durMs,
                        bytes: segment.bytes ?? 0,
                        kind: kind,
                        url: url
                    )
                }
            }
            return nil
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "segment")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "segment")
        let row = rows[indexPath.row]
        cell.textLabel?.text = String(format: "seg_%05d.%@", row.seq, row.kind.rawValue)
        cell.detailTextLabel?.text = [
            row.durationMs.map(Formatters.approximateDuration),
            row.bytes > 0 ? Formatters.byteSize(row.bytes) : nil,
            row.isPlayable ? "Tap to play" : "Share only",
        ].compactMap { $0 }.joined(separator: " - ")
        cell.accessoryType = row.isPlayable ? .disclosureIndicator : .none
        cell.imageView?.image = UIImage(systemName: row.isPlayable ? "play.rectangle" : "doc")
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard shareCoordinator?.isPreparing != true else { return }
        let row = rows[indexPath.row]
        selectedRow = row
        shareButton.isEnabled = true
        if row.isPlayable { play(row.url) }
        tableView.deselectRow(at: indexPath, animated: true)
    }

    private func play(_ url: URL) {
        detachPlayer()
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        addChild(controller)
        controller.view.frame = playerContainer.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        playerContainer.addSubview(controller.view)
        controller.didMove(toParent: self)
        playerViewController = controller
        controller.player?.play()
    }

    private func detachPlayer() {
        playerViewController?.player?.pause()
        playerViewController?.willMove(toParent: nil)
        playerViewController?.view.removeFromSuperview()
        playerViewController?.removeFromParent()
        playerViewController = nil
    }

    @objc private func shareTapped() {
        guard let row = selectedRow, let record else { return }
        let pressedAt = Date(timeIntervalSince1970: Double(record.pressedAtMs) / 1_000)
        let request = SharePreparationRequest(
            sourceURL: row.url,
            suggestedFilename: Formatters.incidentExportFilename(
                pressedAt: pressedAt,
                seq: row.seq,
                fileExtension: row.kind.rawValue,
                timeZone: exportTimeZone
            )
        )
        shareCoordinator?.start(request)
    }

    @objc private func deleteTapped() {
        shareCoordinator?.cancel()
        present(IncidentDeleteConfirmation.alert { [weak self] in
            guard let self else { return }
            self.store.send(.incidents(.deleteTapped(.readable(self.incidentID))))
        }, animated: true)
    }

    private func setSharePreparationControls(preparing: Bool) {
        shareButton.isEnabled = preparing == false && selectedRow != nil
        deleteButton.isEnabled = preparing == false
        tableView.allowsSelection = preparing == false
    }

    private func handleShareSourceUnavailable() {
        selectedRow = nil
        shareButton.isEnabled = false
        detachPlayer()
        tableView.reloadData()
        let alert = UIAlertController(
            title: "Unable to Share Video",
            message: "The video file is no longer available.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    var rowsForTesting: [IncidentArtifactRow] { rows }
    var isSharePreparingForTesting: Bool { shareCoordinator?.isPreparing ?? false }
    var sharePreparationAccessibilityLabelForTesting: String? { shareButton.customView?.accessibilityLabel }
    var isShareButtonEnabledForTesting: Bool { shareButton.isEnabled }
    var isDeleteButtonEnabledForTesting: Bool { deleteButton.isEnabled }
    var allowsSelectionForTesting: Bool { tableView.allowsSelection }
    var presentedShareURLForTesting: URL? { shareCoordinator?.lastPresentedURLForTesting }
    var hasSelectedRowForTesting: Bool { selectedRow != nil }

    func selectRowForTesting(at index: Int) {
        tableView(tableView, didSelectRowAt: IndexPath(row: index, section: 0))
    }

    func shareTappedForTesting() {
        shareTapped()
    }
}
