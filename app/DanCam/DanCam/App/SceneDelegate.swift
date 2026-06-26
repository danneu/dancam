import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var connectionStore: Store<ConnectionFeature.State, ConnectionFeature.Action, AppDependencies>?
    private var indicatorCoordinator: ConnectionIndicatorCoordinator?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let dependencies = AppDependencies.live
        let connectionStore = Store(
            initialState: ConnectionFeature.State(),
            dependencies: dependencies,
            reduce: ConnectionFeature.reduce
        )
        let window = UIWindow(windowScene: windowScene)
        let rootViewController = HomeViewController(dependencies: dependencies, monitor: connectionStore)
        let navigationController = UINavigationController(rootViewController: rootViewController)
        let indicatorCoordinator = ConnectionIndicatorCoordinator(store: connectionStore)

        window.rootViewController = navigationController
        self.window = window
        self.connectionStore = connectionStore
        self.indicatorCoordinator = indicatorCoordinator
        window.makeKeyAndVisible()
        rootViewController.loadViewIfNeeded()
        indicatorCoordinator.attach(to: navigationController)
        connectionStore.send(.start)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        connectionStore?.send(.start)
        topViewController()?.resumeLiveWork()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        connectionStore?.send(.stop)
    }

    private func topViewController() -> ConnectionResumable? {
        let navigationController = window?.rootViewController as? UINavigationController
        return navigationController?.topViewController as? ConnectionResumable
    }
}
