import UIKit

/// Elenco delle piattaforme supportate con le istruzioni di configurazione.
final class SupportedTVsViewController: ClassicTableViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        title = "TV compatibili"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func viewDidLoad() {
        super.viewDidLoad()
        sections = TVBrand.allCases.map { brand in
            var features: [String] = ["Telecomando"]
            let sample = QuickApps.apps(for: brand)
            if !sample.isEmpty { features.append("App rapide") }
            switch brand {
            case .samsung, .lg, .roku, .fireTV: features.append("Tastiera e voce")
            case .androidTV: features.append("Ricerca vocale su YouTube")
            default: break
            }
            if brand == .lg { features.append("Mouse") }
            return TableSection(header: brand.displayName, footer: brand.setupNotes,
                                rows: [TableRow(title: features.joined(separator: " · "), style: .placeholder)])
        }
    }
}
