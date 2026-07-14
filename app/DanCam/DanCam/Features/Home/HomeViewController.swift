import UIKit

nonisolated enum HomeRow: Equatable, Sendable {
    case finished(Clip)
    case recording(RecordingGroup)

    var id: HomeRowID {
        switch self {
        case .finished(let clip):
            .finished(clip.id)
        case .recording(let recording):
            .recording(recording: recording.recordingID, occurrence: recording.occurrence)
        }
    }

    var thumbnailClip: Clip? {
        switch self {
        case .finished(let clip):
            return clip
        case .recording(let recording):
            return recording.representative
        }
    }

    var thumbnailIdentity: ClipThumbnailIdentity? {
        thumbnailClip.map(ClipThumbnailIdentity.init)
    }
}

final class HomeViewController: UIViewController, UITableViewDelegate, UITableViewDataSourcePrefetching, ConnectionResumable {
    private let dependencies: AppDependencies
    private let store: AppStore
    private let previewViewController: PreviewViewController
    private let wallNow: () -> Date
    private let currentCalendar: () -> Calendar

    private var liveRecordingObservation: StoreObservation?
    private var statusPillsObservation: StoreObservation?
    private var clipsObservation: StoreObservation?
    private var clipsStatusObservation: StoreObservation?
    private var clipsLoadedObservation: StoreObservation?
    private var clipsNextCursorObservation: StoreObservation?
    private var incidentButtonObservation: StoreObservation?
    private var incidentFailureObservation: StoreObservation?
    private var calendarDayChangedObserver: NSObjectProtocol?
    private var significantTimeChangedObserver: NSObjectProtocol?

    private let headerContainer = UIView()
    private let headerStack = UIStackView()
    private let statusPillsStack = UIStackView()
    private let tempWarningPill = StatusPillView()
    private let errorPill = StatusPillView()
    private let timeUnverifiedPill = StatusPillView()
    private let recordButton = RecordButton(frame: .zero)
    private let recordButtonRow = UIView()
    private let incidentButton: IncidentButton
    private let incidentButtonRow = UIView()
    private let liveRecordingWidget = LiveRecordingStatusView()
    private let clipsHeaderLabel = UILabel()
    private let clipsTableView = UITableView(frame: .zero, style: .plain)
    private let refreshControl = UIRefreshControl()
    private let clipsFailureBanner = StatusPillView()
    private let clipsBodyPlaceholderView = UIStackView()
    private let clipsLoadingIndicator = UIActivityIndicatorView(style: .medium)
    private let emptyClipsView = UIStackView()
    private let emptyClipsImageView = UIImageView(image: UIImage(systemName: "film"))
    private let emptyClipsLabel = UILabel()
    private let clock = ContinuousClock()
    private let paginationThreshold = 4
    private var dataSource: UITableViewDiffableDataSource<HomeSection, HomeRowID>!
    private lazy var snapshotGate = DiffableSnapshotApplyGate(
        dataSource: dataSource,
        tableView: clipsTableView
    )

    private var liveRecordingStatus: LiveRecordingStatus = .none
    private var recordingAttribution: RecordingAttribution?
    private var finishedClips: [Clip] = []
    private var clipsStatus: ClipsFeature.State.Status = .idle
    private var clipsNextCursor: String?
    private var clipsHasLoadedOnce = false
    private var sections: [HomeSectionModel] = []
    private var rows: [HomeRow] = []
    private var rowsByID: [HomeRowID: HomeRow] = [:]
    private var paginationTailIDs: Set<HomeRowID> = []
    private var preservedVisibleThumbnails: [ClipThumbnailIdentity: UIImage] = [:]
    private var preservedThumbnailGeneration = 0
    private var isManualRefreshing = false
    private var lastFittedHeaderWidth: CGFloat?
    private var needsHeaderRefit = true
    private var prefetchHandles: [ClipThumbnailIdentity: ThumbnailLoader.PrefetchHandle] = [:]
    private var isViewActive = false

    init(
        dependencies: AppDependencies,
        store: AppStore,
        wallNow: @escaping () -> Date = Date.init,
        currentCalendar: @escaping () -> Calendar = { .current }
    ) {
        self.dependencies = dependencies
        self.store = store
        self.wallNow = wallNow
        self.currentCalendar = currentCalendar
        incidentButton = IncidentButton(frame: .zero, continuousNow: dependencies.continuousNow)
        previewViewController = PreviewViewController(dependencies: dependencies)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HomeViewController is programmatic.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.title = "DanCam"
        view.backgroundColor = .systemBackground

        addChild(previewViewController)
        configureViews()
        previewViewController.didMove(toParent: self)
        observeDayRolloverNotifications()

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (viewController: HomeViewController, _) in
            viewController.needsHeaderRefit = true
            viewController.view.setNeedsLayout()
        }

        liveRecordingObservation = store.observe(select: LiveRecordingInputs.from) { [weak self] inputs in
            self?.renderLiveRecording(inputs)
            self?.renderRows()
        }
        statusPillsObservation = store.observe(select: { HomeStatusPills.from($0.link.world) }) { [weak self] pills in
            self?.renderStatusPills(pills)
        }
        clipsObservation = store.observe(\.clips.clips) { [weak self] clips in
            self?.renderClips(clips)
        }
        clipsStatusObservation = store.observe(\.clips.status) { [weak self] status in
            self?.handleClipsStatus(status)
        }
        clipsLoadedObservation = store.observe(\.clips.hasLoadedOnce) { [weak self] hasLoadedOnce in
            self?.clipsHasLoadedOnce = hasLoadedOnce
            self?.updateClipsPresentation()
        }
        clipsNextCursorObservation = store.observe(\.clips.nextCursor) { [weak self] nextCursor in
            self?.clipsNextCursor = nextCursor
            self?.loadMoreIfVisibleTail()
        }
        let continuousNow = dependencies.continuousNow
        incidentButtonObservation = store.observe(select: { state in
            IncidentButtonPresentation.from(state, now: continuousNow())
        }) { [weak self] presentation in
            guard let self else { return }
            self.incidentButton.apply(presentation, now: self.dependencies.continuousNow())
        }
        incidentFailureObservation = store.observe(\.incidents.persistenceFailed) { [weak self] failed in
            guard failed else { return }
            self?.presentIncidentPersistenceAlert()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isViewActive = true
        snapshotGate.setActive(true)
        view.setNeedsLayout()
        reconfigureVisibleThumbnails()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isViewActive = false
        snapshotGate.setActive(false)
        store.send(.clips(.onDisappear))
        refreshControl.endRefreshing()
        isManualRefreshing = false
        cancelAllPrefetches()
        quietVisibleThumbnailLoads()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        snapshotGate.flushIfReady()
        reconfigureVisibleThumbnails()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        installOrSizeHeaderIfPossible()
        updateClipsBottomInset()
        snapshotGate.flushIfReady()
    }

    isolated deinit {
        cancelAllPrefetches()
        if let calendarDayChangedObserver {
            NotificationCenter.default.removeObserver(calendarDayChangedObserver)
        }
        if let significantTimeChangedObserver {
            NotificationCenter.default.removeObserver(significantTimeChangedObserver)
        }
    }

    func resumeLiveWork() {
        previewViewController.reconnect()
    }

    private func configureViews() {
        configurePreview()
        configureStatusPills()
        configureClipsTable()
        configureFailureBanner()

        recordButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)
        recordButton.apply(.unknown)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        liveRecordingWidget.isHidden = true
        recordButtonRow.addSubview(recordButton)

        incidentButton.addTarget(self, action: #selector(incidentTapped), for: .touchUpInside)
        incidentButton.apply(.unavailable, now: dependencies.continuousNow())
        incidentButton.translatesAutoresizingMaskIntoConstraints = false
        incidentButtonRow.addSubview(incidentButton)

        headerContainer.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 12,
            leading: 16,
            bottom: 0,
            trailing: 16
        )
        headerStack.axis = .vertical
        headerStack.spacing = 12
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.addArrangedSubview(previewViewController.view)
        headerStack.addArrangedSubview(recordButtonRow)
        headerStack.addArrangedSubview(incidentButtonRow)
        headerStack.addArrangedSubview(liveRecordingWidget)
        headerStack.addArrangedSubview(statusPillsStack)
        headerStack.addArrangedSubview(clipsHeaderLabel)
        headerStack.addArrangedSubview(clipsBodyPlaceholderView)

        headerContainer.addSubview(headerStack)

        view.addSubview(clipsTableView)
        view.addSubview(clipsFailureBanner)

        NSLayoutConstraint.activate([
            recordButton.topAnchor.constraint(equalTo: recordButtonRow.topAnchor),
            recordButton.bottomAnchor.constraint(equalTo: recordButtonRow.bottomAnchor),
            recordButton.centerXAnchor.constraint(equalTo: recordButtonRow.centerXAnchor),
            recordButton.leadingAnchor.constraint(greaterThanOrEqualTo: recordButtonRow.leadingAnchor),
            recordButton.trailingAnchor.constraint(lessThanOrEqualTo: recordButtonRow.trailingAnchor),

            incidentButton.topAnchor.constraint(equalTo: incidentButtonRow.topAnchor),
            incidentButton.bottomAnchor.constraint(equalTo: incidentButtonRow.bottomAnchor),
            incidentButton.centerXAnchor.constraint(equalTo: incidentButtonRow.centerXAnchor),
            incidentButton.leadingAnchor.constraint(greaterThanOrEqualTo: incidentButtonRow.leadingAnchor),
            incidentButton.trailingAnchor.constraint(lessThanOrEqualTo: incidentButtonRow.trailingAnchor),

            headerStack.leadingAnchor.constraint(equalTo: headerContainer.layoutMarginsGuide.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: headerContainer.layoutMarginsGuide.trailingAnchor),
            headerStack.topAnchor.constraint(equalTo: headerContainer.layoutMarginsGuide.topAnchor),
            headerStack.bottomAnchor.constraint(equalTo: headerContainer.layoutMarginsGuide.bottomAnchor),

            clipsTableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            clipsTableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            clipsTableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            clipsTableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            clipsFailureBanner.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            clipsFailureBanner.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            clipsFailureBanner.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            previewViewController.view.heightAnchor.constraint(
                equalTo: previewViewController.view.widthAnchor,
                multiplier: 0.75
            ),
        ])
    }

    private func configureFailureBanner() {
        clipsFailureBanner.configure(
            caption: "",
            dotColor: .systemRed,
            backgroundStyle: .tinted(UIColor.systemRed.withAlphaComponent(0.16))
        )
        clipsFailureBanner.isHidden = true
        clipsFailureBanner.translatesAutoresizingMaskIntoConstraints = false
    }

    private func installOrSizeHeaderIfPossible() {
        let fittingWidth = clipsTableView.bounds.width
        guard fittingWidth > 0, clipsTableView.window != nil else {
            needsHeaderRefit = true
            return
        }

        let isHeaderInstalled = clipsTableView.tableHeaderView === headerContainer
        if isHeaderInstalled,
           let lastFittedHeaderWidth,
           abs(lastFittedHeaderWidth - fittingWidth) <= 0.5,
           needsHeaderRefit == false {
            return
        }

        headerContainer.frame.size.width = fittingWidth
        let fittingSize = headerContainer.systemLayoutSizeFitting(
            CGSize(width: fittingWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        lastFittedHeaderWidth = fittingWidth
        needsHeaderRefit = false

        let shouldInstallOrUpdate = isHeaderInstalled == false ||
            abs(headerContainer.frame.height - fittingSize.height) > 0.5
        guard shouldInstallOrUpdate else { return }

        var frame = headerContainer.frame
        frame.size.width = fittingWidth
        frame.size.height = fittingSize.height
        headerContainer.frame = frame
        clipsTableView.tableHeaderView = headerContainer
    }

    private func updateClipsBottomInset() {
        let bottomInset = clipsFailureBanner.isHidden ? 0 : clipsFailureBanner.bounds.height

        if abs(clipsTableView.contentInset.bottom - bottomInset) > 0.5 {
            var contentInset = clipsTableView.contentInset
            contentInset.bottom = bottomInset
            clipsTableView.contentInset = contentInset
        }

        if abs(clipsTableView.verticalScrollIndicatorInsets.bottom - bottomInset) > 0.5 {
            var indicatorInsets = clipsTableView.verticalScrollIndicatorInsets
            indicatorInsets.bottom = bottomInset
            clipsTableView.verticalScrollIndicatorInsets = indicatorInsets
        }
    }

    private func configurePreview() {
        previewViewController.view.layer.cornerRadius = 16
        previewViewController.view.layer.cornerCurve = .continuous
        previewViewController.view.layer.masksToBounds = true
        previewViewController.view.translatesAutoresizingMaskIntoConstraints = false
    }

    private func configureStatusPills() {
        statusPillsStack.axis = .vertical
        statusPillsStack.alignment = .leading
        statusPillsStack.spacing = 8
        statusPillsStack.isHidden = true
        statusPillsStack.addArrangedSubview(tempWarningPill)
        statusPillsStack.addArrangedSubview(errorPill)
        statusPillsStack.addArrangedSubview(timeUnverifiedPill)

        tempWarningPill.isHidden = true
        errorPill.isHidden = true
        timeUnverifiedPill.isHidden = true
    }

    private func configureClipsTable() {
        clipsHeaderLabel.text = "Recent clips"
        clipsHeaderLabel.font = .preferredFont(forTextStyle: .headline)
        clipsHeaderLabel.adjustsFontForContentSizeCategory = true

        emptyClipsImageView.tintColor = .secondaryLabel
        emptyClipsImageView.contentMode = .scaleAspectFit

        emptyClipsLabel.text = "No clips yet"
        emptyClipsLabel.font = .preferredFont(forTextStyle: .subheadline)
        emptyClipsLabel.adjustsFontForContentSizeCategory = true
        emptyClipsLabel.numberOfLines = 0
        emptyClipsLabel.textAlignment = .center
        emptyClipsLabel.textColor = .secondaryLabel

        emptyClipsView.axis = .vertical
        emptyClipsView.alignment = .center
        emptyClipsView.spacing = 8
        emptyClipsView.translatesAutoresizingMaskIntoConstraints = false
        emptyClipsView.addArrangedSubview(emptyClipsImageView)
        emptyClipsView.addArrangedSubview(emptyClipsLabel)

        clipsLoadingIndicator.hidesWhenStopped = true

        clipsBodyPlaceholderView.axis = .vertical
        clipsBodyPlaceholderView.alignment = .center
        clipsBodyPlaceholderView.spacing = 8
        clipsBodyPlaceholderView.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 4,
            leading: 0,
            bottom: 8,
            trailing: 0
        )
        clipsBodyPlaceholderView.isLayoutMarginsRelativeArrangement = true
        clipsBodyPlaceholderView.isHidden = true
        clipsBodyPlaceholderView.addArrangedSubview(clipsLoadingIndicator)
        clipsBodyPlaceholderView.addArrangedSubview(emptyClipsView)
        emptyClipsView.isHidden = true

        clipsTableView.delegate = self
        clipsTableView.prefetchDataSource = self
        clipsTableView.register(
            HomeDayHeaderView.self,
            forHeaderFooterViewReuseIdentifier: HomeDayHeaderView.reuseIdentifier
        )
        clipsTableView.register(ClipThumbnailCell.self, forCellReuseIdentifier: "clipThumbnail")
        dataSource = UITableViewDiffableDataSource<HomeSection, HomeRowID>(
            tableView: clipsTableView
        ) { [weak self] tableView, indexPath, id in
            guard let self, let row = self.rowsByID[id] else {
                return UITableViewCell(style: .default, reuseIdentifier: nil)
            }

            switch row {
            case .finished(let clip):
                guard let cell = tableView.dequeueReusableCell(
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

            case .recording(let recording):
                guard let cell = tableView.dequeueReusableCell(
                    withIdentifier: "clipThumbnail",
                    for: indexPath
                ) as? ClipThumbnailCell else {
                    return UITableViewCell(style: .default, reuseIdentifier: nil)
                }
                cell.configure(
                    recording: recording,
                    loader: self.dependencies.thumbnailLoader,
                    preservedThumbnail: recording.representative
                        .map(ClipThumbnailIdentity.init)
                        .flatMap { self.preservedVisibleThumbnails[$0] }
                )
                return cell
            }
        }
        clipsTableView.rowHeight = UITableView.automaticDimension
        clipsTableView.estimatedRowHeight = 72
        clipsTableView.sectionHeaderTopPadding = 0
        clipsTableView.sectionHeaderHeight = UITableView.automaticDimension
        clipsTableView.estimatedSectionHeaderHeight = 32
        clipsTableView.tableFooterView = UIView()
        clipsTableView.alwaysBounceVertical = true
        refreshControl.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        clipsTableView.refreshControl = refreshControl
        clipsTableView.translatesAutoresizingMaskIntoConstraints = false
    }

    private func renderStatusPills(_ pills: HomeStatusPills) {
        if let warning = pills.tempWarning {
            let color: UIColor = warning.isCritical ? .systemRed : .systemOrange
            tempWarningPill.configure(
                caption: warning.caption,
                dotColor: color,
                backgroundStyle: .tinted(color.withAlphaComponent(0.16))
            )
            tempWarningPill.isHidden = false
        } else {
            tempWarningPill.isHidden = true
        }

        if pills.cameraOffline {
            errorPill.configure(
                caption: "Camera offline",
                dotColor: .systemRed,
                backgroundStyle: .tinted(UIColor.systemRed.withAlphaComponent(0.16))
            )
            errorPill.isHidden = false
        } else {
            errorPill.isHidden = true
        }

        if pills.timeUnverified {
            timeUnverifiedPill.configure(
                caption: "Time unverified",
                dotColor: .systemOrange,
                backgroundStyle: .tinted(UIColor.systemOrange.withAlphaComponent(0.16))
            )
            timeUnverifiedPill.isHidden = false
        } else {
            timeUnverifiedPill.isHidden = true
        }

        statusPillsStack.isHidden = tempWarningPill.isHidden
            && errorPill.isHidden
            && timeUnverifiedPill.isHidden
        needsHeaderRefit = true
        view.setNeedsLayout()
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
        liveRecordingStatus = status
        recordingAttribution = RecordingAttribution.from(
            status: status,
            worldBootTag: inputs.worldBootTag,
            recorder: inputs.recorder
        )
        liveRecordingWidget.configure(status: status, now: now)

        let shouldHide = status == .none
        if liveRecordingWidget.isHidden != shouldHide {
            liveRecordingWidget.isHidden = shouldHide
            needsHeaderRefit = true
        }

        recordButton.apply(inputs.recording)
        view.setNeedsLayout()
    }

    private func renderClips(_ clips: [Clip]) {
        finishedClips = clips
        renderRows()
    }

    private func renderRows(completion: (() -> Void)? = nil) {
        let visibleThumbnails = visibleThumbnailImages()
        let newSections = HomeRow.composeSections(
            clips: finishedClips,
            recordingAttribution: recordingAttribution,
            today: wallNow(),
            calendar: currentCalendar()
        )
        let newRows = newSections.flatMap(\.rows)
        let reconfigure = HomeRowDiff.reconfiguredIDs(old: rows, new: newRows)

        sections = newSections
        rows = newRows
        rowsByID = Dictionary(uniqueKeysWithValues: newRows.map { ($0.id, $0) })
        paginationTailIDs = Set(newRows.suffix(paginationThreshold).map(\.id))
        prunePrefetches(surviving: Set(newRows.compactMap(\.thumbnailIdentity)))
        preservedThumbnailGeneration += 1
        let thumbnailGeneration = preservedThumbnailGeneration
        preservedVisibleThumbnails = visibleThumbnails

        var snapshot = NSDiffableDataSourceSnapshot<HomeSection, HomeRowID>()
        snapshot.appendSections(newSections.map(\.id))
        for section in newSections {
            snapshot.appendItems(section.rows.map(\.id), toSection: section.id)
        }
        snapshot.reconfigureItems(reconfigure)
        snapshotGate.submit(
            snapshot,
            completion: { [weak self] in
                MainActor.assumeIsolated {
                    if self?.preservedThumbnailGeneration == thumbnailGeneration {
                        self?.preservedVisibleThumbnails.removeAll()
                    }
                    self?.loadMoreIfVisibleTail()
                    completion?()
                }
            }
        )

        updateClipsPresentation()
    }

    private func handleClipsStatus(_ status: ClipsFeature.State.Status) {
        switch status {
        case .loading:
            break
        case .idle, .failed:
            if isManualRefreshing {
                refreshControl.endRefreshing()
                isManualRefreshing = false
            }
        }

        clipsStatus = status
        updateClipsPresentation()
    }

    private func updateClipsPresentation() {
        let placeholder: ClipsBodyPlaceholderPresentation

        switch clipsStatus {
        case .failed(let error):
            clipsFailureBanner.configure(
                caption: error.displayMessage,
                dotColor: .systemRed,
                backgroundStyle: .tinted(UIColor.systemRed.withAlphaComponent(0.16))
            )
            clipsFailureBanner.isHidden = false
            placeholder = .hidden
        case .idle, .loading:
            clipsFailureBanner.isHidden = true
            if rows.isEmpty == false {
                placeholder = .hidden
            } else if clipsHasLoadedOnce {
                placeholder = .empty
            } else if clipsStatus == .loading {
                placeholder = .loading
            } else {
                placeholder = .hidden
            }
        }

        applyClipsBodyPlaceholder(placeholder)
        view.setNeedsLayout()
    }

    private enum ClipsBodyPlaceholderPresentation {
        case hidden
        case loading
        case empty
    }

    private func applyClipsBodyPlaceholder(_ presentation: ClipsBodyPlaceholderPresentation) {
        let wasHidden = clipsBodyPlaceholderView.isHidden
        let wasShowingLoading = clipsLoadingIndicator.isAnimating
        let wasShowingEmpty = emptyClipsView.isHidden == false

        switch presentation {
        case .hidden:
            clipsBodyPlaceholderView.isHidden = true
            clipsLoadingIndicator.stopAnimating()
            emptyClipsView.isHidden = true
        case .loading:
            clipsBodyPlaceholderView.isHidden = false
            emptyClipsView.isHidden = true
            clipsLoadingIndicator.startAnimating()
        case .empty:
            clipsBodyPlaceholderView.isHidden = false
            clipsLoadingIndicator.stopAnimating()
            emptyClipsView.isHidden = false
        }

        if wasHidden != clipsBodyPlaceholderView.isHidden ||
            wasShowingLoading != clipsLoadingIndicator.isAnimating ||
            wasShowingEmpty != (emptyClipsView.isHidden == false) {
            needsHeaderRefit = true
        }
    }

    private func observeDayRolloverNotifications() {
        calendarDayChangedObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDayRollover()
            }
        }
        significantTimeChangedObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.significantTimeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDayRollover()
            }
        }
    }

    private func handleDayRollover() {
        renderRows { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshVisibleDayHeaders()
            }
        }
    }

    private func refreshVisibleDayHeaders() {
        guard isActiveAndAttached else { return }
        for sectionIndex in 0..<sections.count {
            guard let headerView = clipsTableView.headerView(forSection: sectionIndex) as? HomeDayHeaderView,
                  let section = dataSource.sectionIdentifier(for: sectionIndex) else {
                continue
            }
            headerView.configure(title: headerTitle(for: section))
        }
    }

    private func headerTitle(for section: HomeSection) -> String {
        switch section {
        case .day(let startOfDay, _):
            Formatters.dayHeader(startOfDay, now: wallNow(), calendar: currentCalendar())
        case .dateUnknown:
            "Date unknown"
        }
    }

    @objc private func recordTapped() {
        store.send(.recordTapped)
    }

    @objc private func incidentTapped() {
        guard incidentButton.isEnabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        store.send(.incidents(.pressTapped))
    }

    private func presentIncidentPersistenceAlert() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "Could not save incident",
            message: "DanCam could not make room for this incident. Check available phone storage and try again.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.store.send(.incidents(.persistenceAlertDismissed))
        })
        present(alert, animated: true)
    }

    @objc private func refreshPulled() {
        isManualRefreshing = true
        store.send(.manualRefresh)
        previewViewController.reconnectIfNeeded()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let row = row(at: indexPath) else { return }

        switch row {
        case .finished(let clip):
            tableView.deselectRow(at: indexPath, animated: true)
            navigationController?.pushViewController(
                ClipViewerViewController(dependencies: dependencies, store: store, clip: clip),
                animated: true
            )
        case .recording(let recording):
            tableView.deselectRow(at: indexPath, animated: true)
            navigationController?.pushViewController(
                RecordingDetailViewController(
                    dependencies: dependencies,
                    store: store,
                    recordingID: recording.recordingID,
                    initialLiveSegment: liveRecordingStatus.liveSegment
                ),
                animated: true
            )
        }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let row = row(at: indexPath),
              case .finished(let clip) = row else {
            return nil
        }

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
        guard isActiveAndAttached,
              let row = row(at: indexPath),
              paginationTailIDs.contains(row.id),
              clipsNextCursor != nil else {
            return
        }

        store.send(.clips(.loadMore))
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let sectionID = dataSource.sectionIdentifier(for: section),
              let headerView = tableView.dequeueReusableHeaderFooterView(
                  withIdentifier: HomeDayHeaderView.reuseIdentifier
              ) as? HomeDayHeaderView else {
            return nil
        }

        headerView.configure(title: headerTitle(for: sectionID))
        return headerView
    }

    func tableView(
        _ tableView: UITableView,
        didEndDisplaying cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {
        // `prepareForReuse` fires only on re-dequeue, so a row scrolled offscreen but not yet
        // reused would keep its load (and strong token) live. Quiet it now: a still-queued
        // entry is dropped, a scroll-back re-requests it cache-first.
        (cell as? ClipThumbnailCell)?.cancelLoad()
    }

    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let row = row(at: indexPath),
                  let clip = row.thumbnailClip else {
                continue
            }
            let identity = ClipThumbnailIdentity(clip)
            // Cancel-before-replace: a `PrefetchHandle` is a value type with no `deinit`, so
            // overwriting a slot without cancelling would orphan the prior handle's token and
            // keep pinning its loader entry.
            prefetchHandles[identity]?.cancel()
            prefetchHandles[identity] = dependencies.thumbnailLoader.prefetch(clip)
        }
    }

    func tableView(_ tableView: UITableView, cancelPrefetchingForRowsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let row = row(at: indexPath),
                  let identity = row.thumbnailIdentity else {
                continue
            }
            prefetchHandles.removeValue(forKey: identity)?.cancel()
        }
    }

    private func row(at indexPath: IndexPath) -> HomeRow? {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].rows.indices.contains(indexPath.row) else {
            return nil
        }
        return sections[indexPath.section].rows[indexPath.row]
    }

    private func performDelete(_ clip: Clip) {
        store.send(.clips(.deleteTapped(clip)))
    }

    func performDeleteForTesting(clipID: Int) {
        guard let clip = finishedClips.first(where: { $0.id == clipID }) else { return }
        performDelete(clip)
    }

    private func prunePrefetches(surviving identities: Set<ClipThumbnailIdentity>) {
        let staleIdentities = prefetchHandles.keys.filter { identities.contains($0) == false }
        for identity in staleIdentities {
            prefetchHandles.removeValue(forKey: identity)?.cancel()
        }
    }

    private func loadMoreIfVisibleTail() {
        guard isActiveAndAttached,
              clipsNextCursor != nil,
              let visibleRows = clipsTableView.indexPathsForVisibleRows else {
            return
        }

        for indexPath in visibleRows {
            guard let id = dataSource.itemIdentifier(for: indexPath),
                  paginationTailIDs.contains(id) else {
                continue
            }

            store.send(.clips(.loadMore))
            return
        }
    }

    private func cancelAllPrefetches() {
        for handle in prefetchHandles.values {
            handle.cancel()
        }
        prefetchHandles.removeAll()
    }

    private func quietVisibleThumbnailLoads() {
        guard clipsTableView.window != nil else { return }
        for cell in clipsTableView.visibleCells {
            (cell as? ClipThumbnailCell)?.cancelLoad()
        }
    }

    private func visibleThumbnailImages() -> [ClipThumbnailIdentity: UIImage] {
        guard isActiveAndAttached,
              let visibleRows = clipsTableView.indexPathsForVisibleRows else { return [:] }

        var images: [ClipThumbnailIdentity: UIImage] = [:]
        for indexPath in visibleRows {
            guard let row = row(at: indexPath),
                  let identity = row.thumbnailIdentity,
                  let cell = clipsTableView.cellForRow(at: indexPath) as? ClipThumbnailCell,
                  let image = cell.currentThumbnailImage else {
                continue
            }
            images[identity] = image
        }
        return images
    }

    /// Re-request visible rows on return by reconfiguring the visible `ClipThumbnailCell`s
    /// in place. Diffable snapshots do not reload on appear, so a painted cell hits the
    /// same-identity no-op and a cell quieted on the way out retries once, cache-first.
    private func reconfigureVisibleThumbnails() {
        guard isActiveAndAttached,
              let visibleRows = clipsTableView.indexPathsForVisibleRows else { return }
        for indexPath in visibleRows {
            guard let row = row(at: indexPath),
                  let cell = clipsTableView.cellForRow(at: indexPath) as? ClipThumbnailCell else {
                continue
            }

            switch row {
            case .finished(let clip):
                cell.configure(clip: clip, loader: dependencies.thumbnailLoader)
            case .recording(let recording):
                cell.configure(recording: recording, loader: dependencies.thumbnailLoader)
            }
        }
    }

    private var isActiveAndAttached: Bool {
        isViewActive && view.window != nil && clipsTableView.window != nil
    }

    func clipThumbnailCellForTesting(clipID: Int) -> ClipThumbnailCell? {
        guard let indexPath = dataSource.indexPath(for: .finished(clipID)) else { return nil }
        return clipsTableView.cellForRow(at: indexPath) as? ClipThumbnailCell
    }

    func recordingThumbnailCellForTesting(recording: RecordingID, occurrence: Int = 0) -> ClipThumbnailCell? {
        guard let indexPath = dataSource.indexPath(
            for: .recording(recording: recording, occurrence: occurrence)
        ) else {
            return nil
        }
        return clipsTableView.cellForRow(at: indexPath) as? ClipThumbnailCell
    }

    var sectionHeaderTitlesForTesting: [String] {
        sections.map { headerTitle(for: $0.id) }
    }

    func dayHeaderViewForTesting(section: Int) -> HomeDayHeaderView? {
        clipsTableView.headerView(forSection: section) as? HomeDayHeaderView
    }

    func indexPathForTesting(rowID: HomeRowID) -> IndexPath? {
        for (sectionIndex, section) in sections.enumerated() {
            if let rowIndex = section.rows.firstIndex(where: { $0.id == rowID }) {
                return IndexPath(row: rowIndex, section: sectionIndex)
            }
        }
        return nil
    }

    var rowIDsForTesting: [HomeRowID] {
        rows.map(\.id)
    }

    var presentedRowIDsForTesting: [HomeRowID] {
        dataSource.snapshot().itemIdentifiers
    }

    func layoutClipsTableForTesting() {
        clipsTableView.layoutIfNeeded()
    }

    var liveRecordingWidgetForTesting: LiveRecordingStatusView {
        liveRecordingWidget
    }

    var isShowingPendingWidgetForTesting: Bool {
        liveRecordingStatus == .pending && liveRecordingWidget.isHidden == false
    }

    var recordButtonForTesting: RecordButton {
        recordButton
    }

    var incidentButtonForTesting: IncidentButton {
        incidentButton
    }

    var isLiveRecordingWidgetTickTimerRunningForTesting: Bool {
        liveRecordingWidget.isTickTimerRunningForTesting
    }

    var isTimeUnverifiedPillVisibleForTesting: Bool {
        timeUnverifiedPill.isHidden == false
    }

    var isRefreshingForTesting: Bool {
        refreshControl.isRefreshing
    }

    var isManualRefreshingForTesting: Bool {
        isManualRefreshing
    }

    var clipsFailureMessageForTesting: String? {
        clipsFailureBanner.isHidden ? nil : clipsFailureBanner.accessibilityLabel
    }

    var isShowingEmptyStateForTesting: Bool {
        clipsBodyPlaceholderView.isHidden == false &&
            emptyClipsView.isHidden == false &&
            emptyClipsLabel.isHidden == false
    }

    var isShowingLoadingStateForTesting: Bool {
        clipsBodyPlaceholderView.isHidden == false && clipsLoadingIndicator.isAnimating
    }

    var isTableHeaderInstalledForTesting: Bool {
        clipsTableView.tableHeaderView === headerContainer
    }

    func pullToRefreshForTesting() {
        refreshControl.beginRefreshing()
        refreshPulled()
    }

    func tickLiveRecordingWidgetForTesting(now: ContinuousClock.Instant? = nil) {
        liveRecordingWidget.tickForTesting(now: now)
    }
}
