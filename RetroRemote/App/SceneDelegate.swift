import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        ThemeManager.shared.window = window
        window.rootViewController = RootViewController()
        window.makeKeyAndVisible()
        self.window = window
        ThemeManager.shared.apply()
        Preferences.shared.applyIdleTimer()
        HardwareVolume.shared.onPress = { key in ConnectionManager.shared.press(key) }
        Preferences.shared.applyHardwareVolume(window: window)
        ConnectionManager.shared.activateSelected()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        ThemeManager.shared.refresh()
        ConnectionManager.shared.reconnect()
        HardwareVolume.shared.refresh()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        ConnectionManager.shared.suspend()
    }
}
