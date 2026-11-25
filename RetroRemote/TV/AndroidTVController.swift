import Foundation
import Network
import Security
import CryptoKit

/// Android TV / Google TV: protocollo "Android TV Remote v2".
/// Associazione TLS su 6467 con codice a 6 caratteri, comandi su 6466 (Protocol Buffers).
final class AndroidTVController: BaseController {
    private var connection: NWConnection?
    private var pairingConnection: NWConnection?
    private var buffer: [UInt8] = []
    private var pairingBuffer: [UInt8] = []
    private var serverKey: SecKey?
    private var attemptedPairing = false
    private var configured = false

    /// Il testo viene digitato carattere per carattere (lettere, cifre e punteggiatura comune).
    override var supportsText: Bool { true }

    override func connect() {
        attemptedPairing = false
        teardown()
        openRemote()
    }

    override func disconnect() {
        teardown()
        setState(.idle)
    }

    private func teardown() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        pairingConnection?.stateUpdateHandler = nil
        pairingConnection?.cancel()
        pairingConnection = nil
        buffer = []
        pairingBuffer = []
        configured = false
    }

    private func makeConnection(port: UInt16, identity: SecIdentity) -> NWConnection? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        if let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(options, secIdentity)
        }
        sec_protocol_options_set_verify_block(options, { [weak self] _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            if let key = SecTrustCopyKey(secTrust) { self?.serverKey = key }
            complete(true)
        }, .main)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        return NWConnection(host: NWEndpoint.Host(device.host), port: nwPort, using: parameters)
    }

    // MARK: - Canale comandi (6466)

    private func openRemote() {
        setState(.connecting)
        guard let material = ClientIdentity.shared.load(),
              let conn = makeConnection(port: 6466, identity: material.identity) else {
            setState(.failed("Impossibile creare il certificato"))
            return
        }
        connection = conn
        buffer = []
        configured = false
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let conn = conn, conn === self.connection else { return }
            switch state {
            case .ready:
                self.receiveRemote(on: conn)
            case .failed(let error), .waiting(let error):
                self.remoteFailed(tlsError: Self.isTLS(error))
            default:
                break
            }
        }
        conn.start(queue: .main)
    }

    private static func isTLS(_ error: NWError) -> Bool {
        if case .tls = error { return true }
        return false
    }

    private func remoteFailed(tlsError: Bool) {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        let wasConfigured = configured
        configured = false
        if !attemptedPairing && (tlsError || device.token == nil || !wasConfigured) {
            startPairing()
        } else {
            setState(.failed(wasConfigured ? "Connessione persa" : "Android TV non raggiungibile"))
        }
    }

    private func receiveRemote(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak conn] data, _, isComplete, error in
            guard let self = self, let conn = conn, conn === self.connection else { return }
            if let data = data, !data.isEmpty {
                self.buffer += [UInt8](data)
                for frame in ProtoMessage.drainFrames(&self.buffer) {
                    if let message = ProtoMessage(frame) { self.handleRemote(message) }
                }
            }
            if isComplete || error != nil {
                self.remoteFailed(tlsError: false)
            } else {
                self.receiveRemote(on: conn)
            }
        }
    }

    private func sendRemote(_ build: (inout ProtoWriter) -> Void) {
        var writer = ProtoWriter()
        build(&writer)
        connection?.send(content: Data(ProtoWriter.framed(writer.bytes)), completion: .contentProcessed { _ in })
    }

    private func handleRemote(_ message: ProtoMessage) {
        if message.has(1) {
            sendRemote { w in
                w.message(1) { c in
                    c.varint(1, 622)
                    c.message(2) { d in
                        d.string(1, "iPhone")
                        d.string(2, "Apple")
                        d.varint(3, 1)
                        d.string(4, "1")
                        d.string(5, "com.retroremote.app")
                        d.string(6, "1.0.0")
                    }
                }
            }
        }
        if message.has(2) {
            sendRemote { w in w.message(2) { a in a.varint(1, 622) } }
            configured = true
            if device.token == nil { saveToken("paired") }
            setState(.connected)
        }
        if let ping = message.message(8) {
            let value = ping.varint(1) ?? 0
            sendRemote { w in w.message(9) { r in r.varint(1, value) } }
        }
        if message.has(40) {
            configured = true
            setState(.connected)
        }
    }

    // MARK: - Associazione (6467)

    private func startPairing() {
        attemptedPairing = true
        setState(.pairing)
        guard let material = ClientIdentity.shared.load(),
              let conn = makeConnection(port: 6467, identity: material.identity) else {
            setState(.failed("Impossibile creare il certificato"))
            return
        }
        serverKey = nil
        pairingBuffer = []
        pairingConnection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let conn = conn, conn === self.pairingConnection else { return }
            switch state {
            case .ready:
                self.sendPairing { w in
                    w.message(10) { r in
                        r.string(1, "atvremote")
                        r.string(2, "RetroRemote")
                    }
                }
                self.receivePairing(on: conn)
            case .failed, .waiting:
                self.pairingFailed("Android TV non raggiungibile")
            default:
                break
            }
        }
        conn.start(queue: .main)
    }

    private func pairingFailed(_ message: String) {
        pairingConnection?.stateUpdateHandler = nil
        pairingConnection?.cancel()
        pairingConnection = nil
        setState(.failed(message))
    }

    private func receivePairing(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak conn] data, _, isComplete, error in
            guard let self = self, let conn = conn, conn === self.pairingConnection else { return }
            if let data = data, !data.isEmpty {
                self.pairingBuffer += [UInt8](data)
                for frame in ProtoMessage.drainFrames(&self.pairingBuffer) {
                    if let message = ProtoMessage(frame) { self.handlePairing(message) }
                }
            }
            guard conn === self.pairingConnection else { return }
            if isComplete || error != nil {
                self.pairingFailed("Associazione interrotta")
            } else {
                self.receivePairing(on: conn)
            }
        }
    }

    private func sendPairing(_ build: (inout ProtoWriter) -> Void) {
        var writer = ProtoWriter()
        writer.varint(1, 2)
        writer.varint(2, 200)
        build(&writer)
        pairingConnection?.send(content: Data(ProtoWriter.framed(writer.bytes)), completion: .contentProcessed { _ in })
    }

    private func handlePairing(_ message: ProtoMessage) {
        guard message.varint(2) == 200 else {
            pairingFailed("Associazione rifiutata dalla TV")
            return
        }
        if message.has(11) {
            sendPairing { w in
                w.message(20) { o in
                    o.message(1) { e in e.varint(1, 3); e.varint(2, 6) }
                    o.varint(3, 1)
                }
            }
        } else if message.has(20) {
            sendPairing { w in
                w.message(30) { c in
                    c.message(1) { e in e.varint(1, 3); e.varint(2, 6) }
                    c.varint(2, 1)
                }
            }
        } else if message.has(31) {
            askCode()
        } else if message.has(41) {
            pairingConnection?.stateUpdateHandler = nil
            pairingConnection?.cancel()
            pairingConnection = nil
            saveToken("paired")
            openRemote()
        }
    }

    private func askCode() {
        requestPIN(title: "Codice Android TV",
                   message: "Inserisci il codice di 6 caratteri mostrato sulla TV.",
                   hex: true) { [weak self] code in
            guard let self = self, self.pairingConnection != nil else { return }
            guard let code = code?.trimmingCharacters(in: .whitespaces).uppercased(), code.count == 6,
                  let secret = self.secret(for: code) else {
                self.pairingFailed("Codice non valido")
                return
            }
            self.sendPairing { w in w.message(40) { s in s.data(1, secret) } }
        }
    }

    private func secret(for code: String) -> [UInt8]? {
        guard let material = ClientIdentity.shared.load(),
              let serverKey = serverKey,
              let serverData = SecKeyCopyExternalRepresentation(serverKey, nil) as Data?,
              let client = DER.rsaComponents(material.publicKeyPKCS1),
              let server = DER.rsaComponents(serverData) else { return nil }
        var codeBytes: [UInt8] = []
        var index = code.startIndex
        for _ in 0..<3 {
            let next = code.index(index, offsetBy: 2)
            guard let b = UInt8(code[index..<next], radix: 16) else { return nil }
            codeBytes.append(b)
            index = next
        }
        var hash = SHA256()
        hash.update(data: client.modulus)
        hash.update(data: client.exponent)
        hash.update(data: server.modulus)
        hash.update(data: server.exponent)
        hash.update(data: Array(codeBytes[1...]))
        let digest = Array(hash.finalize())
        guard digest.first == codeBytes[0] else { return nil }
        return digest
    }

    // MARK: - Comandi

    override func send(_ key: RemoteKey) {
        guard let code = Self.androidKeyCode(key) else { return }
        guard connection != nil, configured else {
            if connection == nil && pairingConnection == nil { connect() }
            return
        }
        inject(code)
    }

    override func sendText(_ text: String) {
        for character in text.lowercased() {
            guard let code = Self.characterKeyCode(character) else { continue }
            inject(code)
        }
    }

    static func characterKeyCode(_ c: Character) -> Int? {
        guard let ascii = c.asciiValue else { return nil }
        switch c {
        case "a"..."z": return 29 + Int(ascii - 97)
        case "0"..."9": return 7 + Int(ascii - 48)
        case " ": return 62
        case ".": return 56
        case ",": return 55
        case "-": return 69
        case "=": return 70
        case "/": return 76
        case "@": return 77
        case "'": return 75
        case ";": return 74
        case "+": return 81
        default: return nil
        }
    }

    private func inject(_ code: Int) {
        sendRemote { w in
            w.message(10) { k in
                k.varint(1, UInt64(code))
                k.varint(2, 3)
            }
        }
    }

    override func launch(_ app: TVApp) {
        sendRemote { w in w.message(90) { l in l.string(1, app.id) } }
    }
}
