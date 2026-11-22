import Foundation

/// Diagnostica e modalità sicura per le app CarPlay che fanno chiudere CarPlayss.
///
/// Prima di ogni fase di caricamento viene salvata la fase corrente: se al riavvio è ancora presente,
/// l'ultima apertura si è chiusa lì. Le fasi opzionali (AppDelegate, Dashboard) vengono saltate
/// automaticamente al tentativo successivo, e il rapporto del crash viene mostrato all'utente.
enum CrashGuard {
    enum Phase: String {
        case patch = "preparazione dell'eseguibile"
        case dlopen = "caricamento del codice (inizializzatori statici, tweak, framework)"
        case appDelegate = "AppDelegate dell'app (application:didFinishLaunchingWithOptions:)"
        case carplay = "collegamento della scena CarPlay"
        case dashboard = "collegamento della Dashboard CarPlay"
        case running = "esecuzione (subito dopo l'avvio)"
    }

    struct Record {
        let appID: String
        let appName: String
        let phase: String
        let report: String
    }

    private static let defaults = UserDefaults.standard
    private static let phaseKey = "cps.crashguard.phase"
    private static var crashFile: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("CarPlayss-crash.txt")
    }

    /// Crash dell'avvio precedente, per app.
    private(set) static var records: [String: Record] = [:]

    /// Da chiamare all'avvio di CarPlayss, prima di caricare qualsiasi app.
    static func start() {
        let report = (try? String(contentsOf: crashFile, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: crashFile)

        if let pending = defaults.dictionary(forKey: phaseKey) as? [String: String],
           let appID = pending["app"], let phaseRaw = pending["phase"] {
            let phase = Phase(rawValue: phaseRaw)
            switch phase {
            case .appDelegate?: setSkip(.appDelegate, appID, true)
            case .dashboard?: setSkip(.dashboard, appID, true)
            default: break
            }
            records[appID] = Record(appID: appID, appName: pending["name"] ?? appID, phase: phaseRaw,
                                    report: report.isEmpty ? "Nessun dettaglio registrato (crash Swift o chiusura forzata dal sistema)." : report)
        }
        defaults.removeObject(forKey: phaseKey)
        CPSCrashReporter.install(path: crashFile.path)
    }

    static func begin(_ phase: Phase, app: GuestApp) {
        defaults.set(["app": app.id, "name": app.name, "phase": phase.rawValue], forKey: phaseKey)
        defaults.synchronize()
        CPSCrashReporter.setContext("App: \(app.name) (\(app.id)) \(app.version)\nFase: \(phase.rawValue)\nCarPlayss \(hostVersion)")
    }

    /// L'app è partita: se resta in vita qualche secondo la fase "running" viene azzerata.
    static func finished(app: GuestApp) {
        begin(.running, app: app)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            if let pending = defaults.dictionary(forKey: phaseKey) as? [String: String], pending["app"] == app.id {
                defaults.removeObject(forKey: phaseKey)
            }
            CPSCrashReporter.setContext("App in esecuzione: \(app.name) (\(app.id))\nCarPlayss \(hostVersion)")
        }
    }

    /// Caricamento fallito senza crash (errore gestito).
    static func failed(app: GuestApp) {
        defaults.removeObject(forKey: phaseKey)
    }

    static func clearRecord(_ appID: String) {
        records[appID] = nil
    }

    // MARK: Modalità sicura per app

    enum Skip: String {
        case appDelegate
        case dashboard
    }

    static func skip(_ what: Skip, _ appID: String) -> Bool {
        defaults.bool(forKey: "cps.skip.\(what.rawValue).\(appID)")
    }

    static func setSkip(_ what: Skip, _ appID: String, _ value: Bool) {
        defaults.set(value, forKey: "cps.skip.\(what.rawValue).\(appID)")
    }

    static func resetSafeMode(_ appID: String) {
        setSkip(.appDelegate, appID, false)
        setSkip(.dashboard, appID, false)
    }

    private static var hostVersion: String {
        CPSHooks.hostBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}
