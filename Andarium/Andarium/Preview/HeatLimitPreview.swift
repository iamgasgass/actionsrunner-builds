// SPDX-License-Identifier: GPL-2.0-or-later

import AndariumCore
import SwiftUI
import UIKit

/// The preview's states of Settings' Performance section and of the heat
/// notice's alert. The heat is stated here (the model is told the device is
/// held at critical), so no device is heated and no runtime runs.
@MainActor
enum HeatLimitPreview {
    /// Settings' screens, which scroll to Stats and show Performance below it.
    static let settingsScreens: Set<String> = [
        "settings-performance", "settings-performance-menu", "settings-performance-off",
        "settings-performance-hot", "settings-performance-hot-off",
    ]

    static func apply(screen: String, to model: AppModel) {
        switch screen {
        case "settings-performance-off":
            model.setHeatLimit(false)
        case "settings-performance-hot":
            model.deviceHeatChanged(hot: true)
        case "settings-performance-hot-off":
            model.setHeatLimit(false)
            model.deviceHeatChanged(hot: true)
        case "session-thermal-off":
            // The session after the alert's Turn Off: the notice has gone.
            model.setHeatLimit(false)
        case "session-thermal-alert":
            // The alert is asked for once the screen is up: one asked for in
            // the first frame is presented before the window has its scene.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1800))
                model.askToTurnOffHeatLimit()
            }
        default:
            break
        }
        guard settingsScreens.contains(screen) else { return }
        // Stats' Frame rate row holds still at what Android runs at.
        model.session.readout = Readout(
            previewReadings: 10, memoryMiB: model.guest?.memoryMiB ?? Limits.defaultMemoryRangeMiB.lowerBound)
        model.session.readout.fps = model.deviceIsHot && model.heatLimitOn ? 30 : 60
        if screen == "settings-performance-menu" {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1800))
                openMenu()
            }
        }
    }

    /// Opens the menu of Settings' When hot row as a tap does, for a capture.
    /// SwiftUI's Menu is a button that carries its menu and shows it as its
    /// primary action; Settings has one.
    private static func openMenu() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        var pending: [UIView] = scenes.flatMap(\.windows)
        while let view = pending.popLast() {
            if let button = view as? UIButton, button.menu != nil, button.showsMenuAsPrimaryAction {
                button.performPrimaryAction()
                return
            }
            pending += view.subviews
        }
    }
}
