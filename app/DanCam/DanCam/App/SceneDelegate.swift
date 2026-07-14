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
        let homeViewController = HomeViewController(dependencies: dependencies, store: appStore)
        let homeNavigationController = UINavigationController(rootViewController: homeViewController)
        homeNavigationController.tabBarItem = UITabBarItem(
            title: "Home",
            image: UIImage(systemName: "house"),
            tag: 0
        )

        let debugViewController = DebugViewController(dependencies: dependencies, store: appStore)
        let debugNavigationController = UINavigationController(rootViewController: debugViewController)
        debugNavigationController.tabBarItem = UITabBarItem(
            title: "Debug",
            image: UIImage(systemName: "waveform.path.ecg"),
            tag: 1
        )

        let settingsViewController = SettingsViewController(dependencies: dependencies, store: appStore)
        let settingsNavigationController = UINavigationController(rootViewController: settingsViewController)
        settingsNavigationController.tabBarItem = UITabBarItem(
            title: "Settings",
            image: UIImage(systemName: "gearshape"),
            tag: 2
        )

        let shell = AppShellViewController(
            tabs: [homeNavigationController, debugNavigationController, settingsNavigationController],
            store: appStore
        )

        window.rootViewController = shell
        self.window = window
        self.appStore = appStore
        self.shell = shell
        window.makeKeyAndVisible()
        homeViewController.loadViewIfNeeded()
        appStore.send(.streamStarted)
        appStore.send(.foregrounded)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        if let appStore {
            appStore.send(.streamStarted)
            appStore.send(.foregrounded)
            Log.reducer.notice("snapshot \(appStore.state.logSnapshot, privacy: .public)")
        }
        (shell?.topViewController as? ConnectionResumable)?.resumeLiveWork()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        appStore?.send(.streamStopped)
    }
}
