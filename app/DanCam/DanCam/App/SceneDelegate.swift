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
        let tabs = Self.makeTabs(dependencies: dependencies, store: appStore)
        let homeViewController = (tabs[0].viewControllers.first as? HomeViewController)

        let shell = AppShellViewController(tabs: tabs, store: appStore)

        window.rootViewController = shell
        self.window = window
        self.appStore = appStore
        self.shell = shell
        window.makeKeyAndVisible()
        homeViewController?.loadViewIfNeeded()
        appStore.send(.streamStarted)
        appStore.send(.foregrounded)
    }

    static func makeTabs(dependencies: AppDependencies, store appStore: AppStore) -> [UINavigationController] {
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
            tag: 2
        )

        let incidentsViewController = IncidentsViewController(dependencies: dependencies, store: appStore)
        let incidentsNavigationController = UINavigationController(rootViewController: incidentsViewController)
        incidentsNavigationController.tabBarItem = UITabBarItem(
            title: "Incidents",
            image: UIImage(systemName: "exclamationmark.triangle"),
            tag: 1
        )

        let settingsViewController = SettingsViewController(dependencies: dependencies, store: appStore)
        let settingsNavigationController = UINavigationController(rootViewController: settingsViewController)
        settingsNavigationController.tabBarItem = UITabBarItem(
            title: "Settings",
            image: UIImage(systemName: "gearshape"),
            tag: 3
        )

        return [
            homeNavigationController,
            incidentsNavigationController,
            debugNavigationController,
            settingsNavigationController,
        ]
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
        appStore?.send(.backgrounded)
        appStore?.send(.streamStopped)
    }
}
