// SPDX-License-Identifier: GPL-2.0-or-later

#if TIP_JAR

import AndariumCore
import AndariumCoreTestSupport
import Foundation
import Testing
import UIKit
@testable import Andarium

/// The identifiers the arrangement states on the command line, which Info.plist
/// then holds.
enum TipJarProductsFixture {
    static let arranged = TipJarProducts([
        "lite": "com.example.andarium.tip.lite", "pro": "com.example.andarium.tip.pro",
        "max": "com.example.andarium.tip.max", "ultra": "com.example.andarium.tip.ultra",
    ])!
}

/// What the build makes of the tip jar in the application: the identifiers in
/// Info.plist, the words in the table and what the sheet keeps. The sheet's
/// states are the package's tests (`TipJarTests`), the live store the
/// StoreKit environment's (`TipJarStoreKitTests`).
@MainActor
@Suite(.serialized)
struct TipJarScreenTests {
    private func app(guest: Bool = true) -> AppModel {
        let host = HostDevice(
            name: "iPhone", processorCount: 6, memory: MemoryPolicy(maximumsMiB: [4096]), freeStorageBytes: 40_000_000_000
        )
        let model = AppModel(
            guest: guest ? Guest.fresh(on: host) : nil, host: host,
            system: SystemInfo(version: "17", release: "r2", kernel: "Linux 6.18", architecture: "arm64, 4 KiB pages", appVersion: "1"),
            capabilities: .device, createRequirementBytes: 1
        )
        model.launchApplied = true
        model.phase = .home
        model.tipJarServices.products = { TipJarProductsFixture.arranged }
        return model
    }

    @Test func theBuildPutsTheFourIdentifiersInInfoPlist() {
        #expect(TipJarConfiguration.products == TipJarProductsFixture.arranged)
        let raw = Bundle.main.object(forInfoDictionaryKey: TipJarConfiguration.key) as? [String: String]
        #expect(raw?.count == 4 && raw?.values.allSatisfy { !$0.isEmpty } == true)
    }

    @Test func theEntranceNeedsTheIdentifiersAndAVirtualMachine() {
        let model = app()
        #expect(model.tipJarOffered)
        model.tipJarServices.products = { nil }
        #expect(!model.tipJarOffered && model.makeTipJarModel() == nil)
        #expect(!app(guest: false).tipJarOffered)
    }

    /// Every word the sheet shows is a key of the table the build compiles in, and the table has
    /// no other key: the code and the catalog say the same.
    @Test func theTableHoldsExactlyTheWordsTheCodeUses() throws {
        let path = try #require(Bundle.main.path(forResource: "TipJar", ofType: "strings", inDirectory: nil, forLocalization: "en"))
        let table = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
        let keys = TipJarWords.all.map(\.key)
        #expect(Set(table.keys) == Set(keys))
        for key in keys {
            let value = Bundle.main.localizedString(forKey: key, value: "\u{1}missing", table: TipJarWords.tableName)
            #expect(value != "\u{1}missing", "\(key)")
        }
        // The table says what a tip is.
        let statement = table.values.first { $0.contains("voluntary") && $0.contains("purchase") }
        #expect(statement?.contains("one-time purchase") == true && statement?.contains("Every feature is free") == true)
    }

    /// A tip changes nothing about the application: the entrance, the menu and what the system
    /// remembers for the app are as before, whoever tipped.
    @Test func aTipLeavesNothingBehindInTheApplication() async throws {
        let before = UserDefaults.standard.dictionaryRepresentation().filter { !$0.key.hasPrefix("NS") && !$0.key.hasPrefix("Apple") }
        let model = app()
        let items = model.homeMenuItems
        let store = TipJarStoreServices(
            canMakePayments: { true },
            products: { ids in ids.map { TipJarProduct(identifier: $0, displayPrice: "$1.00") } },
            purchase: { .purchased(TipJarTransaction(productIdentifier: $0) {}) },
            transactions: { AsyncStream { $0.finish() } })
        model.tipJarServices.store = store
        model.tipJarSheetOpen = true
        let jar = try #require(model.makeTipJarModel())
        jar.start()
        let deadline = ContinuousClock.now + .seconds(10)
        while jar.phase == .loading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        jar.purchase(.ultra)
        while !jar.thanked, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(jar.thanked)
        jar.close()
        model.tipJarSheetOpen = false
        #expect(model.homeMenuItems == items, "the menu is what it was")
        #expect(!model.tipJarSheetOpen && model.sheet == nil && model.alert == nil)
        let after = UserDefaults.standard.dictionaryRepresentation().filter { !$0.key.hasPrefix("NS") && !$0.key.hasPrefix("Apple") }
        #expect(Set(after.keys) == Set(before.keys), "no preference was written")
        // The next opening is the first one again.
        let next = try #require(model.makeTipJarModel())
        #expect(next.phase == .loading && next.outcome == nil && next.purchasing == nil && !next.thanked)
    }
}

#endif
