import Foundation

/// Panasonic Viera: SOAP "p00NetworkControl" su HTTP porta 55000.
final class PanasonicController: BaseController {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        return URLSession(configuration: config)
    }()

    private var base: String { "http://\(device.host):55000" }
    private static let service = "urn:panasonic-com:service:p00NetworkControl:1"

    override var supportsText: Bool { false }

    override func connect() {
        setState(.connecting)
        guard let url = URL(string: base + "/nrc/ddd.xml") else {
            setState(.failed("Indirizzo non valido"))
            return
        }
        session.dataTask(with: url) { [weak self] _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            self?.setState(ok ? .connected : .failed("TV Panasonic non raggiungibile"))
        }.resume()
    }

    override func disconnect() {
        setState(.idle)
    }

    private func soap(_ action: String, _ arguments: String) {
        guard let url = URL(string: base + "/nrc/control_0") else { return }
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:\(action) xmlns:u="\(Self.service)">\(arguments)</u:\(action)></s:Body>
        </s:Envelope>
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(Self.service)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)
        session.dataTask(with: request) { [weak self] _, response, error in
            if error != nil {
                self?.setState(.failed("TV Panasonic non raggiungibile"))
            } else if (response as? HTTPURLResponse)?.statusCode == 200 {
                self?.setState(.connected)
            }
        }.resume()
    }

    private func keyName(_ key: RemoteKey) -> String? {
        switch key {
        case .power: return "NRC_POWER"
        case .home: return "NRC_HOME"
        case .back: return "NRC_RETURN"
        case .menu: return "NRC_MENU"
        case .settings: return "NRC_SUBMENU"
        case .input: return "NRC_CHG_INPUT"
        case .info: return "NRC_INFO"
        case .guide: return "NRC_EPG"
        case .exit: return "NRC_CANCEL"
        case .up: return "NRC_UP"
        case .down: return "NRC_DOWN"
        case .left: return "NRC_LEFT"
        case .right: return "NRC_RIGHT"
        case .ok: return "NRC_ENTER"
        case .volumeUp: return "NRC_VOLUP"
        case .volumeDown: return "NRC_VOLDOWN"
        case .mute: return "NRC_MUTE"
        case .channelUp: return "NRC_CH_UP"
        case .channelDown: return "NRC_CH_DOWN"
        case .play, .playPause: return "NRC_PLAY"
        case .pause: return "NRC_PAUSE"
        case .rewind: return "NRC_REW"
        case .fastForward: return "NRC_FF"
        case .stop: return "NRC_STOP"
        case .red: return "NRC_RED"
        case .green: return "NRC_GREEN"
        case .yellow: return "NRC_YELLOW"
        case .blue: return "NRC_BLUE"
        case .digit(let n): return "NRC_D\(n)"
        }
    }

    override func send(_ key: RemoteKey) {
        guard let name = keyName(key) else { return }
        soap("X_SendKey", "<X_KeyEvent>\(name)-ONOFF</X_KeyEvent>")
    }

    override func fetchApps(_ completion: @escaping ([TVApp]) -> Void) {
        completion(quickApps)
    }

    override func launch(_ app: TVApp) {
        soap("X_LaunchApp", "<X_AppType>vc_app</X_AppType><X_LaunchKeyword>product_id=\(app.id)</X_LaunchKeyword>")
    }
}
