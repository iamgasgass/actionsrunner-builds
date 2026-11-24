import Foundation

/// Classe base dei controller. Tutte le callback arrivano sul main thread.
class BaseController: NSObject {
    private(set) var device: TVDevice
    private(set) var state: ConnectionState = .idle

    var onStateChange: ((ConnectionState) -> Void)?
    var onTokenUpdate: ((String) -> Void)?

    init(device: TVDevice) {
        self.device = device
        super.init()
    }

    func connect() {}
    func disconnect() {}
    func send(_ key: RemoteKey) {}
    func sendText(_ text: String) {}
    func fetchApps(_ completion: @escaping ([TVApp]) -> Void) { completion([]) }
    func launch(_ app: TVApp) {}

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

    static func jsonString(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func jsonObject(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
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
