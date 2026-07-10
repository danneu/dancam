import UIKit

extension UITableViewDiffableDataSource {
    func applyDetachedAware(
        _ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>,
        tableView: UITableView,
        animatedWhenAttached: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        if tableView.window != nil {
            apply(snapshot, animatingDifferences: animatedWhenAttached, completion: completion)
        } else {
            applySnapshotUsingReloadData(snapshot, completion: completion)
        }
    }
}

extension UICollectionViewDiffableDataSource {
    func applyDetachedAware(
        _ snapshot: NSDiffableDataSourceSnapshot<SectionIdentifierType, ItemIdentifierType>,
        collectionView: UICollectionView,
        animatedWhenAttached: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        if collectionView.window != nil {
            apply(snapshot, animatingDifferences: animatedWhenAttached, completion: completion)
        } else {
            applySnapshotUsingReloadData(snapshot, completion: completion)
        }
    }
}
