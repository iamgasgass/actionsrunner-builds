// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

/// The notice that Android has no Google apps, on purpose, in the real
/// application.
///
/// The first start: the launch gives the application a guest instance of its
/// own (`ANDARIUM_GUEST_INSTANCE`, a folder in the Simulator's container that
/// no other launch uses), so there is no virtual machine; the test sets one
/// up, starts it, finds the panel last in the boot screen's column, below its
/// first-run note, while the real runtime boots Android on the Simulator's
/// software renderer, and waits for the boot to end, which takes the screen and
/// the panel away.
///
/// Send feedback: the line at the top of its mail, reached from a session's
/// Settings (the launch asks for the input probe, so a session opens with no
/// guest behind it). It is in the mail before anything is written, answers in
/// place and closes; that it is there again on the next sheet is the hosted
/// `NoGoogleNoticeScreenTests`'s. It exists
/// only in a build with Send feedback, as the build the command in
/// docs/testing.md makes (`FEEDBACK_ADDRESS=feedback@example.com`).
@MainActor
final class NoGoogleNoticeUITests: XCTestCase {
    private let reason = "Google licenses its apps and Google Play services only to makers of certified devices."

    /// The elements whose label holds `text`, of any kind: SwiftUI combines a panel into one.
    private func labelled(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testAFirstStartShowsThePanelAndTheBootEndsWithoutIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ANDARIUM_GUEST_INSTANCE"] = "no-google-notice-\(UUID().uuidString.prefix(8))"
        app.launch()

        // No virtual machine yet: set one up, and start it.
        let setUp = app.buttons["Set up virtual machine"]
        XCTAssertTrue(setUp.waitForExistence(timeout: 120), "there is no Welcome screen")
        setUp.tap()
        let create = app.buttons["Create"]
        XCTAssertTrue(create.waitForExistence(timeout: 30), "the create sheet did not open")
        create.tap()
        // Home's button says "Start and set up" until the first start has happened.
        let start = app.buttons["Start and set up"]
        XCTAssertTrue(start.waitForExistence(timeout: 600), "the virtual machine was not created")
        start.tap()

        // The first start's boot screen: its own note, and below it the panel.
        let panel = labelled("No Google apps", in: app)
        XCTAssertTrue(panel.waitForExistence(timeout: 120), "the first start has no panel")
        XCTAssertTrue(panel.label.contains(reason), "the panel says \(panel.label)")
        XCTAssertTrue(
            labelled("The first-run setup may take a few minutes.", in: app).exists, "the boot's own note is not there")
        // The status line is one element with the elapsed time.
        XCTAssertTrue(labelled("First start", in: app).exists, "this is not the first start's screen")

        // Android's first boot ends: the session replaces the screen, and the panel goes with it.
        XCTAssertTrue(
            panel.waitForNonExistence(timeout: 1500), "the panel stayed: the boot did not end, or the panel outlived it")
        XCTAssertFalse(labelled("First start", in: app).exists, "the boot screen stayed")
    }

    #if FEEDBACK_MAIL

    func testSendFeedbackShowsTheLineAndItAnswersInPlaceAndCloses() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ANDARIUM_INPUT_PROBE"] = "1"
        app.launch()
        let keys = app.buttons["Side keys"]
        XCTAssertTrue(keys.waitForExistence(timeout: 90), "the session did not open")
        keys.tap()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "the side keys did not open")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 30), "Settings did not open")

        // Settings opens at its medium detent on an iPhone, and a list makes no row it does not show.
        let row = app.buttons["settings-send-feedback"]
        for _ in 0..<5 where !(row.waitForExistence(timeout: 3) && row.isHittable) {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(row.isHittable, "Settings has no Send feedback row")
        row.tap()

        // The line is at the top of the mail, collapsed: the question and the way to the answer.
        let line = app.buttons["no-google-feedback-open"]
        XCTAssertTrue(line.waitForExistence(timeout: 30), "Send feedback has no line about Google apps")
        XCTAssertTrue(line.label.contains("Missing Google apps?"), "the line says \(line.label)")
        XCTAssertTrue(line.label.contains("That\u{2019}s on purpose."), "the line says \(line.label)")
        XCTAssertTrue(app.textFields.firstMatch.exists || app.textViews.firstMatch.exists, "the mail has no fields")
        let answer = labelled(reason, in: app)
        XCTAssertFalse(answer.exists, "the answer was open before the tap")

        // The answer opens in place, with the reason, and the mail is still there.
        line.tap()
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "the answer did not open")
        XCTAssertTrue(app.buttons["Send feedback"].exists, "the mail lost its Send")

        // Closing takes the line away. The button is a 44 pt target with its own VoiceOver name (the bug-report card's
        // is "Dismiss"), and a tap 18 pt from the glyph's centre on each axis, past where a bare glyph reaches, closes it.
        let close = app.buttons["no-google-feedback-close"]
        XCTAssertTrue(close.exists, "the line has no close button")
        XCTAssertEqual(close.label, "Dismiss Google apps note")
        XCTAssertGreaterThanOrEqual(close.frame.width, 44, "the close button is narrower than 44 pt")
        XCTAssertGreaterThanOrEqual(close.frame.height, 44, "the close button is lower than 44 pt")
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 18, dy: 18)).tap()
        XCTAssertTrue(answer.waitForNonExistence(timeout: 10), "the line stayed after it was closed")
        XCTAssertFalse(app.buttons["no-google-feedback-open"].exists)
    }

    #endif
}
