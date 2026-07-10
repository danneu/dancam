import UIKit

final class DebugViewController: UIViewController {
    private let dependencies: AppDependencies
    private let appStore: AppStore
    private var observation: StoreObservation?
    private(set) var lastExportOutcome: Result<String, Error>?
    private var currentExportError: String?
    private var renderedSections = [DebugSection]()
    private var renderedRows = [DebugRowID: DebugRow]()

    private let refreshControl = UIRefreshControl()
    private lazy var collectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: makeLayout()
    )
    private lazy var dataSource = makeDataSource()

    init(
        dependencies: AppDependencies,
        store appStore: AppStore
    ) {
        self.dependencies = dependencies
        self.appStore = appStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DebugViewController is programmatic.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.title = "Debug"
        view.backgroundColor = .systemBackground
        configureCollectionView()
        observation = appStore.observe(select: \.link) { [weak self] _ in
            self?.render()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    private func makeLayout() -> UICollectionViewLayout {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        return UICollectionViewCompositionalLayout.list(using: configuration)
    }

    private func configureCollectionView() {
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        refreshControl.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        collectionView.refreshControl = refreshControl

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        _ = dataSource
    }

    private func makeDataSource() -> UICollectionViewDiffableDataSource<DebugSectionID, DebugRowID> {
        let valueRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, DebugRowID> { [weak self] cell, _, id in
            guard let row = self?.renderedRows[id],
                  case .value(_, let label, let value, let tint, let detail, let detailTint) = row
            else { return }

            var content = UIListContentConfiguration.valueCell()
            content.text = label
            content.textProperties.adjustsFontForContentSizeCategory = true
            content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
            let valueFont = id == .value(.bootID)
                ? UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)
                : UIFont.monospacedDigitSystemFont(ofSize: 17, weight: .regular)
            let scaledValueFont = UIFontMetrics(forTextStyle: .body).scaledFont(for: valueFont)

            if let detail {
                let text = "\(value) \(detail)"
                let attributedText = NSMutableAttributedString(
                    string: text,
                    attributes: [.font: scaledValueFont]
                )
                attributedText.addAttribute(
                    .foregroundColor,
                    value: tint.color(default: .secondaryLabel),
                    range: NSRange(location: 0, length: value.utf16.count)
                )
                attributedText.addAttribute(
                    .foregroundColor,
                    value: detailTint.color(default: .secondaryLabel),
                    range: NSRange(location: value.utf16.count + 1, length: detail.utf16.count)
                )
                content.secondaryAttributedText = attributedText
            } else {
                content.secondaryText = value
                content.secondaryTextProperties.font = scaledValueFont
                content.secondaryTextProperties.color = tint.color(default: .secondaryLabel)
            }
            cell.contentConfiguration = content
        }

        let messageRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, DebugRowID> { [weak self] cell, _, id in
            guard let row = self?.renderedRows[id] else { return }

            var content = UIListContentConfiguration.cell()
            content.textProperties.adjustsFontForContentSizeCategory = true
            content.textProperties.numberOfLines = 0
            switch row {
            case .banner(let message):
                content.text = message
                content.textProperties.color = .secondaryLabel
            case .exportError(let message):
                content.text = message
                content.textProperties.color = .systemRed
            default:
                return
            }
            cell.contentConfiguration = content
        }

        let buttonRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, DebugRowID> { cell, _, _ in
            var content = UIListContentConfiguration.cell()
            content.text = "Export logs"
            content.textProperties.color = .tintColor
            content.textProperties.adjustsFontForContentSizeCategory = true
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let gaugeRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, DebugRowID> { [weak self] cell, _, id in
            guard let row = self?.renderedRows[id],
                  case .gauge(_, let title, let detail, let fraction, let tint) = row
            else { return }

            cell.contentConfiguration = DebugGaugeConfiguration(
                title: title,
                detail: detail,
                fraction: fraction,
                tint: tint
            )
        }

        let source = UICollectionViewDiffableDataSource<DebugSectionID, DebugRowID>(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            guard let self, let row = self.renderedRows[id] else { return nil }
            switch row {
            case .value:
                return collectionView.dequeueConfiguredReusableCell(using: valueRegistration, for: indexPath, item: id)
            case .gauge:
                return collectionView.dequeueConfiguredReusableCell(using: gaugeRegistration, for: indexPath, item: id)
            case .button:
                return collectionView.dequeueConfiguredReusableCell(using: buttonRegistration, for: indexPath, item: id)
            case .banner, .exportError:
                return collectionView.dequeueConfiguredReusableCell(using: messageRegistration, for: indexPath, item: id)
            }
        }

        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            guard let self,
                  let sectionID = self.dataSource.snapshot().sectionIdentifiers[safe: indexPath.section],
                  let title = self.renderedSections.first(where: { $0.id == sectionID })?.title
            else {
                header.contentConfiguration = nil
                return
            }

            var content = UIListContentConfiguration.header()
            content.text = title
            header.contentConfiguration = content
        }
        source.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }

        return source
    }

    private func render() {
        apply(DebugScreen.sections(for: appStore.state, exportError: currentExportError))
    }

    private func apply(_ sections: [DebugSection]) {
        guard sections != renderedSections else { return }

        let nextRows = Dictionary(uniqueKeysWithValues: sections.flatMap(\.rows).map { ($0.id, $0) })
        let currentIdentity = renderedSections.map { ($0.id, $0.rows.map(\.id)) }
        let nextIdentity = sections.map { ($0.id, $0.rows.map(\.id)) }

        if currentIdentity.elementsEqual(nextIdentity, by: { $0.0 == $1.0 && $0.1 == $1.1 }) {
            let changed = nextRows.compactMap { id, row in
                renderedRows[id] == row ? nil : id
            }
            renderedSections = sections
            renderedRows = nextRows

            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(changed)
            dataSource.apply(snapshot, animatingDifferences: false)
            return
        }

        renderedSections = sections
        renderedRows = nextRows
        var snapshot = NSDiffableDataSourceSnapshot<DebugSectionID, DebugRowID>()
        for section in sections {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.rows.map(\.id), toSection: section.id)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    @objc private func refreshPulled() {
        appStore.send(.reconnectStreamIfOffline)
        refreshControl.endRefreshing()
    }

    @objc private func exportLogsTapped() {
        Task { [weak self] in
            await self?.exportLogs(presentShareSheet: true)
        }
    }

    func buildExportText() async -> Result<String, Error> {
        let result: Result<String, Error>

        do {
            let body = try await dependencies.logExporter.export(.seconds(600))
            result = .success("""
            DanCam log export
            App version: \(Self.appVersion)
            State snapshot: \(appStore.state.logSnapshot)

            \(body)
            """)
        } catch {
            result = .failure(error)
        }

        lastExportOutcome = result
        return result
    }

    func exportLogsForTesting() async {
        await exportLogs(presentShareSheet: false)
    }

    func pullToRefreshForTesting() {
        refreshControl.beginRefreshing()
        refreshPulled()
    }

    var isRefreshingForTesting: Bool {
        refreshControl.isRefreshing
    }

    func rowForTesting(_ id: DebugRowID) -> DebugRow? {
        renderedRows[id]
    }

    var rowIDsForTesting: [DebugRowID] {
        dataSource.snapshot().itemIdentifiers
    }

    func secondaryAttributedTextForTesting(_ id: DebugValueID) -> NSAttributedString? {
        let rowID = DebugRowID.value(id)
        guard let indexPath = dataSource.indexPath(for: rowID) else { return nil }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        collectionView.layoutIfNeeded()
        guard let cell = collectionView.cellForItem(at: indexPath),
              let configuration = cell.contentConfiguration as? UIListContentConfiguration
        else { return nil }

        return configuration.secondaryAttributedText
    }

    func presentedGaugeForTesting(_ id: DebugGaugeID) -> DebugRow? {
        guard let indexPath = dataSource.indexPath(for: .gauge(id)) else { return nil }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        collectionView.layoutIfNeeded()
        guard let cell = collectionView.cellForItem(at: indexPath),
              let configuration = cell.contentConfiguration as? DebugGaugeConfiguration
        else { return nil }

        return .gauge(
            id: id,
            title: configuration.title,
            detail: configuration.detail,
            fraction: configuration.fraction,
            tint: configuration.tint
        )
    }

    private func exportLogs(presentShareSheet: Bool) async {
        switch await buildExportText() {
        case .success(let text):
            currentExportError = nil
            render()
            if presentShareSheet {
                let activityController = UIActivityViewController(activityItems: [text], applicationActivities: nil)
                present(activityController, animated: true)
            }
        case .failure(let error):
            currentExportError = "Log export failed: \(error.localizedDescription)"
            render()
        }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }
}

extension DebugViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        defer { collectionView.deselectItem(at: indexPath, animated: true) }
        guard dataSource.itemIdentifier(for: indexPath) == .button(.exportLogs) else { return }
        exportLogsTapped()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard dataSource.itemIdentifier(for: indexPath) == .value(.bootID),
              case .value(_, _, let value, _, _, _) = renderedRows[.value(.bootID)],
              value != "--"
        else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = value
                },
            ])
        }
    }
}

private struct DebugGaugeConfiguration: UIContentConfiguration, Hashable {
    var title: String
    var detail: String
    var fraction: Double
    var tint: DebugTint

    func makeContentView() -> any UIView & UIContentView {
        DebugGaugeContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> DebugGaugeConfiguration {
        self
    }
}

private final class DebugGaugeContentView: UIView, UIContentView {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)

    var configuration: any UIContentConfiguration {
        didSet {
            guard let configuration = configuration as? DebugGaugeConfiguration else { return }
            apply(configuration)
        }
    }

    init(configuration: DebugGaugeConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        configureViews()
        apply(configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DebugGaugeContentView is programmatic.")
    }

    private func configureViews() {
        // Custom UIContentViews don't inherit the list cell's grouped-style
        // content insets the way UIListContentConfiguration views do; preserve
        // the cell's margins so gauge rows align with the system value cells.
        preservesSuperviewLayoutMargins = true
        directionalLayoutMargins = UIListContentConfiguration.valueCell().directionalLayoutMargins

        isAccessibilityElement = true
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        )

        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel, progressView])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
        ])
    }

    private func apply(_ configuration: DebugGaugeConfiguration) {
        titleLabel.text = configuration.title
        detailLabel.text = configuration.detail
        progressView.progress = Float(configuration.fraction)
        progressView.progressTintColor = configuration.tint.color(default: tintColor)
        accessibilityLabel = configuration.title
        accessibilityValue = configuration.detail
    }
}

private extension DebugTint {
    func color(default defaultColor: UIColor) -> UIColor {
        switch self {
        case .neutral:
            defaultColor
        case .warn:
            .systemOrange
        case .critical:
            .systemRed
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
