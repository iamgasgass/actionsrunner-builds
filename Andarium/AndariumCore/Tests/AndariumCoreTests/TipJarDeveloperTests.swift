// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing

@testable import AndariumTipJarLogic

/// The developer the tip sheet's header shows. Every value here is a placeholder; the real ones are
/// local to the maker's build. The profile address on X is `FollowXProfile`'s (`FollowXTests`).
@Suite struct TipJarDeveloperTests {
    @Test func theAddressIsBuiltFromAHandleAndNeverTakenWhole() {
        #expect(TipJarDeveloper.githubURL(handle: "example")?.absoluteString == "https://github.com/example")
        let developer = TipJarDeveloper(name: "Example", githubHandle: "example-dev", xHandle: "example_dev")
        #expect(developer.name == "Example")
        #expect(developer.githubURL?.absoluteString == "https://github.com/example-dev")
        #expect(developer.xHandle == "example_dev", "the X handle stays a handle")
    }

    @Test func onlyAHandleOfGitHubsShapeBuildsAnAddress() {
        for bad in ["", "-a", "a-", "a b", "a/b", "a?b=c", "https://github.com/example", "@example", "ex\u{e9}", String(repeating: "a", count: 40)] {
            #expect(TipJarDeveloper.githubURL(handle: bad) == nil, "\(bad.debugDescription)")
        }
        #expect(TipJarDeveloper.githubURL(handle: String(repeating: "a", count: 39)) != nil)
    }

    @Test func eachPieceIsThereOnlyWhenItsValueIsWellFormed() {
        let none = TipJarDeveloper(name: nil, githubHandle: nil, xHandle: nil)
        #expect(none == TipJarDeveloper())
        let partial = TipJarDeveloper(name: "  ", githubHandle: "bad handle", xHandle: "example")
        #expect(partial.name == nil && partial.githubURL == nil && partial.xHandle == "example")
        #expect(TipJarDeveloper(name: nil, githubHandle: nil, xHandle: "").xHandle == nil)
        #expect(TipJarDeveloper.displayName("  Example  ") == "Example")
        #expect(TipJarDeveloper.displayName("a\nb") == nil)
        #expect(TipJarDeveloper.displayName(String(repeating: "a", count: 61)) == nil)
    }

    @Test func theInfoPlistKeysAndTheAssetsAreTheOnesTheBuildWrites() {
        #expect(TipJarDeveloperConfiguration.nameKey == "AndariumDeveloperName")
        #expect(TipJarDeveloperConfiguration.githubKey == "AndariumDeveloperGitHub")
        #expect(TipJarDeveloperConfiguration.xKey == "AndariumDeveloperX")
        #expect(TipJarDeveloperConfiguration.avatarAsset == "DeveloperAvatar")
        #expect(TipJarDeveloperConfiguration.githubAsset == "GitHubLogo")
        #expect(TipJarDeveloperConfiguration.xAsset == "XLogo")
    }
}
