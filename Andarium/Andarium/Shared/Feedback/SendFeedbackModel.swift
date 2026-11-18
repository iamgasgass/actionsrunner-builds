// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import AndariumCore
import Observation
import SwiftUI
import UIKit

/// Something that went wrong, said in an alert over the sheet.
struct SendFeedbackFailure: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    /// The alert asks for a download link, which goes in the details: they are ready to type in once it closes.
    var focusesDetails = false
}

extension SendFeedbackMissing {
    /// What the alert says is missing, and what to do.
    var message: String {
        switch self {
        case .problem:
            String(
                localized: "Write what went wrong in the Problem line, then send again.", table: "Feedback")
        case .details:
            String(localized: "Describe what you did and what happened, then send again.", table: "Feedback")
        case .both:
            String(
                localized: "Write what went wrong in the Problem line, and describe what you did and what happened, then send again.",
                table: "Feedback")
        }
    }
}

/// The Send feedback sheet's state and what its controls do. The rules are
/// `SendFeedbackForm`'s; this holds the files and runs the bug report, the
/// screenshot, the picked media and the mail. It stops the virtual machine
/// nowhere, and nothing runs once the sheet is closed.
@Observable
final class SendFeedbackModel {
    @ObservationIgnored let app: AppModel
    @ObservationIgnored let staging: SendFeedbackStaging
    @ObservationIgnored let folder: SendFeedbackFolder
    /// The access held to the files picked from Files, one per attachment.
    @ObservationIgnored let scopes: SendFeedbackScopes
    @ObservationIgnored private var fileCancellation: SendFeedbackCancellation?

    /// What is written and attached; `state` adds what the app says live.
    var form: SendFeedbackForm
    private(set) var thumbnails: [UUID: UIImage] = [:]
    /// The overlay of a file that cannot be used where it is while it is copied;
    /// the sheet draws it over itself. The Simulator preview sets it for a capture.
    var fileBusy: BusyState?
    var failure: SendFeedbackFailure?
    /// Send was tapped while the problem or the details were empty: the alert
    /// that says which, over the sheet. Nothing opens.
    var incomplete: SendFeedbackMissing?
    /// Send was tapped with both fields written and no bug report attached while one can be made: the
    /// alert that asks about it, over the sheet. Nothing opens until it is answered.
    var askingForBugReport = false
    /// The attachment whose contents are being read, in the pages the sheet's own navigation pushes. nil when none is.
    var viewing: SendFeedbackAttachment?
    /// What is known of each bug report attached: its directory, read once when it was attached.
    private(set) var reports: [UUID: SendFeedbackReportState] = [:]
    /// Cancel asks before it discards.
    var confirmingDiscard = false
    /// The information block shows in full.
    var showsInformation = false
    /// The card that asks for a bug report was put away.
    var hintDismissed = false
    /// The no-Google-apps line is at the top of the mail: it is there, closed, whenever a sheet is made, whatever
    /// was done on an earlier one, and it stays until the person closes it on this one.
    private(set) var showsNoGoogleLine = true
    /// Its answer is open in place.
    private(set) var noGoogleAnswerOpen = false
    /// The mail was sent: the sheet shows its confirmation over what was sent and closes when the person
    /// closes the confirmation, not before (`mailFinished`, `close`).
    var sent: Bool { form.sent }
    private(set) var closed = false
    private var presentingMail = false
    /// The information block the mail went with, shown unchanged under the confirmation.
    @ObservationIgnored private var mailedInformation: SendFeedbackInformation?
    /// The staged files and the access held to the picked ones were let go.
    @ObservationIgnored private var filesReleased = false
    /// The start log was offered once, whether or not it was attached, and
    /// whether or not it was removed since: it is made when the sheet opens
    /// and never again.
    @ObservationIgnored private var startLogOffered = false

    init(app: AppModel, staging: SendFeedbackStaging = SendFeedbackStaging()) {
        self.app = app
        self.staging = staging
        folder = staging.makeFolder()
        scopes = SendFeedbackScopes(system: app.feedbackServices.files)
        form = SendFeedbackForm(mailAvailable: app.feedbackServices.canSendMail(), running: app.virtualMachineRuns)
    }

    deinit {
        folder.removeAll()
        scopes.releaseAll()
    }

    // MARK: The no-Google-apps line

    /// The person opened the line's answer: it stays open until the sheet closes.
    func openNoGoogleAnswer() {
        noGoogleAnswerOpen = true
    }

    /// The person closed the line: this sheet has none from now on, and the next one has it again.
    func closeNoGoogleLine() {
        showsNoGoogleLine = false
    }

    /// The form with what the app says now: whether a virtual machine runs,
    /// whether it can make a bug report (the Create bug report row's own
    /// rule, and no other task under the overlay) and whether the bug report
    /// is being made.
    var state: SendFeedbackForm {
        var state = form
        state.running = app.virtualMachineRuns
        state.starting = app.virtualMachineStarts
        state.bugReportPossible = app.canCreateBugReport && app.busy == nil
        state.makingBugReport = app.feedbackBusy != nil
        return state
    }

    /// The basic information the mail ends with; once the mail is sent, the block it went with.
    var information: SendFeedbackInformation {
        if form.sent, let mailedInformation { return mailedInformation }
        return app.feedbackInformation()
    }

    /// Mail can come back when the person adds an account in iOS Settings, and
    /// go when the system restricts it: asked again when the app returns to
    /// the foreground. A sheet whose mail was sent stays as it was.
    func refresh() {
        guard !form.sent else { return }
        form.mailAvailable = app.feedbackServices.canSendMail()
    }

    // MARK: Start log

    /// Opened during a start, the sheet attaches the start log by itself, once:
    /// the step, the time on the notice's clock, the kind of start and this
    /// boot's output as the runtime's record quotes it. It is a row like the
    /// others; taking it out is remembered for this sheet, and it is not made
    /// again while the sheet is open, whatever the start does.
    func offerStartLog() {
        guard !startLogOffered else { return }
        startLogOffered = true
        guard !closed, case let .booting(kind) = app.phase, let boot = information.boot else { return }
        let text = SendFeedbackStartLog.text(
            step: boot.step, seconds: boot.seconds, kind: kind, restarts: boot.restarts, output: app.startOutput(),
            containers: app.diagnosticsContainers, identifiers: app.driver?.guestIdentifiers() ?? .none)
        do {
            // The mail names it by the moment it was made (`Kind.generatedFileName`), as it names the
            // screenshot, whatever it is called where it is staged.
            let url = try folder.reserve("start-log.txt")
            try Data(text.utf8).write(to: url)
            form.attachments.add(
                SendFeedbackAttachment(
                    kind: .startLog, url: url, bytes: Self.size(of: url), madeAt: app.feedbackServices.now()))
        } catch {
            // The log helps; a sheet without it is as usable.
        }
    }

    /// A draft that already lists an Android package (one an earlier build attached) loses it as the sheet opens,
    /// with the alert a pick of one gets. A draft ends with its sheet, so none comes from an earlier build today;
    /// the rule holds the list to the same invariant whichever way it was filled.
    func refuseAndroidPackagesInDraft() {
        let packages = form.attachments.items.filter { item in
            [item.fileName, item.displayName ?? "", item.url.lastPathComponent].contains {
                SendFeedbackAndroidPackage.matches(name: $0)
            }
        }
        guard !packages.isEmpty else { return }
        packages.forEach(remove)
        failure = Self.packageFailure(count: packages.count)
    }

    // MARK: Bug report

    /// Makes the bug report under the app's progress overlay, which the sheet
    /// draws over itself, and attaches the archive.
    func createBugReport() {
        guard state.canMakeBugReport else { return }
        app.createBugReportForFeedback(
            finished: { [weak self] file in
                if let self {
                    adoptBugReport(file)
                } else {
                    try? FileManager.default.removeItem(at: file)
                }
            },
            failed: { [weak self] message in self?.fail(AppModel.bugReportFailure, message) })
    }

    func adoptBugReport(_ file: URL) {
        guard !closed else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        do {
            let staged = try folder.adopt(file, named: file.lastPathComponent)
            let attachment = SendFeedbackAttachment(kind: .bugReport, url: staged, bytes: Self.size(of: staged))
            if let replaced = form.attachments.add(attachment) {
                reports[replaced.id] = nil
                if viewing?.id == replaced.id { viewing = nil }
                folder.remove(replaced.url)
            }
            readDirectory(of: attachment)
        } catch {
            try? FileManager.default.removeItem(at: file)
            fail(String(localized: "Bug report not attached", table: "Feedback"), error.localizedDescription)
        }
    }

    // MARK: Screenshot

    /// Takes the virtual machine's picture as it is now and attaches it.
    func takeScreenshot() {
        guard state.canTakeScreenshot else { return }
        guard let image = app.feedbackServices.captureScreen(app) else {
            fail(
                String(localized: "Screenshot not taken", table: "Feedback"),
                String(
                    localized: "The virtual machine\u{2019}s display isn\u{2019}t available right now.",
                    table: "Feedback"))
            return
        }
        form.takingScreenshot = true
        let folder = folder
        Task { [weak self] in
            let box = ImageBox(image: image)
            let written = await Task.detached { try Self.writePNG(box.image, into: folder) }.result
            let thumbnail = await image.byPreparingThumbnail(
                ofSize: Self.thumbnailSize(for: image.size, longSide: CGFloat(SendFeedbackMedia.thumbnailPixels)))
            guard let self else { return }
            form.takingScreenshot = false
            switch written {
            case .success(let url):
                guard !closed else {
                    folder.remove(url)
                    return
                }
                let pixels = image.cgImage.map { SendFeedbackPixels(width: $0.width, height: $0.height) }
                let attachment = SendFeedbackAttachment(
                    kind: .screenshot, url: url, bytes: Self.size(of: url), pixels: pixels)
                form.attachments.add(attachment)
                thumbnails[attachment.id] = thumbnail
            case .failure(let error):
                fail(String(localized: "Screenshot not taken", table: "Feedback"), error.localizedDescription)
            }
        }
    }

    private nonisolated struct ImageBox: @unchecked Sendable {
        let image: UIImage
    }

    private nonisolated static func writePNG(_ image: UIImage, into folder: SendFeedbackFolder) throws -> URL {
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        let url = try folder.reserve("screenshot.png")
        try data.write(to: url)
        return url
    }

    private static func thumbnailSize(for size: CGSize, longSide: CGFloat) -> CGSize {
        let scale = longSide / max(size.width, size.height, 1)
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    // MARK: Photos and videos

    /// How one picked item becomes a file of ours: the picker hands over an
    /// item that loads slowly (a video comes down from iCloud) and may not
    /// load at all.
    typealias MediaLoader = @MainActor () async -> SendFeedbackPickedFile?

    /// Takes in what the picker returned: each item loads, then moves into the
    /// sheet's folder and becomes a row with its picture, size and, for a
    /// video, its length. The importing state lasts from before the first
    /// load to after the last, so Send waits for the files it will carry; an
    /// item that does not load counts as one that was not added.
    func importMedia(loading loaders: [MediaLoader]) async {
        guard !loaders.isEmpty else { return }
        form.importingMedia = true
        var failed = 0
        for load in loaders {
            if let file = await load() {
                if await take(file) == false { failed += 1 }
            } else {
                failed += 1
            }
        }
        form.importingMedia = false
        guard failed > 0, !closed else { return }
        let device = app.host.name
        if failed == 1 {
            fail(
                String(localized: "One item wasn\u{2019}t added", table: "Feedback"),
                String(
                    localized: "It couldn\u{2019}t be copied. Check the free space on this \(device), then try again.",
                    table: "Feedback"))
        } else {
            fail(
                String(localized: "\(failed) items weren\u{2019}t added", table: "Feedback"),
                String(
                    localized: "They couldn\u{2019}t be copied. Check the free space on this \(device), then try again.",
                    table: "Feedback"))
        }
    }

    /// Takes in files that are already loaded.
    func importMedia(_ files: [SendFeedbackPickedFile]) async {
        await importMedia(loading: files.map { file in { file } })
    }

    /// Moves one loaded file into the sheet's folder and makes its row; false
    /// when it could not be copied. A sheet that closed meanwhile takes
    /// nothing, and the file goes.
    private func take(_ file: SendFeedbackPickedFile) async -> Bool {
        let source = file.url
        // The picker's copy sits in a folder of its own.
        defer {
            let parent = source.deletingLastPathComponent()
            if parent.deletingLastPathComponent().standardizedFileURL == staging.incoming.standardizedFileURL {
                try? FileManager.default.removeItem(at: parent)
            }
        }
        guard !closed else { return true }
        do {
            let kind = file.isVideo ? "video" : "photo"
            let ext = source.pathExtension.isEmpty ? (file.isVideo ? "mov" : "jpg") : source.pathExtension
            let staged = try folder.adopt(source, named: "\(kind).\(ext)")
            let inspection = await SendFeedbackMedia.inspect(staged, isVideo: file.isVideo)
            guard !closed else {
                folder.remove(staged)
                return true
            }
            let attachment = SendFeedbackAttachment(
                kind: file.isVideo ? .video : .photo, url: staged, bytes: Self.size(of: staged),
                pixels: inspection.pixels, durationSeconds: inspection.durationSeconds)
            form.attachments.add(attachment)
            if let data = inspection.thumbnail { thumbnails[attachment.id] = UIImage(data: data) }
            return true
        } catch {
            return false
        }
    }

    // MARK: Files

    /// Opens the system's document picker. What it returns is added where it
    /// is kept (`addFiles`).
    func pickFiles() {
        guard state.canAddFiles else { return }
        _ = app.feedbackServices.pickFiles { [weak self] urls in
            guard let self else { return }
            Task { await self.addFiles(urls) }
        }
    }

    /// Takes in the files the picker opened where they are kept. Each one is
    /// looked at without being read: a folder, a package, an empty file or one
    /// that is not reachable is refused; a file the composer can map from
    /// where it is becomes a row, with the picker's access held until the row
    /// goes; any other (its provider has not downloaded it, its volume refuses
    /// mapping) is copied into the sheet's folder, with the overlay and its
    /// Cancel, and the access let go. Picking a file again attaches it again.
    /// Send waits for all of it. A batch that arrives while another is being
    /// taken in is turned away (the picker is not offered meanwhile), so the
    /// first one's Cancel stays its own.
    func addFiles(_ urls: [URL]) async {
        guard !urls.isEmpty, !closed, !form.addingFiles else { return }
        form.addingFiles = true
        let cancellation = SendFeedbackCancellation()
        fileCancellation = cancellation
        var refusals: [SendFeedbackFileRefusal] = []
        for url in urls {
            if cancellation.isCancelled || closed { break }
            do {
                try await addFile(url, cancellation: cancellation)
            } catch let refusal as SendFeedbackFileRefusal {
                if refusal != .cancelled { refusals.append(refusal) }
            } catch {
                refusals.append(.unavailable)
            }
        }
        fileBusy = nil
        fileCancellation = nil
        form.addingFiles = false
        // A copy that was still under way as the sheet closed may have made its folder again.
        if closed { folder.removeAll() }
        guard !refusals.isEmpty, !closed else { return }
        failure = Self.fileFailure(refusals, device: app.host.name)
    }

    private func addFile(_ url: URL, cancellation: SendFeedbackCancellation) async throws {
        let id = UUID()
        scopes.hold(id, url)
        var keepAccess = false
        defer { if !keepAccess { scopes.release(id) } }
        let system = app.feedbackServices.files
        let info = await Task.detached { system.inspect(url) }.value
        guard !closed else { return }
        switch info.kind {
        case .file: break
        case .folder, .other: throw SendFeedbackFileRefusal.notAFile
        case .missing: throw SendFeedbackFileRefusal.unavailable
        }
        // No mail service delivers an Android package: it is told by its name (and the type its provider gives),
        // and is never opened.
        let name = url.lastPathComponent
        if SendFeedbackAndroidPackage.matches(name: name, contentType: info.contentType)
            || SendFeedbackAndroidPackage.matches(name: SendFeedbackFolder.safeName(name)) {
            throw SendFeedbackFileRefusal.androidPackage
        }
        guard info.bytes > 0 else { throw SendFeedbackFileRefusal.empty }
        let displayName = SendFeedbackNames.display(url.lastPathComponent)
        if info.usableInPlace {
            guard !closed else { return }
            keepAccess = true
            form.attachments.add(SendFeedbackAttachment(
                id: id, kind: .file, url: url, bytes: info.bytes, displayName: displayName,
                mailName: SendFeedbackFolder.safeName(url.lastPathComponent), inPlace: true))
            return
        }
        let staged = try await copy(url, bytes: info.bytes, cancellation: cancellation)
        // A copy that finished while the main actor was busy may have been
        // cancelled, or the sheet closed, before this runs: what the person
        // stopped is not added.
        guard !closed, !cancellation.isCancelled else {
            folder.remove(staged)
            return
        }
        form.attachments.add(SendFeedbackAttachment(
            kind: .file, url: staged, bytes: Self.size(of: staged), displayName: displayName))
    }

    /// Copies a file that cannot be used where it is into the sheet's folder,
    /// off the main thread, under the overlay with its Cancel.
    private func copy(_ url: URL, bytes: UInt64, cancellation: SendFeedbackCancellation) async throws -> URL {
        fileBusy = Self.copyingState(progress: 0, cancel: BusyCancel { [weak self] in self?.fileCancellation?.cancel() })
        defer { fileBusy = nil }
        let folder = folder
        let name = SendFeedbackFolder.safeName(url.lastPathComponent)
        return try await Task.detached(priority: .userInitiated) {
            // The copy is awaited here, so the model outlives it: no weak reference to carry across threads.
            try folder.stageCopy(of: url, bytes: bytes, named: name, cancellation: cancellation) { copied in
                Task { @MainActor in self.fileCopied(copied, of: bytes) }
            }
        }.value
    }

    /// The overlay of a copy at `progress` (0 to 1).
    static func copyingState(progress: Double, cancel: BusyCancel) -> BusyState {
        BusyState(
            title: String(localized: "Copying file", table: "Feedback"),
            detail: String(
                localized: "Andarium makes its own copy of this file before attaching it. Large files take a while.",
                table: "Feedback"),
            progress: progress, cancel: cancel)
    }

    private func fileCopied(_ copied: UInt64, of total: UInt64) {
        guard fileBusy != nil, total > 0 else { return }
        fileBusy?.progress = min(1, Double(copied) / Double(total))
    }

    static func fileFailureTitle(count: Int) -> String {
        count == 1
            ? String(localized: "One item wasn\u{2019}t added", table: "Feedback")
            : String(localized: "\(count) items weren\u{2019}t added", table: "Feedback")
    }

    /// The one alert a pick of files gets, whatever it refused. Android packages alone are said by themselves:
    /// the mail service rejects them, and a download link in the details is what to send instead. With other
    /// refusals they are one line among the others. Either way the details are ready to type in afterwards.
    static func fileFailure(_ refusals: [SendFeedbackFileRefusal], device: String) -> SendFeedbackFailure {
        let packages = refusals.filter { $0 == .androidPackage }.count
        if packages > 0, packages == refusals.count { return packageFailure(count: packages) }
        return SendFeedbackFailure(
            title: fileFailureTitle(count: refusals.count), message: fileFailureMessage(refusals, device: device),
            focusesDetails: packages > 0)
    }

    /// The alert for `count` Android packages that were not attached.
    static func packageFailure(count: Int) -> SendFeedbackFailure {
        SendFeedbackFailure(
            title: String(localized: "APK files can\u{2019}t be sent by mail", table: "Feedback"),
            message: packageLine(count: count), focusesDetails: true)
    }

    private static func packageLine(count: Int) -> String {
        count == 1
            ? String(
                localized: "Mail services reject messages that carry an APK, so this file was not attached. Paste a download link for the app in the details instead.",
                table: "Feedback")
            : String(
                localized: "Mail services reject messages that carry an APK, so these files were not attached. Paste a download link for the app in the details instead.",
                table: "Feedback")
    }

    /// One line for each reason a file was refused, in a fixed order.
    static func fileFailureMessage(_ refusals: [SendFeedbackFileRefusal], device: String) -> String {
        var lines: [String] = []
        if refusals.contains(.notEnoughSpace) {
            lines.append(String(
                localized: "There isn\u{2019}t enough free space on this \(device). Free up space, then try again.",
                table: "Feedback"))
        }
        if refusals.contains(.notAFile) {
            lines.append(String(
                localized: "A folder or a package can\u{2019}t be attached. Compress it in Files first.",
                table: "Feedback"))
        }
        if refusals.contains(.empty) {
            lines.append(String(localized: "An empty file can\u{2019}t be attached.", table: "Feedback"))
        }
        if refusals.contains(.unavailable) {
            lines.append(String(
                localized: "A file couldn\u{2019}t be read. Check that it is still in Files and downloaded, then try again.",
                table: "Feedback"))
        }
        let packages = refusals.filter { $0 == .androidPackage }.count
        if packages > 0 { lines.append(packageLine(count: packages)) }
        return lines.joined(separator: "\n")
    }

    // MARK: Attachments

    /// The attachments whose contents the viewer shows: the bug report, an archive, and the start log, a text.
    /// What else is attached is shown by its row alone.
    static func canView(_ kind: SendFeedbackAttachment.Kind) -> Bool {
        kind == .bugReport || kind == .startLog
    }

    /// Opens the viewer on an attachment's contents, over the sheet. Reading only: nothing is changed, copied or shared.
    func view(_ attachment: SendFeedbackAttachment) {
        guard Self.canView(attachment.kind), !closed, !form.sent,
              form.attachments.items.contains(where: { $0.id == attachment.id }) else { return }
        viewing = attachment
    }

    /// Reads the directory of a bug report once, as it is attached, off the main thread: the row says how many
    /// files it holds, and the pages read from this reader. A report that cannot be read says so on its pages.
    private func readDirectory(of attachment: SendFeedbackAttachment) {
        reports[attachment.id] = .opening
        let id = attachment.id
        let url = attachment.url
        Task { [weak self] in
            let state: SendFeedbackReportState
            do {
                state = .ready(try await SendFeedbackArchiveReader.open(file: url))
            } catch {
                state = .failed(error as? SendFeedbackArchiveError ?? .unavailable)
            }
            guard let self, !self.closed, self.reports[id] != nil else { return }
            self.reports[id] = state
        }
    }

    /// The pages that showed what a bug report holds are gone: the archives opened inside it are let go.
    func releaseViewerReaders() {
        for case .ready(let reader) in reports.values {
            Task { await reader.releaseNested() }
        }
    }

    /// Takes a file out of the mail. A staged file is deleted; a file kept
    /// where the person has it is only let go.
    func remove(_ attachment: SendFeedbackAttachment) {
        guard let removed = form.attachments.remove(attachment.id) else { return }
        if viewing?.id == removed.id { viewing = nil }
        reports[removed.id] = nil
        if removed.inPlace {
            scopes.release(removed.id)
        } else {
            folder.remove(removed.url)
        }
        thumbnails[removed.id] = nil
    }

    private static func size(of url: URL) -> UInt64 {
        UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    // MARK: Mail

    /// The Send button. With both fields written and no bug report attached, while one can be made, it asks
    /// first (`askingForBugReport`); in any other state it hands the mail to the composer, as `openMail` says.
    /// A tap with a field empty says which. It asks on every such tap: nothing is remembered.
    func send() {
        guard state.canSend, !presentingMail else { return }
        // The mail needs a subject and a body: nothing opens, and an alert says which is empty.
        if let missing = state.missing {
            incomplete = missing
            return
        }
        if state.asksAboutBugReportOnSend {
            askingForBugReport = true
            return
        }
        openMail()
    }

    /// The alert's "Send without bug report": the mail opens as it does when nothing could be asked.
    func sendWithoutBugReport() {
        guard state.canSend, state.missing == nil, !presentingMail else { return }
        openMail()
    }

    /// Hands the subject, the body and the files to the system's composer,
    /// where the person reads and may change the mail; nothing is sent from
    /// here.
    private func openMail() {
        guard let address = app.feedbackAddress, attachmentsAreThere() else { return }
        // Every file is mapped here, before the composer opens: one that cannot
        // be (it went after the look above) is said, like any other that is gone,
        // and the person looks at the list again.
        let mapped: [Data]
        switch form.attachments.mapAll() {
        case .success(let data):
            mapped = data
        case .failure(let failure):
            takeOut(form.attachments.items.filter { failure.attachments.contains($0.id) })
            return
        }
        let sentInformation = information
        let request = SendFeedbackMailRequest(
            address: address, subject: SendFeedbackMail.subject(problem: form.problem),
            body: SendFeedbackMail.body(details: form.details, information: sentInformation),
            attachments: form.attachments.items, mapped: mapped)
        mailedInformation = sentInformation
        presentingMail = true
        let shown = app.feedbackServices.presentMail(request) { [weak self] result in
            self?.mailFinished(result)
        }
        if !shown {
            presentingMail = false
            mailedInformation = nil
            fail(
                String(localized: "Mail not opened", table: "Feedback"),
                String(localized: "Andarium couldn\u{2019}t open the mail composer.", table: "Feedback"))
        }
    }

    /// Looks at every file again as Send is tapped. A file that is gone, or
    /// that the composer can no longer map from where it is (the person moved
    /// or deleted it, its provider took it back, access was lost), is taken
    /// out of the list and said so, and nothing is sent: a mail never goes
    /// without a file the person added, unseen. A file that changed has the
    /// size it has now, and what it holds now is what goes.
    private func attachmentsAreThere() -> Bool {
        var gone: [SendFeedbackAttachment] = []
        for item in form.attachments.items {
            if item.inPlace {
                let now = app.feedbackServices.files.inspect(item.url)
                if now.usableInPlace {
                    if now.bytes != item.bytes { form.attachments.update(item.id, bytes: now.bytes) }
                } else {
                    gone.append(item)
                }
            } else if !FileManager.default.fileExists(atPath: item.url.path) {
                gone.append(item)
            }
        }
        guard !gone.isEmpty else { return true }
        takeOut(gone)
        return false
    }

    /// Takes files that are no longer available out of the list and says so;
    /// nothing is sent until the person has looked at the list again.
    private func takeOut(_ gone: [SendFeedbackAttachment]) {
        gone.forEach(remove)
        if gone.count == 1 {
            fail(
                String(localized: "Attachment not available", table: "Feedback"),
                String(
                    localized: "An attachment is no longer available, so it was taken out of the list. Check the list, then send again.",
                    table: "Feedback"))
        } else {
            fail(
                String(localized: "Attachments not available", table: "Feedback"),
                String(
                    localized: "\(gone.count) attachments are no longer available, so they were taken out of the list. Check the list, then send again.",
                    table: "Feedback"))
        }
    }

    /// The person left the composer. Sent leaves the sheet exactly as it was
    /// under its confirmation, with the files still staged, and the draft ends
    /// when the person closes it (`close`); saved and cancelled leave it as it
    /// was, for another try; a failure is the system's own words.
    func mailFinished(_ result: SendFeedbackMailResult) {
        presentingMail = false
        switch result {
        case .sent:
            form.sent = true
            confirmingDiscard = false
        case .saved, .cancelled:
            mailedInformation = nil
        case .failed(let message):
            mailedInformation = nil
            fail(String(localized: "Feedback not sent", table: "Feedback"), message)
        }
    }

    /// The application left the foreground. A sent mail needs none of its files
    /// any more, and the rows under the confirmation are drawn without them, so
    /// a process that ends in the background leaves none behind.
    func applicationEnteredBackground() {
        guard form.sent else { return }
        releaseFiles()
    }

    // MARK: Closing

    /// The sheet is closed: nothing stays behind, and a draft whose mail was
    /// sent ends here, not when the mail left. A parent torn down under the
    /// sheet (the low-space pause, the end of a run) closes it too, so the
    /// sheet's claim on the overlay of a task under way goes with it: the
    /// screens draw that overlay, and its Cancel, again.
    func close() {
        guard !closed else { return }
        closed = true
        viewing = nil
        reports = [:]
        fileCancellation?.cancel()
        app.busyOverSheet = false
        app.feedbackSheetOpen = false
        app.feedbackFromBoot = false
        releaseFiles()
        thumbnails = [:]
        _ = form.attachments.removeAll()
        if form.sent {
            form.problem = ""
            form.details = ""
            mailedInformation = nil
        }
    }

    /// Lets go of the files, once: the staged ones are deleted and the access
    /// the rows hold to the picked ones stops. Only the access the rows own: a
    /// file still being looked at or copied keeps its own until that work
    /// ends (`addFile`), so nothing is read after its access is let go.
    private func releaseFiles() {
        guard !filesReleased else { return }
        filesReleased = true
        for item in form.attachments.items where item.inPlace { scopes.release(item.id) }
        folder.removeAll()
        try? FileManager.default.removeItem(at: staging.incoming)
    }

    private func fail(_ title: String, _ message: String) {
        failure = SendFeedbackFailure(title: title, message: message)
    }
}

/// A bug report's directory, as it is attached: being read, read, or not readable.
enum SendFeedbackReportState: Sendable {
    case opening
    case ready(SendFeedbackArchiveReader)
    case failed(SendFeedbackArchiveError)

    var reader: SendFeedbackArchiveReader? {
        if case .ready(let reader) = self { return reader }
        return nil
    }
}

#endif
