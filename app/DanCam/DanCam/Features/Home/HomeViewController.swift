import UIKit

nonisolated struct LiveSegment: Equatable, Sendable {
    var sessionId: UInt64
    var id: Int
    var seedDurMs: UInt64?
    var anchor: ContinuousClock.Instant

    func elapsedDurMs(at now: ContinuousClock.Instant) -> UInt64 {
        (seedDurMs ?? 0) + Self.milliseconds(from: anchor.duration(to: now))
    }

    private static func milliseconds(from duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds > 0 || components.attoseconds > 0 else { return 0 }

        let seconds = UInt64(max(components.seconds, 0))
        let attoseconds = UInt64(max(components.attoseconds, 0))
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }
}

nonisolated enum HomeRow: Equatable, Sendable {
    case live(LiveSegment)
    case finished(Clip)

    static func compose(
        clips: [Clip],
        recorder: RecorderSnapshot?,
        previousLive: LiveSegment?,
        now: ContinuousClock.Instant
    ) -> [HomeRow] {
        var rows = clips.map(HomeRow.finished)
        guard let recorder, let currentSegment = recorder.currentSegment else {
            return rows
        }

        let live: LiveSegment
        if let previousLive,
           previousLive.sessionId == recorder.session,
           previousLive.id == currentSegment.id {
            if let durMs = currentSegment.durMs {
                live = LiveSegment(
                    sessionId: recorder.session,
                    id: currentSegment.id,
                    seedDurMs: max(durMs, previousLive.elapsedDurMs(at: now)),
                    anchor: now
                )
            } else {
                live = previousLive
            }
        } else {
            live = LiveSegment(
                sessionId: recorder.session,
                id: currentSegment.id,
                seedDurMs: currentSegment.durMs,
                anchor: now
            )
        }

        rows.insert(.live(live), at: 0)
        return rows
    }

    var liveSegment: LiveSegment? {
        if case .live(let segment) = self {
            return segment
        }
        return nil
    }
}

final class HomeViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, ConnectionResumable {
    private let dependencies: AppDependencies
    private let store: AppStore
    private let previewViewController: PreviewViewController

    private var recordingObservation: StoreObservation?
    private var connectionObservation: StoreObservation?
    private var clipsObservation: StoreObservation?

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
    private let clock = ContinuousClock()

    private var recordingState: RecordingFeature.State = .unknown
    private var world: World?
    private var finishedClips: [Clip] = []
    private var rows: [HomeRow] = []
    private var liveTickTimer: Timer?
    private var isVisible = false

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
            self?.recordingState = state
            self?.renderRecording(state)
        }
        connectionObservation = store.observe(\.link.world) { [weak self] world in
            self?.world = world
            self?.renderConnectionPills(world)
            self?.renderRows()
        }
        clipsObservation = store.observe(\.clips) { [weak self] state in
            self?.renderClips(state)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        updateLiveTickTimer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        store.send(.clips(.onDisappear))
        stopLiveTickTimer()
    }

    deinit {
        stopLiveTickTimer()
    }

    func resumeLiveWork() {
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
        clipsTableView.register(LiveClipCell.self, forCellReuseIdentifier: "liveClip")
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

    private func renderConnectionPills(_ world: World?) {
        tempWarningPill.isHidden = true
        errorPill.isHidden = true

        if let world {
            renderTempWarning(sensor: world.tempC.sensor)
            renderCameraError(world: world)
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

    private func renderCameraError(world: World) {
        guard world.cameraState == .offline else {
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
        finishedClips = state.clips
        renderRows()
    }

    private func renderRows(now: ContinuousClock.Instant? = nil) {
        let now = now ?? clock.now
        let previousLive = rows.first?.liveSegment
        rows = HomeRow.compose(
            clips: finishedClips,
            recorder: world?.recorder,
            previousLive: previousLive,
            now: now
        )

        clipsTableView.backgroundView = rows.isEmpty ? emptyClipsBackgroundView : nil
        clipsTableView.reloadData()
        updateLiveTickTimer()
    }

    private func updateLiveTickTimer() {
        let hasLiveRow = rows.contains { $0.liveSegment != nil }
        if hasLiveRow, isVisible {
            guard liveTickTimer == nil else { return }

            liveTickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.updateVisibleLiveElapsed()
            }
        } else {
            stopLiveTickTimer()
        }
    }

    private func stopLiveTickTimer() {
        liveTickTimer?.invalidate()
        liveTickTimer = nil
    }

    private func updateVisibleLiveElapsed() {
        guard let row = rows.firstIndex(where: { $0.liveSegment != nil }),
              let segment = rows[row].liveSegment,
              let cell = clipsTableView.cellForRow(at: IndexPath(row: row, section: 0)) as? LiveClipCell else {
            return
        }

        cell.updateElapsed(segment: segment, now: clock.now)
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
        refreshControl.endRefreshing()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch rows[indexPath.row] {
        case .live(let segment):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: "liveClip",
                for: indexPath
            ) as? LiveClipCell else {
                return UITableViewCell(style: .default, reuseIdentifier: nil)
            }
            cell.configure(segment: segment, now: clock.now)
            return cell

        case .finished(let clip):
            let cell = tableView.dequeueReusableCell(withIdentifier: "clip", for: indexPath)
            configureFinishedCell(cell, clip: clip)
            return cell
        }
    }

    private func configureFinishedCell(_ cell: UITableViewCell, clip: Clip) {
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
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard rows.indices.contains(indexPath.row) else { return }

        switch rows[indexPath.row] {
        case .live:
            return
        case .finished(let clip):
            tableView.deselectRow(at: indexPath, animated: true)
            navigationController?.pushViewController(
                ClipViewerViewController(dependencies: dependencies, clip: clip),
                animated: true
            )
        }
    }
}

private final class LiveClipCell: UITableViewCell {
    private let titleLabel = UILabel()
    private let elapsedLabel = UILabel()
    private let recBadge = StatusPillView(caption: "REC", dotColor: .systemRed)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LiveClipCell is programmatic.")
    }

    func configure(segment: LiveSegment, now: ContinuousClock.Instant) {
        titleLabel.text = String(format: "seg_%05d.ts", segment.id)
        updateElapsed(segment: segment, now: now)
        accessibilityLabel = "\(titleLabel.text ?? ""), recording, \(elapsedLabel.text ?? "")"
    }

    func updateElapsed(segment: LiveSegment, now: ContinuousClock.Instant) {
        elapsedLabel.text = Formatters.countUpDuration(segment.elapsedDurMs(at: now))
    }

    private func configureViews() {
        selectionStyle = .none

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingMiddle

        let elapsedBaseFont = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .regular
        )
        elapsedLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: elapsedBaseFont)
        elapsedLabel.adjustsFontForContentSizeCategory = true
        elapsedLabel.textColor = .secondaryLabel
        elapsedLabel.textAlignment = .right
        elapsedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        recBadge.configure(
            caption: "REC",
            dotColor: .systemRed,
            backgroundStyle: .tinted(UIColor.systemRed.withAlphaComponent(0.14))
        )
        recBadge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [titleLabel, recBadge, elapsedLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
        ])
    }
}
