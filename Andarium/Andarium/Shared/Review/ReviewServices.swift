// SPDX-License-Identifier: GPL-2.0-or-later

#if APP_REVIEW

import UIKit

/// What Review on the App Store asks of the build and of the system, in one
/// place a test replaces. A launch of the application has the live ones.
struct ReviewServices {
    /// The page's identifier, from Info.plist; nil when it is absent or not an
    /// App Store identifier, which hides the item.
    var link: @MainActor () -> ReviewLink? = { ReviewConfiguration.link }
    /// Hands the address to the system, which opens the App Store's page (the
    /// call SwiftUI's `openURL` ends in). No in-app review prompt, no web view.
    var open: @MainActor (URL) -> Void = { UIApplication.shared.open($0, options: [:], completionHandler: nil) }
    /// What the rating prompt asks (`ReviewAsk`).
    var ask = ReviewAskServices()
}

extension AppModel {
    /// The item is offered: the identifier is configured and a virtual machine
    /// is set up.
    var reviewOffered: Bool { guest != nil && reviewServices.link() != nil }

    /// Opens the application's write-review page in the App Store. Someone who
    /// went to write a review is not asked for a rating afterwards.
    func openReview() {
        guard let link = reviewServices.link() else { return }
        reviewAsk?.openedReview()
        reviewServices.open(link.url)
    }
}

#endif
