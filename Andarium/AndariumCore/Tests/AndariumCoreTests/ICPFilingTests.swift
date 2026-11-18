// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing

@testable import AndariumICPLogic

/// The ICP filing footnote's logic: the number in the build's Info.plist, the
/// storefront that shows it and the address it opens. The number here is a
/// placeholder; the real one is local to the maker's build.
struct ICPFilingTests {
    private static let placeholder = "示例ICP备00000000号-0A"

    @Test func theNumberIsReadAsStoredByteForByte() {
        let number = ICPFiling.number(in: [ICPFiling.key: Self.placeholder])
        #expect(number == Self.placeholder)
        #expect(number.map { Array($0.utf8) } == Array(Self.placeholder.utf8), "no normalisation, trimming or case change")
        // Spaces inside are kept as they are.
        #expect(ICPFiling.number(in: [ICPFiling.key: "A B"]) == "A B")
    }

    @Test func noNumberIsAnythingButAStringWithText() {
        #expect(ICPFiling.number(in: nil) == nil)
        #expect(ICPFiling.number(in: [:]) == nil)
        #expect(ICPFiling.number(in: ["Other": Self.placeholder]) == nil)
        #expect(ICPFiling.number(in: [ICPFiling.key: 7]) == nil)
        #expect(ICPFiling.number(in: [ICPFiling.key: ""]) == nil)
        #expect(ICPFiling.number(in: [ICPFiling.key: " \n\t"]) == nil)
    }

    @Test func onlyMainlandChinasStorefrontShowsIt() {
        #expect(ICPFiling.isMainlandChina(countryCode: "CHN"))
        for other in ["USA", "HKG", "TWN", "MAC", "JPN", "CN", "chn", "", " CHN", "CHN "] {
            #expect(!ICPFiling.isMainlandChina(countryCode: other), "\(other.debugDescription)")
        }
        #expect(!ICPFiling.isMainlandChina(countryCode: nil), "unknown is hidden")
    }

    @Test func theLinkIsMIITsFilingSiteAndNothingElse() {
        let url = ICPFiling.siteURL
        #expect(url.absoluteString == "https://beian.miit.gov.cn/")
        #expect(url.scheme == "https" && url.host == "beian.miit.gov.cn" && url.path == "/")
        #expect(url.query == nil && url.fragment == nil && url.user == nil && url.port == nil)
    }

    @Test func theKeyIsTheOneTheBuildAndTheCheckUse() {
        #expect(ICPFiling.key == "AndariumICPNumber")
        #expect(ICPFiling.storefrontCountryCode == "CHN")
    }
}
