// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import AndariumCore
import AndariumCoreTestSupport
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Andarium

/// The Send feedback sheet's model, hosted in the application: the bug report
/// made from the sheet under the app's own overlay, the screenshot, the picked
/// photos, the mail and everything cleaned up after. A stub stands for the
/// runtime and the system's mail composer and picture are replaced, so the tests
/// send no mail, read no photo library and capture no real display. They run
/// where Send feedback is compiled in: a build made with
/// `FEEDBACK_ADDRESS=feedback@example.com` on the xcodebuild command line.
@Suite(.serialized)
@MainActor
struct SendFeedbackScreenTests {
    private let host = HostDevice(
        name: "iPhone", processorCount: 6, memory: MemoryPolicy(maximumsMiB: [4096]), freeStorageBytes: 41_000_000_000
    )

    /// A mail request the stand-in composer was handed, and the way out of it.
    @MainActor private final class Composer {
        var request: SendFeedbackMailRequest?
        /// How many times the composer was opened.
        private(set) var opened = 0
        private var finish: (@MainActor (SendFeedbackMailResult) -> Void)?

        func open(_ request: SendFeedbackMailRequest, _ finish: @escaping @MainActor (SendFeedbackMailResult) -> Void) {
            self.request = request
            opened += 1
            self.finish = finish
        }

        /// The person leaves the composer.
        func leave(_ result: SendFeedbackMailResult) {
            finish?(result)
            finish = nil
        }
    }

    private struct Fixture {
        let app: AppModel
        let driver: StubDriver
        let composer: Composer
        let root: URL
        let staging: SendFeedbackStaging

        func sheet() -> SendFeedbackModel { SendFeedbackModel(app: app, staging: staging) }
    }

    private func fixture(
        phase: Phase = .running(.normal), mail: Bool = true, screen: UIImage? = SendFeedbackScreenTests.picture()
    ) -> Fixture {
        let system = SystemInfo(
            version: "17", release: "r2", kernel: "Linux 6.18", architecture: "arm64, 4 KB pages", appVersion: "1.0 (9)"
        )
        let app = AppModel(
            guest: Guest.fresh(on: host), host: host, system: system, capabilities: .device, createRequirementBytes: 1)
        let driver = StubDriver(plan: .normal)
        app.driver = driver
        app.phase = phase
        let composer = Composer()
        var services = SendFeedbackServices()
        services.address = { "feedback@example.com" }
        services.canSendMail = { mail }
        services.presentMail = { request, finish in
            composer.open(request, finish)
            return true
        }
        services.captureScreen = { _ in screen }
        services.runningSeconds = { _ in 125 }
        app.feedbackServices = services
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("andarium-feedback-hosted-\(UUID().uuidString)", isDirectory: true)
        return Fixture(app: app, driver: driver, composer: composer, root: root, staging: SendFeedbackStaging(root: root))
    }

    private nonisolated static func picture(width: Int = 90, height: Int = 160) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func report(in fixture: Fixture) throws -> URL {
        try FileManager.default.createDirectory(at: BugReportStaging.directory, withIntermediateDirectories: true)
        let url = BugReportStaging.directory.appendingPathComponent("bugreport-\(UUID().uuidString).zip")
        try Data(repeating: 0x50, count: 4096).write(to: url)
        return url
    }

    private nonisolated final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        func release() { lock.withLock { open = true } }
        var isOpen: Bool { lock.withLock { open } }
    }

    // MARK: Entrances

    @Test func theEntrancesNeedAReceiver() {
        let fixture = fixture()
        #expect(fixture.app.feedbackAddress == "feedback@example.com")
        fixture.app.feedbackServices.address = { nil }
        #expect(fixture.app.feedbackAddress == nil)
        // The build's own reading: the example receiver of the arrangement, well formed.
        #expect(SendFeedbackConfiguration.address == "feedback@example.com")
    }

    // MARK: Bug report

    @Test func aBugReportFromTheSheetKeepsSettingsAndTheRunAndBecomesARow() async throws {
        let fixture = fixture()
        let file = try report(in: fixture)
        let gate = Gate()
        fixture.driver.bugReport = { update in
            update(BusyUpdate(progress: 0.5))
            while !gate.isOpen { try await Task.sleep(for: .milliseconds(5)) }
            return file
        }
        var shared = false
        fixture.app.presentShare = { _, _ in
            shared = true
            return true
        }
        fixture.app.sessionSettingsOpen = true
        let sheet = fixture.sheet()
        #expect(sheet.state.running && sheet.state.canMakeBugReport)
        sheet.createBugReport()
        // The sheet draws the app's overlay; the screens do not.
        #expect(fixture.app.busyOverSheet)
        #expect(fixture.app.feedbackBusy?.title == "Creating bug report")
        #expect(fixture.app.feedbackBusy?.cancel != nil)
        #expect(sheet.state.makingBugReport && !sheet.state.fieldsEnabled && !sheet.state.canSend)
        #expect(await eventually { fixture.app.feedbackBusy?.progress == 0.5 })
        gate.release()
        #expect(await eventually { sheet.form.attachments.bugReport != nil })
        let attached = try #require(sheet.form.attachments.bugReport)
        #expect(attached.bytes == 4096)
        #expect(attached.url.deletingLastPathComponent().standardizedFileURL == sheet.folder.url.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: file.path), "the archive moved into the sheet's folder")
        // Nothing shared, nothing dismissed, nothing stopped.
        #expect(!shared)
        #expect(fixture.app.busy == nil && !fixture.app.busyOverSheet && fixture.app.feedbackBusy == nil)
        #expect(fixture.app.sessionSettingsOpen)
        #expect(fixture.app.phase == .running(.normal))
        #expect(!sheet.state.canMakeBugReport, "one report at most")
        sheet.close()
    }

    @Test func cancellingTheReportReturnsToTheSheetWithNothingAttached() async throws {
        let fixture = fixture()
        let stopped = Gate()
        fixture.driver.bugReport = { _ in
            do {
                while true { try await Task.sleep(for: .milliseconds(5)) }
            } catch {
                stopped.release()
                throw error
            }
        }
        let sheet = fixture.sheet()
        sheet.createBugReport()
        let cancel = try #require(fixture.app.feedbackBusy?.cancel)
        cancel.action()
        #expect(await eventually { fixture.app.busy == nil })
        #expect(stopped.isOpen)
        #expect(sheet.form.attachments.isEmpty && sheet.failure == nil && fixture.app.alert == nil)
        #expect(!fixture.app.busyOverSheet && sheet.state.fieldsEnabled)
        sheet.close()
    }

    @Test func aFailedReportIsSaidInTheSheetNotOverTheScreens() async throws {
        let fixture = fixture()
        fixture.driver.bugReport = { _ in throw AdbFailure(.refused, activity: .bugReport) }
        let sheet = fixture.sheet()
        sheet.createBugReport()
        #expect(await eventually { sheet.failure != nil })
        #expect(sheet.failure?.title == "Bug report not created")
        #expect(sheet.failure?.message == "The virtual machine isn\u{2019}t ready to make a bug report. Try again in a moment.")
        #expect(fixture.app.alert == nil && fixture.app.busy == nil && !fixture.app.busyOverSheet)
        #expect(sheet.form.attachments.isEmpty)
        sheet.close()
    }

    @Test func aReportThatArrivesAfterTheSheetClosedIsDeleted() async throws {
        let fixture = fixture()
        let file = try report(in: fixture)
        let gate = Gate()
        fixture.driver.bugReport = { _ in
            while !gate.isOpen { try await Task.sleep(for: .milliseconds(5)) }
            return file
        }
        let sheet = fixture.sheet()
        sheet.createBugReport()
        sheet.close()
        gate.release()
        #expect(await eventually { fixture.app.busy == nil })
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!sheet.folder.exists)
    }

    @Test func aReportCancelledAsItFinishesIsNotAttachedAndItsFileGoes() async throws {
        let fixture = fixture()
        let file = try report(in: fixture)
        let gate = Gate()
        let started = Gate()
        fixture.driver.bugReport = { _ in
            started.release()
            // Ignores the cancel: a separate task waits, the report is returned.
            await Task.detached { while !gate.isOpen { try? await Task.sleep(for: .milliseconds(5)) } }.value
            return file
        }
        let sheet = fixture.sheet()
        sheet.createBugReport()
        #expect(await eventually { started.isOpen })
        try #require(fixture.app.feedbackBusy?.cancel).action()
        gate.release()
        #expect(await eventually { fixture.app.busy == nil })
        #expect(sheet.form.attachments.isEmpty && sheet.failure == nil && fixture.app.alert == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(sheet.state.canMakeBugReport, "the person can try again")
        sheet.close()
    }

    @Test func theBugReportControlFollowsWhatTheAppCanMake() throws {
        let fixture = fixture()
        let sheet = fixture.sheet()
        #expect(sheet.state.bugReportPossible && sheet.state.canMakeBugReport)
        // A file transfer holds the guest's one adb channel, as for the Create
        // bug report row.
        let browser = FileBrowserModel(backend: FileBrowserModelTests.ScriptedBackend(), center: NotificationCenter())
        fixture.app.fileBrowser = browser
        browser.transfer = FileTransfer(direction: .importing, folder: GuestPath.root, items: [])
        #expect(browser.busy && !fixture.app.canCreateBugReport)
        #expect(!sheet.state.bugReportPossible && !sheet.state.canMakeBugReport)
        #expect(sheet.state.canTakeScreenshot && sheet.state.canAddMedia, "the rest of the bar works")
        sheet.createBugReport()
        #expect(fixture.app.busy == nil && !fixture.app.busyOverSheet && sheet.failure == nil)
        browser.transfer = nil
        #expect(sheet.state.canMakeBugReport)
        // Another task under the overlay (an install).
        fixture.app.busy = BusyState(title: "Installing", detail: "Detail", progress: nil)
        #expect(!sheet.state.canMakeBugReport)
        fixture.app.busy = nil
        #expect(sheet.state.canMakeBugReport)
        sheet.close()
        // Recovery mode runs a guest but makes no bug report.
        let recovery = self.fixture(phase: .running(.recovery))
        let other = recovery.sheet()
        #expect(other.state.running && !other.state.canMakeBugReport && other.state.canTakeScreenshot)
        other.close()
    }

    // MARK: Closing under a parent that goes

    @Test func closingTheSheetGivesTheOverlayAndTheFlagBackToTheScreens() async throws {
        let fixture = fixture()
        let gate = Gate()
        fixture.driver.bugReport = { _ in
            while !gate.isOpen { try await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        }
        fixture.app.feedbackSheetOpen = true
        let sheet = fixture.sheet()
        sheet.createBugReport()
        #expect(fixture.app.busyOverSheet && fixture.app.feedbackBusy != nil)
        // The parent goes under the sheet (the low-space pause, the end of a
        // run): the sheet closes with a report under way.
        sheet.close()
        #expect(!fixture.app.busyOverSheet && !fixture.app.feedbackSheetOpen)
        #expect(fixture.app.feedbackBusy == nil, "the sheet draws no overlay of its own")
        let overlay = try #require(fixture.app.busy, "the screens draw it")
        #expect(overlay.cancel != nil, "and its Cancel works")
        overlay.cancel?.action()
        gate.release()
        #expect(await eventually { fixture.app.busy == nil })
        #expect(!fixture.app.busyOverSheet && sheet.form.attachments.isEmpty)
    }

    // MARK: From Home

    /// Home's toolbar menu opens it, where no virtual machine runs.
    @Test func fromHomeThereIsNoBugReportAndNoScreenshotAndTheRestWorks() throws {
        let fixture = fixture(phase: .home)
        let sheet = fixture.sheet()
        #expect(!sheet.state.running && sheet.state.showsHowToReportBug)
        sheet.createBugReport()
        #expect(fixture.app.busy == nil && !fixture.app.busyOverSheet)
        sheet.takeScreenshot()
        #expect(sheet.form.attachments.isEmpty && sheet.failure == nil)
        #expect(!sheet.state.canMakeBugReport && !sheet.state.canTakeScreenshot)
        sheet.form.problem = "An idea"
        sheet.form.details = "Details"
        #expect(sheet.state.canSend && sheet.state.canAddMedia)
        sheet.sendAnyway()
        let request = try #require(fixture.composer.request)
        #expect(request.body.contains("Running: no"))
        sheet.close()
    }

    // MARK: Screenshot

    @Test func aScreenshotIsAPNGOfTheDisplayAtItsOwnPixels() async throws {
        let fixture = fixture(screen: Self.picture(width: 120, height: 200))
        let sheet = fixture.sheet()
        sheet.takeScreenshot()
        #expect(await eventually { sheet.form.attachments.items.first?.kind == .screenshot })
        let shot = try #require(sheet.form.attachments.items.first)
        #expect(shot.pixels == SendFeedbackPixels(width: 120, height: 200))
        #expect(shot.url.lastPathComponent == "screenshot.png" && shot.mimeType == "image/png")
        let data = try Data(contentsOf: shot.url)
        #expect(Array(data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        #expect(UInt64(data.count) == shot.bytes)
        #expect(await eventually { sheet.thumbnails[shot.id] != nil })
        #expect(!sheet.state.takingScreenshot)
        sheet.close()
    }

    @Test func aDisplayThatIsNotThereGivesAnAlertAndNoRow() {
        let fixture = fixture(screen: nil)
        let sheet = fixture.sheet()
        sheet.takeScreenshot()
        #expect(sheet.failure?.title == "Screenshot not taken")
        #expect(sheet.form.attachments.isEmpty && !sheet.state.takingScreenshot)
        sheet.close()
    }

    // MARK: Photos and videos

    private func pickedPhoto(in fixture: Fixture, named name: String = "IMG_0001.png") throws -> SendFeedbackPickedFile {
        let folder = fixture.staging.incoming.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try #require(Self.picture(width: 300, height: 200).pngData()).write(to: url)
        return SendFeedbackPickedFile(url: url, isVideo: false)
    }

    @Test func aPickedPhotoBecomesARowWithItsPictureAndSizeAndCanBeRemoved() async throws {
        let fixture = fixture()
        let sheet = fixture.sheet()
        let picked = try pickedPhoto(in: fixture)
        await sheet.importMedia([picked])
        let photo = try #require(sheet.form.attachments.items.first)
        #expect(photo.kind == .photo && photo.pixels == SendFeedbackPixels(width: 300, height: 200))
        #expect(photo.url.lastPathComponent == "photo.png" && photo.bytes > 0)
        #expect(sheet.thumbnails[photo.id] != nil)
        #expect(!FileManager.default.fileExists(atPath: picked.url.path), "the picker's copy moved")
        #expect(!FileManager.default.fileExists(atPath: picked.url.deletingLastPathComponent().path))
        #expect(!sheet.state.importingMedia)
        sheet.remove(photo)
        #expect(sheet.form.attachments.isEmpty && sheet.thumbnails.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: photo.url.path))
        sheet.close()
    }

    @Test func aFileThePickerLeftThatCannotBeReadIsReportedAndTheRestIsKept() async throws {
        let fixture = fixture()
        let sheet = fixture.sheet()
        let good = try pickedPhoto(in: fixture)
        let missing = SendFeedbackPickedFile(
            url: fixture.staging.incoming.appendingPathComponent("gone/none.jpg"), isVideo: false)
        await sheet.importMedia([missing, good])
        #expect(sheet.form.attachments.count == 1)
        #expect(sheet.failure?.title == "One item wasn\u{2019}t added")
        sheet.close()
    }

    @Test func theImportingStateBeginsBeforeTheFirstLoadAndSendWaitsForIt() async throws {
        let fixture = fixture()
        let sheet = fixture.sheet()
        sheet.form.problem = "Photos"
        sheet.form.details = "Details"
        let good = try pickedPhoto(in: fixture)
        let started = Gate()
        let gate = Gate()
        let loaders: [SendFeedbackModel.MediaLoader] = [
            {
                started.release()
                // The load (an iCloud video coming down) lasts.
                while !gate.isOpen { try? await Task.sleep(for: .milliseconds(5)) }
                return good
            }
        ]
        let importing = Task { await sheet.importMedia(loading: loaders) }
        #expect(await eventually { started.isOpen })
        #expect(sheet.state.importingMedia, "the state began before the file was there")
        #expect(!sheet.state.canSend && !sheet.state.canAddMedia && !sheet.state.canMakeBugReport)
        sheet.sendAnyway()
        #expect(fixture.composer.request == nil, "Send waits for the files it will carry")
        gate.release()
        await importing.value
        #expect(!sheet.state.importingMedia && sheet.state.canSend && sheet.form.attachments.count == 1)
        sheet.sendAnyway()
        #expect(fixture.composer.request?.attachments.count == 1)
        sheet.close()
    }

    @Test func anItemThatDoesNotLoadCountsAsNotAddedAndIsReported() async throws {
        let fixture = fixture()
        let sheet = fixture.sheet()
        let good = try pickedPhoto(in: fixture)
        let several: [SendFeedbackModel.MediaLoader] = [{ nil }, { good }, { nil }]
        await sheet.importMedia(loading: several)
        #expect(sheet.form.attachments.count == 1 && !sheet.state.importingMedia)
        #expect(sheet.failure?.title == "2 items weren\u{2019}t added")
        #expect(sheet.failure?.message.hasPrefix("They couldn\u{2019}t be copied. ") == true)
        sheet.failure = nil
        let one: [SendFeedbackModel.MediaLoader] = [{ nil }]
        await sheet.importMedia(loading: one)
        #expect(sheet.failure?.title == "One item wasn\u{2019}t added")
        #expect(sheet.failure?.message.hasPrefix("It couldn\u{2019}t be copied. ") == true)
        #expect(!sheet.state.importingMedia)
        sheet.close()
    }

    // MARK: The total

    @Test func theTotalWarnsAboveTwentyMiBAndSendStaysAvailable() async throws {
        let fixture = fixture()
        let sheet = fixture.sheet()
        sheet.form.problem = "Large"
        sheet.form.details = "Details"
        let big = try fixture.staging.makeFolder().reserve("video.mov")
        try Data(count: 1).write(to: big)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 21 << 20)
        try handle.close()
        sheet.form.attachments.add(SendFeedbackAttachment(kind: .video, url: big, bytes: 21 << 20))
        #expect(sheet.state.attachments.exceedsWarningSize)
        #expect(sheet.state.canSend, "the composer applies its own rules")
        try? FileManager.default.removeItem(at: big.deletingLastPathComponent())
    }

    // MARK: The mail

    @Test func sendHandsTheComposerTheSubjectTheBodyAndTheFilesAndSendsNothingItself() async throws {
        let fixture = fixture()
        let file = try report(in: fixture)
        fixture.driver.bugReport = { _ in file }
        let sheet = fixture.sheet()
        sheet.form.problem = "  Game freezes\nafter the intro "
        sheet.form.details = "It stops every time."
        sheet.createBugReport()
        #expect(await eventually { sheet.form.attachments.bugReport != nil })
        sheet.sendAnyway()
        let request = try #require(fixture.composer.request)
        #expect(request.address == "feedback@example.com")
        #expect(request.subject == "Andarium feedback: Game freezes after the intro")
        #expect(request.body.hasPrefix("It stops every time.\n\n--\nApp: Andarium "))
        let cores = try #require(fixture.app.guest?.cores)
        #expect(request.body.contains("Virtual machine: \(Formats.vcpus(cores)), "))
        #expect(request.body.contains("Android: r2\n"))
        #expect(request.body.contains("Running: yes, for 2 min\n"))
        #expect(request.body.contains("Free space: \(Formats.size(bytes: 41_000_000_000))\n"))
        #expect(request.attachments.map(\.kind) == [.bugReport])
        // Only the information the block has fields for: no name, no identifier, no path.
        let keys = request.body.components(separatedBy: "\n--\n")[1].split(separator: "\n").compactMap {
            $0.split(separator: ":").first.map(String.init)
        }
        #expect(keys == [
            "App", "Device", "iOS", "Language", "Virtual machine", "Android", "Running", "Free space", "Thermal state",
            "Frame rate limit when hot",
        ])
        #expect(!request.body.contains(NSHomeDirectory()))
        sheet.close()
    }

    /// The names the composer is handed for what the app makes: fixed English ASCII, the same under every
    /// interface language (the suite is also run with each of en, zh-Hans, zh-Hant and ja as the test language).
    @Test func theComposerIsHandedFixedEnglishNamesForTheBugReportAndTheScreenshot() async throws {
        let fixture = fixture()
        let file = try report(in: fixture)
        fixture.driver.bugReport = { _ in file }
        let sheet = fixture.sheet()
        sheet.form.problem = "x"
        sheet.form.details = "Details"
        sheet.createBugReport()
        #expect(await eventually { sheet.form.attachments.bugReport != nil })
        sheet.takeScreenshot()
        #expect(await eventually { sheet.form.attachments.items.contains { $0.kind == .screenshot } })
        sheet.sendAnyway()
        let request = try #require(fixture.composer.request)
        // `bugreport-yyyyMMdd-HHmmss.zip` and `screenshot-yyyyMMdd-HHmmss.png`: fixed English words, a fixed
        // pattern of ASCII digits, whatever the interface language or the device's calendar and digits.
        let names = request.attachments.map(\.fileName)
        #expect(names.count == 2)
        #expect(names[0].wholeMatch(of: /bugreport-[0-9]{8}-[0-9]{6}\.zip/) != nil)
        #expect(names[1].wholeMatch(of: /screenshot-[0-9]{8}-[0-9]{6}\.png/) != nil)
        #expect(request.attachments.map(\.mimeType) == ["application/zip", "image/png"])
        #expect(names.allSatisfy { $0.allSatisfy(\.isASCII) })
        sheet.close()
    }

    @Test func sendNeedsAProblemDetailsAndAnAvailableComposer() {
        let fixture = fixture()
        let sheet = fixture.sheet()
        sheet.sendAnyway()
        #expect(fixture.composer.request == nil && sheet.incomplete == .both && sheet.failure == nil)
        sheet.incomplete = nil
        sheet.form.problem = "x"
        sheet.sendAnyway()
        #expect(fixture.composer.request == nil && sheet.incomplete == .details)
        sheet.incomplete = nil
        sheet.form.problem = " \n "
        sheet.form.details = "y"
        sheet.sendAnyway()
        #expect(fixture.composer.request == nil && sheet.incomplete == .problem)
        sheet.incomplete = nil
        sheet.form.problem = "x"
        fixture.app.feedbackServices.presentMail = { _, _ in false }
        sheet.sendAnyway()
        #expect(sheet.incomplete == nil && sheet.failure?.title == "Mail not opened")
        sheet.close()
    }

    @Test func aMissingFieldAskedAboutDoesNotTouchTheDraftOrTheFiles() async throws {
        let fixture = fixture()
        let sheet = fixture.sheet()
        let picked = try pickedPhoto(in: fixture)
        await sheet.importMedia([picked])
        sheet.form.problem = "x"
        let before = sheet.form
        sheet.sendAnyway()
        #expect(sheet.incomplete == .details && sheet.form == before && fixture.composer.request == nil)
        sheet.close()
    }

    @Test func withoutMailNothingIsAskedAboutEither() {
        let fixture = fixture(mail: false)
        let sheet = fixture.sheet()
        sheet.sendAnyway()
        #expect(sheet.incomplete == nil && fixture.composer.request == nil && sheet.failure == nil)
        sheet.close()
    }

    @Test func savedAndCancelledLeaveTheDraftAndAFailureIsTheSystemsWords() throws {
        let fixture = fixture()
        let sheet = fixture.sheet()
        sheet.form.problem = "x"
        sheet.form.details = "Details"
        sheet.sendAnyway()
        fixture.composer.leave(.cancelled)
        #expect(!sheet.sent && sheet.form.problem == "x" && sheet.failure == nil)
        sheet.sendAnyway()
        fixture.composer.leave(.saved)
        #expect(!sheet.sent && sheet.form.problem == "x" && sheet.failure == nil)
        sheet.sendAnyway()
        fixture.composer.leave(.failed("The operation couldn\u{2019}t be completed."))
        #expect(sheet.failure?.message == "The operation couldn\u{2019}t be completed.")
        #expect(!sheet.sent && sheet.form.problem == "x")
        sheet.close()
    }

    // MARK: The sent notice

    /// A sheet with a problem, details, a photo and a screenshot, ready to send.
    private func filledSheet(in fixture: Fixture) async throws -> SendFeedbackModel {
        let sheet = fixture.sheet()
        sheet.form.problem = "Game freezes"
        sheet.form.details = "The picture stops after the intro."
        await sheet.importMedia([try pickedPhoto(in: fixture)])
        sheet.takeScreenshot()
        try #require(await eventually { sheet.form.attachments.count == 2 })
        return sheet
    }

    @Test func sentLeavesTheSheetAsItWasAndTheFilesStagedUntilItCloses() async throws {
        let fixture = fixture()
        let sheet = try await filledSheet(in: fixture)
        let staged = sheet.form.attachments.items.map(\.url)
        let before = sheet.form
        let pictures = Set(sheet.thumbnails.keys)
        #expect(!pictures.isEmpty)
        sheet.sendAnyway()
        fixture.composer.leave(.sent)
        #expect(sheet.sent && !sheet.closed)
        // What was sent is still the sheet's: the text, the list, the pictures and the files behind them.
        var expected = before
        expected.sent = true
        #expect(sheet.form == expected, "the form under the notice is as it was sent")
        #expect(Set(sheet.thumbnails.keys) == pictures)
        #expect(staged.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } && sheet.folder.exists)
        // Nothing under the notice acts.
        let state = sheet.state
        #expect(!state.fieldsEnabled && !state.canSend && !state.readyToSend && !state.canMakeBugReport
                && !state.canTakeScreenshot && !state.canAddMedia && !state.canAddFiles)
        sheet.sendAnyway()
        sheet.takeScreenshot()
        sheet.createBugReport()
        sheet.pickFiles()
        #expect(fixture.composer.opened == 1 && sheet.form.attachments.count == 2 && fixture.app.busy == nil)
        #expect(sheet.confirmingDiscard == false)
        // Closing ends the draft: no file, no pictures, no text.
        sheet.close()
        #expect(sheet.closed && !sheet.folder.exists)
        #expect(staged.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(!FileManager.default.fileExists(atPath: fixture.staging.incoming.path))
        #expect(sheet.form.problem.isEmpty && sheet.form.details.isEmpty && sheet.form.attachments.isEmpty)
        #expect(sheet.thumbnails.isEmpty)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    @Test func theNextSheetAfterASendIsEmpty() async throws {
        let fixture = fixture()
        let sheet = try await filledSheet(in: fixture)
        sheet.sendAnyway()
        fixture.composer.leave(.sent)
        sheet.close()
        let next = fixture.sheet()
        #expect(next.form.problem.isEmpty && next.form.details.isEmpty && next.form.attachments.isEmpty)
        #expect(!next.sent && next.thumbnails.isEmpty && !next.state.hasContent && next.state.canSend)
        next.close()
        try? FileManager.default.removeItem(at: fixture.root)
    }

    @Test func theFilesAreLetGoOnceAndNoLaterLookAtTheFolderRemovesAnything() async throws {
        let fixture = fixture()
        let sheet = try await filledSheet(in: fixture)
        sheet.sendAnyway()
        fixture.composer.leave(.sent)
        sheet.close()
        // What a second removal would take is not there to take: a file that appears after the close stays.
        let late = sheet.folder.url.appendingPathComponent("late.txt")
        try FileManager.default.createDirectory(at: sheet.folder.url, withIntermediateDirectories: true)
        try Data([1]).write(to: late)
        sheet.close()
        sheet.applicationEnteredBackground()
        #expect(FileManager.default.fileExists(atPath: late.path), "the files were let go once")
        try? FileManager.default.removeItem(at: fixture.root)
    }

    @Test func theInformationBlockUnderTheNoticeIsTheOneTheMailWentWith() async throws {
        let fixture = fixture()
        let sheet = fixture.sheet()
        sheet.form.problem = "x"
        sheet.form.details = "Details"
        #expect(sheet.information.runningSeconds == 125)
        sheet.sendAnyway()
        let body = try #require(fixture.composer.request).body
        fixture.app.feedbackServices.runningSeconds = { _ in 999 }
        #expect(sheet.information.runningSeconds == 999, "until the mail is sent the block is the app's, live")
        fixture.composer.leave(.sent)
        #expect(sheet.information.runningSeconds == 125, "the block under the notice is the one that was sent")
        #expect(body.contains(sheet.information.text), "the mail carried this block")
        sheet.close()
    }

    @Test func savedCancelledAndFailedKeepTheDraftTheFilesAndALiveSheet() async throws {
        for result: SendFeedbackMailResult in [.saved, .cancelled, .failed("The operation couldn\u{2019}t be completed.")] {
            let fixture = fixture()
            let sheet = try await filledSheet(in: fixture)
            let staged = sheet.form.attachments.items.map(\.url)
            let before = sheet.form
            sheet.sendAnyway()
            fixture.composer.leave(result)
            #expect(!sheet.sent && sheet.form == before && !sheet.closed, "\(result)")
            #expect(staged.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "\(result)")
            #expect(sheet.state.canSend && sheet.state.fieldsEnabled && sheet.state.readyToSend, "\(result)")
            // The block is the app's again, and a second try opens the composer again.
            fixture.app.feedbackServices.runningSeconds = { _ in 999 }
            #expect(sheet.information.runningSeconds == 999, "\(result)")
            sheet.sendAnyway()
            #expect(fixture.composer.opened == 2, "\(result)")
            // In the background a draft that was not sent keeps its files.
            sheet.applicationEnteredBackground()
            #expect(staged.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "\(result)")
            sheet.close()
            #expect(staged.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "\(result)")
            try? FileManager.default.removeItem(at: fixture.root)
        }
    }

    @Test func aSendThatLeavesTheForegroundDropsItsFilesAndKeepsWhatTheRowsShow() async throws {
        let fixture = fixture()
        let sheet = try await filledSheet(in: fixture)
        let staged = sheet.form.attachments.items.map(\.url)
        let before = sheet.form
        sheet.sendAnyway()
        fixture.composer.leave(.sent)
        // The application goes to the background and may be ended there: no staged file is left.
        sheet.applicationEnteredBackground()
        #expect(staged.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } && !sheet.folder.exists)
        var expected = before
        expected.sent = true
        #expect(sheet.form == expected && !sheet.thumbnails.isEmpty, "the notice is still over the whole sheet")
        sheet.close()
        try? FileManager.default.removeItem(at: fixture.root)
    }

    @Test func aSheetLetGoAfterASendLeavesNoFolder() async throws {
        let fixture = fixture()
        var url: URL?
        do {
            let sheet = try await filledSheet(in: fixture)
            url = sheet.folder.url
            sheet.sendAnyway()
            fixture.composer.leave(.sent)
            #expect(FileManager.default.fileExists(atPath: try #require(url).path))
        }
        #expect(await eventually { !FileManager.default.fileExists(atPath: url?.path ?? "/") })
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private func nodes(in node: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 64 else { return [] }
        var children = (node.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        if let view = node as? UIView { children += view.subviews }
        return [node] + children.flatMap { nodes(in: $0, depth: depth + 1) }
    }

    /// The sheet as a person meets it: presented over the screen by its own presenter, sent, and left alone
    /// for longer than the old timer (1.8 s). The notice stays over the sheet, which keeps what was sent; a
    /// swipe down and the toolbar's close button do nothing; the notice's own button closes both, and the
    /// next sheet is empty.
    @Test func theNoticeStaysOverTheSheetUntilItsButtonClosesThemBothAndTheNextSheetIsEmpty() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let photo = try pickedPhoto(in: fixture)
        var first: SendFeedbackModel?
        fixture.app.feedbackServices.previewPrepare = { model in
            first = model
            model.form.problem = "Game freezes"
            model.form.details = "The picture stops after the intro."
            await model.importMedia([photo])
            model.sendAnyway()
            fixture.composer.leave(.sent)
        }
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let root = AndariumHostingController(
            rootView: Color.clear.sendFeedbackSheet(fixture.app).environment(fixture.app), model: fixture.app)
        lease.window.rootViewController = root
        root.view.layoutIfNeeded()
        fixture.app.feedbackSheetOpen = true
        let shown = await eventually { first?.sent == true && root.presentedViewController?.view.window != nil }
        try #require(shown, "the sheet was not sent; is ApplicationAccessibilityEnabled on?")
        let sheet = try #require(root.presentedViewController)
        let model = try #require(first)
        let staged = model.form.attachments.items.map(\.url)
        #expect(sheet.isModalInPresentation, "a swipe down is not taken as a dismissal")
        // Longer than the old timer.
        try await Task.sleep(for: .seconds(3.5))
        #expect(root.presentedViewController === sheet && !sheet.isBeingDismissed, "the sheet closed by itself")
        #expect(fixture.app.feedbackSheetOpen && !model.closed)
        #expect(model.form.problem == "Game freezes" && model.form.details == "The picture stops after the intro.")
        #expect(model.form.attachments.count == 1)
        #expect(staged.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "the files wait for the close")
        // The toolbar's close button does nothing, and no question about discarding comes up.
        let bar = ToolbarProbe.barItems(under: root)
        #expect(!bar.isEmpty, "the sheet's bar holds the close button")
        #expect(bar.allSatisfy { !$0.isEnabled }, "the close button is off under the notice: \(ToolbarProbe.describe(under: root))")
        model.confirmingDiscard = false
        #expect(sheet.presentedViewController == nil)
        // The notice's button closes the notice and the sheet together.
        let done = nodes(in: sheet.view).first { $0.accessibilityLabel == "Done" && $0.accessibilityTraits.contains(.button) }
        try #require(done != nil, "the notice has no Done button")
        #expect(done?.accessibilityActivate() == true)
        #expect(await eventually { root.presentedViewController == nil }, "Done did not close the sheet")
        #expect(await eventually { model.closed })
        #expect(!fixture.app.feedbackSheetOpen)
        #expect(staged.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } && !model.folder.exists)
        #expect(model.form.problem.isEmpty && model.form.attachments.isEmpty)
        // The next sheet is empty.
        var second: SendFeedbackModel?
        fixture.app.feedbackServices.previewPrepare = { second = $0 }
        fixture.app.feedbackSheetOpen = true
        try #require(await eventually { second != nil && root.presentedViewController?.view.window != nil })
        #expect(second?.form.problem.isEmpty == true && second?.form.details.isEmpty == true)
        #expect(second?.form.attachments.isEmpty == true && second?.sent == false)
        fixture.app.feedbackSheetOpen = false
        #expect(await eventually { root.presentedViewController == nil })
        root.dismiss(animated: false)
    }

    // MARK: Mail not available

    @Test func withoutMailNothingCanBeEditedOrAttachedUntilAnAccountComesBack() async throws {
        let fixture = fixture(mail: false)
        let sheet = fixture.sheet()
        #expect(!sheet.state.mailAvailable)
        #expect(!sheet.state.fieldsEnabled && !sheet.state.canMakeBugReport && !sheet.state.canTakeScreenshot
                && !sheet.state.canAddMedia && !sheet.state.canSend)
        sheet.createBugReport()
        sheet.takeScreenshot()
        #expect(fixture.app.busy == nil && sheet.form.attachments.isEmpty)
        sheet.form.problem = "x"
        sheet.form.details = "Details"
        sheet.sendAnyway()
        #expect(fixture.composer.request == nil)
        // The person adds an account in iOS Settings and comes back.
        fixture.app.feedbackServices.canSendMail = { true }
        sheet.refresh()
        #expect(sheet.state.mailAvailable && sheet.state.canSend && sheet.state.canMakeBugReport)
        sheet.close()
    }

    // MARK: Closing

    @Test func closingRemovesEveryStagedFileAndWhatThePickerLeft() async throws {
        let fixture = fixture()
        let sheet = fixture.sheet()
        sheet.form.problem = "draft"
        sheet.form.details = "Details"
        await sheet.importMedia([try pickedPhoto(in: fixture)])
        sheet.takeScreenshot()
        #expect(await eventually { sheet.form.attachments.count == 2 })
        let left = fixture.staging.incoming.appendingPathComponent("left", isDirectory: true)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try Data([1]).write(to: left.appendingPathComponent("v.mov"))
        #expect(sheet.folder.exists && sheet.state.hasContent)
        sheet.close()
        #expect(!sheet.folder.exists)
        #expect(!FileManager.default.fileExists(atPath: fixture.staging.incoming.path))
        #expect(sheet.form.attachments.isEmpty && sheet.thumbnails.isEmpty)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    @Test func aSheetThatIsLetGoRemovesItsFolderToo() async throws {
        let fixture = fixture()
        var url: URL?
        do {
            let sheet = fixture.sheet()
            await sheet.importMedia([try pickedPhoto(in: fixture)])
            url = sheet.folder.url
            #expect(FileManager.default.fileExists(atPath: try #require(url).path))
        }
        #expect(await eventually { !FileManager.default.fileExists(atPath: url?.path ?? "/") })
    }
}

#endif
