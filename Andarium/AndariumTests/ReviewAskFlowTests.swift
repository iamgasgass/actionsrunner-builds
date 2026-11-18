// SPDX-License-Identifier: GPL-2.0-or-later

#if APP_REVIEW

import AndariumCore
import AndariumCoreTestSupport
import Foundation
import Security
import Testing
import UIKit
@testable import Andarium

/// The rating prompt in the application: the model's states, the scene's edges and the clocks are
/// driven by the test, the request is a double. The rule and the record of asking are the
/// package's tests (`ReviewAskTests`); this is the coordinator that feeds them.
private final class MemoryReviewStore: ReviewAskPersistence, @unchecked Sendable {
    var snapshot = ReviewAskSnapshot()
    var history: ReviewAskHistory? = ReviewAskHistory()
    func loadSnapshot() -> ReviewAskSnapshot { snapshot }
    func save(_ snapshot: ReviewAskSnapshot) { self.snapshot = snapshot }
    func loadHistory() -> ReviewAskHistory? { history }
    func save(_ history: ReviewAskHistory) { self.history = history }
}

@MainActor
private final class Harness {
    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 86400

    let model: AppModel
    let store: MemoryReviewStore
    let center = NotificationCenter()
    var uptime: TimeInterval = 100
    var requests: [Date] = []
    /// Runs inside the request, as the system's own side of it would.
    var atRequest: (@MainActor () -> Void)?
    var sceneActive = true
    var presenting = false
    private(set) var ask: ReviewAsk!

    init(
        store: MemoryReviewStore = MemoryReviewStore(), seconds: TimeInterval? = nil, lastRunNormal: Bool? = nil,
        guest: Bool = true, start: Bool = true
    ) {
        let host = HostDevice(
            name: "iPhone", processorCount: 6, memory: MemoryPolicy(maximumsMiB: [4096]), freeStorageBytes: 40_000_000_000)
        model = AppModel(
            guest: guest ? Guest.fresh(on: host) : nil, host: host,
            system: SystemInfo(version: "17", release: "r2", kernel: "Linux 6.18", architecture: "arm64, 4 KiB pages", appVersion: "1"),
            capabilities: .device, createRequirementBytes: 1)
        model.launchApplied = true
        model.phase = .home
        self.store = store
        if let seconds { store.snapshot.activeSeconds = seconds }
        if let lastRunNormal { store.snapshot.lastRunEndedNormally = lastRunNormal }
        var services = ReviewAskServices()
        services.persistence = store
        services.center = center
        services.settle = .milliseconds(30)
        services.checkpoint = .milliseconds(20)
        services.sceneActive = { true }
        services.uptime = { [unowned self] in uptime }
        services.request = { [unowned self] in
            atRequest?()
            requests.append(Date())
        }
        services.presenting = { [unowned self] in presenting }
        ask = ReviewAsk(model: model, services: services)
        model.reviewAsk = ask
        if start { ask.start() }
    }

    deinit {
        MainActor.assumeIsolated { ask.stop() }
    }

    /// Waits for the condition, up to a bound.
    func wait(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// Long enough for a request that is going to be made to have been made (many settles).
    func rest(_ duration: Duration = .milliseconds(300)) async {
        try? await Task.sleep(for: duration)
    }

    var history: ReviewAskHistory { ask.tracker.history }

    func post(_ name: Notification.Name) async {
        center.post(name: name, object: nil)
        await rest(.milliseconds(30))
    }

    func resign() async { await post(UIApplication.willResignActiveNotification) }
    func becomeActive() async { await post(UIApplication.didBecomeActiveNotification) }

    /// A start, the boot reaching the guest, and the run ending as Android's own power-off does.
    func startAndBoot() {
        model.start(.normal)
        model.finishBoot(.normal)
    }
}

@MainActor
@Suite(.serialized)
struct ReviewAskFlowTests {
    private let hour = Harness.hour
    private let day = Harness.day

    // MARK: When it asks

    @Test func fiveHoursAtASettledHomeAsksOnce() async {
        let h = Harness(seconds: 5 * hour)
        #expect(await h.wait { h.requests.count == 1 })
        await h.rest()
        #expect(h.requests.count == 1, "one request, however long Home stays")
        #expect(h.history.asked)
    }

    @Test func belowTheThresholdItNeverAsks() async {
        let h = Harness(seconds: 5 * hour - 1)
        await h.rest()
        #expect(h.requests.isEmpty)
    }

    @Test func itWaitsForHomeToSettleAndAnyChangeStartsTheWaitOver() async {
        let h = Harness(seconds: 5 * hour)
        #expect(h.requests.isEmpty, "not before the wait has run")
        // A sheet opens and closes within the wait.
        await h.rest(.milliseconds(10))
        h.model.sheet = .info
        await h.rest(.milliseconds(10))
        let closed = ContinuousClock.now
        h.model.sheet = nil
        #expect(await h.wait { h.requests.count == 1 })
        let waited = ContinuousClock.now - closed
        #expect(waited >= .milliseconds(25), "a whole wait after the sheet closed, not what was left of the first")
    }

    @Test func aRunningSessionCountsOnlyWhileTheSceneIsActive() async {
        let h = Harness()
        h.startAndBoot()
        // The boot is over at once here; time before it counted for nothing: the clock moved first.
        await h.rest(.milliseconds(40))
        h.uptime += 4 * hour
        await h.resign()
        h.uptime += 10 * hour
        await h.becomeActive()
        h.uptime += hour
        // Still running: the counter is five hours, and it is not Home.
        #expect(h.ask.tracker.activeSeconds == 5 * hour)
        await h.rest()
        #expect(h.requests.isEmpty, "a running machine is not Home")
        h.model.powerOff()
        #expect(await h.wait { h.requests.count == 1 })
        #expect(h.ask.tracker.activeSeconds == 5 * hour, "Home added nothing")
    }

    @Test func timeOnHomeAndDuringABootDoesNotCount() async {
        let h = Harness()
        h.uptime += 9 * hour
        await h.rest(.milliseconds(40))
        h.model.start(.normal)
        h.uptime += 9 * hour
        await h.rest(.milliseconds(40))
        #expect(h.ask.tracker.activeSeconds == 0)
        h.model.finishBoot(.normal)
        await h.rest(.milliseconds(40))
        h.uptime += 60
        await h.rest(.milliseconds(40))
        #expect(h.ask.tracker.activeSeconds == 60)
    }

    @Test func aGuestPausedForSpaceDoesNotCount() async {
        let h = Harness()
        h.startAndBoot()
        await h.rest(.milliseconds(40))
        h.uptime += 100
        h.model.spacePause = SpacePause(freeBytes: 1)
        await h.rest(.milliseconds(40))
        h.uptime += 3 * hour
        h.model.spacePause = nil
        await h.rest(.milliseconds(40))
        #expect(h.ask.tracker.activeSeconds == 100)
    }

    @Test func theCounterIsWrittenWhileItRunsAndSurvivesTheApplicationEnding() async {
        let h = Harness()
        h.startAndBoot()
        await h.rest(.milliseconds(40))
        h.uptime += 2 * hour
        await h.rest(.milliseconds(60))
        // The application ends here, without a word: a new one reads the store.
        let relaunched = ReviewAskTracker(persistence: h.store, uptime: { 0 })
        #expect(relaunched.activeSeconds == 2 * hour)
        #expect(!relaunched.lastRunEndedNormally, "ended in the middle of a run")
    }

    // MARK: How the previous run ended

    @Test func aNormalStopWhileTheApplicationIsInTheBackgroundAsksOnReturn() async {
        let h = Harness(seconds: 5 * hour - 10)
        h.startAndBoot()
        await h.rest(.milliseconds(40))
        h.uptime += 20
        await h.resign()
        // The guest powers off while the application is away.
        h.model.powerOff()
        await h.rest()
        #expect(h.requests.isEmpty, "the scene is not active")
        #expect(h.ask.tracker.lastRunEndedNormally)
        await h.becomeActive()
        #expect(await h.wait { h.requests.count == 1 })
    }

    @Test func aRunThatEndedWithAnErrorNeverAsksUntilANormalOneEnds() async {
        let store = MemoryReviewStore()
        let h = Harness(store: store, seconds: 6 * hour)
        h.model.start(.normal)
        h.model.runEnded(RunEnd(result: -11), uptimeSeconds: 12)
        #expect(!h.ask.tracker.lastRunEndedNormally)
        await h.rest()
        #expect(h.requests.isEmpty, "a failed run is not Home")
        // The next process starts at Home with a notice about it.
        let next = Harness(store: store)
        next.model.notice = .sessionEnded(SessionEndNotice(title: "x", text: "y"))
        await next.rest()
        #expect(next.requests.isEmpty)
        next.model.notice = nil
        await next.rest()
        #expect(next.requests.isEmpty, "the notice going away does not make the run normal")
        next.startAndBoot()
        next.model.powerOff()
        #expect(await next.wait { next.requests.count == 1 })
    }

    @Test func aNoticeAboutThePreviousRunHoldsItBackWhileItShows() async {
        let h = Harness(seconds: 6 * hour)
        h.model.notice = .closedInBackground
        await h.rest()
        #expect(h.requests.isEmpty)
        h.model.notice = nil
        #expect(await h.wait { h.requests.count == 1 })
    }

    @Test func iOSEndingTheApplicationInTheMiddleOfARunIsNotNormal() async {
        let store = MemoryReviewStore()
        let first = Harness(store: store, seconds: 6 * hour - 1)
        first.startAndBoot()
        await first.rest(.milliseconds(40))
        // The next launch: nothing ended the run, the process was gone.
        let next = Harness(store: store, start: false)
        #expect(!next.ask.tracker.lastRunEndedNormally)
        next.ask.start()
        await next.rest()
        #expect(next.requests.isEmpty)
    }

    @Test func theSessionRecordOfTheLastLaunchDecides() async {
        let h = Harness(seconds: 6 * hour, lastRunNormal: false, start: false)
        // The record says the run powered off, though the application never saw it end.
        h.ask.previousRunEnded(normally: true)
        h.ask.start()
        #expect(await h.wait { h.requests.count == 1 })
        let other = Harness(seconds: 6 * hour, start: false)
        other.ask.previousRunEnded(normally: false)
        other.ask.start()
        await other.rest()
        #expect(other.requests.isEmpty)
    }

    // MARK: A settled screen

    @Test func nothingPresentedOrPendingHoldsItBack() async {
        let h = Harness(seconds: 6 * hour)
        h.model.alert = AppAlert(title: "t", message: "m")
        await h.rest()
        #expect(h.requests.isEmpty, "an alert")
        h.model.alert = nil
        h.model.sheet = .snapshots
        await h.rest()
        #expect(h.requests.isEmpty, "a sheet")
        h.model.sheet = nil
        h.model.confirmingErase = true
        await h.rest()
        #expect(h.requests.isEmpty, "the erase question")
        h.model.confirmingErase = false
        h.model.permissionPrompt = .microphone
        await h.rest()
        #expect(h.requests.isEmpty, "the microphone alert")
        h.model.permissionPrompt = nil
        #expect(await h.wait { h.requests.count == 1 })
    }

    @Test func somethingUIKitPresentsAtTheEndOfTheWaitHoldsItBack() async {
        let h = Harness(seconds: 6 * hour, start: false)
        h.presenting = true
        h.ask.start()
        await h.rest()
        #expect(h.requests.isEmpty)
        h.presenting = false
        // The next arrival tries again: here, anything that changes the screen.
        h.model.sheet = .info
        h.model.sheet = nil
        #expect(await h.wait { h.requests.count == 1 })
    }

    @Test func theReleaseNotesRibbonCountsAsPending() async {
        let h = Harness(seconds: 6 * hour, start: false)
        let entry = WhatsNewEntry(id: "x", title: "t", text: "t", symbol: "star")
        h.model.whatsNew.launch(
            releases: [WhatsNewRelease(build: 5, version: "1.0", entries: [entry])], record: WhatsNewRecord(seenBuild: 4),
            currentBuild: 5, hasGuest: true, offers: { _ in true })
        guard h.model.whatsNew.showsRibbon else {
            Issue.record("the ribbon was not offered")
            return
        }
        h.ask.start()
        await h.rest()
        #expect(h.requests.isEmpty)
        h.model.whatsNew.putAway()
        #expect(await h.wait { h.requests.count == 1 })
    }

    @Test func aSceneThatIsNotActiveHoldsItBackAndReturningAsks() async {
        let h = Harness(seconds: 6 * hour, start: false)
        h.ask.start()
        await h.resign()
        await h.rest()
        #expect(h.requests.isEmpty)
        await h.becomeActive()
        #expect(await h.wait { h.requests.count == 1 })
    }

    @Test func withoutAVirtualMachineHomeIsTheWelcomeAndItDoesNotAsk() async {
        let h = Harness(seconds: 6 * hour, guest: false)
        await h.rest()
        #expect(h.requests.isEmpty)
    }

    // MARK: Once

    @Test func onceAskedItNeverAsksAgain() async {
        let store = MemoryReviewStore()
        let h = Harness(store: store, seconds: 6 * hour)
        #expect(await h.wait { h.requests.count == 1 })
        await h.rest(.milliseconds(100))
        #expect(h.history.asked && store.history?.asked == true)
        // Whatever Home does afterwards, and however long it waits, nothing asks again.
        for _ in 0..<3 {
            h.model.sheet = .info
            h.model.sheet = nil
            await h.rest(.milliseconds(80))
        }
        #expect(h.requests.count == 1)
        // A launch after that reads the record: the next process does not ask either.
        let next = Harness(store: store, seconds: 6 * hour)
        await next.rest()
        #expect(next.requests.isEmpty)
    }

    @Test func theRequestIsRecordedBeforeItIsMade() async {
        let h = Harness(seconds: 6 * hour, start: false)
        var recordedAtRequest: Bool?
        let store = h.store
        h.atRequest = { recordedAtRequest = store.history?.asked }
        h.ask.start()
        #expect(await h.wait { h.requests.count == 1 })
        #expect(recordedAtRequest == true, "the record is written before anything can be shown")
    }

    @Test func aRecordThatCannotBeReadAsksNothing() async {
        let store = MemoryReviewStore()
        store.history = nil
        let h = Harness(store: store, seconds: 6 * hour)
        await h.rest()
        #expect(h.requests.isEmpty)
    }

    @Test func openingReviewOnTheAppStoreEndsItForGood() async {
        let h = Harness(seconds: 6 * hour, start: false)
        var opened: [URL] = []
        h.model.reviewServices.open = { opened.append($0) }
        h.ask.start()
        // Before the wait is over, the person goes to the menu.
        h.model.choose(.reviewOnAppStore)
        #expect(opened.count == 1)
        #expect(h.history.asked)
        await h.rest()
        #expect(h.requests.isEmpty, "someone who went to write a review is not asked")
        #expect(h.store.history?.asked == true)
    }

    @Test func openingReviewBeforeTheThresholdAlsoEndsIt() async {
        let h = Harness(seconds: 60)
        h.model.reviewServices.open = { _ in }
        h.model.choose(.reviewOnAppStore)
        h.store.snapshot.activeSeconds = 6 * hour
        let later = Harness(store: h.store)
        await later.rest()
        #expect(later.requests.isEmpty)
    }

    @Test func theTipSheetNeverTriggersIt() async {
        #if TIP_JAR
        let h = Harness(seconds: 60)
        h.model.tipJarSheetOpen = true
        h.model.tipJarSheetOpen = false
        await h.rest()
        #expect(h.requests.isEmpty && !h.history.asked)
        #endif
        // And a tip sheet that is open holds a due request back, as any sheet does.
        #if TIP_JAR
        let due = Harness(seconds: 6 * hour)
        due.model.tipJarSheetOpen = true
        await due.rest()
        #expect(due.requests.isEmpty)
        due.model.tipJarSheetOpen = false
        #expect(await due.wait { due.requests.count == 1 })
        #endif
    }

    // MARK: The build

    @Test func theDebugKnobSetsTheCounterAndClearsTheRecord() async {
        #if !APP_STORE
        let store = MemoryReviewStore()
        store.history = ReviewAskHistory(asked: true)
        let h = Harness(store: store, start: false)
        #expect(h.history.asked)
        h.ask.applyDebugLaunch(environment: ["ANDARIUM_REVIEW_ASK_SECONDS": "18000", "ANDARIUM_REVIEW_ASK_RESET": "1"])
        #expect(h.ask.tracker.activeSeconds == 18000 && !h.history.asked)
        h.ask.start()
        #expect(await h.wait { h.requests.count == 1 })
        // A launch that states neither changes nothing.
        let quiet = Harness(store: store, start: false)
        let before = quiet.ask.tracker.activeSeconds
        quiet.ask.applyDebugLaunch(environment: [:])
        #expect(quiet.ask.tracker.activeSeconds == before)
        #endif
    }

    @Test func theModelsOwnLaunchIsTheOnlyOneThatAsks() {
        let host = HostDevice(
            name: "iPhone", processorCount: 6, memory: MemoryPolicy(maximumsMiB: [4096]), freeStorageBytes: 40_000_000_000)
        let model = AppModel(
            guest: Guest.fresh(on: host), host: host,
            system: SystemInfo(version: "17", release: "r2", kernel: "Linux 6.18", architecture: "arm64, 4 KiB pages", appVersion: "1"),
            capabilities: .device, createRequirementBytes: 1)
        #expect(model.reviewAsk == nil, "a model built by a test or the preview has none")
        // Its runs and Review item work without one.
        model.start(.normal)
        model.finishBoot(.normal)
        model.powerOff()
        model.reviewServices.open = { _ in }
        model.openReview()
    }
}

// MARK: The stores

private extension ReviewAskKeychain {
    /// The test's own item, removed at the end of the test.
    func remove() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: ReviewAskKeychain.account, kSecUseDataProtectionKeychain as String: true,
        ] as CFDictionary)
    }
}

@Suite(.serialized)
struct ReviewAskStoreTests {
    private func store() -> (ReviewAskStore, UserDefaults, ReviewAskKeychain, String) {
        let name = "ReviewAskStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let keychain = ReviewAskKeychain(service: name)
        return (ReviewAskStore(defaults: defaults, keychain: keychain), defaults, keychain, name)
    }

    @Test func theCounterAndTheRunsEndRoundTrip() {
        let (store, defaults, keychain, name) = store()
        defer { defaults.removePersistentDomain(forName: name); keychain.remove() }
        #expect(store.loadSnapshot() == ReviewAskSnapshot())
        store.save(ReviewAskSnapshot(activeSeconds: 1234.5, lastRunEndedNormally: false))
        #expect(store.loadSnapshot() == ReviewAskSnapshot(activeSeconds: 1234.5, lastRunEndedNormally: false))
    }

    @Test func theHistoryIsKeptInTheDefaultsAndTheKeychain() {
        let (store, defaults, keychain, name) = store()
        defer { defaults.removePersistentDomain(forName: name); keychain.remove() }
        #expect(store.loadHistory() == ReviewAskHistory())
        let history = ReviewAskHistory(asked: true)
        store.save(history)
        #expect(store.loadHistory() == history)
        #expect(defaults.data(forKey: ReviewAskStore.historyKey) != nil)
        guard case let .found(data) = keychain.read() else {
            Issue.record("the Keychain item was not written")
            return
        }
        #expect((try? JSONDecoder().decode(ReviewAskHistory.self, from: data)) == history)
    }

    @Test func aReinstallKeepsWhatTheKeychainHolds() {
        let (store, defaults, keychain, name) = store()
        defer { defaults.removePersistentDomain(forName: name); keychain.remove() }
        store.save(ReviewAskHistory(asked: true))
        // Deleting the application takes its defaults and leaves the Keychain.
        defaults.removePersistentDomain(forName: name)
        #expect(store.loadHistory()?.asked == true)
    }

    @Test func theFurtherOfTwoReadingsWins() {
        let (store, defaults, keychain, name) = store()
        defer { defaults.removePersistentDomain(forName: name); keychain.remove() }
        let early = ReviewAskHistory(asked: false)
        let late = ReviewAskHistory(asked: true)
        defaults.set(try? JSONEncoder().encode(early), forKey: ReviewAskStore.historyKey)
        keychain.write((try? JSONEncoder().encode(late)) ?? Data())
        #expect(store.loadHistory() == late)
    }

    @Test func aWriteReplacesTheItemInPlace() {
        let (store, defaults, keychain, name) = store()
        defer { defaults.removePersistentDomain(forName: name); keychain.remove() }
        store.save(ReviewAskHistory(asked: false))
        store.save(ReviewAskHistory(asked: true))
        #expect(store.loadHistory()?.asked == true)
    }

    @Test func aDamagedHistoryIsNotGuessedAt() {
        let (store, defaults, keychain, name) = store()
        defer { defaults.removePersistentDomain(forName: name); keychain.remove() }
        defaults.set(Data("not json".utf8), forKey: ReviewAskStore.historyKey)
        #expect(store.loadHistory() == nil)
        defaults.removePersistentDomain(forName: name)
        keychain.write(Data("{".utf8))
        #expect(store.loadHistory() == nil, "the Keychain's copy too")
    }

    @Test func eraseGuestLeavesTheItemAlone() {
        let (store, defaults, keychain, name) = store()
        defer { defaults.removePersistentDomain(forName: name); keychain.remove() }
        store.save(ReviewAskHistory(asked: true))
        // Erase guest deletes the adb key by its tag, a key and not a password item.
        AdbKeyStore(tag: "com.example.\(name)").delete()
        #expect(keychain.read() != .absent)
        #expect(ReviewAskKeychain.defaultService != AdbKeyStore.defaultTag)
    }

    @Test func theKeychainItemIsLocalToTheDevice() throws {
        let (store, defaults, keychain, name) = store()
        defer { defaults.removePersistentDomain(forName: name); keychain.remove() }
        store.save(ReviewAskHistory(asked: true))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: name,
            kSecAttrAccount as String: ReviewAskKeychain.account, kSecUseDataProtectionKeychain as String: true,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess)
        let attributes = try #require(item as? [String: Any])
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect((attributes[kSecAttrSynchronizable as String] as? Int ?? 0) == 0)
    }
}

#endif
