// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import Foundation
import UniformTypeIdentifiers

// What Send feedback does with a file the person picks from Files: it stays
// where it is, the sheet holds the access the picker gave it, and the mail's
// composer maps it from there. A copy is made only of a file that cannot be
// used where it is. Plain values and rules, no UIKit.

/// Why a picked file did not become an attachment.
nonisolated enum SendFeedbackFileRefusal: Error, Equatable, Sendable {
    /// A folder or a package: only one file attaches as one file.
    case notAFile
    /// A file with nothing in it.
    case empty
    /// A copy would not fit in the free space.
    case notEnoughSpace
    /// Gone, or not handed over: its provider did not give it, or access to it
    /// was lost.
    case unavailable
    /// The person stopped the copy.
    case cancelled
    /// An Android package, which no mail service delivers
    /// (`SendFeedbackAndroidPackage`).
    case androidPackage
}

/// What a file is, found without reading any of it.
nonisolated struct SendFeedbackFileInspection: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case file
        /// A folder, and a package, which is a folder to the file system.
        case folder
        case other
        /// Not there, or not reachable.
        case missing
    }

    var kind: Kind
    var bytes: UInt64 = 0
    /// The bytes are on this device. A provider's file that is not downloaded
    /// (iCloud Drive keeps one as a placeholder) reads only after the system
    /// fetches it, which can take minutes and need room.
    var isLocal = true
    /// The file can be mapped where it is. Some volumes and providers refuse.
    var mappable = true
    /// The content type the file system or the provider gives it, from its
    /// metadata alone.
    var contentType: UTType?

    /// The composer can map it from where it is, at once.
    var usableInPlace: Bool { kind == .file && bytes > 0 && isLocal && mappable }

    /// `SF_DATALESS` of `<sys/stat.h>`: the file's data is not on this device.
    private static let datalessFlag: UInt32 = 0x4000_0000

    /// Looks at `url` with `stat`, one open and one page mapped: no byte of
    /// the file is read, and a placeholder is left unfetched.
    static func read(_ url: URL) -> SendFeedbackFileInspection {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return SendFeedbackFileInspection(kind: .missing) }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return SendFeedbackFileInspection(kind: .folder)
        case S_IFREG: break
        default: return SendFeedbackFileInspection(kind: .other)
        }
        var result = SendFeedbackFileInspection(kind: .file, bytes: UInt64(max(info.st_size, 0)))
        result.contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        result.isLocal = info.st_flags & datalessFlag == 0 && isDownloaded(url)
        // A placeholder is not opened: that would fetch it.
        if result.isLocal && result.bytes > 0 { result.mappable = canMapFirstPage(url, bytes: result.bytes) }
        return result
    }

    /// An iCloud Drive item that is current on this device.
    private static func isDownloaded(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]), values.isUbiquitousItem == true else { return true }
        return values.ubiquitousItemDownloadingStatus == .current
    }

    private static func canMapFirstPage(_ url: URL, bytes: UInt64) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let length = Int(min(bytes, 4096))
        guard let page = mmap(nil, length, PROT_READ, MAP_PRIVATE, descriptor, 0),
              page != UnsafeMutableRawPointer(bitPattern: -1) else { return false }
        munmap(page, length)
        return true
    }
}

/// What the model asks of the file system for a picked file, in one place a
/// test replaces: the access the picker granted, and the look at a file.
nonisolated struct SendFeedbackFileSystem: Sendable {
    /// Starts the access a picked URL carries; false when it carried none (a
    /// file of the app's own), which then needs no stop.
    var start: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    var stop: @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    var inspect: @Sendable (URL) -> SendFeedbackFileInspection = SendFeedbackFileInspection.read
}

/// The access held to the files of a draft, one per attachment, from the pick
/// until the attachment is removed or the sheet is gone: every start that the
/// system accepted is stopped exactly once.
nonisolated final class SendFeedbackScopes: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [UUID: URL] = [:]
    private let system: SendFeedbackFileSystem

    init(system: SendFeedbackFileSystem = SendFeedbackFileSystem()) {
        self.system = system
    }

    /// Starts the access `url` carries for the attachment `id`. True when one
    /// is held now; false when the URL carried none.
    @discardableResult
    func hold(_ id: UUID, _ url: URL) -> Bool {
        lock.withLock {
            if held[id] != nil { return true }
            guard system.start(url) else { return false }
            held[id] = url
            return true
        }
    }

    /// Stops what `id` holds, if anything.
    func release(_ id: UUID) {
        let url = lock.withLock { held.removeValue(forKey: id) }
        if let url { system.stop(url) }
    }

    func releaseAll() {
        let urls = lock.withLock {
            defer { held = [:] }
            return Array(held.values)
        }
        urls.forEach(system.stop)
    }

    var count: Int { lock.withLock { held.count } }
}

/// The way to stop a copy that runs on another thread. `onCancel` lets the
/// copy interrupt a wait the thread cannot (a provider's download).
nonisolated final class SendFeedbackCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var hook: (@Sendable () -> Void)?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let run = lock.withLock {
            cancelled = true
            defer { hook = nil }
            return hook
        }
        run?()
    }

    /// Runs `hook` on a cancel; at once when it already happened.
    func onCancel(_ hook: @escaping @Sendable () -> Void) {
        let now = lock.withLock {
            if !cancelled { self.hook = hook }
            return cancelled
        }
        if now { hook() }
    }

    func clearHook() {
        lock.withLock { hook = nil }
    }
}

/// Names of files in the row and in the mail.
nonisolated enum SendFeedbackNames {
    /// A name and its extension, the extension without its dot.
    static func split(_ name: String) -> (base: String, ext: String) {
        let ext = (name as NSString).pathExtension
        return (ext.isEmpty ? name : (name as NSString).deletingPathExtension, ext)
    }

    /// The longest name of a file in the mail, in characters and in UTF-8 bytes (a volume's limit is
    /// 255 bytes, and a name in Chinese or Japanese has three bytes to a character), and the longest
    /// extension kept whole when a name is cut to it.
    static let maxLength = 100
    static let maxBytes = 200
    static let maxExtensionLength = 16

    /// The name as a mail or a volume compares it: letters of any case are the same name (a string
    /// already equals another that spells an accent the other way, composed or not).
    static func key(_ name: String) -> String {
        name.lowercased()
    }

    static func fits(_ name: String) -> Bool {
        name.count <= maxLength && name.utf8.count <= maxBytes
    }

    /// `text` cut from its end to at most `characters` characters and `bytes` UTF-8 bytes.
    static func cut(_ text: String, characters: Int, bytes: Int) -> String {
        var result = ""
        var count = 0
        var used = 0
        for character in text {
            let size = character.utf8.count
            if count >= characters || used + size > bytes { break }
            result.append(character)
            count += 1
            used += size
        }
        return result
    }

    /// A moment as a file name carries it: `20261114-031512`, the same pattern as every generated name
    /// (`yyyyMMdd-HHmmss`), on the Gregorian calendar, in ASCII digits, in the device's time zone with no
    /// zone text. Nothing here follows the device's language, region, calendar or numbering system, so the name
    /// has the same shape wherever the mail is made.
    static func stamp(_ date: Date, in zone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func digits(_ value: Int?, _ width: Int) -> String {
            let text = String(max(value ?? 0, 0))
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return digits(parts.year, 4) + digits(parts.month, 2) + digits(parts.day, 2) + "-"
            + digits(parts.hour, 2) + digits(parts.minute, 2) + digits(parts.second, 2)
    }

    /// What a path or a header would obey, which a name never keeps: control and format characters
    /// (the ones that reverse text among them), line and paragraph separators, and what has no meaning.
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: true
        default: false
        }
    }

    /// `name` with `number` before its extension: `app-2.apk`. The suffix is inside the limits: a
    /// name already at them loses the end of its base, so two long names that differ only at the end
    /// stay distinct and short.
    static func numbered(_ name: String, _ number: Int) -> String {
        var (base, ext) = split(name)
        // A long "extension" is part of the name, as `SendFeedbackFolder.safeName` has it.
        if ext.count > maxExtensionLength { (base, ext) = (name, "") }
        let suffix = "-\(number)" + (ext.isEmpty ? "" : ".\(ext)")
        return cut(base, characters: max(1, maxLength - suffix.count), bytes: max(1, maxBytes - suffix.utf8.count)) + suffix
    }

    /// A file's name as the person knows it, for the row: whatever a screen
    /// should not obey (control and formatting characters, among them the
    /// ones that reverse the text) taken out, the rest as it is. nil when
    /// nothing is left.
    static func display(_ name: String) -> String? {
        let kept = name.unicodeScalars.filter { !isControl($0) }
        let text = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

#endif
