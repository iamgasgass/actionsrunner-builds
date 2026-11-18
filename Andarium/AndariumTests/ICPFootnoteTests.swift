// SPDX-License-Identifier: GPL-2.0-or-later

#if ICP_FILING

import AndariumCore
import AndariumCoreTestSupport
import SwiftUI
import Testing
import UIKit
@testable import Andarium

/// The filing number at the bottom of Info, as the application draws it and VoiceOver reads it, in the
/// build the arrangement makes: a Debug build made with `ICP_NUMBER=示例ICP备00000000号-0A` on the
/// xcodebuild line (a run without it does not build these tests). The storefront is injected and the
/// system's `openURL` is replaced, so nothing asks the App Store and nothing opens; the number is the
/// placeholder, never the maker's. SwiftUI publishes its accessibility elements only while
/// application accessibility is on (the Simulator preference `ApplicationAccessibilityEnabled`), so a
/// run without it fails with that said.
@MainActor
@Suite(.serialized)
struct ICPFootnoteTests {
    private static let number = "示例ICP备00000000号-0A"
    private let host = HostDevice(
        name: "iPhone", processorCount: 6, memory: MemoryPolicy(maximumsMiB: [4096]), freeStorageBytes: 40_000_000_000
    )

    /// What the replaced `openURL` was asked to open.
    @MainActor private final class Opener {
        var urls: [URL] = []
    }

    /// A storefront the test moves: what it is now, and the changes it announces.
    private final class Storefronts: @unchecked Sendable {
        private let lock = NSLock()
        private var code: String?
        private var continuation: AsyncStream<String>.Continuation?

        init(_ code: String?) { self.code = code }

        /// Whether the footnote has asked for the changes.
        var isWatched: Bool {
            lock.lock()
            defer { lock.unlock() }
            return continuation != nil
        }

        func announce(_ new: String) {
            lock.lock()
            code = new
            let continuation = continuation
            lock.unlock()
            continuation?.yield(new)
        }

        var services: ICPStorefrontServices {
            ICPStorefrontServices(
                current: { [self] in
                    lock.lock()
                    defer { lock.unlock() }
                    return code
                },
                updates: { [self] in
                    AsyncStream { stream in
                        lock.lock()
                        continuation = stream
                        lock.unlock()
                    }
                })
        }
    }

    private func model(number: String? = number, storefront: Storefronts) -> AppModel {
        let model = AppModel(
            guest: Guest.fresh(on: host), host: host,
            system: SystemInfo(
                version: "17", release: "r2", kernel: "Linux 6.18", architecture: "arm64, 4 KiB pages", appVersion: "1"),
            capabilities: .device, createRequirementBytes: 1)
        model.icpNumber = { number }
        model.icpStorefront = storefront.services
        return model
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func nodes(in node: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 64 else { return [] }
        var children = (node.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        if let view = node as? UIView { children += view.subviews }
        return [node] + children.flatMap { nodes(in: $0, depth: depth + 1) }
    }

    private func labels(in root: UIView) -> [String] { nodes(in: root).compactMap(\.accessibilityLabel) }

    /// The collection view a SwiftUI `List` stands on.
    private func list(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        for child in view.subviews {
            if let found = list(in: child) { return found }
        }
        return nil
    }

    private func footnote(in root: UIView) -> NSObject? {
        nodes(in: root).first { $0.accessibilityLabel == Self.number }
    }

    /// Info on the application's window, with `openURL` replaced by `opener`.
    private func hostInfo(
        _ model: AppModel, opener: Opener, in lease: HostWindow.Lease, width: Double = 440,
        height: Double = 1100
    ) -> UIHostingController<some View> {
        let view = InfoSheet(page: nil)
            .environment(model)
            .environment(\.openURL, OpenURLAction { url in
                opener.urls.append(url)
                return .handled
            })
            .dynamicTypeSize(.large)
            .frame(width: width, height: height)
        let controller = UIHostingController(rootView: view)
        lease.window.rootViewController = controller
        controller.view.layoutIfNeeded()
        return controller
    }

    /// Waits for Info to be drawn (its last row is there).
    private func drawn(_ root: UIView) async throws {
        let ready = await eventually {
            root.setNeedsLayout()
            root.layoutIfNeeded()
            return labels(in: root).contains("Acknowledgements")
        }
        try #require(ready, "Info was not drawn; is ApplicationAccessibilityEnabled on? \(labels(in: root))")
    }

    // MARK: In mainland China

    @Test func inMainlandChinasStorefrontTheLastLineIsTheNumberAsALink() async throws {
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let controller = hostInfo(model(storefront: Storefronts("CHN")), opener: Opener(), in: lease)
        try await drawn(controller.view)
        let root = controller.view!
        try #require(await eventually { footnote(in: root) != nil }, "\(labels(in: root))")
        let line = try #require(footnote(in: root))
        #expect(line.accessibilityTraits.contains(.link))
        // As stored, byte for byte, and read as it is: no words, no icon around it.
        #expect(Array((line.accessibilityLabel ?? "").utf8) == Array(Self.number.utf8))
        let spoken = labels(in: root)
        #expect(Set(spoken.filter { $0.contains("ICP") }) == [Self.number], "\(spoken)")
        // Below every other row.
        let acknowledgements = try #require(nodes(in: root).first { $0.accessibilityLabel == "Acknowledgements" })
        #expect(line.accessibilityFrame.minY >= acknowledgements.accessibilityFrame.maxY - 1,
                "\(line.accessibilityFrame) \(acknowledgements.accessibilityFrame)")
        // Centred in the list.
        #expect(abs(line.accessibilityFrame.midX - acknowledgements.accessibilityFrame.midX) < 40,
                "\(line.accessibilityFrame) \(acknowledgements.accessibilityFrame)")
    }

    @Test func aTapOpensMIITsFilingSiteThroughTheSystemAndRemembersNothing() async throws {
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let opener = Opener()
        let controller = hostInfo(model(storefront: Storefronts("CHN")), opener: opener, in: lease)
        try await drawn(controller.view)
        let root = controller.view!
        try #require(await eventually { footnote(in: root) != nil })
        let line = try #require(footnote(in: root))
        let before = UserDefaults.standard.dictionaryRepresentation().keys.sorted()
        let linesBefore = labels(in: root).filter { $0 == Self.number }.count
        #expect(line.accessibilityActivate())
        #expect(await eventually { !opener.urls.isEmpty })
        #expect(opener.urls.map(\.absoluteString) == ["https://beian.miit.gov.cn/"])
        #expect(opener.urls.first == ICPFiling.siteURL)
        #expect(UserDefaults.standard.dictionaryRepresentation().keys.sorted() == before)
        // The line stays as it was.
        #expect(labels(in: root).filter { $0 == Self.number }.count == linesBefore)
    }

    // MARK: Elsewhere, and while it is not known

    @Test(arguments: ["USA", "HKG", "TWN", "MAC", "JPN"]) func anotherStorefrontShowsNothing(code: String) async throws {
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let controller = hostInfo(model(storefront: Storefronts(code)), opener: Opener(), in: lease)
        try await drawn(controller.view)
        try await Task.sleep(for: .milliseconds(600))
        controller.view.layoutIfNeeded()
        #expect(footnote(in: controller.view) == nil, "\(labels(in: controller.view))")
    }

    @Test func anUnknownStorefrontShowsNothing() async throws {
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let controller = hostInfo(model(storefront: Storefronts(nil)), opener: Opener(), in: lease)
        try await drawn(controller.view)
        try await Task.sleep(for: .milliseconds(600))
        controller.view.layoutIfNeeded()
        #expect(footnote(in: controller.view) == nil, "\(labels(in: controller.view))")
    }

    @Test func withoutANumberThereIsNoLineEvenInMainlandChina() async throws {
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let controller = hostInfo(model(number: nil, storefront: Storefronts("CHN")), opener: Opener(), in: lease)
        try await drawn(controller.view)
        try await Task.sleep(for: .milliseconds(600))
        controller.view.layoutIfNeeded()
        #expect(!labels(in: controller.view).contains { $0.contains("ICP") }, "\(labels(in: controller.view))")
    }

    // MARK: A change while Info is open

    @Test func theStorefrontIsFollowedWhileInfoIsOpen() async throws {
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let storefronts = Storefronts(nil)
        let controller = hostInfo(model(storefront: storefronts), opener: Opener(), in: lease)
        try await drawn(controller.view)
        let root = controller.view!
        #expect(footnote(in: root) == nil, "not known yet: hidden")
        // The sections of the list: Info has three, and the footnote is a fourth while it shows.
        func sections() -> Int? {
            root.setNeedsLayout()
            root.layoutIfNeeded()
            return list(in: root)?.numberOfSections
        }
        try #require(await eventually { sections() != nil }, "the list of Info")
        #expect(sections() == 3)
        try #require(await eventually { storefronts.isWatched }, "Info follows the storefront while it is open")
        // The storefront becomes known as mainland China's: the line appears.
        storefronts.announce("CHN")
        #expect(await eventually { sections() == 4 && footnote(in: root) != nil }, "\(String(describing: sections()))")
        // It changes to another: the line goes.
        storefronts.announce("USA")
        // (The list is what is asked: the accessibility tree of a window no display drives keeps a removed
        // row's node until it is rebuilt.)
        #expect(await eventually { sections() == 3 }, "\(String(describing: sections()))")
    }

    /// The state alone: the current storefront, then each change, in order.
    @Test func theStateFollowsTheCurrentStorefrontAndEachChange() async throws {
        let storefronts = Storefronts(nil)
        let state = ICPStorefrontState()
        let watching = Task { await state.watch(storefronts.services) }
        defer { watching.cancel() }
        try #require(await eventually { storefronts.isWatched })
        #expect(state.countryCode == nil)
        storefronts.announce("CHN")
        #expect(await eventually { state.countryCode == "CHN" })
        storefronts.announce("USA")
        #expect(await eventually { state.countryCode == "USA" }, "\(String(describing: state.countryCode))")
        storefronts.announce("CHN")
        #expect(await eventually { state.countryCode == "CHN" })
    }

    // MARK: The build's number

    /// The number reaches the label as the arrangement states it: through xcconfig, the preprocessed
    /// Info.plist and the model, byte for byte.
    @Test func theLiveNumberIsTheBuildsInfoPlistValueByteForByte() {
        let live = AppModel(
            guest: Guest.fresh(on: host), host: host,
            system: SystemInfo(version: "17", release: "r2", kernel: "Linux 6.18", architecture: "arm64, 4 KiB pages", appVersion: "1"),
            capabilities: .device, createRequirementBytes: 1)
        let stored = Bundle.main.object(forInfoDictionaryKey: ICPFiling.key) as? String
        #expect(live.icpNumber() == stored)
        #expect(stored.map { Array($0.utf8) } == Array(Self.number.utf8), "the arrangement's placeholder, as written")
    }
}

#endif
