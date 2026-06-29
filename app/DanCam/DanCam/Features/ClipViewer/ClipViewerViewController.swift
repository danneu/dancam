import AVKit
import UIKit

nonisolated enum ProgressiveAvailability {
    enum Decision: Equatable {
        case advance(UInt64)
        case terminateProgressive
        case ignore
    }

    static func decide(
        _ event: ClipPullEvent,
        lastForwarded: inout UInt64
    ) -> Decision {
        switch event {
        case .restarted:
            lastForwarded = 0
            return .terminateProgressive
        case .progress(let bytesWritten, _):
            defer { lastForwarded = bytesWritten }
            return bytesWritten < lastForwarded ? .terminateProgressive : .advance(bytesWritten)
        case .opened, .completed:
            return .ignore
        }
    }
}

@MainActor
final class ClipViewerViewController: UIViewController {
    private let dependencies: AppDependencies
    private let clip: Clip

    private let scrollView = UIScrollView()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let statusLabel = UILabel()
    private let resultLabel = UILabel()
    private let playerContainerView = UIView()

    private var state: ViewerState? {
        didSet {
            guard let state, state != oldValue else { return }
            render(state)
        }
    }

    private var pullTask: Task<Void, Never>?
    private var segmenterTask: Task<Void, Never>?
    private var finalizerTask: Task<Void, Never>?
    private var availabilityContinuation: AsyncStream<UInt64>.Continuation?
    private var lastForwardedAvailability: UInt64 = 0
    private var player: AVPlayer?
    private var playerViewController: AVPlayerViewController?
    private var currentItemStatusObservation: NSKeyValueObservation?
    private var currentItemIsProgressive = false
    private var currentItemURL: URL?
    private var temporaryFiles: Set<URL> = []
    private var progressiveWorkDirectories: Set<URL> = []

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
        startPull()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        tearDown()
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

    var progressFraction: Float {
        progressView.progress
    }

    var hasEmbeddedPlayer: Bool {
        playerViewController != nil
    }

    var currentPlayerItemURL: URL? {
        currentItemURL
    }

    var currentPlayerTime: CMTime {
        player?.currentTime() ?? .invalid
    }

    var isCurrentPlayerPlaying: Bool {
        guard let player else { return false }
        return player.rate != 0 || player.timeControlStatus == .playing
    }

    func seekCurrentPlayerForTesting(to time: CMTime) async {
        guard let player else { return }

        await withCheckedContinuation { continuation in
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
    }

    func pauseCurrentPlayerForTesting() {
        player?.pause()
    }

    func failCurrentProgressivePlayerForTesting() {
        handlePlayerItemFailed(isProgressive: currentItemIsProgressive)
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

        playerContainerView.backgroundColor = .black
        playerContainerView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [
            playerContainerView,
            statusLabel,
            progressView,
            resultLabel,
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

    private func startPull() {
        pullTask?.cancel()
        pullTask = Task { [weak self] in
            await self?.runPull()
        }
    }

    private func runPull() async {
        do {
            for try await event in dependencies.clipPull.pull(clip.id, clip.etag) {
                try Task.checkCancellation()
                handlePullEvent(event)
            }
        } catch is CancellationError {
            removeTemporaryFiles()
        } catch {
            stopProgressivePipeline()
            state = .failed(message: error.localizedDescription)
        }
    }

    private func handlePullEvent(_ event: ClipPullEvent) {
        var lastForwarded = lastForwardedAvailability
        let availabilityDecision = ProgressiveAvailability.decide(event, lastForwarded: &lastForwarded)
        lastForwardedAvailability = lastForwarded
        apply(availabilityDecision)

        switch event {
        case .opened(let fileURL):
            temporaryFiles.insert(fileURL)
            startSegmenter(sourceURL: fileURL)
        case .restarted:
            break
        case .progress(let bytesWritten, let expected):
            updateProgress(PullProgress(bytesWritten: bytesWritten, expected: expected))
        case .completed(let result):
            handlePullCompleted(result)
        }
    }

    private func apply(_ decision: ProgressiveAvailability.Decision) {
        switch decision {
        case .advance(let bytesAvailable):
            availabilityContinuation?.yield(bytesAvailable)
        case .terminateProgressive:
            handleProgressiveFailure(.truncatedReset)
        case .ignore:
            break
        }
    }

    private func updateProgress(_ progress: PullProgress) {
        switch state {
        case .fallback(.awaitingCompletion(_, let reason)):
            state = .fallback(.awaitingCompletion(progress, reason: reason))
        case .playingWhilePulling(_, let ttff):
            state = .playingWhilePulling(progress, ttff: ttff)
        default:
            state = availabilityContinuation == nil
                ? .pulling(progress)
                : .preparingFirstPlayableFragment(progress)
        }
    }

    private func handlePullCompleted(_ result: ClipPullResult) {
        availabilityContinuation?.finish()
        availabilityContinuation = nil
        temporaryFiles.insert(result.fileURL)

        switch state {
        case .fallback(.awaitingCompletion(_, let reason)):
            state = .fallback(.finalizing(result, reason: reason))
            startFinalizer(for: result, source: .fallback)
        default:
            state = .complete(result)
            startFinalizer(for: result, source: currentItemIsProgressive ? .progressiveSwap : .fallback)
        }
    }

    private func startSegmenter(sourceURL: URL) {
        segmenterTask?.cancel()
        availabilityContinuation?.finish()
        lastForwardedAvailability = 0

        let (availability, continuation) = AsyncStream.makeStream(of: UInt64.self)
        availabilityContinuation = continuation
        let events = dependencies.progressiveSegmenter.start(sourceURL, clip.id, availability)

        segmenterTask = Task { [weak self] in
            do {
                for try await event in events {
                    try Task.checkCancellation()
                    self?.handleSegmenterEvent(event)
                }
            } catch is CancellationError {
                // Viewer teardown owns cleanup.
            } catch {
                self?.handleProgressiveFailure(.segmenterFailed)
            }
        }
    }

    private func handleSegmenterEvent(_ event: ProgressiveSegmenterEvent) {
        switch event {
        case .opened(let workDirectory):
            temporaryFiles.insert(workDirectory)
            progressiveWorkDirectories.insert(workDirectory)
        case .firstPlayableReady(let url):
            handleFirstPlayable(url)
        case .finished:
            // A finalized #EXT-X-ENDLIST progressive playlist is now being served.
            // The scrubbable swap is owned by the pull-completion finalizer
            // (handlePullCompleted -> startFinalizer), so there is nothing to do here today.
            break
        }
    }

    private func handleFirstPlayable(_ url: URL) {
        guard let progress = progressiveEligibleProgress() else { return }

        attachPlayer(url: url, isProgressive: true)
        player?.play()
        state = .playingWhilePulling(progress, ttff: nil)
    }

    private func progressiveEligibleProgress() -> PullProgress? {
        switch state {
        case .none:
            PullProgress(bytesWritten: 0, expected: clip.bytes > 0 ? clip.bytes : nil)
        case .pulling(let progress), .preparingFirstPlayableFragment(let progress):
            progress
        default:
            nil
        }
    }

    private func handleProgressiveFailure(_ reason: FallbackReason) {
        guard progressiveFallbackCanApply else { return }

        let progress = currentProgress() ?? PullProgress(bytesWritten: 0, expected: clip.bytes > 0 ? clip.bytes : nil)
        stopProgressivePipeline()
        state = .fallback(.awaitingCompletion(progress, reason: reason))
    }

    private var progressiveFallbackCanApply: Bool {
        switch state {
        case .none, .pulling, .preparingFirstPlayableFragment, .playingWhilePulling:
            true
        case .complete, .finalizing, .readyScrubbable, .progressiveOnly, .fallback, .failed:
            false
        }
    }

    private func currentProgress() -> PullProgress? {
        switch state {
        case .pulling(let progress),
             .preparingFirstPlayableFragment(let progress),
             .playingWhilePulling(let progress, _),
             .fallback(.awaitingCompletion(let progress, _)):
            progress
        case .none, .complete, .finalizing, .readyScrubbable, .progressiveOnly, .fallback, .failed:
            nil
        }
    }

    private func startFinalizer(for result: ClipPullResult, source: FinalizeSource) {
        finalizerTask?.cancel()
        finalizerTask = Task { [weak self] in
            await self?.runFinalizer(for: result, source: source)
        }
    }

    private func runFinalizer(for pullResult: ClipPullResult, source: FinalizeSource) async {
        do {
            state = .finalizing(pullResult, source: source)
            let remuxedResult = try await dependencies.clipRemuxer.remux(pullResult.fileURL, clip.id)
            temporaryFiles.insert(remuxedResult.fileURL)
            if remuxedResult.fileURL != pullResult.fileURL {
                removeTemporaryFile(pullResult.fileURL)
            }
            let shouldSwapExistingPlayer = source == .progressiveSwap && player != nil
            let resumeTime = shouldSwapExistingPlayer ? currentPlayerTime : .zero
            let shouldPlay = shouldSwapExistingPlayer ? shouldResumeCurrentPlayerPlayback : true
            state = .readyScrubbable(ReadyInfo(pullResult: pullResult, remuxResult: remuxedResult))
            try Task.checkCancellation()
            if shouldSwapExistingPlayer {
                replaceCurrentPlayerItem(
                    with: remuxedResult.fileURL,
                    resumeTime: resumeTime,
                    shouldPlay: shouldPlay
                )
            } else {
                attachPlayer(url: remuxedResult.fileURL, isProgressive: false)
                if shouldPlay {
                    player?.play()
                }
            }
            stopProgressivePipeline()
        } catch is CancellationError {
            removeTemporaryFiles()
        } catch {
            handleFinalizerFailure(error, pullResult: pullResult, source: source)
        }
    }

    private func handleFinalizerFailure(
        _ error: Error,
        pullResult: ClipPullResult,
        source: FinalizeSource
    ) {
        guard source == .progressiveSwap, currentItemIsProgressive else {
            state = .failed(message: error.localizedDescription)
            return
        }

        removeTemporaryFile(pullResult.fileURL)
        state = .progressiveOnly(pullResult, message: error.localizedDescription)
    }

    private func render(_ state: ViewerState) {
        switch state {
        case .pulling(let progress), .fallback(.awaitingCompletion(let progress, _)):
            renderProgress(progress)
        case .preparingFirstPlayableFragment:
            statusLabel.text = "Preparing first frame"
        case .playingWhilePulling(let progress, let ttff):
            renderPlayingWhilePulling(progress: progress, ttff: ttff)
        case .complete(let result):
            renderCompleted(result)
        case .fallback(.finalizing):
            statusLabel.text = "Preparing playback"
        case .finalizing(_, let source):
            statusLabel.text = source == .progressiveSwap ? "Preparing scrubbing" : "Preparing playback"
        case .readyScrubbable(let info):
            renderReadyToPlay(pullResult: info.pullResult, remuxResult: info.remuxResult)
        case .progressiveOnly(let result, let message):
            renderProgressiveOnly(pullResult: result, message: message)
        case .failed(let message):
            stopProgressivePipeline()
            removeTemporaryFiles()
            progressView.setProgress(0, animated: false)
            statusLabel.text = "Clip failed"
            resultLabel.text = message
        }
    }

    private func renderProgress(_ progress: PullProgress) {
        if let expected = progress.expected, expected > 0 {
            progressView.setProgress(Float(Double(progress.bytesWritten) / Double(expected)), animated: true)
        }
        statusLabel.text = progressStatusText(progress)
    }

    private func renderPlayingWhilePulling(progress: PullProgress, ttff: Duration?) {
        statusLabel.text = "Playing - \(progressStatusText(progress))"
        if let ttff {
            resultLabel.text = "first frame \(formatSeconds(ttff))"
        }
    }

    private func renderCompleted(_ result: ClipPullResult) {
        progressView.setProgress(1, animated: true)
        statusLabel.text = "Download complete"
        resultLabel.text = "\(Formatters.byteSize(result.bytes)) - \(formatSeconds(result.elapsed)) - \(formatThroughput(result.throughputMbps))"
    }

    private func renderReadyToPlay(
        pullResult: ClipPullResult,
        remuxResult: ClipRemuxResult
    ) {
        statusLabel.text = "Ready"
        resultLabel.text = [
            "\(Formatters.byteSize(pullResult.bytes)) pulled",
            "\(Formatters.byteSize(remuxResult.bytes)) playable",
            formatSeconds(pullResult.elapsed),
            formatThroughput(pullResult.throughputMbps),
        ].joined(separator: " - ")
    }

    private func renderProgressiveOnly(
        pullResult: ClipPullResult,
        message: String
    ) {
        progressView.setProgress(1, animated: true)
        statusLabel.text = "Scrubbing unavailable"
        resultLabel.text = [
            "\(Formatters.byteSize(pullResult.bytes)) pulled",
            formatSeconds(pullResult.elapsed),
            formatThroughput(pullResult.throughputMbps),
            message,
        ].joined(separator: " - ")
    }

    private func progressStatusText(_ progress: PullProgress) -> String {
        if let expected = progress.expected, expected > 0 {
            "\(Formatters.byteSize(progress.bytesWritten)) of \(Formatters.byteSize(expected))"
        } else {
            "\(Formatters.byteSize(progress.bytesWritten)) pulled"
        }
    }

    private func attachPlayer(url: URL, isProgressive: Bool) {
        detachPlayer()

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let playerViewController = AVPlayerViewController()
        playerViewController.player = player
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
        observePlayerItem(item, isProgressive: isProgressive)
        currentItemIsProgressive = isProgressive
        currentItemURL = url
    }

    private var shouldResumeCurrentPlayerPlayback: Bool {
        guard let player else { return true }
        return player.rate != 0 || player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    private func replaceCurrentPlayerItem(
        with url: URL,
        resumeTime: CMTime,
        shouldPlay: Bool
    ) {
        guard let player else {
            attachPlayer(url: url, isProgressive: false)
            if shouldPlay {
                self.player?.play()
            }
            return
        }

        let seekTime = normalizedResumeTime(resumeTime)
        let item = AVPlayerItem(url: url)
        player.pause()
        player.replaceCurrentItem(with: item)
        observePlayerItem(item, isProgressive: false)
        currentItemIsProgressive = false
        currentItemURL = url

        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
            Task { @MainActor in
                guard let self,
                      let player,
                      self.player === player,
                      self.currentItemURL == url else {
                    return
                }
                if shouldPlay {
                    player.play()
                }
            }
        }
    }

    private func normalizedResumeTime(_ time: CMTime) -> CMTime {
        guard time.isValid, time.isNumeric, CMTimeCompare(time, .zero) >= 0 else {
            return .zero
        }
        return time
    }

    private func observePlayerItem(_ item: AVPlayerItem, isProgressive: Bool) {
        currentItemStatusObservation?.invalidate()
        currentItemStatusObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] observedItem, _ in
            guard observedItem.status == .failed else { return }

            Task { @MainActor [weak self, weak item] in
                guard let self,
                      let item,
                      self.player?.currentItem === item else {
                    return
                }
                self.handlePlayerItemFailed(isProgressive: isProgressive)
            }
        }
    }

    private func handlePlayerItemFailed(isProgressive: Bool) {
        guard isProgressive else { return }
        handleProgressiveFailure(.progressivePlayerFailed)
    }

    private func detachPlayer() {
        player?.pause()
        currentItemStatusObservation?.invalidate()
        currentItemStatusObservation = nil
        player = nil
        currentItemIsProgressive = false
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
        finalizerTask?.cancel()
        finalizerTask = nil
        stopProgressivePipeline()
        detachPlayer()
        removeTemporaryFiles()
    }

    private func stopProgressivePipeline() {
        availabilityContinuation?.finish()
        availabilityContinuation = nil
        segmenterTask?.cancel()
        segmenterTask = nil

        if currentItemIsProgressive {
            detachPlayer()
        }
        removeProgressiveWorkDirectories()
    }

    private func removeTemporaryFile(_ url: URL) {
        temporaryFiles.remove(url)
        try? FileManager.default.removeItem(at: url)
    }

    private func removeProgressiveWorkDirectories() {
        for url in progressiveWorkDirectories {
            removeTemporaryFile(url)
        }
        progressiveWorkDirectories.removeAll()
    }

    private func removeTemporaryFiles() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles.removeAll()
        progressiveWorkDirectories.removeAll()
    }

    private func formatSeconds(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
        return String(format: "%.1f s", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }

    private func formatThroughput(_ throughputMbps: Double) -> String {
        String(format: "%.0f Mbps", locale: Locale(identifier: "en_US_POSIX"), throughputMbps)
    }

    private struct PullProgress: Equatable {
        var bytesWritten: UInt64
        var expected: UInt64?
    }

    private struct ReadyInfo: Equatable {
        var pullResult: ClipPullResult
        var remuxResult: ClipRemuxResult
    }

    private enum FinalizeSource: Equatable {
        case progressiveSwap
        case fallback
    }

    private enum FallbackReason: Equatable {
        case segmenterFailed
        case missingOrInvalidSegmentReport
        case segmentExceedsFrozenTargetDuration
        case neverProducedFirstFrame
        case progressivePlayerFailed
        case truncatedReset
    }

    private enum FallbackPhase: Equatable {
        case awaitingCompletion(PullProgress, reason: FallbackReason)
        case finalizing(ClipPullResult, reason: FallbackReason)
    }

    private enum ViewerState: Equatable {
        case pulling(PullProgress)
        case preparingFirstPlayableFragment(PullProgress)
        case playingWhilePulling(PullProgress, ttff: Duration?)
        case complete(ClipPullResult)
        case finalizing(ClipPullResult, source: FinalizeSource)
        case readyScrubbable(ReadyInfo)
        case progressiveOnly(ClipPullResult, message: String)
        case fallback(FallbackPhase)
        case failed(message: String)
    }
}
