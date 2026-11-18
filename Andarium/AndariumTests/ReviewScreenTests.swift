// SPDX-License-Identifier: GPL-2.0-or-later

#if APP_REVIEW

import AndariumCore
import AndariumCoreTestSupport
import Foundation
import Testing
@testable import Andarium

/// What the build makes of Review on the App Store in the application: the identifier in
/// Info.plist, the words in the table in each language, and that the item changes nothing. The
/// address is the package's test (`ReviewLinkTests`); the items on the menu are `HomeMenuTests`.
@MainActor
@Suite(.serialized)
struct ReviewScreenTests {
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
        return model
    }

    /// The tests' arrangement states the placeholder, which the Debug build keeps in Info.plist
    /// and the App Store configuration refuses.
    @Test func theBuildPutsTheIdentifierInInfoPlist() {
        #expect(Bundle.main.object(forInfoDictionaryKey: ReviewConfiguration.key) as? String == "id0000000000")
        #expect(
            ReviewConfiguration.link?.url.absoluteString == "https://apps.apple.com/app/id0000000000?action=write-review")
    }

    @Test func theItemNeedsTheIdentifierAndAVirtualMachine() {
        let model = app()
        #expect(model.reviewOffered)
        model.reviewServices.link = { nil }
        #expect(!model.reviewOffered)
        #expect(!app(guest: false).reviewOffered, "Welcome has no Review item")
    }

    /// The word is in the table of every language the application ships, with "App Store" as the
    /// store spells it, and the code uses the table's one key.
    @Test func theTableHoldsTheWordInEveryLanguage() throws {
        let key = "Review on the App Store"
        for language in ["en", "ja", "zh-Hans", "zh-Hant"] {
            let path = try #require(
                Bundle.main.path(forResource: "Review", ofType: "strings", inDirectory: nil, forLocalization: language),
                "the \(language) table")
            let table = try #require(NSDictionary(contentsOfFile: path) as? [String: String])
            #expect(Set(table.keys) == [key], "\(language)")
            #expect(table[key]?.contains("App Store") == true, "\(language)")
        }
        // English keeps the key; the others differ.
        let japanese = try #require(
            Bundle.main.path(forResource: "Review", ofType: "strings", inDirectory: nil, forLocalization: "ja"))
        #expect((NSDictionary(contentsOfFile: japanese) as? [String: String])?[key] != key)
    }

    /// Choosing the item opens the page and leaves no trace: no sheet, no alert, no preference.
    @Test func choosingTheItemLeavesNothingBehind() {
        let before = UserDefaults.standard.dictionaryRepresentation().filter { !$0.key.hasPrefix("NS") && !$0.key.hasPrefix("Apple") }
        let model = app()
        var opened: [URL] = []
        model.reviewServices.open = { opened.append($0) }
        model.choose(.reviewOnAppStore)
        model.choose(.reviewOnAppStore)
        #expect(opened.count == 2 && opened[0] == opened[1], "each choice opens the page, nothing counts them")
        #expect(model.sheet == nil && model.alert == nil)
        let after = UserDefaults.standard.dictionaryRepresentation().filter { !$0.key.hasPrefix("NS") && !$0.key.hasPrefix("Apple") }
        #expect(Set(after.keys) == Set(before.keys), "no preference was written")
    }
}

#endif
