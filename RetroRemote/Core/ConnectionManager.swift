import Foundation

/// Tiene il controller della TV selezionata e ne diffonde lo stato.
final class ConnectionManager {
    static let shared = ConnectionManager()
    static let stateDidChange = Notification.Name("RetroRemote.ConnectionStateDidChange")

    private(set) var controller: BaseController?

    /// Impostato dall'interfaccia: mostra la richiesta del codice di associazione.
    var pinPrompt: ((_ title: String, _ message: String, _ hex: Bool, _ reply: @escaping (String?) -> Void) -> Void)?

    var state: ConnectionState { controller?.state ?? .idle }

    private init() {
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged),
                                               name: DeviceStore.selectionDidChange, object: nil)
    }

    @objc private func selectionChanged() { activateSelected() }

    func activateSelected() {
        if let old = controller {
            old.onStateChange = nil
            old.onTokenUpdate = nil
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
            c.connect()
        }
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
    }

    func reconnect() {
        if let c = controller { c.connect() } else { activateSelected() }
    }

    func suspend() {
        controller?.disconnect()
    }

    func press(_ key: RemoteKey) {
        if key == .power, state != .connected, let device = DeviceStore.shared.selected,
           let mac = device.mac, !mac.isEmpty {
            wake(device)
            return
        }
        controller?.send(key)
    }

    /// Accende la TV con Wake-on-LAN e poi si riconnette.
    func wake(_ device: TVDevice) {
        guard let mac = device.mac else { return }
        WakeOnLAN.send(mac: mac, host: device.host)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.reconnect() }
    }
}
