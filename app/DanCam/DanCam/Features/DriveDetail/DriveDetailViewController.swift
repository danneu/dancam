import UIKit

private nonisolated enum DriveDetailSection: Hashable, Sendable {
    case clips
}

final class DriveDetailViewController: UIViewController, UITableViewDelegate, UITableViewDataSourcePrefetching {
    private let dependencies: AppDependencies
    private let store: AppStore
    private let bootTag: String
    private let tableView = UITableView(frame: .zero, style: .plain)

    private var stateObservation: StoreObservation?
    private var dataSource: UITableViewDiffableDataSource<DriveDetailSection, Int>!
    private var state: DriveDetailState
    private var clips: [Clip] = []
    private var clipsByID: [Int: Clip] = [:]
    private var paginationTailID: Int?
    private var preservedVisibleThumbnails: [ClipThumbnailIdentity: UIImage] = [:]
    private var preservedThumbnailGeneration = 0
    private var prefetchHandles: [ClipThumbnailIdentity: ThumbnailLoader.PrefetchHandle] = [:]
    private var didRemoveFromNavigationStack = false

    init(dependencies: AppDependencies, store: AppStore, bootTag: String) {
        self.dependencies = dependencies
        self.store = store
        self.bootTag = bootTag
        state = DriveDetailState(allClips: [], nextCursor: nil, bootTag: bootTag)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DriveDetailViewController is programmatic.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Drive"
        view.backgroundColor = .systemBackground
        configureTable()

        let bootTag = bootTag
        stateObservation = store.observe(
            select: { appState in
                DriveDetailState(
                    allClips: appState.clips.clips,
                    nextCursor: appState.clips.nextCursor,
                    bootTag: bootTag
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
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.tableFooterView = UIView()
        tableView.alwaysBounceVertical = true
        tableView.translatesAutoresizingMaskIntoConstraints = false

        dataSource = UITableViewDiffableDataSource<DriveDetailSection, Int>(tableView: tableView) { [weak self] tableView, indexPath, id in
            guard let self, let clip = self.clipsByID[id],
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

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func render(_ newState: DriveDetailState) {
        let oldClips = clips
        let visibleThumbnails = visibleThumbnailImages()
        let reconfigure = changedClipIDs(old: oldClips, new: newState.clips)

        state = newState
        clips = newState.clips
        clipsByID = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        paginationTailID = clips.last?.id
        title = driveTitle(for: clips)
        prunePrefetches(surviving: Set(clips.map(ClipThumbnailIdentity.init)))
        preservedThumbnailGeneration += 1
        let thumbnailGeneration = preservedThumbnailGeneration
        preservedVisibleThumbnails = visibleThumbnails

        var snapshot = NSDiffableDataSourceSnapshot<DriveDetailSection, Int>()
        snapshot.appendSections([.clips])
        snapshot.appendItems(clips.map(\.id), toSection: .clips)
        snapshot.reconfigureItems(reconfigure)
        dataSource.apply(
            snapshot,
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
        if clips.isEmpty {
            if state.canLoadMore {
                store.send(.clips(.loadMore))
            } else {
                removeFromNavigationStack()
            }
            return
        }

        loadMoreIfVisibleTail()
    }

    private func driveTitle(for clips: [Clip]) -> String {
        guard let start = clips.last?.resolvedStartDate,
              let end = clips.first?.resolvedStartDate else {
            return "Drive"
        }

        return Formatters.driveCardTitle(start: start, end: end)
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
        guard let clip = row(at: indexPath) else { return }

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
        guard let clip = row(at: indexPath) else { return nil }

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
              let id = dataSource.itemIdentifier(for: indexPath),
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
            guard let clip = row(at: indexPath) else { continue }

            let identity = ClipThumbnailIdentity(clip)
            prefetchHandles[identity]?.cancel()
            prefetchHandles[identity] = dependencies.thumbnailLoader.prefetch(clip)
        }
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let clip = row(at: indexPath) else { continue }

            prefetchHandles.removeValue(forKey: ClipThumbnailIdentity(clip))?.cancel()
        }
    }

    private func row(at indexPath: IndexPath) -> Clip? {
        guard let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
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
        guard visibleIDs.contains(paginationTailID) else { return }

        store.send(.clips(.loadMore))
    }

    private func visibleThumbnailImages() -> [ClipThumbnailIdentity: UIImage] {
        guard let visibleRows = tableView.indexPathsForVisibleRows else { return [:] }

        var images: [ClipThumbnailIdentity: UIImage] = [:]
        for indexPath in visibleRows {
            guard let clip = row(at: indexPath),
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
            guard let clip = row(at: indexPath),
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
        dataSource.indexPath(for: clipID)
    }

    func clipThumbnailCellForTesting(clipID: Int) -> ClipThumbnailCell? {
        guard let indexPath = dataSource.indexPath(for: clipID) else { return nil }
        return tableView.cellForRow(at: indexPath) as? ClipThumbnailCell
    }

    func performDeleteForTesting(clipID: Int) {
        guard let clip = clipsByID[clipID] else { return }
        performDelete(clip)
    }

    func layoutTableForTesting() {
        tableView.layoutIfNeeded()
    }
}
