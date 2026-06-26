import UIKit

final class ConnectionIndicatorCoordinator: NSObject, UINavigationControllerDelegate {
    private let store: Store<ConnectionFeature.State, ConnectionFeature.Action, AppDependencies>
    private let pill: StatusPillView
    private let item: UIBarButtonItem

    private weak var navigationController: UINavigationController?
    private weak var decoratedViewController: UIViewController?
    private var observation: StoreObservation?
    private var currentConnectivity: ConnectionFeature.Connectivity?

    init(store: Store<ConnectionFeature.State, ConnectionFeature.Action, AppDependencies>) {
        self.store = store
        let pill = StatusPillView()
        self.pill = pill
        item = UIBarButtonItem(customView: pill)
        super.init()

        observation = store.observe { [weak self] state in
            self?.render(state)
        }
    }

    func attach(to navigationController: UINavigationController) {
        self.navigationController = navigationController
        navigationController.delegate = self
        decorate(navigationController.topViewController)
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        decorate(viewController)
    }

    private func render(_ state: ConnectionFeature.State) {
        let previous = currentConnectivity
        let next = state.connectivity

        pill.configure(
            caption: ConnectionCoordination.caption(for: next),
            dotColor: dotColor(for: next),
            backgroundStyle: .material
        )

        if let previous,
           previous == .disconnected,
           ConnectionCoordination.didReconnect(from: previous, to: next) {
            (navigationController?.topViewController as? ConnectionResumable)?.resumeLiveWork()
        }

        currentConnectivity = next
    }

    private func decorate(_ viewController: UIViewController?) {
        guard let viewController else { return }
        if decoratedViewController === viewController {
            appendItem(to: viewController.navigationItem)
            return
        }

        if let decoratedViewController {
            removeItem(from: decoratedViewController.navigationItem)
        }

        decoratedViewController = viewController
        appendItem(to: viewController.navigationItem)
    }

    private func appendItem(to navigationItem: UINavigationItem) {
        var items = navigationItem.rightBarButtonItems
            ?? navigationItem.rightBarButtonItem.map { [$0] }
            ?? []

        items.removeAll { $0 === item }
        items.append(item)
        navigationItem.rightBarButtonItems = items
    }

    private func removeItem(from navigationItem: UINavigationItem) {
        var items = navigationItem.rightBarButtonItems
            ?? navigationItem.rightBarButtonItem.map { [$0] }
            ?? []

        items.removeAll { $0 === item }
        navigationItem.rightBarButtonItems = items.isEmpty ? nil : items
    }

    private func dotColor(for connectivity: ConnectionFeature.Connectivity) -> UIColor {
        switch connectivity {
        case .connecting:
            .secondaryLabel
        case .connected:
            .systemGreen
        case .disconnected:
            .systemRed
        }
    }
}
