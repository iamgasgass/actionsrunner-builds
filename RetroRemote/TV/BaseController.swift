import Foundation

/// Classe base dei controller. Tutte le callback arrivano sul main thread.
class BaseController: NSObject {
    private(set) var device: TVDevice
    private(set) var state: ConnectionState = .idle

    var onStateChange: ((ConnectionState) -> Void)?
    var onTokenUpdate: ((String) -> Void)?
    var onMACUpdate: ((String) -> Void)?

    init(device: TVDevice) {
        self.device = device
        super.init()
    }

    // MARK: - Da sovrascrivere

    func connect() {}
    func disconnect() {}
    func send(_ key: RemoteKey) {}
    func sendText(_ text: String) {}
    func fetchApps(_ completion: @escaping ([TVApp]) -> Void) { completion([]) }
    func launch(_ app: TVApp) {}

    /// La TV accetta testo libero (tastiera / ricerca vocale).
    var supportsText: Bool { true }
    /// Il touchpad può muovere un puntatore sulla TV.
    var supportsPointer: Bool { false }
    func pointerMove(dx: Int, dy: Int) {}
    func pointerClick() {}

    /// App avviabili con un tocco (Netflix, YouTube…).
    var quickApps: [TVApp] { QuickApps.apps(for: device.brand) }

    // MARK: - Utilità

    func setState(_ newState: ConnectionState) {
        let apply = { [weak self] in
            guard let self = self, self.state != newState else { return }
            self.state = newState
            self.onStateChange?(newState)
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    func saveToken(_ token: String) {
        let apply = { [weak self] in
            guard let self = self else { return }
            self.device.token = token
            self.onTokenUpdate?(token)
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    func saveMAC(_ mac: String) {
        let apply = { [weak self] in
            guard let self = self, !mac.isEmpty, self.device.mac != mac else { return }
            self.device.mac = mac
            self.onMACUpdate?(mac)
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    /// Chiede all'utente un codice di associazione mostrato sulla TV.
    func requestPIN(title: String, message: String, hex: Bool, reply: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            if let prompt = ConnectionManager.shared.pinPrompt {
                prompt(title, message, hex, reply)
            } else {
                reply(nil)
            }
        }
    }

    static func jsonString(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func jsonObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Codici tasto Android (KeyEvent), usati da Android TV e Fire TV.
    static func androidKeyCode(_ key: RemoteKey) -> Int? {
        switch key {
        case .home: return 3
        case .back: return 4
        case .up: return 19
        case .down: return 20
        case .left: return 21
        case .right: return 22
        case .ok: return 23
        case .volumeUp: return 24
        case .volumeDown: return 25
        case .power: return 26
        case .menu: return 82
        case .playPause: return 85
        case .stop: return 86
        case .rewind: return 89
        case .fastForward: return 90
        case .play: return 126
        case .pause: return 127
        case .mute: return 164
        case .info: return 165
        case .channelUp: return 166
        case .channelDown: return 167
        case .guide: return 172
        case .settings: return 176
        case .input: return 178
        case .red: return 183
        case .green: return 184
        case .yellow: return 185
        case .blue: return 186
        case .exit: return 111
        case .digit(let n): return 7 + n
        }
    }
}

/// Accetta il certificato autofirmato della TV solo per il suo indirizzo.
func trustTVCertificate(host: String, challenge: URLAuthenticationChallenge,
                        completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
       challenge.protectionSpace.host == host,
       let trust = challenge.protectionSpace.serverTrust {
        completion(.useCredential, URLCredential(trust: trust))
    } else {
        completion(.performDefaultHandling, nil)
    }
}
