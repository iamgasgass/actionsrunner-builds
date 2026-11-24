import UIKit

final class SettingsViewController: ClassicTableViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        title = "Impostazioni"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuild()
    }

    private func rebuild() {
        let prefs = Preferences.shared
        let mode = ThemeManager.shared.mode
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        sections = [
            TableSection(header: "Aspetto",
                         footer: "«Automatico» segue la modalità scura impostata in iOS.",
                         rows: AppearanceMode.allCases.map { m in
                             TableRow(title: m.title, accessory: m == mode ? .checkmark : .none, onSelect: { [weak self] in
                                 ThemeManager.shared.mode = m
                                 self?.rebuild()
                             })
                         }),
            TableSection(header: "Telecomando",
                         footer: "«Schermo intero» nasconde la barra di stato. Con «Tasti volume iPhone» i tasti laterali regolano il volume della TV mentre l'app è aperta.",
                         rows: [
                             TableRow(title: "Vibrazione", toggle: prefs.haptics, onToggle: { prefs.haptics = $0 }),
                             TableRow(title: "Clic dei tasti", toggle: prefs.clicks, onToggle: { prefs.clicks = $0 }),
                             TableRow(title: "Schermo intero", toggle: prefs.hideStatusBar, onToggle: { prefs.hideStatusBar = $0 }),
                             TableRow(title: "Schermo sempre attivo", toggle: prefs.keepAwake, onToggle: { prefs.keepAwake = $0 }),
                             TableRow(title: "Tasti volume iPhone", toggle: prefs.hardwareVolume, onToggle: { prefs.hardwareVolume = $0 })
                         ]),
            TableSection(header: "Informazioni",
                         footer: "RetroRemote non è affiliato con i produttori delle TV. I marchi appartengono ai rispettivi proprietari.",
                         rows: [
                             TableRow(title: "Versione", value: "\(version) (\(build))"),
                             TableRow(title: "TV compatibili", value: "\(TVBrand.allCases.count) piattaforme", accessory: .chevron,
                                      onSelect: { [weak self] in
                                          self?.navigationController?.pushViewController(SupportedTVsViewController(), animated: true)
                                      })
                         ])
        ]
    }
}
