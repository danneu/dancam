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
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let playerContainer = UIView()
    private let shareButton = UIBarButtonItem()
    private var observation: StoreObservation?
    private var record: IncidentRecord?
    private var rows: [IncidentArtifactRow] = []
    private var selectedRow: IncidentArtifactRow?
    private var playerViewController: AVPlayerViewController?
    private var shareArtifactDirectories: Set<URL> = []

    var shareScratchDirectory = FileManager.default.temporaryDirectory
        .appending(path: "incident-share", directoryHint: .isDirectory)
    var exportTimeZone = TimeZone.current

    init(dependencies: AppDependencies, store: AppStore, incidentID: UUID) {
        self.dependencies = dependencies
        self.store = store
        self.incidentID = incidentID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("IncidentDetailViewController is programmatic.") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        configureNavigation()
        configureTable()
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

    isolated deinit {
        for directory in shareArtifactDirectories { try? FileManager.default.removeItem(at: directory) }
    }

    private func configureNavigation() {
        shareButton.image = UIImage(systemName: "square.and.arrow.up")
        shareButton.target = self
        shareButton.action = #selector(shareTapped)
        shareButton.accessibilityLabel = "Share segment"
        shareButton.isEnabled = false
        let deleteButton = UIBarButtonItem(
            image: UIImage(systemName: "trash"),
            style: .plain,
            target: self,
            action: #selector(deleteTapped)
        )
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
        guard let row = selectedRow, let artifact = makeShareArtifact(row: row) else { return }
        let controller = UIActivityViewController(activityItems: [artifact.url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceItem = shareButton
        if let directory = artifact.temporaryDirectory {
            controller.completionWithItemsHandler = { [weak self] _, _, _, _ in
                try? FileManager.default.removeItem(at: directory)
                self?.shareArtifactDirectories.remove(directory)
            }
        }
        present(controller, animated: true)
    }

    @objc private func deleteTapped() {
        present(IncidentDeleteConfirmation.alert { [weak self] in
            guard let self else { return }
            self.store.send(.incidents(.deleteTapped(.readable(self.incidentID))))
        }, animated: true)
    }

    private struct ShareArtifact {
        var url: URL
        var temporaryDirectory: URL?
    }

    private func makeShareArtifact(row: IncidentArtifactRow) -> ShareArtifact? {
        guard let record else { return nil }
        let subdirectory = shareScratchDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let pressedAt = Date(timeIntervalSince1970: Double(record.pressedAtMs) / 1_000)
        let destination = subdirectory.appending(path: Formatters.incidentExportFilename(
            pressedAt: pressedAt,
            seq: row.seq,
            fileExtension: row.kind.rawValue,
            timeZone: exportTimeZone
        ))
        do {
            try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: row.url, to: destination)
            shareArtifactDirectories.insert(subdirectory)
            return ShareArtifact(url: destination, temporaryDirectory: subdirectory)
        } catch {
            try? FileManager.default.removeItem(at: subdirectory)
            return FileManager.default.fileExists(atPath: row.url.path)
                ? ShareArtifact(url: row.url, temporaryDirectory: nil)
                : nil
        }
    }

    func makeShareArtifactForTesting(row: IncidentArtifactRow) -> (url: URL, temporaryDirectory: URL?)? {
        guard let artifact = makeShareArtifact(row: row) else { return nil }
        return (artifact.url, artifact.temporaryDirectory)
    }

    var rowsForTesting: [IncidentArtifactRow] { rows }
}
