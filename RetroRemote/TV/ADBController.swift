import Foundation
import Network
import Security

/// Fire TV (e qualsiasi Android con "Debug ADB" attivo) tramite il protocollo ADB su TCP 5555.
final class ADBController: BaseController {
    private enum Command: UInt32 {
        case cnxn = 0x4E58_4E43
        case auth = 0x4854_5541
        case open = 0x4E45_504F
        case okay = 0x5941_4B4F
        case clse = 0x4553_4C43
        case wrte = 0x4554_5257
    }

    private struct Stream {
        var remoteID: UInt32 = 0
        var output: [UInt8] = []
        var completion: ((String) -> Void)?
    }

    private var connection: NWConnection?
    private var buffer: [UInt8] = []
    private var sentSignature = false
    private var sentPublicKey = false
    private var nextLocalID: UInt32 = 1
    private var streams: [UInt32: Stream] = [:]

    // Shell interattiva persistente per i tasti (più rapida di un processo per tasto)
    private var shellID: UInt32 = 0
    private var shellReady = false
    private var shellBusy = false
    private var shellQueue: [String] = []

    override func connect() {
        teardown()
        setState(.connecting)
        let conn = NWConnection(host: NWEndpoint.Host(device.host), port: 5555, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let conn = conn, conn === self.connection else { return }
            switch state {
            case .ready:
                self.sendPacket(.cnxn, 0x0100_0000, 256 * 1024, Array("host::\u{0}".utf8))
                self.receive(on: conn)
            case .failed, .waiting:
                self.fail("Attiva «Debug ADB» nelle opzioni sviluppatore della TV")
            default:
                break
            }
        }
        conn.start(queue: .main)
    }

    override func disconnect() {
        teardown()
        setState(.idle)
    }

    private func teardown() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer = []
        sentSignature = false
        sentPublicKey = false
        streams.removeAll()
        shellID = 0
        shellReady = false
        shellBusy = false
        shellQueue.removeAll()
    }

    private func fail(_ message: String) {
        teardown()
        setState(.failed(message))
    }

    // MARK: - Pacchetti

    private func sendPacket(_ command: Command, _ arg0: UInt32, _ arg1: UInt32, _ payload: [UInt8] = []) {
        var header: [UInt8] = []
        func put(_ v: UInt32) {
            header += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
        }
        let checksum = payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        put(command.rawValue)
        put(arg0)
        put(arg1)
        put(UInt32(payload.count))
        put(checksum)
        put(command.rawValue ^ 0xFFFF_FFFF)
        connection?.send(content: Data(header + payload), completion: .contentProcessed { _ in })
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self, weak conn] data, _, isComplete, error in
            guard let self = self, let conn = conn, conn === self.connection else { return }
            if let data = data, !data.isEmpty {
                self.buffer += [UInt8](data)
                self.drain()
            }
            if isComplete || error != nil {
                self.fail(self.state == .connected ? "Connessione persa" : "Connessione rifiutata dalla TV")
            } else {
                self.receive(on: conn)
            }
        }
    }

    private func drain() {
        func word(_ offset: Int) -> UInt32 {
            UInt32(buffer[offset]) | UInt32(buffer[offset + 1]) << 8
                | UInt32(buffer[offset + 2]) << 16 | UInt32(buffer[offset + 3]) << 24
        }
        while buffer.count >= 24 {
            let length = Int(word(12))
            guard buffer.count >= 24 + length else { return }
            let command = word(0), arg0 = word(4), arg1 = word(8)
            let payload = Array(buffer[24..<(24 + length)])
            buffer.removeFirst(24 + length)
            if let cmd = Command(rawValue: command) { handle(cmd, arg0, arg1, payload) }
        }
    }

    private func handle(_ command: Command, _ arg0: UInt32, _ arg1: UInt32, _ payload: [UInt8]) {
        switch command {
        case .cnxn:
            if device.token == nil { saveToken("authorized") }
            setState(.connected)
            openShell()
        case .auth:
            guard arg0 == 1, let material = ClientIdentity.shared.load() else { return }
            if !sentSignature {
                sentSignature = true
                var error: Unmanaged<CFError>?
                guard let signature = SecKeyCreateSignature(material.privateKey, .rsaSignatureDigestPKCS1v15SHA1,
                                                            Data(payload) as CFData, &error) as Data? else {
                    fail("Firma ADB non riuscita")
                    return
                }
                sendPacket(.auth, 2, 0, [UInt8](signature))
            } else if !sentPublicKey {
                sentPublicKey = true
                guard let parts = DER.rsaComponents(material.publicKeyPKCS1),
                      let key = ADBKey.encode(modulus: parts.modulus, name: "RetroRemote@iPhone") else {
                    fail("Chiave ADB non valida")
                    return
                }
                setState(.pairing)
                sendPacket(.auth, 3, 0, key)
            }
        case .okay:
            if arg1 == shellID {
                streams[arg1]?.remoteID = arg0
                shellReady = true
                shellBusy = false
                flushShell()
            } else {
                streams[arg1]?.remoteID = arg0
            }
        case .wrte:
            if streams[arg1] != nil { streams[arg1]?.output += payload }
            let remote = streams[arg1]?.remoteID ?? arg0
            sendPacket(.okay, arg1, remote)
        case .clse:
            if let stream = streams.removeValue(forKey: arg1) {
                stream.completion?(String(decoding: stream.output, as: UTF8.self))
                sendPacket(.clse, arg1, arg0)
            }
            if arg1 == shellID {
                shellID = 0
                shellReady = false
            }
        case .open:
            break
        }
    }

    // MARK: - Shell

    @discardableResult
    private func openStream(_ service: String, completion: ((String) -> Void)? = nil) -> UInt32 {
        let id = nextLocalID
        nextLocalID &+= 1
        streams[id] = Stream(completion: completion)
        sendPacket(.open, id, 0, Array((service + "\u{0}").utf8))
        return id
    }

    private func openShell() {
        shellReady = false
        shellBusy = true
        shellID = openStream("shell:")
    }

    private func runInShell(_ command: String) {
        guard state == .connected else {
            if connection == nil { connect() }
            return
        }
        shellQueue.append(command + "\n")
        if shellID == 0 { openShell() }
        flushShell()
    }

    private func flushShell() {
        guard shellReady, !shellBusy, !shellQueue.isEmpty, let remote = streams[shellID]?.remoteID else { return }
        let command = shellQueue.removeFirst()
        shellBusy = true
        sendPacket(.wrte, shellID, remote, Array(command.utf8))
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Comandi

    override func send(_ key: RemoteKey) {
        guard let code = Self.androidKeyCode(key) else { return }
        runInShell("input keyevent \(code)")
    }

    override func sendText(_ text: String) {
        let escaped = text.replacingOccurrences(of: " ", with: "%s")
        runInShell("input text " + Self.shellQuote(escaped))
    }

    override func fetchApps(_ completion: @escaping ([TVApp]) -> Void) {
        guard state == .connected else { completion(quickApps); return }
        let known = Dictionary(uniqueKeysWithValues: quickApps.map { ($0.id, $0.name) })
        openStream("shell:pm list packages -3") { output in
            let packages = output.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("package:") }
                .map { String($0.dropFirst("package:".count)) }
            let apps = packages.map { id -> TVApp in
                TVApp(id: id, name: known[id] ?? Self.prettyName(id), iconURL: nil)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            completion(apps.isEmpty ? self.quickApps : apps)
        }
    }

    private static func prettyName(_ package: String) -> String {
        let ignored: Set<String> = ["com", "tv", "android", "amazon", "firetv", "app", "apps", "mobile", "ninja", "leanback"]
        let parts = package.split(separator: ".").map(String.init).filter { !ignored.contains($0.lowercased()) }
        let name = parts.last ?? package
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    override func launch(_ app: TVApp) {
        let pkg = Self.shellQuote(app.id)
        runInShell("monkey -p \(pkg) -c android.intent.category.LEANBACK_LAUNCHER 1 >/dev/null 2>&1 || monkey -p \(pkg) 1 >/dev/null 2>&1")
    }
}
