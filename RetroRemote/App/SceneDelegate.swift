import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        ThemeManager.shared.window = window
        window.rootViewController = Self.makeRoot()
        window.makeKeyAndVisible()
        self.window = window
        ThemeManager.shared.apply()
        Preferences.shared.applyIdleTimer()
        HardwareVolume.shared.onPress = { key in ConnectionManager.shared.press(key) }
        Preferences.shared.applyHardwareVolume(window: window)
        ConnectionManager.shared.activateSelected(connect: Preferences.shared.autoReconnect)
        NotificationCenter.default.addObserver(self, selector: #selector(styleChanged),
                                               name: InterfaceStyle.didChange, object: nil)
    }

    /// Radice dell'interfaccia nello stile scelto (Liquid Glass o iOS 6).
    static func makeRoot() -> UIViewController {
        let home = HomeViewController()
        if InterfaceStyle.isGlass {
            return GlassNavigationController(rootViewController: home)
        }
        return ClassicNavigationController(rootViewController: home)
    }

    /// Cambio di interfaccia dal menu "…": ricostruisce l'interfaccia con una dissolvenza.
    @objc private func styleChanged() {
        guard let window = window else { return }
        let root = Self.makeRoot()
        UIView.transition(with: window, duration: 0.4, options: [.transitionCrossDissolve, .allowAnimatedContent], animations: {
            window.rootViewController = root
        }, completion: { _ in
            ThemeManager.shared.apply()
        })
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        ThemeManager.shared.refresh()
        ConnectionManager.shared.resume()
        HardwareVolume.shared.refresh()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        ConnectionManager.shared.suspend()
    }
}
