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
            "hardwareVolume": false,
            "autoReconnect": true,
            "liveTyping": true,
            "interfaceStyle": InterfaceStyle.liquidGlass.rawValue,
            "lastMode": 0,
            "quickApps": ["Netflix", "YouTube", "Prime Video"]
        ])
    }

    // MARK: - Interfaccia

    var interfaceStyle: InterfaceStyle {
        get { InterfaceStyle(rawValue: defaults.string(forKey: "interfaceStyle") ?? "") ?? .liquidGlass }
        set {
            guard newValue != interfaceStyle else { return }
            defaults.set(newValue.rawValue, forKey: "interfaceStyle")
            NotificationCenter.default.post(name: InterfaceStyle.didChange, object: nil)
        }
    }

    /// Ultima modalità del telecomando (tasti, touchpad, tastierino, app, testo).
    var lastMode: Int {
        get { defaults.integer(forKey: "lastMode") }
        set { defaults.set(newValue, forKey: "lastMode") }
    }

    // MARK: - Feedback

    var haptics: Bool {
        get { defaults.bool(forKey: "haptics") }
        set { defaults.set(newValue, forKey: "haptics"); notify() }
    }

    var clicks: Bool {
        get { defaults.bool(forKey: "clicks") }
        set { defaults.set(newValue, forKey: "clicks"); notify() }
    }

    // MARK: - Telecomando

    /// "Schermo intero": nasconde la barra di stato.
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

    /// Si collega da solo all'ultima TV usata all'avvio dell'app.
    var autoReconnect: Bool {
        get { defaults.bool(forKey: "autoReconnect") }
        set { defaults.set(newValue, forKey: "autoReconnect"); notify() }
    }

    /// Ogni carattere digitato viene inviato subito alla TV.
    var liveTyping: Bool {
        get { defaults.bool(forKey: "liveTyping") }
        set { defaults.set(newValue, forKey: "liveTyping"); notify() }
    }

    /// App mostrate nella riga di accesso rapido (massimo 3).
    var quickAppNames: [String] {
        get { defaults.stringArray(forKey: "quickApps") ?? [] }
        set { defaults.set(Array(newValue.prefix(3)), forKey: "quickApps"); notify() }
    }

    func applyHardwareVolume(window: UIWindow? = nil) {
        if hardwareVolume {
            if let target = window ?? ThemeManager.shared.window { HardwareVolume.shared.start(in: target) }
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
