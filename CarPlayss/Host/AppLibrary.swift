import SwiftUI
import UIKit
import ZIPFoundation

/// Un'app CarPlay installata in CarPlayss.
final class GuestApp: Identifiable, Equatable {
    enum Source: String {
        case embedded = "Incorporata nella build"
        case imported = "Installata da IPA"
    }

    let id: String
    let name: String
    let version: String
    let bundleURL: URL
    let source: Source
    let report: CarPlayCompatibility.Report
    private(set) lazy var icon: UIImage? = GuestApp.loadIcon(bundleURL: bundleURL)

    init(bundleURL: URL, source: Source, report: CarPlayCompatibility.Report) {
        let info = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
        self.bundleURL = bundleURL
        self.source = source
        self.report = report
        id = info["CFBundleIdentifier"] as? String ?? bundleURL.deletingPathExtension().lastPathComponent
        name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bundleURL.deletingPathExtension().lastPathComponent
        version = info["CFBundleShortVersionString"] as? String ?? ""
    }

    static func == (lhs: GuestApp, rhs: GuestApp) -> Bool { lhs.id == rhs.id }

    private static func loadIcon(bundleURL: URL) -> UIImage? {
        let info = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
        var names: [String] = []
        // CarPlay usa prima l'icona dedicata (CFBundleIcons~carplay), poi quella principale.
        for key in ["CFBundleIcons~carplay", "CFBundleIcons", "CFBundleIcons~ipad"] {
            if let icons = info[key] as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
                if let n = primary["CFBundleIconName"] as? String { names.append(n) }
                if let files = primary["CFBundleIconFiles"] as? [String] { names.append(contentsOf: files.reversed()) }
            }
        }
        names.append(contentsOf: ["AppIcon", "AppIcon60x60", "Icon-60", "Icon"])
        let bundle = Bundle(url: bundleURL)
        for n in names {
            if let bundle = bundle, let img = UIImage(named: n, in: bundle, compatibleWith: nil) { return img }
            for suffix in ["@3x.png", "@2x.png", ".png"] {
                let url = bundleURL.appendingPathComponent(n + suffix)
                if let img = UIImage(contentsOfFile: url.path) { return img }
            }
        }
        if let files = try? FileManager.default.contentsOfDirectory(atPath: bundleURL.path) {
            for f in files.sorted(by: >) where f.hasPrefix("AppIcon") && f.hasSuffix(".png") {
                if let img = UIImage(contentsOfFile: bundleURL.appendingPathComponent(f).path) { return img }
            }
        }
        return nil
    }
}

/// Verifica che un'app sia compatibile con CarPlay.
enum CarPlayCompatibility {
    struct Report {
        let compatible: Bool
        let reason: String
        let sceneDelegateClass: String?
        let categories: [String]
        let encrypted: Bool
    }

    static let categoryNames: [String: String] = [
        "audio": "Audio",
        "communication": "Comunicazione",
        "maps": "Navigazione",
        "navigation": "Navigazione",
        "charging": "Ricarica EV",
        "fueling": "Carburante",
        "parking": "Parcheggi",
        "quick-ordering": "Ordini rapidi",
        "driving-task": "Attività di guida",
        "public-safety": "Sicurezza stradale",
        "messaging": "Messaggi",
        "calling": "Chiamate",
        "voip": "Chiamate VoIP"
    ]

    static func evaluate(appURL: URL) -> Report {
        let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]

        // 1. Scene CarPlay dichiarata nell'Info.plist (iOS 14+)
        var sceneDelegate: String?
        if let manifest = info["UIApplicationSceneManifest"] as? [String: Any],
           let configs = manifest["UISceneConfigurations"] as? [String: Any],
           let carplay = configs["CPTemplateApplicationSceneSessionRoleApplication"] as? [[String: Any]],
           let first = carplay.first {
            sceneDelegate = first["UISceneDelegateClassName"] as? String ?? ""
        }

        // 2. Entitlement com.apple.developer.carplay-* (firma del codice o profilo)
        var text = ""
        var encrypted = false
        if let exec = info["CFBundleExecutable"] as? String,
           let data = try? Data(contentsOf: appURL.appendingPathComponent(exec), options: .mappedIfSafe) {
            let bytes = [UInt8](data)
            encrypted = MachO.isEncrypted(bytes)
            text += MachO.signatureText(bytes)
        }
        if let prov = try? Data(contentsOf: appURL.appendingPathComponent("embedded.mobileprovision")) {
            text += String(decoding: prov, as: UTF8.self)
        }
        var categories: [String] = []
        let marker = "com.apple.developer.carplay-"
        var searchRange = text.startIndex..<text.endIndex
        while let r = text.range(of: marker, range: searchRange) {
            var end = r.upperBound
            while end < text.endIndex, text[end].isLetter || text[end] == "-" { end = text.index(after: end) }
            let key = String(text[r.upperBound..<end])
            let label = categoryNames[key] ?? key
            if !key.isEmpty && !categories.contains(label) { categories.append(label) }
            searchRange = end..<text.endIndex
        }

        if encrypted {
            return Report(compatible: false, reason: "L'IPA è criptata (App Store). Serve un'IPA decriptata.",
                          sceneDelegateClass: sceneDelegate, categories: categories, encrypted: true)
        }
        if sceneDelegate != nil {
            return Report(compatible: true, reason: "Scena CarPlay dichiarata",
                          sceneDelegateClass: sceneDelegate?.isEmpty == true ? nil : sceneDelegate,
                          categories: categories, encrypted: false)
        }
        if !categories.isEmpty {
            return Report(compatible: true, reason: "Entitlement CarPlay presente",
                          sceneDelegateClass: nil, categories: categories, encrypted: false)
        }
        return Report(compatible: false, reason: "L'app non supporta CarPlay (nessuna scena o entitlement CarPlay).",
                      sceneDelegateClass: nil, categories: [], encrypted: false)
    }
}

enum LibraryError: LocalizedError {
    case noApp
    case incompatible(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noApp: return "Nessuna app trovata nell'IPA (manca Payload/*.app)."
        case .incompatible(let r): return "Non installata: \(r)"
        case .failed(let m): return m
        }
    }
}

/// Elenco delle app CarPlay installate: incorporate nella build (CarPlayApps/) o importate da IPA.
final class AppLibrary: ObservableObject {
    @Published private(set) var apps: [GuestApp] = []
    @Published private(set) var isImporting = false
    @Published var message: String?

    private let fm = FileManager.default

    var importedDirectory: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("CarPlayApps", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var embeddedDirectory: URL {
        CPSHooks.hostBundle.bundleURL.appendingPathComponent("CarPlayApps", isDirectory: true)
    }

    init() {
        reload()
    }

    func app(id: String) -> GuestApp? {
        apps.first { $0.id == id }
    }

    func reload() {
        var result: [GuestApp] = []
        for (dir, source) in [(embeddedDirectory, GuestApp.Source.embedded), (importedDirectory, .imported)] {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in items where url.pathExtension == "app" {
                let report = CarPlayCompatibility.evaluate(appURL: url)
                guard report.compatible else { continue }
                let app = GuestApp(bundleURL: url, source: source, report: report)
                if !result.contains(app) { result.append(app) }
            }
        }
        apps = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func importIPA(from url: URL) {
        isImporting = true
        message = "Installazione in corso…"
        let destinationRoot = importedDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<String, Error>
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                result = .success(try Self.install(ipa: url, into: destinationRoot))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                self.isImporting = false
                switch result {
                case .success(let name):
                    self.message = "\(name) installata."
                case .failure(let error):
                    self.message = error.localizedDescription
                }
                self.reload()
            }
        }
    }

    private static func install(ipa: URL, into root: URL) throws -> String {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ipa-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // Copia locale (il file scelto può stare su iCloud o in un'altra app)
        let localIPA = work.appendingPathComponent("app.ipa")
        do { try fm.copyItem(at: ipa, to: localIPA) } catch { throw LibraryError.failed("Impossibile leggere l'IPA: \(error.localizedDescription)") }

        let extracted = work.appendingPathComponent("x", isDirectory: true)
        do { try fm.unzipItem(at: localIPA, to: extracted) } catch { throw LibraryError.failed("IPA non valida: \(error.localizedDescription)") }

        let payload = extracted.appendingPathComponent("Payload", isDirectory: true)
        guard let appURL = (try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else { throw LibraryError.noApp }

        let report = CarPlayCompatibility.evaluate(appURL: appURL)
        guard report.compatible else { throw LibraryError.incompatible(report.reason) }

        // Le estensioni e le app Watch non servono in CarPlay
        for extra in ["PlugIns", "Extensions", "Watch", "AppClips", "com.apple.WatchPlaceholder"] {
            try? fm.removeItem(at: appURL.appendingPathComponent(extra))
        }

        let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Info.plist")) as? [String: Any] ?? [:]
        guard let exec = info["CFBundleExecutable"] as? String else { throw LibraryError.failed("Info.plist senza CFBundleExecutable.") }
        do { try MachO.patch(fileAt: appURL.appendingPathComponent(exec)) } catch {
            throw LibraryError.failed("Patch dell'eseguibile non riuscita: \(error.localizedDescription)")
        }

        let bundleID = info["CFBundleIdentifier"] as? String ?? UUID().uuidString
        let destination = root.appendingPathComponent("\(bundleID).app", isDirectory: true)
        try? fm.removeItem(at: destination)
        do { try fm.moveItem(at: appURL, to: destination) } catch { throw LibraryError.failed(error.localizedDescription) }

        return (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bundleID
    }

    func delete(_ app: GuestApp) {
        guard app.source == .imported else { return }
        try? fm.removeItem(at: app.bundleURL)
        reload()
        message = "\(app.name) rimossa. Riavvia CarPlayss se era già stata aperta."
    }
}
