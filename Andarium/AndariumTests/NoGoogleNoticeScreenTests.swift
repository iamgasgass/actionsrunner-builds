// SPDX-License-Identifier: GPL-2.0-or-later
import AndariumCore
import AndariumCoreTestSupport
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Andarium

/// The notice that Android has no Google apps, on purpose, on the real
/// screens in the application's window: the panel on the boot screen of a
/// first start or the retry of one that did not finish, which the end of the
/// boot takes away; the starts that never show it; and, where Send feedback is
/// compiled in, the line at the top of its mail, which opens in place, closes,
/// and is there again on the next sheet.
/// A stub stands for the runtime, and the boot ends as the runtime ends it
/// (`finishBoot`).
///
/// SwiftUI publishes its accessibility elements only while application
/// accessibility is on (the Simulator preference `ApplicationAccessibilityEnabled`);
/// a run without it finds none and the tests say so.
@Suite(.serialized)
@MainActor
struct NoGoogleNoticeScreenTests {
    private static let title = "No Google apps"
    private static let reason = "Google licenses its apps and Google Play services only to makers of certified devices."

    private let host = HostDevice(
        name: "iPhone", processorCount: 6, memory: MemoryPolicy(maximumsMiB: [4096]), freeStorageBytes: 41_000_000_000
    )

    private final class Clock {
        var now: TimeInterval = 1_000
    }

    private struct Fixture {
        let model: AppModel
        let driver: StubDriver
        let clock: Clock
    }

    private func rig(phase: Phase) -> Fixture {
        let system = SystemInfo(
            version: "17", release: "r2", kernel: "Linux 6.18", architecture: "arm64, 4 KiB pages", appVersion: "1.0 (9)")
        let model = AppModel(
            guest: Guest.fresh(on: host), host: host, system: system, capabilities: .device, createRequirementBytes: 1)
        let driver = StubDriver(plan: .normal)
        model.driver = driver
        let clock = Clock()
        model.clock = { clock.now }
        model.phase = phase
        #if FEEDBACK_MAIL
        var services = SendFeedbackServices()
        services.address = { "feedback@example.com" }
        services.canSendMail = { true }
        services.presentMail = { _, _ in true }
        services.captureScreen = { _ in nil }
        model.feedbackServices = services
        #endif
        return Fixture(model: model, driver: driver, clock: clock)
    }

    // MARK: Finding what is on screen

    private func node(in root: NSObject, depth: Int = 0, where match: (NSObject) -> Bool) -> NSObject? {
        if match(root) { return root }
        guard depth < 64 else { return nil }
        var children = (root.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        if let view = root as? UIView { children += view.subviews }
        for child in children {
            if let found = node(in: child, depth: depth + 1, where: match) { return found }
        }
        return nil
    }

    private func labelled(_ prefix: String, in root: NSObject) -> NSObject? {
        node(in: root) { $0.accessibilityLabel?.hasPrefix(prefix) == true }
    }

    private func button(_ prefix: String, in root: NSObject) -> NSObject? {
        node(in: root) { $0.accessibilityLabel?.hasPrefix(prefix) == true && $0.accessibilityTraits.contains(.button) }
    }

    private func button(exactly label: String, in root: NSObject) -> NSObject? {
        node(in: root) { $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.button) }
    }

    private func eventually(_ condition: () -> Bool, seconds: Double = 8) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// The application's root, in the window, with the model.
    private func root(_ fixture: Fixture, lease: HostWindow.Lease) -> UIViewController {
        let controller = AndariumHostingController(
            rootView: RootView(entry: AppEntry(overrides: LaunchOverrides())).environment(fixture.model),
            model: fixture.model)
        lease.window.rootViewController = controller
        controller.view.layoutIfNeeded()
        return controller
    }

    /// Whether the boot screen is up, by its status line, so an absent panel is told from an absent screen.
    private func bootScreen(_ status: String, in controller: UIViewController) async -> Bool {
        await eventually { labelled(status, in: controller.view) != nil }
    }

    // MARK: The boot screen's panel

    @Test func aFirstStartShowsThePanelAndTheEndOfTheBootTakesItAway() async throws {
        let fixture = rig(phase: .booting(.firstStart))
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let controller = root(fixture, lease: lease)
        guard await bootScreen("First start", in: controller) else {
            Issue.record("the boot screen was not found: is application accessibility on in this Simulator?")
            return
        }
        let panel = try #require(
            await eventually { labelled(Self.title, in: controller.view) != nil }
                ? labelled(Self.title, in: controller.view) : nil,
            "the first start has no panel")
        // One element, the title and then the text, and the boot's own note stays above it.
        let label = try #require(panel.accessibilityLabel)
        #expect(label.hasPrefix("No Google apps"))
        #expect(label.contains(Self.reason))
        #expect(label.contains("Install apps from files you have; many work without them."))
        #expect(labelled("The first-run setup may take a few minutes.", in: controller.view) != nil)

        // The runtime's boot ends: the session replaces the screen, and the panel goes with it.
        fixture.model.finishBoot(.firstStart)
        #expect(fixture.model.phase == .running(.normal))
        let gone = await eventually { labelled(Self.title, in: controller.view) == nil }
        #expect(gone, "the panel stayed after the boot ended")
    }

    @Test func aFirstStartAfterEraseShowsItAgain() async throws {
        // An installation started normally and then erased: its next start is a first start.
        let fixture = rig(phase: .booting(.normal))
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let controller = root(fixture, lease: lease)
        guard await bootScreen("Starting", in: controller) else {
            Issue.record("the boot screen was not found: is application accessibility on in this Simulator?")
            return
        }
        try await Task.sleep(for: .milliseconds(800))
        #expect(labelled(Self.title, in: controller.view) == nil, "a normal start shows the panel")
        fixture.model.finishBoot(.normal)
        fixture.model.phase = .booting(.firstStart)
        #expect(await eventually { labelled(Self.title, in: controller.view) != nil }, "the first start has no panel")
    }

    /// A normal start of a guest whose first Android boot did not complete is that boot still (`SlowStart` says the
    /// same); an ordinary one is not. The model reads the guest's record as the start begins.
    @Test(arguments: [true, false])
    func aNormalStartShowsThePanelOnlyWhileTheFirstBootIsUnfinished(pending: Bool) async throws {
        let fixture = rig(phase: .home)
        fixture.driver.firstBootIsPending = pending
        fixture.model.start(.normal)
        #expect(fixture.model.phase == .booting(.normal))
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let controller = root(fixture, lease: lease)
        guard await bootScreen("Starting", in: controller) else {
            Issue.record("the boot screen was not found: is application accessibility on in this Simulator?")
            return
        }
        if pending {
            #expect(await eventually { labelled(Self.title, in: controller.view) != nil }, "the retry has no panel")
        } else {
            try await Task.sleep(for: .milliseconds(800))
            #expect(labelled(Self.title, in: controller.view) == nil, "an ordinary start shows the panel")
        }
    }

    @Test(arguments: [
        (BootKind.normal, "Starting"), (.upgrade, "Updating"), (.restart, "Restarting"),
        (.recovery, "Starting recovery"),
    ])
    func everyOtherStartShowsNone(kind: BootKind, status: String) async throws {
        let fixture = rig(phase: .booting(kind))
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let controller = root(fixture, lease: lease)
        guard await bootScreen(status, in: controller) else {
            Issue.record("the boot screen was not found: is application accessibility on in this Simulator?")
            return
        }
        try await Task.sleep(for: .milliseconds(800))
        #expect(labelled(Self.title, in: controller.view) == nil, "\(kind) shows the panel")
    }

    @Test func thePanelStaysWhenTheSlowStartNoticeComesAbove() async throws {
        let fixture = rig(phase: .booting(.firstStart))
        fixture.model.slowStart.begin(at: fixture.clock.now)
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let controller = root(fixture, lease: lease)
        guard await eventually({ labelled(Self.title, in: controller.view) != nil }) else {
            Issue.record("the panel was not found: is application accessibility on in this Simulator?")
            return
        }
        // Eight minutes of a first start: the slow-start notice sits above the steps and the panel stays.
        fixture.clock.now += 481
        fixture.model.updateSlowStart()
        #expect(fixture.model.slowStart.showing)
        #expect(await eventually { button("Stop", in: controller.view) != nil }, "the slow-start notice did not come")
        #expect(labelled(Self.title, in: controller.view) != nil, "the panel went when the notice came")
    }

    // MARK: The words in each language

    private static let body = "Google licenses its apps and Google Play services only to makers of certified devices. Install apps from files you have; many work without them."

    /// The notice names Google in Latin letters and in no other way, in every language, and says why in the
    /// owner's words.
    @Test(arguments: ["en", "ja", "zh-Hans", "zh-Hant"])
    func theNoticeSaysItsWordsInEachLanguage(language: String) {
        func text(_ key: String.LocalizationValue, table: String? = nil) -> String {
            String(localized: LocalizedStringResource(key, table: table, locale: Locale(identifier: language), bundle: .main))
        }
        let title = text("No Google apps")
        let body = text("Google licenses its apps and Google Play services only to makers of certified devices. Install apps from files you have; many work without them.")
        func inLatinLetters(_ words: [String]) {
            for word in words {
                #expect(!word.isEmpty)
                #expect(!word.contains("\u{8C37}\u{6B4C}") && !word.contains("グーグル"), "\(language): Google is written in Latin letters")
            }
        }
        inLatinLetters([title, body])
        if language == "en" {
            #expect(title == "No Google apps")
            #expect(body == Self.body && body.hasPrefix(Self.reason))
        } else {
            #expect(title != "No Google apps" && body != Self.body, "\(language) says it in English")
            #expect(title.contains("Google"), "\(language): the title does not name Google")
            #expect(body.hasPrefix("Google") && body.contains("Google Play"), "\(language): the text does not name Google and Google Play")
        }
        #if FEEDBACK_MAIL
        let question = text("Missing Google apps?", table: "Feedback")
        let short = text("That\u{2019}s on purpose.", table: "Feedback")
        let line = text("That\u{2019}s on purpose. Why", table: "Feedback")
        let why = text("Why", table: "Feedback")
        let hint = text("Shows the answer", table: "Feedback")
        let dismiss = text("Dismiss Google apps note", table: "Feedback")
        let answer = text(
            "Google licenses its apps and Google Play services only to makers of certified devices. Install apps from files you have; many work without them.",
            table: "Feedback")
        inLatinLetters([question, short, line, why, hint, answer, dismiss])
        // The collapsed line is the first words and then the word that opens the answer, which the line colours.
        #expect(line.hasPrefix(short) && line.hasSuffix(why), "\(language): the line is not its first words and its Why")
        #expect(answer == body, "\(language): the answer is not the panel's text")
        if language != "en" {
            #expect(question.contains("Google") && question != "Missing Google apps?", "\(language): the question")
            for word in [short, why, hint, dismiss] { #expect(!word.isEmpty) }
            #expect(dismiss != "Dismiss Google apps note" && dismiss != text("Dismiss", table: "Feedback"), "\(language): the close button's name")
            #expect(short != "That\u{2019}s on purpose." && why != "Why" && hint != "Shows the answer", "\(language) says it in English")
        }
        #endif
    }

    // MARK: Send feedback's line

    #if FEEDBACK_MAIL

    /// The contract: every sheet opens with the line, closed, whatever was done on an earlier one.
    @Test func everySheetOpensWithTheLineClosedWhateverWasDoneOnTheLastOne() {
        let fixture = rig(phase: .home)
        let first = SendFeedbackModel(app: fixture.model)
        defer { first.close() }
        #expect(first.showsNoGoogleLine && !first.noGoogleAnswerOpen)
        // Closing the line takes it from this sheet alone.
        first.closeNoGoogleLine()
        #expect(!first.showsNoGoogleLine)
        let second = SendFeedbackModel(app: fixture.model)
        defer { second.close() }
        #expect(second.showsNoGoogleLine && !second.noGoogleAnswerOpen, "the line did not come back after it was closed")
        // Opening its answer suppresses nothing later.
        second.openNoGoogleAnswer()
        #expect(second.noGoogleAnswerOpen && second.showsNoGoogleLine)
        let third = SendFeedbackModel(app: fixture.model)
        defer { third.close() }
        #expect(third.showsNoGoogleLine && !third.noGoogleAnswerOpen, "the line did not come back after its answer was opened")
        // Opened and then closed on one sheet is closed on that one alone.
        second.closeNoGoogleLine()
        #expect(!second.showsNoGoogleLine)
        let fourth = SendFeedbackModel(app: fixture.model)
        defer { fourth.close() }
        #expect(fourth.showsNoGoogleLine && !fourth.noGoogleAnswerOpen, "the line did not come back after it was opened and closed")
    }

    @Test func theLineAtTheTopOfTheMailOpensInPlaceAndCloses() async throws {
        let fixture = rig(phase: .home)
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let controller = root(fixture, lease: lease)
        fixture.model.feedbackSheetOpen = true
        func sheetView() -> UIView? { controller.presentedViewController?.view }
        guard await eventually({ sheetView().flatMap { labelled("Send feedback", in: $0) } != nil }) else {
            Issue.record("the sheet was not found: is application accessibility on in this Simulator?")
            fixture.model.feedbackSheetOpen = false
            return
        }
        let open = try #require(
            await eventually { sheetView().flatMap { button("Missing Google apps?", in: $0) } != nil }
                ? sheetView().flatMap { button("Missing Google apps?", in: $0) } : nil,
            "the sheet has no line")
        // Collapsed: the question, the first words and the Why, and the answer is not on the sheet.
        let label = try #require(open.accessibilityLabel)
        #expect(label.contains("That\u{2019}s on purpose.") && label.hasSuffix("Why"))
        #expect(sheetView().flatMap { labelled("Missing Google apps?", in: $0)?.accessibilityLabel?.contains(Self.reason) } != true,
                "the answer was open before the tap")
        // The answer opens in place, and Send and the fields are still there.
        #expect(open.accessibilityActivate())
        let answer = await eventually { sheetView().flatMap { labelled("Missing Google apps?", in: $0)?.accessibilityLabel?.contains(Self.reason) } == true }
        #expect(answer, "the answer did not open")
        #expect(sheetView().flatMap { button("Send feedback", in: $0) } != nil, "the sheet lost its Send")
        // Close: the line goes from this sheet.
        let dismiss = try #require(
            sheetView().flatMap { button("Dismiss Google apps note", in: $0) }, "the line has no close button")
        // The bug-report card in the same sheet has a Dismiss of its own, and the two are told apart.
        let card = sheetView().flatMap { button(exactly: "Dismiss", in: $0) }
        #expect(card != nil && card !== dismiss, "the card's Dismiss is not another button")
        #expect(dismiss.accessibilityActivate())
        let gone = await eventually { sheetView().flatMap { labelled("Missing Google apps?", in: $0) } == nil }
        #expect(gone, "the line stayed after it was closed")
        // The next presentation of the sheet has the line again, closed.
        fixture.model.feedbackSheetOpen = false
        #expect(await eventually { controller.presentedViewController == nil }, "the sheet did not close")
        fixture.model.feedbackSheetOpen = true
        let back = await eventually { sheetView().flatMap { button("Missing Google apps?", in: $0) } != nil }
        #expect(back, "the line did not come back when the sheet opened again")
        #expect(sheetView().flatMap { labelled("Missing Google apps?", in: $0)?.accessibilityLabel?.contains(Self.reason) } != true,
                "the line came back open")
        fixture.model.feedbackSheetOpen = false
    }

    #endif
}
