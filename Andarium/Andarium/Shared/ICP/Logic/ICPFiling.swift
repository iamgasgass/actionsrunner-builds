// SPDX-License-Identifier: GPL-2.0-or-later

#if ICP_FILING

import Foundation

// China's ICP filing number, the footnote at the bottom of Info: plain values
// and rules, no UIKit. The application compiles this file with the rest of
// the footnote, and only where it is compiled in; the AndariumCore package
// compiles the same file for its tests (Andarium/README.md#icp-filing-number).

/// The filing number the build names and the rule for when it is shown. The
/// number is the developer's own and is tracked nowhere: it comes from the
/// ignored local configuration, into Info.plist, and is shown as it is stored.
nonisolated enum ICPFiling {
    /// The Info.plist key the build writes the number to, only where the
    /// footnote is compiled in (`Config/Andarium.xcconfig`).
    static let key = "AndariumICPNumber"
    /// The country code StoreKit gives the storefront of mainland China (ISO
    /// 3166-1 alpha-3).
    static let storefrontCountryCode = "CHN"
    /// The Ministry of Industry and Information Technology's filing site, the
    /// public address the footnote opens.
    static let host = "beian.miit.gov.cn"

    /// The address of the filing site: `https://` and the host, with the root path.
    static var siteURL: URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = "/"
        return parts.url ?? URL(fileURLWithPath: "/")
    }

    /// The number in a property list (the application's Info.plist), exactly as
    /// stored; nil when the key is absent, its value is not a string, or it is
    /// empty or all white space.
    static func number(in info: [String: Any]?) -> String? {
        guard let value = info?[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// The number this build names.
    static var number: String? { number(in: Bundle.main.infoDictionary) }

    /// Whether a storefront is mainland China's. A storefront not known yet
    /// (not loaded, offline, no account) is nil and is not.
    static func isMainlandChina(countryCode: String?) -> Bool {
        countryCode == storefrontCountryCode
    }
}

#endif
