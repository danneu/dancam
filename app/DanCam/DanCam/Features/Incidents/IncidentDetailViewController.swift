import AVKit
import UIKit

nonisolated struct IncidentArtifactRow: Equatable, Sendable, Identifiable {
    var seq: Int
    var durationMs: UInt64?
    var bytes: UInt64
    var kind: IncidentArtifactKind
    var url: URL
    var isPlayable: Bool

    var id: Int { seq }
}

nonisolated enum IncidentSegmentRowPresentation: Equatable, Sendable {
    case waiting
    case artifact(IncidentArtifactRow)
}

nonisolated struct IncidentSegmentRow: Equatable, Sendable, Identifiable {
    var seq: Int
    var presentation: IncidentSegmentRowPresentation

    var id: Int { seq }

    var artifact: IncidentArtifactRow? {
        guard case let .artifact(artifact) = presentation else { return nil }
        return artifact
    }

    var isWaiting: Bool {
        if case .waiting = presentation { return true }
        return false
    }
}

typealias IncidentTimelineBuild = @Sendable (
    _ segments: [IncidentSegment],
    _ directoryURL: URL
) async -> sending IncidentPlaybackTimeline

@MainActor
final class IncidentDetailViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let dependencies: AppDependencies
    private let store: AppStore
    private let incidentID: UUID
    private let sharePresentation: VideoSharePresentation?
    private let timelineBuild: IncidentTimelineBuild

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let headerView = UIView()
    private let playerContainer = UIView()
    private let placeholderLabel = UILabel()
    private let progressLabel = UILabel()
    private let gapLabel = UILabel()
    private let jumpToPressButton = UIButton(type: .system)
    private let shareButton = UIBarButtonItem()
    private let deleteButton = UIBarButtonItem()
    private let player = AVPlayer()
    private let playerViewController = AVPlayerViewController()

    private var observation: StoreObservation?
    private var currentItemStatusObservation: NSKeyValueObservation?
    private var timelineBuildTask: Task<Void, Never>?
    private var buildGeneration = 0
    private var record: IncidentRecord?
    private var rows: [IncidentSegmentRow] = []
    private var selectedRow: IncidentArtifactRow?
    private var timeline: IncidentPlaybackTimeline?
    private var selfHealAttemptedIdentity: [IncidentPlaybackIdentity]?
    private var selfHealPendingIdentity: [IncidentPlaybackIdentity]?
    private var terminalFailureIdentity: [IncidentPlaybackIdentity]?
    private var isPresentingFullScreen = false
    private var shareCoordinator: VideoShareCoordinator?

    var exportTimeZone = TimeZone.current

    init(
        dependencies: AppDependencies,
        store: AppStore,
        incidentID: UUID,
        sharePresentation: VideoSharePresentation? = nil,
        timelineBuild: @escaping IncidentTimelineBuild = { segments, directoryURL in
            await IncidentPlaybackTimelineBuilder.build(segments: segments, directoryURL: directoryURL)
        }
    ) {
        self.dependencies = dependencies
        self.store = store
        self.incidentID = incidentID
        self.sharePresentation = sharePresentation
        self.timelineBuild = timelineBuild
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("IncidentDetailViewController is programmatic.") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        configureNavigation()
        configureTable()
        configurePlayer()
        configureShareCoordinator()
        let incidentID = incidentID
        observation = store.observe(select: { $0.incidents.incidents.first(where: { $0.id == incidentID }) }) {
            [weak self] record in
            self?.render(record)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeTableHeader()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil, isViewLoaded {
            tearDown()
        }
    }

    isolated deinit {
        tearDown()
    }

    private func configureNavigation() {
        shareButton.image = UIImage(systemName: "square.and.arrow.up")
        shareButton.target = self
        shareButton.action = #selector(shareTapped)
        shareButton.accessibilityLabel = "Share segment"
        shareButton.isEnabled = false
        deleteButton.image = UIImage(systemName: "trash")
        deleteButton.style = .plain
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.tintColor = .systemRed
        deleteButton.accessibilityLabel = "Delete incident"
        navigationItem.rightBarButtonItems = [shareButton, deleteButton]
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false

        playerContainer.backgroundColor = .black
        playerContainer.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.textColor = .white
        placeholderLabel.font = .preferredFont(forTextStyle: .headline)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textAlignment = .center
        placeholderLabel.numberOfLines = 0
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        progressLabel.font = .preferredFont(forTextStyle: .subheadline)
        progressLabel.adjustsFontForContentSizeCategory = true
        progressLabel.numberOfLines = 0

        gapLabel.font = .preferredFont(forTextStyle: .footnote)
        gapLabel.adjustsFontForContentSizeCategory = true
        gapLabel.textColor = .secondaryLabel
        gapLabel.numberOfLines = 0

        jumpToPressButton.configuration = .bordered()
        jumpToPressButton.configuration?.title = "Jump to press"
        jumpToPressButton.configuration?.image = UIImage(systemName: "scope")
        jumpToPressButton.configuration?.imagePadding = 6
        jumpToPressButton.accessibilityLabel = "Jump to incident press"
        jumpToPressButton.isEnabled = false
        jumpToPressButton.addTarget(self, action: #selector(jumpToPressTapped), for: .touchUpInside)

        let chromeStack = UIStackView(arrangedSubviews: [progressLabel, gapLabel, jumpToPressButton])
        chromeStack.axis = .vertical
        chromeStack.alignment = .fill
        chromeStack.spacing = 8
        chromeStack.isLayoutMarginsRelativeArrangement = true
        chromeStack.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        chromeStack.translatesAutoresizingMaskIntoConstraints = false

        headerView.addSubview(playerContainer)
        headerView.addSubview(chromeStack)
        NSLayoutConstraint.activate([
            playerContainer.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            playerContainer.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            playerContainer.topAnchor.constraint(equalTo: headerView.topAnchor),
            playerContainer.heightAnchor.constraint(equalToConstant: 240),
            chromeStack.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            chromeStack.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            chromeStack.topAnchor.constraint(equalTo: playerContainer.bottomAnchor),
            chromeStack.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
        ])
        tableView.tableHeaderView = headerView

        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configurePlayer() {
        playerViewController.player = player
        playerViewController.delegate = self
        playerViewController.allowsVideoFrameAnalysis = false
        playerViewController.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(playerViewController)
        playerContainer.addSubview(playerViewController.view)
        playerContainer.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            playerViewController.view.leadingAnchor.constraint(equalTo: playerContainer.leadingAnchor),
            playerViewController.view.trailingAnchor.constraint(equalTo: playerContainer.trailingAnchor),
            playerViewController.view.topAnchor.constraint(equalTo: playerContainer.topAnchor),
            playerViewController.view.bottomAnchor.constraint(equalTo: playerContainer.bottomAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: playerContainer.leadingAnchor, constant: 24),
            placeholderLabel.trailingAnchor.constraint(equalTo: playerContainer.trailingAnchor, constant: -24),
            placeholderLabel.centerYAnchor.constraint(equalTo: playerContainer.centerYAnchor),
        ])
        playerViewController.didMove(toParent: self)
    }

    private func sizeTableHeader() {
        let width = tableView.bounds.width
        guard width > 0 else { return }
        headerView.frame.size.width = width
        let height = headerView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        guard abs(headerView.frame.height - height) > 0.5 else { return }
        headerView.frame.size.height = height
        tableView.tableHeaderView = headerView
    }

    private func configureShareCoordinator() {
        shareCoordinator = VideoShareCoordinator(
            preparer: dependencies.shareArtifactPreparer,
            presenter: self,
            shareButton: shareButton,
            presentation: sharePresentation,
            preparingChanged: { [weak self] preparing in
                self?.setSharePreparationControls(preparing: preparing)
            },
            sourceUnavailable: { [weak self] in
                self?.handleShareSourceUnavailable()
            }
        )
    }

    private func render(_ record: IncidentRecord?) {
        guard let record else {
            self.record = nil
            shareCoordinator?.cancel()
            selectedRow = nil
            tearDownPlayback(dismissFullScreen: true)
            navigationController?.popViewController(animated: true)
            return
        }

        self.record = record
        navigationItem.title = Formatters.incidentPressedAt(
            Date(timeIntervalSince1970: Double(record.pressedAtMs) / 1_000)
        )
        rows = segmentRows(record: record)
        reconcileSelection()
        renderPendingProgress(record: record)
        tableView.reloadData()
        sizeTableHeader()
        startTimelineBuild(record: record, forceReplacement: false)
    }

    private func segmentRows(record: IncidentRecord) -> [IncidentSegmentRow] {
        let directory = dependencies.incidentStore.directoryURL(record.id)
        return record.wanted.sorted(by: { $0.seq < $1.seq }).compactMap { segment in
            if segment.state == .unresolved || segment.state == .wanted {
                return IncidentSegmentRow(seq: segment.seq, presentation: .waiting)
            }
            guard segment.state == .pulled else { return nil }
            let stem = String(format: "seg_%05d", segment.seq)
            for kind in [IncidentArtifactKind.mp4, .ts] {
                let url = directory.appending(path: "\(stem).\(kind.rawValue)")
                if FileManager.default.fileExists(atPath: url.path) {
                    return IncidentSegmentRow(
                        seq: segment.seq,
                        presentation: .artifact(IncidentArtifactRow(
                            seq: segment.seq,
                            durationMs: segment.durMs,
                            bytes: segment.bytes ?? 0,
                            kind: kind,
                            url: url,
                            isPlayable: false
                        ))
                    )
                }
            }
            return nil
        }
    }

    private func reconcileSelection() {
        guard let selected = selectedRow else { return }
        guard let retained = rows.compactMap(\.artifact).first(where: { $0.url == selected.url }) else {
            shareCoordinator?.cancel()
            selectedRow = nil
            shareButton.isEnabled = false
            return
        }
        selectedRow = retained
    }

    private func startTimelineBuild(record: IncidentRecord, forceReplacement: Bool) {
        let forceReplacement = forceReplacement
            || (selfHealPendingIdentity != nil && selfHealPendingIdentity == timeline?.identity)
        buildGeneration += 1
        let generation = buildGeneration
        timelineBuildTask?.cancel()
        let directoryURL = dependencies.incidentStore.directoryURL(record.id)
        let timelineBuild = timelineBuild
        timelineBuildTask = Task { [weak self] in
            let result = await timelineBuild(record.wanted, directoryURL)
            guard let self, generation == self.buildGeneration, self.record?.id == record.id else { return }
            await self.applyTimeline(
                result,
                record: record,
                generation: generation,
                forceReplacement: forceReplacement
            )
        }
    }

    private func applyTimeline(
        _ result: consuming IncidentPlaybackTimeline,
        record: IncidentRecord,
        generation: Int,
        forceReplacement: Bool
    ) async {
        guard generation == buildGeneration, self.record == record else { return }
        timelineBuildTask = nil
        let playableSeqs = Set(result.segments.map(\.seq))
        rows = rows.map { row in
            guard var artifact = row.artifact else { return row }
            artifact.isPlayable = artifact.kind == .mp4 && playableSeqs.contains(artifact.seq)
            return IncidentSegmentRow(seq: row.seq, presentation: .artifact(artifact))
        }
        if let selected = selectedRow,
           let retained = rows.compactMap(\.artifact).first(where: { $0.url == selected.url }) {
            selectedRow = retained
        }
        renderTimelineChrome(result: result, record: record)
        tableView.reloadData()
        sizeTableHeader()

        let oldIdentity = timeline?.identity ?? []
        let newIdentity = result.identity
        if oldIdentity == newIdentity, forceReplacement == false {
            return
        }

        let anchor = timeline?.anchor(at: player.currentTime())
        let wasPlaying = player.rate != 0
        let shouldAutoplay = timeline?.segments.isEmpty ?? true
        let restoreTime = result.restorationTime(for: anchor)

        if newIdentity.isEmpty {
            currentItemStatusObservation?.invalidate()
            currentItemStatusObservation = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
            timeline = result
            selfHealAttemptedIdentity = nil
            selfHealPendingIdentity = nil
            terminalFailureIdentity = nil
            return
        }

        let item = AVPlayerItem(asset: result.composition)
        await item.seek(to: restoreTime, toleranceBefore: .zero, toleranceAfter: .zero)
        guard generation == buildGeneration, self.record == record else { return }

        if oldIdentity != newIdentity {
            selfHealAttemptedIdentity = nil
            selfHealPendingIdentity = nil
            terminalFailureIdentity = nil
        }
        observePlayerItem(item)
        player.replaceCurrentItem(with: item)
        timeline = result
        if selfHealPendingIdentity == newIdentity {
            selfHealPendingIdentity = nil
        }
        placeholderLabel.isHidden = true
        if wasPlaying || shouldAutoplay {
            player.play()
        }
    }

    private func renderPendingProgress(record: IncidentRecord) {
        let pulled = record.wanted.filter { $0.state == .pulled }.count
        progressLabel.text = record.status == .pending
            ? "Saving \(pulled) of \(record.wanted.count) segments"
            : "\(pulled) of \(record.wanted.count) segments saved"
        if record.status == .pending, gapLabel.text == "All saved segments are playable." {
            setGapText(nil)
        }
        if timeline == nil || timeline?.segments.isEmpty == true {
            placeholderLabel.text = record.status == .pending
                ? "Saving incident video..."
                : "No playable video is available."
            placeholderLabel.isHidden = false
        }
    }

    private func renderTimelineChrome(result: IncidentPlaybackTimeline, record: IncidentRecord) {
        let missing = result.gaps.filter { $0.reason == .missing }.map(\.seq)
        let unavailable = result.gaps.filter { $0.reason == .unavailable }.map(\.seq)
        var lines: [String] = []
        if missing.isEmpty == false { lines.append("Missing: \(sequenceList(missing))") }
        if unavailable.isEmpty == false { lines.append("Unavailable for playback: \(sequenceList(unavailable))") }
        let gapText = if lines.isEmpty {
            record.status == .pending ? nil : "All saved segments are playable."
        } else {
            lines.joined(separator: "\n")
        }
        setGapText(gapText)
        jumpToPressButton.isEnabled = result.segments.isEmpty == false

        if result.segments.isEmpty {
            placeholderLabel.text = record.status == .pending
                ? "Saving incident video..."
                : "No playable video is available."
            placeholderLabel.isHidden = false
        } else if terminalFailureIdentity == result.identity {
            placeholderLabel.text = "Playback failed. Segment sharing and deletion are still available."
            placeholderLabel.isHidden = false
        } else {
            placeholderLabel.isHidden = true
        }
    }

    private func sequenceList(_ seqs: [Int]) -> String {
        seqs.map(String.init).joined(separator: ", ")
    }

    private func setGapText(_ text: String?) {
        gapLabel.text = text
        gapLabel.isHidden = text == nil
    }

    private func observePlayerItem(_ item: AVPlayerItem) {
        currentItemStatusObservation?.invalidate()
        currentItemStatusObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] observed, _ in
            guard observed.status == .failed else { return }
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                self.handlePlayerItemFailed()
            }
        }
    }

    private func handlePlayerItemFailed() {
        guard let record, let identity = timeline?.identity, identity.isEmpty == false else { return }
        if selfHealAttemptedIdentity != identity {
            selfHealAttemptedIdentity = identity
            selfHealPendingIdentity = identity
            startTimelineBuild(record: record, forceReplacement: true)
            return
        }

        terminalFailureIdentity = identity
        player.pause()
        placeholderLabel.text = "Playback failed. Segment sharing and deletion are still available."
        placeholderLabel.isHidden = false
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "segment")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "segment")
        let row = rows[indexPath.row]
        cell.accessoryView = nil
        cell.accessibilityTraits.remove(.notEnabled)
        cell.selectionStyle = .default
        cell.textLabel?.textColor = .label
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.imageView?.image = nil

        guard let artifact = row.artifact else {
            cell.textLabel?.text = "Segment \(row.seq)"
            cell.detailTextLabel?.text = "Waiting to save"
            cell.accessoryType = .none
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.startAnimating()
            cell.accessoryView = indicator
            cell.accessibilityTraits.insert(.notEnabled)
            cell.selectionStyle = .none
            cell.textLabel?.textColor = .secondaryLabel
            return cell
        }

        cell.textLabel?.text = String(format: "seg_%05d.%@", artifact.seq, artifact.kind.rawValue)
        let action: String
        if artifact.isPlayable {
            action = "Tap to play"
        } else if artifact.kind == .mp4 {
            action = "Share only - unavailable for playback"
        } else {
            action = "Share only"
        }
        cell.detailTextLabel?.text = [
            artifact.durationMs.map(Formatters.approximateDuration),
            artifact.bytes > 0 ? Formatters.byteSize(artifact.bytes) : nil,
            action,
        ].compactMap { $0 }.joined(separator: " - ")
        cell.accessoryType = artifact.isPlayable ? .disclosureIndicator : .none
        cell.imageView?.image = UIImage(systemName: artifact.isPlayable ? "play.rectangle" : "doc")
        return cell
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        rows[indexPath.row].artifact == nil ? nil : indexPath
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard shareCoordinator?.isPreparing != true else { return }
        guard let artifact = rows[indexPath.row].artifact else { return }
        selectedRow = artifact
        shareButton.isEnabled = true
        if artifact.isPlayable, let start = timeline?.startTime(for: artifact.seq) {
            player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }

    @objc private func jumpToPressTapped() {
        guard let record, let timeline, timeline.segments.isEmpty == false else { return }
        player.seek(
            to: timeline.pressTime(markSeq: record.markSeq, markAgeMs: record.markAgeMs),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    @objc private func shareTapped() {
        guard let row = selectedRow, let record else { return }
        let pressedAt = Date(timeIntervalSince1970: Double(record.pressedAtMs) / 1_000)
        let request = SharePreparationRequest(
            sourceURL: row.url,
            suggestedFilename: Formatters.incidentExportFilename(
                pressedAt: pressedAt,
                seq: row.seq,
                fileExtension: row.kind.rawValue,
                timeZone: exportTimeZone
            )
        )
        shareCoordinator?.start(request)
    }

    @objc private func deleteTapped() {
        shareCoordinator?.cancel()
        present(IncidentDeleteConfirmation.alert { [weak self] in
            guard let self else { return }
            self.store.send(.incidents(.deleteTapped(.readable(self.incidentID))))
        }, animated: true)
    }

    private func setSharePreparationControls(preparing: Bool) {
        shareButton.isEnabled = preparing == false && selectedRow != nil
        deleteButton.isEnabled = preparing == false
        tableView.allowsSelection = preparing == false
    }

    private func handleShareSourceUnavailable() {
        selectedRow = nil
        shareButton.isEnabled = false
        if let record {
            rows = segmentRows(record: record)
            tableView.reloadData()
            startTimelineBuild(record: record, forceReplacement: false)
        }
        let alert = UIAlertController(
            title: "Unable to Share Video",
            message: "The video file is no longer available.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func tearDownPlayback(dismissFullScreen: Bool) {
        buildGeneration += 1
        timelineBuildTask?.cancel()
        timelineBuildTask = nil
        currentItemStatusObservation?.invalidate()
        currentItemStatusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        timeline = nil
        if dismissFullScreen, isPresentingFullScreen {
            playerViewController.dismiss(animated: false)
            setFullScreen(false)
        }
    }

    private func tearDown() {
        observation = nil
        shareCoordinator?.cancel()
        tearDownPlayback(dismissFullScreen: true)
    }

    private func setFullScreen(_ value: Bool) {
        isPresentingFullScreen = value
    }

    var rowsForTesting: [IncidentSegmentRow] { rows }
    var isSharePreparingForTesting: Bool { shareCoordinator?.isPreparing ?? false }
    var sharePreparationAccessibilityLabelForTesting: String? { shareButton.customView?.accessibilityLabel }
    var isShareButtonEnabledForTesting: Bool { shareButton.isEnabled }
    var isDeleteButtonEnabledForTesting: Bool { deleteButton.isEnabled }
    var allowsSelectionForTesting: Bool { tableView.allowsSelection }
    var presentedShareURLForTesting: URL? { shareCoordinator?.lastPresentedURLForTesting }
    var hasSelectedRowForTesting: Bool { selectedRow != nil }
    var playerForTesting: AVPlayer { player }
    var playerViewControllerForTesting: AVPlayerViewController { playerViewController }
    var timelineForTesting: IncidentPlaybackTimeline? { timeline }
    var placeholderTextForTesting: String? { placeholderLabel.isHidden ? nil : placeholderLabel.text }
    var progressTextForTesting: String? { progressLabel.text }
    var gapTextForTesting: String? { gapLabel.text }
    var isJumpToPressEnabledForTesting: Bool { jumpToPressButton.isEnabled }
    var isPresentingFullScreenForTesting: Bool { isPresentingFullScreen }

    func selectRowForTesting(at index: Int) {
        tableView(tableView, didSelectRowAt: IndexPath(row: index, section: 0))
    }

    func cellForTesting(at index: Int) -> UITableViewCell {
        tableView(tableView, cellForRowAt: IndexPath(row: index, section: 0))
    }

    func waitForTimelineBuildForTesting() async {
        await timelineBuildTask?.value
    }

    func shareTappedForTesting() { shareTapped() }
    func jumpToPressForTesting() { jumpToPressTapped() }
    func failCurrentPlayerForTesting() { handlePlayerItemFailed() }
    func enterFullScreenForTesting() { setFullScreen(true) }
}

extension IncidentDetailViewController: AVPlayerViewControllerDelegate {
    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
    ) {
        setFullScreen(true)
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            if context.isCancelled { self?.setFullScreen(false) }
        }
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
    ) {
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            if context.isCancelled == false { self?.setFullScreen(false) }
        }
    }
}
