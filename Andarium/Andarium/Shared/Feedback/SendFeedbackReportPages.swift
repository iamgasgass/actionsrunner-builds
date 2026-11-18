// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import AndariumCore
import SwiftUI

// What an attached bug report holds, to read before the mail goes: the pages the sheet's own navigation pushes,
// as Files opens a folder. The first page is the file as it travels, then its top level as folders and files;
// a text opens as one page that scrolls on (`SendFeedbackTextFlow.swift`), a picture as a picture. Reading only:
// nothing here changes, shares, exports, saves or copies a file, and the archive is never extracted.
// Everything in it was written by the virtual machine, so it is shown as plain text and as a thumbnail, read
// on demand by the bounded reader of `Logic/`.

#if !APP_STORE
/// Where the Simulator preview takes the pages: the entry it opens (the name the archive gives it), and the
/// place the text's thumb is held at (`FeedbackPreview`).
@MainActor
enum SendFeedbackViewerPreview {
    static var target: String?
    static var thumb: Double?
}
#endif

/// The words of the counts, which agree with the number in English.
enum SendFeedbackViewerWords {
    static func files(_ count: Int) -> String {
        String(AttributedString(localized: "^[\(count) file](inflect: true)", table: "Feedback").characters)
    }

    static func message(for error: SendFeedbackArchiveError) -> LocalizedStringResource {
        switch error {
        case .notAnArchive, .damaged:
            LocalizedStringResource(
                "This bug report can\u{2019}t be read. It may be damaged or cut short.", table: "Feedback")
        case .unsupported, .tooLarge:
            LocalizedStringResource("This bug report can\u{2019}t be shown here.", table: "Feedback")
        case .unavailable:
            LocalizedStringResource("The file couldn\u{2019}t be read.", table: "Feedback")
        }
    }
}

/// A line of words in the middle of a page: what cannot be shown.
struct SendFeedbackViewerMessage: View {
    let message: LocalizedStringResource

    var body: some View {
        Text(String(localized: message).keepingTogether)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("feedback-viewer-message")
    }
}

// MARK: The root

/// What the sheet pushes for a row that opens: the bug report's first page, or the start log's text.
struct SendFeedbackViewerRoot: View {
    let attachment: SendFeedbackAttachment
    let state: SendFeedbackReportState?

    var body: some View {
        if attachment.kind == .startLog {
            SendFeedbackStartLogPage(attachment: attachment)
        } else {
            switch state {
            case .ready(let reader):
                SendFeedbackFolderPage(
                    reader: reader, path: "", title: String(localized: "Bug report", table: "Feedback"),
                    top: .report(name: attachment.fileName, size: attachment.size))
            case .failed(let error):
                SendFeedbackViewerMessage(message: SendFeedbackViewerWords.message(for: error))
                    .navigationTitle(Text("Bug report", tableName: "Feedback"))
                    .navigationBarTitleDisplayMode(.inline)
            case .opening, nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(Text("Bug report", tableName: "Feedback"))
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

/// The start log, a text, as one page.
struct SendFeedbackStartLogPage: View {
    let attachment: SendFeedbackAttachment
    @State private var reader: SendFeedbackTextReader?
    @State private var failed = false

    var body: some View {
        Group {
            if let reader {
                SendFeedbackTextFlowPage(
                    reader: reader, name: String(localized: "Start log", table: "Feedback"), size: reader.byteCount)
            } else if failed {
                SendFeedbackViewerMessage(message: LocalizedStringResource(
                    "The file couldn\u{2019}t be read.", table: "Feedback"))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(Text("Start log", tableName: "Feedback"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let made = SendFeedbackTextReader(file: attachment.url) { reader = made } else { failed = true }
        }
    }
}

// MARK: Folders

/// One level of an archive: the top level, a folder, or the archive inside another. A folder that holds
/// nothing but one folder is shown as one row, as Files shows a chain.
struct SendFeedbackFolderPage: View {
    /// What the first page of a file says about the file.
    enum Top {
        case report(name: String, size: String)
        case nested(name: String, size: String)
    }

    let reader: SendFeedbackArchiveReader
    let path: String
    let title: String
    var top: Top?

    private enum Route: Hashable {
        case folder(SendFeedbackArchiveTree.Folder)
        case entry(SendFeedbackArchiveTree.File)
    }

    #if !APP_STORE
    @State private var auto: Route?
    @State private var hopped = false
    #endif

    var body: some View {
        let level = reader.tree.level(at: path)
        List {
            if let top {
                Section { header(top) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
            }
            Section {
                ForEach(level.folders, id: \.path) { folder in
                    NavigationLink { destination(.folder(folder)) } label: { folderRow(folder) }
                        .accessibilityIdentifier("feedback-viewer-folder")
                }
                ForEach(level.files, id: \.entry.id) { file in
                    SendFeedbackFileRow(reader: reader, file: file)
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 8, for: .scrollContent)
        .accessibilityIdentifier("feedback-viewer-list")
        .overlay {
            if level.folders.isEmpty && level.files.isEmpty {
                SendFeedbackViewerMessage(message: LocalizedStringResource(
                    "This archive has no files.", table: "Feedback"))
            }
        }
        .navigationTitle(Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
        #if !APP_STORE
        .navigationDestination(item: $auto) { destination($0) }
        .task {
            // The Simulator preview opens the pages down to the entry it names.
            guard !hopped, let target = SendFeedbackViewerPreview.target else { return }
            hopped = true
            try? await Task.sleep(for: .milliseconds(450))
            if let folder = level.folders.first(where: { target == $0.path || target.hasPrefix($0.path + "/") }) {
                auto = .folder(folder)
            } else if let file = level.files.first(where: { $0.entry.path == target }) {
                auto = .entry(file)
            }
        }
        #endif
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .folder(let folder):
            SendFeedbackFolderPage(
                reader: reader, path: folder.path,
                title: folder.path.split(separator: "/").last.map(String.init) ?? folder.label)
        case .entry(let file):
            SendFeedbackEntryPage(reader: reader, entry: file.entry, label: SendFeedbackFileRow.name(of: file))
        }
    }

    private func header(_ top: Top) -> some View {
        let facts = reader.facts
        let name: String, size: String, sentence: LocalizedStringResource
        switch top {
        case .report(let fileName, let fileSize):
            name = fileName
            size = fileSize
            sentence = LocalizedStringResource("This file goes with your mail as it is.", table: "Feedback")
        case .nested(let fileName, let fileSize):
            name = fileName
            size = fileSize
            sentence = LocalizedStringResource("Inside the bug report.", table: "Feedback")
        }
        let unpacked = String(localized: "\(Formats.size(bytes: facts.unpackedBytes)) unpacked", table: "Feedback")
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.gradient, in: .rect(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: [size, SendFeedbackViewerWords.files(facts.fileCount), unpacked]
                        .joined(separator: " \u{00B7} "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(String(localized: sentence).keepingTogether)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if reader.listing.unlistedCount > 0 {
                    Text(String(
                        localized: "Only the first \(reader.listing.entries.count) files are listed.", table: "Feedback")
                        .keepingTogether)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feedback-viewer-summary")
    }

    private func folderRow(_ folder: SendFeedbackArchiveTree.Folder) -> some View {
        let files = SendFeedbackViewerWords.files(folder.files)
        let size = Formats.size(bytes: folder.bytes)
        return HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.accentColor.gradient)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: folder.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "\(files) \u{00B7} \(size)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [
            folder.label, String(localized: "Folder", table: "Feedback"), files, size,
        ].joined(separator: ", ")))
    }
}

// MARK: Files

/// A file of a folder: its name, its size and what it is. It opens when it is text, a picture or an archive; a
/// file that is none of them is dimmed, says so, and opens nothing.
struct SendFeedbackFileRow: View {
    let reader: SendFeedbackArchiveReader
    let file: SendFeedbackArchiveTree.File
    @State private var kind: SendFeedbackEntryKind?

    static func name(of file: SendFeedbackArchiveTree.File) -> String {
        file.label.isEmpty ? String(localized: "Unnamed file", table: "Feedback") : file.label
    }

    private var opens: Bool {
        switch kind {
        case .text, .picture, .archive: true
        default: false
        }
    }

    private var dimmed: Bool {
        if case .notShown = kind { return true }
        return kind == .empty
    }

    private var name: String { Self.name(of: file) }
    private var size: String { Formats.size(bytes: file.entry.size) }

    var body: some View {
        Group {
            if opens {
                NavigationLink {
                    SendFeedbackEntryPage(reader: reader, entry: file.entry, label: name)
                } label: {
                    content
                }
                .accessibilityIdentifier("feedback-viewer-entry")
            } else {
                content
                    .accessibilityIdentifier("feedback-viewer-notshown")
            }
        }
        // On every appearance: a picture that was refused while it was open is a dimmed row when the list is back.
        .task { kind = await SendFeedbackEntryKind.shown(after: { try await reader.kind(of: file.entry.id) }, keeping: kind) }
    }

    private var content: some View {
        let said = Self.said(kind).map { String(localized: $0) }
        return HStack(spacing: 12) {
            SendFeedbackGlyph(kind: kind)
                .opacity(dimmed ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                Text(verbatim: [size, said].compactMap { $0 }.joined(separator: " \u{00B7} "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ([name, size] + [said].compactMap { $0 }).joined(separator: ", ")))
    }

    /// What the row says of the file, after its size. Nothing while it is not known yet.
    static func said(_ kind: SendFeedbackEntryKind?) -> LocalizedStringResource? {
        switch kind {
        case nil: nil
        case .text: LocalizedStringResource("Text", table: "Feedback")
        case .picture: LocalizedStringResource("Picture", table: "Feedback")
        case .archive: LocalizedStringResource("Archive", table: "Feedback")
        case .empty: LocalizedStringResource("Empty", table: "Feedback")
        case .notShown(let reason):
            switch reason {
            case .notText, .folder: LocalizedStringResource("Not text, not shown", table: "Feedback")
            case .pictureRefused: LocalizedStringResource("Picture, not shown", table: "Feedback")
            case .compressedArchive, .tooDeep: LocalizedStringResource("Archive, not shown", table: "Feedback")
            case .problem(let problem):
                switch problem {
                case .encrypted: LocalizedStringResource("Encrypted, not shown", table: "Feedback")
                case .unsupportedCompression, .zip64: LocalizedStringResource("Not supported, not shown", table: "Feedback")
                case .tooLarge: LocalizedStringResource("Too large, not shown", table: "Feedback")
                case .damaged: LocalizedStringResource("Damaged, not shown", table: "Feedback")
                }
            }
        }
    }
}

/// A file's glyph, as Files in the app draws a file.
struct SendFeedbackGlyph: View {
    let kind: SendFeedbackEntryKind?
    var size: CGFloat = 32

    var body: some View {
        let (symbol, color): (String, Color) = switch kind {
        case .text: ("doc.text.fill", .blue)
        case .picture: ("photo.fill", .indigo)
        case .archive: ("doc.zipper", .brown)
        default: ("doc.fill", .gray)
        }
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: .rect(cornerRadius: size * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: An entry opened

/// One file opened: its text, the archive inside it as a folder, its picture, or why there is nothing to show.
struct SendFeedbackEntryPage: View {
    let reader: SendFeedbackArchiveReader
    let entry: SendFeedbackArchiveEntry
    let label: String
    @State private var loaded: Loaded = .loading

    private enum Loaded {
        case loading
        case text(SendFeedbackTextReader)
        case archive(SendFeedbackArchiveReader)
        case picture
        case message(LocalizedStringResource)
    }

    var body: some View {
        Group {
            switch loaded {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .text(let text):
                SendFeedbackTextFlowPage(reader: text, name: label, size: entry.size)
            case .archive(let inner):
                SendFeedbackFolderPage(
                    reader: inner, path: "", title: label,
                    top: .nested(name: label, size: Formats.size(bytes: entry.size)))
            case .picture:
                SendFeedbackPicturePage(reader: reader, entry: entry, label: label)
            case .message(let message):
                SendFeedbackViewerMessage(message: message)
                    .navigationTitle(Text(verbatim: label))
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            switch try await reader.content(of: entry.id) {
            case .text(let text): loaded = .text(text)
            case .archive(let inner): loaded = .archive(inner)
            case .picture: loaded = .picture
            case .empty, .unavailable:
                loaded = .message(LocalizedStringResource("This file can\u{2019}t be shown.", table: "Feedback"))
            }
        } catch is CancellationError {
            return
        } catch {
            loaded = .message(LocalizedStringResource("The file couldn\u{2019}t be read.", table: "Feedback"))
        }
    }
}

/// A picture of the bug report: a thumbnail, decoded by the reader off the main thread, at the size it is
/// shown and no larger. Nothing but scaling: no zoom, and nothing that shares, copies or saves it.
struct SendFeedbackPicturePage: View {
    let reader: SendFeedbackArchiveReader
    let entry: SendFeedbackArchiveEntry
    let label: String
    @State private var state: Loaded = .loading

    private enum Loaded {
        case loading
        case shown(SendFeedbackPicture.Thumbnail)
        case refused
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .shown(let picture):
                shown(picture)
            case .refused:
                SendFeedbackViewerMessage(message: LocalizedStringResource(
                    "This file can\u{2019}t be shown.", table: "Feedback"))
            }
        }
        .navigationTitle(Text(verbatim: label))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                state = .shown(try await reader.picture(of: entry.id))
            } catch is CancellationError {
                return
            } catch {
                state = .refused
            }
        }
    }

    private func shown(_ picture: SendFeedbackPicture.Thumbnail) -> some View {
        let pixels = "\(picture.width) \u{00D7} \(picture.height)"
        return VStack(spacing: 12) {
            Image(decorative: picture.image, scale: 1)
                .resizable()
                .scaledToFit()
                .clipShape(.rect(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator))
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: "\(String(localized: "Picture", table: "Feedback")), \(pixels)"))
                .accessibilityIdentifier("feedback-viewer-picture")
            Text(verbatim: "\(pixels) \u{00B7} \(Formats.size(bytes: entry.size))")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#endif
