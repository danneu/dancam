import UIKit

final class AppShellViewController: UIViewController {
    private let embeddedNavigationController: UINavigationController
    private let store: AppStore
    private let strip = ConnectionStatusStripView()

    private var observation: StoreObservation?
    private var previousConnectivity: ConnectionFeature.Connectivity?

    init(
        navigationController: UINavigationController,
        store: AppStore
    ) {
        embeddedNavigationController = navigationController
        self.store = store
        super.init(nibName: nil, bundle: nil)
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

        observation = store.observe(\.connection.connectivity) { [weak self] connectivity in
            self?.render(connectivity)
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

    private func render(_ connectivity: ConnectionFeature.Connectivity) {
        strip.configure(ConnectionCoordination.presentation(for: connectivity))

        if let previousConnectivity,
           ConnectionCoordination.shouldResumeLiveWork(
               from: previousConnectivity,
               to: connectivity
           ) {
            (embeddedNavigationController.topViewController as? ConnectionResumable)?.resumeLiveWork()
        }

        previousConnectivity = connectivity
    }
}
