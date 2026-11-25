import Foundation

final class DeviceStore {
    static let shared = DeviceStore()
    static let didChange = Notification.Name("RetroRemote.DeviceStoreDidChange")
    static let selectionDidChange = Notification.Name("RetroRemote.DeviceSelectionDidChange")

    private(set) var devices: [TVDevice] = []
    private(set) var selectedID: UUID?

    private let devicesKey = "devices.v1"
    private let selectedKey = "devices.selected"

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: devicesKey),
           let decoded = try? JSONDecoder().decode([TVDevice].self, from: data) {
            devices = decoded
        }
        if let raw = defaults.string(forKey: selectedKey) { selectedID = UUID(uuidString: raw) }
        if selected == nil { selectedID = devices.first?.id }
    }

    var selected: TVDevice? { devices.first { $0.id == selectedID } }

    func device(id: UUID) -> TVDevice? { devices.first { $0.id == id } }

    func isSaved(_ d: TVDevice) -> Bool {
        devices.contains { $0.host == d.host && $0.brand == d.brand }
    }

    func add(_ device: TVDevice, select: Bool) {
        if let existing = devices.first(where: { $0.host == device.host && $0.brand == device.brand }) {
            if existing.mac == nil, let mac = device.mac { updateMAC(id: existing.id, mac: mac) }
            if select { self.select(existing.id) }
            return
        }
        devices.append(device)
        save()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        if select || devices.count == 1 { self.select(device.id) }
    }

    func update(_ device: TVDevice) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index] = device
        save()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func updateToken(id: UUID, token: String?) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].token = token
        save()
    }

    func updateMAC(id: UUID, mac: String?) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].mac = mac
        save()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Cancella i token/chiavi di associazione di tutte le TV.
    func forgetAllPairings() {
        for index in devices.indices { devices[index].token = nil }
        save()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func remove(id: UUID) {
        devices.removeAll { $0.id == id }
        let wasSelected = selectedID == id
        save()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        if wasSelected { select(devices.first?.id) }
    }

    func select(_ id: UUID?) {
        selectedID = id
        save()
        NotificationCenter.default.post(name: Self.selectionDidChange, object: nil)
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(devices) { defaults.set(data, forKey: devicesKey) }
        defaults.set(selectedID?.uuidString, forKey: selectedKey)
    }
}
