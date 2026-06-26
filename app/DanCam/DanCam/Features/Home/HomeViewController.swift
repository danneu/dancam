import UIKit

final class HomeViewController: UIViewController, UITableViewDataSource {
    private let dependencies: AppDependencies
    private let previewViewController: PreviewViewController
    private let recordingStore: Store<RecordingFeature.State, RecordingFeature.Action, AppDependencies>
    private let statusStore: Store<StatusFeature.State, StatusFeature.Action, AppDependencies>
    private let clipsStore: Store<ClipsFeature.State, ClipsFeature.Action, AppDependencies>

    private var recordingObservation: StoreObservation?
    private var statusObservation: StoreObservation?
    private var clipsObservation: StoreObservation?

    private let storageChipView = UIView()
    private let storageProgressView = UIProgressView(progressViewStyle: .bar)
    private let storageFreeLabel = UILabel()
    private let tempWarningPill = StatusPillView()
    private let errorPill = StatusPillView()
    private let recordButton = RecordButton(frame: .zero)
    private let recPill = StatusPillView(caption: "REC", dotColor: .systemRed)
    private let clipsHeaderLabel = UILabel()
    private let clipsTableView = UITableView(frame: .zero, style: .plain)
    private let emptyClipsView = UIStackView()
    private let emptyClipsImageView = UIImageView(image: UIImage(systemName: "film"))
    private let emptyClipsLabel = UILabel()

    private var recordingState = RecordingFeature.State.unknown
    private var clips: [Clip] = []

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        previewViewController = PreviewViewController(dependencies: dependencies)
        recordingStore = Store(
            initialState: .unknown,
            dependencies: dependencies,
            reduce: RecordingFeature.reduce
        )
        statusStore = Store(
            initialState: .idle,
            dependencies: dependencies,
            reduce: StatusFeature.reduce
        )
        clipsStore = Store(
            initialState: .idle,
            dependencies: dependencies,
            reduce: ClipsFeature.reduce
        )
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

        recordingObservation = recordingStore.observe { [weak self] state in
            self?.renderRecording(state)
        }
        statusObservation = statusStore.observe { [weak self] state in
            self?.renderStatus(state)
        }
        clipsObservation = clipsStore.observe { [weak self] state in
            self?.renderClips(state)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        recordingStore.send(.onAppear)
        statusStore.send(.onAppear)
        clipsStore.send(.onAppear)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        statusStore.send(.onDisappear)
        clipsStore.send(.onDisappear)
    }

    private func configureViews() {
        configurePreview()
        configureStorageChip()
        configureStatusPills()
        configureClipsTable()

        recordButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)
        recordButton.apply(.unknown)
        recordButton.translatesAutoresizingMaskIntoConstraints = false

        let belowPreviewStack = UIStackView(arrangedSubviews: [
            storageChipView,
            tempWarningPill,
            errorPill,
        ])
        belowPreviewStack.axis = .vertical
        belowPreviewStack.alignment = .leading
        belowPreviewStack.spacing = 8

        let recordButtonRow = UIView()
        recordButtonRow.translatesAutoresizingMaskIntoConstraints = false
        recordButtonRow.addSubview(recordButton)

        let stack = UIStackView(arrangedSubviews: [
            previewViewController.view,
            belowPreviewStack,
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

    private func configureStorageChip() {
        storageChipView.isAccessibilityElement = true
        storageChipView.backgroundColor = .secondarySystemBackground
        storageChipView.layer.cornerRadius = 12
        storageChipView.layer.cornerCurve = .continuous
        storageChipView.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 8,
            leading: 10,
            bottom: 8,
            trailing: 10
        )

        storageProgressView.progressTintColor = .systemGreen
        storageProgressView.trackTintColor = .tertiarySystemFill

        storageFreeLabel.font = .preferredFont(forTextStyle: .subheadline)
        storageFreeLabel.adjustsFontForContentSizeCategory = true
        storageFreeLabel.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [storageProgressView, storageFreeLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        storageChipView.addSubview(stack)

        NSLayoutConstraint.activate([
            storageProgressView.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),

            stack.leadingAnchor.constraint(equalTo: storageChipView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: storageChipView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: storageChipView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: storageChipView.layoutMarginsGuide.bottomAnchor),
        ])
    }

    private func configureStatusPills() {
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
        emptyClipsLabel.textColor = .secondaryLabel

        emptyClipsView.axis = .vertical
        emptyClipsView.alignment = .center
        emptyClipsView.spacing = 8
        emptyClipsView.addArrangedSubview(emptyClipsImageView)
        emptyClipsView.addArrangedSubview(emptyClipsLabel)

        clipsTableView.dataSource = self
        clipsTableView.register(UITableViewCell.self, forCellReuseIdentifier: "clip")
        clipsTableView.rowHeight = UITableView.automaticDimension
        clipsTableView.estimatedRowHeight = 56
        clipsTableView.tableFooterView = UIView()
        clipsTableView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func renderStatus(_ state: StatusFeature.State) {
        tempWarningPill.isHidden = true
        errorPill.isHidden = true

        switch state {
        case .idle, .loading:
            renderStorageChip(storage: nil)
        case .loaded(let response):
            renderStorageChip(storage: response.storage)
            renderTempWarning(sensor: response.tempC.sensor)
            renderCameraError(response: response)
        case .failed:
            renderStorageChip(storage: nil)
            errorPill.configure(
                caption: "Can't reach camera",
                dotColor: .systemRed,
                backgroundStyle: .tinted(UIColor.systemRed.withAlphaComponent(0.16))
            )
            errorPill.isHidden = false
        }
    }

    private func renderStorageChip(storage: Storage?) {
        guard let storage else {
            storageFreeLabel.text = "--"
            storageProgressView.progress = 0
            storageChipView.alpha = 0.55
            storageChipView.accessibilityLabel = "Storage unavailable"
            return
        }

        let display = Formatters.storageDisplay(storage)
        storageFreeLabel.text = "\(display.freeText) free"
        storageProgressView.progress = Float(display.usedFraction)
        storageChipView.alpha = 1
        storageChipView.accessibilityLabel = "\(display.freeText) free"
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
        let previous = recordingState
        recordingState = state

        if HomeCoordination.shouldRefreshClips(from: previous, to: state) {
            clipsStore.send(.refresh)
        }

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
        case .idle, .loading:
            clips = []
        case .loaded(let clips):
            self.clips = clips
        case .failed:
            clips = []
        }

        clipsTableView.backgroundView = clips.isEmpty ? emptyClipsView : nil
        clipsTableView.reloadData()
    }

    @objc private func recordTapped() {
        switch recordingState {
        case .recording:
            recordingStore.send(.stopTapped)
        case .unknown, .idle, .failed:
            recordingStore.send(.startTapped)
        case .starting, .stopping:
            break
        }
    }

    @objc private func debugTapped() {
        navigationController?.pushViewController(
            HealthViewController(dependencies: dependencies),
            animated: true
        )
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
        content.secondaryText = Formatters.byteSize(clip.bytes)
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }
}
