// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL && !APP_STORE

import UIKit

/// What a UI test's probe session (`ANDARIUM_FEEDBACK_PROBE`, on top of `ANDARIUM_INPUT_PROBE`) gives Send
/// feedback in the Simulator, which has no mail account, no guest to make a bug report and no composer:
/// mail that can be sent, a stand-in composer (an alert that names the mail and ends it), and the
/// preview's report in place of the guest's. The receiver is the example address of the arrangement
/// (`FEEDBACK_ADDRESS=feedback@example.com` on the build line), never a local file's. An App Store build
/// has none of it.
@MainActor
enum FeedbackProbe {
    static let environmentName = "ANDARIUM_FEEDBACK_PROBE"

    static func requested(in environment: [String: String]) -> Bool {
        InputProbeLaunch.requested(in: environment) && environment[environmentName] == "1"
    }

    static func install(on model: AppModel) {
        var services = SendFeedbackServices()
        services.address = { "feedback@example.com" }
        services.canSendMail = { true }
        services.runningSeconds = { _ in 125 }
        services.presentMail = { request, finished in
            guard let top = SendFeedbackComposer.topViewController() else { return false }
            let kinds = request.attachments.map { $0.fileName }.joined(separator: ", ")
            let alert = UIAlertController(
                title: "Mail composer", message: "\(request.subject)\n\(kinds)", preferredStyle: .alert)
            alert.view.accessibilityIdentifier = "feedback-probe-composer"
            alert.addAction(UIAlertAction(title: "Cancel mail", style: .cancel) { _ in finished(.cancelled) })
            top.present(alert, animated: false)
            return true
        }
        model.feedbackServices = services
        model.playsBugReport = true
    }
}

#endif
