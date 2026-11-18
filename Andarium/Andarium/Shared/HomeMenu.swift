// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL || TIP_JAR || APP_REVIEW

import SwiftUI

// Home's toolbar menu. Info is the plain button it has always been; each
// feature that is compiled in and available adds its item, and with none the
// menu does not exist (a build without any feature has no menu code at all).

/// What the menu holds, in order.
enum HomeMenuItem: Equatable {
    case info
    #if FEEDBACK_MAIL
    case sendFeedback
    #endif
    #if APP_REVIEW
    case reviewOnAppStore
    #endif
    #if TIP_JAR
    case buyMeTokens
    #endif
}

/// The glyphs of the menu's items. The menu's own button keeps Info's glyph,
/// the one the plain button shows.
enum HomeMenuSymbols {
    static let info = "info.circle"
    #if FEEDBACK_MAIL
    static let sendFeedback = "envelope"
    #endif
    #if APP_REVIEW
    static let review = "star"
    #endif
}

extension AppModel {
    /// The menu's items now: Info, then Send feedback when its receiver is
    /// configured, then Review on the App Store and Buy me tokens when a virtual
    /// machine is set up and their identifiers are configured.
    var homeMenuItems: [HomeMenuItem] {
        var items: [HomeMenuItem] = [.info]
        #if FEEDBACK_MAIL
        if feedbackAddress != nil { items.append(.sendFeedback) }
        #endif
        #if APP_REVIEW
        if reviewOffered { items.append(.reviewOnAppStore) }
        #endif
        #if TIP_JAR
        if tipJarOffered { items.append(.buyMeTokens) }
        #endif
        return items
    }

    /// What choosing an item does.
    func choose(_ item: HomeMenuItem) {
        switch item {
        case .info: sheet = .info
        #if FEEDBACK_MAIL
        case .sendFeedback: feedbackSheetOpen = true
        #endif
        #if APP_REVIEW
        case .reviewOnAppStore: openReview()
        #endif
        #if TIP_JAR
        case .buyMeTokens: tipJarSheetOpen = true
        #endif
        }
    }
}

/// Home's trailing toolbar item: the plain Info button when Info is all there
/// is, otherwise Info's own glyph as a menu that holds Info first and, after a
/// separator, the other items. It is on Welcome too, where Send feedback is
/// reachable before a virtual machine is set up.
struct HomeToolbarMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.homeMenuItems
        if items == [.info] {
            HomeInfoButton()
        } else {
            Menu {
                Button { model.choose(.info) } label: { label(of: .info) }
                    .accessibilityIdentifier(identifier(of: .info))
                Section {
                    ForEach(items.filter { $0 != .info }, id: \.self) { item in
                        Button { model.choose(item) } label: { label(of: item) }
                            .accessibilityIdentifier(identifier(of: item))
                            .accessibilityHint(hint(of: item))
                    }
                }
            } label: {
                // The plain button's own label, so the toolbar looks as it
                // does without a menu. A hint on a toolbar menu never reaches
                // its control, so the label alone says what it is.
                Label("Info", systemImage: "info")
            }
            .accessibilityLabel("Info")
            .accessibilityIdentifier("home-menu")
        }
    }

    @ViewBuilder
    private func label(of item: HomeMenuItem) -> some View {
        switch item {
        case .info: Label("Info", systemImage: HomeMenuSymbols.info)
        #if FEEDBACK_MAIL
        case .sendFeedback: Label { Text("Send feedback", tableName: "Feedback") } icon: { Image(systemName: HomeMenuSymbols.sendFeedback) }
        #endif
        #if APP_REVIEW
        case .reviewOnAppStore: Label { Text("Review on the App Store", tableName: "Review") } icon: { Image(systemName: HomeMenuSymbols.review) }
        #endif
        #if TIP_JAR
        case .buyMeTokens: Label { Text(TipJarWords.name) } icon: { Image(systemName: TipJarSymbols.menuItem) }
        #endif
        }
    }

    private func hint(of item: HomeMenuItem) -> Text {
        switch item {
        #if TIP_JAR
        case .buyMeTokens: Text(TipJarWords.menuHint)
        #endif
        default: Text(verbatim: "")
        }
    }

    private func identifier(of item: HomeMenuItem) -> String {
        switch item {
        case .info: "home-menu-info"
        #if FEEDBACK_MAIL
        case .sendFeedback: "home-menu-send-feedback"
        #endif
        #if APP_REVIEW
        case .reviewOnAppStore: "home-menu-review"
        #endif
        #if TIP_JAR
        case .buyMeTokens: "home-menu-buy-me-tokens"
        #endif
        }
    }
}

#endif
