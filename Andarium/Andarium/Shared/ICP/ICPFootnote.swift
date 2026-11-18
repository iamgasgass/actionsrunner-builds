// SPDX-License-Identifier: GPL-2.0-or-later

#if ICP_FILING

import Observation
import StoreKit
import SwiftUI

/// Where the footnote learns the App Store storefront: its country code now
/// and each change. The application's is StoreKit 2's; a test names its own.
/// Nothing else decides: no locale, region setting, time zone or address.
struct ICPStorefrontServices: Sendable {
    /// The country code of the current storefront; nil when it is not known.
    var current: @Sendable () async -> String?
    /// The country code of each storefront that replaces the current one.
    var updates: @Sendable () -> AsyncStream<String>

    static let live = ICPStorefrontServices(
        current: { await Storefront.current?.countryCode },
        updates: {
            AsyncStream { continuation in
                let watch = Task {
                    for await storefront in Storefront.updates { continuation.yield(storefront.countryCode) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in watch.cancel() }
            }
        })
}

/// The storefront Info's footnote follows while Info is open.
@MainActor
@Observable
final class ICPStorefrontState {
    /// The current storefront's country code; nil until it is known.
    private(set) var countryCode: String?

    /// Follows the storefront until the task is cancelled (Info closing). The
    /// updates are subscribed before the current one is read, so a change in
    /// between is not lost.
    func watch(_ services: ICPStorefrontServices) async {
        let updates = services.updates()
        countryCode = await services.current()
        for await code in updates {
            countryCode = code
        }
    }
}

/// The last line of Info: the filing number as stored, in the secondary colour
/// at footnote size and centred, as a link to the filing site, which opens
/// through the system. It has no icon and no words around it, is not
/// translated, and remembers nothing about a tap.
struct ICPFootnote: View {
    let number: String

    var body: some View {
        Link(destination: ICPFiling.siteURL) {
            // The secondary label colour itself: a hierarchical `.secondary` inside a Link fades the
            // tint instead, which is too faint on either background. The underline says it is a link.
            Text(verbatim: number)
                .font(.footnote)
                .underline()
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(.rect)
        }
        .accessibilityIdentifier("info-icp")
    }
}

#endif
