import Testing
import UIKit
@testable import DanCam

@MainActor
struct DiffableDataSourceDetachedApplyTests {
    @Test func detachedTableDefersCellCreationUntilAttached() throws {
        LayoutCountingTableCell.layoutCount = 0
        let tableView = UITableView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        tableView.register(LayoutCountingTableCell.self, forCellReuseIdentifier: "cell")
        var cellProviderCount = 0
        let dataSource = UITableViewDiffableDataSource<Int, Int>(tableView: tableView) { tableView, indexPath, _ in
            cellProviderCount += 1
            return tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        }

        dataSource.applyDetachedAware(snapshot(), tableView: tableView)

        #expect(cellProviderCount == 0)
        #expect(LayoutCountingTableCell.layoutCount == 0)

        let window = try attach(tableView)
        defer { window.isHidden = true }
        tableView.layoutIfNeeded()

        #expect(cellProviderCount > 0)
        #expect(LayoutCountingTableCell.layoutCount > 0)
    }

    @Test func detachedCollectionDefersCellCreationUntilAttached() throws {
        LayoutCountingCollectionCell.layoutCount = 0
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 100, height: 44)
        let collectionView = UICollectionView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 480),
            collectionViewLayout: layout
        )
        collectionView.register(LayoutCountingCollectionCell.self, forCellWithReuseIdentifier: "cell")
        var cellProviderCount = 0
        let dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: collectionView) { collectionView, indexPath, _ in
            cellProviderCount += 1
            return collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
        }

        dataSource.applyDetachedAware(snapshot(), collectionView: collectionView)

        #expect(cellProviderCount == 0)
        #expect(LayoutCountingCollectionCell.layoutCount == 0)

        let window = try attach(collectionView)
        defer { window.isHidden = true }
        collectionView.layoutIfNeeded()

        #expect(cellProviderCount > 0)
        #expect(LayoutCountingCollectionCell.layoutCount > 0)
    }

    @Test func detachedTableCompletionIsSynchronous() {
        let tableView = UITableView()
        let dataSource = UITableViewDiffableDataSource<Int, Int>(tableView: tableView) { _, _, _ in
            UITableViewCell()
        }
        var done = false

        dataSource.applyDetachedAware(snapshot(), tableView: tableView) { done = true }

        #expect(done)
    }

    @Test func detachedCollectionCompletionIsSynchronous() {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        let dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: collectionView) { _, _, _ in
            UICollectionViewCell()
        }
        var done = false

        dataSource.applyDetachedAware(snapshot(), collectionView: collectionView) { done = true }

        #expect(done)
    }

    private func snapshot() -> NSDiffableDataSourceSnapshot<Int, Int> {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        snapshot.appendItems([0])
        return snapshot
    }

    private func attach(_ view: UIView) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view = view
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }
}

private final class LayoutCountingTableCell: UITableViewCell {
    static var layoutCount = 0

    override func layoutSubviews() {
        Self.layoutCount += 1
        super.layoutSubviews()
    }
}

private final class LayoutCountingCollectionCell: UICollectionViewCell {
    static var layoutCount = 0

    override func layoutSubviews() {
        Self.layoutCount += 1
        super.layoutSubviews()
    }
}
