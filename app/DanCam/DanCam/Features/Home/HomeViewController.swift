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

    var id: HomeRowID {
        switch self {
        case .live(let segment):
            .live(session: segment.sessionId, id: segment.id)
        case .finished(let clip):
            .finished(clip.id)
        }
    }

    var finishedIdentity: ClipThumbnailIdentity? {
        if case .finished(let clip) = self {
            return ClipThumbnailIdentity(clip)
        }
        return nil
    }
}

final class HomeViewController: UIViewController, UITableViewDelegate, UITableViewDataSourcePrefetching, ConnectionResumable {
    private let dependencies: AppDependencies
    private let store: AppStore
    private let previewViewController: PreviewViewController

    private var recordingObservation: StoreObservation?
    private var statusPillsObservation: StoreObservation?
    private var recorderObservation: StoreObservation?
    private var clipsObservation: StoreObservation?
    private var clipsStatusObservation: StoreObservation?

    private let headerContainer = UIView()
    private let headerStack = UIStackView()
    private let statusPillsStack = UIStackView()
    private let tempWarningPill = StatusPillView()
    private let errorPill = StatusPillView()
    private let timeUnverifiedPill = StatusPillView()
    private let recordButton = RecordButton(frame: .zero)
    private let recordButtonRow = UIView()
    private let recPill = StatusPillView(caption: "REC", dotColor: .systemRed)
    private let clipsHeaderLabel = UILabel()
    private let clipsTableView = UITableView(frame: .zero, style: .plain)
    private let refreshControl = UIRefreshControl()
    private let clipsFailureBanner = StatusPillView()
    private let emptyClipsBackgroundView = UIView()
    private let emptyClipsView = UIStackView()
    private let emptyClipsImageView = UIImageView(image: UIImage(systemName: "film"))
    private let emptyClipsLabel = UILabel()
    private let clock = ContinuousClock()
    private let paginationThreshold = 4
    private var dataSource: UITableViewDiffableDataSource<HomeSection, HomeRowID>!

    private var recordingState: RecordingFeature.State = .unknown
    private var recorder: RecorderSnapshot?
    private var finishedClips: [Clip] = []
    private var clipsStatus: ClipsFeature.State.Status = .idle
    private var rows: [HomeRow] = []
    private var rowsByID: [HomeRowID: HomeRow] = [:]
    private var liveTickTimer: Timer?
    private var isVisible = false
    private var isManualRefreshing = false
    private var lastFittedHeaderWidth: CGFloat?
    private var needsHeaderRefit = true
    private var prefetchHandles: [ClipThumbnailIdentity: ThumbnailLoader.PrefetchHandle] = [:]

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

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (viewController: HomeViewController, _) in
            viewController.needsHeaderRefit = true
            viewController.view.setNeedsLayout()
        }

        recordingObservation = store.observe(\.recording) { [weak self] state in
            self?.recordingState = state
            self?.renderRecording(state)
        }
        statusPillsObservation = store.observe(select: { HomeStatusPills.from($0.link.world) }) { [weak self] pills in
            self?.renderStatusPills(pills)
        }
        recorderObservation = store.observe(\.link.world?.recorder) { [weak self] recorder in
            self?.recorder = recorder
            self?.renderRows()
        }
        clipsObservation = store.observe(\.clips.clips) { [weak self] clips in
            self?.renderClips(clips)
        }
        clipsStatusObservation = store.observe(\.clips.status) { [weak self] status in
            self?.handleClipsStatus(status)
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
        refreshControl.endRefreshing()
        isManualRefreshing = false
        stopLiveTickTimer()
        cancelAllPrefetches()
        quietVisibleThumbnailLoads()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeHeaderToFit()
        updateClipsBottomInset()
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
        configureFailureBanner()

        recordButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)
        recordButton.apply(.unknown)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButtonRow.addSubview(recordButton)

        headerContainer.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 12,
            leading: 16,
            bottom: 0,
            trailing: 16
        )
        headerStack.axis = .vertical
        headerStack.spacing = 12
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.addArrangedSubview(previewViewController.view)
        headerStack.addArrangedSubview(recordButtonRow)
        headerStack.addArrangedSubview(statusPillsStack)
        headerStack.addArrangedSubview(clipsHeaderLabel)

        headerContainer.addSubview(headerStack)
        clipsTableView.tableHeaderView = headerContainer

        view.addSubview(clipsTableView)
        view.addSubview(clipsFailureBanner)

        NSLayoutConstraint.activate([
            recPill.topAnchor.constraint(equalTo: previewViewController.view.topAnchor, constant: 10),
            recPill.trailingAnchor.constraint(equalTo: previewViewController.view.trailingAnchor, constant: -10),

            recordButton.topAnchor.constraint(equalTo: recordButtonRow.topAnchor),
            recordButton.bottomAnchor.constraint(equalTo: recordButtonRow.bottomAnchor),
            recordButton.centerXAnchor.constraint(equalTo: recordButtonRow.centerXAnchor),
            recordButton.leadingAnchor.constraint(greaterThanOrEqualTo: recordButtonRow.leadingAnchor),
            recordButton.trailingAnchor.constraint(lessThanOrEqualTo: recordButtonRow.trailingAnchor),

            headerStack.leadingAnchor.constraint(equalTo: headerContainer.layoutMarginsGuide.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: headerContainer.layoutMarginsGuide.trailingAnchor),
            headerStack.topAnchor.constraint(equalTo: headerContainer.layoutMarginsGuide.topAnchor),
            headerStack.bottomAnchor.constraint(equalTo: headerContainer.layoutMarginsGuide.bottomAnchor),

            clipsTableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            clipsTableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            clipsTableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            clipsTableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            clipsFailureBanner.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            clipsFailureBanner.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            clipsFailureBanner.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            previewViewController.view.heightAnchor.constraint(
                equalTo: previewViewController.view.widthAnchor,
                multiplier: 0.75
            ),
        ])
    }

    private func configureFailureBanner() {
        clipsFailureBanner.configure(
            caption: "",
            dotColor: .systemRed,
            backgroundStyle: .tinted(UIColor.systemRed.withAlphaComponent(0.16))
        )
        clipsFailureBanner.isHidden = true
        clipsFailureBanner.translatesAutoresizingMaskIntoConstraints = false
    }

    private func sizeHeaderToFit() {
        guard let header = clipsTableView.tableHeaderView else { return }

        let fittingWidth = clipsTableView.bounds.width
        guard fittingWidth > 0 else { return }

        if let lastFittedHeaderWidth,
           abs(lastFittedHeaderWidth - fittingWidth) <= 0.5,
           needsHeaderRefit == false {
            return
        }

        header.frame.size.width = fittingWidth
        let fittingSize = header.systemLayoutSizeFitting(
            CGSize(width: fittingWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        lastFittedHeaderWidth = fittingWidth
        needsHeaderRefit = false

        guard abs(header.frame.height - fittingSize.height) > 0.5 else { return }

        var frame = header.frame
        frame.size.height = fittingSize.height
        header.frame = frame
        clipsTableView.tableHeaderView = header
    }

    private func updateClipsBottomInset() {
        let bottomInset = clipsFailureBanner.isHidden ? 0 : clipsFailureBanner.bounds.height

        if abs(clipsTableView.contentInset.bottom - bottomInset) > 0.5 {
            var contentInset = clipsTableView.contentInset
            contentInset.bottom = bottomInset
            clipsTableView.contentInset = contentInset
        }

        if abs(clipsTableView.verticalScrollIndicatorInsets.bottom - bottomInset) > 0.5 {
            var indicatorInsets = clipsTableView.verticalScrollIndicatorInsets
            indicatorInsets.bottom = bottomInset
            clipsTableView.verticalScrollIndicatorInsets = indicatorInsets
        }
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
        statusPillsStack.addArrangedSubview(timeUnverifiedPill)

        tempWarningPill.isHidden = true
        errorPill.isHidden = true
        timeUnverifiedPill.isHidden = true
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

        clipsTableView.delegate = self
        clipsTableView.prefetchDataSource = self
        clipsTableView.register(ClipThumbnailCell.self, forCellReuseIdentifier: "clipThumbnail")
        clipsTableView.register(LiveClipCell.self, forCellReuseIdentifier: "liveClip")
        dataSource = UITableViewDiffableDataSource<HomeSection, HomeRowID>(
            tableView: clipsTableView
        ) { [weak self] tableView, indexPath, id in
            guard let self, let row = self.rowsByID[id] else {
                return UITableViewCell(style: .default, reuseIdentifier: nil)
            }

            switch row {
            case .live(let segment):
                guard let cell = tableView.dequeueReusableCell(
                    withIdentifier: "liveClip",
                    for: indexPath
                ) as? LiveClipCell else {
                    return UITableViewCell(style: .default, reuseIdentifier: nil)
                }
                cell.configure(segment: segment, now: self.clock.now)
                return cell

            case .finished(let clip):
                guard let cell = tableView.dequeueReusableCell(
                    withIdentifier: "clipThumbnail",
                    for: indexPath
                ) as? ClipThumbnailCell else {
                    return UITableViewCell(style: .default, reuseIdentifier: nil)
                }
                cell.configure(clip: clip, loader: self.dependencies.thumbnailLoader)
                return cell
            }
        }
        clipsTableView.rowHeight = UITableView.automaticDimension
        clipsTableView.estimatedRowHeight = 72
        clipsTableView.tableFooterView = UIView()
        clipsTableView.alwaysBounceVertical = true
        refreshControl.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        clipsTableView.refreshControl = refreshControl
        clipsTableView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            emptyClipsView.centerXAnchor.constraint(equalTo: emptyClipsBackgroundView.centerXAnchor),
            emptyClipsView.centerYAnchor.constraint(equalTo: emptyClipsBackgroundView.centerYAnchor),
        ])
    }

    private func renderStatusPills(_ pills: HomeStatusPills) {
        if let warning = pills.tempWarning {
            let color: UIColor = warning.isCritical ? .systemRed : .systemOrange
            tempWarningPill.configure(
                caption: warning.caption,
                dotColor: color,
                backgroundStyle: .tinted(color.withAlphaComponent(0.16))
            )
            tempWarningPill.isHidden = false
        } else {
            tempWarningPill.isHidden = true
        }

        if pills.cameraOffline {
            errorPill.configure(
                caption: "Camera offline",
                dotColor: .systemRed,
                backgroundStyle: .tinted(UIColor.systemRed.withAlphaComponent(0.16))
            )
            errorPill.isHidden = false
        } else {
            errorPill.isHidden = true
        }

        if pills.timeUnverified {
            timeUnverifiedPill.configure(
                caption: "Time unverified",
                dotColor: .systemOrange,
                backgroundStyle: .tinted(UIColor.systemOrange.withAlphaComponent(0.16))
            )
            timeUnverifiedPill.isHidden = false
        } else {
            timeUnverifiedPill.isHidden = true
        }

        statusPillsStack.isHidden = tempWarningPill.isHidden
            && errorPill.isHidden
            && timeUnverifiedPill.isHidden
        needsHeaderRefit = true
        view.setNeedsLayout()
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

    private func renderClips(_ clips: [Clip]) {
        finishedClips = clips
        renderRows()
    }

    private func renderRows(now: ContinuousClock.Instant? = nil) {
        let now = now ?? clock.now
        let previousLive = rows.first?.liveSegment
        let newRows = HomeRow.compose(
            clips: finishedClips,
            recorder: recorder,
            previousLive: previousLive,
            now: now
        )
        let reconfigure = HomeRowDiff.reconfiguredIDs(old: rows, new: newRows)

        rows = newRows
        rowsByID = Dictionary(uniqueKeysWithValues: newRows.map { ($0.id, $0) })
        prunePrefetches(surviving: Set(newRows.compactMap(\.finishedIdentity)))

        var snapshot = NSDiffableDataSourceSnapshot<HomeSection, HomeRowID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(newRows.map(\.id), toSection: .main)
        snapshot.reconfigureItems(reconfigure)
        dataSource.apply(snapshot, animatingDifferences: true)

        updateClipsPresentation()
        updateLiveTickTimer()
    }

    private func handleClipsStatus(_ status: ClipsFeature.State.Status) {
        switch status {
        case .loading:
            break
        case .idle, .failed:
            if isManualRefreshing {
                refreshControl.endRefreshing()
                isManualRefreshing = false
            }
        }

        clipsStatus = status
        updateClipsPresentation()
    }

    private func updateClipsPresentation() {
        switch clipsStatus {
        case .failed(let message):
            clipsFailureBanner.configure(
                caption: message,
                dotColor: .systemRed,
                backgroundStyle: .tinted(UIColor.systemRed.withAlphaComponent(0.16))
            )
            clipsFailureBanner.isHidden = false
            clipsTableView.backgroundView = nil
        case .idle, .loading:
            clipsFailureBanner.isHidden = true
            clipsTableView.backgroundView = rows.isEmpty ? emptyClipsBackgroundView : nil
        }

        view.setNeedsLayout()
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
        guard let segment = rows.first?.liveSegment,
              let indexPath = dataSource.indexPath(for: .live(session: segment.sessionId, id: segment.id)),
              let cell = clipsTableView.cellForRow(at: indexPath) as? LiveClipCell else {
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
        isManualRefreshing = true
        store.send(.manualRefresh)
        previewViewController.reconnectIfNeeded()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let row = row(at: indexPath) else { return }

        switch row {
        case .live:
            return
        case .finished(let clip):
            tableView.deselectRow(at: indexPath, animated: true)
            navigationController?.pushViewController(
                ClipViewerViewController(dependencies: dependencies, store: store, clip: clip),
                animated: true
            )
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let row = row(at: indexPath),
              case .finished(let clip) = row else {
            return nil
        }

        let action = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            guard let self else {
                completion(false)
                return
            }

            let alert = UIAlertController(
                title: "Delete clip?",
                message: "This removes the clip from the camera unit.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                completion(false)
            })
            alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
                self.performDelete(clip)
                completion(true)
            })
            self.present(alert, animated: true)
        }
        action.image = UIImage(systemName: "trash")

        return UISwipeActionsConfiguration(actions: [action])
    }

    func tableView(
        _ tableView: UITableView,
        willDisplay cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {
        guard let row = row(at: indexPath),
              indexPath.row >= max(rows.count - paginationThreshold, 0),
              case .finished = row else {
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
            guard let row = row(at: indexPath),
                  case .finished(let clip) = row else {
                continue
            }
            let identity = ClipThumbnailIdentity(clip)
            // Cancel-before-replace: a `PrefetchHandle` is a value type with no `deinit`, so
            // overwriting a slot without cancelling would orphan the prior handle's token and
            // keep pinning its loader entry.
            prefetchHandles[identity]?.cancel()
            prefetchHandles[identity] = dependencies.thumbnailLoader.prefetch(clip)
        }
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let row = row(at: indexPath),
                  let identity = row.finishedIdentity else {
                continue
            }
            prefetchHandles.removeValue(forKey: identity)?.cancel()
        }
    }

    private func row(at indexPath: IndexPath) -> HomeRow? {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return rowsByID[id]
    }

    private func performDelete(_ clip: Clip) {
        store.send(.clips(.deleteTapped(clip)))
    }

    func performDeleteForTesting(clipID: Int) {
        guard let clip = finishedClips.first(where: { $0.id == clipID }) else { return }
        performDelete(clip)
    }

    private func prunePrefetches(surviving identities: Set<ClipThumbnailIdentity>) {
        let staleIdentities = prefetchHandles.keys.filter { identities.contains($0) == false }
        for identity in staleIdentities {
            prefetchHandles.removeValue(forKey: identity)?.cancel()
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
    /// in place. Diffable snapshots do not reload on appear, so a painted cell hits the
    /// same-identity no-op and a cell quieted on the way out retries once, cache-first.
    private func reconfigureVisibleThumbnails() {
        guard let visibleRows = clipsTableView.indexPathsForVisibleRows else { return }
        for indexPath in visibleRows {
            guard let row = row(at: indexPath),
                  case .finished(let clip) = row,
                  let cell = clipsTableView.cellForRow(at: indexPath) as? ClipThumbnailCell else {
                continue
            }
            cell.configure(clip: clip, loader: dependencies.thumbnailLoader)
        }
    }

    func clipThumbnailCellForTesting(clipID: Int) -> ClipThumbnailCell? {
        guard let indexPath = dataSource.indexPath(for: .finished(clipID)) else { return nil }
        return clipsTableView.cellForRow(at: indexPath) as? ClipThumbnailCell
    }

    var recordButtonForTesting: RecordButton {
        recordButton
    }

    var isTimeUnverifiedPillVisibleForTesting: Bool {
        timeUnverifiedPill.isHidden == false
    }

    var isRefreshingForTesting: Bool {
        refreshControl.isRefreshing
    }

    var isManualRefreshingForTesting: Bool {
        isManualRefreshing
    }

    var clipsFailureMessageForTesting: String? {
        clipsFailureBanner.isHidden ? nil : clipsFailureBanner.accessibilityLabel
    }

    var isShowingEmptyStateForTesting: Bool {
        clipsTableView.backgroundView != nil
    }

    func pullToRefreshForTesting() {
        refreshControl.beginRefreshing()
        refreshPulled()
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
