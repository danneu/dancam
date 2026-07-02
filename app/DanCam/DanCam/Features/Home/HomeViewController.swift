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

final class HomeViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITableViewDataSourcePrefetching, ConnectionResumable {
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
    private let paginationThreshold = 4

    private var recordingState: RecordingFeature.State = .unknown
    private var world: World?
    private var finishedClips: [Clip] = []
    private var rows: [HomeRow] = []
    private var liveTickTimer: Timer?
    private var isVisible = false
    private var prefetchHandles: [IndexPath: ThumbnailLoader.PrefetchHandle] = [:]

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
        reconfigureVisibleThumbnails()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        store.send(.clips(.onDisappear))
        stopLiveTickTimer()
        cancelAllPrefetches()
        quietVisibleThumbnailLoads()
    }

    isolated deinit {
        stopLiveTickTimer()
        cancelAllPrefetches()
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
        clipsTableView.prefetchDataSource = self
        clipsTableView.register(ClipThumbnailCell.self, forCellReuseIdentifier: "clipThumbnail")
        clipsTableView.register(LiveClipCell.self, forCellReuseIdentifier: "liveClip")
        clipsTableView.rowHeight = UITableView.automaticDimension
        clipsTableView.estimatedRowHeight = 72
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

        // A full reload invalidates every index-path key in the prefetch map, so drop the
        // outstanding handles (still-queued warms are cancelled; post-permit warms finish and
        // cache regardless). Any still-wanted row is re-requested by the next prefetch/cellForRow.
        cancelAllPrefetches()

        clipsTableView.backgroundView = rows.isEmpty ? emptyClipsBackgroundView : nil
        clipsTableView.reloadData()
        updateLiveTickTimer()
    }

    private func updateLiveTickTimer() {
        let hasLiveRow = rows.contains { $0.liveSegment != nil }
        if hasLiveRow, isVisible {
            guard liveTickTimer == nil else { return }

            liveTickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateVisibleLiveElapsed()
                }
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
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: "clipThumbnail",
                for: indexPath
            ) as? ClipThumbnailCell else {
                return UITableViewCell(style: .default, reuseIdentifier: nil)
            }
            cell.configure(clip: clip, loader: dependencies.thumbnailLoader)
            return cell
        }
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

    func tableView(
        _ tableView: UITableView,
        willDisplay cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {
        guard rows.indices.contains(indexPath.row),
              indexPath.row >= max(rows.count - paginationThreshold, 0),
              case .finished = rows[indexPath.row] else {
            return
        }

        store.send(.clips(.loadMore))
    }

    func tableView(
        _ tableView: UITableView,
        didEndDisplaying cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {
        // `prepareForReuse` fires only on re-dequeue, so a row scrolled offscreen but not yet
        // reused would keep its load (and strong token) live. Quiet it now: a still-queued
        // entry is dropped, a scroll-back re-requests it cache-first.
        (cell as? ClipThumbnailCell)?.cancelLoad()
    }

    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard rows.indices.contains(indexPath.row),
                  case .finished(let clip) = rows[indexPath.row] else {
                continue
            }
            // Cancel-before-replace: a `PrefetchHandle` is a value type with no `deinit`, so
            // overwriting a slot without cancelling would orphan the prior handle's token and
            // keep pinning its loader entry.
            prefetchHandles[indexPath]?.cancel()
            prefetchHandles[indexPath] = dependencies.thumbnailLoader.prefetch(clip)
        }
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        // Cancel the stored handle -- never re-derive a clip id from `rows`, which a reload can
        // shift; the handle already carries the correct `(id, etag)`.
        for indexPath in indexPaths {
            prefetchHandles.removeValue(forKey: indexPath)?.cancel()
        }
    }

    private func cancelAllPrefetches() {
        for handle in prefetchHandles.values {
            handle.cancel()
        }
        prefetchHandles.removeAll()
    }

    private func quietVisibleThumbnailLoads() {
        for cell in clipsTableView.visibleCells {
            (cell as? ClipThumbnailCell)?.cancelLoad()
        }
    }

    /// Re-request visible rows on return by reconfiguring the visible `ClipThumbnailCell`s
    /// *in place* -- the same shape `updateVisibleLiveElapsed()` uses -- rather than a
    /// `reloadData()`. A reload would route each cell through `prepareForReuse` (blanking it
    /// to the placeholder) before `configure`, flashing every already-painted cell; in-place
    /// reconfigure skips reuse, so a painted cell hits the same-identity no-op and a cell
    /// quieted on the way out retries once, cache-first.
    private func reconfigureVisibleThumbnails() {
        guard let visibleRows = clipsTableView.indexPathsForVisibleRows else { return }
        for indexPath in visibleRows {
            guard rows.indices.contains(indexPath.row),
                  case .finished(let clip) = rows[indexPath.row],
                  let cell = clipsTableView.cellForRow(at: indexPath) as? ClipThumbnailCell else {
                continue
            }
            cell.configure(clip: clip, loader: dependencies.thumbnailLoader)
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
