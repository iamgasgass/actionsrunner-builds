import Foundation

/// Tiene il controller della TV selezionata e ne diffonde lo stato.
final class ConnectionManager {
    static let shared = ConnectionManager()
    static let stateDidChange = Notification.Name("RetroRemote.ConnectionStateDidChange")

    private(set) var controller: BaseController?
    private var wasConnectedBeforeSuspend = false

    /// Impostato dall'interfaccia: chiede il codice di associazione mostrato sulla TV.
    var pinPrompt: ((_ title: String, _ message: String, _ hex: Bool, _ reply: @escaping (String?) -> Void) -> Void)?

    var state: ConnectionState { controller?.state ?? .idle }
    var isConnected: Bool { state == .connected }

    private init() {
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged),
                                               name: DeviceStore.selectionDidChange, object: nil)
    }

    @objc private func selectionChanged() { activateSelected(connect: true) }

    /// Crea il controller per la TV selezionata; con `connect` avvia subito la connessione.
    func activateSelected(connect: Bool = true) {
        if let old = controller {
            old.onStateChange = nil
            old.onTokenUpdate = nil
            old.onMACUpdate = nil
            old.disconnect()
        }
        controller = nil
        if let device = DeviceStore.shared.selected {
            let c: BaseController
            switch device.brand {
            case .roku: c = RokuController(device: device)
            case .samsung: c = SamsungController(device: device)
            case .lg: c = LGController(device: device)
            case .androidTV: c = AndroidTVController(device: device)
            case .fireTV: c = ADBController(device: device)
            case .vizio: c = VizioController(device: device)
            case .panasonic: c = PanasonicController(device: device)
            }
            c.onStateChange = { _ in
                NotificationCenter.default.post(name: ConnectionManager.stateDidChange, object: nil)
            }
            let id = device.id
            c.onTokenUpdate = { token in DeviceStore.shared.updateToken(id: id, token: token) }
            c.onMACUpdate = { mac in DeviceStore.shared.updateMAC(id: id, mac: mac) }
            controller = c
            if connect { c.connect() }
        }
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    func reconnect() {
        if let c = controller { c.connect() } else { activateSelected(connect: true) }
    }

    func disconnect() {
        controller?.disconnect()
    }

    /// Chiamato quando l'app va in background.
    func suspend() {
        wasConnectedBeforeSuspend = isConnected
        controller?.disconnect()
    }

    /// Chiamato al ritorno in primo piano.
    func resume() {
        if wasConnectedBeforeSuspend || Preferences.shared.autoReconnect { reconnect() }
        wasConnectedBeforeSuspend = false
    }

    func press(_ key: RemoteKey) {
        if key == .power, state != .connected, let device = DeviceStore.shared.selected,
           let mac = device.mac, !mac.isEmpty {
            wake(device)
            return
        }
        if controller == nil, DeviceStore.shared.selected != nil { activateSelected(connect: true) }
        controller?.send(key)
    }

    func launch(_ app: TVApp) {
        Feedback.tap()
        controller?.launch(app)
    }

    /// Accende la TV con Wake-on-LAN e poi si riconnette.
    func wake(_ device: TVDevice) {
        guard let mac = device.mac else { return }
        WakeOnLAN.send(mac: mac, host: device.host)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.reconnect() }
    }
}
