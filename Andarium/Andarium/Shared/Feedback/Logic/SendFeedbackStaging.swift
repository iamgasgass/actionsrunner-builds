// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import Foundation

/// Where the files of a draft wait: one folder of the temporary directory per
/// open sheet, so they are never in Documents (the harness's) or a backup. The
/// sheet removes its folder when it closes and when the mail has been sent, and
/// a launch removes what an ended process left (`sweep`).
nonisolated struct SendFeedbackStaging: Sendable {
    let root: URL
    /// The free space of the volume that holds a URL, in bytes; nil when it
    /// cannot be read. A test gives its own figure.
    let freeBytes: @Sendable (URL) -> UInt64?

    /// Room a copy asks to be left free when it starts. The look is made once,
    /// before the first byte: a device that fills meanwhile ends the copy as
    /// "not enough space", with no partial file.
    static let spareBytes: UInt64 = 64 * 1_048_576

    init(
        root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Feedback", isDirectory: true),
        freeBytes: @escaping @Sendable (URL) -> UInt64? = SendFeedbackStaging.liveFreeBytes
    ) {
        self.root = root
        self.freeBytes = freeBytes
    }

    /// What the system says it can free for the app's use on the volume of
    /// `url` or, while it is not made yet, of its nearest folder.
    static func liveFreeBytes(_ url: URL) -> UInt64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe.deleteLastPathComponent()
        }
        guard let free = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { return nil }
        return UInt64(max(free, 0))
    }

    /// Where the system's picker leaves a copy of a file until the sheet takes
    /// it into its folder.
    var incoming: URL { root.appendingPathComponent("incoming", isDirectory: true) }

    /// Removes everything under the root.
    func sweep() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A folder for one sheet; made when its first file arrives.
    func makeFolder() -> SendFeedbackFolder {
        SendFeedbackFolder(url: root.appendingPathComponent(UUID().uuidString, isDirectory: true), freeBytes: freeBytes)
    }
}

/// One sheet's folder of staged files.
nonisolated final class SendFeedbackFolder: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private let freeBytes: @Sendable (URL) -> UInt64?
    /// The names handed out, as `SendFeedbackNames.key` writes them: two names that differ only in their
    /// letters' case or in how an accent is composed are one name to a mail and to a volume that ignores both.
    private var reserved: Set<String> = []

    init(url: URL, freeBytes: @escaping @Sendable (URL) -> UInt64? = SendFeedbackStaging.liveFreeBytes) {
        self.url = url
        self.freeBytes = freeBytes
    }

    /// A path in the folder for a file called `name`, made unique and with the
    /// folder in place; nothing is written yet.
    func reserve(_ name: String) throws -> URL {
        try lock.withLock {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let present = Set((try? FileManager.default.contentsOfDirectory(atPath: url.path))?.map(SendFeedbackNames.key) ?? [])
            var candidate = Self.safeName(name)
            var number = 2
            while reserved.contains(SendFeedbackNames.key(candidate)) || present.contains(SendFeedbackNames.key(candidate)) {
                candidate = SendFeedbackNames.numbered(Self.safeName(name), number)
                number += 1
            }
            reserved.insert(SendFeedbackNames.key(candidate))
            return url.appendingPathComponent(candidate)
        }
    }

    /// Moves `file` (on the same volume) into the folder under `name`.
    func adopt(_ file: URL, named name: String) throws -> URL {
        let target = try reserve(name)
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }

    /// Copies `source`, wherever the person keeps it, into the folder under
    /// `name`, and leaves `source` alone. The file is read through the
    /// system's file coordination, so a provider fetches it first, and is
    /// streamed in 1 MiB pieces, so a file of any size is never in memory.
    /// Refuses before the first byte when `bytes` and a margin do not fit in
    /// the free space, and leaves no partial copy when it is cancelled, the
    /// room runs out or the source stops answering. `progress` gets the bytes
    /// copied so far, at most ten times a second.
    func stageCopy(
        of source: URL, bytes: UInt64, named name: String, cancellation: SendFeedbackCancellation,
        progress: @Sendable (UInt64) -> Void
    ) throws -> URL {
        if cancellation.isCancelled { throw SendFeedbackFileRefusal.cancelled }
        if let free = freeBytes(url), free < bytes + SendFeedbackStaging.spareBytes {
            throw SendFeedbackFileRefusal.notEnoughSpace
        }
        // The free-space look can take a while: the person may have stopped meanwhile.
        if cancellation.isCancelled { throw SendFeedbackFileRefusal.cancelled }
        let target: URL
        do {
            target = try reserve(name)
        } catch {
            throw Self.refusal(for: error)
        }
        var outcome: Result<Void, Error> = .failure(SendFeedbackFileRefusal.unavailable)
        // `cancel` is the one call the class allows from another thread.
        nonisolated(unsafe) let coordinator = NSFileCoordinator(filePresenter: nil)
        cancellation.onCancel { coordinator.cancel() }
        defer { cancellation.clearHook() }
        var coordination: NSError?
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordination) { readable in
            outcome = Result { try Self.stream(readable, to: target, cancellation: cancellation, progress: progress) }
        }
        do {
            if cancellation.isCancelled { throw SendFeedbackFileRefusal.cancelled }
            if coordination != nil { throw SendFeedbackFileRefusal.unavailable }
            try outcome.get()
            return target
        } catch {
            remove(target)
            throw Self.refusal(for: error)
        }
    }

    private static func stream(
        _ source: URL, to target: URL, cancellation: SendFeedbackCancellation, progress: @Sendable (UInt64) -> Void
    ) throws {
        let input = open(source.path, O_RDONLY | O_CLOEXEC)
        guard input >= 0 else { throw SendFeedbackFileRefusal.unavailable }
        defer { close(input) }
        let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw refusal(forErrno: errno) }
        var complete = false
        defer {
            close(output)
            if !complete { unlink(target.path) }
        }
        let size = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16384)
        defer { buffer.deallocate() }
        var copied: UInt64 = 0
        var reported = DispatchTime(uptimeNanoseconds: 0)
        while true {
            if cancellation.isCancelled { throw SendFeedbackFileRefusal.cancelled }
            let count = read(input, buffer, size)
            if count < 0 {
                if errno == EINTR { continue }
                throw SendFeedbackFileRefusal.unavailable
            }
            if count == 0 { break }
            var written = 0
            while written < count {
                let put = write(output, buffer + written, count - written)
                if put < 0 {
                    if errno == EINTR { continue }
                    throw refusal(forErrno: errno)
                }
                written += put
            }
            copied += UInt64(count)
            let now = DispatchTime.now()
            if now.uptimeNanoseconds - reported.uptimeNanoseconds >= 100_000_000 {
                reported = now
                progress(copied)
            }
        }
        // A file that emptied under the copy is empty, not a copy.
        guard copied > 0 else { throw SendFeedbackFileRefusal.empty }
        progress(copied)
        complete = true
    }

    private static func refusal(forErrno code: Int32) -> SendFeedbackFileRefusal {
        code == ENOSPC || code == EDQUOT ? .notEnoughSpace : .unavailable
    }

    private static func refusal(for error: Error) -> Error {
        if error is SendFeedbackFileRefusal { return error }
        if let cocoa = error as? CocoaError, cocoa.code == .fileWriteOutOfSpace { return SendFeedbackFileRefusal.notEnoughSpace }
        if let posix = error as? POSIXError { return refusal(forErrno: posix.code.rawValue) }
        return SendFeedbackFileRefusal.unavailable
    }

    /// Removes a file of the folder. A file anywhere else is none of the
    /// folder's: the person's own file, opened where it is, is never deleted.
    func remove(_ file: URL) {
        guard file.deletingLastPathComponent().resolvingSymlinksInPath() == url.resolvingSymlinksInPath() else { return }
        lock.withLock { _ = reserved.remove(SendFeedbackNames.key(file.lastPathComponent)) }
        try? FileManager.default.removeItem(at: file)
    }

    /// Removes the folder and what is in it.
    func removeAll() {
        lock.withLock {
            reserved = []
            try? FileManager.default.removeItem(at: url)
        }
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A file name safe in a folder and in a mail: the name as the person
    /// wrote it, in whatever script. Only what a path or a header would obey is
    /// replaced by "_": the path separators, and every control character, among
    /// them the ones that reverse text and break lines. A leading dot is taken
    /// off, and the name is cut to at most 100 characters and 200 bytes (a
    /// volume's limit is 255 bytes), with a short extension kept whole.
    static func safeName(_ name: String) -> String {
        var text = String(String.UnicodeScalarView(name.unicodeScalars.map { scalar in
            switch scalar {
            case "/", "\\", ":": return "_"
            default: return SendFeedbackNames.isControl(scalar) ? "_" : scalar
            }
        }))
        while text.hasPrefix(".") { text.removeFirst() }
        guard !text.isEmpty else { return "file" }
        guard !SendFeedbackNames.fits(text) else { return text }
        let (base, ext) = SendFeedbackNames.split(text)
        if !ext.isEmpty && ext.count <= SendFeedbackNames.maxExtensionLength {
            let tail = "." + ext
            return SendFeedbackNames.cut(
                base, characters: SendFeedbackNames.maxLength - tail.count, bytes: SendFeedbackNames.maxBytes - tail.utf8.count)
                + tail
        }
        return SendFeedbackNames.cut(text, characters: SendFeedbackNames.maxLength, bytes: SendFeedbackNames.maxBytes)
    }
}

#endif
