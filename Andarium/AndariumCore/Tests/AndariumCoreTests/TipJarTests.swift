// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing

@testable import AndariumTipJarLogic

/// Buy me tokens' logic: the identifiers, every state of the sheet, the rule for
/// transactions that arrive on their own and what the sheet keeps (nothing). The
/// package compiles the application's own sources for this, with the tip jar's
/// condition set, and a fake store stands for the App Store.
@MainActor
struct TipJarTests {
    private static let identifiers = [
        "lite": "com.example.andarium.tip.lite", "pro": "com.example.andarium.tip.pro",
        "max": "com.example.andarium.tip.max", "ultra": "com.example.andarium.tip.ultra",
    ]
    private let products = TipJarProducts(TipJarTests.identifiers)!

    /// The App Store as a test plays it: what it answers, whether it may be
    /// asked, and what became of every transaction it handed out.
    private final class FakeStore: @unchecked Sendable {
        private let lock = NSLock()
        private var _answer: Result<[TipJarProduct], Error> = .success([])
        private var _payments = true
        private var _delay: Duration?
        private var _purchase: @Sendable (String) async -> TipJarPurchase = { _ in .cancelled }
        private var _asked: [[String]] = []
        private var _finished: [String] = []

        var answer: Result<[TipJarProduct], Error> {
            get { lock.withLock { _answer } }
            set { lock.withLock { _answer = newValue } }
        }
        var payments: Bool {
            get { lock.withLock { _payments } }
            set { lock.withLock { _payments = newValue } }
        }
        /// The store takes this long to answer for products.
        var delay: Duration? {
            get { lock.withLock { _delay } }
            set { lock.withLock { _delay = newValue } }
        }
        var purchase: @Sendable (String) async -> TipJarPurchase {
            get { lock.withLock { _purchase } }
            set { lock.withLock { _purchase = newValue } }
        }
        var asked: [[String]] { lock.withLock { _asked } }
        var finished: [String] { lock.withLock { _finished } }

        func transaction(_ identifier: String) -> TipJarTransaction {
            TipJarTransaction(productIdentifier: identifier) { [self] in
                lock.withLock { _finished.append(identifier) }
            }
        }

        func services(updates: AsyncStream<TipJarTransaction> = AsyncStream { $0.finish() }) -> TipJarStoreServices {
            TipJarStoreServices(
                canMakePayments: { [self] in payments },
                products: { [self] identifiers in
                    lock.withLock { _asked.append(identifiers) }
                    if let delay { try await Task.sleep(for: delay) }
                    return try answer.get()
                },
                purchase: { [self] identifier in await purchase(identifier) },
                transactions: { updates })
        }
    }

    private struct StoreDown: Error, LocalizedError {
        var errorDescription: String? { "Cannot connect to the App Store." }
    }

    private static func prices(_ priced: [(TipJarTier, String)]) -> [TipJarProduct] {
        priced.map { TipJarProduct(identifier: identifiers[$0.0.rawValue]!, displayPrice: $0.1) }
    }

    private static let usPrices = prices([(.lite, "$1.99"), (.pro, "$4.99"), (.max, "$19.99"), (.ultra, "$49.99")])

    private func model(_ store: FakeStore, timeout: Duration = .seconds(20)) -> TipJarModel {
        TipJarModel(products: products, store: store.services(), timeout: timeout)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    // MARK: The identifiers

    @Test func theFourIdentifiersAreRequiredWellFormedAndDistinct() {
        #expect(products.all == Self.identifiers.keys.sorted { lhs, rhs in
            TipJarTier.allCases.firstIndex { $0.rawValue == lhs }! < TipJarTier.allCases.firstIndex { $0.rawValue == rhs }!
        }.map { Self.identifiers[$0]! })
        #expect(products.tier(for: "com.example.andarium.tip.max") == .max)
        #expect(products.tier(for: "com.example.andarium.tip.other") == nil)
        #expect(products.identifier(for: .ultra) == "com.example.andarium.tip.ultra")
        for missing in TipJarTier.allCases {
            var named = Self.identifiers
            named[missing.rawValue] = nil
            #expect(TipJarProducts(named) == nil, "without \(missing)")
            named[missing.rawValue] = ""
            #expect(TipJarProducts(named) == nil, "empty \(missing)")
        }
        var same = Self.identifiers
        same["pro"] = same["lite"]
        #expect(TipJarProducts(same) == nil)
        for bad in ["", " ", "a b", "com.example.\"x\"", "-a.b", ".a.b", "a.b;", "a.b\n", "\u{00E9}.b", String(repeating: "a", count: 101)] {
            var named = Self.identifiers
            named["lite"] = bad
            #expect(TipJarProducts(named) == nil, "\(bad.debugDescription)")
        }
        for good in ["a", "com.example.a_b-c.D1", String(repeating: "a", count: 100)] {
            #expect(TipJarProducts.isWellFormed(good), "\(good)")
        }
    }

    // MARK: Loading

    @Test func theTiersLoadWithTheStoresOwnPrices() async {
        let store = FakeStore()
        store.answer = .success(Self.usPrices)
        let jar = model(store)
        #expect(jar.phase == .loading && jar.shownTiers == TipJarTier.allCases && !jar.canBuy, "the tiers show before the prices")
        jar.start()
        #expect(await eventually { jar.phase == .loaded })
        #expect(jar.offers.map(\.price) == ["$1.99", "$4.99", "$19.99", "$49.99"])
        #expect(jar.shownTiers == TipJarTier.allCases && jar.canBuy)
        #expect(store.asked == [products.all], "one question, with the four identifiers")
        // Starting again asks nothing more.
        jar.start()
        #expect(store.asked.count == 1)
        // A storefront with other prices shows its own, never a fixed one.
        let yen = FakeStore()
        yen.answer = .success(Self.prices([(.lite, "\u{00A5}300"), (.pro, "\u{00A5}800"), (.max, "\u{00A5}3,000"), (.ultra, "\u{00A5}8,000")]))
        let other = model(yen)
        other.start()
        #expect(await eventually { other.phase == .loaded })
        #expect(other.offers.map(\.price) == ["\u{00A5}300", "\u{00A5}800", "\u{00A5}3,000", "\u{00A5}8,000"])
    }

    @Test func aTierTheStoreDidNotReturnIsLeftOutAndTheOthersCanBeBought() async {
        let store = FakeStore()
        store.answer = .success(Self.prices([(.lite, "$1.99"), (.pro, "$4.99"), (.ultra, "$49.99")]))
        let jar = model(store)
        jar.start()
        #expect(await eventually { jar.phase == .loaded })
        #expect(jar.shownTiers == [.lite, .pro, .ultra])
        #expect(jar.canBuy(.pro) && !jar.canBuy(.max))
        jar.purchase(.max)
        #expect(jar.purchasing == nil && jar.outcome == nil, "a tier that is not offered cannot be bought")
        // A product nobody asked for is not a tier.
        store.answer = .success(Self.usPrices + [TipJarProduct(identifier: "com.example.other", displayPrice: "$0.99")])
        let again = model(store)
        again.start()
        #expect(await eventually { again.phase == .loaded })
        #expect(again.offers.count == 4)
    }

    @Test func nothingFromTheStoreIsUnavailableAndTryAgainAsksAgain() async {
        let store = FakeStore()
        store.answer = .success([])
        let jar = model(store)
        jar.start()
        #expect(await eventually { jar.phase == .unavailable })
        #expect(jar.shownTiers.isEmpty && jar.canRetry && !jar.canBuy)
        store.answer = .success(Self.usPrices)
        jar.retry()
        #expect(jar.phase == .loading && jar.shownTiers == TipJarTier.allCases)
        #expect(await eventually { jar.phase == .loaded })
        #expect(store.asked.count == 2)
        // Try again is for an empty answer alone.
        jar.retry()
        #expect(store.asked.count == 2)
    }

    @Test func aStoreThatThrowsIsUnavailableToo() async {
        let store = FakeStore()
        store.answer = .failure(StoreDown())
        let jar = model(store)
        jar.start()
        #expect(await eventually { jar.phase == .unavailable })
        #expect(jar.canRetry)
    }

    @Test func aStoreThatDoesNotAnswerInTimeIsUnavailableAndALateAnswerIsNotTaken() async {
        let store = FakeStore()
        store.answer = .success(Self.usPrices)
        store.delay = .milliseconds(400)
        let jar = model(store, timeout: .milliseconds(60))
        jar.start()
        #expect(await eventually { jar.phase == .unavailable })
        try? await Task.sleep(for: .milliseconds(500))
        #expect(jar.phase == .unavailable && jar.offers.isEmpty, "the late answer was for a question the sheet gave up")
        store.delay = nil
        jar.retry()
        #expect(await eventually { jar.phase == .loaded })
    }

    @Test func purchasesNotAllowedDimTheTiersAndKeepTheirPrices() async {
        let store = FakeStore()
        store.answer = .success(Self.usPrices)
        store.payments = false
        let jar = model(store)
        jar.start()
        #expect(await eventually { jar.phase == .loaded })
        #expect(!jar.canMakePayments && !jar.canBuy)
        #expect(jar.shownTiers == TipJarTier.allCases && jar.offers.count == 4)
        #expect(TipJarTier.allCases.allSatisfy { !jar.canBuy($0) })
        jar.purchase(.pro)
        #expect(jar.purchasing == nil && jar.outcome == nil)
        // And without a price to show, there is nothing to try again for.
        store.answer = .success([])
        let empty = model(store)
        empty.start()
        #expect(await eventually { empty.phase == .unavailable })
        #expect(!empty.canRetry)
    }

    // MARK: Buying

    private func loaded(_ store: FakeStore) async -> TipJarModel {
        store.answer = .success(Self.usPrices)
        let jar = model(store)
        jar.start()
        _ = await eventually { jar.phase == .loaded }
        return jar
    }

    /// A purchase the test finishes when it chooses.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<TipJarPurchase, Never>?
        private var ready: TipJarPurchase?
        func wait() async -> TipJarPurchase {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if let ready { continuation.resume(returning: ready) } else { self.continuation = continuation }
                }
            }
        }
        func release(_ result: TipJarPurchase) {
            lock.withLock {
                if let continuation { continuation.resume(returning: result); self.continuation = nil } else { ready = result }
            }
        }
    }

    @Test func aPurchaseIsUnderWayThenThanksAndTheTransactionIsFinishedOnce() async {
        let store = FakeStore()
        let gate = Gate()
        store.purchase = { identifier in
            #expect(identifier == "com.example.andarium.tip.pro")
            return await gate.wait()
        }
        let jar = await loaded(store)
        jar.purchase(.pro)
        #expect(jar.purchasing == .pro && jar.outcome == nil && !jar.canBuy)
        #expect(jar.offer(for: .pro)?.price == "$4.99", "the chosen tier keeps its price while it is bought")
        jar.purchase(.max)
        #expect(jar.purchasing == .pro, "one purchase at a time")
        gate.release(.purchased(store.transaction("com.example.andarium.tip.pro")))
        #expect(await eventually { jar.outcome == .thanks(.pro) })
        #expect(jar.purchasing == nil && jar.thanked)
        #expect(store.finished == ["com.example.andarium.tip.pro"])
        #expect(jar.shownTiers.isEmpty && !jar.canBuy, "after the thank-you the tiers are not offered again in the visit")
        jar.purchase(.lite)
        #expect(jar.purchasing == nil && store.finished.count == 1)
    }

    @Test func aCancelledPurchaseSaysNothingAndTheTiersStay() async {
        let store = FakeStore()
        store.purchase = { _ in .cancelled }
        let jar = await loaded(store)
        jar.purchase(.lite)
        #expect(await eventually { jar.purchasing == nil })
        #expect(jar.outcome == nil && jar.canBuy && jar.shownTiers == TipJarTier.allCases)
        #expect(store.finished.isEmpty)
    }

    @Test func aPendingPurchaseSaysItWaitsForApprovalAndTheTiersStay() async {
        let store = FakeStore()
        store.purchase = { _ in .pending }
        let jar = await loaded(store)
        jar.purchase(.max)
        #expect(await eventually { jar.outcome == .pending(.max) })
        #expect(jar.purchasing == nil && jar.canBuy && jar.shownTiers == TipJarTier.allCases)
        #expect(store.finished.isEmpty, "nothing to finish until the approval arrives")
    }

    @Test func aFailedPurchaseShowsTheStoresOwnMessageAndCanBeTriedAgain() async {
        let store = FakeStore()
        store.purchase = { _ in .failed("Cannot connect to the App Store.") }
        let jar = await loaded(store)
        jar.purchase(.ultra)
        #expect(await eventually { jar.outcome != nil })
        #expect(jar.outcome == .failed(.ultra, "Cannot connect to the App Store."))
        #expect(jar.canBuy && jar.shownTiers == TipJarTier.allCases)
        // The next purchase clears the message.
        store.purchase = { _ in .cancelled }
        jar.purchase(.lite)
        #expect(jar.outcome == nil)
        #expect(await eventually { jar.purchasing == nil })
    }

    @Test func closingTheSheetUnderAPurchaseFinishesItAndShowsNothingLater() async {
        let store = FakeStore()
        let gate = Gate()
        store.purchase = { _ in await gate.wait() }
        let jar = await loaded(store)
        jar.purchase(.lite)
        jar.close()
        #expect(jar.closed && jar.purchasing == nil && jar.outcome == nil)
        gate.release(.purchased(store.transaction("com.example.andarium.tip.lite")))
        #expect(await eventually { store.finished == ["com.example.andarium.tip.lite"] })
        #expect(jar.outcome == nil && jar.purchasing == nil, "the closed sheet shows no thank-you")
        // Nothing starts on a closed model.
        jar.purchase(.pro)
        jar.retry()
        #expect(jar.purchasing == nil && store.asked.count == 1)
    }

    @Test func closingTheSheetUnderTheStoresQuestionDropsTheAnswer() async {
        let store = FakeStore()
        store.answer = .success(Self.usPrices)
        store.delay = .milliseconds(100)
        let jar = model(store)
        jar.start()
        jar.close()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(jar.phase == .loading && jar.offers.isEmpty)
    }

    @Test func aTipLeavesNothingBehind() async {
        let defaults = UserDefaults.standard.dictionaryRepresentation().filter { !$0.key.hasPrefix("NS") }
        let store = FakeStore()
        store.purchase = { [store] identifier in .purchased(store.transaction(identifier)) }
        let jar = await loaded(store)
        jar.purchase(.pro)
        #expect(await eventually { jar.thanked })
        jar.close()
        #expect(UserDefaults.standard.dictionaryRepresentation().filter { !$0.key.hasPrefix("NS") }.count == defaults.count)
        // The next opening is the first one again, whatever happened in this one.
        let next = await loaded(store)
        #expect(next.outcome == nil && next.purchasing == nil && next.canBuy && next.shownTiers == TipJarTier.allCases)
    }

    // MARK: Transactions that arrive on their own

    @Test func everyTransactionTheStoreDeliversIsFinished() async {
        let store = FakeStore()
        let (stream, continuation) = AsyncStream<TipJarTransaction>.makeStream()
        // An interrupted purchase, an Ask to Buy approval and one from another device.
        for identifier in ["com.example.andarium.tip.max", "com.example.andarium.tip.lite", "com.example.andarium.tip.pro"] {
            continuation.yield(store.transaction(identifier))
        }
        continuation.finish()
        await TipJarUpdates.finishAll(stream)
        #expect(store.finished == ["com.example.andarium.tip.max", "com.example.andarium.tip.lite", "com.example.andarium.tip.pro"])
    }

    @Test func theListenerRunsForTheLifeOfTheProcessAndFinishesWhatComesLater() async {
        let store = FakeStore()
        let (stream, continuation) = AsyncStream<TipJarTransaction>.makeStream()
        let task = TipJarUpdates.listen(store.services(updates: stream))
        continuation.yield(store.transaction("com.example.andarium.tip.ultra"))
        #expect(await eventually { store.finished == ["com.example.andarium.tip.ultra"] })
        #expect(!task.isCancelled)
        // A second one, later in the process's life.
        continuation.yield(store.transaction("com.example.andarium.tip.pro"))
        #expect(await eventually { store.finished.count == 2 })
        continuation.finish()
        await task.value
    }

    // MARK: Words

    @Test func everyWordIsInTheTipJarTable() {
        #expect(TipJarWords.all.allSatisfy { $0.table == "TipJar" })
        #expect(TipJarWords.tableName == "TipJar")
        let keys = TipJarWords.all.map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(keys.contains("Purchases aren\u{2019}t allowed on this\u{00A0}%@"))
        #expect(keys.contains("Buy me tokens"))
    }

    /// The last word of each longer English text is tied to the one before it with a no-break space, so
    /// that "way." or "coffee." never wraps alone, and nothing else in the text is tied.
    @Test func theLastWordsOfTheLongerEnglishTextsAreTied() {
        let tied: [(LocalizedStringResource, String)] = [
            (TipJarWords.coffee, "on\u{00A0}coffee."), (TipJarWords.invitation, "me\u{00A0}some."),
            (TipJarWords.statement, "either\u{00A0}way."), (TipJarWords.restrictedTitle(device: "iPhone"), "this\u{00A0}%@"),
        ]
        for (resource, end) in tied {
            #expect(resource.key.hasSuffix(end), "\(resource.key)")
            #expect(resource.key.filter { $0 == "\u{00A0}" }.count == 1, "\(resource.key)")
        }
    }
}
