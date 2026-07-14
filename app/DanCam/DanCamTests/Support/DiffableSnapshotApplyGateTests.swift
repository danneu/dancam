import Testing
import UIKit
@testable import DanCam

@MainActor
struct DiffableSnapshotApplyGateTests {
    @Test func detachedTableWaitsForUsableGeometryAndRunsCompletionAfterApply() throws {
        LayoutCountingTableCell.layoutCount = 0
        let tableView = UITableView(frame: .zero)
        tableView.register(LayoutCountingTableCell.self, forCellReuseIdentifier: "cell")
        var cellProviderCount = 0
        let dataSource = UITableViewDiffableDataSource<Int, Int>(tableView: tableView) { tableView, indexPath, _ in
            cellProviderCount += 1
            return tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        }
        let gate = DiffableSnapshotApplyGate(dataSource: dataSource, tableView: tableView)
        var completed = false

        gate.setActive(true)
        gate.submit(snapshot(items: [1])) { completed = true }

        #expect(dataSource.snapshot().itemIdentifiers.isEmpty)
        #expect(cellProviderCount == 0)
        #expect(LayoutCountingTableCell.layoutCount == 0)
        #expect(completed == false)

        let window = try attachAtZeroSize(tableView)
        defer { window.isHidden = true }
        gate.flushIfReady()

        #expect(dataSource.snapshot().itemIdentifiers.isEmpty)
        #expect(cellProviderCount == 0)
        #expect(completed == false)

        tableView.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        gate.flushIfReady()
        tableView.layoutIfNeeded()

        #expect(dataSource.snapshot().itemIdentifiers == [1])
        #expect(cellProviderCount > 0)
        #expect(LayoutCountingTableCell.layoutCount > 0)
        #expect(completed)
    }

    @Test func detachedCollectionWaitsForUsableGeometryAndRunsCompletionAfterApply() throws {
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
        let gate = DiffableSnapshotApplyGate(dataSource: dataSource, collectionView: collectionView)
        var completed = false

        gate.setActive(true)
        gate.submit(snapshot(items: [1])) { completed = true }

        #expect(dataSource.snapshot().itemIdentifiers.isEmpty)
        #expect(cellProviderCount == 0)
        #expect(LayoutCountingCollectionCell.layoutCount == 0)
        #expect(completed == false)

        let window = try attachAtZeroSize(collectionView)
        defer { window.isHidden = true }
        gate.flushIfReady()

        #expect(dataSource.snapshot().itemIdentifiers.isEmpty)
        #expect(cellProviderCount == 0)
        #expect(completed == false)

        collectionView.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        gate.flushIfReady()
        collectionView.layoutIfNeeded()

        #expect(dataSource.snapshot().itemIdentifiers == [1])
        #expect(cellProviderCount > 0)
        #expect(LayoutCountingCollectionCell.layoutCount > 0)
        #expect(completed)
    }

    @Test func inactiveSubmissionsCoalesceAndPreserveAllCompletions() throws {
        let tableView = UITableView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let dataSource = UITableViewDiffableDataSource<Int, Int>(tableView: tableView) { _, _, _ in
            UITableViewCell()
        }
        let gate = DiffableSnapshotApplyGate(dataSource: dataSource, tableView: tableView)
        var completions: [Int] = []
        let window = try attach(tableView)
        defer { window.isHidden = true }

        gate.submit(snapshot(items: [1])) { completions.append(1) }
        gate.submit(snapshot(items: [2, 3])) { completions.append(2) }

        #expect(dataSource.snapshot().itemIdentifiers.isEmpty)
        #expect(completions.isEmpty)

        gate.setActive(true)

        #expect(dataSource.snapshot().itemIdentifiers == [2, 3])
        #expect(completions == [1, 2])
    }

    @Test func reactivationUsesReloadDataForNewestInactiveSnapshot() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let window = try attach(view)
        defer { window.isHidden = true }
        var diffs: [[Int]] = []
        var reloads: [[Int]] = []
        let gate = DiffableSnapshotApplyGate<Int, Int>(
            listView: view,
            apply: { snapshot, _, completion in
                diffs.append(snapshot.itemIdentifiers)
                completion()
            },
            applyUsingReloadData: { snapshot, completion in
                reloads.append(snapshot.itemIdentifiers)
                completion()
            }
        )

        gate.setActive(true)
        gate.submit(snapshot(items: [1]))
        gate.setActive(false)
        gate.submit(snapshot(items: [2]))
        gate.submit(snapshot(items: [3, 4]))
        gate.setActive(true)

        #expect(diffs == [[1]])
        #expect(reloads == [[3, 4]])
    }

    @Test func interruptedApplyRepairsBeforeDrainingCompletionsInSubmissionOrder() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let window = try attach(view)
        defer { window.isHidden = true }
        var diffCompletions: [() -> Void] = []
        var reloadItems: [[Int]] = []
        var reloadCompletions: [() -> Void] = []
        var completions: [Int] = []
        let gate = DiffableSnapshotApplyGate<Int, Int>(
            listView: view,
            apply: { _, _, completion in
                diffCompletions.append(completion)
            },
            applyUsingReloadData: { snapshot, completion in
                reloadItems.append(snapshot.itemIdentifiers)
                reloadCompletions.append(completion)
            }
        )

        gate.setActive(true)
        gate.submit(snapshot(items: [1])) { completions.append(1) }
        gate.setActive(false)
        gate.submit(snapshot(items: [2])) { completions.append(2) }
        gate.setActive(true)

        #expect(reloadItems == [[2]])
        #expect(completions.isEmpty)

        let interruptedCompletion = try #require(diffCompletions.first)
        interruptedCompletion()

        #expect(reloadItems == [[2]])
        #expect(completions.isEmpty)

        let repairCompletion = try #require(reloadCompletions.first)
        repairCompletion()

        #expect(completions == [1, 2])
    }

    @Test func submissionDuringApplyIsSerialized() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let window = try attach(view)
        defer { window.isHidden = true }
        var appliedItems: [[Int]] = []
        var applyCompletions: [() -> Void] = []
        let gate = DiffableSnapshotApplyGate<Int, Int>(
            listView: view,
            apply: { snapshot, _, completion in
                appliedItems.append(snapshot.itemIdentifiers)
                applyCompletions.append(completion)
            },
            applyUsingReloadData: { _, _ in
                Issue.record("Ready submissions should not use reload-data.")
            }
        )

        gate.setActive(true)
        gate.submit(snapshot(items: [1]))
        gate.submit(snapshot(items: [2]))

        #expect(appliedItems == [[1]])
        let firstCompletion = try #require(applyCompletions.first)
        firstCompletion()

        #expect(appliedItems == [[1], [2]])
    }

    @Test func readySubmissionUsesNormalDiffAndPreservesAnimationPreference() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let window = try attach(view)
        defer { window.isHidden = true }
        var animations: [Bool] = []
        var reloadCount = 0
        let gate = DiffableSnapshotApplyGate<Int, Int>(
            listView: view,
            apply: { _, animated, completion in
                animations.append(animated)
                completion()
            },
            applyUsingReloadData: { _, completion in
                reloadCount += 1
                completion()
            }
        )

        gate.setActive(true)
        gate.submit(snapshot(items: [1]), animatingDifferences: false)
        gate.submit(snapshot(items: [2]), animatingDifferences: true)

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
