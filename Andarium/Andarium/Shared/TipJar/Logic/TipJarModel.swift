// SPDX-License-Identifier: GPL-2.0-or-later

#if TIP_JAR

import Foundation
import Observation

/// What the Buy me tokens sheet shows of the store and of the purchase in
/// progress. One lives for one opening of the sheet and is dropped with it:
/// nothing about a tip is kept, so the sheet opens the same for a person who
/// tipped and one who did not.
@MainActor
@Observable
final class TipJarModel {
    enum Phase: Equatable {
        /// Waiting for the store's answer.
        case loading
        /// The store answered with at least one of the tiers.
        case loaded
        /// The store gave nothing, or did not answer in time.
        case unavailable
    }

    enum Outcome: Equatable {
        case thanks(TipJarTier)
        /// Waiting for someone else to approve it.
        case pending(TipJarTier)
        /// The store's own message.
        case failed(TipJarTier, String)

        var tier: TipJarTier {
            switch self {
            case .thanks(let tier), .pending(let tier), .failed(let tier, _): tier
            }
        }
    }

    private(set) var phase = Phase.loading
    /// The tiers the store answered for, in tier order.
    private(set) var offers: [TipJarOffer] = []
    /// `AppStore.canMakePayments`, read when the store is asked.
    private(set) var canMakePayments: Bool
    /// The tier whose purchase is under way.
    private(set) var purchasing: TipJarTier?
    private(set) var outcome: Outcome?
    private(set) var closed = false

    @ObservationIgnored private let products: TipJarProducts
    @ObservationIgnored private let store: TipJarStoreServices
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private var started = false
    /// Counts the asks of the store, so that an answer to an earlier one is not taken.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    /// `timeout` is how long the store may take to answer before the sheet says
    /// it did not.
    init(products: TipJarProducts, store: TipJarStoreServices, timeout: Duration = .seconds(20)) {
        self.products = products
        self.store = store
        self.timeout = timeout
        canMakePayments = store.canMakePayments()
    }

    // MARK: What the sheet shows

    func offer(for tier: TipJarTier) -> TipJarOffer? { offers.first { $0.tier == tier } }

    /// A purchase can start now.
    var canBuy: Bool { !closed && phase == .loaded && canMakePayments && purchasing == nil && !thanked }

    /// The tiers are offered: not once the thank-you has been said (the sheet
    /// then offers Done alone), not when the store gave nothing.
    var shownTiers: [TipJarTier] {
        guard !thanked else { return [] }
        switch phase {
        case .loading: return TipJarTier.allCases
        case .loaded: return offers.map(\.tier)
        case .unavailable: return []
        }
    }

    func canBuy(_ tier: TipJarTier) -> Bool { canBuy && offer(for: tier) != nil }

    /// The thank-you is on screen.
    var thanked: Bool {
        if case .thanks? = outcome { return true }
        return false
    }

    /// Try again is offered: the store gave nothing, and purchases are not
    /// restricted (which the sheet says instead).
    var canRetry: Bool { phase == .unavailable && canMakePayments }

    // MARK: Asking the store

    /// Asks the store for the prices. Once per model; Try again asks again.
    func start() {
        guard !started, !closed else { return }
        started = true
        fetch()
    }

    func retry() {
        guard canRetry, !closed else { return }
        fetch()
    }

    private func fetch() {
        generation += 1
        let generation = generation
        phase = .loading
        offers = []
        canMakePayments = store.canMakePayments()
        let identifiers = products.all
        let store = store
        let timeout = timeout
        tasks.append(Task { [weak self] in
            let answer = try? await store.products(identifiers)
            guard !Task.isCancelled else { return }
            self?.apply(answer, generation: generation)
        })
        tasks.append(Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.apply(nil, generation: generation)
        })
    }

    /// The store's answer, or nil when it threw or did not answer in time.
    private func apply(_ answer: [TipJarProduct]?, generation: Int) {
        guard !closed, generation == self.generation, phase == .loading else { return }
        let found = TipJarTier.allCases.compactMap { tier -> TipJarOffer? in
            guard let product = answer?.first(where: { $0.identifier == products.identifier(for: tier) })
            else { return nil }
            return TipJarOffer(tier: tier, price: product.displayPrice)
        }
        offers = found
        phase = found.isEmpty ? .unavailable : .loaded
        for task in tasks { task.cancel() }
        tasks.removeAll()
    }

    // MARK: Buying

    func purchase(_ tier: TipJarTier) {
        guard canBuy(tier) else { return }
        outcome = nil
        purchasing = tier
        let identifier = products.identifier(for: tier)
        let store = store
        // Not the model's task: the store's answer finishes the transaction
        // even when the sheet has been closed meanwhile.
        Task { [weak self] in
            let result = await store.purchase(identifier)
            if case .purchased(let transaction) = result { await transaction.finish() }
            self?.apply(result, tier: tier)
        }
    }

    private func apply(_ result: TipJarPurchase, tier: TipJarTier) {
        guard !closed else { return }
        purchasing = nil
        switch result {
        case .purchased: outcome = .thanks(tier)
        case .cancelled: outcome = nil
        case .pending: outcome = .pending(tier)
        case .failed(let message): outcome = .failed(tier, message)
        }
    }

    /// The sheet is closed: nothing is kept, and a late answer is not shown.
    func close() {
        closed = true
        for task in tasks { task.cancel() }
        tasks.removeAll()
        purchasing = nil
        outcome = nil
    }
}

#endif
