import OSLog
import UIKit

final class AppShellViewController: UIViewController {
    private let embeddedNavigationController: UINavigationController
    private let store: AppStore
    private let strip = StatusStripView()

    private var observation: StoreObservation?
    private var previousLinkPhase: StripCoordination.LinkPhase?

    init(
        navigationController: UINavigationController,
        store: AppStore
    ) {
        embeddedNavigationController = navigationController
        self.store = store
        super.init(nibName: nil, bundle: nil)
        embeddedNavigationController.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AppShellViewController is programmatic.")
    }

    var topViewController: UIViewController? {
        embeddedNavigationController.topViewController
    }

    override var childForStatusBarStyle: UIViewController? {
        embeddedNavigationController
    }

    override var childForStatusBarHidden: UIViewController? {
        embeddedNavigationController
    }

    override var childForHomeIndicatorAutoHidden: UIViewController? {
        embeddedNavigationController
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        addChild(embeddedNavigationController)
        configureViews()
        embeddedNavigationController.didMove(toParent: self)

        observation = store.observe(select: StripCoordination.project) { [weak self] projection in
            self?.render(projection)
        }
    }

    private func configureViews() {
        embeddedNavigationController.view.translatesAutoresizingMaskIntoConstraints = false
        strip.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(embeddedNavigationController.view)
        view.addSubview(strip)

        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            strip.topAnchor.constraint(equalTo: view.topAnchor),

            embeddedNavigationController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            embeddedNavigationController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            embeddedNavigationController.view.topAnchor.constraint(equalTo: strip.bottomAnchor),
            embeddedNavigationController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func render(_ projection: StripCoordination.Projection) {
        strip.configure(
            connection: projection.connection,
            recording: projection.recording
        )

        if let previousLinkPhase,
           StripCoordination.shouldResumeLiveWork(
               from: previousLinkPhase,
               to: projection.linkPhase
           ) {
            (embeddedNavigationController.topViewController as? ConnectionResumable)?.resumeLiveWork()
        }

        previousLinkPhase = projection.linkPhase
    }

    var stripForTesting: StatusStripView {
        strip
    }
}

extension AppShellViewController: UINavigationControllerDelegate {
    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        let name = String(describing: type(of: viewController))
        Log.nav.notice("screen=\(name, privacy: .public)")
    }
}
