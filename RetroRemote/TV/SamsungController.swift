import Foundation

/// Samsung Tizen (2016+): WebSocket "samsung.remote.control" su 8002 (wss) con ripiego su 8001 (ws).
final class SamsungController: BaseController, URLSessionWebSocketDelegate {
    private static let clientName = "RetroRemote"

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var useLegacyPort = false
    private var appsCompletion: (([TVApp]) -> Void)?
    private var playing = false

    override func connect() {
        teardown()
        setState(device.token == nil ? .pairing : .connecting)
        var comps = URLComponents()
        comps.scheme = useLegacyPort ? "ws" : "wss"
        comps.host = device.host
        comps.port = useLegacyPort ? 8001 : 8002
        comps.path = "/api/v2/channels/samsung.remote.control"
        var query = [URLQueryItem(name: "name", value: Data(Self.clientName.utf8).base64EncodedString())]
        if let token = device.token, !useLegacyPort { query.append(URLQueryItem(name: "token", value: token)) }
        comps.queryItems = query
        guard let url = comps.url else {
            setState(.failed("Indirizzo non valido"))
            return
        }
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        session = s
        let t = s.webSocketTask(with: url)
        task = t
        t.resume()
        receive(on: t)
    }

    override func disconnect() {
        teardown()
        useLegacyPort = false
        setState(.idle)
    }

    private func teardown() {
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, t === self.task else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let s): self.handle(s)
                    case .data(let d): if let s = String(data: d, encoding: .utf8) { self.handle(s) }
                    @unknown default: break
                    }
                    self.receive(on: t)
                case .failure:
                    self.handleFailure()
                }
            }
        }
    }

    private func handleFailure() {
        if state != .connected && !useLegacyPort {
            useLegacyPort = true
            connect()
        } else {
            teardown()
            useLegacyPort = false
            setState(.failed("Connessione persa"))
        }
    }

    private func handle(_ text: String) {
        guard let obj = Self.jsonObject(text), let event = obj["event"] as? String else { return }
        let data = obj["data"] as? [String: Any]
        switch event {
        case "ms.channel.connect":
            if let token = data?["token"] as? String {
                saveToken(token)
            } else if let token = data?["token"] as? Int {
                saveToken(String(token))
            }
            setState(.connected)
            startPing()
        case "ms.channel.unauthorized":
            teardown()
            setState(.failed("Connessione rifiutata dalla TV"))
        case "ms.channel.timeOut":
            teardown()
            setState(.failed("Tempo scaduto: accetta la richiesta sulla TV"))
        case "ed.installedApp.get":
            let list = (data?["data"] as? [[String: Any]]) ?? []
            let apps = list.compactMap { item -> TVApp? in
                guard let id = item["appId"] as? String else { return nil }
                let name = item["name"] as? String ?? id
                let type = item["app_type"].map { "\($0)" }
                return TVApp(id: id, name: name, iconURL: nil, extra: type)
            }
            appsCompletion?(apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
            appsCompletion = nil
        default:
            break
        }
    }

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.task?.sendPing { _ in }
        }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let t = task, let string = Self.jsonString(object) else { return }
        t.send(.string(string)) { _ in }
    }

    private func code(_ key: RemoteKey) -> String? {
        switch key {
        case .power: return "KEY_POWER"
        case .home: return "KEY_HOME"
        case .back: return "KEY_RETURN"
        case .menu: return "KEY_MENU"
        case .input: return "KEY_SOURCE"
        case .info: return "KEY_INFO"
        case .guide: return "KEY_GUIDE"
        case .exit: return "KEY_EXIT"
        case .up: return "KEY_UP"
        case .down: return "KEY_DOWN"
        case .left: return "KEY_LEFT"
        case .right: return "KEY_RIGHT"
        case .ok: return "KEY_ENTER"
        case .volumeUp: return "KEY_VOLUP"
        case .volumeDown: return "KEY_VOLDOWN"
        case .mute: return "KEY_MUTE"
        case .channelUp: return "KEY_CHUP"
        case .channelDown: return "KEY_CHDOWN"
        case .play: return "KEY_PLAY"
        case .pause: return "KEY_PAUSE"
        case .playPause:
            playing.toggle()
            return playing ? "KEY_PLAY" : "KEY_PAUSE"
        case .rewind: return "KEY_REWIND"
        case .fastForward: return "KEY_FF"
        case .stop: return "KEY_STOP"
        case .red: return "KEY_RED"
        case .green: return "KEY_GREEN"
        case .yellow: return "KEY_YELLOW"
        case .blue: return "KEY_CYAN"
        case .digit(let n): return "KEY_\(n)"
        }
    }

    override func send(_ key: RemoteKey) {
        guard let code = code(key) else { return }
        if task == nil { connect() }
        sendJSON(["method": "ms.remote.control",
                  "params": ["Cmd": "Click", "DataOfCmd": code, "Option": "false", "TypeOfRemote": "SendRemoteKey"]])
    }

    override func sendText(_ text: String) {
        sendJSON(["method": "ms.remote.control",
                  "params": ["Cmd": Data(text.utf8).base64EncodedString(), "DataOfCmd": "base64",
                             "TypeOfRemote": "SendInputString"]])
    }

    override func fetchApps(_ completion: @escaping ([TVApp]) -> Void) {
        appsCompletion = completion
        sendJSON(["method": "ms.channel.emit", "params": ["event": "ed.installedApp.get", "to": "host"]])
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, let pending = self.appsCompletion else { return }
            self.appsCompletion = nil
            pending([])
        }
    }

    override func launch(_ app: TVApp) {
        let action = app.extra == "4" ? "NATIVE_LAUNCH" : "DEEP_LINK"
        sendJSON(["method": "ms.channel.emit",
                  "params": ["event": "ed.apps.launch", "to": "host",
                             "data": ["appId": app.id, "action_type": action]]])
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        trustTVCertificate(host: device.host, challenge: challenge, completion: completionHandler)
    }
}
