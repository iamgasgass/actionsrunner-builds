// SPDX-License-Identifier: GPL-2.0-or-later

import Compression
import Foundation

@testable import AndariumFeedbackLogic

/// Zip archives made in memory for the bug report viewer's tests: the shape Android's report has (stored and
/// deflated entries, text and binary, folders), and the shapes an archive written by a hostile or broken
/// producer has. Any field the reader checks can be stated apart from the bytes it describes.
struct SyntheticZip {
    struct Entry {
        var name: Data
        /// What the entry holds, as the archive carries it (deflated bytes for a deflated entry).
        var payload: Data
        var method: UInt16 = 0
        var flags: UInt16 = 0x0800
        /// The sizes the directory declares; the payload's own when nil.
        var size: UInt32?
        var compressedSize: UInt32?
        /// Where the local header is, when it is not where it was written.
        var headerOffset: UInt32?
        /// Bytes of an extra field in the directory record (a hostile producer's way to make it long).
        var directoryExtra = 0
        /// Bytes after the payload that the file has and the memory does not (`write(to:)` leaves a hole).
        var gap = 0

        static func stored(_ name: String, _ data: Data) -> Entry {
            Entry(name: Data(name.utf8), payload: data)
        }

        static func deflated(_ name: String, _ data: Data) -> Entry {
            Entry(name: Data(name.utf8), payload: SyntheticZip.rawDeflate(data), method: 8, size: UInt32(data.count))
        }
    }

    /// A stored entry.
    static func stored(_ name: String, _ data: Data) -> Entry { .stored(name, data) }

    /// A deflated entry: the raw deflate stream of `data`.
    static func deflated(_ name: String, _ data: Data) -> Entry { .deflated(name, data) }

    static func rawDeflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data([0x03, 0x00]) }
        var capacity = data.count + data.count / 100 + 1024
        while true {
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source in
                    compression_encode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 { return out.prefix(written) }
            capacity *= 2
        }
    }

    var entries: [Entry]
    var comment = Data()

    init(_ entries: [Entry], comment: Data = Data()) {
        self.entries = entries
        self.comment = comment
    }

    /// The pieces of the archive in order: bytes, and holes that only a file can have.
    private enum Piece {
        case bytes(Data)
        case hole(Int)
    }

    private func pieces() -> [Piece] {
        var pieces: [Piece] = []
        var offset: UInt64 = 0
        var central = Data()
        for entry in entries {
            let headerOffset = UInt32(offset)
            let size = entry.size ?? UInt32(entry.payload.count)
            let compressed = entry.compressedSize ?? UInt32(entry.payload.count)
            var local = Data()
            local.zipLE(0x0403_4b50 as UInt32)
            local.zipLE(20 as UInt16)
            local.zipLE(entry.flags)
            local.zipLE(entry.method)
            local.zipLE(0 as UInt16)
            local.zipLE(0x21 as UInt16)
            local.zipLE(0 as UInt32)
            local.zipLE(compressed)
            local.zipLE(size)
            local.zipLE(UInt16(entry.name.count))
            local.zipLE(0 as UInt16)
            local.append(entry.name)
            local.append(entry.payload)
            pieces.append(.bytes(local))
            offset += UInt64(local.count)
            if entry.gap > 0 {
                pieces.append(.hole(entry.gap))
                offset += UInt64(entry.gap)
            }
            central.zipLE(0x0201_4b50 as UInt32)
            central.zipLE(0x031E as UInt16)
            central.zipLE(20 as UInt16)
            central.zipLE(entry.flags)
            central.zipLE(entry.method)
            central.zipLE(0 as UInt16)
            central.zipLE(0x21 as UInt16)
            central.zipLE(0 as UInt32)
            central.zipLE(compressed)
            central.zipLE(size)
            central.zipLE(UInt16(entry.name.count))
            central.zipLE(UInt16(entry.directoryExtra))
            central.zipLE(0 as UInt16)
            central.zipLE(0 as UInt16)
            central.zipLE(0 as UInt16)
            central.zipLE(UInt32(0o100644) << 16)
            central.zipLE(entry.headerOffset ?? headerOffset)
            central.append(entry.name)
            central.append(Data(count: entry.directoryExtra))
        }
        var tail = central
        tail.zipLE(0x0605_4b50 as UInt32)
        tail.zipLE(0 as UInt16)
        tail.zipLE(0 as UInt16)
        tail.zipLE(UInt16(entries.count))
        tail.zipLE(UInt16(entries.count))
        tail.zipLE(UInt32(central.count))
        tail.zipLE(UInt32(offset))
        tail.zipLE(UInt16(comment.count))
        tail.append(comment)
        pieces.append(.bytes(tail))
        return pieces
    }

    /// The archive in memory (holes, if any, as zeros).
    func data() -> Data {
        var out = Data()
        for piece in pieces() {
            switch piece {
            case .bytes(let bytes): out.append(bytes)
            case .hole(let count): out.append(Data(count: count))
            }
        }
        return out
    }

    /// The archive in a file, where a hole is a hole: a large entry costs no room.
    func write(to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for piece in pieces() {
            switch piece {
            case .bytes(let bytes): try handle.write(contentsOf: bytes)
            case .hole(let count): try handle.seek(toOffset: try handle.offset() + UInt64(count))
            }
        }
    }

    /// The end record alone: a zip with no entry.
    static var empty: Data { SyntheticZip([]).data() }

    // MARK: Text

    /// Text lines of the length of a log's, numbered, so a window's start says where it is.
    static func log(lines: Int) -> String {
        (0..<lines).map { "line \($0): the quick brown fox jumps over the lazy dog\n" }.joined()
    }
}

extension Data {
    fileprivate mutating func zipLE<Value: FixedWidthInteger>(_ value: Value) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

/// A source that remembers what was read from it: the proof that a window is read as a window.
final class CountingBytes: SendFeedbackByteSource, @unchecked Sendable {
    private let base: any SendFeedbackByteSource
    private let lock = NSLock()
    private var reads: [Int] = []

    init(_ base: any SendFeedbackByteSource) { self.base = base }

    var length: UInt64 { base.length }

    func read(at offset: UInt64, count: Int) throws -> Data {
        let data = try base.read(at: offset, count: count)
        lock.withLock { reads.append(data.count) }
        return data
    }

    var largestRead: Int { lock.withLock { reads.max() ?? 0 } }
    var totalRead: Int { lock.withLock { reads.reduce(0, +) } }
    func reset() { lock.withLock { reads = [] } }
}
