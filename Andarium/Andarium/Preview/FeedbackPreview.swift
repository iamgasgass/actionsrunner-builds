// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import AndariumCore
import SwiftUI
import UIKit

/// The Simulator preview's Send feedback screens (`-screen feedback…`), played
/// on the real sheet and model: only the system's side is replaced. There is
/// no mail composer, no photo library and no guest display, so the preview
/// answers for them (`SendFeedbackServices`) and fills a draft with files it
/// draws itself. The receiver is the example address. Nothing here exists in a
/// build made without the preview's `FEEDBACK_ADDRESS`.
enum FeedbackPreview {
    /// The screens that open the sheet, over Settings of a running session
    /// (`feedback`…) or over Home, where nothing runs (`feedback-home`…).
    static func opensSheet(_ screen: String) -> Bool { screen.hasPrefix("feedback") }

    static func overHome(_ screen: String) -> Bool { screen.hasPrefix("feedback-home") }

    /// The shots of the sheet the slow-start notice opens, over the boot screen.
    static func overBoot(_ screen: String) -> Bool { screen.hasPrefix("feedback-boot") }

    /// Readies the model for `screen`: its phase, the sheet that stays beneath,
    /// and the services the sheet asks.
    static func configure(screen: String, model: AppModel) {
        guard opensSheet(screen) || screen == "settings-feedback"
            || ["home", "home-menu", "welcome", "welcome-menu", "info"].contains(screen) else { return }
        var services = SendFeedbackServices()
        services.address = { "feedback@example.com" }
        services.canSendMail = { screen != "feedback-nomail" }
        services.presentMail = { _, _ in true }
        // The picker's own screen is the one thing captured as the system draws it; the menu's screen keeps the
        // real picker so that a tap on Files in it opens the system's.
        if !["feedback-file-picker", "feedback-file-menu"].contains(screen) { services.pickFiles = { _ in true } }
        services.captureScreen = { _ in guestPicture() }
        services.runningSeconds = { _ in 2520 }
        services.previewOpensAtLaunch = opensSheet(screen) && !overBoot(screen)
        services.previewOpensOverBoot = overBoot(screen)
        services.previewPrepare = { feedback in
            await prepare(screen: screen, feedback: feedback)
            // The capture run keeps a picture of the sheet only once it is open and its draft is made.
            CaptureState.markFeedbackReady()
        }
        model.feedbackServices = services
        if overBoot(screen) { seedStartRecord(in: model) }
        guard opensSheet(screen) else { return }
        if overHome(screen) {
            model.phase = .home
        } else if overBoot(screen) {
            // The slow start's own screen stays beneath; AppEntry set it.
        } else {
            model.phase = .running(.normal)
            model.sessionPreset = SessionPreset(settings: true, settingsLarge: true)
        }
    }

    // MARK: Start record

    /// The session record a start in progress leaves, with a few lines of what
    /// the guest printed: the sheet reads it for the start log, as it would in
    /// the application. It is in the temporary folder, which the system clears.
    private static func seedStartRecord(in model: AppModel) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("andarium-preview-diagnostics", isDirectory: true)
        let output = """
            [   41.2] init: starting service 'servicemanager'...
            [   41.6] init: starting service 'hwservicemanager'...
            [   43.0] init: starting service 'vold'...
            [   58.4] init: Service 'vold' (pid 312) exited with status 0
            [  102.9] init: starting service 'netd'...
            [  184.7] init: starting service 'zygote'...
            """
        // The record of this process's boot under way, which the sheet quotes only for that boot.
        let begun = Date().addingTimeInterval(-197)
        let processID = ProcessInfo.processInfo.processIdentifier
        model.bootRecord = BootRecordBinding(processID: Int(processID))
        let record = "uml-session 7\nstate running\nend running\nstatus 0\npid \(processID)\n"
            + "started \(Int(begun.timeIntervalSince1970) + 5)\nboot unfinished\nrestarts 0\nkernel-output\n" + output + "\n"
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(record.utf8).write(to: folder.appendingPathComponent(BugReportAttachments.sessionRecord))
        model.diagnosticsDirectory = folder
    }

    // MARK: Drafts

    @MainActor
    private static func prepare(screen: String, feedback: SendFeedbackModel) async {
        let words = Words()
        switch screen {
        case "feedback", "feedback-home", "feedback-nomail", "feedback-boot":
            break
        case "feedback-home-answer":
            // The no-Google-apps line, opened as a tap on it does.
            feedback.openNoGoogleAnswer()
        case "feedback-boot-removed":
            // The start log was taken out: the sheet does not make it again.
            if let log = feedback.form.attachments.items.first(where: { $0.kind == .startLog }) {
                feedback.remove(log)
            }
        case "feedback-filled", "feedback-details", "feedback-discard",
             "feedback-boot-filled", "feedback-boot-details", "feedback-boot-finished":
            feedback.form.problem = words.problem
            feedback.form.details = words.details
            // A start has no bug report to attach: the log is the sheet's own.
            await attachAll(feedback, report: overBoot(screen) ? nil : 8.6, photo: 2.4)
            if screen == "feedback-details" || screen == "feedback-boot-details" { feedback.showsInformation = true }
            if screen == "feedback-boot-finished" {
                // The start finishes while the person writes: the sheet and the
                // draft stay up over the session that follows.
                try? await Task.sleep(for: .milliseconds(900))
                feedback.app.finishBoot(.normal)
            }
            if screen == "feedback-discard" {
                try? await Task.sleep(for: .milliseconds(500))
                feedback.confirmingDiscard = true
            }
        case "feedback-missing-both", "feedback-missing-problem", "feedback-missing-details":
            // Send tapped with the problem or the details empty, as a person does it: the real alert, no composer.
            if screen == "feedback-missing-details" { feedback.form.problem = words.problem }
            if screen == "feedback-missing-problem" { feedback.form.details = words.details }
            try? await Task.sleep(for: .milliseconds(500))
            feedback.send()
        case "feedback-large":
            feedback.form.problem = words.problem
            feedback.form.details = words.details
            await attachAll(feedback, report: 8.6, photo: 21.4)
        case let screen where screen.hasPrefix("feedback-file"):
            await prepareFiles(screen: screen, feedback: feedback, words: words)
        case "feedback-ask":
            // Send tapped with both fields written, no bug report attached and the virtual machine running:
            // the real question, and no composer.
            feedback.form.problem = words.problem
            feedback.form.details = words.details
            try? await Task.sleep(for: .milliseconds(500))
            feedback.send()
        case let screen where screen == "feedback-report" || screen.hasPrefix("feedback-viewer"):
            // The bug report as the Create bug report button makes it in the preview, attached; the pages the
            // row pushes open the first page, a folder, a text, the picture or the archive inside.
            feedback.form.problem = words.problem
            feedback.form.details = words.details
            attachSampleReport(feedback, damaged: screen == "feedback-viewer-damaged")
            SendFeedbackViewerPreview.target = switch screen {
            case "feedback-viewer-folder": "FS/data/tombstones"
            case "feedback-viewer-text": SendFeedbackSampleReport.logName
            case "feedback-viewer-picture": "screenshot.png"
            case "feedback-viewer-nested": "visible_windows.zip"
            default: nil
            }
            SendFeedbackViewerPreview.thumb = screen == "feedback-viewer-text" ? 0.5 : nil
            guard screen != "feedback-report", let report = feedback.form.attachments.bugReport else { break }
            try? await Task.sleep(for: .milliseconds(500))
            feedback.view(report)
        case "feedback-generating":
            feedback.form.problem = words.problem
            feedback.form.details = words.details
            await attachAll(feedback, report: nil, photo: nil)
            // The real report lasts a few seconds: hold its overlay part way.
            let app = feedback.app
            app.busyOverSheet = true
            // The words are the app's own: the overlay of a real report.
            var overlay = AppModel.bugReportState
            overlay.progress = 0.6
            overlay.cancel = BusyCancel {}
            app.busy = overlay
        case "feedback-sent":
            feedback.form.problem = words.problem
            feedback.form.details = words.details
            await attachAll(feedback, report: 8.6, photo: 2.4)
            feedback.mailFinished(.sent)
        case "feedback-home-filled":
            feedback.form.problem = words.suggestion
            feedback.form.details = words.suggestionDetails
            await attachAll(feedback, report: nil, screenshot: false, photo: 2.4)
        default:
            break
        }
    }

    /// The screens of files from Files: sample files of this app's own, opened where
    /// they are as a picked file is, and the real refusals.
    @MainActor
    private static func prepareFiles(screen: String, feedback: SendFeedbackModel, words: Words) async {
        feedback.form.problem = words.fileProblem
        feedback.form.details = words.fileDetails
        switch screen {
        case "feedback-file":
            await attachAll(feedback, report: nil, screenshot: false, photo: nil)
            await attachFile(feedback, named: "example-log.zip", megabytes: 12.4)
        case "feedback-file-long":
            await attachFile(
                feedback, named: "example-application-release-candidate-build-2026-11-13-arm64-v8a-crash-log-with-symbols.zip",
                megabytes: 12.4)
        case "feedback-file-names":
            await attachFile(feedback, named: "\u{6D4B}\u{8BD5}\u{65E5}\u{5FD7}.zip", megabytes: 12.4)
            await attachFile(feedback, named: "\u{30C6}\u{30B9}\u{30C8}\u{30ED}\u{30B0}.zip", megabytes: 5.1)
        case "feedback-file-mixed":
            await attachAll(feedback, report: 3.2, photo: 2.4)
            await attachFile(feedback, named: "example-log.zip", megabytes: 6.8)
        case "feedback-file-large":
            await attachAll(feedback, report: nil, screenshot: false, photo: nil)
            await attachFile(feedback, named: "example-log.zip", megabytes: 1_920)
        case "feedback-file-apk", "feedback-file-apk-several":
            // One pick: an ordinary file, which is attached, and the packages, which are not. The one alert says why.
            await attachAll(feedback, report: nil, screenshot: false, photo: nil)
            var pick: [URL] = []
            let names = screen == "feedback-file-apk"
                ? ["example-log.zip", "example-app.apk"]
                : ["example-log.zip", "example-app.apk", "example-app.apks", "example-app.xapk"]
            for name in names {
                if let file = try? makeFile(named: name, head: emptyZip, megabytes: name.hasSuffix(".zip") ? 0.8 : 12.4) {
                    pick.append(file)
                }
            }
            await feedback.addFiles(pick)
        case "feedback-file-copying":
            // What a person has while a copy runs: the screenshot attached before; the file's row comes when the
            // copy ends, and meanwhile Send is dimmed.
            await attachAll(feedback, report: nil, screenshot: true, photo: nil)
            feedback.form.addingFiles = true
            // The real copy lasts as long as the file is large: hold its overlay part way.
            feedback.fileBusy = SendFeedbackModel.copyingState(progress: 0.42, cancel: BusyCancel {})
        case "feedback-file-refused-one":
            feedback.failure = refusal([.empty], feedback)
        case "feedback-file-refused-four":
            feedback.failure = refusal([.notEnoughSpace, .notAFile, .empty, .unavailable], feedback)
        case "feedback-file-gone":
            // The real path: a file is attached, goes from where it was kept, and Send finds it out.
            await attachAll(feedback, report: nil, screenshot: false, photo: nil)
            if let file = try? makeFile(named: "example-log.zip", head: emptyZip, megabytes: 12.4) {
                await feedback.addFiles([file])
                try? FileManager.default.removeItem(at: file)
                feedback.send()
            }
        case "feedback-file-picker":
            // The system's document picker over the sheet, as a tap on Files opens it.
            try? await Task.sleep(for: .milliseconds(1500))
            feedback.pickFiles()
        case "feedback-file-menu":
            // The Add menu of the bar, open.
            try? await Task.sleep(for: .milliseconds(1500))
            AddMenuProbe.open()
        default:
            // A folder and an empty file are refused, each for its own reason.
            let folder = SendFeedbackStaging().incoming.appendingPathComponent("Example folder", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let empty = try? makeFile(named: "empty.txt", head: Data(), megabytes: 0) {
                await feedback.addFiles([folder, empty])
            }
        }
    }

    /// The alert the sheet makes for these refusals, with the model's own words.
    @MainActor
    private static func refusal(_ reasons: [SendFeedbackFileRefusal], _ feedback: SendFeedbackModel) -> SendFeedbackFailure {
        SendFeedbackFailure(
            title: SendFeedbackModel.fileFailureTitle(count: reasons.count),
            message: SendFeedbackModel.fileFailureMessage(reasons, device: feedback.app.host.name))
    }

    @MainActor
    private static func attachFile(_ feedback: SendFeedbackModel, named name: String, megabytes: Double) async {
        if let file = try? makeFile(named: name, head: emptyZip, megabytes: megabytes) {
            await feedback.addFiles([file])
        }
    }

    /// The preview's report (`SendFeedbackSampleReport`), attached as a made bug report is.
    @MainActor
    private static func attachSampleReport(_ feedback: SendFeedbackModel, damaged: Bool = false) {
        do {
            try FileManager.default.createDirectory(at: BugReportStaging.directory, withIntermediateDirectories: true)
            let file = BugReportStaging.directory.appendingPathComponent("bugreport-\(UUID().uuidString).zip")
            if damaged { try SendFeedbackSampleReport.writeDamaged(to: file) } else { try SendFeedbackSampleReport.write(to: file) }
            feedback.adoptBugReport(file)
        } catch {
            // The capture shows the sheet without it.
        }
    }

    @MainActor
    private static func attachAll(
        _ feedback: SendFeedbackModel, report: Double?, screenshot: Bool = true, photo: Double?
    ) async {
        if let report, let file = try? makeFile(named: "bugreport.zip", head: emptyZip, megabytes: report) {
            feedback.adoptBugReport(file)
        }
        if screenshot, feedback.state.running {
            feedback.takeScreenshot()
            while feedback.form.takingScreenshot { try? await Task.sleep(for: .milliseconds(50)) }
        }
        var picked: [SendFeedbackPickedFile] = []
        if let photo, let head = photoData(),
           let file = try? makeFile(named: "photo.jpg", head: head, megabytes: photo) {
            picked.append(SendFeedbackPickedFile(url: file, isVideo: false))
        }
        await feedback.importMedia(picked)
    }

    private struct Words {
        let problem = "Game freezes after the intro video"
        let details = "The game plays its intro, then the picture stops while the sound goes on. It happens every time since this morning\u{2019}s update."
        let suggestion = "Let me keep the keyboard on screen"
        let fileProblem = "The app closes right after it opens"
        let fileDetails = "I open it from the Home screen, and it closes after about a second. The attached log was saved right after it happened."
        let suggestionDetails = "In games I type a lot, and the keyboard closes after every message. The picture shows where."
    }

    // MARK: Files

    private static let emptyZip = Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))

    /// A file in the picker's folder with `head` at its start, and zeros after it
    /// up to `megabytes` MiB (a sparse file; decoders stop at the picture's end).
    private static func makeFile(named name: String, head: Data, megabytes: Double) throws -> URL {
        let folder = SendFeedbackStaging().incoming.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try head.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: max(UInt64(megabytes * Double(Limits.bytesPerMiB)), UInt64(head.count)))
        return url
    }

    @MainActor
    private static func photoData() -> Data? {
        let renderer = ImageRenderer(content: PhotoScene().frame(width: 800, height: 600))
        renderer.scale = 1
        return renderer.uiImage?.jpegData(compressionQuality: 0.85)
    }

    /// The mock Android home screen at the display's own pixels.
    @MainActor
    private static func guestPicture() -> UIImage? {
        guard let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen else { return nil }
        let size = screen.bounds.size
        let renderer = ImageRenderer(content: GuestHomeScreen().frame(width: size.width, height: size.height))
        renderer.scale = screen.nativeScale
        return renderer.uiImage
    }
}

/// Opens the bar's Add menu the way VoiceOver does, by activating its button.
@MainActor
private enum AddMenuProbe {
    static func open() {
        let label = String(localized: "Add a photo or a file", table: "Feedback")
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            if let button = nodes(in: window).first(where: { $0.accessibilityLabel == label }) {
                _ = button.accessibilityActivate()
                return
            }
        }
    }

    private static func nodes(in node: NSObject, depth: Int = 0) -> [NSObject] {
        guard depth < 64 else { return [] }
        var children = (node.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        if let view = node as? UIView { children += view.subviews }
        return [node] + children.flatMap { nodes(in: $0, depth: depth + 1) }
    }
}

/// A made-up photo: hills under an evening sky.
private struct PhotoScene: View {
    var body: some View {
        Canvas { context, size in
            let sky = Gradient(colors: [Color(hex: 0x3B4C8C), Color(hex: 0xE58B6B), Color(hex: 0xF6C77E)])
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                sky, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.75)))
            let sun = CGRect(x: size.width * 0.58, y: size.height * 0.38, width: size.width * 0.2, height: size.width * 0.2)
            context.fill(Path(ellipseIn: sun), with: .color(Color(hex: 0xFFE3A3)))
            func hill(_ top: CGFloat, _ color: Color, _ phase: CGFloat) {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for step in 0...24 {
                    let x = size.width * CGFloat(step) / 24
                    let y = size.height * (top + 0.06 * sin(Double(step) / 3.6 + phase))
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(color))
            }
            hill(0.62, Color(hex: 0x6A4A6B), 0.4)
            hill(0.72, Color(hex: 0x3F3150), 2.1)
            hill(0.84, Color(hex: 0x231C33), 4.0)
        }
    }
}

#endif
