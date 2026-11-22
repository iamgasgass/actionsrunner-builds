import CarPlay
import MediaPlayer
import SwiftUI
import UIKit

enum GuestError: LocalizedError {
    case invalidBundle
    case patch(String)
    case load(String)
    case signing(String)
    case needsSigning
    case noCarPlayEntry

    var errorDescription: String? {
        switch self {
        case .invalidBundle:
            return "Bundle dell'app non valido."
        case .patch(let m):
            return "Impossibile preparare l'eseguibile: \(m)"
        case .load(let m):
            return "Caricamento non riuscito.\n\n\(m)"
        case .needsSigning:
            return "Il codice dell'app deve essere firmato."
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

    // Interfaccia "telefono" dell'app (storyboard / scena principale): avviata dietro lo schermo dell'auto
    var phoneWindow: UIWindow?
    var phoneSceneDelegate: NSObject?
    var appKind = "—"

    @Published var tick = 0
    @Published var selectedTab = 0
    @Published var lastError: String?
    @Published var selectedTrip = 0
    @Published var selectedRoute = 0
    @Published var selectedPOI: Int?
    @Published var searchText = ""
    @Published var searchResults: [CPListItem] = []
    /// Diagnostica: cosa è stato chiamato e cosa ha fatto l'app.
    @Published var log: [String] = []
    var delegateClassName = "—"
    var delegateMethods: [String] = []

    func note(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date()))  \(message)")
        if log.count > 60 { log.removeFirst(log.count - 60) }
    }

    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var extraObservers: [NSObjectProtocol] = []

    var id: String { app.id }

    init(app: GuestApp) {
        self.app = app
        controller = CPSInterfaceController.make()
        window = CPSObjC.makeCarWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        scene = CPSTemplateApplicationScene.make(controller: controller, window: window)
        controller.cps_onChange = { [weak self] in self?.refresh() }
        controller.cps_onLog = { [weak self] msg in self?.note("App → \(msg)") }
        // Eventi di React Native (caricamento del JavaScript), utili a capire perché un'app RN non imposta template
        for name in ["RCTJavaScriptWillStartLoadingNotification", "RCTJavaScriptDidLoadNotification",
                     "RCTJavaScriptDidFailToLoadNotification", "RCTContentDidAppearNotification",
                     "RCTInstanceDidLoadBundle", "RCTJavaScriptWillStartExecutingNotification"] {
            let token = NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                var text = "React Native: \(name)"
                if let error = note.userInfo?["error"] as? NSError { text += " — \(error.localizedDescription)" }
                self?.note(text)
            }
            extraObservers.append(token)
        }
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
        captureHostWindows()
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
            CrashGuard.finished(app: app)
            scheduleFallback(session)
            startWindowGuard()
            loading.remove(app.id)
        } catch GuestError.needsSigning {
            guard allowSigning else {
                errors[app.id] = GuestError.signing("La firma non è stata applicata a tutti i file.").localizedDescription
                loading.remove(app.id)
                return
            }
            sign(app, reason: "")
        } catch GuestError.load(let message) where message.contains("code signature") || message.contains("signature") {
            CrashGuard.failed(app: app)
            guard allowSigning else {
                errors[app.id] = GuestError.signing(message).localizedDescription
                loading.remove(app.id)
                return
            }
            sign(app, reason: message)
        } catch {
            errors[app.id] = error.localizedDescription
            loading.remove(app.id)
            CrashGuard.failed(app: app)
        }
    }

    /// Molte app gestiscono CarPlay in scene(_:willConnectTo:options:) (con `scene as? CPTemplateApplicationScene`)
    /// invece che in templateApplicationScene(_:didConnect:). Se dopo 2 s non c'è un template, si prova anche lì.
    private func scheduleFallback(_ session: GuestSession) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard session.stack.isEmpty, let delegate = session.sceneDelegate,
                  !CrashGuard.skip(.fallback, session.app.id) else { return }
            let sel = NSSelectorFromString("scene:willConnectToSession:options:")
            guard delegate.responds(to: sel) else {
                session.note("Nessun template dopo 2 s; il delegato non implementa scene:willConnectToSession:options:")
                return
            }
            session.note("Nessun template dopo 2 s → CarPlayss → scene:willConnectToSession:options:")
            CrashGuard.begin(.fallback, app: session.app)
            session.guest("Avvio alternativo") {
                CPSObjC.send(delegate, sel, session.scene, nil, nil)
                CPSObjC.send(delegate, NSSelectorFromString("sceneWillEnterForeground:"), session.scene)
                CPSObjC.send(delegate, NSSelectorFromString("sceneDidBecomeActive:"), session.scene)
            }
            CrashGuard.finished(app: session.app)
        }
    }

    // MARK: Finestre dell'interfaccia telefono

    private var hostWindows: Set<ObjectIdentifier> = []
    private var windowTimer: Timer?

    /// Finestre esistenti prima di caricare qualsiasi app: sono di CarPlayss.
    func captureHostWindows() {
        guard hostWindows.isEmpty else { return }
        hostWindows = Set(allWindows().map { ObjectIdentifier($0) })
    }

    private func allWindows() -> [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
    }

    /// Le app possono aprire finestre per l'interfaccia del telefono: nell'auto non si vedono, quindi si nascondono.
    private func startWindowGuard() {
        guard windowTimer == nil else { return }
        windowTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.hideForeignWindows()
        }
        hideForeignWindows()
    }

    private func hideForeignWindows() {
        var allowed = hostWindows
        for s in sessions.values {
            allowed.insert(ObjectIdentifier(s.window))

            if let d = s.dashboardWindow { allowed.insert(ObjectIdentifier(d)) }
        }
        // Finestra principale di CarPlayss (livello normale); quelle di sistema (tastiera ecc.) hanno livelli alti.
        let hostWindow = allWindows().first {
            hostWindows.contains(ObjectIdentifier($0)) && !$0.isHidden && $0.windowLevel == .normal
        }
        let behind = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        for window in allWindows() where !allowed.contains(ObjectIdentifier(window)) {
            let name = NSStringFromClass(type(of: window))
            let isSystem = name.hasPrefix("UI") || name.hasPrefix("_UI")
            guard type(of: window) == UIWindow.self || !isSystem else { continue }
            // L'interfaccia telefono dell'app resta attiva (Flutter/SwiftUI/UIKit continuano a lavorare)
            // ma sta dietro lo schermo dell'auto.
            if window.windowLevel != behind { window.windowLevel = behind }
            if window.isKeyWindow, let host = hostWindow { host.makeKey() }
        }
    }

    /// Firma con il certificato di LiveContainer, salva l'impronta e riprova una volta.
    private func sign(_ app: GuestApp, reason: String) {
        CPSLiveContainer.signApp(atPath: app.bundleURL.path) { [weak self] ok, error in
            guard let self = self else { return }
            if ok {
                SignStamp.write(app.bundleURL)
                self.attempt(app, allowSigning: false)
            } else {
                self.errors[app.id] = GuestError.signing(error ?? reason).localizedDescription
                self.loading.remove(app.id)
            }
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
        CrashGuard.begin(.patch, app: app)
        do {
            try MachO.patchBundle(at: app.bundleURL, executableName: exec.lastPathComponent)
        } catch {
            if (try? MachO.needsPatch(exec)) == true { throw GuestError.patch(error.localizedDescription) }
        }

        // App importate: la firma deve coprire i file così come sono ora. Una pagina modificata dopo la firma
        // fa chiudere il processo con SIGKILL (non intercettabile), quindi si rifirma PRIMA del caricamento.
        if app.source == .imported, CPSLiveContainer.isHostedInLiveContainer, !SignStamp.isValid(app.bundleURL) {
            CrashGuard.failed(app: app)
            throw GuestError.needsSigning
        }

        // Da qui il codice che chiede Bundle.main riceve il bundle dell'app ospite (come LiveContainer).
        CPSHooks.markGuestEpoch()
        CPSHooks.guestBundle = bundle

        // Come LiveContainer: @executable_path dell'app ospite deve puntare al suo eseguibile, non a CarPlayss
        // (tweak e dylib iniettati come libsubstrate.dylib vengono cercati lì).
        CPSLiveContainer.setExecutablePath(exec.path)

        CrashGuard.begin(.dlopen, app: app)
        guard dlopen(exec.path, RTLD_LAZY | RTLD_GLOBAL) != nil else {
            let message = dlerror().map { String(cString: $0) } ?? "errore sconosciuto"
            throw GuestError.load(message)
        }

        let classNames = CPSObjC.classNames(inImageAtPath: exec.path)
        let session = GuestSession(app: app)

        // AppDelegate dell'app: molte app CarPlay preparano player, database e SDK qui.
        let appDelegateProto = NSProtocolFromString("UIApplicationDelegate")
        let sceneProto = NSProtocolFromString("UISceneDelegate")
        if runAppDelegate, !CrashGuard.skip(.appDelegate, app.id), let proto = appDelegateProto {
            CrashGuard.begin(.appDelegate, app: app)
            let candidates = classNames.compactMap { NSClassFromString($0) }.filter { cls in
                CPSObjC.isClass(cls, conformingTo: proto) && !(sceneProto.map { CPSObjC.isClass(cls, conformingTo: $0) } ?? false)
            }
            if let cls = candidates.first {
                session.guest("AppDelegate") {
                    if let delegate = CPSObjC.instantiate(cls) as? NSObject {
                        session.appDelegate = delegate
                        CPSHooks.registerGuestAppDelegate(delegate, bundlePath: app.bundleURL.path)
                        _ = CPSObjC.sendLaunch(delegate, NSSelectorFromString("application:willFinishLaunchingWithOptions:"), application: UIApplication.shared)
                        _ = CPSObjC.sendLaunch(delegate, NSSelectorFromString("application:didFinishLaunchingWithOptions:"), application: UIApplication.shared)
                        session.note("CarPlayss → AppDelegate \(NSStringFromClass(cls)) didFinishLaunching")
                        CPSObjC.send(delegate, NSSelectorFromString("applicationDidBecomeActive:"), UIApplication.shared)
                    }
                }
            }
        }

        bootPhoneUI(session, bundle: bundle)

        // Delegato della scena CarPlay
        CrashGuard.begin(.carplay, app: app)
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
                session.delegateClassName = NSStringFromClass(cls)
                session.delegateMethods = CPSObjC.methodNames(of: cls).filter {
                    $0.contains("scene") || $0.contains("Scene") || $0.contains("template") || $0.contains("Template") || $0.contains("contentStyle")
                }
                session.sceneDelegate = delegate
                session.scene.cps_delegate = delegate
                let withWindow = NSSelectorFromString("templateApplicationScene:didConnectInterfaceController:toWindow:")
                let plain = NSSelectorFromString("templateApplicationScene:didConnectInterfaceController:")
                CPSObjC.send(delegate, NSSelectorFromString("sceneWillEnterForeground:"), session.scene)
                if delegate.responds(to: withWindow) {
                    session.usesWindow = true
                    session.note("CarPlayss → templateApplicationScene:didConnectInterfaceController:toWindow:")
                    CPSObjC.send(delegate, withWindow, session.scene, session.controller, session.window)
                } else if delegate.responds(to: plain) {
                    session.note("CarPlayss → templateApplicationScene:didConnectInterfaceController:")
                    CPSObjC.send(delegate, plain, session.scene, session.controller)
                } else {
                    session.note("Il delegato non implementa templateApplicationScene:didConnect…")
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

        if !CrashGuard.skip(.dashboard, app.id) {
            CrashGuard.begin(.dashboard, app: app)
            connectDashboard(session, bundle: bundle, classNames: classNames)
        }
        return session
    }

    /// Avvia l'interfaccia principale dell'app (come farebbe UIApplicationMain): molte app inizializzano
    /// mappa, posizione e dati lì, e il codice CarPlay aspetta che siano pronti.
    private func bootPhoneUI(_ session: GuestSession, bundle: Bundle) {
        let info = bundle.infoDictionary ?? [:]
        var kind: [String] = []
        let frameworks = (try? FileManager.default.contentsOfDirectory(atPath: bundle.bundleURL.appendingPathComponent("Frameworks").path)) ?? []
        if frameworks.contains("Flutter.framework") { kind.append("Flutter") }
        if frameworks.contains(where: { $0.hasPrefix("React") || $0.hasPrefix("hermes") }) { kind.append("React Native") }
        if frameworks.contains(where: { $0.hasPrefix("UnityFramework") }) { kind.append("Unity") }

        var storyboardName = info["UIMainStoryboardFile"] as? String
        var phoneDelegateClass: AnyClass?
        if let manifest = info["UIApplicationSceneManifest"] as? [String: Any],
           let configs = manifest["UISceneConfigurations"] as? [String: Any],
           let phone = (configs["UIWindowSceneSessionRoleApplication"] as? [[String: Any]])?.first {
            kind.append("scene")
            if let sb = phone["UISceneStoryboardFile"] as? String { storyboardName = sb }
            if let name = phone["UISceneDelegateClassName"] as? String { phoneDelegateClass = NSClassFromString(name) }
        }
        if storyboardName != nil { kind.append("storyboard") }

        guard let hostScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            session.appKind = kind.joined(separator: ", ")
            return
        }

        // Finestra già creata dall'AppDelegate (UI programmatica)?
        if let delegate = session.appDelegate,
           let existing = CPSObjC.get(delegate, NSSelectorFromString("window")) as? UIWindow {
            session.phoneWindow = existing
            kind.append("finestra dell'AppDelegate")
        }

        if session.phoneWindow == nil, let name = storyboardName {
            session.guest("Interfaccia telefono") {
                let storyboard = UIStoryboard(name: name, bundle: bundle)
                guard let root = storyboard.instantiateInitialViewController() else { return }
                let window = UIWindow(windowScene: hostScene)
                window.rootViewController = root
                window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
                window.isHidden = false
                session.phoneWindow = window
                if let delegate = session.appDelegate, delegate.responds(to: NSSelectorFromString("setWindow:")) {
                    CPSObjC.send(delegate, NSSelectorFromString("setWindow:"), window)
                }
                session.note("CarPlayss → interfaccia telefono avviata dallo storyboard \(name)")
            }
        }

        if let cls = phoneDelegateClass {
            session.guest("Scena telefono") {
                guard let delegate = CPSObjC.instantiate(cls) as? NSObject else { return }
                session.phoneSceneDelegate = delegate
                if let window = session.phoneWindow, delegate.responds(to: NSSelectorFromString("setWindow:")) {
                    CPSObjC.send(delegate, NSSelectorFromString("setWindow:"), window)
                }
                session.note("CarPlayss → delegato scena telefono \(NSStringFromClass(cls)) creato")
            }
            // React Native, Flutter e molte app UIKit creano la loro interfaccia (e avviano il motore JS/Dart che
            // poi imposta i template CarPlay) in scene(_:willConnectTo:options:): si chiama con la scena reale.
            let willConnect = NSSelectorFromString("scene:willConnectToSession:options:")
            if let delegate = session.phoneSceneDelegate, delegate.responds(to: willConnect),
               !CrashGuard.skip(.phoneScene, session.app.id) {
                CrashGuard.begin(.phoneScene, app: session.app)
                session.note("CarPlayss → scena telefono scene:willConnectToSession:options:")
                session.guest("Scena telefono") {
                    CPSObjC.send(delegate, willConnect, hostScene, hostScene.session, nil)
                    CPSObjC.send(delegate, NSSelectorFromString("sceneWillEnterForeground:"), hostScene)
                    CPSObjC.send(delegate, NSSelectorFromString("sceneDidBecomeActive:"), hostScene)
                }
                if let window = CPSObjC.get(delegate, NSSelectorFromString("window")) as? UIWindow {
                    session.phoneWindow = window
                }
            }
        }
        // L'interfaccia telefono resta attiva ma dietro lo schermo dell'auto, e CarPlayss resta la finestra principale.
        session.phoneWindow?.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        if let host = hostScene.windows.first(where: { hostWindows.contains(ObjectIdentifier($0)) && $0.windowLevel == .normal }) {
            host.makeKey()
        }

        if NSClassFromString("SwiftUI.AppDelegate") != nil || classLinksSwiftUI(bundle) { kind.append("SwiftUI") }
        session.appKind = kind.isEmpty ? "UIKit" : kind.joined(separator: ", ")
    }

    private func classLinksSwiftUI(_ bundle: Bundle) -> Bool {
        guard let exec = bundle.executableURL else { return false }
        return MachO.linkedLibraries(exec).contains { $0.contains("SwiftUI.framework") }
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
