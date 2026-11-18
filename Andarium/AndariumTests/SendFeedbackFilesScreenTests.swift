// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import AndariumCore
import AndariumCoreTestSupport
import Darwin
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
import UIKit
@testable import Andarium

/// Files picked from Files in the Send feedback sheet, hosted in the
/// application: a file stays where it is under an access the sheet holds, a
/// file that cannot be used there is copied, and everything is let go of when
/// the attachment goes or the sheet closes. The system's picker is replaced by
/// an injected source of URLs, the access by counters, and the look at a file
/// by the real one or, where a provider's state is needed, a stand-in. They
/// run where Send feedback is compiled in (`FEEDBACK_ADDRESS` on the xcodebuild
/// command line).
@Suite(.serialized)
@MainActor
struct SendFeedbackFilesScreenTests {
    private let host = HostDevice(
        name: "iPhone", processorCount: 6, memory: MemoryPolicy(maximumsMiB: [4096]), freeStorageBytes: 41_000_000_000
    )
    private let mebibyte: UInt64 = 1 << 20

    private nonisolated final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        func release() { lock.withLock { open = true } }
        var isOpen: Bool { lock.withLock { open } }
        /// Waits until it is released, or 20 s: a test that never releases it fails on what it checks, and the suite goes on.
        func wait() {
            let deadline = ContinuousClock.now + .seconds(20)
            while !isOpen && ContinuousClock.now < deadline { usleep(2000) }
        }
    }

    /// What the stand-in for the system's access and look at a file saw.
    private nonisolated final class Access: @unchecked Sendable {
        private let lock = NSLock()
        private var started: [String] = []
        private var stopped: [String] = []
        private var away: Set<String> = []
        func start(_ url: URL) { lock.withLock { started.append(url.lastPathComponent) } }
        func stop(_ url: URL) { lock.withLock { stopped.append(url.lastPathComponent) } }
        var starts: [String] { lock.withLock { started } }
        var stops: [String] { lock.withLock { stopped } }
        /// Names the provider has not downloaded.
        func notDownloaded(_ name: String, _ gone: Bool = true) {
            lock.withLock {
                if gone { away.insert(name) } else { away.remove(name) }
            }
        }
        func isAway(_ name: String) -> Bool { lock.withLock { away.contains(name) } }
        private var typed: [String: UTType] = [:]
        /// The content type the provider gives a file, whatever its name.
        func gives(_ type: UTType, to name: String) { lock.withLock { typed[name] = type } }
        func type(of name: String) -> UTType? { lock.withLock { typed[name] } }
    }

    /// What a stand-in for the look at a file saw while it ran on its worker.
    private nonisolated final class Look: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var stopsSeen: Int?
        func begin() { lock.withLock { started = true } }
        var hasBegun: Bool { lock.withLock { started } }
        /// How many accesses had been let go as the file was read.
        func read(stops: Int) { lock.withLock { stopsSeen = stops } }
        var stopsWhenRead: Int? { lock.withLock { stopsSeen } }
    }

    private struct Fixture {
        let app: AppModel
        let composer: Composer
        let access: Access
        /// Where the staging folder is, and where the person's own files are.
        let root: URL
        let library: URL
        let staging: SendFeedbackStaging

        func sheet() -> SendFeedbackModel { SendFeedbackModel(app: app, staging: staging) }

        /// A file of the person's, in a folder of its own.
        func original(_ name: String, bytes: Int = 4096, fill: UInt8 = 7) throws -> URL {
            let url = library.appendingPathComponent(name)
            try Data(repeating: fill, count: bytes).write(to: url)
            return url
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor private final class Composer {
        var request: SendFeedbackMailRequest?
        private var finish: (@MainActor (SendFeedbackMailResult) -> Void)?
        func open(_ request: SendFeedbackMailRequest, _ finish: @escaping @MainActor (SendFeedbackMailResult) -> Void) {
            self.request = request
            self.finish = finish
        }
        func leave(_ result: SendFeedbackMailResult) {
            finish?(result)
            finish = nil
        }
    }

    private func fixture(free: UInt64? = nil, hold: Gate? = nil) throws -> Fixture {
        let system = SystemInfo(
            version: "17", release: "r2", kernel: "Linux 6.18", architecture: "arm64, 4 KB pages", appVersion: "1.0 (9)")
        let app = AppModel(
            guest: Guest.fresh(on: host), host: host, system: system, capabilities: .device, createRequirementBytes: 1)
        let driver = StubDriver(plan: .normal)
        app.driver = driver
        app.phase = .running(.normal)
        let composer = Composer()
        let access = Access()
        var services = SendFeedbackServices()
        services.address = { "feedback@example.com" }
        services.canSendMail = { true }
        services.presentMail = { request, finish in
            composer.open(request, finish)
            return true
        }
        services.captureScreen = { _ in Self.picture() }
        services.runningSeconds = { _ in 125 }
        services.files = SendFeedbackFileSystem(
            start: { url in
                access.start(url)
                return true
            },
            stop: { access.stop($0) },
            inspect: { url in
                var found = SendFeedbackFileInspection.read(url)
                if access.isAway(url.lastPathComponent) { found.isLocal = false }
                if let type = access.type(of: url.lastPathComponent) { found.contentType = type }
                return found
            })
        app.feedbackServices = services
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("andarium-feedback-files-\(UUID().uuidString)", isDirectory: true)
        let library = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let staging = SendFeedbackStaging(
            root: root.appendingPathComponent("staging", isDirectory: true),
            freeBytes: { _ in
                hold?.wait()
                return free
            })
        return Fixture(app: app, composer: composer, access: access, root: root, library: library, staging: staging)
    }

    private nonisolated static func picture() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 90, height: 160), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 90, height: 160))
        }
    }

    /// A poll that returns as soon as the condition holds; the 10 s is only its deadline.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// What the footprint grew by since `before`; a footprint that shrank grew by nothing.
    private func growth(since before: UInt64) -> UInt64 {
        let now = footprint()
        return now > before ? now - before : 0
    }

    private func size(of url: URL) -> UInt64 {
        UInt64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0)
    }

    private func isEmpty(_ folder: SendFeedbackFolder) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.url.path)) ?? []).isEmpty
    }

    // MARK: In place

    @Test func aPickedFileStaysWhereItIsIsNotCopiedAndHoldsItsAccess() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let file = try fixture.original("app-release.zip", bytes: 12_345)
        let sheet = fixture.sheet()
        sheet.form.problem = "Crash"
        sheet.form.details = "Details"
        await sheet.addFiles([file])
        let row = try #require(sheet.form.attachments.items.first)
        #expect(sheet.form.attachments.count == 1)
        #expect(row.kind == .file && row.inPlace && row.url == file && row.bytes == 12_345)
        #expect(row.displayName == "app-release.zip" && row.fileName == "app-release.zip")
        #expect(!sheet.folder.exists, "no copy: nothing was staged")
        #expect(!FileManager.default.fileExists(atPath: fixture.staging.root.path))
        #expect(fixture.access.starts == ["app-release.zip"] && fixture.access.stops.isEmpty && sheet.scopes.count == 1)
        #expect(sheet.thumbnails.isEmpty, "a plain file has no picture")
        #expect(!sheet.state.addingFiles && sheet.state.canSend && sheet.fileBusy == nil && sheet.failure == nil)
        sheet.close()
    }

    @Test func theFilesPickedAreAddedAtTheEndInTheOrderTheyCame() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let sheet = fixture.sheet()
        sheet.takeScreenshot()
        #expect(await eventually { sheet.form.attachments.count == 1 })
        await sheet.addFiles([try fixture.original("b.bin"), try fixture.original("a.bin")])
        #expect(sheet.form.attachments.items.map(\.kind) == [.screenshot, .file, .file])
        let stamp = SendFeedbackNames.stamp(sheet.form.attachments.items[0].madeAt)
        #expect(sheet.form.attachments.items.map(\.fileName) == ["screenshot-\(stamp).png", "b.bin", "a.bin"])
        sheet.close()
    }

    @Test func removingAFileLetsGoOfItsAccessAndNeverDeletesTheOriginal() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let file = try fixture.original("keep-me.zip", bytes: 2000, fill: 9)
        let sheet = fixture.sheet()
        await sheet.addFiles([file])
        sheet.remove(try #require(sheet.form.attachments.items.first))
        #expect(sheet.form.attachments.isEmpty && sheet.scopes.count == 0)
        #expect(fixture.access.starts == ["keep-me.zip"] && fixture.access.stops == ["keep-me.zip"])
        #expect(try Data(contentsOf: file) == Data(repeating: 9, count: 2000), "the person's file is still there, whole")
        sheet.close()
        #expect(fixture.access.stops.count == 1, "closed, nothing more to stop")
    }

    @Test func closingStopsEveryAccessOnceAndLeavesTheFilesAlone() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let one = try fixture.original("one.zip"), two = try fixture.original("two.zip")
        let sheet = fixture.sheet()
        await sheet.addFiles([one, two])
        sheet.remove(try #require(sheet.form.attachments.items.first))
        sheet.close()
        sheet.close()
        #expect(fixture.access.starts.sorted() == ["one.zip", "two.zip"])
        #expect(fixture.access.stops.sorted() == ["one.zip", "two.zip"], "each exactly once")
        #expect(FileManager.default.fileExists(atPath: one.path) && FileManager.default.fileExists(atPath: two.path))
    }

    @Test func aSheetLetGoWithoutClosingStillStopsItsAccess() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let file = try fixture.original("gone-with-the-sheet.zip")
        do {
            let sheet = fixture.sheet()
            await sheet.addFiles([file])
            #expect(fixture.access.stops.isEmpty)
        }
        #expect(await eventually { fixture.access.stops == ["gone-with-the-sheet.zip"] })
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aSentMailKeepsTheAccessUnderTheNoticeAndLetsGoOnceWhenTheSheetCloses() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let sheet = fixture.sheet()
        sheet.form.problem = "x"
        sheet.form.details = "Details"
        await sheet.addFiles([try fixture.original("sent.zip")])
        sheet.sendAnyway()
        #expect(fixture.access.stops.isEmpty, "the composer maps the file: the access stays until it is over")
        fixture.composer.leave(.sent)
        #expect(fixture.access.stops.isEmpty && sheet.scopes.count == 1, "the notice is over the list: the files wait for the close")
        sheet.close()
        #expect(fixture.access.stops == ["sent.zip"] && sheet.scopes.count == 0)
        sheet.close()
        sheet.applicationEnteredBackground()
        #expect(fixture.access.stops.count == 1, "each access is stopped once")
    }

    @Test func aSentMailLetsGoOfTheAccessAtOnceWhenTheApplicationLeavesTheForeground() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let sheet = fixture.sheet()
        sheet.form.problem = "x"
        sheet.form.details = "Details"
        await sheet.addFiles([try fixture.original("sent.zip")])
        sheet.applicationEnteredBackground()
        #expect(fixture.access.stops.isEmpty, "a draft that was not sent keeps its files in the background")
        sheet.sendAnyway()
        fixture.composer.leave(.sent)
        sheet.applicationEnteredBackground()
        #expect(fixture.access.stops == ["sent.zip"] && sheet.scopes.count == 0)
        #expect(sheet.form.attachments.count == 1, "the row under the notice stays")
        sheet.close()
        #expect(fixture.access.stops.count == 1)
    }

    @Test func aFileThePickerHandedUsTwiceIsAttachedTwiceWithNamesOfItsOwn() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let file = try fixture.original("app.zip")
        let sheet = fixture.sheet()
        await sheet.addFiles([file])
        await sheet.addFiles([file])
        #expect(sheet.form.attachments.items.map(\.fileName) == ["app.zip", "app-2.zip"])
        #expect(sheet.form.attachments.items.map(\.displayName) == ["app.zip", "app.zip"])
        #expect(fixture.access.starts.count == 2 && sheet.scopes.count == 2)
        sheet.remove(sheet.form.attachments.items[0])
        #expect(fixture.access.stops.count == 1 && FileManager.default.fileExists(atPath: file.path))
        sheet.close()
        #expect(fixture.access.stops.count == 2, "one stop for each start")
    }

    // MARK: Names

    @Test func theMailGetsASafeUniqueNameWhileTheRowKeepsTheName() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let sheet = fixture.sheet()
        sheet.form.problem = "x"
        sheet.form.details = "Details"
        sheet.takeScreenshot()
        #expect(await eventually { sheet.form.attachments.count == 1 })
        // The screenshot is named with the moment it was made; a file of the person's with that name,
        // whatever the letters' case, is numbered, not the screenshot.
        let stamp = SendFeedbackNames.stamp(sheet.form.attachments.items[0].madeAt)
        let clash = try fixture.original("Screenshot-\(stamp).PNG")
        let odd = try fixture.original("My App \u{5E94}\u{7528} (v2)\u{202E}.zip")
        await sheet.addFiles([clash, odd])
        sheet.sendAnyway()
        let request = try #require(fixture.composer.request)
        #expect(request.attachments.map(\.fileName) == [
            "screenshot-\(stamp).png", "Screenshot-\(stamp)-2.PNG", "My App \u{5E94}\u{7528} (v2)_.zip",
        ])
        #expect(request.attachments[1].url == clash && request.attachments[2].url == odd, "from where they are kept")
        #expect(request.attachments.map(\.displayName) == [nil, "Screenshot-\(stamp).PNG", "My App \u{5E94}\u{7528} (v2).zip"], "the row has no control characters")
        #expect(request.attachments[2].mimeType == "application/zip")
        sheet.close()
    }

    // MARK: Refusals

    @Test func aFolderAMissingFileAndAnEmptyFileAreRefusedEachForItsReason() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let folder = fixture.library.appendingPathComponent("Some Folder", isDirectory: true)
        let package = fixture.library.appendingPathComponent("Thing.app", isDirectory: true)
        for directory in [folder, package] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1]).write(to: directory.appendingPathComponent("inside.bin"))
        }
        let empty = try fixture.original("empty.txt", bytes: 0)
        let missing = fixture.library.appendingPathComponent("never-was.zip")
        let sheet = fixture.sheet()
        for (url, line) in [
            (folder, "A folder or a package can\u{2019}t be attached. Compress it in Files first."),
            (package, "A folder or a package can\u{2019}t be attached. Compress it in Files first."),
            (empty, "An empty file can\u{2019}t be attached."),
            (missing, "A file couldn\u{2019}t be read. Check that it is still in Files and downloaded, then try again."),
        ] {
            sheet.failure = nil
            await sheet.addFiles([url])
            #expect(sheet.form.attachments.isEmpty, "\(url.lastPathComponent)")
            #expect(sheet.failure?.title == "One item wasn\u{2019}t added" && sheet.failure?.message == line, "\(url.lastPathComponent)")
            #expect(!sheet.state.addingFiles && sheet.fileBusy == nil)
        }
        #expect(fixture.access.stops.sorted() == fixture.access.starts.sorted(), "a refused file's access is let go at once")
        #expect(sheet.scopes.count == 0)
        // Nothing of the folders is touched.
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("inside.bin").path))
        sheet.close()
    }

    @Test func severalRefusalsAreOneAlertWithALineForEachReasonAndTheGoodFileIsKept() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let folder = fixture.library.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sheet = fixture.sheet()
        await sheet.addFiles([
            folder, try fixture.original("empty.txt", bytes: 0), try fixture.original("good.zip"), folder,
        ])
        #expect(sheet.form.attachments.items.map(\.fileName) == ["good.zip"])
        #expect(sheet.failure?.title == "3 items weren\u{2019}t added")
        #expect(sheet.failure?.message == """
            A folder or a package can\u{2019}t be attached. Compress it in Files first.
            An empty file can\u{2019}t be attached.
            """)
        #expect(fixture.access.starts.count == 4 && fixture.access.stops.count == 3 && sheet.scopes.count == 1)
        sheet.close()
        #expect(fixture.access.stops.count == 4)
    }

    // MARK: Large files

    /// A file can be several gigabytes: added and given to the composer from where it is, with
    /// its size known, and not one byte of it in memory.
    @Test func aFileOfSeveralGiBIsAddedAndHandedOverWithoutBeingReadIntoMemory() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let big = fixture.library.appendingPathComponent("big.zip")
        try Data([0x50]).write(to: big)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: 3 << 30)
        try handle.close()
        let sheet = fixture.sheet()
        sheet.form.problem = "Big"
        sheet.form.details = "Details"
        let before = footprint()
        await sheet.addFiles([big])
        let row = try #require(sheet.form.attachments.items.first)
        #expect(row.bytes == 3 << 30 && sheet.state.attachments.exceedsWarningSize)
        #expect(sheet.state.canSend, "the warning never blocks Send")
        sheet.sendAnyway()
        let request = try #require(fixture.composer.request)
        let mapped = try #require(request.mapped.first, "the composer is given the file mapped")
        #expect(request.mapped.count == 1 && mapped.count == 3 << 30 && mapped[0] == 0x50)
        let grown = growth(since: before)
        #expect(grown < 1536 * mebibyte, "\(grown / mebibyte) MiB grew for a 3 GiB file")
        #expect(!sheet.folder.exists)
        sheet.close()
    }

    // MARK: A file that cannot be used where it is

    @Test func aFileNotDownloadedIsCopiedAndItsAccessLetGoRightAfter() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let file = try fixture.original("cloud.zip", bytes: 70_000, fill: 3)
        fixture.access.notDownloaded("cloud.zip")
        let sheet = fixture.sheet()
        await sheet.addFiles([file])
        let row = try #require(sheet.form.attachments.items.first)
        #expect(row.kind == .file && !row.inPlace && row.bytes == 70_000)
        #expect(row.url.deletingLastPathComponent().resolvingSymlinksInPath() == sheet.folder.url.resolvingSymlinksInPath())
        #expect(try Data(contentsOf: row.url) == Data(repeating: 3, count: 70_000))
        #expect(row.displayName == "cloud.zip" && row.fileName == "cloud.zip")
        #expect(try Data(contentsOf: file) == Data(repeating: 3, count: 70_000), "the original is untouched")
        #expect(fixture.access.starts == ["cloud.zip"] && fixture.access.stops == ["cloud.zip"], "released once the copy was made")
        #expect(sheet.scopes.count == 0 && sheet.fileBusy == nil && !sheet.state.addingFiles)
        // Removing a copy deletes the copy, not the original.
        sheet.remove(row)
        #expect(!FileManager.default.fileExists(atPath: row.url.path) && FileManager.default.fileExists(atPath: file.path))
        #expect(fixture.access.stops.count == 1)
        sheet.close()
    }

    @Test func theCopyShowsTheOverlayWithProgressAndCancelAndSendWaits() async throws {
        let gate = Gate()
        let fixture = try fixture(hold: gate)
        defer {
            gate.release()
            fixture.tearDown()
        }
        fixture.access.notDownloaded("slow.zip")
        let sheet = fixture.sheet()
        sheet.form.problem = "x"
        sheet.form.details = "Details"
        let file = try fixture.original("slow.zip")
        let adding = Task { await sheet.addFiles([file]) }
        #expect(await eventually { sheet.fileBusy != nil })
        let busy = try #require(sheet.fileBusy)
        #expect(busy.title == "Copying file" && busy.progress == 0 && busy.cancel != nil && busy.result == nil)
        #expect(sheet.state.addingFiles && !sheet.state.canSend && !sheet.state.canAddFiles)
        sheet.sendAnyway()
        #expect(fixture.composer.request == nil, "Send waits for the files it will carry")
        gate.release()
        await adding.value
        #expect(sheet.fileBusy == nil && sheet.form.attachments.count == 1 && sheet.state.canSend)
        sheet.close()
    }

    @Test func cancellingTheCopyRemovesWhatWasCopiedAndSaysNothing() async throws {
        let gate = Gate()
        let fixture = try fixture(hold: gate)
        defer {
            gate.release()
            fixture.tearDown()
        }
        fixture.access.notDownloaded("big.zip")
        let sheet = fixture.sheet()
        let file = try fixture.original("big.zip", bytes: 3_000_000)
        let later = try fixture.original("later.zip")
        let adding = Task { await sheet.addFiles([file, later]) }
        #expect(await eventually { sheet.fileBusy != nil })
        try #require(sheet.fileBusy?.cancel).action()
        gate.release()
        await adding.value
        #expect(sheet.form.attachments.isEmpty, "the rest of the batch is not added either")
        #expect(sheet.failure == nil && sheet.fileBusy == nil && !sheet.state.addingFiles)
        #expect(!sheet.folder.exists || isEmpty(sheet.folder), "no partial copy")
        #expect(fixture.access.starts == ["big.zip"] && fixture.access.stops == ["big.zip"])
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(sheet.state.canAddFiles, "the person can try again")
        sheet.close()
    }

    @Test func aCopyThatDoesNotFitIsRefusedWithTheRoomMessageAndLeavesNothing() async throws {
        let fixture = try fixture(free: 1000)
        defer { fixture.tearDown() }
        fixture.access.notDownloaded("huge.zip")
        let file = try fixture.original("huge.zip", bytes: 5000)
        let sheet = fixture.sheet()
        await sheet.addFiles([file])
        #expect(sheet.form.attachments.isEmpty)
        #expect(sheet.failure?.title == "One item wasn\u{2019}t added")
        #expect(sheet.failure?.message == "There isn\u{2019}t enough free space on this iPhone. Free up space, then try again.")
        #expect(!sheet.folder.exists, "no file, no folder")
        #expect(fixture.access.starts == ["huge.zip"] && fixture.access.stops == ["huge.zip"])
        #expect(FileManager.default.fileExists(atPath: file.path))
        sheet.close()
    }

    @Test func aFileThatIsGoneBeforeItsCopyStartsIsReadAsUnavailable() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        // The inspection says the bytes are not here; the provider then fails to give the file.
        let file = fixture.library.appendingPathComponent("vanishing.zip")
        try Data(repeating: 1, count: 100).write(to: file)
        fixture.app.feedbackServices.files.inspect = { _ in
            SendFeedbackFileInspection(kind: .file, bytes: 100, isLocal: false, mappable: true)
        }
        try FileManager.default.removeItem(at: file)
        let sheet = fixture.sheet()
        await sheet.addFiles([file])
        #expect(sheet.failure?.message == "A file couldn\u{2019}t be read. Check that it is still in Files and downloaded, then try again.")
        #expect(sheet.form.attachments.isEmpty && (!sheet.folder.exists || isEmpty(sheet.folder)))
        #expect(fixture.access.stops.count == 1)
        sheet.close()
    }

    @Test func closingTheSheetUnderACopyStopsItAndLeavesNothing() async throws {
        let gate = Gate()
        let fixture = try fixture(hold: gate)
        defer {
            gate.release()
            fixture.tearDown()
        }
        fixture.access.notDownloaded("mid.zip")
        let sheet = fixture.sheet()
        let file = try fixture.original("mid.zip")
        let adding = Task { await sheet.addFiles([file]) }
        #expect(await eventually { sheet.fileBusy != nil })
        sheet.close()
        gate.release()
        await adding.value
        #expect(sheet.form.attachments.isEmpty && sheet.failure == nil && !sheet.folder.exists)
        #expect(fixture.access.stops == ["mid.zip"] && sheet.scopes.count == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Between the pick and Send

    @Test func aFileDeletedBeforeSendIsTakenOutAndNothingIsSent() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let keep = try fixture.original("keep.zip"), lose = try fixture.original("lose.zip")
        let sheet = fixture.sheet()
        sheet.form.problem = "x"
        sheet.form.details = "Details"
        await sheet.addFiles([keep, lose])
        try FileManager.default.removeItem(at: lose)
        sheet.sendAnyway()
        #expect(fixture.composer.request == nil, "a mail never goes without a file the person added, unseen")
        #expect(sheet.form.attachments.items.map(\.fileName) == ["keep.zip"])
        #expect(sheet.failure?.title == "Attachment not available")
        #expect(sheet.failure?.message == "An attachment is no longer available, so it was taken out of the list. Check the list, then send again.")
        #expect(fixture.access.stops == ["lose.zip"] && sheet.form.problem == "x")
        sheet.failure = nil
        sheet.sendAnyway()
        #expect(fixture.composer.request?.attachments.map(\.fileName) == ["keep.zip"], "the second try goes")
        #expect(fixture.composer.request?.mapped == [Data(repeating: 7, count: 4096)])
        sheet.close()
    }

    @Test func aFileTheProviderTookBackBeforeSendIsTakenOutToo() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let file = try fixture.original("evicted.zip")
        let sheet = fixture.sheet()
        sheet.form.problem = "x"
        sheet.form.details = "Details"
        await sheet.addFiles([file])
        fixture.access.notDownloaded("evicted.zip")
        sheet.sendAnyway()
        #expect(fixture.composer.request == nil && sheet.form.attachments.isEmpty)
        #expect(sheet.failure?.title == "Attachment not available")
        #expect(fixture.access.stops == ["evicted.zip"] && FileManager.default.fileExists(atPath: file.path))
        sheet.close()
    }

    @Test func aFileThatChangedBeforeSendGoesAsItIsNowWithItsNewSize() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let file = try fixture.original("rebuilt.zip", bytes: 1000, fill: 1)
        let sheet = fixture.sheet()
        sheet.form.problem = "x"
        sheet.form.details = "Details"
        await sheet.addFiles([file])
        try Data(repeating: 2, count: 21 << 20).write(to: file)
        sheet.sendAnyway()
        let request = try #require(fixture.composer.request)
        let sent = try #require(request.attachments.first)
        #expect(sent.bytes == 21 << 20 && sheet.form.attachments.items[0].bytes == 21 << 20)
        #expect(sheet.state.attachments.exceedsWarningSize, "the total and the warning follow the file")
        #expect(request.mapped.first?.prefix(4) == Data(repeating: 2, count: 4))
        #expect(sheet.failure == nil)
        sheet.close()
    }

    @Test func aFileThatBecameEmptyBeforeSendIsTakenOut() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let file = try fixture.original("emptied.zip")
        let sheet = fixture.sheet()
        sheet.form.problem = "x"
        sheet.form.details = "Details"
        await sheet.addFiles([file])
        try Data().write(to: file)
        sheet.sendAnyway()
        #expect(fixture.composer.request == nil && sheet.form.attachments.isEmpty)
        #expect(sheet.failure?.title == "Attachment not available")
        sheet.close()
    }

    @Test func aStagedFileTheSystemTookAwayIsAlsoSaidNotSilentlyLeftOut() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let sheet = fixture.sheet()
        sheet.form.problem = "x"
        sheet.form.details = "Details"
        sheet.takeScreenshot()
        #expect(await eventually { sheet.form.attachments.count == 1 })
        try FileManager.default.removeItem(at: sheet.form.attachments.items[0].url)
        sheet.sendAnyway()
        #expect(fixture.composer.request == nil && sheet.form.attachments.isEmpty)
        #expect(sheet.failure?.title == "Attachment not available")
        sheet.close()
    }

    // MARK: Interleavings

    @Test func aFileThatCannotBeMappedAfterTheLastLookIsTakenOutAndNothingIsSent() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let keep = try fixture.original("keep.zip"), lose = try fixture.original("lose.zip")
        let sheet = fixture.sheet()
        sheet.form.problem = "x"
        sheet.form.details = "Details"
        await sheet.addFiles([keep, lose])
        // Send's own look finds `lose` as it should be, and the file is gone right after it: the mapping is what finds out.
        let look = fixture.app.feedbackServices.files.inspect
        fixture.app.feedbackServices.files.inspect = { url in
            let found = look(url)
            if url.lastPathComponent == "lose.zip" { try? FileManager.default.removeItem(at: url) }
            return found
        }
        sheet.sendAnyway()
        #expect(fixture.composer.request == nil, "a mail never goes without a file the person added, unseen")
        #expect(sheet.form.attachments.items.map(\.fileName) == ["keep.zip"])
        #expect(sheet.failure?.title == "Attachment not available")
        #expect(fixture.access.stops == ["lose.zip"] && sheet.scopes.count == 1 && sheet.form.problem == "x")
        #expect(FileManager.default.fileExists(atPath: keep.path))
        // Looking at the list again, the person sends the rest.
        fixture.app.feedbackServices.files.inspect = look
        sheet.failure = nil
        sheet.sendAnyway()
        #expect(fixture.composer.request?.attachments.map(\.fileName) == ["keep.zip"])
        #expect(fixture.composer.request?.mapped == [Data(repeating: 7, count: 4096)])
        sheet.close()
    }

    @Test func closingWhileAFileIsBeingLookedAtKeepsItsAccessUntilTheLookEnds() async throws {
        let gate = Gate()
        let fixture = try fixture()
        defer {
            gate.release()
            fixture.tearDown()
        }
        let file = try fixture.original("looking.zip")
        let probe = Look()
        let access = fixture.access
        let read = fixture.app.feedbackServices.files.inspect
        fixture.app.feedbackServices.files.inspect = { url in
            probe.begin()
            gate.wait()
            probe.read(stops: access.stops.count)
            return read(url)
        }
        let sheet = fixture.sheet()
        let adding = Task { await sheet.addFiles([file]) }
        #expect(await eventually { probe.hasBegun })
        sheet.close()
        #expect(fixture.access.stops.isEmpty, "the look is still reading the file: its access stays")
        gate.release()
        await adding.value
        #expect(probe.stopsWhenRead == 0, "the file was read under its access")
        #expect(fixture.access.stops == ["looking.zip"], "let go once, when the look ended")
        #expect(sheet.scopes.count == 0 && sheet.form.attachments.isEmpty && sheet.failure == nil && !sheet.folder.exists)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aCopyThatFinishedAfterCancelWasPressedIsNotAdded() async throws {
        let gate = Gate()
        let fixture = try fixture(hold: gate)
        defer {
            gate.release()
            fixture.tearDown()
        }
        fixture.access.notDownloaded("late.zip")
        let sheet = fixture.sheet()
        let file = try fixture.original("late.zip", bytes: 70_000)
        let adding = Task { await sheet.addFiles([file]) }
        #expect(await eventually { sheet.fileBusy != nil })
        let cancel = try #require(sheet.fileBusy?.cancel)
        gate.release()
        // From here the main actor is held, so the task that waits for the copy is not resumed: the copy is
        // made and has returned by the time Cancel is pressed, which is the order a busy main actor makes.
        let staged = sheet.folder.url.appendingPathComponent("late.zip")
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline && size(of: staged) != 70_000 { usleep(2000) }
        #expect(size(of: staged) == 70_000, "the copy is complete before Cancel")
        usleep(300_000)  // The copy's return, which no flag shows.
        cancel.action()
        await adding.value
        #expect(sheet.form.attachments.isEmpty, "what the person stopped is not added")
        #expect(!sheet.folder.exists || isEmpty(sheet.folder), "and its copy is removed")
        #expect(sheet.failure == nil && sheet.fileBusy == nil && !sheet.state.addingFiles && sheet.state.canAddFiles)
        #expect(fixture.access.starts == ["late.zip"] && fixture.access.stops == ["late.zip"])
        #expect(FileManager.default.fileExists(atPath: file.path))
        sheet.close()
    }

    @Test func aBatchThatArrivesWhileAnotherIsTakenInIsTurnedAwayAndTheFirstKeepsItsCancel() async throws {
        let gate = Gate()
        let fixture = try fixture(hold: gate)
        defer {
            gate.release()
            fixture.tearDown()
        }
        fixture.access.notDownloaded("first.zip")
        let sheet = fixture.sheet()
        let first = try fixture.original("first.zip", bytes: 3_000_000)
        let second = try fixture.original("second.zip")
        let adding = Task { await sheet.addFiles([first]) }
        #expect(await eventually { sheet.fileBusy != nil })
        let cancel = try #require(sheet.fileBusy?.cancel)
        await sheet.addFiles([second])
        #expect(sheet.form.attachments.isEmpty && fixture.access.starts == ["first.zip"], "the second batch is not taken in")
        #expect(sheet.state.addingFiles && sheet.fileBusy != nil, "the first is still under its overlay")
        // Cancel is still the first batch's: it stops the copy.
        cancel.action()
        gate.release()
        await adding.value
        #expect(sheet.form.attachments.isEmpty && sheet.failure == nil && !sheet.state.addingFiles)
        #expect(!sheet.folder.exists || isEmpty(sheet.folder), "no partial copy")
        #expect(fixture.access.starts == ["first.zip"] && fixture.access.stops == ["first.zip"])
        sheet.close()
    }

    @Test func cancellingACopyKeepsWhatWasAttachedBeforeItAndDropsTheFilesThatWereNotTakenIn() async throws {
        let gate = Gate()
        let fixture = try fixture(hold: gate)
        defer {
            gate.release()
            fixture.tearDown()
        }
        fixture.access.notDownloaded("slow.zip")
        let sheet = fixture.sheet()
        let kept = try fixture.original("kept.zip")
        let slow = try fixture.original("slow.zip", bytes: 3_000_000)
        let later = try fixture.original("later.zip")
        let adding = Task { await sheet.addFiles([kept, slow, later]) }
        #expect(await eventually { sheet.fileBusy != nil })
        try #require(sheet.fileBusy?.cancel).action()
        gate.release()
        await adding.value
        #expect(sheet.form.attachments.items.map(\.fileName) == ["kept.zip"], "what was attached before stays")
        #expect(fixture.access.starts == ["kept.zip", "slow.zip"], "the file after the copy was never looked at")
        #expect(fixture.access.stops == ["slow.zip"] && sheet.scopes.count == 1, "the kept file keeps its access")
        #expect(sheet.failure == nil && !sheet.state.addingFiles && (!sheet.folder.exists || isEmpty(sheet.folder)))
        sheet.close()
        #expect(fixture.access.stops.sorted() == ["kept.zip", "slow.zip"])
    }

    @Test func severalAttachmentsThatAreGoneAtSendAreSaidTogetherWithTheirCount() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let keep = try fixture.original("keep.zip"), one = try fixture.original("one.zip"), two = try fixture.original("two.zip")
        let sheet = fixture.sheet()
        sheet.form.problem = "x"
        sheet.form.details = "Details"
        await sheet.addFiles([keep, one, two])
        try FileManager.default.removeItem(at: one)
        try FileManager.default.removeItem(at: two)
        sheet.sendAnyway()
        #expect(fixture.composer.request == nil && sheet.form.attachments.items.map(\.fileName) == ["keep.zip"])
        #expect(sheet.failure?.title == "Attachments not available")
        #expect(sheet.failure?.message == "2 attachments are no longer available, so they were taken out of the list. Check the list, then send again.")
        #expect(fixture.access.stops.sorted() == ["one.zip", "two.zip"])
        sheet.close()
    }

    @Test func aNameInChineseOrJapaneseIsTheNameOfTheFileInTheMailAndTheRow() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let chinese = try fixture.original("\u{6D4B}\u{8BD5}\u{5E94}\u{7528}.zip")
        let japanese = try fixture.original("\u{30C6}\u{30B9}\u{30C8}\u{30A2}\u{30D7}\u{30EA}.zip")
        let sheet = fixture.sheet()
        sheet.form.problem = "x"
        sheet.form.details = "Details"
        await sheet.addFiles([chinese, japanese])
        sheet.sendAnyway()
        let request = try #require(fixture.composer.request)
        #expect(request.attachments.map(\.fileName) == ["\u{6D4B}\u{8BD5}\u{5E94}\u{7528}.zip", "\u{30C6}\u{30B9}\u{30C8}\u{30A2}\u{30D7}\u{30EA}.zip"])
        #expect(request.attachments.map(\.displayName) == request.attachments.map(\.fileName))
        #expect(request.attachments.allSatisfy { $0.mimeType == "application/zip" })
        sheet.close()
    }

    // MARK: The picker

    @Test func pickingFilesOpensThePickerAndWhatItReturnsIsAdded() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        var deliver: (@MainActor ([URL]) -> Void)?
        var opened = 0
        fixture.app.feedbackServices.pickFiles = { picked in
            opened += 1
            deliver = picked
            return true
        }
        let sheet = fixture.sheet()
        sheet.pickFiles()
        #expect(opened == 1)
        deliver?([try fixture.original("picked.zip")])
        #expect(await eventually { sheet.form.attachments.count == 1 })
        #expect(sheet.form.attachments.items[0].inPlace)
        // Nothing opens while something else is under way.
        sheet.form.takingScreenshot = true
        sheet.pickFiles()
        #expect(opened == 1)
        sheet.form.takingScreenshot = false
        sheet.close()
    }

    // MARK: Android packages

    private static let packageTitle = "APK files can\u{2019}t be sent by mail"
    private static let packageOne = "Mail services reject messages that carry an APK, so this file was not attached. "
        + "Paste a download link for the app in the details instead."
    private static let packageMany = "Mail services reject messages that carry an APK, so these files were not attached. "
        + "Paste a download link for the app in the details instead."

    @Test(arguments: ["app.apk", "App.APK", "bundle.apks", "bundle.XAPK", "bundle.apkm", "my.app.release.v2.apk"])
    func anAndroidPackageIsNeverAttachedAndTheAlertSaysWhyAndAsksForALink(name: String) async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let file = try fixture.original(name, bytes: 5000)
        let sheet = fixture.sheet()
        await sheet.addFiles([file])
        #expect(sheet.form.attachments.isEmpty && !sheet.form.addingFiles)
        #expect(sheet.failure?.title == Self.packageTitle && sheet.failure?.message == Self.packageOne)
        #expect(sheet.failure?.focusesDetails == true, "the details are ready for the link once the alert closes")
        // The person's file is left alone, the access the pick carried is let go, and nothing was copied.
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(fixture.access.starts == [name] && fixture.access.stops == [name] && sheet.scopes.count == 0)
        #expect(!sheet.folder.exists)
        sheet.close()
    }

    @Test func aPackageTypedAsOneByItsProviderIsRefusedWhateverItsNameIs() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let file = try fixture.original("installer")
        fixture.access.gives(try #require(UTType(mimeType: "application/vnd.android.package-archive")), to: "installer")
        let sheet = fixture.sheet()
        await sheet.addFiles([file])
        #expect(sheet.form.attachments.isEmpty && sheet.failure?.title == Self.packageTitle)
        sheet.close()
    }

    @Test func filesWhoseNamesOnlyContainApkAreAttachedLikeAnyOther() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let names = ["apk.txt", "myapk", "app.apk.zip", "notes on apk", "bundle.apks.bak"]
        let sheet = fixture.sheet()
        await sheet.addFiles(try names.map { try fixture.original($0) })
        #expect(sheet.form.attachments.items.map(\.fileName) == names)
        #expect(sheet.failure == nil)
        sheet.close()
    }

    @Test func aMixedPickAttachesTheOtherFilesInOrderAndOneAlertNamesThePackage() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let sheet = fixture.sheet()
        await sheet.addFiles([
            try fixture.original("trace.zip"), try fixture.original("app.apk"), try fixture.original("notes.txt"),
        ])
        #expect(sheet.form.attachments.items.map(\.fileName) == ["trace.zip", "notes.txt"])
        #expect(sheet.failure?.title == Self.packageTitle && sheet.failure?.message == Self.packageOne)
        // The mail carries what was attached and never a package.
        sheet.form.problem = "x"
        sheet.form.details = "y"
        sheet.sendAnyway()
        #expect(fixture.composer.request?.attachments.map(\.fileName) == ["trace.zip", "notes.txt"])
        sheet.close()
    }

    @Test func severalPackagesInOnePickAreOneAlertInThePlural() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let sheet = fixture.sheet()
        await sheet.addFiles([
            try fixture.original("a.apk"), try fixture.original("b.apks"), try fixture.original("c.xapk"),
            try fixture.original("d.apkm"),
        ])
        #expect(sheet.form.attachments.isEmpty)
        #expect(sheet.failure?.title == Self.packageTitle && sheet.failure?.message == Self.packageMany)
        #expect(sheet.failure?.focusesDetails == true)
        sheet.close()
    }

    @Test func packagesBesideOtherRefusalsAreOneAlertWithALineEach() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let folder = fixture.library.appendingPathComponent("A Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sheet = fixture.sheet()
        await sheet.addFiles([folder, try fixture.original("empty.txt", bytes: 0), try fixture.original("app.apk")])
        #expect(sheet.failure?.title == "3 items weren\u{2019}t added")
        #expect(sheet.failure?.message == [
            "A folder or a package can\u{2019}t be attached. Compress it in Files first.",
            "An empty file can\u{2019}t be attached.", Self.packageOne,
        ].joined(separator: "\n"))
        #expect(sheet.failure?.focusesDetails == true)
        // Without a package the alert asks for nothing more.
        await sheet.addFiles([folder])
        #expect(sheet.failure?.focusesDetails == false)
        sheet.close()
    }

    @Test func aDraftThatAlreadyListsAPackageLosesItAsTheSheetOpensWithTheSameAlert() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let sheet = fixture.sheet()
        // A draft an earlier build made: a staged package, one kept where it is, and an ordinary file.
        let staged = try sheet.folder.reserve("old.apk")
        try Data([1, 2, 3]).write(to: staged)
        sheet.form.attachments.add(SendFeedbackAttachment(kind: .file, url: staged, bytes: 3, displayName: "old.apk"))
        let kept = try fixture.original("older.APKS")
        sheet.form.attachments.add(SendFeedbackAttachment(
            kind: .file, url: kept, bytes: 4096, displayName: "older.APKS", inPlace: true))
        sheet.form.attachments.add(SendFeedbackAttachment(
            kind: .file, url: try fixture.original("trace.zip"), bytes: 4096, displayName: "trace.zip", inPlace: true))
        sheet.refuseAndroidPackagesInDraft()
        #expect(sheet.form.attachments.items.map(\.displayName) == ["trace.zip"])
        #expect(!FileManager.default.fileExists(atPath: staged.path), "the staged copy goes")
        #expect(FileManager.default.fileExists(atPath: kept.path), "the person's own file stays")
        #expect(sheet.failure?.title == Self.packageTitle && sheet.failure?.message == Self.packageMany)
        // A draft without one is left alone, and so is the second look.
        sheet.failure = nil
        sheet.refuseAndroidPackagesInDraft()
        #expect(sheet.failure == nil && sheet.form.attachments.count == 1)
        sheet.close()
    }

    /// The alert as the system draws it, over the sheet: the title, the text, one OK; once, however many were
    /// picked. OK leaves the details ready to type in.
    @Test func theAlertIsOneOKOverTheSheetAndLeavesTheDetailsReady() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let packages = [try fixture.original("a.apk"), try fixture.original("b.apks"), try fixture.original("c.apkm")]
        let log = try fixture.original("trace.zip")
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let controller = hostSheet(fixture, in: lease) { model in
            model.form.problem = "The app closes"
            model.form.details = "It closes after a second."
            await model.addFiles([log] + packages)
        }
        var alert: UIAlertController?
        let shown = await eventually {
            alert = controller.presentedViewController as? UIAlertController
            return alert != nil
        }
        try #require(shown, "the alert was not presented; is ApplicationAccessibilityEnabled on?")
        #expect(alert?.title == Self.packageTitle)
        #expect(alert?.message == Self.packageMany)
        #expect(alert?.actions.map(\.title) == ["OK"])
        // OK closes it, nothing else comes up, and the focus goes to the details.
        let action = try #require(alert?.actions.first)
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        let handler = unsafeBitCast(try #require(action.value(forKey: "handler") as AnyObject?), to: Handler.self)
        handler(action)
        alert?.dismiss(animated: false)
        #expect(await eventually { controller.presentedViewController == nil })
        try await Task.sleep(for: .milliseconds(500))
        #expect(controller.presentedViewController == nil, "one alert for the whole pick")
        let details = await eventually {
            (self.firstResponder(in: controller.view) as? UITextView)?.text == "It closes after a second."
        }
        #expect(details, "the details take the focus once the alert is closed")
    }

    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let found = firstResponder(in: subview) { return found }
        }
        return nil
    }

    // MARK: The sheet as it is drawn

    private func nodes(in node: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 64 else { return [] }
        var children = (node.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        if let view = node as? UIView { children += view.subviews }
        return [node] + children.flatMap { nodes(in: $0, depth: depth + 1) }
    }

    /// The node VoiceOver reads under `label`. Labels are what a person gets; an identifier is not
    /// always published for every node of the hosted tree.
    private func element(labelled label: String, in root: UIView) -> NSObject? {
        nodes(in: root).first { $0.accessibilityLabel == label }
    }

    /// The sheet on the application's window, the way a person meets it. A hook of the preview opens it
    /// on a state; the picker is the injected source of URLs.
    private func hostSheet(
        _ fixture: Fixture, in lease: HostWindow.Lease, prepare: @escaping @MainActor (SendFeedbackModel) async -> Void = { _ in }
    ) -> UIHostingController<some View> {
        fixture.app.feedbackServices.previewPrepare = prepare
        let controller = UIHostingController(
            rootView: SendFeedbackSheet(app: fixture.app).environment(fixture.app).frame(width: 390, height: 844))
        lease.window.rootViewController = controller
        controller.view.layoutIfNeeded()
        return controller
    }

    @Test func theBarHasOneAddButtonAndTheRowOfAPickedFileAppearsWithItsLabelsAndCanBeRemoved() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let file = try fixture.original("example-app.zip", bytes: 25 << 20)
        var deliver: (@MainActor ([URL]) -> Void)?
        fixture.app.feedbackServices.pickFiles = { picked in
            deliver = picked
            return true
        }
        let lease = try await HostWindow.take()
        defer { lease.give() }
        // The sheet's own model: the Files item of the Add menu is the system's, and calls this.
        var shown: SendFeedbackModel?
        let controller = hostSheet(fixture, in: lease, prepare: { shown = $0 })
        var add: NSObject?
        let drawn = await eventually {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            add = element(labelled: "Add a photo or a file", in: controller.view)
            return add != nil && shown != nil
        }
        try #require(drawn, "the sheet was not drawn; is ApplicationAccessibilityEnabled on?")
        #expect(add?.accessibilityTraits.contains(.button) == true, "the Add button is a button")
        for removed in ["Photos", "Files", "Add files", "Add photos or videos"] {
            #expect(element(labelled: removed, in: controller.view) == nil, "\(removed) is in the menu, not on the bar")
        }
        shown?.pickFiles()
        #expect(await eventually { deliver != nil }, "the Files item opens the injected picker")
        deliver?([file])
        let row = "File, example-app.zip, 25 MiB"
        let attached = await eventually {
            controller.view.layoutIfNeeded()
            return element(labelled: row, in: controller.view) != nil
        }
        try #require(attached, "the row was not drawn with its labels")
        // The sizes are written with a no-break space before the unit.
        let words = nodes(in: controller.view).compactMap(\.accessibilityLabel)
            .map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
        #expect(words.contains { $0.contains("1 attachment") && $0.contains("25 MiB") && $0.contains("20 MiB") },
                "the total and the warning for 25 MiB: \(words)")
        let remove = try #require(element(labelled: "Remove file", in: controller.view))
        _ = remove.accessibilityActivate()
        #expect(await eventually {
            controller.view.layoutIfNeeded()
            return element(labelled: row, in: controller.view) == nil
        }, "removing the row takes it out")
        #expect(FileManager.default.fileExists(atPath: file.path), "the file itself stays")
    }

    @Test func theCopyingCardIsModalForVoiceOverAndSaysWhatItDoes() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let state = SendFeedbackModel.copyingState(progress: 0.42, cancel: BusyCancel {})
        let controller = UIHostingController(rootView: BusyOverlay(state: state).environment(fixture.app).frame(width: 390, height: 844))
        lease.window.rootViewController = controller
        controller.view.layoutIfNeeded()
        var modal = false
        let drawn = await eventually {
            controller.view.layoutIfNeeded()
            modal = nodes(in: controller.view).contains { $0.accessibilityViewIsModal }
            return element(labelled: "Cancel", in: controller.view) != nil
        }
        try #require(drawn, "the card was not drawn; is ApplicationAccessibilityEnabled on?")
        #expect(modal, "VoiceOver reaches nothing behind the card")
        #expect(state.title == "Copying file" && state.detail.hasPrefix("Andarium makes its own copy of this file"))
    }

    @Test func theAlertSaysEachReasonOnItsOwnLine() async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let folder = fixture.library.appendingPathComponent("A Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let empty = try fixture.original("empty.txt", bytes: 0)
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let controller = hostSheet(fixture, in: lease) { model in await model.addFiles([folder, empty]) }
        var alert: UIAlertController?
        let shown = await eventually {
            alert = controller.presentedViewController as? UIAlertController
            return alert != nil
        }
        try #require(shown, "the alert was not presented")
        #expect(alert?.title == "2 items weren\u{2019}t added")
        #expect(alert?.message == """
            A folder or a package can\u{2019}t be attached. Compress it in Files first.
            An empty file can\u{2019}t be attached.
            """)
        #expect(alert?.actions.map(\.title) == ["OK"])
    }

    /// Send with the problem or the details empty: no composer, and the system's alert over the sheet says
    /// which. A file or the start log in the draft is neither.
    @Test(arguments: [
        ("", "", "Write what went wrong in the Problem line, and describe what you did and what happened, then send again."),
        ("", "It stops.", "Write what went wrong in the Problem line, then send again."),
        ("Game freezes", " \n ", "Describe what you did and what happened, then send again."),
    ])
    func sendWithAFieldEmptyOpensNoMailAndAnAlertSaysWhichIsMissing(
        problem: String, details: String, message: String
    ) async throws {
        let fixture = try fixture()
        defer { fixture.tearDown() }
        let file = try fixture.original("example-app.zip", bytes: 1 << 20)
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let controller = hostSheet(fixture, in: lease) { model in
            // A file is in the draft: it is not a problem and not details.
            await model.addFiles([file])
            model.form.problem = problem
            model.form.details = details
            model.sendAnyway()
        }
        var alert: UIAlertController?
        let shown = await eventually {
            alert = controller.presentedViewController as? UIAlertController
            return alert != nil
        }
        try #require(shown, "the alert was not presented")
        #expect(alert?.title == "Can\u{2019}t send yet")
        #expect(alert?.message == message)
        #expect(alert?.actions.map(\.title) == ["OK"])
        #expect(fixture.composer.request == nil, "no mail composer opens")
    }

    @Test func theRowSpeaksItsKindItsNameAndItsSizeAndFilesHaveTheirOwnWords() {
        let file = SendFeedbackAttachment(
            kind: .file, url: URL(fileURLWithPath: "/Files/a b.zip"), bytes: 2_097_152, displayName: "a b.zip", inPlace: true)
        #expect(SendFeedbackSheet.spoken(file) == "File, a b.zip, 2 MiB")
        let nameless = SendFeedbackAttachment(
            kind: .file, url: URL(fileURLWithPath: "/Files/x.bin"), bytes: 10, mailName: "x.bin", inPlace: true)
        #expect(SendFeedbackSheet.spoken(nameless) == "File, x.bin, 10 B")
        #expect(String(localized: SendFeedbackSheet.removeLabel(.file)) == "Remove file")
        #expect(SendFeedbackSheet.detail(file) == "2 MiB", "a file shows no picture size and no length")
        #expect(SendFeedbackSheet.symbol(.file) == "doc.fill")
    }

    /// Reads the deprecated mode on purpose: it is the only way to see that the picker opens in place.
    @available(iOS, deprecated: 14.0, message: "reads the picker's mode, which has no other accessor")
    @Test func thePickerOpensFilesWhereTheyAreKeptAndAllowsSeveral() {
        let picker = SendFeedbackFilePicker.makePicker()
        #expect(picker.allowsMultipleSelection)
        #expect(picker.documentPickerMode == .open, "open in place, not an import")
    }
}

#endif
