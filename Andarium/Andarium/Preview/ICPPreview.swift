// SPDX-License-Identifier: GPL-2.0-or-later

#if ICP_FILING

import Foundation

/// The Simulator preview's storefront for the filing number's footnote of Info
/// (`-icpStorefront …`), so that a screen does not depend on the Simulator's
/// own account. The number is the build's (the arrangement's placeholder).
///
///     -icpStorefront CHN       mainland China's storefront (the default): the footnote shows
///     -icpStorefront USA       another storefront: no footnote
///     -icpStorefront none      the storefront is not known: no footnote
///     -icpStorefront later     not known at first, mainland China's after two seconds
enum ICPPreview {
    static func configure(model: AppModel) {
        let choice = UserDefaults.standard.string(forKey: "icpStorefront") ?? "CHN"
        switch choice {
        case "none":
            model.icpStorefront = ICPStorefrontServices(current: { nil }, updates: { AsyncStream { $0.finish() } })
        case "later":
            model.icpStorefront = ICPStorefrontServices(
                current: { nil },
                updates: {
                    AsyncStream { continuation in
                        let wait = Task {
                            try? await Task.sleep(for: .seconds(2))
                            if !Task.isCancelled { continuation.yield("CHN") }
                        }
                        continuation.onTermination = { _ in wait.cancel() }
                    }
                })
        default:
            model.icpStorefront = ICPStorefrontServices(current: { choice }, updates: { AsyncStream { $0.finish() } })
        }
    }
}

#endif
