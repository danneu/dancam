import OSLog
import UIKit

@MainActor
struct VideoSharePresentation {
    typealias Ready = @MainActor () -> Void
    typealias Completed = @MainActor () -> Void
    var present: @MainActor (URL, UIBarButtonItem, @escaping Ready, @escaping Completed) -> Void

    static func live(presenter: UIViewController) -> Self {
        Self { [unowned presenter] url, sourceItem, ready, completed in
            let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            controller.popoverPresentationController?.sourceItem = sourceItem
            controller.completionWithItemsHandler = { _, _, _, _ in
                Task { @MainActor in completed() }
            }
            presenter.present(controller, animated: true, completion: ready)
        }
    }
}

@MainActor
final class VideoShareCoordinator {
    private let preparer: ShareArtifactPreparer
    private let shareButton: UIBarButtonItem
    private let preparingChanged: (Bool) -> Void
    private let sourceUnavailable: () -> Void
    private let presentation: VideoSharePresentation
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var ownedDirectory: URL?

    private(set) var isPreparing = false
    private(set) var lastPresentedURLForTesting: URL?

    init(
        preparer: ShareArtifactPreparer,
        presenter: UIViewController,
        shareButton: UIBarButtonItem,
        presentation: VideoSharePresentation? = nil,
        preparingChanged: @escaping (Bool) -> Void,
        sourceUnavailable: @escaping () -> Void
    ) {
        self.preparer = preparer
        self.shareButton = shareButton
        self.presentation = presentation ?? .live(presenter: presenter)
        self.preparingChanged = preparingChanged
        self.sourceUnavailable = sourceUnavailable
        spinner.hidesWhenStopped = true
    }

    func start(_ request: SharePreparationRequest) {
        guard task == nil, isPreparing == false else { return }

        generation &+= 1
        let token = generation
        setPreparing(true)
        let started = ContinuousClock.now
        Log.share.notice("phase=prepare outcome=start source=\(request.sourceURL.lastPathComponent, privacy: .public)")

        task = Task { [weak self, preparer] in
            do {
                let artifact = try await preparer.prepare(request)
                guard let self else {
                    Self.removeOwnedDirectory(artifact.ownedDirectory)
                    return
                }
                guard Task.isCancelled == false, self.generation == token, self.isPreparing else {
                    Self.removeOwnedDirectory(artifact.ownedDirectory)
                    return
                }

                self.ownedDirectory = artifact.ownedDirectory
                let elapsed = started.duration(to: .now)
                Log.share.notice(
                    "phase=prepare outcome=\(artifact.ownedDirectory == nil ? "fallback" : "cloned", privacy: .public) duration=\(String(describing: elapsed), privacy: .public)"
                )
                if artifact.ownedDirectory == nil {
                    Log.share.notice("phase=prepare outcome=raw_url_fallback")
                }
                self.present(artifact, token: token)
            } catch is CancellationError {
                Log.share.notice("phase=prepare outcome=cancelled")
                self?.finish(token: token)
            } catch {
                let elapsed = started.duration(to: .now)
                Log.share.error(
                    "phase=prepare outcome=unavailable duration=\(String(describing: elapsed), privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                guard let self, self.generation == token, self.isPreparing else { return }
                self.finish(token: token)
                self.sourceUnavailable()
            }
        }
    }

    func cancel() {
        guard task != nil || isPreparing || ownedDirectory != nil else { return }
        generation &+= 1
        task?.cancel()
        task = nil
        removeOwnedDirectory()
        setPreparing(false)
        Log.share.notice("phase=prepare outcome=cancelled")
    }

    private func present(_ artifact: PreparedShareArtifact, token: UInt64) {
        let initializationStarted = ContinuousClock.now
        lastPresentedURLForTesting = artifact.url
        presentation.present(artifact.url, shareButton, { [weak self] in
            self?.finish(token: token)
        }, { [weak self] in
            self?.removeOwnedDirectory()
        })
        let elapsed = initializationStarted.duration(to: .now)
        Log.share.notice(
            "phase=sheet_init duration=\(String(describing: elapsed), privacy: .public)"
        )
    }

    private func finish(token: UInt64) {
        guard generation == token else { return }
        task = nil
        setPreparing(false)
    }

    private func setPreparing(_ preparing: Bool) {
        guard isPreparing != preparing else { return }
        isPreparing = preparing
        if preparing {
            spinner.startAnimating()
            shareButton.customView = spinner
            spinner.accessibilityLabel = "Preparing video"
        } else {
            spinner.stopAnimating()
            shareButton.customView = nil
        }
        preparingChanged(preparing)
    }

    private func removeOwnedDirectory() {
        Self.removeOwnedDirectory(ownedDirectory)
        ownedDirectory = nil
    }

    nonisolated private static func removeOwnedDirectory(_ directory: URL?) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
