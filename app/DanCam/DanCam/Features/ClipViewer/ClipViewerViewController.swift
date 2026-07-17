import AVKit
import OSLog
import UIKit

@MainActor
final class ClipViewerViewController: UIViewController {
    private let dependencies: AppDependencies
    private let store: AppStore
    private let clip: Clip
    private let sharePresentation: VideoSharePresentation?

    private let scrollView = UIScrollView()
    private let progressContainer = UIView()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let preparingIndicator = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let resultLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let shareButton = UIBarButtonItem()
    private let deleteButton = UIBarButtonItem()
    private let playerContainerView = UIView()
    private let captionLabel = UILabel()

    private var state: ViewerState? {
        didSet {
            guard let state, state != oldValue else { return }
            logViewerTransition(from: oldValue, to: state)
            render(state)
        }
    }

    private var pullTask: Task<Void, Never>?
    private var player: AVPlayer?
    private var playerViewController: AVPlayerViewController?
    private var currentItemStatusObservation: NSKeyValueObservation?
    private var currentPlaybackSource: PlaybackSource?
    private var currentMediaLease: ClipMediaLease?
    private var currentItemURL: URL?
    private var didSelfHealCacheHitFailure = false
    private var isPresentingFullScreen = false
    private var hasCompletedFirstLayout = false

    private var shareCoordinator: VideoShareCoordinator?

    init(
        dependencies: AppDependencies,
        store: AppStore,
        clip: Clip,
        sharePresentation: VideoSharePresentation? = nil
    ) {
        self.dependencies = dependencies
        self.store = store
        self.clip = clip
        self.sharePresentation = sharePresentation
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClipViewerViewController is programmatic.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.title = String(format: "seg_%05d.ts", clip.id)
        view.backgroundColor = .systemBackground
        configureViews()
        configureShareButton()
        configureShareCoordinator()

        pullTask = Task { [weak self] in
            self?.startPull()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        hasCompletedFirstLayout = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil {
            tearDown()
        }
    }

    isolated deinit {
        tearDown()
    }

    var statusText: String? {
        statusLabel.text
    }

    var resultText: String? {
        resultLabel.text
    }

    var captionText: String? {
        captionLabel.text
    }

    var progressFraction: Float {
        progressView.progress
    }

    var progressIndicatorForTesting: ProgressIndicatorState {
        if preparingIndicator.isAnimating {
            return .indeterminate
        }

        if progressView.isHidden == false {
            return .determinate
        }

        return .hidden
    }

    var hasEmbeddedPlayer: Bool {
        playerViewController != nil
    }

    var currentPlayerItemURL: URL? {
        currentItemURL
    }

    var isRetryButtonHidden: Bool {
        retryButton.isHidden
    }

    var isShareButtonEnabled: Bool {
        shareButton.isEnabled
    }

    var isDeleteButtonEnabledForTesting: Bool { deleteButton.isEnabled }
    var isSharePreparingForTesting: Bool { shareCoordinator?.isPreparing ?? false }
    var sharePreparationAccessibilityLabelForTesting: String? { shareButton.customView?.accessibilityLabel }
    var isScrollEnabledForTesting: Bool { scrollView.isScrollEnabled }
    var presentedShareURLForTesting: URL? { shareCoordinator?.lastPresentedURLForTesting }

    var isPresentingFullScreenForTesting: Bool {
        isPresentingFullScreen
    }

    func retryForTesting() {
        retry()
    }

    func shareTappedForTesting() {
        shareTapped(shareButton)
    }

    func performDeleteForTesting() {
        performDelete()
    }

    func failCurrentPlayerForTesting() {
        handlePlayerItemFailed(source: currentPlaybackSource, message: "Clip playback failed.")
    }

    func enterFullScreenForTesting() {
        setFullScreen(true)
    }

    func exitFullScreenForTesting() {
        setFullScreen(false)
    }

    private func configureViews() {
        progressContainer.translatesAutoresizingMaskIntoConstraints = false

        progressView.progress = 0
        progressView.translatesAutoresizingMaskIntoConstraints = false

        preparingIndicator.hidesWhenStopped = true
        preparingIndicator.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.text = "Preparing"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0

        resultLabel.font = .preferredFont(forTextStyle: .subheadline)
        resultLabel.adjustsFontForContentSizeCategory = true
        resultLabel.numberOfLines = 0
        resultLabel.textColor = .secondaryLabel

        retryButton.setTitle("Retry", for: .normal)
        retryButton.isHidden = true
        retryButton.addTarget(self, action: #selector(retryButtonTapped), for: .touchUpInside)

        playerContainerView.backgroundColor = .black
        playerContainerView.translatesAutoresizingMaskIntoConstraints = false

        captionLabel.text = Formatters.clipDetailLine(clip)
        captionLabel.font = .preferredFont(forTextStyle: .footnote)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = .secondaryLabel
        captionLabel.textAlignment = .center
        captionLabel.numberOfLines = 0

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        progressContainer.addSubview(progressView)
        progressContainer.addSubview(preparingIndicator)
        showIndeterminate()

        let stack = UIStackView(arrangedSubviews: [
            playerContainerView,
            captionLabel,
            statusLabel,
            progressContainer,
            resultLabel,
            retryButton,
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),

            playerContainerView.heightAnchor.constraint(equalTo: playerContainerView.widthAnchor, multiplier: 0.75),

            progressContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
            progressContainer.heightAnchor.constraint(greaterThanOrEqualTo: preparingIndicator.heightAnchor),

            progressView.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor),
            progressView.centerYAnchor.constraint(equalTo: progressContainer.centerYAnchor),

            preparingIndicator.centerXAnchor.constraint(equalTo: progressContainer.centerXAnchor),
            preparingIndicator.centerYAnchor.constraint(equalTo: progressContainer.centerYAnchor),
        ])
    }

    private func configureShareButton() {
        shareButton.image = UIImage(systemName: "square.and.arrow.up")
        shareButton.style = .plain
        shareButton.target = self
        shareButton.action = #selector(shareTapped(_:))
        shareButton.accessibilityLabel = "Share clip"
        shareButton.isEnabled = false
        configureDeleteButton()
        navigationItem.rightBarButtonItems = [shareButton, deleteButton]
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
                guard let self, self.currentItemURL != nil else { return }
                self.startPull()
            }
        )
    }

    private func configureDeleteButton() {
        deleteButton.image = UIImage(systemName: "trash")
        deleteButton.style = .plain
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.accessibilityLabel = "Delete clip"
        deleteButton.tintColor = .systemRed
    }

    @objc private func retryButtonTapped() {
        retry()
    }

    @objc private func shareTapped(_ sender: UIBarButtonItem) {
        guard let sourceURL = currentItemURL else { return }
        let request = SharePreparationRequest(
            sourceURL: sourceURL,
            suggestedFilename: Formatters.clipExportFilename(clip)
        )
        shareCoordinator?.start(request)
    }

    @objc private func deleteTapped() {
        let alert = UIAlertController(
            title: "Delete clip?",
            message: "This removes the clip from the camera unit.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.performDelete()
        })
        present(alert, animated: true)
    }

    private func performDelete() {
        shareCoordinator?.cancel()
        store.send(.clips(.deleteTapped(clip)))
        navigationController?.popViewController(animated: true)
    }

    private func retry() {
        startPull()
    }

    private func startPull() {
        shareCoordinator?.cancel()
        pullTask?.cancel()
        pullTask = nil
        detachPlayer()
        progressView.setProgress(0, animated: false)
        state = .pulling(PullProgress(bytesWritten: 0, expected: clip.bytes > 0 ? clip.bytes : nil))

        pullTask = Task { [weak self] in
            await self?.runPullRemuxCacheAndPlay()
        }
    }

    private func runPullRemuxCacheAndPlay() async {
        do {
            let lease = try await dependencies.clipMedia.playback(clip) { [weak self] progress in
                await self?.apply(progress)
            }
            try Task.checkCancellation()
            play(lease.url, source: lease.isCacheHit ? .cacheHit : .freshRemux)
            currentMediaLease = lease
            pullTask = nil
        } catch is CancellationError {
        } catch {
            fail(message: error.localizedDescription)
        }
    }

    private func apply(_ progress: ClipMediaProgress) {
        if progress.isPreparing {
            state = .preparing
        } else {
            state = .pulling(PullProgress(
                bytesWritten: progress.bytesWritten,
                expected: progress.expectedBytes
            ))
        }
    }

    private func invalidateMediaAndRepull() {
        pullTask?.cancel()
        pullTask = Task { [weak self] in
            guard let self else { return }
            await dependencies.clipMedia.remove(clip)
            guard Task.isCancelled == false else { return }
            startPull()
        }
    }

    private func play(_ url: URL, source: PlaybackSource) {
        detachPlayer()
        Log.playback.notice(
            "clip_id=\(self.clip.id, privacy: .public) phase=play source=\(source.logLabel, privacy: .public)"
        )

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let playerViewController = AVPlayerViewController()
        playerViewController.player = player
        playerViewController.delegate = self
        // Dashcam clips don't need Live Text, subject lift, visual lookup, or code
        // detection; turning off AVKit's paused-frame analysis also quiets the system
        // VisionKit analyzer log noise (VKCImageAnalyzerRequest / verify_image_parameters
        // / "Visual isTranslatable"). Default is true; flag is iOS 16+, target is 26.5.
        playerViewController.allowsVideoFrameAnalysis = false
        playerViewController.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(playerViewController)
        playerContainerView.addSubview(playerViewController.view)
        NSLayoutConstraint.activate([
            playerViewController.view.leadingAnchor.constraint(equalTo: playerContainerView.leadingAnchor),
            playerViewController.view.trailingAnchor.constraint(equalTo: playerContainerView.trailingAnchor),
            playerViewController.view.topAnchor.constraint(equalTo: playerContainerView.topAnchor),
            playerViewController.view.bottomAnchor.constraint(equalTo: playerContainerView.bottomAnchor),
        ])
        playerViewController.didMove(toParent: self)

        self.player = player
        self.playerViewController = playerViewController
        currentPlaybackSource = source
        currentItemURL = url
        observePlayerItem(item, source: source)
        state = .playing(url)
        player.play()
    }

    private func setFullScreen(_ newValue: Bool) {
        guard isPresentingFullScreen != newValue else { return }

        isPresentingFullScreen = newValue
        Log.playback.notice(
            "clip_id=\(self.clip.id, privacy: .public) phase=fullscreen state=\(newValue ? "enter" : "exit", privacy: .public)"
        )
    }

    private func observePlayerItem(_ item: AVPlayerItem, source: PlaybackSource) {
        currentItemStatusObservation?.invalidate()
        currentItemStatusObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] observedItem, _ in
            guard observedItem.status == .failed else { return }

            Task { @MainActor [weak self, weak item] in
                guard let self,
                      let item,
                      self.player?.currentItem === item else {
                    return
                }
                self.handlePlayerItemFailed(
                    source: source,
                    message: item.error?.localizedDescription ?? "Clip playback failed."
                )
            }
        }
    }

    private func handlePlayerItemFailed(source: PlaybackSource?, message: String) {
        switch source {
        case .cacheHit where didSelfHealCacheHitFailure == false:
            didSelfHealCacheHitFailure = true
            Log.playback.notice(
                "clip_id=\(self.clip.id, privacy: .public) phase=self_heal decision=repull source=cacheHit"
            )
            invalidateMediaAndRepull()
        case .cacheHit, .freshRemux:
            Log.playback.notice(
                "clip_id=\(self.clip.id, privacy: .public) phase=self_heal decision=fail source=\(source?.logLabel ?? "unknown", privacy: .public)"
            )
            fail(message: message)
        case .none:
            break
        }
    }

    private func fail(message: String) {
        pullTask?.cancel()
        pullTask = nil
        detachPlayer()
        state = .failed(message: message)
    }

    private func logViewerTransition(from oldState: ViewerState?, to newState: ViewerState) {
        let oldPhase = oldState?.logPhase ?? "none"
        let newPhase = newState.logPhase
        guard oldPhase != newPhase else { return }

        Log.playback.notice(
            "clip_id=\(self.clip.id, privacy: .public) viewer \(oldPhase, privacy: .public) -> \(newPhase, privacy: .public)"
        )
    }

    private func render(_ state: ViewerState) {
        switch state {
        case .pulling(let progress):
            shareButton.isEnabled = false
            renderProgress(progress)
        case .preparing:
            shareButton.isEnabled = false
            showIndeterminate()
            statusLabel.text = "Preparing"
            resultLabel.text = nil
            retryButton.isHidden = true
        case .playing:
            shareButton.isEnabled = shareCoordinator?.isPreparing != true
            hideProgressIndicators()
            statusLabel.text = "Ready"
            resultLabel.text = nil
            retryButton.isHidden = true
        case .failed(let message):
            shareButton.isEnabled = false
            hideProgressIndicators()
            statusLabel.text = "Clip failed"
            resultLabel.text = message
            retryButton.isHidden = false
        }
    }

    private func renderProgress(_ progress: PullProgress) {
        if let expected = progress.expected, expected > 0 {
            showDeterminate(Float(Double(progress.bytesWritten) / Double(expected)))
        } else {
            showIndeterminate()
        }
        statusLabel.text = progressStatusText(progress)
        resultLabel.text = nil
        retryButton.isHidden = true
    }

    private func showIndeterminate() {
        progressView.isHidden = true
        preparingIndicator.startAnimating()
    }

    private func showDeterminate(_ fraction: Float) {
        preparingIndicator.stopAnimating()
        progressView.isHidden = false
        progressView.setProgress(fraction, animated: hasCompletedFirstLayout)
    }

    private func hideProgressIndicators() {
        preparingIndicator.stopAnimating()
        progressView.isHidden = true
    }

    private func progressStatusText(_ progress: PullProgress) -> String {
        if let expected = progress.expected, expected > 0 {
            "\(Formatters.byteSize(progress.bytesWritten)) of \(Formatters.byteSize(expected))"
        } else {
            "\(Formatters.byteSize(progress.bytesWritten)) pulled"
        }
    }

    private func detachPlayer() {
        player?.pause()
        currentItemStatusObservation?.invalidate()
        currentItemStatusObservation = nil
        player = nil
        currentPlaybackSource = nil
        currentItemURL = nil
        currentMediaLease = nil

        if let playerViewController {
            playerViewController.willMove(toParent: nil)
            playerViewController.view.removeFromSuperview()
            playerViewController.removeFromParent()
            self.playerViewController = nil
        }
    }

    private func tearDown() {
        shareCoordinator?.cancel()
        pullTask?.cancel()
        pullTask = nil
        detachPlayer()
    }

    private func setSharePreparationControls(preparing: Bool) {
        shareButton.isEnabled = preparing == false && state?.isPlaying == true
        deleteButton.isEnabled = preparing == false
    }

    private struct PullProgress: Equatable {
        var bytesWritten: UInt64
        var expected: UInt64?
    }

    enum ProgressIndicatorState: Equatable {
        case hidden
        case indeterminate
        case determinate
    }

    private enum PlaybackSource: Equatable {
        case cacheHit
        case freshRemux

        var logLabel: String {
            switch self {
            case .cacheHit:
                "cacheHit"
            case .freshRemux:
                "freshRemux"
            }
        }
    }

    private enum ViewerState: Equatable {
        case pulling(PullProgress)
        case preparing
        case playing(URL)
        case failed(message: String)

        var isPlaying: Bool {
            if case .playing = self { return true }
            return false
        }

        var logPhase: String {
            switch self {
            case .pulling:
                "pulling"
            case .preparing:
                "preparing"
            case .playing:
                "playing"
            case .failed:
                "failed"
            }
        }
    }
}

extension ClipViewerViewController: AVPlayerViewControllerDelegate {
    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
    ) {
        setFullScreen(true)
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            if context.isCancelled {
                self?.setFullScreen(false)
            }
        }
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
    ) {
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            if context.isCancelled == false {
                self?.setFullScreen(false)
            }
        }
    }
}
