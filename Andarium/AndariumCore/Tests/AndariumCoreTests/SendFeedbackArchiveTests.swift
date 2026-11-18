// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing

@testable import AndariumCore
@testable import AndariumFeedbackLogic

/// The reader behind the bug report viewer: what an archive lists, how an entry is read in windows, and that
/// nothing an archive says is trusted. Archives are made in memory (`SyntheticZip`), or in a file for the
/// parts that read from one; no real report is used.
struct SendFeedbackArchiveTests {
    private func open(_ zip: SyntheticZip) throws -> SendFeedbackArchive {
        try SendFeedbackArchive.open(SendFeedbackMemoryBytes(zip.data()))
    }

    private func reader(_ zip: SyntheticZip) throws -> SendFeedbackArchiveReader {
        SendFeedbackArchiveReader(try open(zip))
    }

    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("andarium-archive-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func text(_ content: SendFeedbackEntryContent) -> SendFeedbackTextReader? {
        if case .text(let reader) = content { return reader }
        return nil
    }

    private func unavailable(_ content: SendFeedbackEntryContent) -> SendFeedbackEntryContent.Reason? {
        if case .unavailable(let reason) = content { return reason }
        return nil
    }

    private func all(_ reader: SendFeedbackTextReader) async throws -> String {
        var result = ""
        for index in 0..<reader.windowCount { result += try await reader.window(index).text }
        return result
    }

    // MARK: The shape of a bug report

    /// What Android's report holds: a long deflated text, short stored files, a folder and a picture, with the
    /// records Andarium appends after the last entry by `BugReportArchive`.
    @Test func aBugReportListsItsEntriesAndShowsTheTextOnes() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let big = SyntheticZip.log(lines: 2_000)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D]) + Data((0..<600).map { UInt8($0 * 7 & 0xFF) })
        let base = SyntheticZip([
            .deflated("bugreport-lineage-2026-11-17-15-00-00.txt", Data(big.utf8)),
            .stored("version.txt", Data("3.0\n".utf8)),
            .stored("FS/", Data()),
            .stored("FS/data/misc/example.txt", Data("example\n".utf8)),
            .stored("screenshot-2026-11-17.png", png),
        ])
        let file = directory.appendingPathComponent("report.zip")
        try base.data().write(to: file)
        try BugReportArchive.append(
            [.init(name: "andarium/session-current.txt", data: Data("uml-session 7\n".utf8))], to: file)

        let archive = try await SendFeedbackArchiveReader.open(file: file)
        let names = archive.listing.entries.map(\.name)
        #expect(names == [
            "bugreport-lineage-2026-11-17-15-00-00.txt", "version.txt", "FS/", "FS/data/misc/example.txt",
            "screenshot-2026-11-17.png", "andarium/session-current.txt",
        ])
        #expect(archive.listing.declaredCount == 6 && archive.listing.unlistedCount == 0)
        #expect(archive.listing.entries[0].size == UInt64(big.utf8.count))
        #expect(archive.listing.entries[2].isFolder)
        #expect(archive.listing.entries.allSatisfy { $0.problem == nil })

        let main = try #require(try await text(archive.content(of: 0)))
        let first = try await main.window(0)
        #expect(first.text.hasPrefix("line 0: the quick brown fox"))
        #expect(first.index == 0 && first.count == main.windowCount && main.windowCount > 1)
        #expect(try await all(main) == big)
        let appended = try #require(try await text(archive.content(of: 5)))
        #expect(try await appended.window(0).text == "uml-session 7\n")
        if case .picture = try await archive.content(of: 4) {
            // a picture is told by its name and its first bytes
        } else {
            Issue.record("the picture is not told as one")
        }
        #expect(unavailable(try await archive.content(of: 2)) == .folder)
    }

    @Test func anEmptyArchiveListsNothing() throws {
        let archive = try SendFeedbackArchive.open(SendFeedbackMemoryBytes(SyntheticZip.empty))
        #expect(archive.listing.entries.isEmpty && archive.listing.declaredCount == 0)
        #expect(archive.listing.totalBytes == 0)
    }

    @Test func anEmptyEntryHasNothingToShow() async throws {
        let archive = try reader(SyntheticZip([.stored("empty.txt", Data())]))
        guard case .empty = try await archive.content(of: 0) else {
            Issue.record("an entry with no bytes is empty")
            return
        }
    }

    // MARK: A file that is not, or no longer, an archive

    @Test func nothingThatIsNotAnArchiveOpens() {
        for bytes in [Data(), Data([1, 2, 3]), Data(repeating: 0x41, count: 5_000), Data("PK".utf8)] {
            #expect(throws: SendFeedbackArchiveError.notAnArchive) {
                try SendFeedbackArchive.open(SendFeedbackMemoryBytes(bytes))
            }
        }
    }

    @Test func anArchiveCutShortSaysSoAndNeverCrashes() throws {
        let whole = SyntheticZip([
            .deflated("a.txt", Data(SyntheticZip.log(lines: 400).utf8)), .stored("b.txt", Data("b".utf8)),
        ]).data()
        // Every cut: the end record goes first, so no cut opens as an archive.
        for cut in stride(from: 1, to: whole.count, by: 7) {
            #expect(throws: SendFeedbackArchiveError.self, "cut at \(cut)") {
                try SendFeedbackArchive.open(SendFeedbackMemoryBytes(whole.prefix(cut)))
            }
        }
    }

    @Test func aDirectoryThatContradictsItselfIsDamaged() {
        func opens(_ mutate: (inout Data) -> Void) -> SendFeedbackArchiveError? {
            var data = SyntheticZip([.stored("a.txt", Data("a".utf8)), .stored("b.txt", Data("b".utf8))]).data()
            mutate(&data)
            do {
                _ = try SendFeedbackArchive.open(SendFeedbackMemoryBytes(data))
                return nil
            } catch { return error as? SendFeedbackArchiveError }
        }
        let end = SyntheticZip([.stored("a.txt", Data("a".utf8)), .stored("b.txt", Data("b".utf8))]).data().count - 22
        // The entry count says three, the directory holds two.
        #expect(opens { $0[end + 10] = 3; $0[end + 8] = 3 } == .damaged)
        // The two counts disagree.
        #expect(opens { $0[end + 8] = 1 } == .damaged)
        // The directory starts past the end record.
        #expect(opens { $0[end + 16] = 0xF0; $0[end + 17] = 0xFF } == .damaged)
        // The directory's size reaches beyond the end record.
        #expect(opens { $0[end + 12] = 0xF0; $0[end + 13] = 0xFF } == .damaged)
        // A record without its signature.
        let start = Int(SyntheticZip([.stored("a.txt", Data("a".utf8)), .stored("b.txt", Data("b".utf8))]).data()
            .withUnsafeBytes { $0.loadUnaligned(fromByteOffset: end + 16, as: UInt32.self) })
        #expect(opens { $0[start] = 0 } == .damaged)
        // A name that runs past the directory.
        #expect(opens { $0[start + 28] = 0xFF; $0[start + 29] = 0xFF } == .damaged)
    }

    @Test func severalDisksAndZip64AreSaidToBeUnsupported() {
        func opens(_ mutate: (inout Data) -> Void) -> SendFeedbackArchiveError? {
            var data = SyntheticZip([.stored("a.txt", Data("a".utf8))]).data()
            mutate(&data)
            do {
                _ = try SendFeedbackArchive.open(SendFeedbackMemoryBytes(data))
                return nil
            } catch { return error as? SendFeedbackArchiveError }
        }
        let end = SyntheticZip([.stored("a.txt", Data("a".utf8))]).data().count - 22
        #expect(opens { $0[end + 4] = 1 } == .unsupported)
        #expect(opens { $0[end + 10] = 0xFF; $0[end + 11] = 0xFF } == .unsupported)
        #expect(opens { for index in 16..<20 { $0[end + index] = 0xFF } } == .unsupported)
    }

    // MARK: Bounds

    @Test func moreEntriesThanTheBoundAreCountedAndOnlyTheBoundAreListed() throws {
        let zip = SyntheticZip((0..<5_000).map { .stored("e\($0)", Data()) })
        let archive = try open(zip)
        #expect(archive.listing.entries.count == SendFeedbackArchiveLimits.maxEntries)
        #expect(archive.listing.declaredCount == 5_000)
        #expect(archive.listing.unlistedCount == 5_000 - SendFeedbackArchiveLimits.maxEntries)
        #expect(archive.listing.entries.last?.name == "e\(SendFeedbackArchiveLimits.maxEntries - 1)")
    }

    @Test func aDirectoryLargerThanTheBoundListsWhatFitsInIt() throws {
        // Seventy records with 64 KiB of extra field each: 4.4 MiB of directory.
        var entries: [SyntheticZip.Entry] = (0..<70).map { .stored("e\($0)", Data()) }
        for index in entries.indices { entries[index].directoryExtra = 65_000 }
        let archive = try open(SyntheticZip(entries))
        #expect(archive.listing.declaredCount == 70)
        #expect(archive.listing.entries.count < 70 && archive.listing.entries.count > 50)
        #expect(archive.listing.unlistedCount == 70 - archive.listing.entries.count)
    }

    @Test func anEntryThatDeclaresMoreThanTheBoundIsListedAndNotShown() async throws {
        // A real file with a hole in it, so that a stored entry of 600 MiB lies inside it.
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let size = UInt32(600 << 20)
        var huge = SyntheticZip.stored("huge.txt", Data("head".utf8))
        huge.size = size
        huge.compressedSize = size
        huge.gap = Int(size) - 4
        let file = directory.appendingPathComponent("huge.zip")
        try SyntheticZip([huge, .stored("small.txt", Data("small".utf8))]).write(to: file)
        let archive = try await SendFeedbackArchiveReader.open(file: file)
        let first = try #require(archive.listing.entries.first)
        #expect(first.name == "huge.txt" && first.size == UInt64(size))
        #expect(first.problem == .tooLarge)
        #expect(unavailable(try await archive.content(of: 0)) == .problem(.tooLarge))
        #expect(try await text(archive.content(of: 1)) != nil, "the rest of the archive is read")
    }

    @Test func aSizeThatNoDeflateStreamOfThatLengthCanHoldIsDamaged() async throws {
        var entry = SyntheticZip.deflated("bomb.txt", Data(repeating: 0x61, count: 100))
        entry.size = 50 << 20
        let archive = try reader(SyntheticZip([entry]))
        #expect(archive.listing.entries[0].problem == .damaged)
        #expect(unavailable(try await archive.content(of: 0)) == .problem(.damaged))
    }

    @Test func aStoredEntryWhoseTwoSizesDifferIsDamaged() throws {
        var entry = SyntheticZip.stored("a.txt", Data("abcdefgh".utf8))
        entry.size = 100
        #expect(try open(SyntheticZip([entry])).listing.entries[0].problem == .damaged)
    }

    @Test func anEntryThatRunsPastTheEndOfTheFileIsDamagedAndTheRestStays() async throws {
        var entry = SyntheticZip.stored("far.txt", Data("abc".utf8))
        entry.headerOffset = 1 << 30
        let archive = try reader(SyntheticZip([entry, .stored("near.txt", Data("near".utf8))]))
        #expect(archive.listing.entries[0].problem == .damaged)
        #expect(archive.listing.entries[1].problem == nil)
        #expect(unavailable(try await archive.content(of: 0)) == .problem(.damaged))
        #expect(try await text(archive.content(of: 1))?.window(0).text == "near")
    }

    @Test func aLocalHeaderThatIsNotOneIsDamagedWhenTheEntryIsOpened() async throws {
        // The second entry's directory record points into the zeros the first one holds.
        var second = SyntheticZip.stored("b.txt", Data("b".utf8))
        second.headerOffset = 30 + 1 + 100
        let archive = try reader(SyntheticZip([.stored("a", Data(count: 300)), second]))
        await #expect(throws: SendFeedbackArchiveError.damaged) { try await archive.content(of: 1) }
    }

    @Test func anEncryptedOrUnusuallyCompressedOrZip64EntryIsListedWithItsReason() throws {
        var encrypted = SyntheticZip.stored("secret.txt", Data("xyz".utf8))
        encrypted.flags = 0x0801
        var bzip = SyntheticZip.stored("bzip.txt", Data("xyz".utf8))
        bzip.method = 12
        var wide = SyntheticZip.stored("wide.txt", Data("xyz".utf8))
        wide.size = 0xFFFF_FFFF
        let archive = try open(SyntheticZip([encrypted, bzip, wide]))
        #expect(archive.listing.entries.map(\.problem) == [.encrypted, .unsupportedCompression, .zip64])
        #expect(archive.listing.entries.map(\.name) == ["secret.txt", "bzip.txt", "wide.txt"])
    }

    // MARK: Names

    /// A name is shown, and never joined to a path: nothing is made on disk, whatever a name says.
    @Test func aNameWithPathSeparatorsIsShownAsWrittenAndTheEntryStillReads() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try reader(SyntheticZip([
            .stored("../../escape.txt", Data("one".utf8)), .stored("/etc/passwd", Data("two".utf8)),
            .stored("a\\b\\c.txt", Data("three".utf8)), .stored("dir/./x/../y.txt", Data("four".utf8)),
        ]))
        #expect(archive.listing.entries.map(\.name) == ["../../escape.txt", "/etc/passwd", "a\\b\\c.txt", "dir/./x/../y.txt"])
        for (index, expected) in ["one", "two", "three", "four"].enumerated() {
            #expect(try await text(archive.content(of: index))?.window(0).text == expected)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("escape.txt").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, "nothing is extracted")
    }

    @Test func aNameWithBytesThatAreNotTextShowsReplacementCharacters() throws {
        var raw = SyntheticZip.stored("x", Data("abc".utf8))
        // Invalid UTF-8, a NUL, an escape, a right-to-left override and a line separator.
        raw.name = Data([0x61, 0xFF, 0xC3, 0x28, 0x00, 0x1B]) + Data("\u{202E}b\u{2028}".utf8)
        let name = try open(SyntheticZip([raw])).listing.entries[0].name
        #expect(name == "a\u{FFFD}\u{FFFD}(\u{FFFD}\u{FFFD}\u{FFFD}b\u{FFFD}")
        #expect(!name.unicodeScalars.contains { SendFeedbackNames.isControl($0) })
    }

    @Test func aLongNameIsCutAndSaysSo() throws {
        let long = String(repeating: "n", count: 5_000)
        let name = try open(SyntheticZip([.stored(long, Data("x".utf8))])).listing.entries[0].name
        #expect(name.count == SendFeedbackArchiveLimits.maxNameCharacters + 1 && name.hasSuffix("\u{2026}"))
        // Wide characters too: the cut is in characters, after the bytes were bounded.
        let wide = String(repeating: "\u{65E5}", count: 3_000)
        let wideName = try open(SyntheticZip([.stored(wide, Data("x".utf8))])).listing.entries[0].name
        #expect(wideName.count <= SendFeedbackArchiveLimits.maxNameCharacters + 1 && wideName.hasSuffix("\u{2026}"))
        // A short name is shown whole.
        #expect(try open(SyntheticZip([.stored("short", Data("x".utf8))])).listing.entries[0].name == "short")
    }

    // MARK: Windows

    /// Text of characters of one to four bytes, long enough for several windows, so that windows begin and
    /// end inside characters: every window shows whole characters, and the windows are the whole text.
    @Test func windowsAreWholeCharactersAndAddUpToTheEntryWhateverTheMethod() async throws {
        let line = "caf\u{E9} \u{65E5}\u{672C}\u{8A9E} \u{1F680} end\n"
        let big = String(repeating: line, count: 4_000)
        let archive = try reader(SyntheticZip([
            .stored("stored.txt", Data(big.utf8)), .deflated("deflated.txt", Data(big.utf8)),
        ]))
        for entry in 0..<2 {
            let reader = try #require(try await text(archive.content(of: entry)))
            #expect(reader.windowCount == (big.utf8.count + reader.windowBytes - 1) / reader.windowBytes)
            #expect(reader.windowCount > 3)
            var joined = ""
            for index in 0..<reader.windowCount {
                let window = try await reader.window(index)
                #expect(!window.text.contains("\u{FFFD}"), "entry \(entry) window \(index) cut a character")
                joined += window.text
            }
            #expect(joined == big)
        }
    }

    @Test func aWindowIsTheSameWhicheverWayItWasReached() async throws {
        let big = SyntheticZip.log(lines: 3_000)
        let archive = try reader(SyntheticZip([.deflated("log.txt", Data(big.utf8))]))
        let reader = try #require(try await text(archive.content(of: 0)))
        let last = reader.windowCount - 1
        let end = try await reader.window(last)
        let middle = try await reader.window(last / 2)
        // Behind the inflater, which starts again, then ahead of it.
        let beginning = try await reader.window(0)
        #expect(beginning.text.hasPrefix("line 0:"))
        #expect(try await reader.window(last / 2) == middle)
        #expect(try await reader.window(last) == end)
        // The last window may hold no line (the last line began in the one before): the text still ends as it does.
        #expect(try await all(reader).hasSuffix("lazy dog\n") && end.count == reader.windowCount)
        // A window past the ends is the nearest one.
        #expect(try await reader.window(-4) == beginning)
        #expect(try await reader.window(last + 40) == end)
    }

    @Test func aStoredEntryIsReadAWindowAtATimeFromWhereItLies() async throws {
        let big = Data(SyntheticZip.log(lines: 40_000).utf8)  // about 2 MiB
        let counting = CountingBytes(SendFeedbackMemoryBytes(SyntheticZip([.stored("log.txt", big)]).data()))
        let archive = SendFeedbackArchiveReader(try SendFeedbackArchive.open(counting))
        let reader = try #require(try await text(archive.content(of: 0)))
        counting.reset()
        _ = try await reader.window(reader.windowCount / 2)
        let most = reader.windowBytes + SendFeedbackArchiveLimits.windowLookaheadBytes + 5
        #expect(counting.largestRead <= most, "one window and the rest of its last line, at most")
        #expect(counting.totalRead <= most)
        _ = try await reader.window(3)
        #expect(counting.totalRead <= 2 * most)
    }

    @Test func aDeflatedEntryIsInflatedThroughOneChunkAtATime() async throws {
        let big = Data(SyntheticZip.log(lines: 40_000).utf8)
        let counting = CountingBytes(SendFeedbackMemoryBytes(SyntheticZip([.deflated("log.txt", big)]).data()))
        let archive = SendFeedbackArchiveReader(try SendFeedbackArchive.open(counting))
        let reader = try #require(try await text(archive.content(of: 0)))
        counting.reset()
        _ = try await reader.window(reader.windowCount - 1)
        #expect(counting.largestRead <= SendFeedbackArchiveLimits.inputChunkBytes)
    }

    /// 64 MiB of one byte is a few dozen KiB deflated. It reads like any entry, in windows.
    @Test func aStreamThatExpandsAThousandfoldIsReadInWindows() async throws {
        let zeros = Data(repeating: 0x61, count: 64 << 20)
        let archive = try reader(SyntheticZip([.deflated("zeros.txt", zeros)]))
        #expect(archive.listing.entries[0].problem == nil && archive.listing.entries[0].size == 64 << 20)
        let reader = try #require(try await text(archive.content(of: 0)))
        #expect(reader.windowCount == (64 << 20) / reader.windowBytes)
        let window = try await reader.window(reader.windowCount - 1)
        #expect(window.text.count == reader.windowBytes && window.text.allSatisfy { $0 == "a" })
    }

    @Test func aDeflatedEntryThatEndsBeforeItsDeclaredSizeIsDamagedWhenItIsRead() async throws {
        var entry = SyntheticZip.deflated("short.txt", Data(SyntheticZip.log(lines: 100).utf8))
        let real = entry.size!
        entry.size = real * 4
        let archive = try reader(SyntheticZip([entry]))
        let reader = try #require(try await text(archive.content(of: 0)))
        await #expect(throws: SendFeedbackArchiveError.damaged) { try await reader.window(0) }
    }

    @Test func aDeflatedEntryLongerThanItsDeclaredSizeIsReadOnlyToTheSize() async throws {
        var entry = SyntheticZip.deflated("long.txt", Data(SyntheticZip.log(lines: 100).utf8))
        entry.size = 50
        let archive = try reader(SyntheticZip([entry]))
        let reader = try #require(try await text(archive.content(of: 0)))
        #expect(reader.byteCount == 50)
        #expect(try await reader.window(0).text == String(SyntheticZip.log(lines: 1).prefix(50)))
    }

    @Test func aDeflatedEntryCutShortOrMadeOfGarbageIsDamagedAndNeverHangs() async throws {
        let big = Data(SyntheticZip.log(lines: 3_000).utf8)
        var cut = SyntheticZip.deflated("cut.txt", big)
        cut.payload = cut.payload.prefix(cut.payload.count / 3)
        var garbage = SyntheticZip.deflated("garbage.txt", big)
        garbage.payload = Data((0..<2_000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 7) })
        garbage.size = 5_000
        var nothing = SyntheticZip.deflated("nothing.txt", big)
        nothing.payload = Data()
        nothing.size = 100
        let archive = try reader(SyntheticZip([cut, garbage, nothing]))
        for entry in 0..<3 {
            do {
                if let reader = try await text(archive.content(of: entry)) {
                    _ = try await reader.window(reader.windowCount - 1)
                    Issue.record("entry \(entry) read to its end")
                }
            } catch let error as SendFeedbackArchiveError {
                #expect(error == .damaged, "entry \(entry)")
            }
        }
    }

    @Test func aReadThatIsCancelledStopsInsteadOfInflatingToTheEnd() async throws {
        let zeros = Data(repeating: 0x61, count: 64 << 20)
        let archive = try reader(SyntheticZip([.deflated("zeros.txt", zeros)]))
        let reader = try #require(try await text(archive.content(of: 0)))
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await Result { try await reader.window(reader.windowCount - 1) }
        }.value
        guard case .failure(let error) = outcome else {
            Issue.record("a cancelled read ran to the end")
            return
        }
        #expect(error is CancellationError)
    }

    // MARK: Text

    @Test func textIsShownAsPlainTextWithWhatAScreenWouldObeyReplaced() async throws {
        let padding = String(repeating: "A line of an ordinary log, with words in it.\n", count: 12)
        let hostile = Data(padding.utf8) + Data("one\r\ntwo\rthree\u{1B}[31m\u{202E}tab\there\u{0}end\n".utf8) + Data([0xFF, 0xFE]) + Data("https://example.com [link](https://example.com) <b>x</b>\n".utf8)
        let archive = try reader(SyntheticZip([.stored("t.txt", hostile)]))
        let textReader = try #require(try await text(archive.content(of: 0)))
        let shown = try await textReader.window(0).text
        #expect(shown.dropFirst(padding.count).hasPrefix("one\ntwo\nthree\u{FFFD}[31m\u{FFFD}tab\there\u{FFFD}end\n\u{FFFD}\u{FFFD}"))
        // Links and markup are characters like any other: nothing is parsed, and nothing is dropped.
        #expect(shown.hasSuffix("https://example.com [link](https://example.com) <b>x</b>\n"))
        #expect(!shown.unicodeScalars.contains { $0 == "\r" || $0 == "\u{1B}" || $0 == "\u{202E}" || $0 == "\u{0}" })
    }

    @Test func whatLooksLikeTextAndWhatDoesNot() {
        #expect(SendFeedbackText.looksLikeText(Data()))
        #expect(SendFeedbackText.looksLikeText(Data("plain log\nline two\t\n".utf8)))
        #expect(SendFeedbackText.looksLikeText(Data("\u{65E5}\u{672C}\u{8A9E}".utf8)))
        #expect(SendFeedbackText.looksLikeText(Data("good".utf8) + Data([0xFF]) + Data(String(repeating: "good", count: 100).utf8)))
        #expect(!SendFeedbackText.looksLikeText(Data(repeating: 0, count: 600)))
        #expect(!SendFeedbackText.looksLikeText(Data((0..<600).map { UInt8($0 * 7 & 0xFF) })))
        #expect(!SendFeedbackText.looksLikeText(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0xC0, count: 400)))
        #expect(SendFeedbackText.looksLikeArchive(Data([0x50, 0x4B, 0x03, 0x04, 0, 0])))
        #expect(SendFeedbackText.looksLikeArchive(Data([0x50, 0x4B, 0x05, 0x06])))
        #expect(!SendFeedbackText.looksLikeArchive(Data("PK text".utf8)))
    }

    // MARK: An archive inside

    @Test func anArchiveInsideIsListedOneLevelDown() async throws {
        let inner = SyntheticZip([
            .stored("inner/readme.txt", Data("inner text".utf8)), .deflated("inner/log.txt", Data(SyntheticZip.log(lines: 800).utf8)),
        ]).data()
        let archive = try reader(SyntheticZip([.stored("nested.zip", inner), .stored("after.txt", Data("after".utf8))]))
        guard case .archive(let nested) = try await archive.content(of: 0) else {
            Issue.record("the stored archive is not listed as one")
            return
        }
        #expect(nested.depth == 1)
        #expect(nested.listing.entries.map(\.name) == ["inner/readme.txt", "inner/log.txt"])
        #expect(try await text(nested.content(of: 0))?.window(0).text == "inner text")
        let log = try #require(try await text(nested.content(of: 1)))
        #expect(try await log.window(0).text.hasPrefix("line 0:"))
        #expect(try await text(archive.content(of: 1))?.window(0).text == "after")
    }

    @Test func anArchiveThatIsDeflatedInsideIsListedByNameAndSizeAlone() async throws {
        let inner = SyntheticZip([.stored("x.txt", Data("x".utf8))]).data()
        let archive = try reader(SyntheticZip([.deflated("nested.zip", inner + Data(repeating: 0, count: 2_000))]))
        #expect(unavailable(try await archive.content(of: 0)) == .compressedArchive)
    }

    @Test func anArchiveInsideAnArchiveInsideIsNotOpened() async throws {
        let deepest = SyntheticZip([.stored("x.txt", Data("x".utf8))]).data()
        let middle = SyntheticZip([.stored("deepest.zip", deepest)]).data()
        let archive = try reader(SyntheticZip([.stored("middle.zip", middle)]))
        guard case .archive(let nested) = try await archive.content(of: 0) else {
            Issue.record("the first level is not listed")
            return
        }
        #expect(unavailable(try await nested.content(of: 0)) == .tooDeep)
    }

    @Test func somethingThatStartsLikeAnArchiveAndIsNotOneIsNotText() async throws {
        let archive = try reader(SyntheticZip([.stored("fake.zip", Data([0x50, 0x4B, 0x03, 0x04]) + Data(repeating: 0x41, count: 300))]))
        #expect(unavailable(try await archive.content(of: 0)) == .notText)
    }

    // MARK: The bytes of a whole entry

    @Test func theBytesOfAnEntryAreItsWholeContentWhateverTheMethod() async throws {
        let picture = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data((0..<3_000).map { UInt8($0 * 31 & 0xFF) })
        let packed = Data((0..<40_000).map { UInt8($0 / 97 & 0xFF) })
        let archive = try reader(SyntheticZip([
            .stored("a.png", picture), .deflated("b.png", packed), .stored("empty.bin", Data()),
        ]))
        #expect(try await archive.bytes(of: 0, limit: 1 << 20) == picture)
        #expect(try await archive.bytes(of: 1, limit: 1 << 20) == packed)
        #expect(try await archive.bytes(of: 2, limit: 1 << 20) == Data())
    }

    @Test func anEntryAboveTheLimitOrNotShownIsNotReadWhole() async throws {
        let archive = try reader(SyntheticZip([
            .stored("big.png", Data(repeating: 7, count: 5_000)), .stored("FS/", Data()), .stored("x.txt", Data("x".utf8)),
        ]))
        await #expect(throws: SendFeedbackArchiveError.tooLarge) { try await archive.bytes(of: 0, limit: 4_999) }
        #expect(try await archive.bytes(of: 0, limit: 5_000).count == 5_000)
        await #expect(throws: SendFeedbackArchiveError.unsupported) { try await archive.bytes(of: 1, limit: 1 << 20) }
        await #expect(throws: SendFeedbackArchiveError.damaged) { try await archive.bytes(of: 99, limit: 1 << 20) }
        await #expect(throws: SendFeedbackArchiveError.tooLarge) { try await archive.bytes(of: 2, limit: -1) }
    }

    @Test func noLimitReadsMoreThanTheHardBound() async throws {
        // 33 MiB of zeros deflates to about 32 KiB: the declared size, not the compressed one, is what is bounded.
        let size = SendFeedbackArchiveLimits.maxWholeEntryBytes + (1 << 20)
        let archive = try reader(SyntheticZip([.deflated("zeros.bin", Data(count: size))]))
        await #expect(throws: SendFeedbackArchiveError.tooLarge) { try await archive.bytes(of: 0, limit: Int.max) }
    }

    @Test func theBytesOfADamagedEntryAreDamagedAndNeverHang() async throws {
        var zip = SyntheticZip([.deflated("log.txt", Data(SyntheticZip.log(lines: 300).utf8))]).data()
        // Garbage in the middle of the deflate stream.
        for index in (zip.count / 3)..<(zip.count / 3 + 40) { zip[index] = 0xFF }
        let archive = SendFeedbackArchiveReader(try SendFeedbackArchive.open(SendFeedbackMemoryBytes(zip)))
        await #expect(throws: SendFeedbackArchiveError.damaged) { try await archive.bytes(of: 0, limit: 1 << 20) }
    }

    // MARK: A plain file

    @Test func aPlainTextFileIsShownTheSameWay() async throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("start-log.txt")
        let body = SyntheticZip.log(lines: 900)
        try Data(body.utf8).write(to: file)
        let reader = try #require(SendFeedbackTextReader(file: file))
        #expect(reader.windowCount > 1)
        #expect(try await all(reader) == body)
        try Data().write(to: file)
        #expect(SendFeedbackTextReader(file: file) == nil, "an empty file has nothing to show")
        #expect(SendFeedbackTextReader(file: directory.appendingPathComponent("missing")) == nil)
        #expect(SendFeedbackTextReader(file: directory) == nil, "a folder is not a file")
    }
}
