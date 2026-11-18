// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing

@testable import AndariumCore
@testable import AndariumFeedbackLogic

/// Send feedback's logic: the mail, the information block, the attachments, the
/// enabling of every control and the staging folder. The package compiles the
/// application's own sources for this, with Send feedback's condition set.
struct SendFeedbackTests {
    private func information(
        machine: SendFeedbackInformation.VirtualMachine? = .init(
            vcpus: 6, memoryMiB: 2560, display: "1206 x 2622 px, 480 dpi", graphicsMiB: 1157),
        running: Int? = 2520
    ) -> SendFeedbackInformation {
        SendFeedbackInformation(
            appVersion: "1.0", build: "9", configuration: "AppStore", deviceModel: "iPhone18,1",
            systemVersion: "27.2", language: "en-US", virtualMachine: machine, androidRelease: "r20",
            runningSeconds: running, freeSpaceBytes: 44_700_000_000, thermalState: "nominal")
    }

    private func attachment(_ kind: SendFeedbackAttachment.Kind, bytes: UInt64, name: String = "file.bin")
        -> SendFeedbackAttachment
    {
        SendFeedbackAttachment(kind: kind, url: URL(fileURLWithPath: "/staged/\(name)"), bytes: bytes)
    }

    @Test func aStartThatIsStillBootingSaysWhereItIs() {
        var info = information(running: nil)
        info.boot = .init(step: "Startup", seconds: 197, restarts: 0)
        #expect(info.lines.contains("Boot: not finished, at Startup after 3 min"))
        info.boot = .init(step: "Linux kernel", seconds: 2_700, restarts: 3)
        #expect(info.lines.contains("Boot: not finished, at Linux kernel after 45 min, restarted 3 times"))
        info.boot = .init(step: "Storage", seconds: 90, restarts: 1)
        #expect(info.lines.contains("Boot: not finished, at Storage after 1 min, restarted 1 time"))
        // Not booting: no line.
        #expect(!information().lines.contains { $0.hasPrefix("Boot:") })
    }

    // MARK: The mail

    @Test func theSubjectIsThePrefixAndTheProblemOnOneLine() {
        #expect(SendFeedbackMail.subject(problem: "Game freezes") == "Andarium feedback: Game freezes")
        #expect(SendFeedbackMail.subject(problem: "  Game \n freezes\t after\n") == "Andarium feedback: Game freezes after")
    }

    @Test func theBodyIsTheDetailsASeparatorAndTheInformation() {
        let body = SendFeedbackMail.body(details: "  It stops.\nEvery time.  \n", information: information())
        #expect(body.hasPrefix("It stops.\nEvery time.\n\n--\nApp: Andarium 1.0 (9), AppStore\n"))
        #expect(body.hasSuffix("Thermal state: nominal\nFrame rate limit when hot: on\n"))
    }

    @Test func withoutDetailsTheBodyLeavesRoomToType() {
        let body = SendFeedbackMail.body(details: " \n ", information: information())
        #expect(body.hasPrefix("\n\n--\nApp: "))
    }

    @Test func anAddressNeedsALocalPartAndADottedDomain() {
        #expect(SendFeedbackMail.isWellFormed(address: "feedback@example.com"))
        #expect(SendFeedbackMail.isWellFormed(address: "a.b+c@mail.example.org"))
        #expect(SendFeedbackMail.isWellFormed(address: "a_b%c-d@x-y.example.org"))
        for bad in ["", "feedback", "feedback@", "@example.com", "a@b", "a@b.", "a@.com", "a b@example.com", "a@b@c.com"] {
            #expect(!SendFeedbackMail.isWellFormed(address: bad), "\(bad)")
        }
    }

    /// The same rules as the App Store bundle check's pattern
    /// (tests/tooling/andarium/test_check_app_store_bundle.py holds the other half).
    @Test func anAddressIsOneStrictShape() {
        let longLocal = String(repeating: "a", count: 65) + "@example.com"
        let longLabel = "a@" + String(repeating: "b", count: 64) + ".com"
        let longAddress = "a@" + (0..<26).map { _ in String(repeating: "b", count: 9) }.joined(separator: ".") + ".com"
        #expect(SendFeedbackMail.isWellFormed(address: String(repeating: "a", count: 64) + "@example.com"))
        #expect(SendFeedbackMail.isWellFormed(address: "a@" + String(repeating: "b", count: 63) + ".com"))
        for bad in [
            "\"feedback@example.com\"", "\"a\"@example.com", "<feedback@example.com>",
            "Name <feedback@example.com>", "feedback@example.com;", "feedback@example.com,", "feedback@example.com>",
            "a..b@example.com", ".a@example.com", "a.@example.com", "-a@example.com", "a-@example.com",
            "a@-b.com", "a@b-.com", "a@b..com", "a@b.c", "a@b.c1", "a@b.123", "a@b_c.com", "a@b.com.",
            "a@example.com\n", " a@example.com", "a@example.com ", "a;b@example.com", "a(b)@example.com",
            "\u{00E9}@example.com", "a@\u{00E9}xample.com", "a@example.c\u{00F6}m",
            longLocal, longLabel, longAddress,
        ] {
            #expect(!SendFeedbackMail.isWellFormed(address: bad), "\(bad)")
        }
    }

    // MARK: The information block

    @Test func theInformationBlockNamesTheAppTheDeviceAndTheVirtualMachine() {
        #expect(information().lines == [
            "App: Andarium 1.0 (9), AppStore",
            "Device: iPhone18,1",
            "iOS: 27.2",
            "Language: en-US",
            "Virtual machine: 6 vCPUs, 2.5 GiB memory, display 1206 x 2622 px, 480 dpi, graphics memory about 1.13 GiB",
            "Android: r20",
            "Running: yes, for 42 min",
            "Free space: 41.6 GiB",
            "Thermal state: nominal",
            "Frame rate limit when hot: on",
        ])
    }

    @Test func theInformationBlockSaysInFixedEnglishWhetherTheFrameRateLimitIsOff() {
        var off = information()
        off.heatLimitOn = false
        #expect(off.lines.suffix(2) == ["Thermal state: nominal", "Frame rate limit when hot: off"])
        #expect(off.text.hasSuffix("Frame rate limit when hot: off"))
    }

    @Test func beforeAVirtualMachineExistsOrRunsTheBlockSaysSo() {
        let none = information(machine: nil, running: nil)
        #expect(none.lines.contains("Virtual machine: not created"))
        #expect(none.lines.contains("Running: no"))
        let stopped = information(running: nil)
        #expect(stopped.lines.contains("Running: no"))
        #expect(stopped.lines.contains { $0.hasPrefix("Virtual machine: 6 vCPUs") })
        let withoutEstimate = information(
            machine: .init(vcpus: 1, memoryMiB: 1536, display: "720 x 1560 px, 320 dpi", graphicsMiB: nil))
        #expect(withoutEstimate.lines.contains("Virtual machine: 1 vCPU, 1.5 GiB memory, display 720 x 1560 px, 320 dpi"))
    }

    /// The device line is never empty, and an iPad app on a Mac does not pass
    /// for a phone: what is known is said where the model is not.
    @Test func theDeviceLineSaysWhatIsKnown() {
        var info = information()
        #expect(info.deviceText == "iPhone18,1" && info.lines.contains("Device: iPhone18,1"))
        info.deviceModel = "Mac15,3"
        info.runsOnMac = true
        #expect(info.deviceText == "Mac15,3, iPad app on a Mac")
        #expect(info.lines.contains("Device: Mac15,3, iPad app on a Mac"))
        for unreadable in [nil, "", "  \n"] {
            info.deviceModel = unreadable
            #expect(info.deviceText == "a Mac, iPad app", "\(String(describing: unreadable)) on a Mac")
            #expect(info.lines.contains("Device: a Mac, iPad app"))
        }
        info.runsOnMac = false
        for unreadable in [nil, "", " "] {
            info.deviceModel = unreadable
            #expect(info.deviceText == "unknown")
            #expect(info.lines.contains("Device: unknown"))
        }
        #expect(info.lines.count == 10 && !info.lines.contains("Device: "))
        // The frame rate limit's line closes the block, in both states.
        #expect(info.lines.last == "Frame rate limit when hot: on")
        info.heatLimitOn = false
        #expect(info.lines.count == 10 && info.lines.last == "Frame rate limit when hot: off")
    }

    @Test func aRunningTimeIsInTheLargestUnitThatFits() {
        #expect(SendFeedbackInformation.duration(0) == "0 s")
        #expect(SendFeedbackInformation.duration(59) == "59 s")
        #expect(SendFeedbackInformation.duration(60) == "1 min")
        #expect(SendFeedbackInformation.duration(3599) == "59 min")
        #expect(SendFeedbackInformation.duration(3600) == "1 h 0 min")
        #expect(SendFeedbackInformation.duration(4320) == "1 h 12 min")
        #expect(SendFeedbackInformation.duration(-5) == "0 s")
    }

    @Test func aValueWithALineBreakStaysOneLine() {
        var info = information()
        info.language = "en\nUS"
        info.androidRelease = "r20\r\nextra"
        #expect(info.lines.count == 10)
        #expect(info.lines.allSatisfy { !$0.contains("\n") && !$0.contains("\r") })
        #expect(info.lines.last == "Frame rate limit when hot: on")
        info.heatLimitOn = false
        #expect(info.lines.count == 10 && info.lines.last == "Frame rate limit when hot: off")
    }

    @Test func theBlockHoldsNothingThatSinglesOutTheDeviceOrThePerson() {
        // The type has no field for a name, an identifier, an account or a
        // path; the text a normal value gives has no path and no address.
        let text = information().text
        #expect(!text.contains("/"))
        #expect(!text.contains("@"))
        #expect(!text.lowercased().contains("name"))
        #expect(!text.lowercased().contains("account"))
    }

    // MARK: Attachments

    @Test func theTotalIsTheSumOfTheSizesAndTheWarningStartsAboveTwentyMiB() {
        var set = SendFeedbackAttachments()
        #expect(set.isEmpty && set.totalBytes == 0 && !set.exceedsWarningSize)
        set.add(attachment(.bugReport, bytes: 8 << 20))
        set.add(attachment(.screenshot, bytes: 2 << 20))
        set.add(attachment(.video, bytes: 10 << 20))
        #expect(set.count == 3 && set.totalBytes == 20 << 20)
        #expect(!set.exceedsWarningSize, "exactly 20 MiB does not warn")
        set.add(attachment(.photo, bytes: 1))
        #expect(set.exceedsWarningSize)
    }

    @Test func removingAFileGivesItBackAndLowersTheTotal() {
        var set = SendFeedbackAttachments()
        let photo = attachment(.photo, bytes: 3 << 20, name: "photo.bin")
        set.add(attachment(.screenshot, bytes: 1 << 20))
        set.add(photo)
        #expect(set.remove(photo.id) == photo)
        #expect(set.totalBytes == 1 << 20)
        #expect(set.remove(photo.id) == nil)
    }

    @Test func aBugReportGoesFirstAndReplacesTheOneThatIsThere() {
        var set = SendFeedbackAttachments()
        set.add(attachment(.photo, bytes: 5))
        let first = attachment(.bugReport, bytes: 100, name: "a.zip")
        #expect(set.add(first) == nil)
        #expect(set.items.map(\.kind) == [.bugReport, .photo])
        let second = attachment(.bugReport, bytes: 200, name: "b.zip")
        #expect(set.add(second) == first)
        #expect(set.items.map(\.kind) == [.bugReport, .photo])
        #expect(set.bugReport == second)
    }

    private func made(_ kind: SendFeedbackAttachment.Kind, _ name: String, at date: Date) -> SendFeedbackAttachment {
        SendFeedbackAttachment(kind: kind, url: URL(fileURLWithPath: "/staged/\(name)"), bytes: 1, madeAt: date)
    }

    /// The mail names what the app makes itself with fixed English words and the moment it was made, whatever
    /// the file is called where it is staged (the guest names its own report; a name could come from a translated
    /// word or a date); the person's own files keep theirs.
    @Test func filesTheAppMakesHaveFixedEnglishDatedMailNamesAndThePersonsFilesKeepTheirs() {
        let moment = Date(timeIntervalSince1970: 1_794_626_712)
        let later = moment.addingTimeInterval(5)
        let stamp = SendFeedbackNames.stamp(moment)
        let laterStamp = SendFeedbackNames.stamp(later)
        var set = SendFeedbackAttachments()
        set.add(attachment(.photo, bytes: 1, name: "IMG_0042.JPG"))
        set.add(made(.bugReport, "bugreport-lineage-2026-11-03-10-00-00.zip", at: moment))
        set.add(made(.screenshot, "\u{5C4F}\u{5E55}\u{622A}\u{56FE} 2026-11-14.png", at: moment))
        set.add(made(.screenshot, "\u{30B9}\u{30AF}\u{30EA}\u{30FC}\u{30F3}.png", at: later))
        #expect(set.items.map(\.fileName) == [
            "bugreport-\(stamp).zip", "IMG_0042.JPG", "screenshot-\(stamp).png", "screenshot-\(laterStamp).png",
        ])
        let generated = set.items.filter { $0.kind == .bugReport || $0.kind == .screenshot }
        #expect(generated.allSatisfy { $0.fileName.allSatisfy(\.isASCII) })
        #expect(generated.map(\.mimeType) == ["application/zip", "image/png", "image/png"])
    }

    @Test func aGeneratedFileTakesTheNumberWhenAnotherAttachmentHasItsName() {
        let moment = Date(timeIntervalSince1970: 1_794_626_712)
        var set = SendFeedbackAttachments()
        set.add(attachment(.file, bytes: 1, name: "SCREENSHOT-\(SendFeedbackNames.stamp(moment)).PNG"))
        set.add(made(.screenshot, "anything.png", at: moment))
        set.add(made(.screenshot, "other.png", at: moment))
        #expect(set.items.map(\.fileName) == [
            "SCREENSHOT-\(SendFeedbackNames.stamp(moment)).PNG",
            "screenshot-\(SendFeedbackNames.stamp(moment))-2.png", "screenshot-\(SendFeedbackNames.stamp(moment))-3.png",
        ])
    }

    @Test func theStampIsOnePatternInAsciiOnTheGregorianCalendarInTheGivenZone() throws {
        let moment = Date(timeIntervalSince1970: 1_794_626_712)  // 2026-11-14 03:25:12 UTC
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let bangkok = try #require(TimeZone(identifier: "Asia/Bangkok"))
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        #expect(SendFeedbackNames.stamp(moment, in: utc) == "20261114-032512")
        #expect(SendFeedbackNames.stamp(moment, in: bangkok) == "20261114-102512")
        #expect(SendFeedbackNames.stamp(moment, in: newYork) == "20261113-222512")
        #expect(SendFeedbackNames.stamp(Date(timeIntervalSince1970: 0), in: utc) == "19700101-000000")
        // The shape is the same wherever the device is set: eight digits, a dash, six digits.
        let shape = SendFeedbackNames.stamp(moment)
        #expect(shape.count == 15 && shape.allSatisfy(\.isASCII))
        #expect(shape.enumerated().allSatisfy { $0.offset == 8 ? $0.element == "-" : $0.element.isNumber })
    }

    /// What a formatter that follows the device's settings would write for the same moment: not ASCII digits,
    /// and not the Gregorian year. The stamp consults no setting, so a device set this way (a Buddhist calendar
    /// with Thai digits, Arabic-Indic digits on the Hijri calendar, Persian digits) gets the same name.
    @Test func aDeviceSetToAnotherCalendarOrOtherDigitsStillGetsAnAsciiGregorianName() throws {
        let moment = Date(timeIntervalSince1970: 1_794_626_712)
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        for identifier in [
            "th_TH@calendar=buddhist;numbers=thai", "ar_SA@calendar=islamic-umalqura;numbers=arab",
            "fa_IR@calendar=persian;numbers=arabext", "ja_JP@calendar=japanese", "zh_Hans_CN@numbers=hanidec",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: identifier)
            formatter.timeZone = utc
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            #expect(formatter.string(from: moment) != "20261114-032512", "\(identifier) would have changed the name")
        }
        #expect(SendFeedbackNames.stamp(moment, in: utc) == "20261114-032512")
    }

    @Test func aFileHasItsMimeTypeFromItsExtension() {
        func mime(_ name: String) -> String { attachment(.photo, bytes: 1, name: name).mimeType }
        #expect(mime("a.png") == "image/png")
        #expect(mime("a.jpeg") == "image/jpeg")
        #expect(mime("a.mov") == "video/quicktime")
        #expect(mime("a.zip") == "application/zip")
        #expect(mime("a.unknownext") == "application/octet-stream")
    }

    // MARK: The form

    @Test func sendNeedsAProblemAndDetailsAndSaysWhichIsMissing() {
        var form = SendFeedbackForm(mailAvailable: true, running: true)
        #expect(form.canSend, "Send stays enabled, so that its tap can say what is missing")
        #expect(form.missing == .both)
        form.problem = "It froze"
        #expect(form.canSend && form.missing == .details)
        form.details = "I opened a game"
        #expect(form.canSend && form.missing == nil)
        form.problem = ""
        #expect(form.canSend && form.missing == .problem)
    }

    @Test func sendLooksReadyOnlyWhenATapWouldOpenTheMail() {
        var form = SendFeedbackForm(mailAvailable: true, running: true)
        #expect(form.canSend && !form.readyToSend, "dimmed, and its tap still says what is missing")
        form.problem = "It froze"
        #expect(!form.readyToSend)
        form.details = "  \n "
        #expect(!form.readyToSend, "white space is not details")
        form.details = "I opened a game"
        #expect(form.readyToSend)
        form.importingMedia = true
        #expect(!form.readyToSend)
        form.importingMedia = false
        form.mailAvailable = false
        #expect(!form.readyToSend)
    }

    @Test func whiteSpaceAndLineBreaksAreNotWords() {
        var form = SendFeedbackForm(mailAvailable: true, running: true)
        form.problem = "  \n \t"
        form.details = "\n\n   \r\n"
        #expect(form.missing == .both)
        form.problem = "It froze"
        #expect(form.missing == .details)
        form.problem = " \n "
        form.details = "I opened a game"
        #expect(form.missing == .problem)
        form.problem = "\u{00A0}\u{2003}"
        #expect(form.missing == .problem, "no-break and wide spaces are white space too")
    }

    @Test func filesAndTheStartLogAreNeitherAProblemNorDetails() {
        var form = SendFeedbackForm(mailAvailable: true, running: true)
        form.attachments.add(attachment(.bugReport, bytes: 10))
        form.attachments.add(attachment(.screenshot, bytes: 10))
        form.attachments.add(attachment(.file, bytes: 10))
        #expect(form.missing == .both)
        form.problem = "x"
        #expect(form.missing == .details)
    }

    @Test func theProblemLineIsFocusedFirstWhenItIsEmpty() {
        #expect(SendFeedbackMissing.both.focusesProblem)
        #expect(SendFeedbackMissing.problem.focusesProblem)
        #expect(!SendFeedbackMissing.details.focusesProblem)
    }

    @Test func aMissingFieldDoesNotEnableSendWhileSomethingRunsOrMailIsOff() {
        var form = SendFeedbackForm(mailAvailable: false, running: true)
        #expect(!form.canSend)
        form.mailAvailable = true
        form.importingMedia = true
        #expect(!form.canSend && form.missing == .both)
    }

    @Test func whileAReportIsMadeNothingIsEditedOrAddedOrSent() {
        var form = SendFeedbackForm(mailAvailable: true, running: true)
        form.problem = "x"
        form.makingBugReport = true
        #expect(!form.fieldsEnabled && !form.canSend && !form.canMakeBugReport && !form.canTakeScreenshot
                && !form.canAddMedia)
        form.makingBugReport = false
        form.takingScreenshot = true
        #expect(form.fieldsEnabled && !form.canSend && !form.canMakeBugReport && !form.canTakeScreenshot
                && !form.canAddMedia)
        form.takingScreenshot = false
        form.importingMedia = true
        #expect(!form.canSend && !form.canAddMedia)
        form.importingMedia = false
        #expect(form.canSend && form.canMakeBugReport && form.canTakeScreenshot && form.canAddMedia)
    }

    @Test func onceTheMailIsSentNothingIsEditedAttachedOrSentAgain() {
        var form = SendFeedbackForm(mailAvailable: true, running: true)
        form.problem = "x"
        form.details = "y"
        form.attachments.add(attachment(.photo, bytes: 10))
        #expect(form.fieldsEnabled && form.canSend && form.readyToSend && form.canMakeBugReport
                && form.canTakeScreenshot && form.canAddMedia && form.canAddFiles)
        form.sent = true
        #expect(!form.fieldsEnabled && !form.canSend && !form.readyToSend && !form.canMakeBugReport
                && !form.canTakeScreenshot && !form.canAddMedia && !form.canAddFiles)
        #expect(form.hasContent && form.problem == "x" && form.attachments.count == 1,
                "what was sent is still the sheet's, under the notice")
    }

    @Test func withoutMailEveryControlIsOff() {
        var form = SendFeedbackForm(mailAvailable: false, running: true)
        form.problem = "x"
        #expect(!form.fieldsEnabled && !form.canSend && !form.canMakeBugReport && !form.canTakeScreenshot
                && !form.canAddMedia)
        form.mailAvailable = true
        #expect(form.fieldsEnabled && form.canSend && form.canMakeBugReport)
    }

    @Test func aBugReportAndAScreenshotNeedARunningVirtualMachine() {
        var form = SendFeedbackForm(mailAvailable: true, running: false)
        #expect(form.showsHowToReportBug)
        #expect(!form.canMakeBugReport && !form.canTakeScreenshot)
        #expect(form.canAddMedia, "the rest of the form works")
        form.problem = "an idea"
        #expect(form.canSend)
        form.running = true
        #expect(!form.showsHowToReportBug && form.canMakeBugReport && form.canTakeScreenshot)
    }

    @Test func oneBugReportAtMostIsMade() {
        var form = SendFeedbackForm(mailAvailable: true, running: true)
        form.attachments.add(attachment(.bugReport, bytes: 10))
        #expect(!form.canMakeBugReport)
        #expect(form.canTakeScreenshot)
        form.attachments.remove(form.attachments.items[0].id)
        #expect(form.canMakeBugReport)
    }

    /// The app says whether a bug report can start now (the Create bug report
    /// row's rule, with no other task under the overlay): the control follows it.
    @Test func aBugReportNeedsTheAppToBeAbleToMakeOne() {
        var form = SendFeedbackForm(mailAvailable: true, running: true)
        form.problem = "x"
        #expect(form.bugReportPossible && form.canMakeBugReport)
        form.bugReportPossible = false
        #expect(!form.canMakeBugReport)
        #expect(form.canTakeScreenshot && form.canAddMedia && form.canSend, "the rest of the form works")
        form.bugReportPossible = true
        #expect(form.canMakeBugReport)
    }

    @Test func closingAsksOnceSomethingIsTypedOrAttached() {
        var form = SendFeedbackForm(mailAvailable: true, running: false)
        #expect(!form.hasContent)
        form.problem = "   "
        form.details = "\n"
        #expect(!form.hasContent, "blanks are nothing")
        form.details = "x"
        #expect(form.hasContent)
        form.details = ""
        form.attachments.add(attachment(.photo, bytes: 1))
        #expect(form.hasContent)
    }

    // MARK: Staging

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("andarium-feedback-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func aFolderIsMadeWithItsFirstFileAndRemovedWithEverythingInIt() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = SendFeedbackStaging(root: root.appendingPathComponent("Feedback"))
        let folder = staging.makeFolder()
        #expect(!folder.exists, "no file, no folder")
        let first = try folder.reserve("photo.heic")
        try Data([1]).write(to: first)
        let second = try folder.reserve("photo.heic")
        #expect(first != second && second.lastPathComponent == "photo-2.heic")
        try Data([2]).write(to: second)
        #expect(folder.exists)
        folder.remove(first)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        folder.removeAll()
        #expect(!folder.exists)
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test func aFileIsMovedIntoTheFolderUnderASafeName() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = SendFeedbackStaging(root: root.appendingPathComponent("Feedback"))
        let folder = staging.makeFolder()
        let incoming = root.appendingPathComponent("picked")
        try Data(repeating: 7, count: 5).write(to: incoming)
        let adopted = try folder.adopt(incoming, named: "../My Photo (1).jpg")
        #expect(adopted.deletingLastPathComponent().standardizedFileURL == folder.url.standardizedFileURL)
        #expect(adopted.lastPathComponent == "_My Photo (1).jpg")
        #expect(!FileManager.default.fileExists(atPath: incoming.path))
        #expect(try Data(contentsOf: adopted).count == 5)
        #expect(SendFeedbackFolder.safeName("...") == "file")
        #expect(SendFeedbackFolder.safeName(String(repeating: "a", count: 300)).count == 100)
    }

    @Test func aSweepRemovesWhatAnEndedProcessLeftBehind() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = SendFeedbackStaging(root: root.appendingPathComponent("Feedback"))
        let left = staging.makeFolder()
        try Data([1]).write(to: try left.reserve("bugreport.zip"))
        try FileManager.default.createDirectory(at: staging.incoming, withIntermediateDirectories: true)
        try Data([2]).write(to: staging.incoming.appendingPathComponent("video.mov"))
        staging.sweep()
        #expect(!FileManager.default.fileExists(atPath: staging.root.path))
        staging.sweep()  // nothing left is not an error
    }
}
