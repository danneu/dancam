import OSLog
import UIKit

final class AppShellViewController: UIViewController {
    private let embeddedTabBarController: UITabBarController
    private let store: AppStore
    private let strip = StatusStripView()

    private var observation: StoreObservation?
    private var previousLinkPhase: StripCoordination.LinkPhase?

    init(
        tabs: [UINavigationController],
        store: AppStore
    ) {
        embeddedTabBarController = UITabBarController()
        embeddedTabBarController.setViewControllers(tabs, animated: false)
        self.store = store
        super.init(nibName: nil, bundle: nil)
        embeddedTabBarController.delegate = self
        for tab in tabs {
            tab.delegate = self
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AppShellViewController is programmatic.")
    }

    var topViewController: UIViewController? {
        (embeddedTabBarController.selectedViewController as? UINavigationController)?.topViewController
    }

    override var childForStatusBarStyle: UIViewController? {
        embeddedTabBarController
    }

    override var childForStatusBarHidden: UIViewController? {
        embeddedTabBarController
    }

    override var childForHomeIndicatorAutoHidden: UIViewController? {
        embeddedTabBarController
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        addChild(embeddedTabBarController)
        configureViews()
        embeddedTabBarController.didMove(toParent: self)

        observation = store.observe(select: StripCoordination.project) { [weak self] projection in
            self?.render(projection)
        }
    }

    private func configureViews() {
        embeddedTabBarController.view.translatesAutoresizingMaskIntoConstraints = false
        strip.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(embeddedTabBarController.view)
        view.addSubview(strip)

        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            strip.topAnchor.constraint(equalTo: view.topAnchor),

            embeddedTabBarController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            embeddedTabBarController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            embeddedTabBarController.view.topAnchor.constraint(equalTo: strip.bottomAnchor),
            embeddedTabBarController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
            (topViewController as? ConnectionResumable)?.resumeLiveWork()
        }

        previousLinkPhase = projection.linkPhase
    }

    var stripForTesting: StatusStripView {
        strip
    }

    func selectTabForTesting(_ index: Int) {
        embeddedTabBarController.selectedIndex = index
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

extension AppShellViewController: UITabBarControllerDelegate {
    func tabBarController(
        _ tabBarController: UITabBarController,
        didSelect viewController: UIViewController
    ) {
        let screen = (viewController as? UINavigationController)?.topViewController ?? viewController
        Log.nav.notice("tab=\(viewController.tabBarItem.title ?? "?", privacy: .public) screen=\(String(describing: type(of: screen)), privacy: .public)")
    }
}
