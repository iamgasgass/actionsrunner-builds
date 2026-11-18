// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import AndariumCore
import MessageUI
import UIKit

/// How a mail left the composer.
enum SendFeedbackMailResult: Equatable {
    case sent, saved, cancelled
    /// The system's own words for what went wrong.
    case failed(String)
}

/// What Send feedback asks of the system and of the guest, in one place a test
/// or the Simulator preview replaces: whether mail can be sent, the composer,
/// the guest's picture and the clock of the run. A launch of the application
/// has the live ones.
struct SendFeedbackServices {
    /// The receiver, from Info.plist; nil when it is absent or not well formed,
    /// which hides both entrances.
    var address: @MainActor () -> String? = { SendFeedbackConfiguration.address }
    /// `MFMailComposeViewController.canSendMail()`: a mail account exists and
    /// mail is not restricted.
    var canSendMail: @MainActor () -> Bool = { MFMailComposeViewController.canSendMail() }
    /// Presents the composer over whatever is on screen and reports how the
    /// person left it, once; false when there is nothing to present from.
    var presentMail: @MainActor (SendFeedbackMailRequest, @escaping @MainActor (SendFeedbackMailResult) -> Void) -> Bool =
        SendFeedbackComposer.present
    /// Presents the document picker over whatever is on screen, which opens
    /// what the person chooses where it is kept, and reports the URLs once;
    /// false when there is nothing to present from.
    var pickFiles: @MainActor (@escaping @MainActor ([URL]) -> Void) -> Bool = SendFeedbackFilePicker.present
    /// What the sheet asks of the file system for a picked file.
    var files = SendFeedbackFileSystem()
    /// The virtual machine's display as it is now.
    var captureScreen: @MainActor (AppModel) -> UIImage? = { $0.driver?.captureGuestDisplay() }
    /// Seconds the virtual machine has run.
    var runningSeconds: @MainActor (AppModel) -> Int? = { $0.driver?.runningSeconds() }
    /// The moment a file the sheet makes by itself is named for.
    var now: @MainActor () -> Date = { Date() }
    #if !APP_STORE
    // The Simulator preview's hooks. The App Store product has neither the
    // properties nor the code that reads them.
    /// Opens the sheet once Home or Settings has settled, as a launch of the
    /// Simulator preview asks; never in the application.
    var previewOpensAtLaunch = false
    /// The same for the sheet the boot screen's notice opens, which the root
    /// presents (`sendFeedbackFromBootSheet`).
    var previewOpensOverBoot = false
    /// Runs when the sheet appears: the Simulator preview fills a draft with it.
    var previewPrepare: @MainActor (SendFeedbackModel) async -> Void = { _ in }
    #endif
}

/// Where the receiver's address is read from.
enum SendFeedbackConfiguration {
    /// The Info.plist key the build writes the address to, only where Send
    /// feedback is compiled in (`Config/Andarium.xcconfig`).
    static let key = "AndariumFeedbackAddress"

    static var address: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              SendFeedbackMail.isWellFormed(address: value) else { return nil }
        return value
    }
}

#endif
