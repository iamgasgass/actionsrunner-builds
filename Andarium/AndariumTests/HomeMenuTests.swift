// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL || TIP_JAR || APP_REVIEW

import AndariumCore
import AndariumCoreTestSupport
import SwiftUI
import Testing
import UIKit
@testable import Andarium

/// Home's one toolbar menu: Info, and each feature that is compiled in and
/// available. A build that has all three features answers every combination of
/// them; a build with fewer answers its own; a build with none has no menu and
/// is not here (`HomePlainInfoTests`).
@MainActor
@Suite(.serialized)
struct HomeMenuTests {
    #if TIP_JAR
    private static let arranged = TipJarProductsFixture.arranged
    #endif

    private func model(guest: Bool = true, feedback: Bool = true, review: Bool = true, tips: Bool = true) -> AppModel {
        let host = HostDevice(
            name: "iPhone", processorCount: 6, memory: MemoryPolicy(maximumsMiB: [4096]), freeStorageBytes: 40_000_000_000
        )
        let model = AppModel(
            guest: guest ? Guest.fresh(on: host) : nil, host: host,
            system: SystemInfo(version: "17", release: "r2", kernel: "Linux 6.18", architecture: "arm64, 4 KiB pages", appVersion: "1"),
            capabilities: .device, createRequirementBytes: 1
        )
        model.launchApplied = true
        model.driver = StubDriver(plan: .normal)
        model.phase = .home
        #if FEEDBACK_MAIL
        model.feedbackServices.address = { feedback ? "feedback@example.com" : nil }
        #endif
        #if APP_REVIEW
        model.reviewServices.link = { review ? ReviewLink(identifier: "id1234567890") : nil }
        #endif
        #if TIP_JAR
        model.tipJarServices.products = { tips ? Self.arranged : nil }
        #endif
        return model
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// What this build's menu holds when every feature it compiled in is configured: on Home with
    /// a virtual machine all of them, on Welcome (none set up yet) Info and Send feedback only.
    private func expectedItems(onHome: Bool) -> [HomeMenuItem] {
        var items: [HomeMenuItem] = [.info]
        #if FEEDBACK_MAIL
        items.append(.sendFeedback)
        #endif
        if onHome {
            #if APP_REVIEW
            items.append(.reviewOnAppStore)
            #endif
            #if TIP_JAR
            items.append(.buyMeTokens)
            #endif
        }
        return items
    }

    /// Where this build has a menu at all: Welcome has one only with Send feedback.
    nonisolated static var places: [Bool] {
        #if FEEDBACK_MAIL
        [true, false]
        #else
        [true]
        #endif
    }

    // MARK: What the menu holds

    #if FEEDBACK_MAIL && TIP_JAR && APP_REVIEW
    /// All three features: the eight combinations, in the order the menu shows them.
    @Test func theMenuFollowsTheFeaturesInEachOfTheEightCombinations() {
        for feedback in [false, true] {
            for review in [false, true] {
                for tips in [false, true] {
                    var expected: [HomeMenuItem] = [.info]
                    if feedback { expected.append(.sendFeedback) }
                    if review { expected.append(.reviewOnAppStore) }
                    if tips { expected.append(.buyMeTokens) }
                    #expect(
                        model(feedback: feedback, review: review, tips: tips).homeMenuItems == expected,
                        "feedback \(feedback), review \(review), tips \(tips)")
                }
            }
        }
        #expect(model().homeMenuItems == [.info, .sendFeedback, .reviewOnAppStore, .buyMeTokens])
    }

    /// Welcome, before a virtual machine is set up: Send feedback is there, the other two never are.
    @Test func onWelcomeTheMenuHoldsInfoAndSendFeedbackAndNothingElse() {
        for review in [true, false] {
            for tips in [true, false] {
                #expect(
                    model(guest: false, feedback: true, review: review, tips: tips).homeMenuItems == [.info, .sendFeedback])
                #expect(model(guest: false, feedback: false, review: review, tips: tips).homeMenuItems == [.info])
            }
        }
    }
    #endif

    /// Whatever the build compiled in: each item is there exactly where its feature is configured
    /// and, for the two that need a virtual machine, where one is set up.
    @Test func eachItemIsThereWhereItsFeatureIsAvailable() {
        #expect(model().homeMenuItems == expectedItems(onHome: true))
        #expect(model(guest: false).homeMenuItems == expectedItems(onHome: false))
        #expect(model(feedback: false, review: false, tips: false).homeMenuItems == [.info])
    }

    @Test func eachItemDoesWhatItsEntranceDid() {
        let model = model()
        model.choose(.info)
        #expect(model.sheet == .info)
        model.sheet = nil
        #if FEEDBACK_MAIL
        model.choose(.sendFeedback)
        #expect(model.feedbackSheetOpen)
        #expect(model.sheet == nil, "Send feedback is its own sheet, not a page of Info")
        model.feedbackSheetOpen = false
        #endif
        #if APP_REVIEW
        var opened: [URL] = []
        model.reviewServices.open = { opened.append($0) }
        model.choose(.reviewOnAppStore)
        #expect(opened.map(\.absoluteString) == ["https://apps.apple.com/app/id1234567890?action=write-review"])
        #expect(model.sheet == nil, "the item opens the App Store, not a sheet")
        #endif
        #if TIP_JAR
        model.choose(.buyMeTokens)
        #expect(model.tipJarSheetOpen)
        model.tipJarSheetOpen = false
        #endif
        #expect(model.sheet == nil)
    }

    #if FEEDBACK_MAIL
    /// The words of the menu are in every language the application ships: Info and Send feedback.
    @Test(arguments: ["ja", "zh-Hans", "zh-Hant"])
    func theMenuSaysItsItemsInEachLanguage(language: String) {
        func text(_ key: String.LocalizationValue, table: String? = nil) -> String {
            String(localized: LocalizedStringResource(key, table: table, locale: Locale(identifier: language), bundle: .main))
        }
        #expect(text("Info") != "Info" && !text("Info").isEmpty, "\(language) says Info in English")
        let sendFeedback = text("Send feedback", table: "Feedback")
        #expect(sendFeedback != "Send feedback" && !sendFeedback.isEmpty, "\(language) says Send feedback in English")
        #expect(!sendFeedback.contains("\u{2026}"), "the menu item carries no ellipsis")
    }
    #endif

    // MARK: The real toolbar

    private func host(_ model: AppModel) async throws -> (UIViewController, HostWindow.Lease) {
        let lease = try await HostWindow.take()
        let controller = AndariumHostingController(
            rootView: RootView(entry: AppEntry(overrides: LaunchOverrides())).environment(model), model: model)
        lease.window.rootViewController = controller
        guard await eventually({ controller.viewIfLoaded?.window != nil }) else {
            lease.give()
            throw HostWindow.Failure.noKeyWindow
        }
        return (controller, lease)
    }

    /// The bar holds one menu button, which keeps Info's own accessibility label, in place of
    /// the Info button, on Home and (with Send feedback) on Welcome. (SwiftUI builds a toolbar
    /// menu's items when it opens, so what it holds is `homeMenuItems`, which `HomeToolbarMenu`
    /// lays out.)
    @Test(arguments: HomeMenuTests.places)
    func theToolbarHoldsOneMenuInPlaceOfTheInfoButton(onHome: Bool) async throws {
        let model = model(guest: onHome)
        let (controller, lease) = try await host(model)
        defer { lease.give() }
        let shown = await eventually {
            ToolbarProbe.barItems(under: controller).contains { $0.menu != nil }
        }
        try #require(shown, "the toolbar shows a menu; it holds: \(ToolbarProbe.describe(under: controller))")
        try await Task.sleep(for: .milliseconds(500))
        let items = ToolbarProbe.barItems(under: controller)
        #expect(items.filter { $0.menu != nil }.count == 1, "one menu, not one per feature")
        #expect(items.count == 1, "Info is in the menu, not beside it")
        #expect(items.first?.title == "Info" || items.first?.accessibilityLabel == "Info", "it reads Info: \(ToolbarProbe.describe(under: controller))")
        #expect(model.homeMenuItems == expectedItems(onHome: onHome), "the menu holds Info, then the features in their order")
    }

    /// What VoiceOver finds in the navigation bar: buttons labelled Info (the bar's button and
    /// the control inside it), which are the menu's control (a hint on a toolbar menu never
    /// reaches it, so the label carries the meaning). On a Mac the control inside the bar's
    /// button is named for its symbol, in lower case: "info".
    @Test func voiceOverFindsTheMenuAsTheInfoButton() async throws {
        let model = model()
        let (controller, lease) = try await host(model)
        defer { lease.give() }
        let shown = await eventually {
            ToolbarProbe.barItems(under: controller).contains { $0.menu != nil }
        }
        try #require(shown, "the toolbar shows a menu")
        try await Task.sleep(for: .milliseconds(500))
        let top = ToolbarProbe.elements(in: lease.window)
        let buttons = top.filter { $0.traits.contains(.button) && $0.top < 100 }
        let onMac = ProcessInfo.processInfo.isiOSAppOnMac
        #expect(
            !buttons.isEmpty && buttons.allSatisfy { onMac ? $0.label.lowercased() == "info" : $0.label == "Info" },
            "the bar: \(top.map(\.description))")
    }

    /// What VoiceOver reads for an item of the menu, in English.
    private func spoken(_ item: HomeMenuItem) -> String {
        switch item {
        case .info: "Info"
        #if FEEDBACK_MAIL
        case .sendFeedback: "Send feedback"
        #endif
        #if APP_REVIEW
        case .reviewOnAppStore: "Review on the App Store"
        #endif
        #if TIP_JAR
        case .buyMeTokens: String(localized: TipJarWords.name)
        #endif
        }
    }

    /// Opened as a tap opens it, the menu offers exactly its items as buttons, in the order it
    /// holds them, which is what VoiceOver finds in it. The bar's own buttons are labelled Info
    /// too and the host window holds buttons of its own, so only what the opening adds to the
    /// scene is read.
    @Test(.disabled(if: ProcessInfo.processInfo.isiOSAppOnMac, "an iPad app on a Mac draws an open menu natively, with no UIKit element for its items"))
    func theOpenMenuOffersEachItemToVoiceOver() async throws {
        let model = model()
        let (controller, lease) = try await host(model)
        defer { lease.give() }
        let shown = await eventually { ToolbarProbe.barItems(under: controller).contains { $0.menu != nil } }
        try #require(shown, "the toolbar shows a menu")
        try await Task.sleep(for: .milliseconds(600))
        let expected = model.homeMenuItems.map(spoken)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        func buttons() -> [ToolbarProbe.Element] {
            scenes.flatMap(\.windows).flatMap { ToolbarProbe.elements(in: $0, above: 4000) }
                .filter { $0.traits.contains(.button) }
        }
        // Kept alive, so that no object of the opening can take the identity of one that went.
        let beforeElements = buttons()
        let before = Set(beforeElements.map { ObjectIdentifier($0.object) })
        var pending: [UIView] = [lease.window]
        var interaction: UIContextMenuInteraction?
        while let view = pending.popLast(), interaction == nil {
            if let control = view as? UIControl,
               let menu = control.interactions.compactMap({ $0 as? UIContextMenuInteraction }).first {
                control.performPrimaryAction()
                interaction = menu
            }
            pending += view.subviews
        }
        try #require(interaction != nil, "a control of the bar carries the menu")
        defer { interaction?.dismissMenu() }
        func added() -> [ToolbarProbe.Element] {
            withExtendedLifetime(beforeElements) { buttons().filter { !before.contains(ObjectIdentifier($0.object)) } }
        }
        // The system lays an open menu's item out twice (two elements, one label and one frame), so
        // an item is counted once per place on the screen, and the items are read top to bottom.
        func items() -> [String] {
            var places = Set<String>()
            return added().sorted { $0.top < $1.top }
                .filter { places.insert("\($0.label) \($0.object.accessibilityFrame)").inserted }.map(\.label)
        }
        let found = await eventually { items().contains(expected.last ?? "") }
        try #require(found, "the open menu offers \(expected.last ?? ""): \(added().map(\.description))")
        try await Task.sleep(for: .milliseconds(400))
        #expect(items() == expected, "the open menu: \(added().map { "\($0.description) \($0.object.accessibilityFrame)" })")
    }

    /// The bar holds Info and nothing else: one item, labelled Info, and no menu.
    private func expectPlainInfo(_ controller: UIViewController) {
        let items = ToolbarProbe.barItems(under: controller)
        #expect(items.allSatisfy { $0.menu == nil }, "no menu holds Info alone")
        #expect(items.count == 1, "the bar holds Info and nothing else: \(ToolbarProbe.describe(under: controller))")
        #expect(
            items.filter { $0.title == "Info" || $0.accessibilityLabel == "Info" }.count == 1,
            "the one item reads Info: \(ToolbarProbe.describe(under: controller))")
    }

    /// With nothing configured there is nothing for a menu to hold beside Info: the plain button again.
    @Test func withNothingConfiguredInfoIsThePlainButtonAgain() async throws {
        let model = model(feedback: false, review: false, tips: false)
        let (controller, lease) = try await host(model)
        defer { lease.give() }
        try await Task.sleep(for: .seconds(1))
        #expect(model.homeMenuItems == [.info])
        expectPlainInfo(controller)
    }

    #if TIP_JAR || APP_REVIEW
    /// On Welcome the review and tip items never show, so without Send feedback Info is plain there.
    @Test func withNothingAvailableOnWelcomeInfoIsThePlainButtonAgain() async throws {
        let model = model(guest: false, feedback: false, review: true, tips: true)
        let (controller, lease) = try await host(model)
        defer { lease.give() }
        try await Task.sleep(for: .seconds(1))
        #expect(model.homeMenuItems == [.info])
        expectPlainInfo(controller)
    }
    #endif

    #if FEEDBACK_MAIL
    @Test func sendFeedbackOpensOverHomeFromTheMenu() async throws {
        let model = model()
        let (controller, lease) = try await host(model)
        defer { lease.give() }
        model.choose(.sendFeedback)
        #expect(await eventually { controller.presentedViewController != nil }, "the sheet is over Home")
        model.feedbackSheetOpen = false
        #expect(await eventually { controller.presentedViewController == nil })
    }
    #endif

    #if TIP_JAR
    @Test func buyMeTokensOpensOverHomeFromTheMenuAndNeverByItself() async throws {
        let model = model()
        let (controller, lease) = try await host(model)
        defer { lease.give() }
        // Nothing prompts: Home stays as it is while the app waits.
        try await Task.sleep(for: .seconds(2))
        #expect(controller.presentedViewController == nil && !model.tipJarSheetOpen)
        model.choose(.buyMeTokens)
        #expect(await eventually { controller.presentedViewController != nil }, "the sheet is over Home")
        model.tipJarSheetOpen = false
        #expect(await eventually { controller.presentedViewController == nil })
    }
    #endif

    // MARK: Info

    #if FEEDBACK_MAIL
    private func nodes(in node: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 64 else { return [] }
        var children = (node.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        if let view = node as? UIView { children += view.subviews }
        return [node] + children.flatMap { nodes(in: $0, depth: depth + 1) }
    }

    /// Info keeps its other rows and no longer holds Send feedback, though the receiver is configured.
    @Test func infoHoldsNoSendFeedbackSection() async throws {
        let model = model()
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let controller = UIHostingController(
            rootView: InfoSheet(page: nil).environment(model).frame(width: 440, height: 1100))
        lease.window.rootViewController = controller
        let drawn = await eventually {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            return nodes(in: controller.view).contains { $0.accessibilityLabel == "Project on GitHub" }
        }
        try #require(drawn, "Info was not drawn; is ApplicationAccessibilityEnabled on?")
        let labels = nodes(in: controller.view).compactMap(\.accessibilityLabel)
        let identifiers = nodes(in: controller.view).compactMap { ($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier }
        #expect(!labels.contains { $0.contains("Send feedback") }, "\(labels)")
        #expect(!identifiers.contains("info-send-feedback"), "\(identifiers)")
        #expect(labels.contains("Acknowledgements"), "Info still lists Acknowledgements: \(labels)")
    }
    #endif
}

#endif
