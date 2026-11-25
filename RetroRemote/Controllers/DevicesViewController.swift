import UIKit

/// "Scegli una TV": TV salvate, ricerca in rete e aggiunta manuale.
final class DevicesViewController: StyledTableViewController {
    private let scanner = NetworkScanner()
    private var found: [TVDevice] = []
    private var scanning = false
    private var didScan = false
    private var scanTask: Task<Void, Never>?
    private static let genericNames: Set<String> = ["Android TV", "Fire TV", "VIZIO TV", "LG webOS TV"]

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Scegli una TV"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    deinit { scanTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        setBarButton(.right, symbol: "plus", action: #selector(addManually))
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

    private func close() {
        navigationController?.popToRootViewController(animated: true)
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
                                if isSelected {
                                    if state != .connected { ConnectionManager.shared.reconnect() }
                                } else {
                                    store.select(device.id)
                                }
                                self?.close()
                            },
                            onDetail: { [weak self] in
                                self?.navigationController?.pushViewController(DeviceDetailViewController(deviceID: device.id),
                                                                               animated: true)
                            })
        }
        if saved.isEmpty {
            saved = [TableRow(title: "Nessuna TV salvata", style: .placeholder)]
        }
        var result = [TableSection(header: "Le mie TV",
                                   footer: "Tocca una TV per usarla. iPhone e TV devono essere collegati alla stessa rete Wi-Fi.",
                                   rows: saved)]

        let newOnes = found.filter { !store.isSaved($0) }
        var rows = newOnes.map { device in
            TableRow(title: device.name, value: device.brand.shortName, accessory: .chevron, onSelect: { [weak self] in
                DeviceStore.shared.add(device, select: true)
                self?.close()
            })
        }
        if rows.isEmpty {
            rows = [TableRow(title: scanning ? "Ricerca in corso…" : (didScan ? "Nessuna nuova TV trovata" : "Ricerca non ancora avviata"),
                             style: .placeholder)]
        }
        if !scanning {
            rows.append(TableRow(title: "Cerca di nuovo", style: .button, onSelect: { [weak self] in self?.startScan() }))
        }
        rows.append(TableRow(title: "Aggiungi a mano…", style: .button, onSelect: { [weak self] in self?.addManually() }))
        result.append(TableSection(header: scanning ? "Ricerca in rete…" : "Trovate in rete",
                                   footer: "Compatibili: Samsung, LG, Roku, Android TV / Google TV (Sony, Philips, TCL, Hisense, Xiaomi…), Fire TV, VIZIO e Panasonic.",
                                   rows: rows,
                                   headerSpinner: scanning))
        sections = result
    }

    private func startScan() {
        guard !scanning else { return }
        scanning = true
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
            self.rebuild()
        }
    }

    @objc private func addManually() {
        let alert = StyledAlert(title: "Aggiungi TV", message: "Scegli il tipo di TV.")
        alert.prefersSheet = true
        for brand in TVBrand.allCases {
            alert.addAction(brand.displayName) { [weak self] _ in self?.askAddress(for: brand) }
        }
        alert.addAction("Annulla", style: .cancel)
        alert.show(from: self)
    }

    private func askAddress(for brand: TVBrand) {
        let alert = StyledAlert(title: brand.displayName,
                                message: "Inserisci l'indirizzo IP indicato nelle impostazioni di rete della TV.")
        alert.addTextField(placeholder: "Es. 192.168.1.20", keyboard: .numbersAndPunctuation)
        alert.addTextField(placeholder: "Nome (facoltativo)", capitalization: .words)
        alert.addAction("Annulla", style: .cancel)
        alert.addAction("Aggiungi") { [weak self] a in
            let host = a.value(0)
            let name = a.value(1)
            guard Self.isValidHost(host) else {
                let error = StyledAlert(title: "Indirizzo non valido", message: "Scrivi un indirizzo come 192.168.1.20.")
                error.addAction("OK", style: .cancel)
                if let self = self { error.show(from: self) }
                return
            }
            DeviceStore.shared.add(TVDevice(name: name.isEmpty ? brand.displayName : name, host: host, brand: brand),
                                   select: true)
            self?.close()
        }
        alert.show(from: self)
    }

    /// IPv4 (o nome host locale) senza spazi né schema.
    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, !host.contains(" "), !host.contains("/"), !host.contains(":") else { return false }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) { return true }
        return host.contains(".local") || host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
            && host.contains(where: { $0.isLetter })
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
