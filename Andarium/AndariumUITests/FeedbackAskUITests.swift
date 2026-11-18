// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

#if FEEDBACK_MAIL

/// Send feedback asks about a bug report, and shows what is in one, in the real application.
///
/// The launch asks for the input probe, so a session opens with no guest behind it, and for the feedback
/// probe on top of it (`ANDARIUM_FEEDBACK_PROBE`): the Simulator has no mail account and no guest to make a
/// bug report, so the probe session gives the sheet mail that can be sent, an alert that stands in for the
/// composer (it carries the identifier `feedback-probe-composer` and names the mail) and the preview's
/// report in place of the guest's. Both the report and the question are the real ones. It needs a build with
/// Send feedback, as the build the command in docs/testing.md makes (`FEEDBACK_ADDRESS=feedback@example.com`).
///
/// One path, through every step: Send with a problem and details written and no bug report asks, with two
/// buttons, and no mail opens; Create bug report leaves the person in the sheet with the report attached and
/// no composer; the report's row leads in to its pages (the file, folders and files, a text with its thumb, the
/// picture); the report is removed and Send asks again, and Send without bug report goes on to the mail.
@MainActor
final class FeedbackAskUITests: XCTestCase {
    private func any(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The elements whose label begins with `text`, of any kind.
    private func labelled(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    /// The report's row, the button that opens it: the row's buttons share the identifier `feedback-attachment`, and
    /// the one that opens it is named for the report and its size.
    private func reportRow(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'feedback-attachment' AND label BEGINSWITH 'Bug report'"))
            .firstMatch
    }

    /// The place a text's thumb says it is at, in percent.
    private func percent(_ thumb: XCUIElement) -> Int {
        Int((thumb.value as? String)?.prefix { $0.isNumber } ?? "") ?? -1
    }

    /// Back, from a page the sheet's navigation pushed.
    private func back(in app: XCUIApplication) {
        let back = app.navigationBars.buttons["BackButton"]
        (back.exists ? back : app.navigationBars.buttons.firstMatch).tap()
    }

    /// Sends the keyboard away without a tap that could land on the sheet: Send is out of its reach while it is up.
    private func dismissKeyboard(in app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        for key in ["Return", "return", "Done", "done"] where app.keyboards.buttons[key].exists {
            app.keyboards.buttons[key].tap()
            break
        }
    }

    func testSendFeedbackAsksAboutTheBugReportAndShowsWhatIsInIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ANDARIUM_INPUT_PROBE"] = "1"
        app.launchEnvironment["ANDARIUM_FEEDBACK_PROBE"] = "1"
        app.launch()

        // The session's Settings, and its Send feedback row.
        let keys = app.buttons["Side keys"]
        XCTAssertTrue(keys.waitForExistence(timeout: 90), "the session did not open")
        keys.tap()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "the side keys did not open")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 30), "Settings did not open")
        let row = app.buttons["settings-send-feedback"]
        for _ in 0..<5 where !(row.waitForExistence(timeout: 3) && row.isHittable) {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(row.isHittable, "Settings has no Send feedback row")
        row.tap()

        // A problem and details, both written.
        let problem = any("feedback-problem", in: app)
        XCTAssertTrue(problem.waitForExistence(timeout: 30), "Send feedback did not open")
        problem.tap()
        problem.typeText("The game closes by itself")
        let details = any("feedback-details", in: app)
        details.tap()
        details.typeText("It closes after the first level.")
        dismissKeyboard(in: app)

        // Send, with no bug report attached: the question, and no mail.
        let send = app.buttons["feedback-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10), "the sheet has no Send")
        send.tap()
        let alert = app.alerts["Send without a bug report?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Send did not ask about a bug report")
        XCTAssertEqual(alert.buttons.count, 2, "the question has not exactly two buttons")
        XCTAssertTrue(alert.buttons["Create bug report"].exists, "the question has no Create bug report")
        XCTAssertTrue(alert.buttons["Send without bug report"].exists, "the question has no Send without bug report")
        XCTAssertTrue(
            labelled("Without a bug report, a problem will most likely not get fixed.", in: app).exists,
            "the question does not say that a problem will most likely not get fixed")
        XCTAssertFalse(any("feedback-probe-composer", in: app).exists, "the mail opened before the question was answered")

        // Create bug report: the sheet stays, the report is attached, and no mail opens.
        alert.buttons["Create bug report"].tap()
        let report = reportRow(in: app)
        XCTAssertTrue(report.waitForExistence(timeout: 90), "the bug report was not attached")
        XCTAssertFalse(alert.exists, "the question stayed")
        XCTAssertFalse(any("feedback-probe-composer", in: app).exists, "Create bug report opened the mail")
        XCTAssertEqual(app.textFields["feedback-problem"].value as? String, "The game closes by itself", "the draft changed")

        // The report's row leads in: its pages are inside the sheet's own navigation (Back, no Done): the file as
        // it goes with the mail, then its top level as folders and files.
        XCTAssertTrue(report.label.hasSuffix("12 files"), "the row does not say how many files the report holds: \(report.label)")
        report.tap()
        let summary = any("feedback-viewer-summary", in: app)
        XCTAssertTrue(summary.waitForExistence(timeout: 30), "the bug report did not open")
        XCTAssertTrue(summary.label.contains("12 files"), "the first page says \(summary.label)")
        XCTAssertTrue(summary.label.contains("This file goes with your mail as it is."), "the first page says \(summary.label)")
        XCTAssertTrue(app.navigationBars.buttons["BackButton"].exists, "the first page has no Back")
        XCTAssertTrue(labelled("FS/data, Folder, 4 files", in: app).waitForExistence(timeout: 30), "a chain of folders is not one row")
        let notText = labelled("dumpstate_board.bin, 2 KiB, Not text, not shown", in: app)
        XCTAssertTrue(notText.waitForExistence(timeout: 30), "a file that is not text does not say so")
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'dumpstate_board.bin'")).firstMatch.exists,
            "a file that is not text opens")

        // A short text opens as a page of lines, then Back.
        let version = labelled("version.txt, 4 B, Text", in: app)
        XCTAssertTrue(version.waitForExistence(timeout: 30), "the first page lists no text")
        version.tap()
        let text = any("feedback-viewer-text", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 30), "the entry showed no text")
        XCTAssertTrue(text.label.contains("3.0"), "the entry's text is \(text.label)")
        back(in: app)
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "Back did not return to the first page")

        // The long log scrolls on, and its thumb goes anywhere and says where while it is held.
        labelled("bugreport-lineage-2026-11-17-15-00-00.txt, ", in: app).tap()
        let thumb = any("feedback-viewer-thumb", in: app)
        XCTAssertTrue(thumb.waitForExistence(timeout: 30), "the long text has no thumb")
        XCTAssertTrue((thumb.value as? String)?.hasPrefix("0 %") == true, "the thumb reads \(String(describing: thumb.value))")
        // At rest the thumb takes a band of its own, 44 by 60 points, and not the whole edge: the rest of the edge
        // is the text's. A grip held takes the whole strip.
        let rest = thumb.frame
        XCTAssertEqual(rest.width, 44, accuracy: 1, "the thumb at rest is \(rest)")
        XCTAssertEqual(rest.height, 60, accuracy: 1, "the thumb at rest takes more than a band: \(rest)")
        let window = app.windows.firstMatch
        let height = window.frame.height
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        }
        point(rest.midX, rest.midY).press(forDuration: 0.2, thenDragTo: point(rest.midX, height * 0.6))
        let place = percent(thumb)
        XCTAssertTrue((40...75).contains(place), "the thumb did not go to about the middle: \(String(describing: thumb.value))")

        // A tap and a swipe on the edge, far from the thumb, scroll or do nothing, and never take the thumb there.
        let low = height - 70
        point(rest.midX, low).tap()
        XCTAssertEqual(percent(thumb), place, "a tap on the edge, away from the thumb, took the thumb there")
        let reading = thumb.value as? String
        point(rest.midX, low).press(
            forDuration: 0.05, thenDragTo: point(rest.midX, low - 150), withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertEqual(percent(thumb), place, "a swipe on the edge, away from the thumb, took the thumb there")
        XCTAssertNotEqual(thumb.value as? String, reading, "a swipe on the edge, away from the thumb, did not scroll the text")

        // Upward drags go on across windows of the text (about 16 KiB each, 252 KiB in all, so two windows are 13 %)
        // without a blank page and without a jump back: the thumb never goes back, and the lines are on the page.
        var last = place
        for fling in 1...18 {
            point(rest.minX - 150, height * 0.93).press(
                forDuration: 0.02, thenDragTo: point(rest.minX - 150, height * 0.10), withVelocity: .fast, thenHoldForDuration: 0)
            let now = percent(thumb)
            XCTAssertGreaterThanOrEqual(now, last, "fling \(fling) went back from \(last) % to \(now) %")
            last = now
        }
        XCTAssertGreaterThanOrEqual(last - place, 13, "eighteen drags crossed less than two windows (13 %): \(place) % to \(last) %")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '11-17 15:'")).firstMatch.waitForExistence(timeout: 10),
            "after the flings the page shows no line")
        back(in: app)
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "Back did not return to the first page")

        // The screenshot is a picture, and a folder opens like Files opens one.
        labelled("screenshot.png, ", in: app).tap()
        XCTAssertTrue(any("feedback-viewer-picture", in: app).waitForExistence(timeout: 30), "the screenshot showed no picture")
        back(in: app)
        labelled("FS/data, Folder", in: app).tap()
        XCTAssertTrue(labelled("misc, Folder", in: app).waitForExistence(timeout: 30), "the folder lists no folder")
        back(in: app)
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "Back did not return to the first page")
        back(in: app)
        XCTAssertTrue(summary.waitForNonExistence(timeout: 10), "the pages stayed")
        XCTAssertTrue(reportRow(in: app).waitForExistence(timeout: 10), "the sheet lost the report")

        // With the report attached, Send opens the mail at once.
        let sendAgain = app.buttons["feedback-send"]
        sendAgain.tap()
        let composer = any("feedback-probe-composer", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Send with a report attached did not open the mail")
        XCTAssertFalse(app.alerts["Send without a bug report?"].exists, "Send asked with a report attached")
        app.buttons["Cancel mail"].tap()
        XCTAssertTrue(composer.waitForNonExistence(timeout: 10), "the mail stayed")

        // Without the report, Send asks again, and Send without bug report goes on to the mail.
        let remove = app.buttons["Remove bug report"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "the report has no Remove")
        remove.tap()
        XCTAssertTrue(reportRow(in: app).waitForNonExistence(timeout: 10), "the report stayed")
        app.buttons["feedback-send"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Send did not ask again")
        alert.buttons["Send without bug report"].tap()
        XCTAssertTrue(
            composer.waitForExistence(timeout: 10), "Send without bug report did not go on to the mail")
        XCTAssertFalse(alert.exists, "the question stayed")
    }
}

#endif
