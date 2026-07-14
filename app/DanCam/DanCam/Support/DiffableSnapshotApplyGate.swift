import UIKit

@MainActor
final class DiffableSnapshotApplyGate<Section: Hashable & Sendable, Item: Hashable & Sendable> {
    typealias Snapshot = NSDiffableDataSourceSnapshot<Section, Item>
    typealias Apply = (Snapshot, Bool, @escaping () -> Void) -> Void
    typealias Reload = (Snapshot, @escaping () -> Void) -> Void

    private weak var listView: UIView?
    private let apply: Apply
    private let applyUsingReloadData: Reload
    private var pendingSnapshot: Snapshot?
    private var pendingAnimation = true
    private var pendingRequiresReload = false
    private var pendingCompletions: [() -> Void] = []
    private var isActive = false
    private var isApplying = false
    private var inFlightSnapshot: Snapshot?
    private var inFlightCompletions: [() -> Void] = []
    private var applySequence = 0
    private var currentApplyID: Int?

    init(
        dataSource: UITableViewDiffableDataSource<Section, Item>,
        tableView: UITableView
    ) {
        listView = tableView
        apply = { snapshot, animated, completion in
            dataSource.apply(snapshot, animatingDifferences: animated, completion: completion)
        }
        applyUsingReloadData = { snapshot, completion in
            dataSource.applySnapshotUsingReloadData(snapshot, completion: completion)
        }
    }

    init(
        dataSource: UICollectionViewDiffableDataSource<Section, Item>,
        collectionView: UICollectionView
    ) {
        listView = collectionView
        apply = { snapshot, animated, completion in
            dataSource.apply(snapshot, animatingDifferences: animated, completion: completion)
        }
        applyUsingReloadData = { snapshot, completion in
            dataSource.applySnapshotUsingReloadData(snapshot, completion: completion)
        }
    }

    init(listView: UIView, apply: @escaping Apply, applyUsingReloadData: @escaping Reload) {
        self.listView = listView
        self.apply = apply
        self.applyUsingReloadData = applyUsingReloadData
    }

    func submit(
        _ snapshot: Snapshot,
        animatingDifferences: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        pendingSnapshot = snapshot
        pendingAnimation = animatingDifferences
        if let completion {
            pendingCompletions.append(completion)
        }
        if isReady == false {
            pendingRequiresReload = true
        }
        applyPendingIfReady()
    }

    func setActive(_ active: Bool) {
        isActive = active

        guard active == false else {
            applyPendingIfReady()
            return
        }

        pendingRequiresReload = true
        guard isApplying else { return }

        if pendingSnapshot == nil {
            pendingSnapshot = inFlightSnapshot
        }
        pendingCompletions = inFlightCompletions + pendingCompletions
        currentApplyID = nil
        inFlightSnapshot = nil
        inFlightCompletions.removeAll()
        isApplying = false
    }

    func flushIfReady() {
        applyPendingIfReady()
    }

    private var isReady: Bool {
        guard let listView else { return false }
        return isActive && listView.window != nil && listView.bounds.width > 0 && listView.bounds.height > 0
    }

    private func applyPendingIfReady() {
        guard let snapshot = pendingSnapshot else { return }
        guard isReady else {
            pendingRequiresReload = true
            return
        }
        guard isApplying == false else { return }

        let animation = pendingAnimation
        let requiresReload = pendingRequiresReload
        pendingSnapshot = nil
        pendingRequiresReload = false
        inFlightSnapshot = snapshot
        inFlightCompletions = pendingCompletions
        pendingCompletions.removeAll()
        isApplying = true
        applySequence += 1
        let applyID = applySequence
        currentApplyID = applyID

        let didApply = { [weak self] in
            guard let self, self.currentApplyID == applyID else { return }
            let completions = self.inFlightCompletions
            self.currentApplyID = nil
            self.inFlightSnapshot = nil
            self.inFlightCompletions.removeAll()
            self.isApplying = false
            completions.forEach { $0() }
            self.applyPendingIfReady()
        }

        if requiresReload {
            applyUsingReloadData(snapshot, didApply)
        } else {
            apply(snapshot, animation, didApply)
        }
    }
}
