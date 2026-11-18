// SPDX-License-Identifier: GPL-2.0-or-later

#if TIP_JAR

import SwiftUI
import UIKit

/// The Simulator preview's Buy me tokens screens (`-screen tipjar…`), played on
/// the real sheet and model: only the App Store is replaced, by a store that
/// answers as a test says (`TipJarStoreServices`). The product identifiers are
/// the arrangement's example ones. Nothing here talks to the App Store, and
/// nothing exists in a build made without the arrangement.
///
///     -screen tipjar            the sheet over Home, the four tiers
///     -screen tipjar-loading    the store has not answered yet
///     -screen tipjar-missing    the store knows three of the four
///     -screen tipjar-unavailable  the store gave nothing (Try again)
///     -screen tipjar-restricted purchases are not allowed on this device
///     -screen tipjar-purchasing a purchase of Pro is under way
///     -screen tipjar-thanks     Pro was bought
///     -screen tipjar-pending    Pro waits for approval
///     -screen tipjar-failed     Pro failed, with the store's message
///     -screen tipjar-home       Home with the toolbar menu, no sheet
///     -tipPrices us|jp|dk|mixed the store's prices (us); mixed puts four very
///                               different widths side by side
///     -tipHeight full           the sheet at the full height of a page, taller than
///                               its conversation, which stands at the top
///     -tipDeveloperParts a,b    which of name, avatar, github and x the header
///                               shows (all); empty shows none
///
/// The header's developer is the one the build holds: the values the arrangement
/// states (`SHEET_DEVELOPER_NAME`, `_GITHUB` and `_X`) and the assets compiled in
/// with them, the plain glyphs or, for a capture, the files of `Config/Local`.
/// A build without developer values shows the header a product without them does.
enum TipJarPreview {
    static func opensSheet(_ screen: String) -> Bool { screen.hasPrefix("tipjar") && screen != "tipjar-home" }

    /// Readies the model for `screen`: the store it asks, and the sheet that
    /// opens over Home.
    static func configure(screen: String, model: AppModel) {
        let prices = Prices(rawValue: UserDefaults.standard.string(forKey: "tipPrices") ?? "") ?? .us
        var services = TipJarServices()
        services.products = { TipJarProducts(Self.identifiers) }
        services.store = store(for: screen, prices: prices)
        services.previewOpensSheet = opensSheet(screen)
        services.sender = { sender() }
        services.previewFullHeight = UserDefaults.standard.string(forKey: "tipHeight") == "full"
        services.previewPlays = { jar in await prepare(screen: screen, jar: jar) }
        if screen == "tipjar-loading" { services.timeout = .seconds(3600) }
        model.tipJarServices = services
    }

    /// The developer for the header: what the build holds, kept to the parts `-tipDeveloperParts` names.
    @MainActor
    private static func sender() -> TipJarSenderContent {
        let live = TipJarSenderContent.live
        guard let named = UserDefaults.standard.string(forKey: "tipDeveloperParts") else { return live }
        let parts = Set(named.split(separator: ",").map(String.init))
        return TipJarSenderContent(
            name: parts.contains("name") ? live.name : nil, avatar: parts.contains("avatar") ? live.avatar : nil,
            links: live.links.filter { parts.contains($0.site.rawValue) })
    }

    private nonisolated static let identifiers = [
        "lite": "com.example.andarium.tip.lite", "pro": "com.example.andarium.tip.pro",
        "max": "com.example.andarium.tip.max", "ultra": "com.example.andarium.tip.ultra",
    ]

    /// The prices as the store formats each storefront's.
    enum Prices: String {
        case us, jp, dk, mixed

        var values: [String] {
            switch self {
            case .us: ["$1.99", "$4.99", "$19.99", "$49.99"]
            case .jp: ["\u{00A5}300", "\u{00A5}800", "\u{00A5}3,000", "\u{00A5}8,000"]
            case .dk: ["15,00\u{00A0}kr.", "39,00\u{00A0}kr.", "149,00\u{00A0}kr.", "1.499,00\u{00A0}kr."]
            case .mixed: ["US$1.99", "\u{00A5}8,000", "1.499,00\u{00A0}kr", "COP\u{00A0}219.900,00"]
            }
        }
    }

    private struct Down: LocalizedError {
        var errorDescription: String? { "Cannot connect to the App Store." }
    }

    private static func store(for screen: String, prices: Prices) -> TipJarStoreServices {
        let answer = zip(TipJarTier.allCases, prices.values).map { tier, price in
            TipJarProduct(identifier: identifiers[tier.rawValue]!, displayPrice: price)
        }
        return TipJarStoreServices(
            canMakePayments: { screen != "tipjar-restricted" },
            products: { _ in
                switch screen {
                case "tipjar-loading":
                    try await Task.sleep(for: .seconds(3600))
                    return []
                case "tipjar-unavailable": return []
                case "tipjar-missing": return answer.filter { $0.identifier != identifiers["max"] }
                default: return answer
                }
            },
            purchase: { identifier in
                switch screen {
                case "tipjar-pending": return .pending
                case "tipjar-failed": return .failed("Cannot connect to the App Store.")
                case "tipjar-purchasing":
                    try? await Task.sleep(for: .seconds(3600))
                    return .cancelled
                default:
                    // The store's sheet would be up meanwhile.
                    try? await Task.sleep(for: .milliseconds(1400))
                    return .purchased(TipJarTransaction(productIdentifier: identifier) {})
                }
            },
            transactions: { AsyncStream { $0.finish() } })
    }

    /// Plays the person's choice for the screens that show an outcome.
    @MainActor
    private static func prepare(screen: String, jar: TipJarModel) async {
        guard ["tipjar-purchasing", "tipjar-thanks", "tipjar-pending", "tipjar-failed"].contains(screen) else { return }
        jar.start()
        let deadline = ContinuousClock.now + .seconds(10)
        while jar.phase == .loading, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        jar.purchase(.pro)
    }
}

#endif
