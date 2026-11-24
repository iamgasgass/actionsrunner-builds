import UIKit

private final class FooterButtonContainer: UIView {
    let button: UIControl

    init(button: UIControl) {
        self.button = button
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 90))
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = ClassicCell.sideInset(for: bounds.width)
        button.frame = CGRect(x: inset, y: 14, width: bounds.width - inset * 2, height: 46)
    }
}

final class DeviceDetailViewController: ClassicTableViewController {
    private let deviceID: UUID

    init(deviceID: UUID) {
        self.deviceID = deviceID
        super.init(nibName: nil, bundle: nil)
        title = DeviceStore.shared.device(id: deviceID)?.name ?? "TV"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let delete = ClassicBigButton(title: "Elimina TV")
        delete.addTarget(self, action: #selector(confirmDelete), for: .touchUpInside)
        tableView.tableFooterView = FooterButtonContainer(button: delete)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(rebuild), name: DeviceStore.didChange, object: nil)
        center.addObserver(self, selector: #selector(rebuild), name: ConnectionManager.stateDidChange, object: nil)
        rebuild()
    }

    @objc private func rebuild() {
        guard let device = DeviceStore.shared.device(id: deviceID) else { return }
        navBar.title = device.name
        let isSelected = DeviceStore.shared.selectedID == deviceID
        var result = [
            TableSection(rows: [
                TableRow(title: "Nome", value: device.name, accessory: .chevron, onSelect: { [weak self] in self?.rename() }),
                TableRow(title: "Indirizzo IP", value: device.host),
                TableRow(title: "Tipo", value: device.brand.displayName),
                TableRow(title: "Modello", value: device.model ?? "—"),
                TableRow(title: "Indirizzo MAC", value: device.mac ?? "Aggiungi", accessory: .chevron,
                         onSelect: { [weak self] in self?.editMAC() })
            ]),
            TableSection(footer: isSelected ? "Stato: \(ConnectionManager.shared.state.label)" : nil, rows: [
                TableRow(title: isSelected ? "Riconnetti" : "Usa questa TV", style: .button, onSelect: {
                    if isSelected {
                        ConnectionManager.shared.reconnect()
                    } else {
                        DeviceStore.shared.select(device.id)
                    }
                })
            ])
        ]
        if device.mac != nil {
            result.append(TableSection(footer: "Accende la TV dallo standby di rete (Wake-on-LAN), se la funzione è attiva sulla TV.", rows: [
                TableRow(title: "Accendi la TV", style: .button, onSelect: { ConnectionManager.shared.wake(device) })
            ]))
        }
        if device.token != nil {
            result.append(TableSection(footer: "La TV chiederà di nuovo l'autorizzazione alla prossima connessione.", rows: [
                TableRow(title: "Annulla associazione", style: .button, onSelect: { [weak self] in self?.forgetPairing() })
            ]))
        }
        sections = result
    }

    private func rename() {
        guard let device = DeviceStore.shared.device(id: deviceID) else { return }
        let alert = ClassicAlertController(title: "Rinomina", message: nil)
        alert.addTextField(placeholder: "Nome", text: device.name)
        alert.addAction("Annulla", style: .cancel)
        alert.addAction("Salva") { a in
            let name = (a.textFields.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, var updated = DeviceStore.shared.device(id: device.id) else { return }
            updated.name = name
            DeviceStore.shared.update(updated)
        }
        alert.show(from: self)
    }

    private func editMAC() {
        guard let device = DeviceStore.shared.device(id: deviceID) else { return }
        let alert = ClassicAlertController(title: "Indirizzo MAC",
                                           message: "Serve per accendere la TV via rete. Lo trovi nelle impostazioni di rete della TV.")
        alert.addTextField(placeholder: "AA:BB:CC:DD:EE:FF", text: device.mac, keyboard: .asciiCapable,
                           capitalization: .allCharacters)
        alert.addAction("Annulla", style: .cancel)
        alert.addAction("Salva") { [weak self] a in
            guard let self = self else { return }
            let value = (a.textFields.first?.text ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            DeviceStore.shared.updateMAC(id: self.deviceID, mac: value.isEmpty ? nil : value)
        }
        alert.show(from: self)
    }

    private func forgetPairing() {
        DeviceStore.shared.updateToken(id: deviceID, token: nil)
        if DeviceStore.shared.selectedID == deviceID { ConnectionManager.shared.activateSelected() }
        rebuild()
    }

    @objc private func confirmDelete() {
        let alert = ClassicAlertController(title: "Eliminare la TV?",
                                           message: "Potrai aggiungerla di nuovo in qualsiasi momento.")
        alert.addAction("Annulla", style: .cancel)
        alert.addAction("Elimina") { [weak self] _ in
            guard let self = self else { return }
            DeviceStore.shared.remove(id: self.deviceID)
            self.navigationController?.popViewController(animated: true)
        }
        alert.show(from: self)
    }
}
