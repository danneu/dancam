import UIKit

final class HomeViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, ConnectionResumable {
    private let dependencies: AppDependencies
    private let store: AppStore
    private let previewViewController: PreviewViewController

    private var recordingObservation: StoreObservation?
    private var connectionObservation: StoreObservation?
    private var clipsObservation: StoreObservation?
    private var manualRefreshObservation: StoreObservation?

    private let statusPillsStack = UIStackView()
    private let tempWarningPill = StatusPillView()
    private let errorPill = StatusPillView()
    private let recordButton = RecordButton(frame: .zero)
    private let recPill = StatusPillView(caption: "REC", dotColor: .systemRed)
    private let clipsHeaderLabel = UILabel()
    private let clipsTableView = UITableView(frame: .zero, style: .plain)
    private let refreshControl = UIRefreshControl()
    private let emptyClipsBackgroundView = UIView()
    private let emptyClipsView = UIStackView()
    private let emptyClipsImageView = UIImageView(image: UIImage(systemName: "film"))
    private let emptyClipsLabel = UILabel()

    private var clips: [Clip] = []

    init(
        dependencies: AppDependencies,
        store: AppStore
    ) {
        self.dependencies = dependencies
        self.store = store
        previewViewController = PreviewViewController(dependencies: dependencies)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HomeViewController is programmatic.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "DanCam"
        view.backgroundColor = .systemBackground
        let debugItem = UIBarButtonItem(
            image: UIImage(systemName: "chart.bar"),
            style: .plain,
            target: self,
            action: #selector(debugTapped)
        )
        debugItem.accessibilityLabel = "Status detail"
        navigationItem.rightBarButtonItem = debugItem

        addChild(previewViewController)
        configureViews()
        previewViewController.didMove(toParent: self)

        recordingObservation = store.observe(\.recording) { [weak self] state in
            self?.renderRecording(state)
        }
        connectionObservation = store.observe(\.connection.lastStatus) { [weak self] status in
            self?.renderConnectionPills(status)
        }
        clipsObservation = store.observe(\.clips) { [weak self] state in
            self?.renderClips(state)
        }
        manualRefreshObservation = store.observe(\.pendingManualRefresh) { [weak self] pending in
            if pending == false {
                self?.refreshControl.endRefreshing()
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        store.send(.clips(.onAppear))
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        store.send(.clips(.onDisappear))
    }

    func resumeLiveWork() {
        store.send(.clips(.refresh))
        previewViewController.reconnect()
    }

    private func configureViews() {
        configurePreview()
        configureStatusPills()
        configureClipsTable()

        recordButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)
        recordButton.apply(.unknown)
        recordButton.translatesAutoresizingMaskIntoConstraints = false

        let recordButtonRow = UIView()
        recordButtonRow.translatesAutoresizingMaskIntoConstraints = false
        recordButtonRow.addSubview(recordButton)

        let stack = UIStackView(arrangedSubviews: [
            previewViewController.view,
            statusPillsStack,
            recordButtonRow,
            clipsHeaderLabel,
            clipsTableView,
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            recPill.topAnchor.constraint(equalTo: previewViewController.view.topAnchor, constant: 10),
            recPill.trailingAnchor.constraint(equalTo: previewViewController.view.trailingAnchor, constant: -10),

            recordButton.topAnchor.constraint(equalTo: recordButtonRow.topAnchor),
            recordButton.bottomAnchor.constraint(equalTo: recordButtonRow.bottomAnchor),
            recordButton.centerXAnchor.constraint(equalTo: recordButtonRow.centerXAnchor),

            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            previewViewController.view.heightAnchor.constraint(
                equalTo: previewViewController.view.widthAnchor,
                multiplier: 0.75
            ),
            clipsTableView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }

    private func configurePreview() {
        previewViewController.view.backgroundColor = .black
        previewViewController.view.layer.cornerRadius = 16
        previewViewController.view.layer.cornerCurve = .continuous
        previewViewController.view.layer.masksToBounds = true
        previewViewController.view.translatesAutoresizingMaskIntoConstraints = false

        recPill.configure(caption: "REC", dotColor: .systemRed, backgroundStyle: .material)
        recPill.accessibilityLabel = "Recording"
        recPill.isHidden = true
        recPill.translatesAutoresizingMaskIntoConstraints = false
        previewViewController.view.addSubview(recPill)
    }

    private func configureStatusPills() {
        statusPillsStack.axis = .vertical
        statusPillsStack.alignment = .leading
        statusPillsStack.spacing = 8
        statusPillsStack.isHidden = true
        statusPillsStack.addArrangedSubview(tempWarningPill)
        statusPillsStack.addArrangedSubview(errorPill)

        tempWarningPill.isHidden = true
        errorPill.isHidden = true
    }

    private func configureClipsTable() {
        clipsHeaderLabel.text = "Recent clips"
        clipsHeaderLabel.font = .preferredFont(forTextStyle: .headline)
        clipsHeaderLabel.adjustsFontForContentSizeCategory = true

        emptyClipsImageView.tintColor = .secondaryLabel
        emptyClipsImageView.contentMode = .scaleAspectFit

        emptyClipsLabel.text = "No clips yet"
        emptyClipsLabel.font = .preferredFont(forTextStyle: .subheadline)
        emptyClipsLabel.adjustsFontForContentSizeCategory = true
        emptyClipsLabel.numberOfLines = 0
        emptyClipsLabel.textAlignment = .center
        emptyClipsLabel.textColor = .secondaryLabel

        emptyClipsView.axis = .vertical
        emptyClipsView.alignment = .center
        emptyClipsView.spacing = 8
        emptyClipsView.translatesAutoresizingMaskIntoConstraints = false
        emptyClipsView.addArrangedSubview(emptyClipsImageView)
        emptyClipsView.addArrangedSubview(emptyClipsLabel)

        emptyClipsBackgroundView.addSubview(emptyClipsView)

        clipsTableView.dataSource = self
        clipsTableView.delegate = self
        clipsTableView.register(UITableViewCell.self, forCellReuseIdentifier: "clip")
        clipsTableView.rowHeight = UITableView.automaticDimension
        clipsTableView.estimatedRowHeight = 56
        clipsTableView.tableFooterView = UIView()
        refreshControl.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        clipsTableView.refreshControl = refreshControl
        clipsTableView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            emptyClipsView.centerXAnchor.constraint(equalTo: emptyClipsBackgroundView.centerXAnchor),
            emptyClipsView.centerYAnchor.constraint(equalTo: emptyClipsBackgroundView.centerYAnchor),
        ])
    }

    private func renderConnectionPills(_ status: StatusResponse?) {
        tempWarningPill.isHidden = true
        errorPill.isHidden = true

        if let response = status {
            renderTempWarning(sensor: response.tempC.sensor)
            renderCameraError(response: response)
        }

        statusPillsStack.isHidden = tempWarningPill.isHidden && errorPill.isHidden
    }

    private func renderTempWarning(sensor: Double?) {
        guard let sensor, let warning = Formatters.sensorWarning(for: sensor) else {
            tempWarningPill.isHidden = true
            return
        }

        let color: UIColor = warning == .critical ? .systemRed : .systemOrange
        tempWarningPill.configure(
            caption: "\(Formatters.temperature(sensor)) camera",
            dotColor: color,
            backgroundStyle: .tinted(color.withAlphaComponent(0.16))
        )
        tempWarningPill.isHidden = false
    }

    private func renderCameraError(response: StatusResponse) {
        guard response.cameraState == .offline else {
            errorPill.isHidden = true
            return
        }

        errorPill.configure(
            caption: "Camera offline",
            dotColor: .systemRed,
            backgroundStyle: .tinted(UIColor.systemRed.withAlphaComponent(0.16))
        )
        errorPill.isHidden = false
    }

    private func renderRecording(_ state: RecordingFeature.State) {
        switch state {
        case .starting, .recording, .stopping:
            recPill.isHidden = false
        case .unknown, .idle, .failed:
            recPill.isHidden = true
        }

        recordButton.apply(state)
    }

    private func renderClips(_ state: ClipsFeature.State) {
        switch state {
        case .loaded(let clips):
            self.clips = clips
        case .idle, .loading, .failed:
            break
        }

        clipsTableView.backgroundView = clips.isEmpty ? emptyClipsBackgroundView : nil
        clipsTableView.reloadData()
    }

    @objc private func recordTapped() {
        store.send(.recordTapped)
    }

    @objc private func debugTapped() {
        navigationController?.pushViewController(
            HealthViewController(dependencies: dependencies, store: store),
            animated: true
        )
    }

    @objc private func refreshPulled() {
        store.send(.manualRefresh)
        previewViewController.reconnect()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        clips.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "clip", for: indexPath)
        let clip = clips[indexPath.row]
        let filename = String(format: "seg_%05d.ts", clip.id)
        var content = UIListContentConfiguration.subtitleCell()
        content.text = filename
        content.secondaryText = Formatters.clipMetadata(durMs: clip.durMs, bytes: clip.bytes)
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.selectionStyle = .default
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard clips.indices.contains(indexPath.row) else { return }

        navigationController?.pushViewController(
            ClipViewerViewController(dependencies: dependencies, clip: clips[indexPath.row]),
            animated: true
        )
    }
}
