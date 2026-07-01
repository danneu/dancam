import OSLog
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var appStore: AppStore?
    private var shell: AppShellViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let dependencies = AppDependencies.live
        let appStore = AppStore(
            initialState: AppFeature.State(),
            dependencies: dependencies,
            reduce: AppFeature.reduce,
            log: AppFeature.logTransition
        )
        Log.reducer.notice("snapshot \(appStore.state.logSnapshot, privacy: .public)")

        let window = UIWindow(windowScene: windowScene)
        let rootViewController = HomeViewController(dependencies: dependencies, store: appStore)
        let navigationController = UINavigationController(rootViewController: rootViewController)
        let shell = AppShellViewController(
            navigationController: navigationController,
            store: appStore
        )

        window.rootViewController = shell
        self.window = window
        self.appStore = appStore
        self.shell = shell
        window.makeKeyAndVisible()
        rootViewController.loadViewIfNeeded()
        appStore.send(.streamStarted)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        if let appStore {
            appStore.send(.streamStarted)
            Log.reducer.notice("snapshot \(appStore.state.logSnapshot, privacy: .public)")
        }
        (shell?.topViewController as? ConnectionResumable)?.resumeLiveWork()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        appStore?.send(.streamStopped)
    }
}
