// SPDX-License-Identifier: GPL-2.0-or-later
import CryptoKit
import Foundation
import Security
import UIKit

/// The developer certificate JIT-less mode signs a game's converted libraries with (JITLess.swift). iOS loads a library in a
/// sideloaded app only when it is signed by the same team as the app, so this has to be the certificate SideStore or AltStore
/// installed Husk with. It comes from the store itself (it hands it over through a URL callback) or from a .p12 file and its
/// password. Kept in the Keychain; nothing leaves the device.
@MainActor
final class SigningCertificate: ObservableObject {
    static let shared = SigningCertificate()

    struct Info: Equatable {
        let teamID: String
        let expires: Date
        /// Names this certificate in the converted libraries' .signer files: a new one means they are signed again.
        let tag: String
    }

    @Published private(set) var info: Info?
    @Published var lastError: String?
    /// HUSK_P12_* of the last import that failed to open the .p12 (nil after one that opened).
    private var lastFailure: Int?

    private static let service = "com.husk.signing"
    private static let callbackScheme = "husk"
    private static let callbackHost = "certificate"

    private init() { info = Self.loadStored().flatMap { try? Self.open($0.p12, $0.password).get().info } }

    // MARK: - what the signer needs

    /// The certificate and password, for signing (read from the Keychain each time).
    nonisolated static func credentials() -> (p12: Data, password: String, tag: String)? {
        guard let s = loadStored() else { return nil }
        return (s.p12, s.password, tag(s.p12))
    }

    // MARK: - importing

    /// A .p12 file and its password (empty when it has none).
    /// True when it was imported (lastError may still hold a warning, such as an expired certificate).
    @discardableResult
    func importP12(_ raw: Data, password: String, fromStore: Bool = false) -> Bool {
        let data = Self.normalized(raw)
        let decoded = data.count != raw.count ? " (\(data.count) after decoding text)" : ""
        HuskLog.log("sign", "opening .p12: \(raw.count) bytes\(decoded), password length \(password.count)")
        let opened: (info: Info, password: String)
        switch Self.open(data, password) {
        case .success(let o):
            opened = o
            lastFailure = nil
        case .failure(let failure):
            lastFailure = failure.code
            lastError = Self.message(failure, passwordGiven: !password.isEmpty, fromStore: fromStore)
            return false
        }
        if let team = Self.installedTeamID, team != opened.info.teamID {
            lastError = "This certificate belongs to team \(opened.info.teamID), but Husk was installed with team \(team). "
                      + "Use the certificate of the Apple ID that installed Husk."
            return false
        }
        guard Self.store(data, opened.password) else { lastError = "The certificate could not be saved in the Keychain."; return false }
        info = opened.info
        // Same team is not enough: iOS trusts only the certificate Husk itself was installed with (the store's profile lists it)
        let sameCertificate = data.withUnsafeBytes { b in
            husk_p12_matches_app(b.bindMemory(to: UInt8.self).baseAddress, b.count, opened.password, Bundle.main.executablePath)
        }
        HuskLog.log("sign", "certificate is the one Husk is installed with: \(sameCertificate == 1 ? "yes" : sameCertificate == 0 ? "no" : "unknown")")
        lastError = opened.info.expires < Date()
            ? "Imported, but this certificate expired on \(opened.info.expires.formatted(date: .abbreviated, time: .omitted)). "
              + "Refresh Husk in your store, then import its new certificate."
            : sameCertificate == 0
            ? "Imported, but this is not the certificate Husk was installed with, so iOS will refuse the libraries it signs. "
              + "Export the .p12 again from the store that installed Husk (after its last refresh) and import that."
            : nil
        HuskLog.log("sign", "certificate imported: team \(opened.info.teamID), expires \(opened.info.expires)")
        return true
    }

    /// A .p12 picked in Husk: imported straight away when it has no password. True when it needs one, to be asked for;
    /// false when it was imported or when it cannot be used whatever the password (lastError says why).
    func importPicked(_ data: Data) -> Bool {
        if importP12(data, password: "") { return false }
        guard lastFailure == Int(HUSK_P12_BAD_PASSWORD) else { return false }
        lastError = nil
        return true
    }

    /// Why a .p12 did not open, from husk_p12_check.
    struct OpenFailure: Error {
        let code: Int
        let detail: String
    }

    private static func message(_ f: OpenFailure, passwordGiven: Bool, fromStore: Bool) -> String {
        switch f.code {
        case Int(HUSK_P12_BAD_PASSWORD):
            if fromStore {
                return "The store's certificate did not open with the password it sent. Refresh Husk in the store and try again, "
                     + "or export the certificate as a .p12 and import that."
            }
            return passwordGiven
                ? "That password did not open the .p12. Passwords are case-sensitive; check it, or export the certificate again."
                : "That .p12 needs a password. Enter the one you set when you exported it."
        case Int(HUSK_P12_NO_KEY):
            return "This file has the certificate but not its private key, so Husk cannot sign with it. Export it again with the "
                 + "key (in Keychain Access, expand the certificate and export both together, as .p12)."
        case Int(HUSK_P12_NO_CERT):
            return "This file has a private key but no certificate. Export the certificate and its key together, as .p12."
        case Int(HUSK_P12_NOT_P12):
            return "That file is not a .p12 certificate (\(f.detail)). A .mobileprovision or .cer file is not enough: "
                 + "Play without JIT needs the .p12 with the private key."
        case Int(HUSK_P12_NOT_APPLE):
            return "That certificate opened, but it is not an Apple developer certificate (it names no team)."
        default:
            return "That .p12 could not be used: \(f.detail)."
        }
    }

    /// A .p12 saved as text (base64, as some signing services and stores hand it over, maybe with PEM-style lines) is decoded;
    /// a binary .p12 is left as it is.
    nonisolated static func normalized(_ data: Data) -> Data {
        guard let first = data.first, first != 0x30, data.count < 16 << 20,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return data }
        let body = text.split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("-----") && !$0.contains(":") }
            .joined()
        guard let decoded = p12(fromBase64: body), decoded.first == 0x30, decoded.count > 32 else { return data }
        return decoded
    }

    /// Ask SideStore or AltStore for the certificate it signs Husk with; it answers by opening husk://certificate?cert=…&password=…
    func requestFromStore(_ store: Store) {
        let callback = "\(Self.callbackScheme)://\(Self.callbackHost)?cert=$(BASE64_CERT)&password=$(PASSWORD)"
        guard let encoded = callback.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "\(store.scheme)://certificate?callback_template=\(encoded)") else { return }
        HuskLog.log("sign", "asking \(store.title) for its certificate")
        UIApplication.shared.open(url) { [weak self] ok in
            if !ok { Task { @MainActor in self?.lastError = "\(store.title) is not installed, or did not answer." } }
        }
    }

    /// husk://certificate?cert=<base64>&password=<password>, from SideStore or AltStore. False when the URL is not one.
    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == Self.callbackScheme, url.host?.lowercased() == Self.callbackHost else { return false }
        // Split the raw query so '+' stays '+' (URLComponents turns it into a space, which breaks base64 and passwords).
        func value(_ name: String) -> String? {
            let raw = Self.rawQueryItems(url)[name]
                ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name.lowercased() == name })?.value
            guard var s = raw, !s.isEmpty else { return raw }
            if let once = s.removingPercentEncoding { s = once }
            return s
        }
        guard let cert = value("cert"), let data = Self.p12(fromBase64: cert), data.count > 32 else {
            lastError = "The store's answer had no certificate in it."
            return true
        }
        var password = value("password") ?? value("pass") ?? ""
        if password == "$(PASSWORD)" { password = "" }
        HuskLog.log("sign", "store certificate: \(data.count) bytes, password length \(password.count)")
        importP12(data, password: password, fromStore: true)
        return true
    }

    func remove() {
        for account in ["p12", "password"] {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: Self.service, kSecAttrAccount: account] as CFDictionary)
        }
        info = nil
        HuskLog.log("sign", "certificate removed")
    }

    enum Store: CaseIterable, Identifiable {
        case sideStore, altStore
        var id: Self { self }
        var title: String { self == .sideStore ? "SideStore" : "AltStore" }
        var scheme: String { self == .sideStore ? "sidestore" : "altstore-classic" }
    }

    // MARK: - the team Husk was installed with

    /// From the provisioning profile the sideloader embedded; nil when there is none (TrollStore, a development build).
    nonisolated static var installedTeamID: String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url),
              let start = raw.range(of: Data("<?xml".utf8)), let end = raw.range(of: Data("</plist>".utf8), in: start.lowerBound..<raw.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: raw[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        return (plist["TeamIdentifier"] as? [String])?.first
    }

    // MARK: - Keychain and inspection

    /// SideStore percent-encodes the cert; a leftover '+' may still arrive as a space. Also accepts base64url.
    private nonisolated static func p12(fromBase64 raw: String) -> Data? {
        var s = raw.replacingOccurrences(of: " ", with: "+")
        if let again = s.removingPercentEncoding { s = again }
        s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .filter { !$0.isWhitespace }
        let pad = (4 - s.count % 4) % 4
        if pad > 0 { s += String(repeating: "=", count: pad) }
        return Data(base64Encoded: s) ?? Data(base64Encoded: s, options: .ignoreUnknownCharacters)
    }

    private nonisolated static func rawQueryItems(_ url: URL) -> [String: String] {
        let text = url.absoluteString
        guard let q = text.split(separator: "?", maxSplits: 1).dropFirst().first else { return [:] }
        var out: [String: String] = [:]
        for part in q.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = kv.first?.lowercased(), !name.isEmpty else { continue }
            out[name] = kv.count > 1 ? String(kv[1]) : ""
        }
        return out
    }

    /// The forms of a password worth trying: as typed or sent, and the ways a store's URL or the keyboard can bend it (spaces at
    /// either end, a '+' that became a space, leftover percent-encoding). "" and no password at all are tried by the C side
    /// (husk_p12_check), which tells from the .p12's MAC which one is right -- SideStore can re-save the .p12 with no password
    /// and still send the old one.
    private nonisolated static func passwordCandidates(_ given: String) -> [String] {
        var out: [String] = []
        func add(_ s: String) { if !out.contains(s) { out.append(s) } }
        let trimmed = given.trimmingCharacters(in: .whitespacesAndNewlines)
        add(given)
        add(trimmed)
        add(trimmed.replacingOccurrences(of: " ", with: "+"))
        if let decoded = trimmed.removingPercentEncoding { add(decoded) }
        return out
    }

    private nonisolated static func open(_ p12: Data, _ password: String) -> Result<(info: Info, password: String), OpenFailure> {
        var failure = OpenFailure(code: Int(HUSK_P12_NOT_P12), detail: "empty file")
        for candidate in passwordCandidates(password) {
            var team = [CChar](repeating: 0, count: 64), err = [CChar](repeating: 0, count: 300)
            var notAfter: Double = 0
            let rc = p12.withUnsafeBytes { b in
                husk_p12_check(b.bindMemory(to: UInt8.self).baseAddress, b.count, candidate, &team, team.count, &notAfter, &err, err.count)
            }
            if Int(rc) == Int(HUSK_P12_OK) {
                return .success((Info(teamID: String(cString: team), expires: Date(timeIntervalSince1970: notAfter), tag: tag(p12)), candidate))
            }
            failure = OpenFailure(code: Int(rc), detail: String(cString: err))
            // Only a wrong password is worth another form of it; anything else is about the file.
            if Int(rc) != Int(HUSK_P12_BAD_PASSWORD) { break }
        }
        HuskLog.log("sign", "certificate not usable: \(failure.detail) (\(failure.code))")
        return .failure(failure)
    }

    private nonisolated static func tag(_ p12: Data) -> String {
        SHA256.hash(data: p12).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func store(_ p12: Data, _ password: String) -> Bool {
        func put(_ account: String, _ value: Data) -> Bool {
            let key: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
            SecItemDelete(key as CFDictionary)
            var add = key
            add[kSecValueData] = value
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return put("p12", p12) && put("password", Data(password.utf8))
    }

    private nonisolated static func loadStored() -> (p12: Data, password: String)? {
        func get(_ account: String) -> Data? {
            var out: CFTypeRef?
            let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
            return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
        }
        guard let p12 = get("p12") else { return nil }
        return (p12, get("password").flatMap { String(data: $0, encoding: .utf8) } ?? "")
    }
}
