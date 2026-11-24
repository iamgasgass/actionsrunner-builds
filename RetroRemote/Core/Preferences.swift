import UIKit

final class Preferences {
    static let shared = Preferences()
    static let didChange = Notification.Name("RetroRemote.PreferencesDidChange")

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "haptics": true,
            "clicks": true,
            "hideStatusBar": false,
            "keepAwake": false,
            "hardwareVolume": false
        ])
    }

    var haptics: Bool {
        get { defaults.bool(forKey: "haptics") }
        set { defaults.set(newValue, forKey: "haptics"); notify() }
    }

    var clicks: Bool {
        get { defaults.bool(forKey: "clicks") }
        set { defaults.set(newValue, forKey: "clicks"); notify() }
    }

    /// "Schermo intero": nasconde la barra di stato e lascia l'interfaccia iOS 6 a tutto schermo.
    var hideStatusBar: Bool {
        get { defaults.bool(forKey: "hideStatusBar") }
        set { defaults.set(newValue, forKey: "hideStatusBar"); notify() }
    }

    var keepAwake: Bool {
        get { defaults.bool(forKey: "keepAwake") }
        set { defaults.set(newValue, forKey: "keepAwake"); applyIdleTimer(); notify() }
    }

    /// I tasti volume dell'iPhone regolano il volume della TV.
    var hardwareVolume: Bool {
        get { defaults.bool(forKey: "hardwareVolume") }
        set { defaults.set(newValue, forKey: "hardwareVolume"); applyHardwareVolume(); notify() }
    }

    func applyHardwareVolume(window: UIWindow? = nil) {
        if hardwareVolume {
            let target = window ?? ThemeManager.shared.window
            if let target = target { HardwareVolume.shared.start(in: target) }
        } else {
            HardwareVolume.shared.stop()
        }
    }

    func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}
