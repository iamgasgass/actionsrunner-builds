// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import AndariumCore
import AndariumCoreTestSupport
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Andarium

/// The sheet the slow-start notice opens, hosted in the application: the tip it
/// shows in each state and the start log it attaches by itself, once, from what
/// the application already has (the runtime's session record of this boot).
/// Like `SendFeedbackScreenTests` they run where Send feedback is compiled in: a
/// build made with `FEEDBACK_ADDRESS=feedback@example.com` on the xcodebuild
/// command line.
@Suite(.serialized)
@MainActor
struct SendFeedbackStartLogTests {
    private let host = HostDevice(
        name: "iPhone", processorCount: 6, memory: MemoryPolicy(maximumsMiB: [4096]), freeStorageBytes: 41_000_000_000
    )

    /// A key as the Android adb keeps it, and a serial: values that must never
    /// reach the log.
    private static let key = "QAAAAGJ4Z0n2Hq+Lx0aT/m8nR4sJ0d5bYwV9cE7uKf3PzQ1yM6hS2oXkUa8tNvB5rLq=="
    private static let serial = "K7QX2M9T4R"

    /// The row's remove button, in the language of the run (the application's own words).
    private static var removeLabel: String { String(localized: "Remove start log", table: "Feedback") }

    /// 2026-11-08 05:04:50 UTC: the moment the sheets of these tests make their log.
    private static let moment = Date(timeIntervalSince1970: 1_794_114_290)

    /// The name that moment gives in the device's clock, written out here with
    /// the Gregorian calendar and `String(format:)`, independently of the code.
    private static var expectedName: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: moment)
        return String(
            format: "start-log-%04d%02d%02d-%02d%02d%02d.txt", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    private struct Fixture {
        let app: AppModel
        let diagnostics: URL
        let staging: SendFeedbackStaging
        let composer: Composer

        var record: URL { diagnostics.appendingPathComponent(BugReportAttachments.sessionRecord) }

        func sheet() -> SendFeedbackModel { SendFeedbackModel(app: app, staging: staging) }

        /// The session record a start under way leaves, with `output` as what the
        /// guest printed: of this process, begun in this run (the start under way
        /// began 3:17 before `moment`) and of the guest's `restarts`th boot. The
        /// other arguments make the records that are not this boot's.
        func writeRecord(
            output: String, state: String = "running", end: String = "running", pid: Int32 = getpid(),
            started: Int = Int(SendFeedbackStartLogTests.moment.timeIntervalSince1970) - 190, restarts: Int = 0
        ) throws {
            var text = "uml-session 7\nstate \(state)\nend \(end)\nstatus 0\npid \(pid)\nstarted \(started)\n"
            if state != "running" { text += "ended \(started + 5)\n" }
            text += "boot unfinished\nrestarts \(restarts)\nkernel-output\n" + output
            try Data(text.utf8).write(to: record)
        }
    }

    @MainActor private final class Composer {
        var request: SendFeedbackMailRequest?
    }

    private func fixture(phase: Phase = .booting(.normal)) throws -> Fixture {
        let system = SystemInfo(
            version: "17", release: "r2", kernel: "Linux 6.18", architecture: "arm64, 4 KB pages", appVersion: "1.0 (9)"
        )
        let app = AppModel(
            guest: Guest.fresh(on: host), host: host, system: system, capabilities: .device, createRequirementBytes: 1)
        app.driver = StubDriver(plan: .normal)
        app.phase = phase
        // A clock that stands still: the start has run 3:17.
        app.clock = { 5000 }
        if case .booting = phase {
            app.slowStart.begin(at: 5000 - 197)
            app.updateSlowStart()
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("andarium-startlog-hosted-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = root.appendingPathComponent("diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        app.diagnosticsDirectory = diagnostics
        // This process's run, which began with the start, when the file held no record.
        app.bootRecord = BootRecordBinding(processID: Int(getpid()))
        let composer = Composer()
        var services = SendFeedbackServices()
        services.address = { "feedback@example.com" }
        services.canSendMail = { true }
        services.presentMail = { request, _ in
            composer.request = request
            return true
        }
        services.runningSeconds = { _ in 125 }
        services.now = { Self.moment }
        app.feedbackServices = services
        return Fixture(
            app: app, diagnostics: diagnostics, staging: SendFeedbackStaging(root: root.appendingPathComponent("staging")),
            composer: composer)
    }

    private func contents(of attachment: SendFeedbackAttachment) throws -> String {
        try String(contentsOf: attachment.url, encoding: .utf8)
    }

    private static let output = """
        [   41.2] init: starting service 'servicemanager'...
        [  102.9] init: starting service 'netd'...
        [  184.7] init: starting service 'zygote'...

        """

    // MARK: The tip

    @Test func theTipFollowsTheStateTheSheetIsOpenedIn() throws {
        let home = try fixture(phase: .home).sheet()
        #expect(home.state.tip == .home && home.state.showsHowToReportBug)
        let running = try fixture(phase: .running(.normal)).sheet()
        #expect(running.state.tip == .running)
        let starting = try fixture().sheet()
        #expect(starting.state.tip == .starting)
        // A bug report and a screenshot stay unavailable during a start, and the rest works.
        #expect(!starting.state.canMakeBugReport && !starting.state.canTakeScreenshot)
        #expect(starting.state.canAddMedia)
        starting.close()
        home.close()
        running.close()
    }

    // MARK: The log

    @Test func theSheetOpenedDuringAStartAttachesTheLogOnceFromTheSeededBoot() throws {
        let fixture = try fixture()
        try fixture.writeRecord(output: Self.output)
        let sheet = fixture.sheet()
        #expect(sheet.form.attachments.isEmpty, "making the model attaches nothing; the sheet's task does")
        sheet.offerStartLog()
        sheet.offerStartLog()
        #expect(sheet.form.attachments.count == 1)
        let log = try #require(sheet.form.attachments.items.first)
        #expect(log.kind == .startLog && log.fileName == Self.expectedName && log.mimeType == "text/plain")
        // The name is English, Gregorian and ASCII whatever the device's language, calendar and digits are.
        #expect(log.fileName.range(of: #"^start-log-[0-9]{8}-[0-9]{6}\.txt$"#, options: .regularExpression) != nil)
        let text = try contents(of: log)
        #expect(UInt64(text.utf8.count) == log.bytes)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.starts(with: ["Start log", "Step: \(sheet.information.boot?.step ?? "?")", "Time: 3:17", "Start: ordinary start"]))
        #expect(!lines.contains { $0.contains("Made") }, "the moment is in the name alone")
        #expect(lines.contains("[  102.9] init: starting service 'netd'..."))
        // It counts with the rest.
        #expect(sheet.form.attachments.totalBytes == log.bytes)
        // And it goes with the mail, once the Problem and the details are written.
        sheet.form.problem = "Too slow"
        sheet.form.details = "Stuck at the boot screen"
        sheet.sendAnyway()
        let request = try #require(fixture.composer.request)
        #expect(request.attachments.map(\.fileName) == [Self.expectedName])
        #expect(request.body.contains("Boot: not finished"))
        sheet.close()
    }

    /// The sheet's start log of a record that is not the boot under way's quotes
    /// none of it.
    private func logText(_ fixture: Fixture) throws -> String {
        let sheet = fixture.sheet()
        sheet.offerStartLog()
        defer { sheet.close() }
        return try contents(of: try #require(sheet.form.attachments.items.first))
    }

    @Test func aRecordThatEndedOrIsAnotherProcessesOrBeganBeforeTheRunIsNotQuoted() throws {
        let fixture = try fixture()
        let quote = "[  102.9] init: starting service 'netd'..."
        for (name, write) in [
            ("an ended record", { try fixture.writeRecord(output: Self.output, state: "ended", end: "stopped") }),
            ("a restart's end", { try fixture.writeRecord(output: Self.output, state: "ended", end: "restarted") }),
            ("another process", { try fixture.writeRecord(output: Self.output, pid: getpid() + 1) }),
            ("an earlier boot", { try fixture.writeRecord(output: Self.output, restarts: 3) }),
        ] as [(String, () throws -> Void)] {
            try write()
            let text = try logText(fixture)
            #expect(!text.contains(quote) && text.hasSuffix("(nothing yet)\n"), "\(name)")
        }
        // The record of this boot is quoted, whatever second it says: the clock may have stepped back.
        for started in [Int(Self.moment.timeIntervalSince1970) - 190, 1_000_000, 0] {
            try fixture.writeRecord(output: Self.output, started: started)
            #expect(try logText(fixture).contains(quote), "started \(started)")
        }
    }

    /// A running record the file held as the run began is not the run's, and the
    /// run's own record, whatever second it says, is.
    @Test func aRunningRecordThatWasInTheFileAsTheRunBeganIsNotQuoted() throws {
        let fixture = try fixture()
        let quote = "[  102.9] init: starting service 'netd'..."
        let started = Int(Self.moment.timeIntervalSince1970) - 4000
        try fixture.writeRecord(output: Self.output, started: started)
        fixture.app.bootRecord = BootRecordBinding(
            processID: Int(getpid()), recordAtStart: SessionRecord.read(at: fixture.record))
        #expect(!(try logText(fixture)).contains(quote))
        try fixture.writeRecord(output: Self.output, started: started - 600)
        #expect(try logText(fixture).contains(quote))
    }

    @Test func aRestartOfTheGuestMovesTheBootTheLogQuotesToTheNextOne() throws {
        let fixture = try fixture()
        try fixture.writeRecord(output: Self.output)
        #expect(fixture.app.startOutput()?.contains("zygote") == true)
        // The runtime reports the restart before it begins the next record: until it does, the file holds the
        // boot before, which has ended or says the count before.
        fixture.app.guestRestartsCounted(1)
        #expect(fixture.app.startOutput() == nil)
        try fixture.writeRecord(output: Self.output, state: "ended", end: "restarted")
        #expect(fixture.app.startOutput() == nil)
        try fixture.writeRecord(output: "[    1.0] init: the next boot\n", restarts: 1)
        #expect(fixture.app.startOutput() == "[    1.0] init: the next boot\n")
    }

    /// A start binds the record to its own run, of this process, and counts the restarts again from none.
    @Test func aStartMakesTheBindingOfItsRun() throws {
        let fixture = try fixture(phase: .home)
        // The file holds a running record of an earlier run as the start begins.
        let started = Int(Self.moment.timeIntervalSince1970) - 4000
        try fixture.writeRecord(output: Self.output, started: started)
        fixture.app.bootRecord = nil
        fixture.app.start(.normal)
        let binding = try #require(fixture.app.bootRecord)
        #expect(binding.processID == Int(getpid()) && binding.restarts == 0)
        #expect(fixture.app.startOutput() == nil, "the record that was there is not the run's")
        try fixture.writeRecord(output: Self.output, started: started + 1)
        #expect(fixture.app.startOutput() != nil)
        fixture.app.guestRestartsCounted(2)
        #expect(fixture.app.bootRecord?.restarts == 2)
    }

    @Test func theLogTakesOutTheKeyTheSerialAndThePaths() throws {
        let fixture = try fixture()
        let container = fixture.diagnostics.path
        try fixture.writeRecord(
            output: """
                [    0.0] Kernel command line: androidboot.serialno=\(Self.serial) androidboot.kernarium.adb_key=\(Self.key) --session-record=\(container)/session.txt
                [    5.1] eth0: address aa:bb:cc:dd:ee:ff
                [   99.0] init: starting service 'netd'...

                """)
        fixture.app.diagnosticsContainers = [container]
        let sheet = fixture.sheet()
        sheet.offerStartLog()
        let text = try contents(of: try #require(sheet.form.attachments.items.first))
        #expect(!text.contains(Self.key) && !text.contains("QAAAAGJ4") && !text.contains(Self.serial))
        #expect(!text.contains("aa:bb:cc") && !text.contains(container))
        #expect(text.contains("adb_key=<masked>") && text.contains("serialno=<masked>"))
        #expect(text.contains("[   99.0] init: starting service 'netd'..."))
        sheet.close()
    }

    /// The values the driver knows are taken out wherever the output has them,
    /// and the formats that carry any value are taken out without them.
    @Test func theLogTakesOutWhatTheDriverKnowsAndTheFormatsThatCarryAnyValue() throws {
        let fixture = try fixture()
        let driver = try #require(fixture.app.driver as? StubDriver)
        driver.identifiers = GuestIdentifiers(
            serial: Self.serial, adbKey: Self.key, hardwareAddresses: [[0x02, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E]],
            timeZones: ["America/Argentina/Buenos_Aires"])
        let uuid = "12345678-1234-4abc-8def-123456789abc"
        try fixture.writeRecord(
            output: """
                [    1.0] init: using \(Self.serial) and America/Argentina/Buenos_Aires
                [    2.0] init: Init cannot set 'ro.boot.kernarium.adb_key' to '\(Self.key)': __system_property_add failed
                [    3.0] eth0: IPv6 duplicate address fe80::1a:2bff:fe3c:4d5e used by 02:1a:2b:3c:4d:5e detected!
                [    4.0] EXT4-fs (ubdb1): mounted filesystem \(uuid) r/w with ordered data mode. Quota mode: none.
                [    5.0] eth0: 10.0.2.15 at 05:04:50

                """)
        let text = try logText(fixture)
        for value in [Self.serial, "Buenos_Aires", Self.key, "QAAAAGJ4", "fe80::1a", "02:1a:2b", uuid] {
            #expect(!text.contains(value), "\(value) in \(text)")
        }
        #expect(text.contains("init: using <masked> and <time zone>"))
        #expect(text.contains("init: Init cannot set 'ro.boot.kernarium.adb_key' to '<masked>': __system_property_add failed"))
        #expect(text.contains("eth0: IPv6 duplicate address <ipv6> used by <address> detected!"))
        #expect(text.contains("EXT4-fs (ubdb1): mounted filesystem <uuid> r/w with ordered data mode. Quota mode: none."))
        #expect(text.contains("[    5.0] eth0: 10.0.2.15 at 05:04:50"))
    }

    /// The name is the moment the log was made, in the device's clock, and the ambient
    /// language, calendar and digits (the run's `-testLanguage` and `-testRegion`)
    /// change nothing: the control shows what a formatter that follows them
    /// writes.
    @Test func theNameIsFixedWhateverTheDevicesLanguageCalendarAndDigitsAre() throws {
        let fixture = try fixture()
        let sheet = fixture.sheet()
        sheet.offerStartLog()
        let name = try #require(sheet.form.attachments.items.first).fileName
        #expect(name == Self.expectedName)
        #expect(name.range(of: #"^start-log-[0-9]{8}-[0-9]{6}\.txt$"#, options: .regularExpression) != nil)
        let following = DateFormatter()
        following.timeZone = TimeZone.current
        following.dateFormat = "yyyyMMdd-HHmmss"
        print("ambient", Locale.current.identifier, Locale.current.calendar.identifier, "a formatter that follows it writes", following.string(from: Self.moment), "the name has", name)
        // Made once: neither the row's removal nor the sheet's task running again names another.
        sheet.remove(try #require(sheet.form.attachments.items.first))
        fixture.app.feedbackServices.now = { Self.moment.addingTimeInterval(60) }
        sheet.offerStartLog()
        #expect(sheet.form.attachments.isEmpty)
        sheet.close()
    }

    @Test func aRecordWithoutOutputGivesALogThatSaysSo() throws {
        let fixture = try fixture()
        let sheet = fixture.sheet()
        sheet.offerStartLog()
        let text = try contents(of: try #require(sheet.form.attachments.items.first))
        #expect(text.hasSuffix("(nothing yet)\n") && text.contains("Step: "))
        sheet.close()
    }

    @Test func theLogIsAtMostTheRecordsFourKiBAndNeverTheLastBootsOutput() throws {
        let fixture = try fixture()
        // The record's cursor starts with the boot: a record of this boot holds
        // this boot's output only, and the log takes the last 4 KiB of it.
        let lines = (0..<400).map { "[\(String(format: "%7.1f", Double($0)))] message \($0) of this boot" }
        try fixture.writeRecord(output: lines.joined(separator: "\n") + "\n")
        let sheet = fixture.sheet()
        sheet.offerStartLog()
        let text = try contents(of: try #require(sheet.form.attachments.items.first))
        let printed = try #require(text.components(separatedBy: "at most):\n").last)
        #expect(printed.utf8.count <= SendFeedbackStartLog.outputLimit + 1)
        #expect(printed.hasSuffix("message 399 of this boot\n") && !printed.contains("message 0 of"))
        sheet.close()
    }

    @Test func removingTheLogIsRememberedAndItIsNotMadeAgain() throws {
        let fixture = try fixture()
        try fixture.writeRecord(output: Self.output)
        let sheet = fixture.sheet()
        sheet.offerStartLog()
        let log = try #require(sheet.form.attachments.items.first)
        sheet.remove(log)
        #expect(sheet.form.attachments.isEmpty && !FileManager.default.fileExists(atPath: log.url.path))
        // The sheet's task runs again (the view is rebuilt), and the start moves on.
        sheet.offerStartLog()
        fixture.app.clock = { 5060 }
        sheet.offerStartLog()
        #expect(sheet.form.attachments.isEmpty, "a removed log is not attached again")
        sheet.close()
    }

    @Test func theLogIsNotRefreshedWhileTheSheetIsOpen() throws {
        let fixture = try fixture()
        try fixture.writeRecord(output: Self.output)
        let sheet = fixture.sheet()
        sheet.offerStartLog()
        let log = try #require(sheet.form.attachments.items.first)
        let before = try contents(of: log)
        try fixture.writeRecord(output: Self.output + "[  190.0] init: a later line\n")
        fixture.app.clock = { 5063 }
        sheet.offerStartLog()
        #expect(try contents(of: log) == before && !before.contains("a later line"))
        #expect(sheet.form.attachments.count == 1)
        sheet.close()
    }

    /// The log that the sheet attaches by itself is neither the Problem nor the
    /// details: Send looks dimmed until both are written, and its tap, which is
    /// enabled, says what is missing instead of opening the mail.
    @Test func theStartLogDoesNotCountAsAFilledField() throws {
        let fixture = try fixture()
        try fixture.writeRecord(output: Self.output)
        let sheet = fixture.sheet()
        sheet.offerStartLog()
        #expect(sheet.form.attachments.count == 1)
        #expect(sheet.state.canSend && sheet.state.missing == .both && !sheet.state.readyToSend)
        sheet.sendAnyway()
        #expect(sheet.incomplete == .both && fixture.composer.request == nil)
        sheet.form.problem = "Too slow"
        #expect(sheet.state.missing == .details && !sheet.state.readyToSend)
        sheet.sendAnyway()
        #expect(sheet.incomplete == .details && fixture.composer.request == nil)
        sheet.form.details = "Stuck at the boot screen"
        #expect(sheet.state.missing == nil && sheet.state.readyToSend)
        sheet.sendAnyway()
        #expect(fixture.composer.request?.attachments.map(\.kind) == [.startLog])
        sheet.close()
    }

    @Test func theLogIsOnlyMadeDuringAStart() throws {
        for phase in [Phase.home, .running(.normal)] {
            let fixture = try fixture(phase: phase)
            try fixture.writeRecord(output: Self.output)
            let sheet = fixture.sheet()
            sheet.offerStartLog()
            #expect(sheet.form.attachments.isEmpty, "\(phase) has no start to log")
            sheet.close()
        }
    }

    @Test func aSheetThatHoldsOnlyTheLogClosesWithoutAskingButADraftDoesAsk() throws {
        let fixture = try fixture()
        let sheet = fixture.sheet()
        sheet.offerStartLog()
        #expect(sheet.form.attachments.count == 1 && !sheet.state.hasContent)
        sheet.form.problem = "Too slow"
        #expect(sheet.state.hasContent)
        sheet.close()
    }

    // MARK: The sheet

    private func button(labelled label: String, in node: NSObject, depth: Int = 0) -> NSObject? {
        if node.accessibilityLabel == label, node.accessibilityTraits.contains(.button) { return node }
        guard depth < 64 else { return nil }
        var children = (node.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        if let view = node as? UIView { children += view.subviews }
        for child in children {
            if let found = button(labelled: label, in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// The sheet's own task makes the log, in the application as well as in the
    /// model's tests: the sheet the notice opens shows its row, and the row's
    /// button takes it out for good.
    @Test func theSheetTheNoticeOpensShowsTheLogRowAndRemovesIt() async throws {
        let fixture = try fixture()
        try fixture.writeRecord(output: Self.output)
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let host = AndariumHostingController(
            rootView: RootView(entry: AppEntry(overrides: LaunchOverrides())).environment(fixture.app), model: fixture.app)
        lease.window.rootViewController = host
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        fixture.app.feedbackFromBoot = true
        func row(_ present: Bool) async throws -> NSObject? {
            let deadline = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < deadline {
                let found = host.presentedViewController.flatMap { button(labelled: Self.removeLabel, in: $0.view) }
                if (found != nil) == present { return found }
                try await Task.sleep(for: .milliseconds(50))
            }
            return nil
        }
        guard let remove = try await row(true) else {
            Issue.record("the log's row was not found: is application accessibility on in this Simulator?")
            fixture.app.feedbackFromBoot = false
            return
        }
        #expect(remove.accessibilityActivate())
        #expect(try await row(false) == nil, "the row stays after its button was used")
        // The row is not made again when the sheet is laid out again.
        try await Task.sleep(for: .milliseconds(500))
        #expect(host.presentedViewController.flatMap { button(labelled: Self.removeLabel, in: $0.view) } == nil)
        fixture.app.feedbackFromBoot = false
        host.dismiss(animated: false)
    }

    // MARK: The start ends

    @Test func whenTheStartFinishesTheTipIsTheRunningOneAndTheLogStays() throws {
        let fixture = try fixture()
        try fixture.writeRecord(output: Self.output)
        let sheet = fixture.sheet()
        sheet.offerStartLog()
        #expect(sheet.state.tip == .starting && !sheet.state.canTakeScreenshot)
        fixture.app.finishBoot(.normal)
        #expect(sheet.state.tip == .running && !sheet.state.showsHowToReportBug)
        #expect(sheet.state.canTakeScreenshot, "the screenshot is available once the virtual machine runs")
        #expect(sheet.form.attachments.items.map(\.kind) == [.startLog])
        // The sheet's task does not run again for a running session, and if it did, no second log is made.
        sheet.offerStartLog()
        #expect(sheet.form.attachments.count == 1)
        sheet.close()
    }
}

#endif
