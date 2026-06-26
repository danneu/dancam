import UIKit

final class AppShellViewController: UIViewController {
    private let embeddedNavigationController: UINavigationController
    private let monitor: Store<ConnectionFeature.State, ConnectionFeature.Action, AppDependencies>
    private let strip = ConnectionStatusStripView()

    private var observation: StoreObservation?
    private var previousConnectivity: ConnectionFeature.Connectivity?

    init(
        navigationController: UINavigationController,
        monitor: Store<ConnectionFeature.State, ConnectionFeature.Action, AppDependencies>
    ) {
        embeddedNavigationController = navigationController
        self.monitor = monitor
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

        observation = monitor.observe { [weak self] state in
            self?.render(state)
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

    private func render(_ state: ConnectionFeature.State) {
        strip.configure(ConnectionCoordination.presentation(for: state.connectivity))

        if let previousConnectivity,
           ConnectionCoordination.shouldResumeLiveWork(
               from: previousConnectivity,
               to: state.connectivity
           ) {
            (embeddedNavigationController.topViewController as? ConnectionResumable)?.resumeLiveWork()
        }

        previousConnectivity = state.connectivity
    }
}
