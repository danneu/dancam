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
    private var state: RecordingDetailState
    private var clips: [Clip] = []
    private var clipsByID: [Int: Clip] = [:]
    private var paginationTailID: Int?
    private var hasLoadedClips = false
    private var liveRecordingStatus: LiveRecordingStatus
    private var showsLiveRow = false
    private var preservedVisibleThumbnails: [ClipThumbnailIdentity: UIImage] = [:]
    private var preservedThumbnailGeneration = 0
    private var prefetchHandles: [ClipThumbnailIdentity: ThumbnailLoader.PrefetchHandle] = [:]
    private var didRemoveFromNavigationStack = false

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

        title = "Recording"
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
        reconfigureVisibleThumbnails()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelAllPrefetches()
        quietVisibleThumbnailLoads()
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
        title = recordingTitle(for: clips)
        prunePrefetches(surviving: Set(clips.map(ClipThumbnailIdentity.init)))
        preservedThumbnailGeneration += 1
        let thumbnailGeneration = preservedThumbnailGeneration
        preservedVisibleThumbnails = visibleThumbnails

        dataSource.apply(
            makeSnapshot(reconfigure: reconfigure),
            animatingDifferences: canAnimateTableUpdates,
            completion: { [weak self] in
                MainActor.assumeIsolated {
                    if self?.preservedThumbnailGeneration == thumbnailGeneration {
                        self?.preservedVisibleThumbnails.removeAll()
                    }
                    self?.handlePostApplyState()
                }
            }
        )
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

        let reconfigure: [RecordingDetailRow] = wasShowing && showsLiveRow && statusChanged
            ? [.liveRecording]
            : []
        dataSource.apply(
            makeSnapshot(reconfigure: reconfigure),
            animatingDifferences: canAnimateTableUpdates,
            completion: { [weak self] in
                MainActor.assumeIsolated {
                    self?.handlePostApplyState()
                }
            }
        )
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

    private var canAnimateTableUpdates: Bool {
        isViewLoaded && view.window != nil && tableView.window != nil
    }

    private func changedClipIDs(old: [Clip], new: [Clip]) -> [Int] {
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        return new.compactMap { clip in
            guard let oldClip = oldByID[clip.id], oldClip != clip else { return nil }
            return clip.id
        }
    }

    private func handlePostApplyState() {
        guard hasLoadedClips else { return }

        if clips.isEmpty {
            if state.canLoadMore {
                store.send(.clips(.loadMore))
            } else if showsLiveRow == false {
                // A live/pending row with zero finished clips is legitimate (fresh boot, or the
                // user deleted everything mid-recording); only pop once recording stops.
                removeFromNavigationStack()
            }
            return
        }

        loadMoreIfVisibleTail()
    }

    private func recordingTitle(for clips: [Clip]) -> String {
        guard let start = clips.last?.resolvedStartDate,
              let end = clips.first?.resolvedStartDate else {
            return "Recording"
        }

        return Formatters.recordingCardTitle(start: start, end: end)
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
        guard state.canLoadMore,
              case .clip(let id)? = dataSource.itemIdentifier(for: indexPath),
              id == paginationTailID else {
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
        guard case .clip(let id)? = dataSource.itemIdentifier(for: indexPath) else { return nil }
        return clipsByID[id]
    }

    private func performDelete(_ clip: Clip) {
        store.send(.clips(.deleteTapped(clip)))
    }

    private func loadMoreIfVisibleTail() {
        guard state.canLoadMore,
              let paginationTailID,
              let visibleRows = tableView.indexPathsForVisibleRows else {
            return
        }

        let visibleIDs = visibleRows.compactMap { dataSource.itemIdentifier(for: $0) }
        guard visibleIDs.contains(.clip(paginationTailID)) else { return }

        store.send(.clips(.loadMore))
    }

    private func visibleThumbnailImages() -> [ClipThumbnailIdentity: UIImage] {
        guard let visibleRows = tableView.indexPathsForVisibleRows else { return [:] }

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
        guard let visibleRows = tableView.indexPathsForVisibleRows else { return }
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
        for cell in tableView.visibleCells {
            (cell as? ClipThumbnailCell)?.cancelLoad()
        }
    }

    func clipIDsForTesting() -> [Int] {
        clips.map(\.id)
    }

    func indexPathForTesting(clipID: Int) -> IndexPath? {
        dataSource.indexPath(for: .clip(clipID))
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
