// SPDX-License-Identifier: GPL-2.0-or-later

#if TIP_JAR

import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import Andarium

/// The live StoreKit adapter against StoreKit's own test environment: a
/// session that serves the four example products of `TipJar.storekit` and plays
/// the App Store's side (a purchase, a cancelled one, Ask to Buy, a failure).
/// Nothing reaches the App Store; no account, receipt or real purchase is
/// involved. They run where the tip jar is compiled in: a build made with the
/// four example identifiers on the xcodebuild command line.
@Suite(.serialized)
@MainActor
struct TipJarStoreKitTests {
    private static let identifiers = ["lite", "pro", "max", "ultra"].map { "com.example.andarium.tip.\($0)" }
    private let products = TipJarProducts([
        "lite": "com.example.andarium.tip.lite", "pro": "com.example.andarium.tip.pro",
        "max": "com.example.andarium.tip.max", "ultra": "com.example.andarium.tip.ultra",
    ])!

    /// The test environment's session serves the products only while it is
    /// alive, so the suite's instance (one per test) holds it for the test.
    private let session: SKTestSession

    /// StoreKit wants `Transaction.updates` iterated before a purchase is made (it says so, and
    /// the purchase does not complete otherwise). The application's own launch does that where it
    /// finishes what it hears, which would race the tests, so under a test it does not run, and
    /// the suite iterates the updates itself, finishing nothing, for the life of the process.
    private static let updatesIterated = Task { for await _ in StoreKit.Transaction.updates {} }

    init() throws {
        _ = Self.updatesIterated
        let bundle = Bundle(for: BundleMarker.self)
        let file = bundle.url(forResource: "TipJar", withExtension: "storekit")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("TipJar.storekit")
        session = try SKTestSession(contentsOf: file)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        session.failTransactionsEnabled = false
    }

    private final class BundleMarker {}

    /// The session's storefront arrives asynchronously, and the first request on a fresh
    /// Simulator can precede it and get nothing; the tests start once the store serves the four
    /// products. The wait is bounded.
    private func serving() async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if let found = try? await Product.products(for: Self.identifiers), found.count == Self.identifiers.count { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        Issue.record("the test session never served the four products")
        throw CancellationError()
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    /// What the store has not been told the app finished.
    private func unfinished() async -> [String] {
        var left: [String] = []
        for await result in StoreKit.Transaction.unfinished {
            switch result {
            case .verified(let transaction), .unverified(let transaction, _): left.append(transaction.productID)
            }
        }
        return left
    }

    @Test func theStoreAnswersForTheFourProductsWithItsOwnPrices() async throws {
        try await serving()
        let jar = TipJarModel(products: products, store: .live)
        jar.start()
        #expect(await eventually { jar.phase != .loading })
        #expect(jar.phase == .loaded && jar.canMakePayments)
        #expect(jar.offers.map(\.tier) == TipJarTier.allCases)
        // The store formats each price for the storefront; the app holds none.
        #expect(jar.offers.map(\.price) == ["$1.99", "$4.99", "$19.99", "$49.99"])
    }

    @Test func aPurchaseIsFinishedAndThanksAndNothingIsLeftToDeliver() async throws {
        try await serving()
        let jar = TipJarModel(products: products, store: .live)
        jar.start()
        #expect(await eventually { jar.phase == .loaded })
        jar.purchase(.pro)
        #expect(await eventually { jar.outcome != nil })
        #expect(jar.outcome == .thanks(.pro) && jar.thanked && jar.shownTiers.isEmpty)
        #expect(await eventually { await unfinished().isEmpty }, "the transaction was finished")
        // A consumable can be bought again in the next visit.
        let next = TipJarModel(products: products, store: .live)
        next.start()
        #expect(await eventually { next.phase == .loaded })
        next.purchase(.pro)
        #expect(await eventually { next.outcome != nil })
        #expect(next.outcome == .thanks(.pro))
        #expect(await eventually { await unfinished().isEmpty }, "the second transaction was finished")
    }

    @Test func aPurchaseThatTheStoreFailsShowsTheStoresMessageAndLeavesTheTiers() async throws {
        try await serving()
        session.failTransactionsEnabled = true
        let jar = TipJarModel(products: products, store: .live)
        jar.start()
        #expect(await eventually { jar.phase == .loaded })
        jar.purchase(.lite)
        #expect(await eventually { jar.outcome != nil })
        guard case .failed(.lite, let message)? = jar.outcome else {
            Issue.record("expected a failure, got \(String(describing: jar.outcome))")
            return
        }
        #expect(!message.isEmpty)
        #expect(jar.canBuy && jar.shownTiers == TipJarTier.allCases)
        #expect(await unfinished().isEmpty)
    }

    @Test func askToBuyWaitsForApprovalAndTheListenerFinishesItWhenItArrives() async throws {
        try await serving()
        session.askToBuyEnabled = true
        let listener = TipJarUpdates.listen(.live)
        defer { listener.cancel() }
        let jar = TipJarModel(products: products, store: .live)
        jar.start()
        #expect(await eventually { jar.phase == .loaded })
        jar.purchase(.max)
        #expect(await eventually { jar.outcome != nil })
        #expect(jar.outcome == .pending(.max))
        #expect(jar.canBuy, "the tiers stay offered while the approval waits")
        let waiting = try #require(session.allTransactions().first { $0.state == .deferred })
        // The organiser approves, later and with no sheet open.
        jar.close()
        try session.approveAskToBuyTransaction(identifier: waiting.identifier)
        #expect(await eventually { await unfinished().isEmpty && session.allTransactions().contains { $0.state == .purchased } })
        #expect(jar.outcome == nil, "a closed sheet shows nothing")
    }

    @Test func aTransactionLeftUnfinishedIsFinishedAtLaunch() async throws {
        try await serving()
        // A purchase made outside the app, which nobody finished. The application's own launch
        // listener does not run under a test, so it is the one this test starts that finishes it.
        // The store lists it as unfinished a moment after the purchase returns (on a Simulator that
        // has just booted, a little more than a moment).
        try await session.buyProduct(identifier: "com.example.andarium.tip.ultra")
        #expect(
            await eventually { await unfinished() == ["com.example.andarium.tip.ultra"] },
            "the purchase is open until a listener finishes it")
        let listener = TipJarUpdates.listen(.live)
        defer { listener.cancel() }
        #expect(await eventually { await unfinished().isEmpty }, "the listener finished what was open at launch")
        #expect(session.allTransactions().contains { $0.productIdentifier == "com.example.andarium.tip.ultra" && $0.state == .purchased })
    }

    @Test func purchasesTheDeviceMayNotMakeAreSaidBeforeAnyPurchase() async throws {
        try await serving()
        // The live answer is the system's; the test environment allows purchases.
        #expect(TipJarStoreServices.live.canMakePayments())
        // The model dims the tiers and refuses a purchase when the answer is no.
        var store = TipJarStoreServices.live
        store.canMakePayments = { false }
        let jar = TipJarModel(products: products, store: store)
        jar.start()
        #expect(await eventually { jar.phase == .loaded })
        #expect(!jar.canMakePayments && !jar.canBuy)
        jar.purchase(.pro)
        #expect(jar.purchasing == nil && jar.outcome == nil)
        #expect(await unfinished().isEmpty && session.allTransactions().isEmpty)
    }
}

#endif
