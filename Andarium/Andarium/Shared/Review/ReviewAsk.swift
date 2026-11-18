// SPDX-License-Identifier: GPL-2.0-or-later

#if APP_REVIEW

import AndariumCore
import Foundation
import Observation
import UIKit

/// Asks for a rating with the system's own prompt: once the virtual machine has
/// run five hours in the foreground, at a settled Home, after a run that ended
/// normally, and only once per device. The rule, the counter and the record of
/// asking are `ReviewAskRule` and `ReviewAskTracker`; this class feeds them the
/// model's state, waits for Home to settle, records the request and makes it.
/// It has no screen of its own, shows nothing before or after the prompt, does
/// not look at what the system did, and is never tied to the tip sheet.
///
/// It is driven by the model's own changes (Observation) and by the scene's
/// edges, never by a timer except one write a minute while the counter runs.
/// It exists only where Review on the App Store is compiled in, and only in the
/// application's own launch (`AppEntry.makeModel`): the Simulator preview never asks.
@MainActor
final class ReviewAsk {
    private weak var model: AppModel?
    private(set) var tracker: ReviewAskTracker
    private let services: ReviewAskServices
    /// The scene is active in the foreground, kept from its own notifications.
    private var sceneActive: Bool
    private var settleTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    init(model: AppModel, services: ReviewAskServices) {
        self.model = model
        self.services = services
        tracker = ReviewAskTracker(persistence: services.persistence, uptime: services.uptime)
        sceneActive = services.sceneActive()
    }

    /// Begins to watch the model and the scene.
    func start() {
        guard !started else { return }
        started = true
        let edges: [(Notification.Name, Bool?)] = [
            (UIApplication.willResignActiveNotification, false),
            (UIApplication.didBecomeActiveNotification, true),
            (UIApplication.didEnterBackgroundNotification, nil),
            (UIApplication.willTerminateNotification, nil),
        ]
        observers = edges.map { name, active in
            services.center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let active { self.sceneActive = active }
                    self.evaluate()
                }
            }
        }
        observe()
        evaluate()
    }

    func stop() {
        started = false
        observers.forEach { services.center.removeObserver($0) }
        observers = []
        settleTask?.cancel()
        settleTask = nil
        checkpointTask?.cancel()
        checkpointTask = nil
    }

    // MARK: What the model tells it

    /// A virtual machine starts: until it ends normally the most recent run has not.
    func runBegan() {
        tracker.runBegan()
        evaluate()
    }

    /// A run ended: normally when Android powered off or was stopped.
    func runEnded(normally: Bool) {
        tracker.runEnded(normally: normally)
        evaluate()
    }

    /// At launch: how the previous process's session record says its run
    /// ended. The record knows a stop that completed while the application was
    /// in the background, or that it ended in the middle of a run.
    func previousRunEnded(normally: Bool) {
        tracker.runEnded(normally: normally)
    }

    /// The person opened Review on the App Store from the menu: the question is answered.
    func openedReview() {
        tracker.markAsked()
        evaluate()
    }

    #if !APP_STORE
    /// A Debug build's own check: sets the counter and clears the record of
    /// asking (`ANDARIUM_REVIEW_ASK_SECONDS`, `ANDARIUM_REVIEW_ASK_RESET`).
    func applyDebugLaunch(environment: [String: String]) {
        let seconds = environment["ANDARIUM_REVIEW_ASK_SECONDS"].flatMap { TimeInterval($0) }
        let reset = environment["ANDARIUM_REVIEW_ASK_RESET"] == "1"
        guard seconds != nil || reset else { return }
        tracker.debugSet(activeSeconds: seconds, clearHistory: reset)
        print("Andarium: rating prompt counter set for this launch")
    }
    #endif

    // MARK: Watching

    /// Reads what the decision reads under Observation, so a change in any of
    /// it brings the decision again; one hop to the main actor lets the change
    /// land first.
    private func observe() {
        guard started else { return }
        withObservationTracking {
            _ = readSituation(settled: true, uikitPresenting: false)
            _ = countingNow
        } onChange: {
            // One change per registration, so the closure holds the object only until it fires.
            Task { @MainActor in
                guard self.started else { return }
                self.observe()
                self.evaluate()
            }
        }
    }

    /// A virtual machine runs, past boot, in the foreground scene, and is not
    /// paused for want of space.
    private var countingNow: Bool {
        guard let model, case .running(_) = model.phase else { return false }
        return sceneActive && model.spacePause == nil
    }

    private func readSituation(settled: Bool, uikitPresenting: Bool) -> ReviewAskRule.Situation {
        guard let model else { return ReviewAskRule.Situation(onHome: false) }
        var presented = model.sheet != nil || model.alert != nil || model.confirmingErase || model.startBlocked
            || model.permissionPrompt != nil || model.spacePause != nil || model.whatsNew.showsRibbon
            || model.busy != nil
        #if FEEDBACK_MAIL
        presented = presented || model.feedbackSheetOpen
        #endif
        #if TIP_JAR
        presented = presented || model.tipJarSheetOpen
        #endif
        return ReviewAskRule.Situation(
            activeSeconds: tracker.activeSeconds, asked: tracker.history.asked,
            onHome: model.phase == .home, hasGuest: model.guest != nil,
            lastRunEndedNormally: tracker.lastRunEndedNormally, noticeShown: model.notice != nil,
            somethingPresented: presented || uikitPresenting, sceneActive: sceneActive, settled: settled)
    }

    /// The decision, again: counts, writes at the edges, and starts or cancels
    /// the wait for Home to settle.
    private func evaluate() {
        guard started, model != nil else { return }
        tracker.count(countingNow)
        updateCheckpoint()
        if ReviewAskRule.isEligibleOnceSettled(readSituation(settled: false, uikitPresenting: false)) {
            if settleTask == nil { startSettling() }
        } else {
            settleTask?.cancel()
            settleTask = nil
        }
    }

    private func updateCheckpoint() {
        if countingNow {
            guard checkpointTask == nil else { return }
            checkpointTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let interval = self?.services.checkpoint else { return }
                    try? await Task.sleep(for: interval, tolerance: interval / 6)
                    guard !Task.isCancelled, let self else { return }
                    tracker.checkpoint()
                }
            }
        } else {
            checkpointTask?.cancel()
            checkpointTask = nil
        }
    }

    private func startSettling() {
        settleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: services.settle)
            guard !Task.isCancelled else { return }
            settleTask = nil
            let situation = readSituation(settled: true, uikitPresenting: services.presenting())
            guard ReviewAskRule.isEligible(situation) else {
                #if !APP_STORE
                print("Andarium: rating prompt not asked now: \(ReviewAskRule.blockers(situation))")
                #endif
                return
            }
            ask()
        }
    }

    /// Records the request first, so that nothing the request or the end of
    /// the application does can lose it, then asks. The system decides whether
    /// anything shows; the application does not look, and does not ask again.
    private func ask() {
        tracker.markAsked()
        services.request()
        evaluate()
    }
}

#endif
