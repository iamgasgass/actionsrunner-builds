// SPDX-License-Identifier: GPL-2.0-or-later

#if TIP_JAR

import Foundation

/// A tier as the store sells it: the price exactly as the store formats it
/// for this person's storefront.
nonisolated struct TipJarOffer: Equatable, Identifiable, Sendable {
    let tier: TipJarTier
    let price: String
    var id: String { tier.rawValue }
}

/// A product the store answered for.
nonisolated struct TipJarProduct: Equatable, Sendable {
    let identifier: String
    let displayPrice: String
}

/// A purchase the store completed, or one it delivers later. `finish` tells the
/// store the app has dealt with it, which a consumable needs before the same
/// product can be bought again. The app delivers nothing for a tip, so there is
/// never anything to hold it back for.
nonisolated struct TipJarTransaction: Sendable {
    let productIdentifier: String
    let finish: @Sendable () async -> Void
}

/// How a purchase ended.
nonisolated enum TipJarPurchase: Sendable {
    case purchased(TipJarTransaction)
    /// The person dismissed the store's sheet: nothing is said.
    case cancelled
    /// The purchase waits for someone else to approve it (Ask to Buy). It
    /// completes later through the store's updates.
    case pending
    /// The store's own message.
    case failed(String)
}

/// What the tip jar asks of the App Store, in one place a test or the
/// Simulator preview replaces. The live one is StoreKit 2
/// (`TipJarStoreKit.swift`); nothing here keeps a purchase, a receipt or an
/// account.
nonisolated struct TipJarStoreServices: Sendable {
    /// `AppStore.canMakePayments`: purchases are not restricted on this device.
    var canMakePayments: @Sendable () -> Bool
    /// The store's answer for these identifiers: the ones it knows.
    var products: @Sendable ([String]) async throws -> [TipJarProduct]
    /// Buys one product, presenting the store's own sheet.
    var purchase: @Sendable (String) async -> TipJarPurchase
    /// The transactions the app has not finished (an interrupted purchase), and
    /// then every one the store delivers outside a purchase made here: Ask to
    /// Buy approvals and purchases made on another device.
    var transactions: @Sendable () -> AsyncStream<TipJarTransaction>
}

/// The one rule about transactions that arrive on their own.
nonisolated enum TipJarUpdates {
    /// Finishes every transaction the sequence delivers, however it verified:
    /// a tip unlocks nothing, so nothing waits on the result, and a consumable
    /// left unfinished would stay in the store's queue and be offered again at
    /// every launch.
    static func finishAll(_ transactions: AsyncStream<TipJarTransaction>) async {
        for await transaction in transactions {
            await transaction.finish()
        }
    }

    /// Starts listening for the life of the process.
    @discardableResult
    static func listen(_ store: TipJarStoreServices) -> Task<Void, Never> {
        let transactions = store.transactions()
        return Task.detached(priority: .utility) { await finishAll(transactions) }
    }
}

#endif
