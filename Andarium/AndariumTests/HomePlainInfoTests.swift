// SPDX-License-Identifier: GPL-2.0-or-later

#if !FEEDBACK_MAIL && !TIP_JAR && !APP_REVIEW

import AndariumCore
import AndariumCoreTestSupport
import SwiftUI
import Testing
import UIKit
@testable import Andarium

/// A build that has none of Send feedback, Review on the App Store and Buy me
/// tokens has no toolbar menu: Info is the plain button it has always been.
@MainActor
@Suite(.serialized)
struct HomePlainInfoTests {
    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func infoIsAPlainButtonAndNoMenuIsThere() async throws {
        let host = HostDevice(
            name: "iPhone", processorCount: 6, memory: MemoryPolicy(maximumsMiB: [4096]), freeStorageBytes: 40_000_000_000
        )
        let model = AppModel(
            guest: Guest.fresh(on: host), host: host,
            system: SystemInfo(version: "17", release: "r2", kernel: "Linux 6.18", architecture: "arm64, 4 KiB pages", appVersion: "1"),
            capabilities: .device, createRequirementBytes: 1
        )
        model.launchApplied = true
        model.driver = StubDriver(plan: .normal)
        model.phase = .home
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let controller = AndariumHostingController(
            rootView: RootView(entry: AppEntry(overrides: LaunchOverrides())).environment(model), model: model)
        lease.window.rootViewController = controller
        let shown = await eventually { !ToolbarProbe.barItems(under: controller).isEmpty }
        try #require(shown, "the toolbar shows Info")
        try await Task.sleep(for: .seconds(1))
        let items = ToolbarProbe.barItems(under: controller)
        #expect(items.allSatisfy { $0.menu == nil }, "Info is a plain button, not a menu")
        #expect(items.count == 1, "the bar holds Info and nothing else: \(ToolbarProbe.describe(under: controller))")
        #expect(
            items.filter { $0.title == "Info" || $0.accessibilityLabel == "Info" }.count == 1,
            "the one item reads Info: \(ToolbarProbe.describe(under: controller))")
    }
}

#endif
