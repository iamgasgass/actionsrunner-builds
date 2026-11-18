// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import Foundation

// What the viewer makes of the bytes of an archive: which entries are text,
// text in windows, and the readers that keep one open archive or entry each,
// off the main thread. Text is shown as plain text only: what is not valid
// UTF-8 and what a screen would obey (control and formatting characters, the
// ones that reverse text among them) becomes U+FFFD.

nonisolated enum SendFeedbackText {
    /// Plain text for the screen: invalid bytes were already replaced by the decoder; line ends become
    /// one kind, a tab stays, and any other control or formatting character becomes U+FFFD.
    static func sanitize(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var previousWasReturn = false
        for scalar in text.unicodeScalars {
            defer { previousWasReturn = scalar == "\r" }
            switch scalar {
            case "\n":
                if !previousWasReturn { result.append("\n") }
            case "\r":
                result.append("\n")
            case "\t":
                result.append(scalar)
            default:
                result.append(SendFeedbackNames.isControl(scalar) ? "\u{FFFD}" : scalar)
            }
        }
        return String(result)
    }

    /// The start of an entry looks like text: almost every byte is valid UTF-8 and almost none is a control.
    static func looksLikeText(_ head: Data) -> Bool {
        guard !head.isEmpty else { return true }
        var invalid = 0
        var controls = 0
        var total = 0
        for scalar in String(decoding: head, as: UTF8.self).unicodeScalars {
            total += 1
            if scalar == "\u{FFFD}" {
                invalid += 1
            } else if scalar.value < 0x20 && scalar != "\n" && scalar != "\r" && scalar != "\t" && scalar != "\u{0C}" {
                controls += 1
            }
        }
        return controls * 50 <= total && invalid * 20 <= total
    }

    /// The start of an entry is a zip: an archive inside the archive.
    static func looksLikeArchive(_ head: Data) -> Bool {
        let bytes = [UInt8](head.prefix(4))
        return bytes == [0x50, 0x4B, 0x03, 0x04] || bytes == [0x50, 0x4B, 0x05, 0x06]
    }

    /// A continuation byte of UTF-8: the middle or the end of a character, never its start.
    static func isContinuation(_ byte: UInt8) -> Bool { byte & 0xC0 == 0x80 }
}

/// One window of an entry's text: `index` of `count`, and what it says.
nonisolated struct SendFeedbackTextWindow: Equatable, Sendable {
    var index: Int
    var count: Int
    var text: String
}

/// Reads the text of one entry (or of a plain file) in windows of `windowBytes`.
/// A window is the lines that begin in its 16 KiB, to the end of the line it ends in, so that the windows
/// one after the other are the text with no line cut and no CR LF split, and a window is the same whichever
/// way it was reached. Windows read one after the other go on from where the last one ended.
actor SendFeedbackTextReader {
    private let stream: SendFeedbackEntryStream
    private var cached: [Int: SendFeedbackTextWindow] = [:]
    private var cachedOrder: [Int] = []
    private static let cacheCount = 4

    nonisolated let byteCount: UInt64
    nonisolated let windowBytes: Int

    init(_ location: SendFeedbackEntryLocation, windowBytes: Int = SendFeedbackArchiveLimits.windowBytes) {
        stream = SendFeedbackEntryStream(location)
        byteCount = location.size
        self.windowBytes = windowBytes
    }

    /// A plain file, shown the same way (the start log).
    init?(file url: URL) {
        guard let source = SendFeedbackFileBytes(url: url), source.length > 0 else { return nil }
        self.init(SendFeedbackEntryLocation(plain: source))
    }

    nonisolated var windowCount: Int {
        max(1, Int((byteCount + UInt64(windowBytes) - 1) / UInt64(windowBytes)))
    }

    func window(_ index: Int) throws -> SendFeedbackTextWindow {
        let index = min(max(0, index), windowCount - 1)
        if let hit = cached[index] { return hit }
        let size = byteCount
        let nominalStart = UInt64(index) * UInt64(windowBytes)
        let nominalEnd = min(size, nominalStart + UInt64(windowBytes))
        // From the byte before the start (a line may begin at the start) to a little past the end (the line the
        // window ends in is whole): the bytes both ends of the window are told from.
        let lookahead = SendFeedbackArchiveLimits.windowLookaheadBytes
        let readStart = nominalStart == 0 ? 0 : nominalStart - 1
        let readEnd = min(size, nominalEnd + UInt64(lookahead) + 4)
        let data = try stream.read(at: readStart, count: Int(readEnd - readStart))
        func byte(_ offset: UInt64) -> UInt8? {
            guard offset >= readStart, offset - readStart < UInt64(data.count) else { return nil }
            return data[data.startIndex + Int(offset - readStart)]
        }
        // Where the window that begins at `boundary` begins: after the first line feed from the byte before the
        // boundary on, so that the windows are whole lines and a CR LF is never split; and where there is none in
        // reach (a line longer than that), at a character, and not between a CR and its LF.
        func cut(_ boundary: UInt64) -> UInt64 {
            if boundary == 0 { return 0 }
            if boundary >= size { return size }
            var offset = boundary - 1
            while offset < boundary - 1 + UInt64(lookahead), offset < size, let next = byte(offset) {
                if next == 0x0A { return offset + 1 }
                offset += 1
            }
            var at = boundary
            while at < size, at < boundary + 3, let next = byte(at), SendFeedbackText.isContinuation(next) { at += 1 }
            if at < size, byte(at - 1) == 0x0D, byte(at) == 0x0A { at += 1 }
            return at
        }
        let start = cut(nominalStart)
        let end = max(start, cut(nominalEnd))
        let slice = data.subdata(in: (data.startIndex + Int(start - readStart))..<(data.startIndex + Int(end - readStart)))
        let made = SendFeedbackTextWindow(
            index: index, count: windowCount, text: SendFeedbackText.sanitize(String(decoding: slice, as: UTF8.self)))
        cached[index] = made
        cachedOrder.append(index)
        if cachedOrder.count > Self.cacheCount { cached[cachedOrder.removeFirst()] = nil }
        return made
    }
}

/// What opening an entry gives.
nonisolated enum SendFeedbackEntryContent: Sendable {
    case text(SendFeedbackTextReader)
    case archive(SendFeedbackArchiveReader)
    case picture
    case empty
    case unavailable(Reason)

    enum Reason: Equatable, Sendable {
        case folder
        case problem(SendFeedbackArchiveEntry.Problem)
        /// Not text: shown by name and size alone.
        case notText
        /// An archive that is itself deflated: reading its directory would mean inflating all of it.
        case compressedArchive
        /// An archive inside an archive inside the report.
        case tooDeep
        /// A picture the decoder was not given: refused, or beyond what is decoded.
        case pictureRefused
    }
}

/// What an entry is, told from its name and its first bytes, which is what a row says before it opens.
nonisolated enum SendFeedbackEntryKind: Equatable, Sendable {
    case text
    /// A PNG by its name and by its first bytes.
    case picture
    /// An archive stored inside, which opens like a folder.
    case archive
    case empty
    case notShown(SendFeedbackEntryContent.Reason)
}

extension SendFeedbackEntryKind {
    /// What a row shows once the read of its kind is over: what was read; what the row showed before when the read
    /// was cancelled (a row that was left, or that came back, has not found its file damaged); and damaged when
    /// the read failed.
    static func shown(after read: () async throws -> SendFeedbackEntryKind, keeping previous: SendFeedbackEntryKind?) async
        -> SendFeedbackEntryKind?
    {
        do {
            return try await read()
        } catch is CancellationError {
            return previous
        } catch {
            return .notShown(.problem(.damaged))
        }
    }
}

/// What the report is, from its directory: what the first page and the row say.
nonisolated struct SendFeedbackArchiveFacts: Equatable, Sendable {
    /// Entries that are files and not folders, the ones listed and the ones the bound left out.
    var fileCount: Int
    /// What the listed entries make once unpacked.
    var unpackedBytes: UInt64
}

/// An open archive: its listing, and the content of an entry on request. Reads happen on its own
/// executor, never on the main thread.
actor SendFeedbackArchiveReader {
    private let archive: SendFeedbackArchive
    private var kinds: [Int: SendFeedbackEntryKind] = [:]
    private var nested: [Int: SendFeedbackArchiveReader] = [:]
    /// The entries whose archive is kept open, the oldest first.
    private var nestedOrder: [Int] = []
    /// How many archives inside this one are kept open at once: the page shown and the one it came from.
    static let nestedKept = 2

    /// How many archives inside this one are open now (for the tests of the bound).
    var nestedCount: Int { nested.count }

    /// Lets go of the archives opened inside this one, when the pages that showed them are gone.
    func releaseNested() {
        nested = [:]
        nestedOrder = []
    }

    nonisolated var listing: SendFeedbackArchiveListing { archive.listing }
    nonisolated var depth: Int { archive.depth }
    /// The folders and files the names make.
    nonisolated let tree: SendFeedbackArchiveTree

    nonisolated var facts: SendFeedbackArchiveFacts {
        let files = archive.listing.entries.filter { !$0.isFolder }
        return SendFeedbackArchiveFacts(
            fileCount: files.count + archive.listing.unlistedFiles, unpackedBytes: archive.listing.totalBytes)
    }

    init(_ archive: SendFeedbackArchive) {
        self.archive = archive
        tree = SendFeedbackArchiveTree(entries: archive.listing.entries)
    }

    /// Opens the archive in `url`; throws what is wrong with it.
    static func open(file url: URL) async throws -> SendFeedbackArchiveReader {
        try await Task.detached(priority: .userInitiated) {
            guard let source = SendFeedbackFileBytes(url: url) else { throw SendFeedbackArchiveError.unavailable }
            return SendFeedbackArchiveReader(try SendFeedbackArchive.open(source))
        }.value
    }

    /// The whole of an entry, for a viewer that draws it itself (a picture), and only when it declares at most
    /// `limit` bytes, and never above `SendFeedbackArchiveLimits.maxWholeEntryBytes`. A larger entry throws
    /// `.tooLarge`; a folder, an encrypted entry and the like throw `.unsupported`; an entry whose bytes do
    /// not match the directory throws `.damaged`. Nothing is written to disk.
    func bytes(of entryID: Int, limit: Int) throws -> Data {
        guard let entry = archive.listing.entries.first(where: { $0.id == entryID }) else {
            throw SendFeedbackArchiveError.damaged
        }
        if entry.isFolder || entry.problem != nil { throw SendFeedbackArchiveError.unsupported }
        let allowed = UInt64(min(max(0, limit), SendFeedbackArchiveLimits.maxWholeEntryBytes))
        guard entry.size <= allowed else { throw SendFeedbackArchiveError.tooLarge }
        if entry.size == 0 { return Data() }
        let stream = SendFeedbackEntryStream(try archive.location(of: entry))
        return try stream.read(at: 0, count: Int(entry.size), keepsTail: false)
    }

    /// What an entry is, from its name and its first bytes (a few KiB read, and inflated if it is deflated).
    func kind(of entryID: Int) throws -> SendFeedbackEntryKind {
        if let known = kinds[entryID] { return known }
        let made = try classify(entryID)
        kinds[entryID] = made
        return made
    }

    /// A picture that was opened and refused is a row that is not shown from then on.
    func refuse(_ entryID: Int) {
        kinds[entryID] = .notShown(.pictureRefused)
    }

    /// The archive stored in the bytes of `location`, one level down; nil when it does not open.
    private func openInner(_ location: SendFeedbackEntryLocation) -> SendFeedbackArchive? {
        guard let range = SendFeedbackRangeBytes(
            parent: archive.source, start: location.dataStart, length: location.size) else { return nil }
        return try? SendFeedbackArchive.open(range, depth: archive.depth + 1)
    }

    /// The reader of the archive an entry holds: the ones kept (at most `nestedKept`, the oldest let go first), or
    /// one opened now.
    private func nestedReader(_ entryID: Int) throws -> SendFeedbackArchiveReader {
        if let kept = nested[entryID] {
            nestedOrder.removeAll { $0 == entryID }
            nestedOrder.append(entryID)
            return kept
        }
        guard let entry = archive.listing.entries.first(where: { $0.id == entryID }),
              let opened = openInner(try archive.location(of: entry)) else { throw SendFeedbackArchiveError.damaged }
        let reader = SendFeedbackArchiveReader(opened)
        nested[entryID] = reader
        nestedOrder.append(entryID)
        while nestedOrder.count > Self.nestedKept { nested[nestedOrder.removeFirst()] = nil }
        return reader
    }

    private func classify(_ entryID: Int) throws -> SendFeedbackEntryKind {
        guard let entry = archive.listing.entries.first(where: { $0.id == entryID }) else {
            throw SendFeedbackArchiveError.damaged
        }
        if entry.isFolder { return .notShown(.folder) }
        if let problem = entry.problem { return .notShown(.problem(problem)) }
        if entry.size == 0 { return .empty }
        let location = try archive.location(of: entry)
        let stream = SendFeedbackEntryStream(location)
        let head = try stream.read(at: 0, count: SendFeedbackArchiveLimits.sniffBytes)
        switch SendFeedbackPicture.format(named: entry.path, head: head) {
        case .png:
            return entry.size <= UInt64(SendFeedbackArchiveLimits.maxWholeEntryBytes) ? .picture : .notShown(.pictureRefused)
        case .jpeg:
            return .notShown(.pictureRefused)
        case nil:
            break
        }
        if SendFeedbackText.looksLikeArchive(head) {
            if archive.depth >= 1 { return .notShown(.tooDeep) }
            guard !location.deflated else { return .notShown(.compressedArchive) }
            // Only told apart here: the archive is opened again when a page asks for it (`nestedReader`).
            if openInner(location) != nil { return .archive }
            return .notShown(.notText)
        }
        return SendFeedbackText.looksLikeText(head) ? .text : .notShown(.notText)
    }

    func content(of entryID: Int) throws -> SendFeedbackEntryContent {
        switch try kind(of: entryID) {
        case .text:
            guard let entry = archive.listing.entries.first(where: { $0.id == entryID }) else {
                throw SendFeedbackArchiveError.damaged
            }
            return .text(SendFeedbackTextReader(try archive.location(of: entry)))
        case .archive:
            return .archive(try nestedReader(entryID))
        case .picture: return .picture
        case .empty: return .empty
        case .notShown(let reason): return .unavailable(reason)
        }
    }

    /// The picture of an entry, as a thumbnail: its bytes read through `bytes(of:limit:)` and decoded off this
    /// reader, so that the reader is free meanwhile. A refusal marks the entry as not shown.
    func picture(of entryID: Int) async throws -> SendFeedbackPicture.Thumbnail {
        guard case .picture = try kind(of: entryID) else { throw SendFeedbackPicture.Refusal.notPicture }
        try Task.checkCancellation()
        let data = try bytes(of: entryID, limit: SendFeedbackArchiveLimits.maxWholeEntryBytes)
        do {
            // A detached task does not inherit the cancellation of the one that waits for it: pass it on.
            let decoding = Task.detached(priority: .userInitiated) {
                try SendFeedbackPicture.thumbnail(of: data)
            }
            return try await withTaskCancellationHandler { try await decoding.value } onCancel: { decoding.cancel() }
        } catch let refusal as SendFeedbackPicture.Refusal {
            refuse(entryID)
            throw refusal
        }
    }
}

#endif
