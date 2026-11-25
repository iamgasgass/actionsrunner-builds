import UIKit

final class SettingsViewController: StyledTableViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Impostazioni"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: DeviceStore.didChange, object: nil)
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuild()
    }

    @objc private func rebuild() {
        let prefs = Preferences.shared
        let mode = ThemeManager.shared.mode
        let style = InterfaceStyle.current
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let quick = prefs.quickAppNames.isEmpty ? "Nessuna" : prefs.quickAppNames.joined(separator: ", ")
        sections = [
            TableSection(header: "Interfaccia",
                         footer: "Puoi cambiare interfaccia anche dal menu «…» della schermata principale.",
                         rows: InterfaceStyle.allCases.map { s in
                             TableRow(title: s.title, accessory: s == style ? .checkmark : .none, onSelect: {
                                 Preferences.shared.interfaceStyle = s
                             })
                         }),
            TableSection(header: "Aspetto",
                         footer: "«Automatico» segue la modalità scura impostata in iOS.",
                         rows: AppearanceMode.allCases.map { m in
                             TableRow(title: m.title, accessory: m == mode ? .checkmark : .none, onSelect: { [weak self] in
                                 ThemeManager.shared.mode = m
                                 self?.rebuild()
                             })
                         }),
            TableSection(header: "Feedback", rows: [
                TableRow(title: "Vibrazione", toggle: prefs.haptics, onToggle: { prefs.haptics = $0 }),
                TableRow(title: "Suono dei tasti", toggle: prefs.clicks, onToggle: { prefs.clicks = $0 })
            ]),
            TableSection(header: "Accesso rapido",
                         footer: "Le app scelte compaiono sotto il telecomando per aprirle con un tocco.",
                         rows: [
                             TableRow(title: "App rapide", value: quick, accessory: .chevron, onSelect: { [weak self] in
                                 self?.navigationController?.pushViewController(QuickAccessViewController(), animated: true)
                             })
                         ]),
            TableSection(header: "Dispositivi", rows: [
                TableRow(title: "Riconnetti all'ultima TV", toggle: prefs.autoReconnect, onToggle: { prefs.autoReconnect = $0 }),
                TableRow(title: "Gestisci le TV", value: "\(DeviceStore.shared.devices.count)", accessory: .chevron,
                         onSelect: { [weak self] in
                             self?.navigationController?.pushViewController(DevicesViewController(), animated: true)
                         }),
                TableRow(title: "Dimentica le associazioni", style: .destructive, onSelect: { [weak self] in
                    self?.confirmForget()
                })
            ]),
            TableSection(header: "Telecomando",
                         footer: "Con «Tasti volume iPhone» i tasti laterali regolano il volume della TV mentre l'app è aperta.",
                         rows: [
                             TableRow(title: "Digitazione dal vivo", toggle: prefs.liveTyping, onToggle: { prefs.liveTyping = $0 }),
                             TableRow(title: "Tasti volume iPhone", toggle: prefs.hardwareVolume, onToggle: { prefs.hardwareVolume = $0 }),
                             TableRow(title: "Schermo intero", toggle: prefs.hideStatusBar, onToggle: { prefs.hideStatusBar = $0 }),
                             TableRow(title: "Schermo sempre attivo", toggle: prefs.keepAwake, onToggle: { prefs.keepAwake = $0 })
                         ]),
            TableSection(header: "Informazioni",
                         footer: "RetroRemote comunica solo con le TV della tua rete locale e non raccoglie dati. Non è affiliato con i produttori delle TV; i marchi appartengono ai rispettivi proprietari.",
                         rows: [
                             TableRow(title: "Versione", value: "\(version) (\(build))"),
                             TableRow(title: "TV compatibili", value: "\(TVBrand.allCases.count) piattaforme", accessory: .chevron,
                                      onSelect: { [weak self] in
                                          self?.navigationController?.pushViewController(SupportedTVsViewController(), animated: true)
                                      })
                         ])
        ]
    }

    private func confirmForget() {
        let alert = StyledAlert(title: "Dimenticare le associazioni?",
                                message: "Le TV chiederanno di nuovo l'autorizzazione alla prossima connessione.")
        alert.addAction("Annulla", style: .cancel)
        alert.addAction("Dimentica", style: .destructive) { _ in
            DeviceStore.shared.forgetAllPairings()
            ConnectionManager.shared.activateSelected(connect: false)
        }
        alert.show(from: self)
    }
}

/// Scelta delle app della riga di accesso rapido (massimo 3).
final class QuickAccessViewController: StyledTableViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        title = "App rapide"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuild()
    }

    private func rebuild() {
        let selected = Preferences.shared.quickAppNames
        sections = [
            TableSection(header: "Scegli fino a 3 app",
                         footer: "Se ne scegli una quarta, viene tolta la prima della lista. L'avvio dipende dal supporto della TV.",
                         rows: QuickApps.names.map { name in
                             let index = selected.firstIndex(of: name)
                             return TableRow(title: name, value: index.map { "\($0 + 1)" },
                                             accessory: index != nil ? .checkmark : .none,
                                             onSelect: { [weak self] in self?.toggle(name) })
                         })
        ]
    }

    private func toggle(_ name: String) {
        var list = Preferences.shared.quickAppNames
        if let index = list.firstIndex(of: name) {
            list.remove(at: index)
        } else {
            list.append(name)
            if list.count > 3 { list.removeFirst() }
        }
        Preferences.shared.quickAppNames = list
        Feedback.selection()
        rebuild()
    }
}
