import Foundation

/// LG webOS: SSAP via WebSocket (wss 3001 sui modelli recenti, ws 3000 sui precedenti)
/// + socket "pointer" per i tasti di navigazione.
final class LGController: BaseController, URLSessionWebSocketDelegate {
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pointerTask: URLSessionWebSocketTask?
    private var endpointIndex = 0
    private var nextID = 0
    private var callbacks: [String: ([String: Any]) -> Void] = [:]
    private var playing = false

    private var endpoints: [String] { ["wss://\(device.host):3001", "ws://\(device.host):3000"] }

    private static let permissions = [
        "LAUNCH", "LAUNCH_WEBAPP", "APP_TO_APP", "CLOSE", "TEST_OPEN", "TEST_PROTECTED",
        "CONTROL_AUDIO", "CONTROL_DISPLAY", "CONTROL_INPUT_JOYSTICK", "CONTROL_INPUT_MEDIA_RECORDING",
        "CONTROL_INPUT_MEDIA_PLAYBACK", "CONTROL_INPUT_TV", "CONTROL_POWER", "CONTROL_TV_SCREEN",
        "READ_APP_STATUS", "READ_CURRENT_CHANNEL", "READ_INPUT_DEVICE_LIST", "READ_NETWORK_STATE",
        "READ_RUNNING_APPS", "READ_TV_CHANNEL_LIST", "WRITE_NOTIFICATION_TOAST", "READ_POWER_STATE",
        "READ_COUNTRY_INFO", "READ_INSTALLED_APPS", "CONTROL_INPUT_TEXT", "CONTROL_MOUSE_AND_KEYBOARD"
    ]

    override func connect() {
        teardown()
        endpointIndex = 0
        open()
    }

    override func disconnect() {
        teardown()
        setState(.idle)
    }

    private func open() {
        guard endpointIndex < endpoints.count, let url = URL(string: endpoints[endpointIndex]) else {
            teardown()
            setState(.failed("TV LG non raggiungibile"))
            return
        }
        setState(.connecting)
        let s = session ?? URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        session = s
        let t = s.webSocketTask(with: url)
        task = t
        t.resume()
        receive(on: t)
    }

    private func teardown() {
        pointerTask?.cancel(with: .goingAway, reason: nil)
        pointerTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        callbacks.removeAll()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        if webSocketTask === task { register() }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        trustTVCertificate(host: device.host, challenge: challenge, completion: completionHandler)
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let isMain = t === self.task
                let isPointer = t === self.pointerTask
                guard isMain || isPointer else { return }
                switch result {
                case .success(let message):
                    if isMain, case .string(let s) = message { self.handle(s) }
                    self.receive(on: t)
                case .failure:
                    if isPointer {
                        self.pointerTask = nil
                    } else {
                        self.handleMainFailure()
                    }
                }
            }
        }
    }

    private func handleMainFailure() {
        if state == .connected || state == .pairing {
            teardown()
            setState(.failed("Connessione persa"))
            return
        }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        endpointIndex += 1
        open()
    }

    private func register() {
        var payload: [String: Any] = [
            "forcePairing": false,
            "pairingType": "PROMPT",
            "manifest": [
                "manifestVersion": 1,
                "appVersion": "1.0",
                "permissions": Self.permissions
            ] as [String: Any]
        ]
        if let key = device.token { payload["client-key"] = key }
        sendRaw(["type": "register", "id": "register_0", "payload": payload])
        if device.token == nil { setState(.pairing) }
    }

    private func handle(_ text: String) {
        guard let obj = Self.jsonObject(text) else { return }
        let type = obj["type"] as? String
        let id = obj["id"] as? String
        let payload = obj["payload"] as? [String: Any] ?? [:]
        if id == "register_0" {
            if type == "registered" {
                if let key = payload["client-key"] as? String { saveToken(key) }
                setState(.connected)
                requestPointerSocket()
                request("ssap://com.webos.service.connectionmanager/getinfo") { [weak self] info in
                    let wifi = (info["wifiInfo"] as? [String: Any])?["macAddress"] as? String
                    let wired = (info["wiredInfo"] as? [String: Any])?["macAddress"] as? String
                    if let mac = wired ?? wifi { self?.saveMAC(mac) }
                }
            } else if type == "response", payload["pairingType"] as? String == "PROMPT" {
                setState(.pairing)
            } else if type == "error" {
                teardown()
                setState(.failed((obj["error"] as? String) ?? "Associazione rifiutata"))
            }
            return
        }
        if let id = id, let callback = callbacks.removeValue(forKey: id) {
            callback(payload)
        }
    }

    private func sendRaw(_ object: [String: Any]) {
        guard let t = task, let s = Self.jsonString(object) else { return }
        t.send(.string(s)) { _ in }
    }

    private func request(_ uri: String, _ payload: [String: Any]? = nil,
                         completion: (([String: Any]) -> Void)? = nil) {
        nextID += 1
        let id = "req_\(nextID)"
        if let completion = completion { callbacks[id] = completion }
        var message: [String: Any] = ["type": "request", "id": id, "uri": uri]
        if let payload = payload { message["payload"] = payload }
        sendRaw(message)
    }

    private func requestPointerSocket() {
        request("ssap://com.webos.service.networkinput/getPointerInputSocket") { [weak self] payload in
            guard let self = self, let path = payload["socketPath"] as? String,
                  let url = URL(string: path), let s = self.session else { return }
            let t = s.webSocketTask(with: url)
            self.pointerTask = t
            t.resume()
            self.receive(on: t)
        }
    }

    private func button(_ name: String) {
        guard let t = pointerTask else {
            if state == .connected { requestPointerSocket() }
            return
        }
        t.send(.string("type:button\nname:\(name)\n\n")) { _ in }
    }

    private func buttonName(_ key: RemoteKey) -> String? {
        switch key {
        case .up: return "UP"
        case .down: return "DOWN"
        case .left: return "LEFT"
        case .right: return "RIGHT"
        case .ok: return "ENTER"
        case .back: return "BACK"
        case .home: return "HOME"
        case .menu: return "MENU"
        case .info: return "INFO"
        case .guide: return "GUIDE"
        case .exit: return "EXIT"
        case .mute: return "MUTE"
        case .red: return "RED"
        case .green: return "GREEN"
        case .yellow: return "YELLOW"
        case .blue: return "BLUE"
        case .settings: return "QMENU"
        case .dash: return "DASH"
        case .digit(let n): return "\(n)"
        default: return nil
        }
    }

    override func send(_ key: RemoteKey) {
        if task == nil { connect(); return }
        switch key {
        case .power: request("ssap://system/turnOff")
        case .volumeUp: request("ssap://audio/volumeUp")
        case .volumeDown: request("ssap://audio/volumeDown")
        case .channelUp: request("ssap://tv/channelUp")
        case .channelDown: request("ssap://tv/channelDown")
        case .play: request("ssap://media.controls/play")
        case .pause: request("ssap://media.controls/pause")
        case .playPause:
            playing.toggle()
            request(playing ? "ssap://media.controls/play" : "ssap://media.controls/pause")
        case .rewind: request("ssap://media.controls/rewind")
        case .fastForward: request("ssap://media.controls/fastForward")
        case .stop: request("ssap://media.controls/stop")
        case .input: request("ssap://system.launcher/launch", ["id": "com.webos.app.inputpicker"])
        case .backspace: request("ssap://com.webos.service.ime/deleteCharacters", ["count": 1])
        case .enter: request("ssap://com.webos.service.ime/sendEnterKey")
        default:
            if let name = buttonName(key) { button(name) }
        }
    }

    override var supportsPointer: Bool { true }

    override func pointerMove(dx: Int, dy: Int) {
        pointerTask?.send(.string("type:move\ndx:\(dx)\ndy:\(dy)\ndown:0\n\n")) { _ in }
    }

    override func pointerClick() {
        pointerTask?.send(.string("type:click\n\n")) { _ in }
    }

    override func sendText(_ text: String) {
        request("ssap://com.webos.service.ime/insertText", ["text": text, "replace": 0])
    }

    override func fetchApps(_ completion: @escaping ([TVApp]) -> Void) {
        guard task != nil, state == .connected else { completion([]); return }
        request("ssap://com.webos.applicationManager/listLaunchPoints") { payload in
            let points = payload["launchPoints"] as? [[String: Any]] ?? []
            let apps = points.compactMap { lp -> TVApp? in
                guard let id = lp["id"] as? String else { return nil }
                let icon = (lp["largeIcon"] as? String) ?? (lp["icon"] as? String)
                return TVApp(id: id, name: lp["title"] as? String ?? id, iconURL: icon.flatMap { URL(string: $0) })
            }
            completion(apps)
        }
    }

    override func launch(_ app: TVApp) {
        request("ssap://system.launcher/launch", ["id": app.id])
    }
}
