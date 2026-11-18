// SPDX-License-Identifier: GPL-2.0-or-later

#if APP_REVIEW

import Foundation

// When the application asks for a rating: the time a virtual machine has run
// in the foreground, and the conditions the moment must meet. Pure logic, with
// the clock passed in. The application compiles these files with the rest of
// the feature, and only where it is compiled in; the AndariumCore package
// compiles the same files for its tests (Andarium/README.md#rating-prompt).

/// The seconds during which a virtual machine ran with the application's scene
/// active in the foreground. The reading comes from a monotonic clock the
/// caller passes in, so a change of the date or time zone moves nothing, and
/// the total never decreases.
nonisolated struct ReviewAskCounter: Equatable, Sendable {
    /// The seconds counted up to the last bank, from a previous run of the
    /// application or from this one.
    private(set) var banked: TimeInterval
    /// The clock's reading when the count that is under way began.
    private var since: TimeInterval?

    /// The most a counter keeps, so that a value damaged in storage cannot be
    /// taken for a very long run.
    static let ceiling: TimeInterval = 100 * 365 * 24 * 3600

    init(banked: TimeInterval = 0) {
        self.banked = banked.isFinite ? min(max(banked, 0), Self.ceiling) : 0
    }

    var isCounting: Bool { since != nil }

    func total(at now: TimeInterval) -> TimeInterval {
        min(banked + (since.map { max(0, now - $0) } ?? 0), Self.ceiling)
    }

    /// Starts or stops counting at `now`. Returns whether that changed anything.
    @discardableResult
    mutating func set(counting: Bool, at now: TimeInterval) -> Bool {
        switch (counting, since) {
        case (true, nil):
            since = now
            return true
        case (false, let began?):
            banked = min(banked + max(0, now - began), Self.ceiling)
            since = nil
            return true
        default:
            return false
        }
    }

    /// Moves the time counted so far into `banked` without stopping the count.
    mutating func bank(at now: TimeInterval) {
        guard let began = since else { return }
        banked = min(banked + max(0, now - began), Self.ceiling)
        since = now
    }
}

/// What decides whether this is the moment to ask.
nonisolated enum ReviewAskRule {
    /// Five hours of a virtual machine running in the foreground.
    static let threshold: TimeInterval = 5 * 3600
    /// How long Home has to have been visible, as it is, before the request
    /// goes, so that it does not collide with a transition.
    static let settle: Duration = .seconds(1)
    /// How often the counter is written while it runs; a crash loses at most this.
    static let checkpoint: Duration = .seconds(60)

    /// Everything the decision reads, gathered by the caller.
    struct Situation: Equatable, Sendable {
        var activeSeconds: TimeInterval = 0
        /// The prompt was already requested, or the person has gone to write a
        /// review (`ReviewAskHistory.asked`).
        var asked = false
        /// Home is the screen, and no virtual machine runs or starts.
        var onHome = false
        /// A virtual machine is set up: without one Home shows its welcome.
        var hasGuest = true
        /// The most recent run ended normally (`ReviewAskTracker.lastRunEndedNormally`).
        var lastRunEndedNormally = true
        /// Home shows a notice about the previous run.
        var noticeShown = false
        /// A sheet, an alert, a dialog or the release notes are up or pending.
        var somethingPresented = false
        var sceneActive = true
        /// Home has been visible, as it is, for `settle`.
        var settled = true
    }

    enum Blocker: Equatable, Sendable, CaseIterable {
        case belowThreshold, asked, notOnHome, noGuest, lastRunNotNormal
        case noticeShown, somethingPresented, sceneInactive, notSettled
    }

    static func blockers(_ situation: Situation) -> [Blocker] {
        var found: [Blocker] = []
        if situation.activeSeconds < threshold { found.append(.belowThreshold) }
        if situation.asked { found.append(.asked) }
        if !situation.onHome { found.append(.notOnHome) }
        if !situation.hasGuest { found.append(.noGuest) }
        if !situation.lastRunEndedNormally { found.append(.lastRunNotNormal) }
        if situation.noticeShown { found.append(.noticeShown) }
        if situation.somethingPresented { found.append(.somethingPresented) }
        if !situation.sceneActive { found.append(.sceneInactive) }
        if !situation.settled { found.append(.notSettled) }
        return found
    }

    static func isEligible(_ situation: Situation) -> Bool { blockers(situation).isEmpty }

    /// Whether everything but the waiting holds: the moment to start waiting.
    static func isEligibleOnceSettled(_ situation: Situation) -> Bool {
        blockers(situation).allSatisfy { $0 == .notSettled }
    }
}

#endif
