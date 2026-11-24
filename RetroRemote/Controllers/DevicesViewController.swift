import UIKit

final class DevicesViewController: ClassicTableViewController {
    private let scanButton = ClassicBarButton(symbol: "arrow.clockwise")
    private let addButton = ClassicBarButton(symbol: "plus")
    private let scanner = NetworkScanner()
    private var found: [TVDevice] = []
    private var scanning = false
    private var didScan = false
    private var scanTask: Task<Void, Never>?

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Dispositivi"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func viewDidLoad() {
        super.viewDidLoad()
        scanButton.addTarget(self, action: #selector(startScan), for: .touchUpInside)
        addButton.addTarget(self, action: #selector(addManually), for: .touchUpInside)
        navBar.leftView = scanButton
        navBar.rightView = addButton
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(rebuild), name: DeviceStore.didChange, object: nil)
        center.addObserver(self, selector: #selector(rebuild), name: DeviceStore.selectionDidChange, object: nil)
        center.addObserver(self, selector: #selector(rebuild), name: ConnectionManager.stateDidChange, object: nil)
        rebuild()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didScan && !scanning { startScan() }
    }

    @objc private func rebuild() {
        let store = DeviceStore.shared
        let state = ConnectionManager.shared.state
        var saved = store.devices.map { device -> TableRow in
            let isSelected = device.id == store.selectedID
            return TableRow(title: device.name,
                            value: isSelected ? state.shortLabel : device.brand.shortName,
                            accessory: .detail,
                            onSelect: { [weak self] in
                                store.select(device.id)
                                if isSelected { ConnectionManager.shared.reconnect() }
                                self?.rootController?.selectTab(0)
                            },
                            onDetail: { [weak self] in
                                self?.navigationController?.pushViewController(DeviceDetailViewController(deviceID: device.id), animated: true)
                            })
        }
        if saved.isEmpty {
            saved = [TableRow(title: "Nessun dispositivo", style: .placeholder)]
        }
        var result = [TableSection(header: "Le mie TV",
                                   footer: "Tocca una TV per usarla. iPhone e TV devono essere collegati alla stessa rete Wi-Fi.",
                                   rows: saved)]

        let newOnes = found.filter { !store.isSaved($0) }
        if scanning || didScan {
            var rows = newOnes.map { device in
                TableRow(title: device.name, value: device.brand.shortName, accessory: .chevron, onSelect: { [weak self] in
                    DeviceStore.shared.add(device, select: true)
                    self?.rootController?.selectTab(0)
                })
            }
            if rows.isEmpty {
                rows = [TableRow(title: scanning ? "Ricerca in corso…" : "Nessuna nuova TV trovata", style: .placeholder)]
            }
            result.append(TableSection(header: "Trovate in rete",
                                       footer: scanning ? nil : "Compatibili: Samsung, LG, Roku, Android TV / Google TV (Sony, Philips, TCL, Hisense, Xiaomi…), Fire TV, VIZIO e Panasonic. Se la TV non compare, aggiungila a mano con +.",
                                       rows: rows,
                                       headerSpinner: scanning))
        }
        sections = result
    }

    @objc private func startScan() {
        guard !scanning else { return }
        scanning = true
        scanButton.isSpinning = true
        found = []
        rebuild()
        scanTask = Task { [weak self] in
            guard let scanner = self?.scanner else { return }
            await scanner.scan { device in
                guard let self = self else { return }
                if let index = self.found.firstIndex(where: { $0.host == device.host && $0.brand == device.brand }) {
                    // Bonjour fornisce il nome reale: sostituisce quello generico della scansione
                    if Self.genericNames.contains(self.found[index].name) && !Self.genericNames.contains(device.name) {
                        self.found[index].name = device.name
                        self.rebuild()
                    }
                } else {
                    self.found.append(device)
                    self.rebuild()
                }
            }
            guard let self = self else { return }
            self.scanning = false
            self.didScan = true
            self.scanButton.isSpinning = false
            self.rebuild()
        }
    }

    private static let genericNames: Set<String> = ["Android TV", "Fire TV", "VIZIO TV", "LG webOS TV"]

    @objc private func addManually() {
        let alert = ClassicAlertController(title: "Aggiungi TV", message: "Scegli il tipo di TV.")
        for brand in TVBrand.allCases {
            alert.addAction(brand.displayName) { [weak self] _ in self?.askAddress(for: brand) }
        }
        alert.addAction("Annulla", style: .cancel)
        alert.show(from: self)
    }

    private func askAddress(for brand: TVBrand) {
        let alert = ClassicAlertController(title: brand.displayName,
                                           message: "Inserisci l'indirizzo IP indicato nelle impostazioni di rete della TV.")
        alert.addTextField(placeholder: "Es. 192.168.1.20", keyboard: .numbersAndPunctuation)
        alert.addTextField(placeholder: "Nome (facoltativo)")
        alert.addAction("Annulla", style: .cancel)
        alert.addAction("Aggiungi") { [weak self] a in
            let host = (a.textFields[0].text ?? "").trimmingCharacters(in: .whitespaces)
            let name = (a.textFields[1].text ?? "").trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty else { return }
            DeviceStore.shared.add(TVDevice(name: name.isEmpty ? brand.displayName : name, host: host, brand: brand),
                                   select: true)
            self?.rootController?.selectTab(0)
        }
        alert.show(from: self)
    }
}

extension ConnectionState {
    var shortLabel: String {
        switch self {
        case .idle: return "Non connessa"
        case .connecting: return "Connessione…"
        case .pairing: return "In attesa…"
        case .connected: return "Connessa"
        case .failed: return "Errore"
        }
    }
}
