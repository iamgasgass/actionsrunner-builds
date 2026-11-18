// SPDX-License-Identifier: GPL-2.0-or-later

#if TIP_JAR

import Foundation

// Buy me tokens' logic: plain values and rules, no UIKit, SwiftUI or StoreKit.
// The application compiles these files with the rest of the tip jar, and only
// where it is compiled in; the AndariumCore package compiles the same files for
// its tests (Andarium/README.md#buy-me-tokens).

/// The four tips. A tier's name is the app's own and the same in every
/// language; the store supplies only the price.
nonisolated enum TipJarTier: String, CaseIterable, Identifiable, Sendable {
    case lite, pro, max, ultra

    var id: String { rawValue }

    var name: String {
        switch self {
        case .lite: "Lite"
        case .pro: "Pro"
        case .max: "Max"
        case .ultra: "Ultra"
        }
    }
}

/// The App Store product identifier of each tier, which the build reads from
/// the ignored local configuration (`Config/TipJar.local.xcconfig`) and writes
/// to Info.plist only where the tip jar is compiled in.
nonisolated struct TipJarProducts: Equatable, Sendable {
    private let identifiers: [TipJarTier: String]

    /// The four identifiers by tier name (`lite`, `pro`, `max`, `ultra`); nil
    /// unless every tier has one that is well formed, and no two are the same.
    init?(_ named: [String: String]) {
        var identifiers: [TipJarTier: String] = [:]
        for tier in TipJarTier.allCases {
            guard let identifier = named[tier.rawValue], Self.isWellFormed(identifier) else { return nil }
            identifiers[tier] = identifier
        }
        guard Set(identifiers.values).count == TipJarTier.allCases.count else { return nil }
        self.identifiers = identifiers
    }

    /// The identifiers in tier order.
    var all: [String] { TipJarTier.allCases.compactMap { identifiers[$0] } }

    func identifier(for tier: TipJarTier) -> String { identifiers[tier] ?? "" }

    func tier(for identifier: String) -> TipJarTier? {
        TipJarTier.allCases.first { identifiers[$0] == identifier }
    }

    /// One strict shape, the one the App Store bundle check holds the build's
    /// identifiers to (`Andarium/scripts/check-app-store-bundle.py`): 1 to 100
    /// letters, digits, `.`, `_` and `-`, starting with a letter or digit.
    static func isWellFormed(_ identifier: String) -> Bool {
        let bytes = Array(identifier.utf8)
        guard (1...100).contains(bytes.count), isAlphanumeric(bytes[0]) else { return false }
        return bytes.allSatisfy { isAlphanumeric($0) || "._-".utf8.contains($0) }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
    }
}

/// Where the identifiers are read from.
nonisolated enum TipJarConfiguration {
    /// The Info.plist key the build writes the identifiers to, a dictionary
    /// with a string for each tier, only where the tip jar is compiled in
    /// (`Config/Andarium.xcconfig`).
    static let key = "AndariumTipProducts"

    static var products: TipJarProducts? {
        guard let named = Bundle.main.object(forInfoDictionaryKey: key) as? [String: String] else { return nil }
        return TipJarProducts(named)
    }
}

#endif
