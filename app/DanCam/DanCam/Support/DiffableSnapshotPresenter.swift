import UIKit

@MainActor
final class DiffableSnapshotPresenter<Section: Hashable & Sendable, Item: Hashable & Sendable> {
    typealias Snapshot = NSDiffableDataSourceSnapshot<Section, Item>
    typealias Apply = (Snapshot, Bool, @escaping () -> Void) -> Void
    typealias Reload = (Snapshot, @escaping () -> Void) -> Void

    private struct Submission {
        let revision: Int
        let snapshot: Snapshot
        let animatingDifferences: Bool
    }

    private weak var listView: UIView?
    private let apply: Apply
    private let applyUsingReloadData: Reload
    private let didCommitLatest: @MainActor () -> Void
    private var desiredSubmission: Submission?
    private var nextRevision = 0
    private var requiresReload = false
    private var isActive = false
    private var isApplying = false
    private var applySequence = 0
    private var currentApplyID: Int?
    private var presentedItems = Set<Item>()
    private var pendingReconfiguredItems = Set<Item>()

    init(
        dataSource: UITableViewDiffableDataSource<Section, Item>,
        tableView: UITableView,
        didCommitLatest: @escaping @MainActor () -> Void
    ) {
        listView = tableView
        apply = { snapshot, animated, completion in
            dataSource.apply(snapshot, animatingDifferences: animated, completion: completion)
        }
        applyUsingReloadData = { snapshot, completion in
            dataSource.applySnapshotUsingReloadData(snapshot, completion: completion)
        }
        self.didCommitLatest = didCommitLatest
    }

    init(
        dataSource: UICollectionViewDiffableDataSource<Section, Item>,
        collectionView: UICollectionView,
        didCommitLatest: @escaping @MainActor () -> Void
    ) {
        listView = collectionView
        apply = { snapshot, animated, completion in
            dataSource.apply(snapshot, animatingDifferences: animated, completion: completion)
        }
        applyUsingReloadData = { snapshot, completion in
            dataSource.applySnapshotUsingReloadData(snapshot, completion: completion)
        }
        self.didCommitLatest = didCommitLatest
    }

    init(
        listView: UIView,
        apply: @escaping Apply,
        applyUsingReloadData: @escaping Reload,
        didCommitLatest: @escaping @MainActor () -> Void
    ) {
        self.listView = listView
        self.apply = apply
        self.applyUsingReloadData = applyUsingReloadData
        self.didCommitLatest = didCommitLatest
    }

    func submit(
        _ snapshot: Snapshot,
        animatingDifferences: Bool = true
    ) {
        pendingReconfiguredItems.formUnion(snapshot.reconfiguredItemIdentifiers)
        nextRevision += 1
        desiredSubmission = Submission(
            revision: nextRevision,
            snapshot: snapshot,
            animatingDifferences: animatingDifferences
        )
        if isReady == false {
            requiresReload = true
        }
        applyDesiredIfReady()
    }

    func setActive(_ active: Bool) {
        isActive = active

        guard active == false else {
            applyDesiredIfReady()
            return
        }

        requiresReload = true
        guard isApplying else { return }

        currentApplyID = nil
        isApplying = false
    }

    func flushIfReady() {
        applyDesiredIfReady()
    }

    private var isReady: Bool {
        guard let listView else { return false }
        return isActive && listView.window != nil && listView.bounds.width > 0 && listView.bounds.height > 0
    }

    private func applyDesiredIfReady() {
        guard let submission = desiredSubmission else { return }
        guard isReady else {
            requiresReload = true
            return
        }
        guard isApplying == false else { return }

        let useReload = requiresReload
        requiresReload = false
        isApplying = true
        applySequence += 1
        let applyID = applySequence
        currentApplyID = applyID
        let snapshot = useReload
            ? submission.snapshot
            : carryingPendingReconfigurations(in: submission.snapshot)

        let didApply = { [weak self] in
            guard let self, self.currentApplyID == applyID else { return }
            self.currentApplyID = nil
            self.isApplying = false
            self.presentedItems = Set(snapshot.itemIdentifiers)

            guard self.isReady else {
                self.requiresReload = true
                return
            }
            guard let desiredSubmission = self.desiredSubmission else { return }
            guard desiredSubmission.revision == submission.revision else {
                self.applyDesiredIfReady()
                return
            }

            self.desiredSubmission = nil
            self.pendingReconfiguredItems.removeAll()
            self.didCommitLatest()
            self.applyDesiredIfReady()
        }

        if useReload {
            applyUsingReloadData(snapshot, didApply)
        } else {
            apply(snapshot, submission.animatingDifferences, didApply)
        }
    }

    private func carryingPendingReconfigurations(in snapshot: Snapshot) -> Snapshot {
        let reconfigured = Set(snapshot.reconfiguredItemIdentifiers)
        let reloaded = Set(snapshot.reloadedItemIdentifiers)
        let carried = snapshot.itemIdentifiers.filter {
            presentedItems.contains($0) &&
                pendingReconfiguredItems.contains($0) &&
                reconfigured.contains($0) == false &&
                reloaded.contains($0) == false
        }
        guard carried.isEmpty == false else { return snapshot }

        var snapshot = snapshot
        snapshot.reconfigureItems(carried)
        return snapshot
    }
}
