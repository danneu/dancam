import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private weak var runtime: AppRuntime?
    private var shell: AppShellViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard
            let windowScene = scene as? UIWindowScene,
            let appDelegate = UIApplication.shared.delegate as? AppDelegate
        else { return }
        let appRuntime = appDelegate.runtime
        let appStore = appRuntime.store

        let window = UIWindow(windowScene: windowScene)
        let tabs = Self.makeTabs(dependencies: appRuntime.dependencies, store: appStore)
        let homeViewController = (tabs[0].viewControllers.first as? HomeViewController)

        let shell = AppShellViewController(tabs: tabs, store: appStore)

        window.rootViewController = shell
        self.window = window
        self.runtime = appRuntime
        self.shell = shell
        window.makeKeyAndVisible()
        homeViewController?.loadViewIfNeeded()
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
        runtime?.activateScene(id: scene.session.persistentIdentifier)
        (shell?.topViewController as? ConnectionResumable)?.resumeLiveWork()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        runtime?.deactivateScene(id: scene.session.persistentIdentifier)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        runtime?.deactivateScene(id: scene.session.persistentIdentifier)
    }
}
