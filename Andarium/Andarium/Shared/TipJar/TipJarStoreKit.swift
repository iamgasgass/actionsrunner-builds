// SPDX-License-Identifier: GPL-2.0-or-later

#if TIP_JAR

import StoreKit
import UIKit

/// The App Store itself: StoreKit 2 behind `TipJarStoreServices`. Four
/// consumable products, bought one at a time; no account, no receipt, no server
/// and nothing kept beyond what StoreKit keeps.
extension TipJarStoreServices {
    nonisolated static var live: TipJarStoreServices {
        TipJarStoreServices(
            canMakePayments: { AppStore.canMakePayments },
            products: { identifiers in
                let products = try await Product.products(for: identifiers)
                await TipJarProductCache.shared.keep(products)
                return products.map { TipJarProduct(identifier: $0.id, displayPrice: $0.displayPrice) }
            },
            purchase: { identifier in await TipJarStoreKit.purchase(identifier) },
            transactions: { TipJarStoreKit.transactions() })
    }
}

/// The products the store last answered for, so that a purchase buys the one
/// the sheet priced.
private actor TipJarProductCache {
    static let shared = TipJarProductCache()
    private var products: [String: Product] = [:]

    func keep(_ answered: [Product]) {
        for product in answered { products[product.id] = product }
    }

    func product(_ identifier: String) -> Product? { products[identifier] }
}

nonisolated enum TipJarStoreKit {
    @MainActor
    static func purchase(_ identifier: String) async -> TipJarPurchase {
        let known = await TipJarProductCache.shared.product(identifier)
        let fetched = known == nil ? try? await Product.products(for: [identifier]).first : nil
        guard let product = known ?? fetched else {
            return .failed(Product.PurchaseError.productUnavailable.localizedDescription)
        }
        do {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            let result = if let scene {
                try await product.purchase(confirmIn: scene)
            } else {
                try await product.purchase()
            }
            switch result {
            case .success(let verification):
                // The store took the payment; whether the signature check on
                // this device passed does not change that, and nothing is
                // delivered for a tip either way. So one that does not verify
                // is finished and thanked as one that does is (left open, a
                // consumable would be offered again at every launch, and
                // saying it failed would invite a second payment).
                let transaction = Self.transaction(of: verification)
                return .purchased(TipJarTransaction(productIdentifier: transaction.productID) { await transaction.finish() })
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending
            @unknown default:
                return .failed(StoreKitError.unknown.localizedDescription)
            }
        } catch StoreKitError.userCancelled {
            return .cancelled
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The transaction a verification result carries, verified or not.
    private static func transaction(of result: VerificationResult<StoreKit.Transaction>) -> StoreKit.Transaction {
        switch result {
        case .verified(let transaction), .unverified(let transaction, _): transaction
        }
    }

    /// What the store has not been told the app finished, and then everything
    /// it delivers outside a purchase made here (an Ask to Buy approval, a
    /// purchase made on another device, one that was interrupted).
    static func transactions() -> AsyncStream<TipJarTransaction> {
        AsyncStream { continuation in
            func deliver(_ result: VerificationResult<StoreKit.Transaction>) {
                // Verified or not: see purchase(_:).
                let transaction = Self.transaction(of: result)
                continuation.yield(
                    TipJarTransaction(productIdentifier: transaction.productID) { await transaction.finish() })
            }
            let unfinished = Task {
                for await result in StoreKit.Transaction.unfinished { deliver(result) }
            }
            let updates = Task {
                for await result in StoreKit.Transaction.updates { deliver(result) }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                unfinished.cancel()
                updates.cancel()
            }
        }
    }
}

#endif
