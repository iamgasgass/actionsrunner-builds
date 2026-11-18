// SPDX-License-Identifier: GPL-2.0-or-later

#if APP_REVIEW

import Foundation

// Review on the App Store's logic: the address of the application's
// write-review page, built from the identifier the build reads from the
// ignored local configuration. The application compiles these files with the
// rest of the feature, and only where it is compiled in; the AndariumCore
// package compiles the same files for its tests
// (Andarium/README.md#review-on-the-app-store).

/// The App Store page of this application, from its identifier ("id" and
/// digits, as the page's address spells it).
nonisolated struct ReviewLink: Equatable, Sendable {
    let identifier: String

    /// nil unless the identifier is `id` and 5 to 15 digits: the one shape the
    /// App Store bundle check holds the build's identifier to
    /// (`Andarium/scripts/check-app-store-bundle.py`, which also refuses the
    /// all-zero placeholder the tests' arrangement uses in an App Store build).
    init?(identifier: String) {
        let bytes = Array(identifier.utf8)
        guard bytes.count >= 7, bytes.count <= 17, bytes[0] == 0x69, bytes[1] == 0x64 else { return nil }
        let digits = bytes.dropFirst(2)
        guard digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        self.identifier = identifier
    }

    /// The page that writes a review, with no storefront in it: the App Store
    /// opens it in the person's own.
    var url: URL {
        // The identifier holds letters and digits only, so the address is always valid.
        URL(string: "https://apps.apple.com/app/\(identifier)?action=write-review")!
    }
}

/// Where the identifier is read from.
nonisolated enum ReviewConfiguration {
    /// The Info.plist key the build writes the identifier to, only where the
    /// feature is compiled in (`Config/Andarium.xcconfig`).
    static let key = "AndariumReviewID"

    static var link: ReviewLink? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        return ReviewLink(identifier: identifier)
    }
}

#endif
