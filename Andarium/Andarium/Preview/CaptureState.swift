// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UIKit

/// What a screenshot run needs to know before it keeps a picture as Andarium's:
/// that this process is the app in front and ready for input. A system alert,
/// another app and the Home screen all take that away, and none of them shows
/// in the app's own state. The state is written to `capture-state.json` in the
/// app's caches directory whenever it changes, and `scripts/capture-screens.py`
/// reads it with `simctl get_app_container`.
@MainActor
enum CaptureState {
    private static var screen = ""
    private static var feedbackReady = false

    /// Send feedback's sheet is open and its draft made: a picture before this shows what is under the sheet.
    static func markFeedbackReady() {
        feedbackReady = true
        write()
    }

    static func begin(screen: String) {
        self.screen = screen
        for name in [
            UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification,
        ] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { write() }
            }
        }
        write()
    }

    private static func write() {
        let state = switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        default: "background"
        }
        var record: [String: Any] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier), "screen": screen, "state": state,
        ]
        #if FEEDBACK_MAIL
        // The screens of Send feedback exist only in a build that has it.
        record["feedback"] = true
        record["feedbackReady"] = feedbackReady
        #endif
        #if TIP_JAR
        // And those of Buy me tokens.
        record["tipjar"] = true
        #endif
        #if ICP_FILING
        // And the footnote of Info.
        record["icp"] = true
        #endif
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        try? data.write(to: caches.appendingPathComponent("capture-state.json"), options: .atomic)
    }
}
