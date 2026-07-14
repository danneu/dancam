import Testing
import UIKit
@testable import DanCam

@MainActor
struct DiffableSnapshotPresenterTests {
    @Test func detachedTableWaitsForUsableGeometryAndCommitsAfterApply() throws {
        LayoutCountingTableCell.layoutCount = 0
        let tableView = UITableView(frame: .zero)
        tableView.register(LayoutCountingTableCell.self, forCellReuseIdentifier: "cell")
        var cellProviderCount = 0
        let dataSource = UITableViewDiffableDataSource<Int, Int>(tableView: tableView) { tableView, indexPath, _ in
            cellProviderCount += 1
            return tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        }
        var commitCount = 0
        let presenter = DiffableSnapshotPresenter(
            dataSource: dataSource,
            tableView: tableView,
            didCommitLatest: { commitCount += 1 }
        )

        presenter.setActive(true)
        presenter.submit(snapshot(items: [1]))

        #expect(dataSource.snapshot().itemIdentifiers.isEmpty)
        #expect(cellProviderCount == 0)
        #expect(LayoutCountingTableCell.layoutCount == 0)
        #expect(commitCount == 0)

        let window = try attachAtZeroSize(tableView)
        defer { window.isHidden = true }
        presenter.flushIfReady()

        #expect(dataSource.snapshot().itemIdentifiers.isEmpty)
        #expect(cellProviderCount == 0)
        #expect(commitCount == 0)

        tableView.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        presenter.flushIfReady()
        tableView.layoutIfNeeded()

        #expect(dataSource.snapshot().itemIdentifiers == [1])
        #expect(cellProviderCount > 0)
        #expect(LayoutCountingTableCell.layoutCount > 0)
        #expect(commitCount == 1)
    }

    @Test func detachedCollectionWaitsForUsableGeometryAndCommitsAfterApply() throws {
        LayoutCountingCollectionCell.layoutCount = 0
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: 100, height: 44)
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.register(LayoutCountingCollectionCell.self, forCellWithReuseIdentifier: "cell")
        var cellProviderCount = 0
        let dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: collectionView) { collectionView, indexPath, _ in
            cellProviderCount += 1
            return collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
        }
        var commitCount = 0
        let presenter = DiffableSnapshotPresenter(
            dataSource: dataSource,
            collectionView: collectionView,
            didCommitLatest: { commitCount += 1 }
        )

        presenter.setActive(true)
        presenter.submit(snapshot(items: [1]))

        #expect(dataSource.snapshot().itemIdentifiers.isEmpty)
        #expect(cellProviderCount == 0)
        #expect(LayoutCountingCollectionCell.layoutCount == 0)
        #expect(commitCount == 0)

        let window = try attachAtZeroSize(collectionView)
        defer { window.isHidden = true }
        presenter.flushIfReady()

        #expect(dataSource.snapshot().itemIdentifiers.isEmpty)
        #expect(cellProviderCount == 0)
        #expect(commitCount == 0)

        collectionView.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        presenter.flushIfReady()
        collectionView.layoutIfNeeded()

        #expect(dataSource.snapshot().itemIdentifiers == [1])
        #expect(cellProviderCount > 0)
        #expect(LayoutCountingCollectionCell.layoutCount > 0)
        #expect(commitCount == 1)
    }

    @Test func inactiveSubmissionsCoalesceToNewestSnapshotAndEmitOneCommit() throws {
        let tableView = UITableView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let dataSource = UITableViewDiffableDataSource<Int, Int>(tableView: tableView) { _, _, _ in
            UITableViewCell()
        }
        var commitCount = 0
        let presenter = DiffableSnapshotPresenter(
            dataSource: dataSource,
            tableView: tableView,
            didCommitLatest: { commitCount += 1 }
        )
        let window = try attach(tableView)
        defer { window.isHidden = true }

        presenter.submit(snapshot(items: [1]))
        presenter.submit(snapshot(items: [2, 3]))

        #expect(dataSource.snapshot().itemIdentifiers.isEmpty)
        #expect(commitCount == 0)

        presenter.setActive(true)

        #expect(dataSource.snapshot().itemIdentifiers == [2, 3])
        #expect(commitCount == 1)
    }

    @Test func newerSubmissionDuringApplySuppressesOlderCommit() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let window = try attach(view)
        defer { window.isHidden = true }
        var appliedItems: [[Int]] = []
        var applyCompletions: [() -> Void] = []
        var commitCount = 0
        let presenter = DiffableSnapshotPresenter<Int, Int>(
            listView: view,
            apply: { snapshot, _, completion in
                appliedItems.append(snapshot.itemIdentifiers)
                applyCompletions.append(completion)
            },
            applyUsingReloadData: { _, _ in
                Issue.record("Ready submissions should not use reload-data.")
            },
            didCommitLatest: { commitCount += 1 }
        )

        presenter.setActive(true)
        presenter.submit(snapshot(items: [1]))
        presenter.submit(snapshot(items: [2]))

        #expect(appliedItems == [[1]])
        let firstCompletion = try #require(applyCompletions.first)
        firstCompletion()

        #expect(appliedItems == [[1], [2]])
        #expect(commitCount == 0)
        let latestCompletion = try #require(applyCompletions.last)
        latestCompletion()

        #expect(commitCount == 1)
    }

    @Test func reactivationImmediatelyRepairsInterruptedApplyAndIgnoresStaleCallback() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let window = try attach(view)
        defer { window.isHidden = true }
        var diffCompletions: [() -> Void] = []
        var reloadItems: [[Int]] = []
        var reloadCompletions: [() -> Void] = []
        var commitCount = 0
        let presenter = DiffableSnapshotPresenter<Int, Int>(
            listView: view,
            apply: { _, _, completion in
                diffCompletions.append(completion)
            },
            applyUsingReloadData: { snapshot, completion in
                reloadItems.append(snapshot.itemIdentifiers)
                reloadCompletions.append(completion)
            },
            didCommitLatest: { commitCount += 1 }
        )

        presenter.setActive(true)
        presenter.submit(snapshot(items: [1]))
        presenter.setActive(false)
        presenter.submit(snapshot(items: [2]))
        presenter.setActive(true)

        #expect(reloadItems == [[2]])
        #expect(commitCount == 0)

        let interruptedCompletion = try #require(diffCompletions.first)
        interruptedCompletion()

        #expect(reloadItems == [[2]])
        #expect(commitCount == 0)

        let repairCompletion = try #require(reloadCompletions.first)
        repairCompletion()

        #expect(commitCount == 1)
    }

    @Test func commitHandlerMaySynchronouslySubmitAnotherSnapshot() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let window = try attach(view)
        defer { window.isHidden = true }
        var appliedItems: [[Int]] = []
        var applyCompletions: [() -> Void] = []
        var commitCount = 0
        let holder = PresenterHolder()
        let presenter = DiffableSnapshotPresenter<Int, Int>(
            listView: view,
            apply: { snapshot, _, completion in
                appliedItems.append(snapshot.itemIdentifiers)
                applyCompletions.append(completion)
            },
            applyUsingReloadData: { _, _ in
                Issue.record("Ready submissions should not use reload-data.")
            },
            didCommitLatest: {
                commitCount += 1
                if commitCount == 1 {
                    holder.presenter?.submit(self.snapshot(items: [2]))
                }
            }
        )
        holder.presenter = presenter

        presenter.setActive(true)
        presenter.submit(snapshot(items: [1]))
        let firstCompletion = try #require(applyCompletions.first)
        firstCompletion()

        #expect(appliedItems == [[1], [2]])
        #expect(commitCount == 1)

        let secondCompletion = try #require(applyCompletions.last)
        secondCompletion()

        #expect(commitCount == 2)
    }

    @Test func reactivationUsesReloadDataForNewestInactiveSnapshot() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let window = try attach(view)
        defer { window.isHidden = true }
        var diffs: [[Int]] = []
        var reloads: [[Int]] = []
        var commitCount = 0
        let presenter = DiffableSnapshotPresenter<Int, Int>(
            listView: view,
            apply: { snapshot, _, completion in
                diffs.append(snapshot.itemIdentifiers)
                completion()
            },
            applyUsingReloadData: { snapshot, completion in
                reloads.append(snapshot.itemIdentifiers)
                completion()
            },
            didCommitLatest: { commitCount += 1 }
        )

        presenter.setActive(true)
        presenter.submit(snapshot(items: [1]))
        presenter.setActive(false)
        presenter.submit(snapshot(items: [2]))
        presenter.submit(snapshot(items: [3, 4]))
        presenter.setActive(true)

        #expect(diffs == [[1]])
        #expect(reloads == [[3, 4]])
        #expect(commitCount == 2)
    }

    @Test func readySubmissionsPreserveAnimationPreference() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let window = try attach(view)
        defer { window.isHidden = true }
        var animations: [Bool] = []
        var reloadCount = 0
        let presenter = DiffableSnapshotPresenter<Int, Int>(
            listView: view,
            apply: { _, animated, completion in
                animations.append(animated)
                completion()
            },
            applyUsingReloadData: { _, completion in
                reloadCount += 1
                completion()
            },
            didCommitLatest: {}
        )

        presenter.setActive(true)
        presenter.submit(snapshot(items: [1]), animatingDifferences: false)
        presenter.submit(snapshot(items: [2]), animatingDifferences: true)

        #expect(animations == [false, true])
        #expect(reloadCount == 0)
    }

    private func snapshot(items: [Int]) -> NSDiffableDataSourceSnapshot<Int, Int> {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        snapshot.appendItems(items)
        return snapshot
    }

    private func attachAtZeroSize(_ view: UIView) throws -> UIWindow {
        let window = try makeWindow()
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        view.frame = .zero
        window.makeKeyAndVisible()
        return window
    }

    private func attach(_ view: UIView) throws -> UIWindow {
        let window = try makeWindow()
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        return window
    }

    private func makeWindow() throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        return UIWindow(windowScene: scene)
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

@MainActor
private final class PresenterHolder {
    var presenter: DiffableSnapshotPresenter<Int, Int>?
}
