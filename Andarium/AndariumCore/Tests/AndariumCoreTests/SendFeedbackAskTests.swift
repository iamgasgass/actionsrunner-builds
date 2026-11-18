// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing

@testable import AndariumCore
@testable import AndariumFeedbackLogic

/// When Send asks about a missing bug report before the mail opens: with both fields written, a bug report
/// could be made right now, and none is attached. Every other state sends as it always did.
struct SendFeedbackAskTests {
    /// A sheet over a running virtual machine whose app can make a bug report, with both fields written.
    private func ready() -> SendFeedbackForm {
        var form = SendFeedbackForm(mailAvailable: true, running: true)
        form.problem = "It froze"
        form.details = "I opened a game"
        return form
    }

    private func bugReport() -> SendFeedbackAttachment {
        SendFeedbackAttachment(kind: .bugReport, url: URL(fileURLWithPath: "/staged/report.zip"), bytes: 10)
    }

    @Test func aRunningMachineWithBothFieldsWrittenAndNoReportAsks() {
        let form = ready()
        #expect(form.canMakeBugReport && form.canSend && form.missing == nil)
        #expect(form.asksAboutBugReportOnSend)
    }

    @Test func aMissingFieldIsSaidFirstAndNothingIsAskedYet() {
        var form = ready()
        form.problem = " \n"
        #expect(!form.asksAboutBugReportOnSend, "the missing-field alert comes first")
        form = ready()
        form.details = ""
        #expect(!form.asksAboutBugReportOnSend)
        form.problem = ""
        #expect(!form.asksAboutBugReportOnSend)
    }

    @Test func anAttachedReportIsNotAskedAboutAndRemovingItAsksAgain() {
        var form = ready()
        let report = bugReport()
        form.attachments.add(report)
        #expect(!form.asksAboutBugReportOnSend)
        form.attachments.remove(report.id)
        #expect(form.asksAboutBugReportOnSend, "it asks on every such tap")
        #expect(form.asksAboutBugReportOnSend, "and again on the next")
    }

    @Test func otherFilesDoNotAnswerTheQuestion() {
        var form = ready()
        for kind in [SendFeedbackAttachment.Kind.screenshot, .photo, .video, .startLog, .file] {
            form.attachments.add(SendFeedbackAttachment(kind: kind, url: URL(fileURLWithPath: "/staged/x"), bytes: 1))
        }
        #expect(form.asksAboutBugReportOnSend)
    }

    @Test func aReportThatIsBeingMadeAsksNothing() {
        var form = ready()
        form.makingBugReport = true
        #expect(!form.canSend && !form.asksAboutBugReportOnSend)
    }

    @Test func aStartThatIsStillUnderWayAsksNothing() {
        var form = SendFeedbackForm(mailAvailable: true, running: false)
        form.starting = true
        form.problem = "Slow start"
        form.details = "It takes minutes"
        #expect(form.canSend && form.missing == nil)
        #expect(!form.asksAboutBugReportOnSend, "nothing can be reproduced there, and the start log is attached")
    }

    /// The sheet opened from the main screen: no report can be made, and the card on the sheet says what one needs.
    @Test func noVirtualMachineAsksNothing() {
        var form = SendFeedbackForm(mailAvailable: true, running: false)
        form.problem = "An idea"
        form.details = "Keep the keyboard open"
        #expect(form.canSend && form.missing == nil && form.showsHowToReportBug)
        #expect(!form.asksAboutBugReportOnSend)
    }

    @Test func anAppThatCannotMakeOneNowAsksNothing() {
        var form = ready()
        form.bugReportPossible = false
        #expect(form.canSend && !form.canMakeBugReport)
        #expect(!form.asksAboutBugReportOnSend, "another task is under the overlay, or the session is not a normal one")
    }

    @Test func withoutMailOrOnceSentOrWhileSomethingElseRunsNothingIsAsked() {
        var form = ready()
        form.mailAvailable = false
        #expect(!form.asksAboutBugReportOnSend)
        form = ready()
        form.sent = true
        #expect(!form.asksAboutBugReportOnSend)
        for busy in [\SendFeedbackForm.takingScreenshot, \.importingMedia, \.addingFiles] {
            form = ready()
            form[keyPath: busy] = true
            #expect(!form.canSend && !form.asksAboutBugReportOnSend)
        }
    }

    /// Every combination of what the decision depends on, against the rule written out once more.
    @Test func everyCombinationFollowsTheRule() {
        var checked = 0
        for bits in 0..<(1 << 7) {
            func has(_ bit: Int) -> Bool { bits & (1 << bit) != 0 }
            let filled = has(0), possible = has(1), attached = has(2), making = has(3), starting = has(4)
            let running = has(5), mail = has(6)
            var form = SendFeedbackForm(mailAvailable: mail, running: running)
            form.starting = starting
            form.bugReportPossible = possible
            form.makingBugReport = making
            if filled {
                form.problem = "p"
                form.details = "d"
            }
            if attached { form.attachments.add(bugReport()) }
            let expected = filled && possible && !attached && !making && !starting && running && mail
            #expect(
                form.asksAboutBugReportOnSend == expected,
                "filled \(filled) possible \(possible) attached \(attached) making \(making) starting \(starting) running \(running) mail \(mail)")
            checked += 1
        }
        #expect(checked == 128)
    }
}
