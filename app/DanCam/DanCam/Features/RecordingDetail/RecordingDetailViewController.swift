import UIKit

private nonisolated enum RecordingDetailSection: Hashable, Sendable {
    case clips
}

private nonisolated enum RecordingDetailRow: Hashable, Sendable {
    case liveRecording
    case clip(Int)
}

final class RecordingDetailViewController: UIViewController, UITableViewDelegate, UITableViewDataSourcePrefetching {
    private let dependencies: AppDependencies
    private let store: AppStore
    private let recordingID: RecordingID
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let clock = ContinuousClock()

    private var liveRecordingObservation: StoreObservation?
    private var stateObservation: StoreObservation?
    private var dataSource: UITableViewDiffableDataSource<RecordingDetailSection, RecordingDetailRow>!
    private lazy var snapshotPresenter = DiffableSnapshotPresenter(
        dataSource: dataSource,
        tableView: tableView,
        didCommitLatest: { [weak self] in
            self?.handleLatestSnapshotCommit()
        }
    )
    private var state: RecordingDetailState
    private var clips: [Clip] = []
    private var clipsByID: [Int: Clip] = [:]
    private var paginationTailID: Int?
    private var hasLoadedClips = false
    private var liveRecordingStatus: LiveRecordingStatus
    private var showsLiveRow = false
    private var preservedVisibleThumbnails: [ClipThumbnailIdentity: UIImage] = [:]
    private var prefetchHandles: [ClipThumbnailIdentity: ThumbnailLoader.PrefetchHandle] = [:]
    private var didRemoveFromNavigationStack = false
    private var isViewActive = false

    init(
        dependencies: AppDependencies,
        store: AppStore,
        recordingID: RecordingID,
        initialLiveSegment: LiveSegment? = nil
    ) {
        self.dependencies = dependencies
        self.store = store
        self.recordingID = recordingID
        state = RecordingDetailState(allClips: [], nextCursor: nil, recordingID: recordingID)
        // Seed the threaded `previous` so a detail pushed mid-segment counts elapsed up from
        // Home's running total instead of anchoring at 00:00 (segment_opened folds durMs: nil).
        liveRecordingStatus = initialLiveSegment.map(LiveRecordingStatus.live) ?? .none
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RecordingDetailViewController is programmatic.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.title = "Session"
        view.backgroundColor = .systemBackground
        configureTable()

        // Register the live observation before the clips projection: `showsLiveRow` must be
        // known before `handlePostApplyState` can decide an empty recording should pop, so a
        // recording we are actively recording into with zero finished clips stays on screen.
        liveRecordingObservation = store.observe(select: LiveRecordingInputs.from) { [weak self] inputs in
            self?.renderLiveRecording(inputs)
        }

        let recordingID = recordingID
        stateObservation = store.observe(
            select: { appState in
                RecordingDetailState(
                    allClips: appState.clips.clips,
                    nextCursor: appState.clips.nextCursor,
                    recordingID: recordingID
                )
            }
        ) { [weak self] state in
            self?.render(state)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isViewActive = true
        snapshotPresenter.setActive(true)
        view.setNeedsLayout()
        reconfigureVisibleThumbnails()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isViewActive = false
        snapshotPresenter.setActive(false)
        cancelAllPrefetches()
        quietVisibleThumbnailLoads()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        snapshotPresenter.flushIfReady()
        reconfigureVisibleThumbnails()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        snapshotPresenter.flushIfReady()
    }

    isolated deinit {
        cancelAllPrefetches()
    }

    private func configureTable() {
        tableView.delegate = self
        tableView.prefetchDataSource = self
        tableView.register(ClipThumbnailCell.self, forCellReuseIdentifier: "clipThumbnail")
        tableView.register(LiveRecordingCell.self, forCellReuseIdentifier: "liveRecording")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.tableFooterView = UIView()
        tableView.alwaysBounceVertical = true
        tableView.translatesAutoresizingMaskIntoConstraints = false

        dataSource = UITableViewDiffableDataSource<RecordingDetailSection, RecordingDetailRow>(tableView: tableView) { [weak self] tableView, indexPath, row in
            guard let self else {
                return UITableViewCell(style: .default, reuseIdentifier: nil)
            }

            switch row {
            case .liveRecording:
                guard let cell = tableView.dequeueReusableCell(
                    withIdentifier: "liveRecording",
                    for: indexPath
                ) as? LiveRecordingCell else {
                    return UITableViewCell(style: .default, reuseIdentifier: nil)
                }
                cell.configure(status: self.liveRecordingStatus, now: self.clock.now)
                return cell

            case .clip(let id):
                guard let clip = self.clipsByID[id],
                      let cell = tableView.dequeueReusableCell(
                          withIdentifier: "clipThumbnail",
                          for: indexPath
                      ) as? ClipThumbnailCell else {
                    return UITableViewCell(style: .default, reuseIdentifier: nil)
                }
                cell.configure(
                    clip: clip,
                    loader: self.dependencies.thumbnailLoader,
                    preservedThumbnail: self.preservedVisibleThumbnails[ClipThumbnailIdentity(clip)]
                )
                return cell
            }
        }

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func render(_ newState: RecordingDetailState) {
        let oldClips = clips
        let visibleThumbnails = visibleThumbnailImages()
        let reconfigure = changedClipIDs(old: oldClips, new: newState.clips).map(RecordingDetailRow.clip)

        hasLoadedClips = true
        state = newState
        clips = newState.clips
        clipsByID = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        paginationTailID = clips.last?.id
        updateSessionTitle()
        prunePrefetches(surviving: Set(clips.map(ClipThumbnailIdentity.init)))
        preservedVisibleThumbnails = visibleThumbnails

        snapshotPresenter.submit(makeSnapshot(reconfigure: reconfigure))
        handleProjectedState()
    }

    private func renderLiveRecording(
        _ inputs: LiveRecordingInputs,
        now: ContinuousClock.Instant? = nil
    ) {
        let now = now ?? clock.now
        let status = LiveRecordingStatus.from(
            recording: inputs.recording,
            recorder: inputs.recorder,
            previous: liveRecordingStatus.liveSegment,
            now: now
        )
        let showsLiveRow = RecordingAttribution.from(
            status: status,
            storageGeneration: inputs.storageGeneration,
            worldBootTag: inputs.worldBootTag,
            recorder: inputs.recorder
        )?.id == recordingID

        // The stable `.liveRecording` identity means pending -> live, freeze/thaw, and segment
        // rolls are in-place reconfigures rather than row churn; force one whenever the rendered
        // status changed and the row is present in both the old and new snapshots.
        let wasShowing = self.showsLiveRow
        let statusChanged = liveRecordingStatus != status
        liveRecordingStatus = status
        self.showsLiveRow = showsLiveRow
        updateSessionTitle()

        let reconfigure: [RecordingDetailRow] = wasShowing && showsLiveRow && statusChanged
            ? [.liveRecording]
            : []
        snapshotPresenter.submit(makeSnapshot(reconfigure: reconfigure))
        handleProjectedState()
    }

    private func makeSnapshot(
        reconfigure: [RecordingDetailRow]
    ) -> NSDiffableDataSourceSnapshot<RecordingDetailSection, RecordingDetailRow> {
        var snapshot = NSDiffableDataSourceSnapshot<RecordingDetailSection, RecordingDetailRow>()
        snapshot.appendSections([.clips])
        if showsLiveRow {
            snapshot.appendItems([.liveRecording], toSection: .clips)
        }
        snapshot.appendItems(clips.map { RecordingDetailRow.clip($0.id) }, toSection: .clips)
        snapshot.reconfigureItems(reconfigure)
        return snapshot
    }

    private func changedClipIDs(old: [Clip], new: [Clip]) -> [Int] {
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        return new.compactMap { clip in
            guard let oldClip = oldByID[clip.id], oldClip != clip else { return nil }
            return clip.id
        }
    }

    private func handleProjectedState() {
        guard hasLoadedClips else { return }

        if clips.isEmpty {
            if state.canLoadMore == false, showsLiveRow == false {
                // A live/pending row with zero finished clips is legitimate (fresh boot, or the
                // user deleted everything mid-recording); only pop once recording stops.
                removeFromNavigationStack()
            }
        }
    }

    private func updateSessionTitle() {
        let newestEnd = clips.first.flatMap { clip -> Date? in
            guard let start = clip.resolvedStartDate, let durMs = clip.durMs else { return nil }
            return start.addingTimeInterval(Double(durMs) / 1_000)
        }
        let freshness: RecordingAttribution.Freshness?
        if showsLiveRow {
            switch liveRecordingStatus {
            case .pending:
                freshness = .live
            case .live(let segment):
                freshness = segment.isTicking ? .live : .lastKnown
            case .none:
                freshness = nil
            }
        } else {
            freshness = nil
        }
        navigationItem.title = Formatters.sessionTitle(
            start: clips.last?.resolvedStartDate,
            end: newestEnd,
            freshness: freshness,
            now: dependencies.wallNow()
        )
    }

    private func removeFromNavigationStack() {
        guard didRemoveFromNavigationStack == false else { return }
        didRemoveFromNavigationStack = true

        guard let navigationController else { return }
        if navigationController.topViewController === self {
            navigationController.popViewController(animated: true)
        } else {
            navigationController.viewControllers.removeAll { $0 === self }
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let clip = clip(at: indexPath) else { return }

        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(
            ClipViewerViewController(dependencies: dependencies, store: store, clip: clip),
            animated: true
        )
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let clip = clip(at: indexPath) else { return nil }

        return UISwipeActionsConfiguration(actions: [
            ClipDeleteConfirmation.swipeAction(presenting: self) { [weak self] in
                self?.performDelete(clip)
            },
        ])
    }

    func tableView(
        _ tableView: UITableView,
        willDisplay cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {
        guard isActiveAndAttached,
              state.canLoadMore,
              clip(at: indexPath)?.id == paginationTailID else {
            return
        }

        store.send(.clips(.loadMore))
    }

    func tableView(
        _ tableView: UITableView,
        didEndDisplaying cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {
        (cell as? ClipThumbnailCell)?.cancelLoad()
    }

    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let clip = clip(at: indexPath) else { continue }

            let identity = ClipThumbnailIdentity(clip)
            prefetchHandles[identity]?.cancel()
            prefetchHandles[identity] = dependencies.thumbnailLoader.prefetch(clip)
        }
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let clip = clip(at: indexPath) else { continue }

            prefetchHandles.removeValue(forKey: ClipThumbnailIdentity(clip))?.cancel()
        }
    }

    private func clip(at indexPath: IndexPath) -> Clip? {
        guard indexPath.section == 0 else { return nil }
        let clipIndex = indexPath.row - (showsLiveRow ? 1 : 0)
        guard clips.indices.contains(clipIndex) else { return nil }
        return clips[clipIndex]
    }

    private func performDelete(_ clip: Clip) {
        store.send(.clips(.deleteTapped(clip)))
    }

    private func loadMoreIfVisibleTail() {
        guard isActiveAndAttached,
              state.canLoadMore,
              let paginationTailID,
              let visibleRows = tableView.indexPathsForVisibleRows else {
            return
        }

        let visibleIDs = visibleRows.compactMap { dataSource.itemIdentifier(for: $0) }
        guard visibleIDs.contains(.clip(paginationTailID)) else { return }

        store.send(.clips(.loadMore))
    }

    private func visibleThumbnailImages() -> [ClipThumbnailIdentity: UIImage] {
        guard isActiveAndAttached,
              let visibleRows = tableView.indexPathsForVisibleRows else { return [:] }

        var images: [ClipThumbnailIdentity: UIImage] = [:]
        for indexPath in visibleRows {
            guard let clip = clip(at: indexPath),
                  let cell = tableView.cellForRow(at: indexPath) as? ClipThumbnailCell,
                  let image = cell.currentThumbnailImage else {
                continue
            }
            images[ClipThumbnailIdentity(clip)] = image
        }
        return images
    }

    private func reconfigureVisibleThumbnails() {
        guard isActiveAndAttached,
              let visibleRows = tableView.indexPathsForVisibleRows else { return }
        for indexPath in visibleRows {
            guard let clip = clip(at: indexPath),
                  let cell = tableView.cellForRow(at: indexPath) as? ClipThumbnailCell else {
                continue
            }
            cell.configure(clip: clip, loader: dependencies.thumbnailLoader)
        }
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
        guard tableView.window != nil else { return }
        for cell in tableView.visibleCells {
            (cell as? ClipThumbnailCell)?.cancelLoad()
        }
    }

    private func resumePaginationAfterSnapshot() {
        guard isActiveAndAttached, state.canLoadMore else { return }
        if clips.isEmpty {
            store.send(.clips(.loadMore))
        } else {
            loadMoreIfVisibleTail()
        }
    }

    private func handleLatestSnapshotCommit() {
        preservedVisibleThumbnails.removeAll()
        resumePaginationAfterSnapshot()
    }

    private var isActiveAndAttached: Bool {
        isViewActive && view.window != nil && tableView.window != nil
    }

    func clipIDsForTesting() -> [Int] {
        clips.map(\.id)
    }

    var presentedClipIDsForTesting: [Int] {
        dataSource.snapshot().itemIdentifiers.compactMap { row in
            guard case .clip(let id) = row else { return nil }
            return id
        }
    }

    func indexPathForTesting(clipID: Int) -> IndexPath? {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return nil }
        return IndexPath(row: index + (showsLiveRow ? 1 : 0), section: 0)
    }

    func clipThumbnailCellForTesting(clipID: Int) -> ClipThumbnailCell? {
        guard let indexPath = dataSource.indexPath(for: .clip(clipID)) else { return nil }
        return tableView.cellForRow(at: indexPath) as? ClipThumbnailCell
    }

    func performDeleteForTesting(clipID: Int) {
        guard let clip = clipsByID[clipID] else { return }
        performDelete(clip)
    }

    func layoutTableForTesting() {
        tableView.layoutIfNeeded()
    }

    var isShowingLiveRowForTesting: Bool {
        showsLiveRow
    }

    func liveRecordingCellForTesting() -> LiveRecordingCell? {
        guard let indexPath = dataSource.indexPath(for: .liveRecording) else { return nil }
        return tableView.cellForRow(at: indexPath) as? LiveRecordingCell
    }

    func tickLiveRecordingCellForTesting(now: ContinuousClock.Instant? = nil) {
        liveRecordingCellForTesting()?.statusViewForTesting.tickForTesting(now: now)
    }
}
