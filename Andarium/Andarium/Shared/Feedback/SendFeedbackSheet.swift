// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import AndariumCore
import PhotosUI
import SwiftUI

/// Send feedback, laid out as the mail it becomes: the problem is the subject
/// line, the details are the body, the files sit in the body as Mail shows
/// them, and the basic information closes it. One bar at the foot holds the
/// bug report, the screenshot, the photos and videos, the files, and Send feedback; it
/// rides above the keyboard. A card over the bar asks for a bug report until
/// one is attached or the card is put away.
struct SendFeedbackSheet: View {
    @State private var model: SendFeedbackModel
    @State private var picking = false
    @State private var picked: [PhotosPickerItem] = []
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private enum Field { case problem, details }
    private static let endID = "feedback-end"

    /// The words more than one place uses, in the feature's table.
    private enum Words {
        static let bugReport = LocalizedStringResource("Bug report", table: "Feedback")
        static let startLog = LocalizedStringResource("Start log", table: "Feedback")
        static let screenshot = LocalizedStringResource("Screenshot", table: "Feedback")
        static let photos = LocalizedStringResource("Photos", table: "Feedback")
        static let addPhotos = LocalizedStringResource("Add photos or videos", table: "Feedback")
        static let files = LocalizedStringResource("Files", table: "Feedback")
        static let addFiles = LocalizedStringResource("Add files", table: "Feedback")
        static let add = LocalizedStringResource("Add", table: "Feedback")
        static let addPhotoOrFile = LocalizedStringResource("Add a photo or a file", table: "Feedback")
        static let attached = LocalizedStringResource("Attached", table: "Feedback")
        static let onlyWhileRunning = LocalizedStringResource(
            "Only while the virtual machine is running", table: "Feedback")
        static let createBugReport = LocalizedStringResource("Create bug report", table: "Feedback")
        static let sendWithoutBugReport = LocalizedStringResource("Send without bug report", table: "Feedback")
        static let cancel = LocalizedStringResource("Cancel", table: "Feedback")
        static let discard = LocalizedStringResource("Discard", table: "Feedback")
        static let keepEditing = LocalizedStringResource("Keep editing", table: "Feedback")
        static let ok = LocalizedStringResource("OK", table: "Feedback")
        static let hide = LocalizedStringResource("Hide", table: "Feedback")
        static let show = LocalizedStringResource("Show", table: "Feedback")
        static let hideDetails = LocalizedStringResource("Hide app and device details", table: "Feedback")
        static let showDetails = LocalizedStringResource("Show app and device details", table: "Feedback")
    }

    init(app: AppModel) {
        _model = State(initialValue: SendFeedbackModel(app: app))
    }

    private var state: SendFeedbackForm { model.state }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if model.showsNoGoogleLine {
                        NoGoogleFeedbackLine(model: model)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                    if !state.mailAvailable {
                        mailUnavailable
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                    Group {
                        subject
                        Divider().padding(.leading, 20)
                        bodyText
                        if !state.attachments.isEmpty { attachments }
                        information
                    }
                    .disabled(!state.mailAvailable)
                    .opacity(state.mailAvailable ? 1 : 0.45)
                    Color.clear.frame(height: 1).id(Self.endID)
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            // The block that opens is the last thing in the mail: bring it into view.
            .onChange(of: model.showsInformation) { _, shown in
                guard shown else { return }
                withAnimation(.snappy) { proxy.scrollTo(Self.endID, anchor: .bottom) }
            }
            }
            .background(Color(.systemBackground))
            .safeAreaBar(edge: .bottom) { bar }
            .navigationTitle(Text("Send feedback", tableName: "Feedback"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Words.cancel, systemImage: "xmark", role: .cancel, action: cancel)
                        .accessibilityIdentifier("feedback-cancel")
                }
            }
            // What a file holds opens inside the sheet, as Files opens a folder: Back returns to the mail.
            .navigationDestination(item: $model.viewing) { attachment in
                SendFeedbackViewerRoot(attachment: attachment, state: model.reports[attachment.id])
            }
        }
        // Once the mail is sent the sheet stays as it was under the notice, and nothing in it acts: the notice's
        // own button closes the notice and the sheet together. The notice is outside this scope.
        .disabled(model.sent)
        .overlay {
            if let busy = model.app.feedbackBusy {
                BusyOverlay(state: busy)
            } else if let busy = model.fileBusy {
                BusyOverlay(state: busy)
            } else if model.sent {
                BusyOverlay(state: BusyState(
                    title: String(localized: "Feedback sent", table: "Feedback"),
                    detail: String(localized: "Thank you for helping make Andarium better.", table: "Feedback"),
                    result: BusyResult(failed: false, dismiss: BusyCancel { dismiss() })))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.app.feedbackBusy != nil)
        .animation(.easeInOut(duration: 0.2), value: model.fileBusy != nil)
        .animation(.easeInOut(duration: 0.2), value: model.sent)
        // Once something is typed or attached, a stray swipe loses nothing. Over the sent notice a swipe does
        // nothing: the notice's button is the way out.
        .interactiveDismissDisabled(
            state.hasContent || state.makingBugReport || model.fileBusy != nil || model.sent)
        // An alert, not a dialog: on an iPad a dialog is a popover that leaves out
        // its cancel button, and both choices must show.
        .alert(Text("Discard this feedback?", tableName: "Feedback"), isPresented: $model.confirmingDiscard) {
            Button(Words.discard, role: .destructive) { dismiss() }
            Button(Words.keepEditing, role: .cancel) {}
        }
        .alert(
            (model.failure?.title ?? "").keepingTogether,
            isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }),
            presenting: model.failure
        ) { failure in
            // An alert that asks for a link leaves the details ready for it.
            Button(Words.ok, role: .cancel) { if failure.focusesDetails { focus = .details } }
        } message: { failure in
            Text(failure.message.keepingTogether)
        }
        // The mail needs a problem and details: Send says which is empty, and the first empty field is
        // ready to be typed in once the alert is closed.
        .alert(
            Text("Can\u{2019}t send yet", tableName: "Feedback"),
            isPresented: Binding(get: { model.incomplete != nil }, set: { if !$0 { model.incomplete = nil } }),
            presenting: model.incomplete
        ) { missing in
            Button(Words.ok, role: .cancel) { focus = missing.focusesProblem ? .problem : .details }
        } message: { missing in
            Text(missing.message.keepingTogether)
        }
        // Send, with both fields written and no bug report while one can be made: the question comes first, and
        // the mail opens only from its second button. Create bug report makes the report as the bar's button
        // does and leaves the person in the sheet, to read it and tap Send again.
        .alert(
            Text("Send without a bug report?", tableName: "Feedback"),
            isPresented: $model.askingForBugReport
        ) {
            // First, so that it is the one at the top of the alert. It is not marked as the alert's preferred
            // action: iOS 27 draws a default-style preferred action's label in red on the tint's fill.
            Button(Words.createBugReport) { model.createBugReport() }
            Button(Words.sendWithoutBugReport) { model.sendWithoutBugReport() }
        } message: {
            Text(String(
                localized: "Without a bug report, a problem will most likely not get fixed. Send without one only if your message reports no problem, such as a suggestion or a question, or if you don\u{2019}t want to attach it.",
                table: "Feedback").keepingTogether)
        }
        .photosPicker(
            isPresented: $picking, selection: $picked, matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current
        )
        // The page the row pushes comes up over the fields: the keyboard goes.
        .onChange(of: model.viewing != nil) { _, viewing in
            if viewing { focus = nil } else { model.releaseViewerReaders() }
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task { await importPicked(items) }
        }
        // An account added in iOS Settings brings the sheet to life.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh() }
            if phase == .background { model.applicationEnteredBackground() }
        }
        // The keyboard goes with the notice: a field that kept the focus would take a hardware keyboard's text.
        .onChange(of: model.sent) { _, sent in
            if sent { focus = nil }
        }
        // The system gives the focus back to the field that had it when an alert closes, after the one the alert
        // asked for: let go of it first, as the alert that says what is missing does (`sendButton`).
        .onChange(of: model.failure?.focusesDetails == true) { _, asks in
            if asks { focus = nil }
        }
        .task {
            // Opened during a start, the sheet attaches its start log once; the
            // task runs again if the view is rebuilt, and the model remembers.
            model.offerStartLog()
            model.refuseAndroidPackagesInDraft()
            #if !APP_STORE
            await model.app.feedbackServices.previewPrepare(model)
            #endif
        }
        .onDisappear { model.close() }
        .presentationSizing(.page)
    }

    private func cancel() {
        // The notice's button closes the sheet; the discard question is for a draft that was not sent.
        guard !model.sent else { return }
        if state.hasContent {
            model.confirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func importPicked(_ items: [PhotosPickerItem]) async {
        await model.importMedia(loading: items.map { item in
            { try? await item.loadTransferable(type: SendFeedbackPickedFile.self) }
        })
    }

    // MARK: Mail not available

    private var mailUnavailable: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mail can\u{2019}t send from this \(model.app.host.name)", tableName: "Feedback")
                    .font(.subheadline.weight(.semibold))
                Text(String(
                    localized: "Feedback is sent with the Mail app. Add a mail account in Settings \u{203A} Apps \u{203A} Mail \u{203A} Mail Accounts, then come back.",
                    table: "Feedback").keepingTogether)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feedback-mail-unavailable")
    }

    // MARK: The mail

    private var subject: some View {
        @Bindable var model = model
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Problem", tableName: "Feedback")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(text: $model.form.problem, prompt: Text("What went wrong?", tableName: "Feedback")) {
                Text("Problem", tableName: "Feedback")
            }
                .fontWeight(.semibold)
                .focused($focus, equals: .problem)
                .submitLabel(.next)
                .onSubmit { focus = .details }
                .accessibilityIdentifier("feedback-problem")
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 50)
    }

    private var bodyText: some View {
        @Bindable var model = model
        return TextField(
            text: $model.form.details,
            prompt: Text("What did you do, and what happened?", tableName: "Feedback"), axis: .vertical
        ) {
            Text("Details", tableName: "Feedback")
        }
        .lineLimit(6...)
        .focused($focus, equals: .details)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .accessibilityIdentifier("feedback-details")
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.attachments.items) { attachment in
                row(attachment)
            }
            let total = Formats.size(bytes: state.attachments.totalBytes)
            let count = String(AttributedString(
                localized: "^[\(state.attachments.count) attachment](inflect: true)", table: "Feedback").characters)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if state.attachments.exceedsWarningSize {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                    Text(String(
                        localized: "\(count) \u{00B7} \(total). Some mail services refuse mail over 20 MiB.",
                        table: "Feedback").keepingTogether)
                } else {
                    Text("\(count) \u{00B7} \(total)", tableName: "Feedback")
                }
            }
            .font(.footnote)
            .foregroundStyle(state.attachments.exceedsWarningSize ? Color.orange : Color.secondary)
            .padding(.leading, 4)
            .accessibilityIdentifier("feedback-total")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private func row(_ attachment: SendFeedbackAttachment) -> some View {
        let opens = SendFeedbackModel.canView(attachment.kind)
        let files = model.reports[attachment.id]?.reader?.facts.fileCount
        return HStack(spacing: opens ? 0 : 12) {
            if opens {
                // The bug report and the start log open to what they hold, to read before the mail goes: the
                // whole row but its remove button leads in, and a hairline sets the button apart.
                Button { model.view(attachment) } label: {
                    HStack(spacing: 12) {
                        rowContent(attachment, files: files)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.trailing, 10)
                            .accessibilityHidden(true)
                    }
                    .padding(.leading, 8)
                    .frame(minHeight: 60)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.spoken(attachment, files: files))
                .accessibilityHint(Text(Self.viewHint(attachment.kind)))
                .accessibilityIdentifier("feedback-attachment-open")
                Rectangle()
                    .fill(Color(.separator))
                    .frame(width: 1, height: 28)
                    .accessibilityHidden(true)
            } else {
                rowContent(attachment, files: files)
                Spacer(minLength: 8)
            }
            Button { withAnimation(.snappy) { model.remove(attachment) } } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.removeLabel(attachment.kind))
        }
        .padding(.leading, opens ? 0 : 8)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("feedback-attachment")
    }

    /// The tile and the two lines of a row.
    private func rowContent(_ attachment: SendFeedbackAttachment, files: Int?) -> some View {
        HStack(spacing: 12) {
            picture(attachment)
                .frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                // A file is known by its name; the others by what they are.
                (attachment.kind == .file
                    ? Text(verbatim: attachment.displayName ?? attachment.fileName)
                    : Text(Self.title(attachment.kind)))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(attachment.kind == .file ? 1 : nil)
                    .truncationMode(.middle)
                Text(Self.detail(attachment, files: files))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spoken(attachment, files: files))
        }
    }

    /// What VoiceOver says a tap on a row that opens does.
    private static func viewHint(_ kind: SendFeedbackAttachment.Kind) -> LocalizedStringResource {
        kind == .startLog
            ? LocalizedStringResource("Shows the start log", table: "Feedback")
            : LocalizedStringResource("Shows what the bug report holds", table: "Feedback")
    }

    @ViewBuilder
    private func picture(_ attachment: SendFeedbackAttachment) -> some View {
        if let image = model.thumbnails[attachment.id] {
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                if attachment.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                }
            }
        } else {
            ZStack {
                Rectangle().fill(Color.accentColor.gradient)
                // A fixed size, as the tile is: a glyph that grew with the text would outgrow it.
                Image(systemName: Self.symbol(attachment.kind))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    static func symbol(_ kind: SendFeedbackAttachment.Kind) -> String {
        switch kind {
        case .bugReport: "ladybug.fill"
        case .screenshot: "camera.viewfinder"
        case .photo: "photo"
        case .video: "video.fill"
        case .startLog: "doc.text.fill"
        case .file: "doc.fill"
        }
    }

    private static func title(_ kind: SendFeedbackAttachment.Kind) -> LocalizedStringResource {
        switch kind {
        case .bugReport: Words.bugReport
        case .screenshot: Words.screenshot
        case .photo: LocalizedStringResource("Photo", table: "Feedback")
        case .video: LocalizedStringResource("Video", table: "Feedback")
        case .startLog: Words.startLog
        case .file: LocalizedStringResource("File", table: "Feedback")
        }
    }

    static func removeLabel(_ kind: SendFeedbackAttachment.Kind) -> LocalizedStringResource {
        switch kind {
        case .bugReport: LocalizedStringResource("Remove bug report", table: "Feedback")
        case .screenshot: LocalizedStringResource("Remove screenshot", table: "Feedback")
        case .photo: LocalizedStringResource("Remove photo", table: "Feedback")
        case .video: LocalizedStringResource("Remove video", table: "Feedback")
        case .startLog: LocalizedStringResource("Remove start log", table: "Feedback")
        case .file: LocalizedStringResource("Remove file", table: "Feedback")
        }
    }

    /// The line under the title: the picture's pixels or a video's length,
    /// then the size.
    static func detail(_ attachment: SendFeedbackAttachment, files: Int? = nil) -> String {
        var parts: [String] = []
        if let pixels = attachment.pixels { parts.append("\(pixels.width) \u{00D7} \(pixels.height)") }
        if let seconds = attachment.durationSeconds { parts.append(Formats.elapsed(seconds)) }
        parts.append(attachment.size)
        if let files { parts.append(SendFeedbackViewerWords.files(files)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// What VoiceOver reads for a row: its kind, a file's name, a video's length
    /// ("1 second", "42 seconds") and its size.
    static func spoken(_ attachment: SendFeedbackAttachment, files: Int? = nil) -> String {
        var parts = [String(localized: title(attachment.kind))]
        if attachment.kind == .file { parts.append(attachment.displayName ?? attachment.fileName) }
        if let seconds = attachment.durationSeconds {
            parts.append(String(AttributedString(
                localized: "^[\(seconds) second](inflect: true)", table: "Feedback").characters))
        }
        parts.append(attachment.size)
        if let files { parts.append(SendFeedbackViewerWords.files(files)) }
        return parts.joined(separator: ", ")
    }

    /// The block as it ends the mail, folded to its first lines.
    private var information: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "\u{2014}")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(model.information.text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(model.showsInformation ? nil : 2)
            Button(model.showsInformation ? Words.hide : Words.show) {
                withAnimation(.snappy) { model.showsInformation.toggle() }
            }
            .font(.caption.weight(.semibold))
            .accessibilityLabel(model.showsInformation ? Words.hideDetails : Words.showDetails)
        }
        .padding(.horizontal, 20)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("feedback-information")
    }

    // MARK: The bar

    private var showsCard: Bool {
        state.mailAvailable && state.attachments.bugReport == nil && !model.hintDismissed && focus == nil
            && !state.makingBugReport
    }

    private var bar: some View {
        VStack(spacing: 10) {
            if showsCard {
                card.transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ViewThatFits(in: .horizontal) {
                barContent(send: .words)
                barContent(send: .short)
                barContent(send: .icon)
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .disabled(!state.mailAvailable)
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: showsCard)
    }

    private enum SendStyle { case words, short, icon }

    private func barContent(send style: SendStyle) -> some View {
        HStack(spacing: 2) {
            if !state.running {
                // From Home neither can be made: dimmed, they bring the card
                // with the way to them back.
                let showWay = { withAnimation(.snappy) { model.hintDismissed = false } }
                source(symbol: "ladybug.fill", title: Words.bugReport, enabled: false, id: "feedback-bug-report",
                       hint: Words.onlyWhileRunning, action: showWay)
                source(symbol: "camera.viewfinder", title: Words.screenshot, enabled: false, id: "feedback-screenshot",
                       hint: Words.onlyWhileRunning, action: showWay)
            } else if state.attachments.bugReport != nil {
                // One report at most: attached, the button says so and does
                // nothing more; its row in the body removes it.
                source(symbol: "checkmark.circle.fill", title: Words.bugReport, enabled: true,
                       id: "feedback-bug-report", value: Words.attached, action: {})
                    .allowsHitTesting(false)
                source(symbol: "camera.viewfinder", title: Words.screenshot, enabled: state.canTakeScreenshot,
                       id: "feedback-screenshot", action: model.takeScreenshot)
            } else {
                source(symbol: "ladybug.fill", title: Words.bugReport, enabled: state.canMakeBugReport,
                       id: "feedback-bug-report", action: model.createBugReport)
                source(symbol: "camera.viewfinder", title: Words.screenshot, enabled: state.canTakeScreenshot,
                       id: "feedback-screenshot", action: model.takeScreenshot)
            }
            addMenu
            Spacer(minLength: 8)
            sendButton(style)
        }
    }

    /// What a button of the bar looks like: its symbol over its name.
    private func sourceLabel(symbol: String, title: LocalizedStringResource, enabled: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .frame(height: 22)
            Text(title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(enabled && state.mailAvailable ? Color.accentColor : Color(.tertiaryLabel))
        .padding(.horizontal, 3)
        .frame(minWidth: 54, minHeight: 48)
        .contentShape(.capsule)
    }

    /// One button for what comes from outside the app: a menu with the photo
    /// library and Files. Each item opens its picker as it did from its own
    /// button; the menu is the system's, anchored on the button.
    private var addMenu: some View {
        let enabled = state.canAddMedia || state.canAddFiles
        return Menu {
            Button { picking = true } label: {
                Label(Words.photos, systemImage: "photo.on.rectangle.angled")
            }
            .disabled(!state.canAddMedia)
            .accessibilityLabel(Text(Words.addPhotos))
            .accessibilityIdentifier("feedback-photos")
            Button(action: model.pickFiles) {
                Label(Words.files, systemImage: "doc")
            }
            .disabled(!state.canAddFiles)
            .accessibilityLabel(Text(Words.addFiles))
            .accessibilityIdentifier("feedback-files")
        } label: {
            sourceLabel(symbol: "paperclip", title: Words.add, enabled: enabled)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(!enabled)
        .accessibilityLabel(Text(Words.addPhotoOrFile))
        .accessibilityIdentifier("feedback-add")
    }

    private func source(
        symbol: String, title: LocalizedStringResource, enabled: Bool, id: String,
        hint: LocalizedStringResource? = nil, value: LocalizedStringResource? = nil,
        spoken: LocalizedStringResource? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            sourceLabel(symbol: symbol, title: title, enabled: enabled)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(spoken ?? title))
        .accessibilityValue(value.map { Text($0) } ?? Text(verbatim: ""))
        .accessibilityHint(hint.map { Text($0) } ?? Text(verbatim: ""))
        .accessibilityIdentifier(id)
    }

    /// The control that hands the mail to Mail. Its words shorten when the
    /// bar cannot hold them; its accessibility name never does.
    private func sendButton(_ style: SendStyle) -> some View {
        Button {
            // An alert that says what is missing, or asks about the bug report, would give the focus back to the
            // field that had it when it closes, after the first empty field was asked for: let go of it first.
            if state.missing != nil || state.asksAboutBugReportOnSend { focus = nil }
            model.send()
        } label: {
            Group {
                switch style {
                case .words:
                    HStack(spacing: 5) { Image(systemName: "arrow.up"); Text("Send feedback", tableName: "Feedback") }
                case .short:
                    HStack(spacing: 5) { Image(systemName: "arrow.up"); Text("Send", tableName: "Feedback") }
                case .icon: Image(systemName: "arrow.up")
                }
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, style == .icon ? 0 : 14)
            .frame(minWidth: 48, minHeight: 48)
            .background(Capsule().fill(state.readyToSend ? Color.accentColor : Color(.systemGray3)))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .disabled(!state.canSend)
        .accessibilityLabel(Text("Send feedback", tableName: "Feedback"))
        .accessibilityIdentifier("feedback-send")
        .fixedSize()
    }

    /// The request for a bug report, over the bar; from Home, where no virtual
    /// machine runs, the way to one.
    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "ladybug.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                switch state.tip {
                case .running:
                    Text(
                        "For any bug, attach a bug report. It tells us what the virtual machine and the app were doing.",
                        tableName: "Feedback")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(Words.createBugReport, action: model.createBugReport)
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                        .disabled(!state.canMakeBugReport)
                        .accessibilityIdentifier("feedback-create-bug-report")
                case .starting:
                    // The virtual machine is starting, so there is nothing to
                    // start: the log of the start is what goes with the mail.
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reporting a slow start?", tableName: "Feedback")
                            .font(.subheadline.weight(.semibold))
                        Text(String(
                            localized: "A bug report and a screenshot need the virtual machine to finish starting. The start log is attached.",
                            table: "Feedback").keepingTogether)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                case .home:
                    // No virtual machine runs, so no bug report can be made here: the card says what one is worth,
                    // and the way to one.
                    Text(String(
                        localized: "Without a bug report, a problem will most likely not get fixed.",
                        table: "Feedback").keepingTogether)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    SendFeedbackSteps(font: .footnote)
                }
            }
            Spacer(minLength: 0)
            Button { withAnimation(.snappy) { model.hintDismissed = true } } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss", tableName: "Feedback"))
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .accessibilityIdentifier("feedback-card")
    }
}

/// The way to a bug report from where no virtual machine runs (Home): start it,
/// make the problem happen again, and open Send feedback from the session's
/// Settings with a bug report attached. VoiceOver reads them as one, numbers included.
struct SendFeedbackSteps: View {
    @ScaledMetric(relativeTo: .subheadline) private var badge: CGFloat = 20
    var font: Font = .subheadline

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            step(1, LocalizedStringResource("Start the virtual machine.", table: "Feedback"))
            step(2, LocalizedStringResource("Make the problem happen again.", table: "Feedback"))
            step(3, LocalizedStringResource(
                "Tap the side keys, then Settings \u{203A} Send feedback, and attach a bug report.", table: "Feedback"))
        }
        .accessibilityElement(children: .combine)
    }

    private func step(_ number: Int, _ words: LocalizedStringResource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: badge, height: badge)
                .background(Color.accentColor, in: .circle)
            Text(String(localized: words).keepingTogether)
                .font(font)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#endif
