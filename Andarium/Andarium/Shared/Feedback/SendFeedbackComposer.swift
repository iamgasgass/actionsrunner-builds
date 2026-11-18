// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import MessageUI
import ObjectiveC
import UIKit

/// The system's mail composer over whatever is on screen, which hands the mail
/// to the person to read, change and send: Andarium sends nothing itself.
@MainActor
enum SendFeedbackComposer {
    /// Shows the composer and reports once how the person left it. Returns
    /// false, without reporting, when mail cannot be sent or there is no window
    /// to present from.
    static func present(
        _ request: SendFeedbackMailRequest, finished: @escaping @MainActor (SendFeedbackMailResult) -> Void
    ) -> Bool {
        // Every file arrives mapped (`SendFeedbackModel.send`); the composer never maps,
        // so it can never leave a file out of the mail.
        guard request.mapped.count == request.attachments.count,
            MFMailComposeViewController.canSendMail(), let top = topViewController()
        else { return false }
        let composer = MFMailComposeViewController()
        let delegate = Delegate(finished: finished)
        composer.mailComposeDelegate = delegate
        // The composer holds its delegate weakly.
        objc_setAssociatedObject(composer, &Delegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        composer.setToRecipients([request.address])
        composer.setSubject(request.subject)
        composer.setMessageBody(request.body, isHTML: false)
        // Mapped data: the file's pages are read as the composer copies them,
        // not all held in the application's memory at once.
        for (attachment, data) in zip(request.attachments, request.mapped) {
            composer.addAttachmentData(data, mimeType: attachment.mimeType, fileName: attachment.fileName)
        }
        top.present(composer, animated: true)
        return true
    }

    static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    private final class Delegate: NSObject, MFMailComposeViewControllerDelegate {
        nonisolated(unsafe) static var key = 0
        let finished: @MainActor (SendFeedbackMailResult) -> Void

        init(finished: @escaping @MainActor (SendFeedbackMailResult) -> Void) {
            self.finished = finished
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: (any Error)?
        ) {
            let outcome: SendFeedbackMailResult = switch result {
            case .sent: .sent
            case .saved: .saved
            case .cancelled: .cancelled
            case .failed: .failed(error?.localizedDescription ?? String(localized: "Mail couldn\u{2019}t send the message.", table: "Feedback"))
            @unknown default: .cancelled
            }
            controller.dismiss(animated: true) { self.finished(outcome) }
        }
    }
}

#endif
