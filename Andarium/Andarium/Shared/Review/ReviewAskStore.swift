// SPDX-License-Identifier: GPL-2.0-or-later

#if APP_REVIEW

import Foundation
import Security

/// Where the rating prompt keeps what it knows, on this device only.
///
/// The counter and the previous run's end are in the application's defaults. The
/// record that the prompt was asked for, or the review page opened, is in the
/// defaults and in a Keychain item, and is read back as the furthest of the
/// two. The defaults go with the application when it is deleted; the Keychain
/// item stays, as every Keychain item of the application does, so a person
/// who reinstalls is not asked again. The item is the application's own
/// default access group, local to the device and excluded from backups to
/// another one: no iCloud, no new capability or entitlement. Erase guest
/// deletes the adb key (`AdbKeyStore`) and nothing else, so it leaves this
/// item alone.
nonisolated struct ReviewAskStore: ReviewAskPersistence, @unchecked Sendable {
    static let secondsKey = "ReviewAskActiveSeconds"
    static let lastRunKey = "ReviewAskLastRunNormal"
    static let historyKey = "ReviewAskHistory"

    let defaults: UserDefaults
    let keychain: ReviewAskKeychain

    init(defaults: UserDefaults = .standard, keychain: ReviewAskKeychain = ReviewAskKeychain()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    func loadSnapshot() -> ReviewAskSnapshot {
        ReviewAskSnapshot(
            activeSeconds: defaults.object(forKey: Self.secondsKey) as? Double ?? 0,
            lastRunEndedNormally: defaults.object(forKey: Self.lastRunKey) as? Bool ?? true)
    }

    func save(_ snapshot: ReviewAskSnapshot) {
        defaults.set(snapshot.activeSeconds, forKey: Self.secondsKey)
        defaults.set(snapshot.lastRunEndedNormally, forKey: Self.lastRunKey)
    }

    func loadHistory() -> ReviewAskHistory? {
        var readings: [ReviewAskHistory] = []
        if let data = defaults.data(forKey: Self.historyKey) {
            // Present and damaged is not the same as absent.
            guard let history = try? JSONDecoder().decode(ReviewAskHistory.self, from: data) else { return nil }
            readings.append(history)
        }
        switch keychain.read() {
        case .absent:
            break
        case let .found(data):
            guard let history = try? JSONDecoder().decode(ReviewAskHistory.self, from: data) else { return nil }
            readings.append(history)
        case .failed:
            return nil
        }
        return readings.reduce(ReviewAskHistory()) { $0.merged(with: $1) }
    }

    func save(_ history: ReviewAskHistory) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: Self.historyKey)
        keychain.write(data)
    }
}

/// One generic-password item of the application's: a few bytes of JSON.
nonisolated struct ReviewAskKeychain: Sendable {
    enum Reading: Equatable {
        case absent
        case found(Data)
        case failed(OSStatus)
    }

    /// The application's own bundle identifier names the item, so that a fork's
    /// build, which has its own, carries nothing of another's.
    static var defaultService: String { "\(Bundle.main.bundleIdentifier ?? "Andarium").review-ask" }
    static let account = "history"

    /// A test names a service of its own.
    let service: String

    init(service: String = ReviewAskKeychain.defaultService) {
        self.service = service
    }

    private var identity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func read() -> Reading {
        var item: CFTypeRef?
        let query = identity.merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data else { return .failed(errSecDecode) }
            return .found(data)
        case errSecItemNotFound:
            return .absent
        case let status:
            return .failed(status)
        }
    }

    /// Writes the item, replacing what is there. A write that fails leaves the
    /// defaults' copy, which is all the rating prompt needs to ask once.
    @discardableResult
    func write(_ data: Data) -> Bool {
        let update = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        let add = identity.merging([
            kSecValueData as String: data,
            // After the first unlock, so that the application reads it whenever it runs, and
            // never on another device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrLabel as String: "Andarium rating prompt",
        ]) { _, new in new }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

#endif
