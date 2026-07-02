import AVKit
import OSLog
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ClipViewerViewController: UIViewController {
    private let dependencies: AppDependencies
    private let clip: Clip

    private let scrollView = UIScrollView()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let statusLabel = UILabel()
    private let resultLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let shareButton = UIBarButtonItem()
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
    private var currentItemURL: URL?
    private var temporaryFiles: Set<URL> = []
    private var shareArtifactDirectories: Set<URL> = []
    private var didSelfHealCacheHitFailure = false
    private var isPresentingFullScreen = false

    // Root for the per-share clone subdirectories. Internal (not private) with a single
    // default so a test can point it at a regular file, forcing the clone below to fail and
    // exercising the last-resort fallback -- no DI seam through AppDependencies.
    var shareScratchDirectory = FileManager.default.temporaryDirectory
        .appending(path: "clip-share", directoryHint: .isDirectory)

    init(dependencies: AppDependencies, clip: Clip) {
        self.dependencies = dependencies
        self.clip = clip
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClipViewerViewController is programmatic.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = String(format: "seg_%05d.ts", clip.id)
        view.backgroundColor = .systemBackground
        configureViews()
        configureShareButton()

        state = .preparing
        pullTask = Task { [weak self] in
            await self?.loadFromCacheThenPlayOrPull()
        }
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

    var isPresentingFullScreenForTesting: Bool {
        isPresentingFullScreen
    }

    func retryForTesting() {
        retry()
    }

    func makeShareArtifactForTesting() -> (url: URL, temporaryDirectory: URL?)? {
        guard let artifact = makeShareArtifact() else { return nil }
        return (artifact.url, artifact.temporaryDirectory)
    }

    func shareTappedForTesting() {
        shareTapped(shareButton)
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
        progressView.progress = 0
        progressView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.text = "Preparing pull"
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

        captionLabel.text = Formatters.clipMetadata(durMs: clip.durMs, bytes: clip.bytes)
        captionLabel.font = .preferredFont(forTextStyle: .footnote)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = .secondaryLabel
        captionLabel.textAlignment = .center
        captionLabel.numberOfLines = 0

        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [
            playerContainerView,
            captionLabel,
            statusLabel,
            progressView,
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
        ])
    }

    private func configureShareButton() {
        shareButton.image = UIImage(systemName: "square.and.arrow.up")
        shareButton.style = .plain
        shareButton.target = self
        shareButton.action = #selector(shareTapped(_:))
        shareButton.accessibilityLabel = "Share clip"
        shareButton.isEnabled = false
        navigationItem.rightBarButtonItem = shareButton
    }

    @objc private func retryButtonTapped() {
        retry()
    }

    @objc private func shareTapped(_ sender: UIBarButtonItem) {
        guard let artifact = makeShareArtifact() else {
            if currentItemURL != nil {
                startPull()   // cache purged between .playing and the tap -> self-heal (ADR 13)
            }
            return
        }

        let activityViewController = UIActivityViewController(
            activityItems: [ClipShareItemSource(url: artifact.url)],
            applicationActivities: nil
        )
        activityViewController.popoverPresentationController?.sourceItem = sender
        if let directory = artifact.temporaryDirectory {
            activityViewController.completionWithItemsHandler = { _, _, _, _ in
                try? FileManager.default.removeItem(at: directory)
            }
        }
        present(activityViewController, animated: true)
    }

    private struct ShareArtifact {
        let url: URL
        let temporaryDirectory: URL?   // non-nil only when we created a clone to clean up
    }

    private func makeShareArtifact() -> ShareArtifact? {
        guard let cacheURL = currentItemURL, fileExistsAsFile(cacheURL) else { return nil }

        let subdirectory = shareScratchDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let destination = subdirectory.appending(path: Formatters.clipExportFilename(clip))

        do {
            try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: cacheURL, to: destination)  // APFS COW clone: instant, independent inode
            shareArtifactDirectories.insert(subdirectory)
            return ShareArtifact(url: destination, temporaryDirectory: subdirectory)
        } catch {
            try? FileManager.default.removeItem(at: subdirectory)
            // Last resort: share the real cache file (ugly name) rather than fail -- but only
            // if it still exists; if it was purged in the TOCTOU window, self-heal instead.
            return fileExistsAsFile(cacheURL) ? ShareArtifact(url: cacheURL, temporaryDirectory: nil) : nil
        }
    }

    private func fileExistsAsFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue == false
    }

    private func retry() {
        startPull()
    }

    private func loadFromCacheThenPlayOrPull() async {
        if let cachedURL = await dependencies.clipCache.lookup(clip.id, clip.etag) {
            guard Task.isCancelled == false else { return }
            play(cachedURL, source: .cacheHit)
            return
        }

        guard Task.isCancelled == false else { return }
        startPull()
    }

    private func startPull() {
        pullTask?.cancel()
        pullTask = nil
        removeTemporaryFiles()
        detachPlayer()
        state = .pulling(PullProgress(bytesWritten: 0, expected: clip.bytes > 0 ? clip.bytes : nil))

        pullTask = Task { [weak self] in
            await self?.runPullRemuxCacheAndPlay()
        }
    }

    private func runPullRemuxCacheAndPlay() async {
        do {
            for try await event in dependencies.clipPull.pull(clip.id, clip.etag) {
                try Task.checkCancellation()
                switch event {
                case .opened(let fileURL):
                    temporaryFiles.insert(fileURL)
                case .restarted:
                    break
                case .progress(let bytesWritten, let expected):
                    state = .pulling(PullProgress(bytesWritten: bytesWritten, expected: expected))
                case .completed(let result):
                    try await prepareAndPlay(result)
                    pullTask = nil
                    return
                }
            }
            pullTask = nil
        } catch is CancellationError {
            removeTemporaryFiles()
        } catch {
            fail(message: error.localizedDescription)
        }
    }

    private func prepareAndPlay(_ result: ClipPullResult) async throws {
        temporaryFiles.insert(result.fileURL)
        state = .preparing

        let remuxedResult = try await dependencies.clipRemuxer.remux(result.fileURL, clip.id)
        try Task.checkCancellation()
        temporaryFiles.insert(remuxedResult.fileURL)

        let cachedURL = try await dependencies.clipCache.insert(
            clip.id,
            result.resolvedETag,
            remuxedResult.fileURL
        )
        try Task.checkCancellation()

        if cachedURL != remuxedResult.fileURL {
            temporaryFiles.remove(remuxedResult.fileURL)
        }
        if cachedURL != result.fileURL {
            removeTemporaryFile(result.fileURL)
        }

        play(cachedURL, source: .freshRemux)
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
            startPull()
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
        removeTemporaryFiles()
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
            progressView.setProgress(1, animated: true)
            statusLabel.text = "Preparing"
            resultLabel.text = nil
            retryButton.isHidden = true
        case .playing:
            shareButton.isEnabled = true
            progressView.setProgress(1, animated: false)
            statusLabel.text = "Ready"
            resultLabel.text = nil
            retryButton.isHidden = true
        case .failed(let message):
            shareButton.isEnabled = false
            progressView.setProgress(0, animated: false)
            statusLabel.text = "Clip failed"
            resultLabel.text = message
            retryButton.isHidden = false
        }
    }

    private func renderProgress(_ progress: PullProgress) {
        if let expected = progress.expected, expected > 0 {
            progressView.setProgress(Float(Double(progress.bytesWritten) / Double(expected)), animated: true)
        } else {
            progressView.setProgress(0, animated: false)
        }
        statusLabel.text = progressStatusText(progress)
        resultLabel.text = nil
        retryButton.isHidden = true
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

        if let playerViewController {
            playerViewController.willMove(toParent: nil)
            playerViewController.view.removeFromSuperview()
            playerViewController.removeFromParent()
            self.playerViewController = nil
        }
    }

    private func tearDown() {
        pullTask?.cancel()
        pullTask = nil
        detachPlayer()
        removeTemporaryFiles()
        removeShareArtifactDirectories()
    }

    private func removeShareArtifactDirectories() {
        for directory in shareArtifactDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        shareArtifactDirectories.removeAll()
    }

    private func removeTemporaryFile(_ url: URL) {
        temporaryFiles.remove(url)
        try? FileManager.default.removeItem(at: url)
    }

    private func removeTemporaryFiles() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles.removeAll()
    }

    private struct PullProgress: Equatable {
        var bytesWritten: UInt64
        var expected: UInt64?
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

/// Wraps a clip's file URL for the share sheet so the movie UTType is declared
/// explicitly rather than inferred from the `.mp4` extension alone. Intentionally
/// omits `activityViewControllerLinkMetadata`: the sheet keeps its auto-generated
/// QuickLook preview header (no `LPLinkMetadata`).
@MainActor
final class ClipShareItemSource: NSObject, UIActivityItemSource {
    private let url: URL
    private let typeIdentifier: String

    init(url: URL) {
        self.url = url
        self.typeIdentifier = UTType(filenameExtension: url.pathExtension)?.identifier
            ?? UTType.mpeg4Movie.identifier
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        typeIdentifier
    }
}
