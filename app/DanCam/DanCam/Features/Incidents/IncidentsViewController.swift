import UIKit

nonisolated private enum IncidentListSection: Hashable, Sendable { case incidents }

@MainActor
final class IncidentsViewController: UIViewController, UICollectionViewDelegate {
    private let dependencies: AppDependencies
    private let store: AppStore
    private var observation: StoreObservation?
    private var projection = IncidentListProjection(rows: [], count: 0, totalBytes: 0)

    private lazy var collectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: makeLayout()
    )
    private lazy var dataSource = makeDataSource()
    private lazy var snapshotPresenter = DiffableSnapshotPresenter(
        dataSource: dataSource,
        collectionView: collectionView,
        didCommitLatest: { [weak self] in
            self?.refreshVisibleHeaders()
        }
    )
    private var isViewActive = false

    init(dependencies: AppDependencies, store: AppStore) {
        self.dependencies = dependencies
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("IncidentsViewController is programmatic.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.title = "Incidents"
        view.backgroundColor = .systemGroupedBackground
        configureCollectionView()
        observation = store.observe(select: { IncidentListProjection.project($0.incidents) }) { [weak self] in
            self?.render($0)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isViewActive = true
        snapshotPresenter.setActive(true)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isViewActive = false
        snapshotPresenter.setActive(false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        snapshotPresenter.flushIfReady()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        snapshotPresenter.flushIfReady()
    }

    private func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let itemID = self.dataSource.itemIdentifier(for: indexPath) else { return nil }
            return UISwipeActionsConfiguration(actions: [
                IncidentDeleteConfirmation.swipeAction(presenting: self) { [weak self] in
                    self?.store.send(.incidents(.deleteTapped(itemID)))
                },
            ])
        }
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    private func configureCollectionView() {
        collectionView.delegate = self
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        _ = dataSource
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<IncidentListSection, IncidentListItemID> {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, IncidentListItemID> {
            [weak self] cell, _, itemID in
            guard let self, let row = self.projection.rows.first(where: { $0.id == itemID }) else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.textProperties.adjustsFontForContentSizeCategory = true
            content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
            content.imageProperties.maximumSize = CGSize(width: 88, height: 50)
            content.imageProperties.cornerRadius = 6

            if let record = row.record, let pressedAt = row.pressedAt {
                content.text = Formatters.incidentPressedAt(pressedAt)
                content.secondaryText = [
                    row.coveredDurationMs > 0 ? Formatters.approximateDuration(row.coveredDurationMs) : nil,
                    row.bytes > 0 ? Formatters.byteSize(row.bytes) : nil,
                ].compactMap { $0 }.joined(separator: " - ")
                let thumbnailURL = self.dependencies.incidentStore.directoryURL(record.id)
                    .appending(path: "thumb.jpg")
                content.image = UIImage(contentsOfFile: thumbnailURL.path) ?? UIImage(systemName: "car.rear.road.lane")
                cell.accessories = [
                    .customView(configuration: .init(customView: IncidentStatusAccessory(status: row.status), placement: .trailing())),
                    .disclosureIndicator(),
                ]
            } else {
                content.text = "Unreadable incident"
                content.secondaryText = "Saved files could not be read"
                content.image = UIImage(systemName: "exclamationmark.triangle")
                content.imageProperties.tintColor = .systemOrange
                cell.accessories = [
                    .customView(configuration: .init(customView: IncidentStatusAccessory(status: .unreadable), placement: .trailing())),
                ]
            }
            cell.contentConfiguration = content
            cell.accessibilityLabel = [content.text, content.secondaryText, statusText(row.status)]
                .compactMap { $0 }.joined(separator: ", ")
        }

        let source = UICollectionViewDiffableDataSource<IncidentListSection, IncidentListItemID>(
            collectionView: collectionView
        ) { collectionView, indexPath, itemID in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: itemID)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, _ in
            self?.configureHeader(view)
        }
        source.supplementaryViewProvider = { collectionView, kind, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
        return source
    }

    private func render(_ projection: IncidentListProjection) {
        self.projection = projection
        let previousIDs = Set(dataSource.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<IncidentListSection, IncidentListItemID>()
        snapshot.appendSections([.incidents])
        snapshot.appendItems(projection.rows.map(\.id))
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter(previousIDs.contains))
        snapshotPresenter.submit(snapshot)
    }

    private func configureHeader(_ header: UICollectionViewListCell) {
        var content = UIListContentConfiguration.header()
        let count = projection.count
        let incidentText = count == 1 ? "1 incident" : "\(count) incidents"
        content.text = "\(incidentText) - \(Formatters.byteSize(projection.totalBytes))"
        header.contentConfiguration = content
    }

    private func refreshVisibleHeaders() {
        guard isViewActive, view.window != nil, collectionView.window != nil else { return }
        for case let header as UICollectionViewListCell in collectionView.visibleSupplementaryViews(
            ofKind: UICollectionView.elementKindSectionHeader
        ) {
            configureHeader(header)
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let itemID = dataSource.itemIdentifier(for: indexPath),
              let row = projection.rows.first(where: { $0.id == itemID }),
              let record = row.record else { return }
        navigationController?.pushViewController(
            IncidentDetailViewController(
                dependencies: dependencies,
                store: store,
                incidentID: record.id
            ),
            animated: true
        )
    }

    var projectionForTesting: IncidentListProjection { projection }

    var presentedItemIDsForTesting: [IncidentListItemID] {
        dataSource.snapshot().itemIdentifiers
    }

    var presentedHeaderTextForTesting: String? {
        view.layoutIfNeeded()
        collectionView.layoutIfNeeded()
        return collectionView.visibleSupplementaryViews(
            ofKind: UICollectionView.elementKindSectionHeader
        ).compactMap { view in
            (view as? UICollectionViewListCell)?.contentConfiguration as? UIListContentConfiguration
        }.first?.text
    }

    func layoutCollectionForTesting() {
        view.layoutIfNeeded()
        collectionView.layoutIfNeeded()
    }
}

@MainActor
private final class IncidentStatusAccessory: UIView {
    private var accessorySize = CGSize.zero

    init(status: IncidentListStatus) {
        super.init(frame: .zero)
        if status == .saving {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            spinner.frame.size = spinner.intrinsicContentSize
            addSubview(spinner)
            accessorySize = spinner.intrinsicContentSize
        } else {
            let label = UILabel()
            label.text = statusText(status)
            label.font = .preferredFont(forTextStyle: .caption1)
            label.adjustsFontForContentSizeCategory = true
            let tint: UIColor = switch status {
            case .partial, .unreadable: .systemOrange
            case .saved: .systemGreen
            case .saving: .secondaryLabel
            }
            label.textColor = tint
            label.sizeToFit()
            label.frame.origin = CGPoint(x: 6, y: 3)
            addSubview(label)
            backgroundColor = tint.withAlphaComponent(0.14)
            layer.cornerRadius = 6
            accessorySize = CGSize(width: label.bounds.width + 12, height: label.bounds.height + 6)
        }
        frame.size = accessorySize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("IncidentStatusAccessory is programmatic.") }

    override var intrinsicContentSize: CGSize { accessorySize }
}

private func statusText(_ status: IncidentListStatus) -> String {
    switch status {
    case .saving: "Saving"
    case .saved: "Saved"
    case .partial: "Partial"
    case .unreadable: "Unreadable"
    }
}
