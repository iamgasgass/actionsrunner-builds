import Foundation

/// Roku External Control Protocol (HTTP sulla porta 8060).
final class RokuController: BaseController {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 4
        return URLSession(configuration: config)
    }()

    private var base: String { "http://\(device.host):8060" }

    override func connect() {
        setState(.connecting)
        guard let url = URL(string: base + "/query/device-info") else {
            setState(.failed("Indirizzo non valido"))
            return
        }
        session.dataTask(with: url) { [weak self] _, response, _ in
            guard let self = self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                self.setState(.connected)
            } else if code == 403 {
                self.setState(.failed("Attiva «Controllo da app mobili» sulla TV"))
            } else {
                self.setState(.failed("TV non raggiungibile"))
            }
        }.resume()
    }

    override func disconnect() {
        setState(.idle)
    }

    private func post(_ path: String, completion: (() -> Void)? = nil) {
        guard let url = URL(string: base + "/" + path) else { completion?(); return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        session.dataTask(with: request) { [weak self] _, response, error in
            if error != nil {
                self?.setState(.failed("TV non raggiungibile"))
            } else if (response as? HTTPURLResponse)?.statusCode == 403 {
                self?.setState(.failed("Attiva «Controllo da app mobili» sulla TV"))
            } else {
                self?.setState(.connected)
            }
            completion?()
        }.resume()
    }

    private func keyName(_ key: RemoteKey) -> String? {
        switch key {
        case .power: return "Power"
        case .home, .exit: return "Home"
        case .back: return "Back"
        case .menu, .info: return "Info"
        case .input: return "InputTuner"
        case .guide: return "Search"
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        case .ok: return "Select"
        case .volumeUp: return "VolumeUp"
        case .volumeDown: return "VolumeDown"
        case .mute: return "VolumeMute"
        case .channelUp: return "ChannelUp"
        case .channelDown: return "ChannelDown"
        case .play, .pause, .playPause: return "Play"
        case .rewind: return "Rev"
        case .fastForward: return "Fwd"
        case .stop: return "InstantReplay"
        case .red, .green, .yellow, .blue, .settings, .previousChannel, .dash: return nil
        case .backspace: return "Backspace"
        case .enter: return "Enter"
        case .digit(let n): return "Lit_\(n)"
        }
    }

    override func send(_ key: RemoteKey) {
        guard let name = keyName(key) else { return }
        post("keypress/\(name)")
    }

    override func sendText(_ text: String) {
        sendLiterals(Array(text), index: 0)
    }

    private func sendLiterals(_ chars: [Character], index: Int) {
        guard index < chars.count else { return }
        let encoded = String(chars[index]).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        post("keypress/Lit_\(encoded)") { [weak self] in
            self?.sendLiterals(chars, index: index + 1)
        }
    }

    override func fetchApps(_ completion: @escaping ([TVApp]) -> Void) {
        guard let url = URL(string: base + "/query/apps") else { completion([]); return }
        let base = self.base
        session.dataTask(with: url) { data, _, _ in
            var apps: [TVApp] = []
            if let data = data {
                let parser = XMLParser(data: data)
                let delegate = RokuAppsParser()
                parser.delegate = delegate
                parser.parse()
                apps = delegate.apps.map { entry in
                    TVApp(id: entry.id, name: entry.name, iconURL: URL(string: "\(base)/query/icon/\(entry.id)"), extra: entry.type)
                }
            }
            DispatchQueue.main.async { completion(apps) }
        }.resume()
    }

    override func launch(_ app: TVApp) {
        let id = app.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? app.id
        post("launch/\(id)")
    }
}

private final class RokuAppsParser: NSObject, XMLParserDelegate {
    struct Entry { let id: String; let type: String; let name: String }
    private(set) var apps: [Entry] = []
    private var currentID: String?
    private var currentType = ""
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "app" {
            currentID = attributeDict["id"]
            currentType = attributeDict["type"] ?? ""
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "app", let id = currentID {
            apps.append(Entry(id: id, type: currentType, name: text.trimmingCharacters(in: .whitespacesAndNewlines)))
            currentID = nil
        }
    }
}
