import AVKit
import UIKit

final class ClipViewerViewController: UIViewController {
    private let dependencies: AppDependencies
    private let clip: Clip

    private let scrollView = UIScrollView()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let statusLabel = UILabel()
    private let resultLabel = UILabel()
    private let playerContainerView = UIView()

    private var pullTask: Task<Void, Never>?
    private var server: LoopbackHLSServer?
    private var player: AVPlayer?
    private var playerViewController: AVPlayerViewController?

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
            var completedResult: ClipPullResult?

            for try await event in dependencies.clipPull.pull(clip.id, clip.etag) {
                try Task.checkCancellation()

                switch event {
                case .progress(let bytesWritten, let expected):
                    renderProgress(bytesWritten: bytesWritten, expected: expected)
                case .completed(let result):
                    completedResult = result
                    renderCompleted(result)
                }
            }

            guard let completedResult else { return }
            try Task.checkCancellation()
            try await startPlayback(from: completedResult.fileURL)
        } catch is CancellationError {
        } catch {
            renderFailure(error)
        }
    }

    private func renderProgress(bytesWritten: UInt64, expected: UInt64?) {
        if let expected, expected > 0 {
            progressView.setProgress(Float(Double(bytesWritten) / Double(expected)), animated: true)
            statusLabel.text = "\(Formatters.byteSize(bytesWritten)) of \(Formatters.byteSize(expected))"
        } else {
            statusLabel.text = "\(Formatters.byteSize(bytesWritten)) pulled"
        }
    }

    private func renderCompleted(_ result: ClipPullResult) {
        progressView.setProgress(1, animated: true)
        statusLabel.text = "Ready"
        resultLabel.text = "\(Formatters.byteSize(result.bytes)) - \(formatSeconds(result.elapsed)) - \(formatThroughput(result.throughputMbps))"
    }

    private func startPlayback(from fileURL: URL) async throws {
        let durationSeconds = Double(clip.durMs ?? 30_000) / 1_000.0
        let server = LoopbackHLSServer(segmentURL: fileURL, durationSeconds: durationSeconds)
        self.server = server
        let baseURL = try await server.start()
        try Task.checkCancellation()

        let player = AVPlayer(url: baseURL.appending(path: "index.m3u8"))
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
        player.play()
    }

    private func renderFailure(_ error: Error) {
        progressView.setProgress(0, animated: false)
        statusLabel.text = "Pull failed"
        resultLabel.text = error.localizedDescription
    }

    private func tearDown() {
        pullTask?.cancel()
        pullTask = nil
        player?.pause()
        player = nil

        if let playerViewController {
            playerViewController.willMove(toParent: nil)
            playerViewController.view.removeFromSuperview()
            playerViewController.removeFromParent()
            self.playerViewController = nil
        }

        if let server {
            Task { [server] in
                await server.stop()
            }
            self.server = nil
        }
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
}
