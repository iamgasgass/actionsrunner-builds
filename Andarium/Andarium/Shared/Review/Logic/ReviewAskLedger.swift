// SPDX-License-Identifier: GPL-2.0-or-later

#if APP_REVIEW

import Foundation

// What the application keeps about asking for a rating. Pure logic: the
// clocks come in as parameters and the storage behind a protocol. Everything
// here stays on the device; nothing leaves it or enters a bug report.

/// Whether the rating prompt was asked for: once per device. iOS gives no
/// result for a review request (`AppStore.requestReview(in:)` may or may not
/// show anything) and the application does not try to find out, so it asks
/// once, records that before it asks, and never again. The record is kept on
/// the device in two places (`ReviewAskPersistence`) and read back as the
/// furthest of the two.
nonisolated struct ReviewAskHistory: Equatable, Sendable, Codable {
    /// The prompt was requested, or the person opened Review on the App Store.
    var asked = false

    /// The furthest of two readings of the same record: asked if either says so.
    func merged(with other: ReviewAskHistory) -> ReviewAskHistory {
        ReviewAskHistory(asked: asked || other.asked)
    }
}

/// What a launch of the application reads back about the counter and the
/// previous run.
nonisolated struct ReviewAskSnapshot: Equatable, Sendable {
    var activeSeconds: TimeInterval = 0
    /// The most recent run ended normally. A run that has begun has not (yet):
    /// an application that ends in the middle of one leaves it so.
    var lastRunEndedNormally = true
}

/// Where the counter and the history are kept.
nonisolated protocol ReviewAskPersistence {
    func loadSnapshot() -> ReviewAskSnapshot
    func save(_ snapshot: ReviewAskSnapshot)
    /// nil when the history cannot be read; the tracker then asks nothing.
    func loadHistory() -> ReviewAskHistory?
    func save(_ history: ReviewAskHistory)
}

/// The counter, the run's end and the record of asking, with their writes: one at each
/// state change and one for each checkpoint while the counter runs, never more.
nonisolated struct ReviewAskTracker {
    private let persistence: any ReviewAskPersistence
    /// A monotonic clock, in seconds.
    private let uptime: () -> TimeInterval
    private(set) var counter: ReviewAskCounter
    private(set) var history: ReviewAskHistory
    private(set) var lastRunEndedNormally: Bool

    init(persistence: any ReviewAskPersistence, uptime: @escaping () -> TimeInterval) {
        self.persistence = persistence
        self.uptime = uptime
        let snapshot = persistence.loadSnapshot()
        counter = ReviewAskCounter(banked: snapshot.activeSeconds)
        lastRunEndedNormally = snapshot.lastRunEndedNormally
        // A record that cannot be read is not guessed at: nothing is asked.
        history = persistence.loadHistory() ?? ReviewAskHistory(asked: true)
    }

    var activeSeconds: TimeInterval { counter.total(at: uptime()) }

    private func saveSnapshot() {
        persistence.save(ReviewAskSnapshot(activeSeconds: activeSeconds, lastRunEndedNormally: lastRunEndedNormally))
    }

    private func saveHistory() { persistence.save(history) }

    /// A virtual machine is running in the foreground, or it is not.
    mutating func count(_ counting: Bool) {
        if counter.set(counting: counting, at: uptime()) { saveSnapshot() }
    }

    /// The periodic write while the counter runs.
    mutating func checkpoint() {
        guard counter.isCounting else { return }
        counter.bank(at: uptime())
        saveSnapshot()
    }

    /// A run begins: until it ends normally the most recent run has not.
    mutating func runBegan() { setRun(normal: false) }

    /// A run ended, or the previous process's record says how its run ended.
    mutating func runEnded(normally: Bool) { setRun(normal: normally) }

    private mutating func setRun(normal: Bool) {
        guard lastRunEndedNormally != normal else { return }
        lastRunEndedNormally = normal
        saveSnapshot()
    }

    /// The prompt is about to be requested, or Review on the App Store was
    /// opened from the menu. Written before the request goes, so that nothing
    /// the request or the end of the application does can lose it.
    mutating func markAsked() {
        guard !history.asked else { return }
        history.asked = true
        saveHistory()
    }

    #if !APP_STORE
    /// For a Debug build's own check: the counter at `seconds`, and the
    /// record cleared. An App Store product holds neither.
    mutating func debugSet(activeSeconds seconds: TimeInterval?, clearHistory: Bool) {
        if let seconds {
            counter = ReviewAskCounter(banked: seconds)
            saveSnapshot()
        }
        if clearHistory {
            history = ReviewAskHistory()
            saveHistory()
        }
    }
    #endif
}

#endif
