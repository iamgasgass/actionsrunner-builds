// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import UIKit

/// The Simulator preview's way to show Home's toolbar menu open, as a tap on
/// the button does: it finds the navigation bar's button that carries a menu
/// and performs its primary action. It looks inside the navigation bar only,
/// so a menu elsewhere on Home is never the one it opens. Only AndariumPreview
/// builds this.
@MainActor
enum PreviewMenu {
    static func openToolbarMenu() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        var bars: [UIView] = []
        var pending: [UIView] = [window]
        while let view = pending.popLast() {
            if view is UINavigationBar {
                bars.append(view)
            } else {
                pending += view.subviews
            }
        }
        pending = bars
        while let view = pending.popLast() {
            if let control = view as? UIControl,
               control.interactions.contains(where: { $0 is UIContextMenuInteraction }) {
                control.performPrimaryAction()
                return
            }
            pending += view.subviews
        }
    }
}

#endif
