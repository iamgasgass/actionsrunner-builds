// SPDX-License-Identifier: GPL-2.0-or-later

#if TIP_JAR

import Foundation

// The developer the tip sheet's header shows: a name, the GitHub profile its
// button opens, and the X handle its other button uses. The values are local to
// the maker's build (`Config/Developer.local.xcconfig`, which Git ignores) and
// reach the product only in an AppStore build that has Buy me tokens, as
// Info.plist keys; the code builds the addresses from the handles, so no address
// is ever written in a file. The X profile's address is Follow developer on X's
// to build (`FollowXProfile`), so the handle stays a plain value here. Plain
// values and rules, no UIKit or SwiftUI.

nonisolated struct TipJarDeveloper: Equatable, Sendable {
    /// Shown as it is, in every language.
    var name: String?
    var githubURL: URL?
    /// The handle on X as the build names it, for `FollowXProfile` to judge.
    var xHandle: String?

    init(name: String? = nil, githubURL: URL? = nil, xHandle: String? = nil) {
        self.name = name
        self.githubURL = githubURL
        self.xHandle = xHandle
    }

    /// The developer a build names; every piece is nil that is absent or not well formed.
    init(name: String?, githubHandle: String?, xHandle: String?) {
        self.init(
            name: name.flatMap(Self.displayName),
            githubURL: githubHandle.flatMap(Self.githubURL),
            xHandle: xHandle.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// A name shown as a person wrote it: not empty after trimming, no control character, at most 60.
    static func displayName(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 60,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }

    /// A GitHub account: 1 to 39 letters, digits and hyphens, none at either end.
    static func githubURL(handle: String) -> URL? {
        let bytes = Array(handle.utf8)
        guard (1...39).contains(bytes.count), bytes.first != 0x2D, bytes.last != 0x2D,
              bytes.allSatisfy({ isAlphanumeric($0) || $0 == 0x2D }) else { return nil }
        return URL(string: "https://github.com/\(handle)")
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
    }
}

/// Where the developer's values and artwork are read from.
nonisolated enum TipJarDeveloperConfiguration {
    /// The Info.plist keys the build writes the values to, each only where its
    /// value is set (`Config/Andarium.xcconfig`).
    static let nameKey = "AndariumDeveloperName"
    static let githubKey = "AndariumDeveloperGitHub"
    static let xKey = "AndariumDeveloperX"
    /// The assets the build compiles in with each value, in the asset catalogs
    /// that name them: the avatar, GitHub's mark, and the X logo that Follow
    /// developer on X shares.
    static let avatarAsset = "DeveloperAvatar"
    static let githubAsset = "GitHubLogo"
    static let xAsset = "XLogo"

    static var developer: TipJarDeveloper {
        func string(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }
        return TipJarDeveloper(name: string(nameKey), githubHandle: string(githubKey), xHandle: string(xKey))
    }
}

#endif
