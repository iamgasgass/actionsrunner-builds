import Foundation

/// Tiene il controller della TV selezionata e ne diffonde lo stato.
final class ConnectionManager {
    static let shared = ConnectionManager()
    static let stateDidChange = Notification.Name("RetroRemote.ConnectionStateDidChange")

    private(set) var controller: BaseController?

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
            }
            c.onStateChange = { _ in
                NotificationCenter.default.post(name: ConnectionManager.stateDidChange, object: nil)
            }
            let id = device.id
            c.onTokenUpdate = { token in DeviceStore.shared.updateToken(id: id, token: token) }
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
        controller?.send(key)
    }
}
