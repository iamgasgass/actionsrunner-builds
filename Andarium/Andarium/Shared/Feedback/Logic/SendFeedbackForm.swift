// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import Foundation

/// What Send still lacks: the mail needs a problem (its subject) and details
/// (its body), and a file or the start log is neither.
nonisolated enum SendFeedbackMissing: Equatable, Sendable {
    case problem, details, both

    /// The Problem line is empty, so it takes the focus first.
    var focusesProblem: Bool { self != .details }
}

/// What the person has written and attached, and what each control may do:
/// every rule of the sheet's enabling in one place.
nonisolated struct SendFeedbackForm: Equatable, Sendable {
    var problem = ""
    var details = ""
    var attachments = SendFeedbackAttachments()
    /// The system can send mail (a mail account exists and mail is not
    /// restricted). Nothing can be edited or attached while it cannot.
    var mailAvailable: Bool
    /// A virtual machine runs: the sheet was opened from the session's
    /// Settings. Without one no bug report or screenshot can be made.
    var running: Bool
    /// The virtual machine is starting (the sheet was opened from the boot
    /// screen's notice, and Android has not been seen to boot): no bug report or
    /// screenshot can be made yet, and a start log is attached.
    var starting = false
    /// The app can start a bug report now: a normal session whose runtime
    /// makes one, with the guest's adb channel and the progress overlay free
    /// (no file transfer or install is under way).
    var bugReportPossible = true
    /// A bug report is being made, under the progress overlay.
    var makingBugReport = false
    /// A screenshot is being taken.
    var takingScreenshot = false
    /// Picked photos and videos are being copied into the sheet's folder.
    var importingMedia = false
    /// Picked files are being looked at, or one that cannot be used where it
    /// is is being copied.
    var addingFiles = false
    /// The mail was sent. The sheet stays as it was under the notice that says
    /// so, until the person closes the notice: nothing is edited, attached or
    /// sent again, and the sheet asks no question about what it holds.
    var sent = false

    init(mailAvailable: Bool, running: Bool) {
        self.mailAvailable = mailAvailable
        self.running = running
    }

    var trimmedProblem: String { problem.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedDetails: String { details.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What is empty of the two fields Send needs (white space and line breaks
    /// are empty); nil when both are written. Send stays enabled while one is
    /// missing, so that its tap can say which.
    var missing: SendFeedbackMissing? {
        switch (trimmedProblem.isEmpty, trimmedDetails.isEmpty) {
        case (true, true): .both
        case (true, false): .problem
        case (false, true): .details
        case (false, false): nil
        }
    }

    /// Something is under way that the sheet waits for.
    var isBusy: Bool { makingBugReport || takingScreenshot || importingMedia || addingFiles }

    /// The fields can be edited.
    var fieldsEnabled: Bool { mailAvailable && !makingBugReport && !sent }

    /// Nothing is under way and the mail has not gone: a button may act.
    private var idle: Bool { !isBusy && !sent }

    var canMakeBugReport: Bool {
        mailAvailable && running && bugReportPossible && idle && attachments.bugReport == nil
    }
    var canTakeScreenshot: Bool { mailAvailable && running && idle }
    var canAddMedia: Bool { mailAvailable && idle }
    var canAddFiles: Bool { mailAvailable && idle }
    /// Send can be tapped: it opens the mail when `missing` is nil and says what is missing otherwise.
    var canSend: Bool { mailAvailable && idle }
    /// A tap on Send would open the mail. Send looks dimmed until then, so
    /// that nobody has to tap it to learn that a field is still empty.
    var readyToSend: Bool { canSend && missing == nil }

    /// Send, with both fields written, asks first: a bug report could be made
    /// right now (`canMakeBugReport`: the virtual machine runs, the app can start
    /// one, nothing else is under way) and none is attached. It asks on every
    /// such tap. Where no bug report can be made (no virtual machine, a start
    /// still under way, another task under the overlay) Send opens the mail as
    /// ever: the sheet's card says what a bug report needs there.
    var asksAboutBugReportOnSend: Bool {
        canSend && missing == nil && !starting && canMakeBugReport
    }

    /// Where a bug report would be, the way to one: only a running virtual
    /// machine can make it.
    var showsHowToReportBug: Bool { !running }

    /// What the card above the bar says.
    enum Tip: Equatable, Sendable {
        /// Opened from Home: nothing runs, and the way to a bug report is to
        /// start the virtual machine and open the sheet from its Settings.
        case home
        /// Opened during a start: a bug report and a screenshot wait for the
        /// start to finish, and the start log is attached.
        case starting
        /// A virtual machine runs: the bug report is made from the sheet.
        case running
    }

    var tip: Tip { running ? .running : (starting ? .starting : .home) }

    /// Something is typed or attached: closing asks first, and the sheet
    /// cannot be swiped away.
    /// The start log, which the sheet attaches by itself, is not something the
    /// person made: a sheet that holds nothing else closes without asking.
    var hasContent: Bool {
        !trimmedProblem.isEmpty || !trimmedDetails.isEmpty || attachments.items.contains { $0.kind != .startLog }
    }
}

#endif
