import Foundation

/// VIZIO SmartCast: API HTTPS (porta 7345, o 9000 sui firmware vecchi) con PIN di associazione.
final class VizioController: BaseController, URLSessionDelegate {
    private var activeSession: URLSession?
    private var session: URLSession {
        if let s = activeSession { return s }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let s = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        activeSession = s
        return s
    }

    override func disconnect() {
        activeSession?.invalidateAndCancel()
        activeSession = nil
        setState(.idle)
    }

    private var port = 7345
    private var base: String { "https://\(device.host):\(port)" }

    private static var clientID: String {
        let key = "vizio.clientID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    override var supportsText: Bool { false }

    private func request(_ method: String, _ path: String, _ body: [String: Any]? = nil,
                         completion: @escaping (Int, [String: Any]?) -> Void) {
        guard let url = URL(string: base + path) else { completion(0, nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = device.token { req.setValue(token, forHTTPHeaderField: "AUTH") }
        if let body = body { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        session.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            completion(code, json)
        }.resume()
    }

    private static func succeeded(_ json: [String: Any]?) -> Bool {
        ((json?["STATUS"] as? [String: Any])?["RESULT"] as? String)?.uppercased() == "SUCCESS"
    }

    override func connect() {
        setState(.connecting)
        probe(ports: [7345, 9000])
    }

    private func probe(ports: [Int]) {
        guard let first = ports.first else {
            setState(.failed("TV VIZIO non raggiungibile"))
            return
        }
        port = first
        request("GET", "/state/device/power_mode") { [weak self] code, _ in
            guard let self = self else { return }
            if code == 0 {
                self.probe(ports: Array(ports.dropFirst()))
            } else if self.device.token == nil {
                self.startPairing()
            } else if code == 200 {
                self.setState(.connected)
            } else {
                self.startPairing()
            }
        }
    }

    private func startPairing() {
        setState(.pairing)
        let id = Self.clientID
        request("PUT", "/pairing/start", ["DEVICE_ID": id, "DEVICE_NAME": "RetroRemote"]) { [weak self] _, json in
            guard let self = self else { return }
            guard let item = json?["ITEM"] as? [String: Any],
                  let token = item["PAIRING_REQ_TOKEN"] as? Int else {
                self.setState(.failed("La TV non ha avviato l'associazione"))
                return
            }
            let challenge = item["CHALLENGE_TYPE"] as? Int ?? 1
            self.requestPIN(title: "PIN VIZIO", message: "Inserisci il PIN mostrato sulla TV.", hex: false) { pin in
                guard let pin = pin, !pin.isEmpty else {
                    self.request("PUT", "/pairing/cancel", ["DEVICE_ID": id, "CHALLENGE_TYPE": challenge,
                                                            "RESPONSE_VALUE": "1111", "PAIRING_REQ_TOKEN": token]) { _, _ in }
                    self.setState(.failed("Associazione annullata"))
                    return
                }
                self.request("PUT", "/pairing/pair", ["DEVICE_ID": id, "CHALLENGE_TYPE": challenge,
                                                      "RESPONSE_VALUE": pin, "PAIRING_REQ_TOKEN": token]) { _, json in
                    if let auth = (json?["ITEM"] as? [String: Any])?["AUTH_TOKEN"] as? String {
                        self.saveToken(auth)
                        self.setState(.connected)
                    } else {
                        self.setState(.failed("PIN errato"))
                    }
                }
            }
        }
    }

    private func code(_ key: RemoteKey) -> (Int, Int)? {
        switch key {
        case .fastForward: return (2, 0)
        case .rewind: return (2, 1)
        case .pause: return (2, 2)
        case .play, .playPause: return (2, 3)
        case .down: return (3, 0)
        case .left: return (3, 1)
        case .ok: return (3, 2)
        case .right: return (3, 7)
        case .up: return (3, 8)
        case .back: return (4, 0)
        case .info: return (4, 6)
        case .menu, .settings: return (4, 8)
        case .home: return (4, 15)
        case .volumeDown: return (5, 0)
        case .volumeUp: return (5, 1)
        case .mute: return (5, 4)
        case .input: return (7, 1)
        case .channelDown: return (8, 0)
        case .channelUp: return (8, 1)
        case .previousChannel: return (8, 2)
        case .exit: return (9, 0)
        case .power: return (11, 2)
        default: return nil
        }
    }

    override func send(_ key: RemoteKey) {
        guard let pair = code(key) else { return }
        request("PUT", "/key_command/", ["KEYLIST": [["CODESET": pair.0, "CODE": pair.1, "ACTION": "KEYPRESS"]]]) { [weak self] status, json in
            if status == 0 {
                self?.setState(.failed("TV VIZIO non raggiungibile"))
            } else if Self.succeeded(json) {
                self?.setState(.connected)
            }
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        trustTVCertificate(host: device.host, challenge: challenge, completion: completionHandler)
    }
}
