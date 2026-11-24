import Foundation
import Security

/// Chiave RSA 2048 + certificato client autofirmato salvati nel portachiavi.
/// Servono per l'associazione con Android TV (TLS reciproco) e per l'autenticazione ADB (Fire TV).
final class ClientIdentity {
    static let shared = ClientIdentity()

    struct Material {
        let identity: SecIdentity
        let privateKey: SecKey
        let publicKeyPKCS1: Data
    }

    private let keyTag = Data("com.retroremote.client-key".utf8)
    private let certLabel = "RetroRemote Client"
    private let lock = NSLock()
    private var cached: Material?

    func load() -> Material? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cached { return cached }
        guard let privateKey = existingKey() ?? createKey(),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { return nil }
        let identity = findIdentity(publicKey: publicData) ?? createIdentity(privateKey: privateKey, publicKey: publicData)
        guard let id = identity else { return nil }
        let material = Material(identity: id, privateKey: privateKey, publicKeyPKCS1: publicData)
        cached = material
        return material
    }

    private func existingKey() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let found = item else { return nil }
        return (found as! SecKey)
    }

    private func createKey() -> SecKey? {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ] as [String: Any]
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateRandomKey(attributes as CFDictionary, &error)
    }

    private func findIdentity(publicKey: Data) -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [Any] else { return nil }
        for item in items {
            let identity = item as! SecIdentity
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let cert = certificate,
                  let key = SecCertificateCopyKey(cert),
                  let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else { continue }
            if data == publicKey { return identity }
        }
        return nil
    }

    private func createIdentity(privateKey: SecKey, publicKey: Data) -> SecIdentity? {
        guard let der = Self.selfSignedCertificate(publicKeyPKCS1: publicKey, privateKey: privateKey,
                                                   commonName: "RetroRemote"),
              let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        let add: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: certLabel
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { return nil }
        return findIdentity(publicKey: publicKey)
    }

    static func selfSignedCertificate(publicKeyPKCS1: Data, privateKey: SecKey, commonName: String) -> Data? {
        let algorithm = DER.sequence([DER.oidSHA256WithRSA, DER.null])
        let name = DER.sequence([DER.set([DER.sequence([DER.oidCommonName, DER.utf8(commonName)])])])
        var serial = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] = (serial[0] & 0x7F) | 0x01
        let now = Date()
        let validity = DER.sequence([DER.utcTime(now.addingTimeInterval(-86_400)),
                                     DER.utcTime(now.addingTimeInterval(86_400 * 365 * 20))])
        let spki = DER.sequence([DER.sequence([DER.oidRSAEncryption, DER.null]),
                                 DER.bitString([UInt8](publicKeyPKCS1))])
        let tbs = DER.sequence([DER.explicit(0, DER.integer([2])), DER.integer(serial),
                                algorithm, name, validity, name, spki])
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                    Data(tbs) as CFData, &error) as Data? else { return nil }
        return Data(DER.sequence([tbs, algorithm, DER.bitString([UInt8](signature))]))
    }
}
