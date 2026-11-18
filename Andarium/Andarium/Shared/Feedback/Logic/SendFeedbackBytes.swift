// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import Foundation

// Where the bytes of an attached file are read from, for the viewer that shows
// what a bug report holds. Positional reads only: nothing is mapped or read
// whole, and a read never moves a position another reader of the same file
// depends on.

/// A run of bytes read at an offset. `read` returns fewer bytes than asked only
/// at the end, and throws when the medium fails.
nonisolated protocol SendFeedbackByteSource: Sendable {
    var length: UInt64 { get }
    func read(at offset: UInt64, count: Int) throws -> Data
}

/// A file opened for reading, read with `pread`. The descriptor is closed with
/// the object, which is also all a viewer does to let go of a file it never
/// copied.
nonisolated final class SendFeedbackFileBytes: SendFeedbackByteSource, @unchecked Sendable {
    private let descriptor: Int32
    let length: UInt64

    /// nil when the file cannot be opened, is not a regular file, or is empty.
    init?(url: URL) {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
        length = UInt64(max(info.st_size, 0))
    }

    deinit { close(descriptor) }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard count > 0, offset < length, offset <= UInt64(Int64.max) else { return Data() }
        let wanted = Int(min(UInt64(count), length - offset))
        var data = Data(count: wanted)
        var done = 0
        while done < wanted {
            let got = data.withUnsafeMutableBytes { buffer in
                pread(descriptor, buffer.baseAddress! + done, wanted - done, off_t(offset) + off_t(done))
            }
            if got < 0 {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown)
            }
            if got == 0 { break }
            done += got
        }
        return data.prefix(done)
    }
}

/// A part of another source: an entry of an archive that is stored, read as an
/// archive of its own. It cannot reach outside its range.
nonisolated struct SendFeedbackRangeBytes: SendFeedbackByteSource {
    let parent: any SendFeedbackByteSource
    let start: UInt64
    let length: UInt64

    /// nil when the range does not lie inside the parent.
    init?(parent: any SendFeedbackByteSource, start: UInt64, length: UInt64) {
        let (end, overflow) = start.addingReportingOverflow(length)
        guard !overflow, end <= parent.length else { return nil }
        self.parent = parent
        self.start = start
        self.length = length
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard count > 0, offset < length else { return Data() }
        return try parent.read(at: start + offset, count: Int(min(UInt64(count), length - offset)))
    }
}

/// Bytes in memory, for what is already there (a short text).
nonisolated struct SendFeedbackMemoryBytes: SendFeedbackByteSource {
    let data: Data

    init(_ data: Data) { self.data = data }

    var length: UInt64 { UInt64(data.count) }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard count > 0, offset < length else { return Data() }
        let start = data.startIndex + Int(offset)
        return Data(data[start..<min(data.endIndex, start + count)])
    }
}

#endif
