// SPDX-License-Identifier: GPL-2.0-or-later

import Darwin
import Foundation

/// Reads a file in pieces with POSIX `read` into one buffer it keeps, and
/// hands each piece out as a `Data` of its own. A transfer reads a file of
/// any length on the thread of an adb operation. That thread turns no run
/// loop, so its autorelease pool is emptied only when the thread ends, and a
/// `FileHandle` read, which returns an autoreleased object, would keep every
/// piece of a 3 GiB file alive until then. A `Data` made here is released when
/// its last reference goes.
///
/// The size is that of the open file (`fstat`). A coordinated read that has
/// brought an iCloud file down opens the file it has now, so the size is
/// never one cached from before.
public final class FileChunkReader {
    /// The file's length; zero for anything but a regular file.
    public let size: UInt64
    public let isDirectory: Bool
    private let descriptor: Int32
    private let buffer: UnsafeMutableRawPointer
    private let capacity: Int

    /// Opens `url` for reading. `capacity` is the largest piece `read` gives.
    public init(contentsOf url: URL, capacity: Int) throws {
        precondition(capacity > 0)
        let opened = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC)
        }
        guard opened >= 0 else { throw Self.failure(errno) }
        var status = stat()
        guard fstat(opened, &status) == 0 else {
            let code = errno
            Darwin.close(opened)
            throw Self.failure(code)
        }
        descriptor = opened
        isDirectory = status.st_mode & S_IFMT == S_IFDIR
        size = status.st_mode & S_IFMT == S_IFREG ? UInt64(max(status.st_size, 0)) : 0
        self.capacity = capacity
        buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    }

    deinit {
        Darwin.close(descriptor)
        buffer.deallocate()
    }

    /// The next piece of at most `limit` bytes (and never more than the
    /// capacity), or nil at the end of the file.
    public func read(upTo limit: Int) throws -> Data? {
        let count = min(limit, capacity)
        guard count > 0 else { return nil }
        while true {
            let got = Darwin.read(descriptor, buffer, count)
            if got > 0 { return Data(bytes: buffer, count: got) }
            if got == 0 { return nil }
            if errno != EINTR { throw Self.failure(errno) }
        }
    }

    private static func failure(_ code: Int32) -> Error {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
