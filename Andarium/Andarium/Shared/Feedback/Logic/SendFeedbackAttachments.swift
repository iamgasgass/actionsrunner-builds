// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import AndariumCore
import Foundation
import UniformTypeIdentifiers

/// One file that goes with the mail: staged in the sheet's folder, which is
/// removed when the sheet closes, or, for a file the person picked from Files,
/// where it is kept (`inPlace`).
nonisolated struct SendFeedbackAttachment: Identifiable, Hashable, Sendable {
    enum Kind: Equatable, Sendable {
        case bugReport, screenshot, photo, video
        /// What the sheet attaches by itself when it opens during a start.
        case startLog
        /// Any other file, picked from Files.
        case file

        /// The name the mail gives a file the app made itself: fixed English words and the moment it was
        /// made (`SendFeedbackNames.stamp`), whatever the interface language and whatever the file is
        /// called where it is staged (the guest names its own report). A file the person picked keeps
        /// its own name.
        func generatedFileName(at date: Date) -> String? {
            switch self {
            case .bugReport: "bugreport-\(SendFeedbackNames.stamp(date)).zip"
            case .screenshot: "screenshot-\(SendFeedbackNames.stamp(date)).png"
            case .startLog: "start-log-\(SendFeedbackNames.stamp(date)).txt"
            case .photo, .video, .file: nil
            }
        }
    }

    let id: UUID
    var kind: Kind
    var url: URL
    var bytes: UInt64
    /// The picture's size in pixels, for a screenshot or a photo.
    var pixels: SendFeedbackPixels?
    /// A video's length.
    var durationSeconds: Int?
    /// A picked file's name as the person knows it, for its row.
    var displayName: String?
    /// The name the mail carries, when it is not the file's own: a picked
    /// file's name made safe, and any name that another attachment has.
    var mailName: String?
    /// When the app made the file, for the date in a generated file's mail name.
    var madeAt: Date
    /// `url` is the person's own file, opened where it is kept under an access
    /// the sheet holds until the attachment is removed. It is never moved or
    /// deleted, only released.
    var inPlace: Bool

    init(
        id: UUID = UUID(), kind: Kind, url: URL, bytes: UInt64, pixels: SendFeedbackPixels? = nil,
        durationSeconds: Int? = nil, displayName: String? = nil, mailName: String? = nil, inPlace: Bool = false,
        madeAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.url = url
        self.bytes = bytes
        self.pixels = pixels
        self.durationSeconds = durationSeconds
        self.displayName = displayName
        self.mailName = mailName
        self.inPlace = inPlace
        self.madeAt = madeAt
    }

    /// The name the mail gives the file: a numbered one when another attachment has its name, else the
    /// fixed name of a file the app made, else the file's own.
    var fileName: String { mailName ?? kind.generatedFileName(at: madeAt) ?? url.lastPathComponent }

    /// The type the composer is told the file has.
    var mimeType: String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// The file's bytes for the composer, mapped: its pages are read as the
    /// composer copies them, never all held in memory at once, whatever the
    /// size.
    func mappedData() throws -> Data {
        try Data(contentsOf: url, options: .alwaysMapped)
    }

    var size: String { Formats.size(bytes: bytes) }
}

nonisolated struct SendFeedbackPixels: Hashable, Sendable {
    var width: Int
    var height: Int
}

/// The files of a draft, in the order they were added, and what the mail
/// service may think of them together.
nonisolated struct SendFeedbackAttachments: Equatable, Sendable {
    /// Above this many bytes in all, a mail service may refuse the mail. The
    /// composer applies its own rules; Send is never blocked by it.
    static let warningBytes: UInt64 = 20 * Limits.bytesPerMiB

    private(set) var items: [SendFeedbackAttachment] = []

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    var totalBytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }
    var exceedsWarningSize: Bool { totalBytes > Self.warningBytes }
    var bugReport: SendFeedbackAttachment? { items.first { $0.kind == .bugReport } }

    /// Adds a file at the end, except a bug report, which goes first and
    /// replaces the one already there. Returns the file it replaced. A name
    /// another attachment has already (whatever the letters' case) is numbered
    /// in the mail, so no two files of a mail share a name.
    @discardableResult
    mutating func add(_ attachment: SendFeedbackAttachment) -> SendFeedbackAttachment? {
        var attachment = attachment
        var replaced: SendFeedbackAttachment?
        if attachment.kind == .bugReport, let index = items.firstIndex(where: { $0.kind == .bugReport }) {
            replaced = items.remove(at: index)
        }
        attachment.mailName = uniqueName(of: attachment)
        if attachment.kind == .bugReport {
            items.insert(attachment, at: 0)
        } else {
            items.append(attachment)
        }
        return replaced
    }

    /// The mail name `attachment` is to carry: its own while no other has it.
    private func uniqueName(of attachment: SendFeedbackAttachment) -> String? {
        let taken = Set(items.map { SendFeedbackNames.key($0.fileName) })
        let name = attachment.fileName
        guard taken.contains(SendFeedbackNames.key(name)) else { return attachment.mailName }
        var number = 2
        while taken.contains(SendFeedbackNames.key(SendFeedbackNames.numbered(name, number))) { number += 1 }
        return SendFeedbackNames.numbered(name, number)
    }

    /// A file's size as it is now, for one that changed after it was picked.
    mutating func update(_ id: SendFeedbackAttachment.ID, bytes: UInt64) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].bytes = bytes
    }

    @discardableResult
    mutating func remove(_ id: SendFeedbackAttachment.ID) -> SendFeedbackAttachment? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    mutating func removeAll() -> [SendFeedbackAttachment] {
        defer { items = [] }
        return items
    }

    /// Every file's bytes, mapped, in the order of the list: what the composer
    /// is given, so that a file that cannot be mapped now (it vanished between
    /// the last look at it and here) is found before the composer opens and
    /// not left out of the mail unseen. A failure names every file that
    /// could not be mapped.
    func mapAll() -> Result<[Data], SendFeedbackMappingFailure> {
        var data: [Data] = []
        var failed: [SendFeedbackAttachment.ID] = []
        for item in items {
            do {
                data.append(try item.mappedData())
            } catch {
                failed.append(item.id)
            }
        }
        return failed.isEmpty ? .success(data) : .failure(SendFeedbackMappingFailure(attachments: failed))
    }
}

/// The files that could not be mapped for the composer.
nonisolated struct SendFeedbackMappingFailure: Error, Equatable, Sendable {
    var attachments: [SendFeedbackAttachment.ID]
}

#endif
