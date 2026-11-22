import CarPlay
import MediaPlayer
import SwiftUI
import UIKit

enum GuestError: LocalizedError {
    case invalidBundle
    case patch(String)
    case load(String)
    case signing(String)
    case noCarPlayEntry

    var errorDescription: String? {
        switch self {
        case .invalidBundle:
            return "Bundle dell'app non valido."
        case .patch(let m):
            return "Impossibile preparare l'eseguibile: \(m)"
        case .load(let m):
            return "Caricamento non riuscito.\n\n\(m)"
        case .signing(let m):
            return "Il codice dell'app non è firmato e non è stato possibile firmarlo.\n\n\(m)\n\nSu iOS 26 LiveContainer non permette di caricare codice non firmato nemmeno con JIT: serve la modalità JIT-less (certificato importato in LiveContainer). In alternativa metti l'IPA nella cartella EmbeddedApps del repository e ricompila."
        case .noCarPlayEntry:
            return "L'app non ha un delegato di scena CarPlay (CPTemplateApplicationSceneDelegate)."
        }
    }
}

/// Sessione CarPlay di un'app ospite: controller, scena, finestra dell'auto e stato UI.
final class GuestSession: ObservableObject, Identifiable {
    let app: GuestApp
    let controller: CPSInterfaceController
    let scene: CPSTemplateApplicationScene
    let window: UIWindow
    var sceneDelegate: NSObject?
    var appDelegate: NSObject?
    var usesWindow = false

    // Dashboard CarPlay (app di navigazione con CPTemplateApplicationDashboardSceneDelegate)
    var dashboardController: CPSDashboardController?
    var dashboardScene: CPSDashboardScene?
    var dashboardWindow: UIWindow?
    var dashboardDelegate: NSObject?

    @Published var tick = 0
    @Published var selectedTab = 0
    @Published var lastError: String?
    @Published var selectedTrip = 0
    @Published var selectedRoute = 0
    @Published var selectedPOI: Int?
    @Published var searchText = ""
    @Published var searchResults: [CPListItem] = []

    private var timer: Timer?
    private var observer: NSObjectProtocol?

    var id: String { app.id }

    init(app: GuestApp) {
        self.app = app
        controller = CPSInterfaceController.make()
        window = CPSObjC.makeCarWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        scene = CPSTemplateApplicationScene.make(controller: controller, window: window)
        controller.cps_onChange = { [weak self] in self?.refresh() }
        observer = NotificationCenter.default.addObserver(forName: .cpsStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        // I template possono cambiare senza notifiche (updateSections, setText...): aggiornamento periodico.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick &+= 1
        }
    }

    deinit {
        timer?.invalidate()
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        tick &+= 1
    }

    var stack: [CPTemplate] { controller.cps_stack }
    var top: CPTemplate? { stack.last }
    var presented: CPTemplate? { controller.cps_presented }

    /// Esegue codice dell'app ospite intercettando le eccezioni Objective-C.
    func guest(_ label: String, _ block: () -> Void) {
        if let error = CPSObjC.catching(block) {
            lastError = "\(label): \(error)"
        }
        refresh()
    }

    func back() {
        guest("Indietro") { controller.cps_userPop() }
    }

    func dismissPresented() {
        guest("Chiudi") { controller.cps_userDismiss() }
    }

    func tap(handlerOf object: AnyObject, label: String = "Azione") {
        guard let handler = CPSObjC.handler(of: object) else { return }
        guest(label) { CPSObjC.invoke(block: handler, object: object) }
    }

    func select(_ item: CPSelectableListItem) {
        guard let handler = item.handler else { return }
        guest("Selezione") { handler(item) {} }
    }
}

/// Carica le app CarPlay nel processo e le collega a una scena CarPlay simulata.
final class GuestRuntime: ObservableObject {
    @Published private(set) var sessions: [String: GuestSession] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var loading: Set<String> = []

    var runAppDelegate = true

    func launch(_ app: GuestApp) {
        guard sessions[app.id] == nil, !loading.contains(app.id) else { return }
        loading.insert(app.id)
        errors[app.id] = nil
        DispatchQueue.main.async {
            self.attempt(app, allowSigning: true)
        }
    }

    private func attempt(_ app: GuestApp, allowSigning: Bool) {
        do {
            let session = try load(app)
            sessions[app.id] = session
            loading.remove(app.id)
        } catch GuestError.load(let message) where message.contains("code signature") || message.contains("signature") {
            guard allowSigning else {
                errors[app.id] = GuestError.signing(message).localizedDescription
                loading.remove(app.id)
                return
            }
            // Firma con il certificato di LiveContainer e riprova una volta.
            CPSLiveContainer.signApp(atPath: app.bundleURL.path) { [weak self] ok, error in
                guard let self = self else { return }
                if ok {
                    self.attempt(app, allowSigning: false)
                } else {
                    self.errors[app.id] = GuestError.signing(error ?? message).localizedDescription
                    self.loading.remove(app.id)
                }
            }
        } catch {
            errors[app.id] = error.localizedDescription
            loading.remove(app.id)
        }
    }

    func retry(_ app: GuestApp) {
        errors[app.id] = nil
        launch(app)
    }

    private func load(_ app: GuestApp) throws -> GuestSession {
        guard let bundle = Bundle(url: app.bundleURL), let exec = bundle.executableURL else {
            throw GuestError.invalidBundle
        }

        // Patch sempre (è idempotente): corregge anche app importate con versioni precedenti di CarPlayss.
        // Se il file cambia la firma non è più valida: dlopen fallisce e l'app viene rifirmata qui sotto.
        do {
            try MachO.patchBundle(at: app.bundleURL, executableName: exec.lastPathComponent)
        } catch {
            if (try? MachO.needsPatch(exec)) == true { throw GuestError.patch(error.localizedDescription) }
        }

        // Da qui il codice che chiede Bundle.main riceve il bundle dell'app ospite (come LiveContainer).
        CPSHooks.markGuestEpoch()
        CPSHooks.guestBundle = bundle

        // Come LiveContainer: @executable_path dell'app ospite deve puntare al suo eseguibile, non a CarPlayss
        // (tweak e dylib iniettati come libsubstrate.dylib vengono cercati lì).
        CPSLiveContainer.setExecutablePath(exec.path)

        guard dlopen(exec.path, RTLD_LAZY | RTLD_GLOBAL) != nil else {
            let message = dlerror().map { String(cString: $0) } ?? "errore sconosciuto"
            throw GuestError.load(message)
        }

        let classNames = CPSObjC.classNames(inImageAtPath: exec.path)
        let session = GuestSession(app: app)

        // AppDelegate dell'app: molte app CarPlay preparano player, database e SDK qui.
        let appDelegateProto = NSProtocolFromString("UIApplicationDelegate")
        let sceneProto = NSProtocolFromString("UISceneDelegate")
        if runAppDelegate, let proto = appDelegateProto {
            let candidates = classNames.compactMap { NSClassFromString($0) }.filter { cls in
                CPSObjC.isClass(cls, conformingTo: proto) && !(sceneProto.map { CPSObjC.isClass(cls, conformingTo: $0) } ?? false)
            }
            if let cls = candidates.first {
                session.guest("AppDelegate") {
                    if let delegate = CPSObjC.instantiate(cls) as? NSObject {
                        session.appDelegate = delegate
                        _ = CPSObjC.sendLaunch(delegate, NSSelectorFromString("application:willFinishLaunchingWithOptions:"), application: UIApplication.shared)
                        _ = CPSObjC.sendLaunch(delegate, NSSelectorFromString("application:didFinishLaunchingWithOptions:"), application: UIApplication.shared)
                        CPSObjC.send(delegate, NSSelectorFromString("applicationDidBecomeActive:"), UIApplication.shared)
                    }
                }
            }
        }

        // Delegato della scena CarPlay
        var delegateClass: AnyClass?
        if let name = app.report.sceneDelegateClass {
            delegateClass = NSClassFromString(name)
        }
        if delegateClass == nil, let proto = NSProtocolFromString("CPTemplateApplicationSceneDelegate") {
            delegateClass = classNames.compactMap { NSClassFromString($0) }.first { CPSObjC.isClass($0, conformingTo: proto) }
        }

        if let cls = delegateClass {
            var connectError: String?
            connectError = CPSObjC.catching {
                guard let delegate = CPSObjC.instantiate(cls) as? NSObject else { return }
                session.sceneDelegate = delegate
                session.scene.cps_delegate = delegate
                let withWindow = NSSelectorFromString("templateApplicationScene:didConnectInterfaceController:toWindow:")
                let plain = NSSelectorFromString("templateApplicationScene:didConnectInterfaceController:")
                CPSObjC.send(delegate, NSSelectorFromString("sceneWillEnterForeground:"), session.scene)
                if delegate.responds(to: withWindow) {
                    session.usesWindow = true
                    CPSObjC.send(delegate, withWindow, session.scene, session.controller, session.window)
                } else {
                    CPSObjC.send(delegate, plain, session.scene, session.controller)
                }
                CPSObjC.send(delegate, NSSelectorFromString("sceneDidBecomeActive:"), session.scene)
            }
            if let error = connectError { session.lastError = "Connessione CarPlay: \(error)" }
        } else if let delegate = session.appDelegate,
                  delegate.responds(to: NSSelectorFromString("application:didConnectCarInterfaceController:toWindow:")) {
            // API CarPlay precedente a iOS 14 (CPApplicationDelegate)
            session.usesWindow = true
            session.guest("Connessione CarPlay") {
                CPSObjC.send(delegate, NSSelectorFromString("application:didConnectCarInterfaceController:toWindow:"),
                             UIApplication.shared, session.controller, session.window)
            }
        } else {
            throw GuestError.noCarPlayEntry
        }

        connectDashboard(session, bundle: bundle, classNames: classNames)
        return session
    }

    /// Collega la scena Dashboard di CarPlay, se l'app la dichiara.
    private func connectDashboard(_ session: GuestSession, bundle: Bundle, classNames: [String]) {
        var cls: AnyClass?
        if let manifest = bundle.infoDictionary?["UIApplicationSceneManifest"] as? [String: Any],
           let configs = manifest["UISceneConfigurations"] as? [String: Any],
           let dash = (configs["CPTemplateApplicationDashboardSceneSessionRoleApplication"] as? [[String: Any]])?.first,
           let name = dash["UISceneDelegateClassName"] as? String {
            cls = NSClassFromString(name)
        }
        if cls == nil, let proto = NSProtocolFromString("CPTemplateApplicationDashboardSceneDelegate") {
            cls = classNames.compactMap { NSClassFromString($0) }.first { CPSObjC.isClass($0, conformingTo: proto) }
        }
        guard let delegateClass = cls else { return }
        let controller = CPSDashboardController.make()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 480, height: 400))
        window.backgroundColor = .black
        window.overrideUserInterfaceStyle = .dark
        window.isHidden = false
        let scene = CPSDashboardScene.make(controller: controller, window: window)
        let error = CPSObjC.catching {
            guard let delegate = CPSObjC.instantiate(delegateClass) as? NSObject else { return }
            session.dashboardDelegate = delegate
            scene.cps_delegate = delegate
            CPSObjC.send(delegate, NSSelectorFromString("sceneWillEnterForeground:"), scene)
            CPSObjC.send(delegate, NSSelectorFromString("templateApplicationDashboardScene:didConnectDashboardController:toWindow:"),
                         scene, controller, window)
            CPSObjC.send(delegate, NSSelectorFromString("sceneDidBecomeActive:"), scene)
        }
        if let error = error {
            session.lastError = "Dashboard: \(error)"
            return
        }
        session.dashboardController = controller
        session.dashboardScene = scene
        session.dashboardWindow = window
    }

    /// Giorno/notte dell'auto: CarPlay lo comunica alle scene con contentStyleDidChange:.
    func contentStyleChanged(dark: Bool) {
        let style: UIUserInterfaceStyle = dark ? .dark : .light
        for session in sessions.values {
            session.controller.prefersDarkUserInterfaceStyle = dark
            session.window.overrideUserInterfaceStyle = style
            session.dashboardWindow?.overrideUserInterfaceStyle = style
            for delegate in [session.sceneDelegate, session.dashboardDelegate].compactMap({ $0 }) {
                session.guest("Tema") {
                    CPSObjC.send(delegate, NSSelectorFromString("contentStyleDidChange:"), integer: style.rawValue)
                }
            }
        }
    }
}

// MARK: - Comandi remoti dell'app ospite (Now Playing)

enum GuestRemote {
    static var center: MPRemoteCommandCenter { MPRemoteCommandCenter.shared() }

    static var nowPlayingInfo: [String: Any] { MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:] }

    static var isPlaying: Bool {
        (nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0) > 0
    }

    static func togglePlayPause() {
        if CPSHooks.invoke(center.togglePlayPauseCommand) { return }
        if isPlaying { _ = CPSHooks.invoke(center.pauseCommand) } else { _ = CPSHooks.invoke(center.playCommand) }
    }

    static func next() {
        if CPSHooks.invoke(center.nextTrackCommand) { return }
        _ = CPSHooks.invoke(center.skipForwardCommand)
    }

    static func previous() {
        if CPSHooks.invoke(center.previousTrackCommand) { return }
        _ = CPSHooks.invoke(center.skipBackwardCommand)
    }

    static var usesSkipIntervals: Bool {
        !CPSHooks.hasGuestHandler(for: center.nextTrackCommand) && CPSHooks.hasGuestHandler(for: center.skipForwardCommand)
    }
}
