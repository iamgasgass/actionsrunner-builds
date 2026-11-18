// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing

@testable import AndariumCore
@testable import AndariumFeedbackLogic

/// The notes of the review of the bug report reader (R1 to R5): cancellation while producing output, an
/// end-of-directory look-alike in the comment, a CRLF across a window, windows read one after the other
/// without starting the inflater again, and the budgets that no other test pinned.
struct SendFeedbackReaderNotesTests {
    /// A source that counts what is read from it.
    final class CountingBytes: SendFeedbackByteSource, @unchecked Sendable {
        private let base: SendFeedbackMemoryBytes
        private let lock = NSLock()
        private var bytes: UInt64 = 0
        private var calls = 0

        init(_ data: Data) { base = SendFeedbackMemoryBytes(data) }

        var length: UInt64 { base.length }
        var bytesRead: UInt64 { lock.withLock { bytes } }
        var reads: Int { lock.withLock { calls } }

        func reset() {
            lock.withLock {
                bytes = 0
                calls = 0
            }
        }

        func read(at offset: UInt64, count: Int) throws -> Data {
            let data = try base.read(at: offset, count: count)
            lock.withLock {
                bytes += UInt64(data.count)
                calls += 1
            }
            return data
        }
    }

    private func reader(_ source: any SendFeedbackByteSource) throws -> SendFeedbackArchiveReader {
        SendFeedbackArchiveReader(try SendFeedbackArchive.open(source))
    }

    private func textReader(_ archive: SendFeedbackArchiveReader, entry: Int = 0) async throws -> SendFeedbackTextReader {
        guard case .text(let text) = try await archive.content(of: entry) else {
            Issue.record("the entry is not shown as text")
            throw SendFeedbackArchiveError.damaged
        }
        return text
    }

    private func joined(_ reader: SendFeedbackTextReader) async throws -> String {
        var result = ""
        for index in 0..<reader.windowCount { result += try await reader.window(index).text }
        return result
    }

    // MARK: R1 cancellation while producing

    /// A raw deflate stream of `blocks` empty stored blocks that are not the last, then a last block holding "A":
    /// five bytes a block, and one byte of output.
    private func slowStream(blocks: Int) -> Data {
        var stream = Data()
        stream.reserveCapacity(blocks * 5 + 6)
        for _ in 0..<blocks { stream.append(contentsOf: [0x00, 0x00, 0x00, 0xFF, 0xFF]) }
        stream.append(contentsOf: [0x01, 0x01, 0x00, 0xFE, 0xFF, 0x41])
        return stream
    }

    @Test func aReadThatProducesNothingForAWhileStopsWhenItIsCancelled() async throws {
        var entry = SyntheticZip.Entry.stored("slow.txt", slowStream(blocks: 1_000_000))
        entry.method = 8
        entry.size = 1
        let archive = try reader(SendFeedbackMemoryBytes(SyntheticZip([entry]).data()))
        let text = try await textReader(archive)
        // The task starts reading only once it is cancelled, so the first thing the read does is look.
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try await text.window(0)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: R2 an end record in the comment

    // A comment that holds an end record of its own makes two records that both fit the file, and nothing in the
    // archive says which is the real one: the archive is refused (C5), not guessed at.

    @Test func anEndRecordInTheCommentMakesTheArchiveUnreadable() throws {
        let lookalike = Data([0x50, 0x4B, 0x05, 0x06]) + Data(count: 18)
        let zip = SyntheticZip([.stored("a.txt", Data("a".utf8))], comment: lookalike)
        #expect(throws: SendFeedbackArchiveError.damaged) { try SendFeedbackArchive.open(SendFeedbackMemoryBytes(zip.data())) }
    }

    @Test func anEndRecordInTheCommentWithADirectoryOfItsOwnMakesTheArchiveUnreadable() throws {
        // 1 entry, 46 bytes, at offset 0: what a second record that fits would say.
        let lookalike = Data([0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, 1, 0, 1, 0, 46, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let zip = SyntheticZip([.stored("one.txt", Data("1".utf8)), .stored("two.txt", Data("2".utf8))], comment: lookalike)
        #expect(throws: SendFeedbackArchiveError.damaged) { try SendFeedbackArchive.open(SendFeedbackMemoryBytes(zip.data())) }
    }

    // MARK: R3 a CRLF across a window

    @Test func aCRLFAcrossAWindowIsOneNewlineWhateverTheMethod() async throws {
        let size = SendFeedbackArchiveLimits.windowBytes
        let body = Data(String(repeating: "A", count: size - 1).utf8) + Data("\r\nB\r\nC".utf8)
        let expected = SendFeedbackText.sanitize(String(decoding: body, as: UTF8.self))
        let archive = try reader(SendFeedbackMemoryBytes(SyntheticZip([.stored("s.txt", body), .deflated("d.txt", body)]).data()))
        for entry in 0..<2 {
            let text = try await textReader(archive, entry: entry)
            #expect(try await joined(text) == expected, "entry \(entry)")
        }
    }

    @Test func aLineLongerThanTheLookaheadIsCutWhereACharacterEndsAndTheRestStaysWhole() async throws {
        // No line break for 40,000 bytes of two-byte characters: windows end at a character, then CR LF and a tail.
        let body = Data((String(repeating: "\u{E9}", count: 20_000) + "\r\ntail\r\n").utf8)
        let expected = SendFeedbackText.sanitize(String(decoding: body, as: UTF8.self))
        let archive = try reader(SendFeedbackMemoryBytes(SyntheticZip([.stored("s.txt", body), .deflated("d.txt", body)]).data()))
        for entry in 0..<2 {
            let text = try await textReader(archive, entry: entry)
            #expect(try await joined(text) == expected, "entry \(entry)")
            for index in 0..<text.windowCount {
                #expect(!(try await text.window(index).text.contains("\u{FFFD}")), "window \(index) of entry \(entry) cut a character")
            }
        }
    }

    // MARK: R4 windows one after the other

    @Test func windowsReadOneAfterTheOtherDoNotStartTheInflaterAgain() async throws {
        // Text that does not shrink much, so that what is read again would show.
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ".utf8)
        var body = Data()
        for line in 0..<3_000 {
            body.append(Data("\(line) ".utf8))
            for _ in 0..<60 { body.append(alphabet[Int.random(in: 0..<alphabet.count, using: &generator)]) }
            body.append(0x0A)
        }
        let entry = SyntheticZip.Entry.deflated("log.txt", body)
        let source = CountingBytes(SyntheticZip([entry]).data())
        let text = try await textReader(try reader(source))
        let compressed = UInt64(entry.payload.count)
        #expect(text.windowCount >= 8)
        source.reset()
        var all = ""
        for index in 0..<text.windowCount { all += try await text.window(index).text }
        #expect(all == SendFeedbackText.sanitize(String(decoding: body, as: UTF8.self)))
        // The compressed bytes are read once, and one chunk of slack for where a read ends.
        #expect(source.bytesRead <= compressed + UInt64(SendFeedbackArchiveLimits.inputChunkBytes), "read \(source.bytesRead) of \(compressed)")
    }

    @Test func aJumpBackFartherThanWhatIsKeptStartsAgainAndStillReadsTheSame() async throws {
        let body = Data((0..<1_500).map { "line \($0): " + String(repeating: "x", count: 100) + "\n" }.joined().utf8)
        let archive = try reader(SendFeedbackMemoryBytes(SyntheticZip([.deflated("log.txt", body)]).data()))
        let text = try await textReader(archive)
        let last = text.windowCount - 1
        let forward = try await text.window(last).text
        // Window 0 is far behind the last one (and out of the windows kept): it is read from the start.
        let first = try await text.window(0).text
        #expect(first.hasPrefix("line 0: "))
        // The last window again, after the jump back, is what it was.
        let again = try await textReader(archive)
        #expect(try await again.window(last).text == forward)
    }

    // MARK: R5 the budgets

    @Test func aNameIsReadOnlyUpToTheBound() {
        #expect(SendFeedbackArchiveLimits.maxNameBytes == 1_024)
        #expect(SendFeedbackArchiveNames.bytesRead(nameLength: 65_535) == 1_024)
        #expect(SendFeedbackArchiveNames.bytesRead(nameLength: 1_024) == 1_024)
        #expect(SendFeedbackArchiveNames.bytesRead(nameLength: 10) == 10)
        #expect(SendFeedbackArchiveNames.bytesRead(nameLength: 0) == 0)
    }

    @Test func aNameLongerThanTheBoundStillListsWithItsEnd() throws {
        let long = String(repeating: "n", count: 5_000) + "/"
        let zip = SyntheticZip([.stored(long, Data()), .stored("b.txt", Data("b".utf8))])
        let archive = try SendFeedbackArchive.open(SendFeedbackMemoryBytes(zip.data()))
        #expect(archive.listing.entries.count == 2)
        #expect(archive.listing.entries[0].isFolder, "a folder name that is cut is still a folder")
        #expect(archive.listing.entries[0].name.hasSuffix("\u{2026}"))
        #expect(archive.listing.entries[0].name.count <= SendFeedbackArchiveLimits.maxNameCharacters + 1)
    }

    @Test func aWindowIsSixteenKiBAndTheCountFollowsFromIt() async throws {
        #expect(SendFeedbackArchiveLimits.windowBytes == 16_384)
        let body = Data(String(repeating: "0123456789\n", count: 9_091).utf8)  // 100,001 bytes
        let archive = try reader(SendFeedbackMemoryBytes(SyntheticZip([.stored("s.txt", body)]).data()))
        let text = try await textReader(archive)
        #expect(text.byteCount == 100_001)
        #expect(text.windowCount == 7)
        for index in 0..<text.windowCount {
            let window = try await text.window(index)
            // A window is what starts in its 16 KiB, to the end of the line it ends in: never much more.
            #expect(window.text.utf8.count <= SendFeedbackArchiveLimits.windowBytes + SendFeedbackArchiveLimits.windowLookaheadBytes)
        }
    }

    @Test func onlyTheLastFourWindowsAreKept() async throws {
        let body = Data(String(repeating: "0123456789\n", count: 9_091).utf8)
        let source = CountingBytes(SyntheticZip([.stored("s.txt", body)]).data())
        let text = try await textReader(try reader(source))
        for index in 0..<text.windowCount { _ = try await text.window(index) }
        func reads(_ index: Int) async throws -> Int {
            let before = source.reads
            _ = try await text.window(index)
            return source.reads - before
        }
        let last = text.windowCount - 1
        #expect(try await reads(last) == 0, "the newest window is kept")
        #expect(try await reads(last - 3) == 0, "the fourth newest is kept")
        // Four are kept: the fifth newest was let go when the newest came.
        #expect(try await reads(last - 4) > 0, "the fifth newest was dropped")
    }
}
