import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var connectionStore: Store<ConnectionFeature.State, ConnectionFeature.Action, AppDependencies>?
    private var shell: AppShellViewController?

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
        let shell = AppShellViewController(
            navigationController: navigationController,
            monitor: connectionStore
        )

        window.rootViewController = shell
        self.window = window
        self.connectionStore = connectionStore
        self.shell = shell
        window.makeKeyAndVisible()
        rootViewController.loadViewIfNeeded()
        connectionStore.send(.start)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        connectionStore?.send(.start)
        (shell?.topViewController as? ConnectionResumable)?.resumeLiveWork()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        connectionStore?.send(.stop)
    }
}
