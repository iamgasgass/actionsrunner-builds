// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing

@testable import AndariumReviewLogic

/// The address Review on the App Store opens. The identifier here is the
/// placeholder of the tracked example, never the application's own.
@Suite struct ReviewLinkTests {
    @Test func theAddressIsTheWriteReviewPageWithNoStorefront() throws {
        let link = try #require(ReviewLink(identifier: "id1234567890"))
        #expect(link.url.absoluteString == "https://apps.apple.com/app/id1234567890?action=write-review")
        #expect(link.url.scheme == "https" && link.url.host == "apps.apple.com")
        // No two-letter storefront segment before `app`.
        #expect(link.url.pathComponents == ["/", "app", "id1234567890"])
        #expect(URLComponents(url: link.url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "action", value: "write-review")])
    }

    @Test func onlyAnIdentifierOfTheAppStoresShapeBuildsALink() {
        // The placeholder of the tests' arrangement has the shape; only the App Store build refuses it.
        for good in ["id123456", "id1234567890", "id100000", "id123456789012345", "id0000000000", "id00000"] {
            #expect(ReviewLink(identifier: good) != nil, "\(good)")
        }
        // A missing prefix, letters, a path, a query, spaces, and bad lengths.
        let bad = [
            "", "id", "id0000", "1234567890", "ID1234567890", "id1234",
            "id1234567890123456", "id12345a7890", "id123456/../x", "id123456?x=1", "id 123456", "id123456\n",
            "https://apps.apple.com/us/app/andarium/id1234567890", "id１２３４５６７",
        ]
        for value in bad {
            #expect(ReviewLink(identifier: value) == nil, "\(value.debugDescription)")
        }
    }

    @Test func theInfoPlistKeyIsTheOneTheBuildWrites() {
        #expect(ReviewConfiguration.key == "AndariumReviewID")
    }
}
