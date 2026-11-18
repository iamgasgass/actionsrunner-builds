// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import AndariumCore
import AndariumCoreTestSupport
import Foundation
import Testing
import UIKit
@testable import Andarium

extension SendFeedbackModel {
    /// Send, and where the sheet asks about the bug report, the answer "Send without bug report": what a
    /// test that is about the mail, and not about the question, means by tapping Send.
    func sendAnyway() {
        send()
        if askingForBugReport {
            askingForBugReport = false
            sendWithoutBugReport()
        }
    }
}

/// The question Send asks before the mail opens, and the viewer of what the attached report holds, on the
/// sheet's model hosted in the application. A stub stands for the runtime and the system's composer. The
/// decision itself (every combination) is `andarium-core`'s `SendFeedbackAskTests`; the screens' own part
/// is the UI test's.
@Suite(.serialized)
@MainActor
struct SendFeedbackAskScreenTests {
    private let host = HostDevice(
        name: "iPhone", processorCount: 6, memory: MemoryPolicy(maximumsMiB: [4096]), freeStorageBytes: 41_000_000_000
    )

    @MainActor private final class Composer {
        var request: SendFeedbackMailRequest?
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

        func sheet(filled: Bool = true) -> SendFeedbackModel {
            let sheet = SendFeedbackModel(app: app, staging: staging)
            if filled {
                sheet.form.problem = "Game freezes"
                sheet.form.details = "The picture stops after the intro."
            }
            return sheet
        }
    }

    private func fixture(phase: Phase = .running(.normal)) -> Fixture {
        let system = SystemInfo(
            version: "17", release: "r2", kernel: "Linux 6.18", architecture: "arm64, 4 KB pages", appVersion: "1.0 (9)")
        let app = AppModel(
            guest: Guest.fresh(on: host), host: host, system: system, capabilities: .device, createRequirementBytes: 1)
        let driver = StubDriver(plan: .normal)
        app.driver = driver
        app.phase = phase
        let composer = Composer()
        var services = SendFeedbackServices()
        services.address = { "feedback@example.com" }
        services.canSendMail = { true }
        services.presentMail = { request, finish in
            composer.open(request, finish)
            return true
        }
        services.runningSeconds = { _ in 125 }
        app.feedbackServices = services
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("andarium-feedback-ask-\(UUID().uuidString)", isDirectory: true)
        return Fixture(app: app, driver: driver, composer: composer, root: root, staging: SendFeedbackStaging(root: root))
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// A small zip as Android's report is one, with Andarium's own record appended after its last entry.
    private func makeReport() throws -> URL {
        try FileManager.default.createDirectory(at: BugReportStaging.directory, withIntermediateDirectories: true)
        let url = BugReportStaging.directory.appendingPathComponent("bugreport-\(UUID().uuidString).zip")
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: url)
        try BugReportArchive.append(
            [
                .init(name: "bugreport-example.txt", data: Data(String(repeating: "dumpstate line\n", count: 3_000).utf8)),
                .init(name: "version.txt", data: Data("3.0\n".utf8)),
                .init(name: "andarium/session-current.txt", data: Data("uml-session 7\n".utf8)),
            ], to: url)
        return url
    }

    // MARK: The question

    @Test func sendAsksOnceBothFieldsAreWrittenWhileAReportCouldBeMadeAndOpensNothing() throws {
        let fixture = fixture()
        let sheet = fixture.sheet()
        #expect(sheet.state.asksAboutBugReportOnSend)
        sheet.send()
        #expect(sheet.askingForBugReport, "the alert is up")
        #expect(fixture.composer.opened == 0, "nothing opens before the answer")
        #expect(sheet.incomplete == nil && sheet.failure == nil && fixture.app.busy == nil)
        #expect(sheet.form.problem == "Game freezes" && sheet.form.details == "The picture stops after the intro.")
        sheet.close()
    }

    @Test func sendWithoutBugReportOpensTheMailAsItDoesToday() throws {
        let fixture = fixture()
        let sheet = fixture.sheet()
        sheet.send()
        sheet.askingForBugReport = false
        sheet.sendWithoutBugReport()
        #expect(fixture.composer.opened == 1)
        let request = try #require(fixture.composer.request)
        #expect(request.address == "feedback@example.com" && request.subject == "Andarium feedback: Game freezes")
        #expect(request.attachments.isEmpty)
        #expect(!sheet.askingForBugReport)
        sheet.close()
    }

    @Test func itAsksOnEveryTapAndRemembersNothing() throws {
        let fixture = fixture()
        let sheet = fixture.sheet()
        for round in 1...3 {
            sheet.send()
            #expect(sheet.askingForBugReport, "tap \(round)")
            sheet.askingForBugReport = false
        }
        #expect(fixture.composer.opened == 0)
        sheet.close()
        // And a sheet after the first one starts as that one did.
        let next = fixture.sheet()
        next.send()
        #expect(next.askingForBugReport)
        next.close()
    }

    @Test func createBugReportMakesItAttachesItAndStaysInTheSheet() async throws {
        let fixture = fixture()
        let file = try makeReport()
        fixture.driver.bugReport = { _ in file }
        let sheet = fixture.sheet()
        sheet.send()
        #expect(sheet.askingForBugReport)
        // The alert's first button: the sheet's own Create bug report, as the bar's button does it.
        sheet.askingForBugReport = false
        sheet.createBugReport()
        #expect(fixture.app.busyOverSheet, "the same overlay, over the sheet")
        #expect(await eventually { sheet.form.attachments.bugReport != nil })
        #expect(fixture.composer.opened == 0, "no mail composer afterwards")
        #expect(!sheet.askingForBugReport && sheet.failure == nil && !sheet.closed)
        #expect(sheet.form.problem == "Game freezes", "the draft is as it was")
        // The person reads the report, and taps Send again: no question now, the mail opens with it.
        sheet.send()
        #expect(!sheet.askingForBugReport)
        #expect(fixture.composer.opened == 1)
        #expect(fixture.composer.request?.attachments.map(\.kind) == [.bugReport])
        sheet.close()
    }

    @Test func aReportThatFailsIsSaidInTheSheetAndAsksAgainOnTheNextSend() async throws {
        let fixture = fixture()
        fixture.driver.bugReport = { _ in throw AdbFailure(.refused, activity: .bugReport) }
        let sheet = fixture.sheet()
        sheet.send()
        sheet.askingForBugReport = false
        sheet.createBugReport()
        #expect(await eventually { sheet.failure != nil })
        #expect(sheet.failure?.title == "Bug report not created")
        #expect(fixture.composer.opened == 0)
        sheet.failure = nil
        sheet.send()
        #expect(sheet.askingForBugReport, "nothing is attached: it asks again")
        sheet.close()
    }

    @Test func aMissingFieldIsSaidFirstAndNothingIsAsked() throws {
        let fixture = fixture()
        let sheet = fixture.sheet(filled: false)
        sheet.form.details = "Details"
        sheet.send()
        #expect(sheet.incomplete == .problem && !sheet.askingForBugReport && fixture.composer.opened == 0)
        sheet.incomplete = nil
        sheet.form.problem = "Problem"
        sheet.form.details = " \n"
        sheet.send()
        #expect(sheet.incomplete == .details && !sheet.askingForBugReport)
        sheet.close()
    }

    @Test func anAttachedReportIsNotAskedAboutAndRemovingItAsksAgain() async throws {
        let fixture = fixture()
        let sheet = fixture.sheet()
        sheet.adoptBugReport(try makeReport())
        let report = try #require(sheet.form.attachments.bugReport)
        sheet.send()
        #expect(!sheet.askingForBugReport && fixture.composer.opened == 1)
        fixture.composer.leave(.cancelled)
        sheet.remove(report)
        sheet.send()
        #expect(sheet.askingForBugReport && fixture.composer.opened == 1)
        sheet.close()
    }

    /// The sheet opened from the main screen: nothing can be reproduced, the card says so, and Send does what it did.
    @Test func withoutAVirtualMachineSendOpensTheMailAndAsksNothing() throws {
        let fixture = fixture(phase: .home)
        let sheet = fixture.sheet()
        sheet.send()
        #expect(!sheet.askingForBugReport && fixture.composer.opened == 1)
        sheet.close()
    }

    @Test func whileTheVirtualMachineStartsSendOpensTheMailAndAsksNothing() throws {
        let fixture = fixture(phase: .booting(.normal))
        let sheet = fixture.sheet()
        #expect(sheet.state.starting)
        sheet.send()
        #expect(!sheet.askingForBugReport && fixture.composer.opened == 1)
        sheet.close()
    }

    @Test func anotherTaskUnderTheOverlayAndARecoverySessionAskNothing() throws {
        let fixture = fixture()
        let sheet = fixture.sheet()
        fixture.app.busy = BusyState(title: "Installing", detail: "Detail", progress: nil)
        sheet.send()
        #expect(!sheet.askingForBugReport && fixture.composer.opened == 1)
        fixture.app.busy = nil
        sheet.close()
        let recovery = self.fixture(phase: .running(.recovery))
        let other = recovery.sheet()
        other.send()
        #expect(!other.askingForBugReport && recovery.composer.opened == 1)
        other.close()
    }

    @Test func whileTheReportIsBeingMadeSendDoesNothing() async throws {
        let fixture = fixture()
        let release = OpenGate()
        let file = try makeReport()
        fixture.driver.bugReport = { _ in
            while !release.isOpen { try await Task.sleep(for: .milliseconds(5)) }
            return file
        }
        let sheet = fixture.sheet()
        sheet.createBugReport()
        sheet.send()
        #expect(!sheet.askingForBugReport && fixture.composer.opened == 0)
        release.open()
        #expect(await eventually { sheet.form.attachments.bugReport != nil })
        sheet.close()
    }

    private nonisolated final class OpenGate: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        func open() { lock.withLock { released = true } }
        var isOpen: Bool { lock.withLock { released } }
    }

    // MARK: The viewer

    @Test func theBugReportAndTheStartLogOpenAndNothingElseDoes() throws {
        let fixture = fixture()
        let sheet = fixture.sheet()
        sheet.adoptBugReport(try makeReport())
        sheet.form.attachments.add(
            SendFeedbackAttachment(kind: .photo, url: URL(fileURLWithPath: "/staged/photo.jpg"), bytes: 10))
        let report = try #require(sheet.form.attachments.bugReport)
        let photo = try #require(sheet.form.attachments.items.first { $0.kind == .photo })
        #expect(SendFeedbackModel.canView(.bugReport) && SendFeedbackModel.canView(.startLog))
        #expect(![SendFeedbackAttachment.Kind.screenshot, .photo, .video, .file].contains(where: SendFeedbackModel.canView))
        sheet.view(photo)
        #expect(sheet.viewing == nil)
        sheet.view(report)
        #expect(sheet.viewing?.id == report.id)
        sheet.viewing = nil
        sheet.view(report)
        sheet.remove(report)
        #expect(sheet.viewing == nil, "an attachment taken out is no longer shown")
        sheet.close()
        sheet.view(report)
        #expect(sheet.viewing == nil, "a closed sheet shows nothing")
    }

    @Test func theViewerListsWhatTheStagedReportHoldsAndChangesNothing() async throws {
        let fixture = fixture()
        let sheet = fixture.sheet()
        sheet.adoptBugReport(try makeReport())
        let report = try #require(sheet.form.attachments.bugReport)
        let before = try Data(contentsOf: report.url)
        let reader = try await SendFeedbackArchiveReader.open(file: report.url)
        #expect(reader.listing.entries.map(\.name) == ["bugreport-example.txt", "version.txt", "andarium/session-current.txt"])
        #expect(reader.listing.entries.map(\.size) == [45_000, 4, 14])
        guard case .text(let text) = try await reader.content(of: 0) else {
            Issue.record("the first entry is text")
            return
        }
        #expect(try await text.window(0).text.hasPrefix("dumpstate line\n"))
        #expect(try Data(contentsOf: report.url) == before, "reading changes nothing")
        #expect(try FileManager.default.contentsOfDirectory(atPath: sheet.folder.url.path) == [report.url.lastPathComponent],
                "nothing is extracted beside it")
        sheet.close()
    }

    @Test func theStartLogReadsAsText() async throws {
        let fixture = fixture(phase: .booting(.normal))
        let sheet = fixture.sheet()
        let url = try sheet.folder.reserve("start-log.txt")
        try Data("Boot step 3 after 3 min\nline two\n".utf8).write(to: url)
        sheet.form.attachments.add(SendFeedbackAttachment(kind: .startLog, url: url, bytes: 33))
        let log = try #require(sheet.form.attachments.items.first { $0.kind == .startLog })
        let reader = try #require(SendFeedbackTextReader(file: log.url))
        #expect(try await reader.window(0).text == "Boot step 3 after 3 min\nline two\n")
        sheet.view(log)
        #expect(sheet.viewing?.id == log.id)
        sheet.close()
    }

    @Test func theRowSaysHowManyFilesTheReportHoldsOnceItsDirectoryIsRead() async throws {
        let fixture = fixture()
        let sheet = fixture.sheet()
        sheet.adoptBugReport(try makeReport())
        let report = try #require(sheet.form.attachments.bugReport)
        #expect(await eventually { sheet.reports[report.id]?.reader != nil }, "the directory is read as the report is attached")
        let facts = try #require(sheet.reports[report.id]?.reader?.facts)
        #expect(facts.fileCount == 3 && facts.unpackedBytes == 45_018)
        #expect(SendFeedbackSheet.detail(report, files: facts.fileCount) == "\(report.size) \u{00B7} 3 files")
        #expect(SendFeedbackSheet.spoken(report, files: facts.fileCount) == "Bug report, \(report.size), 3 files")
        #expect(SendFeedbackSheet.detail(report) == report.size, "while the directory is not read there is no count")
        // A second report replaces the first and its directory.
        sheet.adoptBugReport(try makeReport())
        let second = try #require(sheet.form.attachments.bugReport)
        #expect(second.id != report.id && sheet.reports[report.id] == nil)
        #expect(await eventually { sheet.reports[second.id]?.reader != nil })
        sheet.remove(second)
        #expect(sheet.reports[second.id] == nil, "a report taken out leaves no directory behind")
        sheet.close()
    }

    @Test func aReportThatIsNotAnArchiveIsSaidOnItsPageAndHasNoCount() async throws {
        let fixture = fixture()
        let sheet = fixture.sheet()
        try FileManager.default.createDirectory(at: BugReportStaging.directory, withIntermediateDirectories: true)
        let url = BugReportStaging.directory.appendingPathComponent("bugreport-\(UUID().uuidString).zip")
        try Data(repeating: 0x41, count: 4_096).write(to: url)
        sheet.adoptBugReport(url)
        let report = try #require(sheet.form.attachments.bugReport)
        #expect(await eventually {
            if case .failed = sheet.reports[report.id] { return true }
            return false
        }, "an archive that cannot be read says so instead of listing")
        #expect(sheet.reports[report.id]?.reader == nil)
        sheet.close()
    }

    // MARK: Words

    /// Every string of the question, the card and the viewer is translated, and none says "guest" or names a
    /// company or a provider: the virtual machine is the virtual machine in each language.
    @Test(arguments: ["en", "ja", "zh-Hans", "zh-Hant"])
    func theWordsAreInEveryLanguage(language: String) {
        func text(_ key: String.LocalizationValue) -> String {
            String(localized: LocalizedStringResource(key, table: "Feedback", locale: Locale(identifier: language), bundle: .main))
        }
        let strings = [
            text("Send without a bug report?"),
            text("Without a bug report, a problem will most likely not get fixed. Send without one only if your message reports no problem, such as a suggestion or a question, or if you don\u{2019}t want to attach it."),
            text("Create bug report"), text("Send without bug report"),
            text("Without a bug report, a problem will most likely not get fixed."),
            text("Start the virtual machine."), text("Make the problem happen again."),
            text("Tap the side keys, then Settings \u{203A} Send feedback, and attach a bug report."),
            text("Shows what the bug report holds"), text("Shows the start log"),
            text("This bug report can\u{2019}t be read. It may be damaged or cut short."),
            text("This file goes with your mail as it is."), text("Inside the bug report."),
            text("Text"), text("Picture"), text("Archive"), text("Empty"), text("Not text, not shown"),
            text("Picture, not shown"), text("Archive, not shown"), text("Encrypted, not shown"),
            text("Not supported, not shown"), text("Too large, not shown"), text("Damaged, not shown"),
            text("Position"),
        ]
        for string in strings {
            #expect(!string.isEmpty)
            #expect(!string.localizedCaseInsensitiveContains("guest"), "\(language): \(string)")
            for company in ["Google", "Apple", "Anthropic", "Claude", "OpenAI"] {
                #expect(!string.contains(company), "\(language): \(string)")
            }
        }
        if language == "en" {
            #expect(strings[0] == "Send without a bug report?" && strings[3] == "Send without bug report")
            #expect(strings[1].hasPrefix("Without a bug report, a problem will most likely not get fixed."))
            #expect(strings[4] == "Without a bug report, a problem will most likely not get fixed.")
        } else {
            for index in [0, 1, 3, 4, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23] {
                let ascii = strings[index].unicodeScalars.allSatisfy { $0.isASCII }
                #expect(!ascii, "\(language) says it in English: \(strings[index])")
            }
            // The question's message and the card's first line say the same first thing.
            let first = strings[4].dropLast()
            #expect(strings[1].hasPrefix(first), "\(language): the message and the card do not start alike")
        }
    }

    private func said(_ key: String.LocalizationValue, in language: String) -> String {
        String(localized: LocalizedStringResource(key, table: "Feedback", locale: Locale(identifier: language), bundle: .main))
    }

    /// The viewer calls what a report holds a file, and nothing else: not an item, not an entry, not a part.
    @Test(arguments: ["ja", "zh-Hans", "zh-Hant"])
    func theViewerNamesWhatItHoldsAFile(language: String) {
        let noun = ["ja": "ファイル", "zh-Hans": "文件", "zh-Hant": "檔案"][language]!
        let old = ["ja": "項目", "zh-Hans": "项目", "zh-Hant": "項目"][language]!
        let strings = [
            said("Unnamed file", in: language), said("This file can\u{2019}t be shown.", in: language),
            said("This archive has no files.", in: language), said("Only the first \(12) files are listed.", in: language),
            said("This file can\u{2019}t be read. It may be damaged or cut short.", in: language),
        ]
        for string in strings {
            #expect(string.contains(noun), "\(language): \(string)")
            #expect(!string.contains(old), "\(language): \(string)")
            #expect(!string.unicodeScalars.allSatisfy { $0.isASCII }, "\(language) says it in English: \(string)")
        }
        #expect(strings[3].contains("12"), "\(language): the number is where it is said")
    }

    /// The archive is one term in each Chinese: the one the row says (Archive), in the row that is not shown too,
    /// and in the page that lists nothing.
    @Test(arguments: [("zh-Hans", "归档文件", "压缩文件"), ("zh-Hant", "封存檔", "壓縮檔")])
    func theArchiveIsOneTermInChinese(language: String, term: String, other: String) {
        for string in [said("Archive", in: language), said("Archive, not shown", in: language), said("This archive has no files.", in: language)] {
            #expect(string.contains(term), "\(language): \(string)")
            #expect(!string.contains(other), "\(language): \(string)")
        }
    }
}

#endif
