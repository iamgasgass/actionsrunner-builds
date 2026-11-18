// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing

@testable import AndariumCore
@testable import AndariumFeedbackLogic

/// The findings of the second review of the bug report reader (C1 to C6): the kept tail after a read that
/// threw, a bounded tail, nested readers that are not kept for ever, a tree built from the structural name, two
/// end records that both fit, and the parser's use of the name clamp.
struct SendFeedbackReviewTests {
    /// A source that cancels the task that reads from it, once armed, on its next read.
    final class CancelOnRead: SendFeedbackByteSource, @unchecked Sendable {
        private let base: SendFeedbackMemoryBytes
        private let lock = NSLock()
        private var cancelNext = false

        init(_ data: Data) { base = SendFeedbackMemoryBytes(data) }

        var length: UInt64 { base.length }
        func arm() { lock.withLock { cancelNext = true } }

        func read(at offset: UInt64, count: Int) throws -> Data {
            let cancel = lock.withLock { () -> Bool in
                let was = cancelNext
                cancelNext = false
                return was
            }
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            return try base.read(at: offset, count: count)
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

    // MARK: C1 the kept tail after a read that threw

    /// Raw deflate: `blocks` of 16 KiB, each of one letter (A, B, ...), each after 10,000 empty stored blocks, so
    /// that one production call reaches over several input chunks. A stored block of 16 KiB is `00 00 40 FF BF`.
    private func lettersStream(blocks: Int) -> Data {
        var payload = Data()
        for index in 0..<blocks {
            payload.append(contentsOf: [0, 0, 0x40, 0xFF, 0xBF])
            payload.append(Data(repeating: UInt8(65 + index % 26), count: 16_384))
            for _ in 0..<10_000 { payload.append(contentsOf: [0, 0, 0, 0xFF, 0xFF]) }
        }
        return payload
    }

    private func deflatedEntry(_ payload: Data, size: Int) -> SyntheticZip.Entry {
        var entry = SyntheticZip.Entry.stored("x.txt", payload)
        entry.method = 8
        entry.size = UInt32(size)
        return entry
    }

    @Test func aReadThatFailedDoesNotLeaveBytesThatAreReturnedAsAnEarlierPlace() async throws {
        // Six letters of 16 KiB, then a block of a type that does not exist; the directory declares 40 windows.
        var payload = lettersStream(blocks: 6)
        payload.append(0x07)
        let archive = try reader(SendFeedbackMemoryBytes(SyntheticZip([deflatedEntry(payload, size: 40 * 16_384)]).data()))
        let text = try await textReader(archive)
        _ = try await text.window(0)
        _ = try await text.window(1)
        await #expect(throws: SendFeedbackArchiveError.damaged) { try await text.window(12) }
        // Window 4 is what the stream holds at 64 KiB: right, or an error, never what was kept before.
        let got = try await text.window(4)
        #expect(got.text.utf8.count == 16_384 && got.text.utf8.allSatisfy { $0 == 69 }, "window 4 is E and nothing else")
    }

    @Test func aReadThatWasCancelledDoesNotLeaveBytesThatAreReturnedAsAnEarlierPlace() async throws {
        var payload = lettersStream(blocks: 40)
        payload.append(contentsOf: [1, 0, 0, 0xFF, 0xFF])
        let data = SyntheticZip([deflatedEntry(payload, size: 40 * 16_384)]).data()
        let source = CancelOnRead(data)
        let archive = try SendFeedbackArchive.open(source)
        let stream = SendFeedbackEntryStream(try archive.location(of: archive.listing.entries[0]))
        _ = try stream.read(at: 0, count: 100)
        source.arm()
        nonisolated(unsafe) let unsafeStream = stream
        let cancelled = await Task { () -> Bool in
            do {
                _ = try unsafeStream.read(at: 12 * 16_384, count: 100)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value
        #expect(cancelled, "the read was cancelled")
        // Where the inflater had got to when it stopped: a read just behind it is what the tail was for.
        let place = max(1, stream.emittedBytes) - 1
        let got = try stream.read(at: place, count: 8)
        let letter = UInt8(65 + Int(place / 16_384) % 26)
        #expect(got == Data(repeating: letter, count: 8), "the bytes at \(place) are \(letter), whatever was read before")
    }

    @Test func theTailNeverHoldsMoreThanItsBoundAndAWholeEntryReadDoesNotFeedIt() async throws {
        var payload = lettersStream(blocks: 8)
        payload.append(contentsOf: [1, 0, 0, 0xFF, 0xFF])
        let size = 8 * 16_384
        let data = SyntheticZip([deflatedEntry(payload, size: size)]).data()
        let archive = try SendFeedbackArchive.open(SendFeedbackMemoryBytes(data))
        let location = try archive.location(of: archive.listing.entries[0])
        let stream = SendFeedbackEntryStream(location)
        // A jump forward is skipped in chunks, which are appended to the tail as they come.
        _ = try stream.read(at: 100_000, count: 100)
        #expect(stream.tailCount <= SendFeedbackEntryStream.tailBytes)
        var offset: UInt64 = 100_100
        while offset < UInt64(size) {
            _ = try stream.read(at: offset, count: 16_384)
            #expect(stream.tailCount <= SendFeedbackEntryStream.tailBytes)
            offset += 16_384
        }
        let whole = SendFeedbackEntryStream(location)
        let bytes = try whole.read(at: 0, count: size, keepsTail: false)
        #expect(bytes.count == size && whole.tailCount == 0, "a read of the whole entry keeps nothing")
        // And what it leaves behind still reads right.
        #expect(try whole.read(at: 5 * 16_384, count: 4) == Data(repeating: 70, count: 4))
    }

    // MARK: C5 two end records that both fit

    @Test func anEmptyEndRecordInTheCommentThatPointsAtItselfMakesTheArchiveUnreadable() throws {
        var fake = Data([0x50, 0x4B, 0x05, 0x06]) + Data(count: 18)
        let entries = [SyntheticZip.Entry.stored("real.txt", Data("real".utf8))]
        let position = SyntheticZip(entries, comment: fake).data().count - 22
        for index in 0..<4 { fake[16 + index] = UInt8((position >> (index * 8)) & 255) }
        let data = SyntheticZip(entries, comment: fake).data()
        #expect(throws: SendFeedbackArchiveError.damaged) { try SendFeedbackArchive.open(SendFeedbackMemoryBytes(data)) }
    }

    @Test func anOrdinaryCommentStillOpensTheArchive() throws {
        let entries = [SyntheticZip.Entry.stored("real.txt", Data("real".utf8))]
        let plain = try SendFeedbackArchive.open(SendFeedbackMemoryBytes(
            SyntheticZip(entries, comment: Data("made by a build server".utf8)).data()))
        #expect(plain.listing.entries.map(\.name) == ["real.txt"])
        // The four bytes of the signature in a comment, with no end record that reaches the end of the file.
        let signature = Data([0x50, 0x4B, 0x05, 0x06]) + Data(repeating: 0x41, count: 24)
        let odd = try SendFeedbackArchive.open(SendFeedbackMemoryBytes(SyntheticZip(entries, comment: signature).data()))
        #expect(odd.listing.entries.map(\.name) == ["real.txt"])
    }

    // MARK: C4 the tree is built from the structural name

    @Test func aLongFolderNameChangesNeitherTheHierarchyNorTheFile() throws {
        let long = String(repeating: "x", count: 200)
        let archive = try reader(SendFeedbackMemoryBytes(SyntheticZip([
            .stored("folder/\(long)/real.txt", Data("private".utf8)),
        ]).data()))
        // "folder" holds one folder and nothing else, so the two are one row, as Files shows a chain.
        let top = archive.tree.level(at: "")
        let chain = try #require(top.folders.first)
        #expect(top.folders.count == 1 && top.files.isEmpty)
        #expect(chain.path == "folder/\(long)", "the hierarchy is the archive's")
        #expect(chain.label == "folder/" + String(repeating: "x", count: SendFeedbackArchiveLimits.maxNameCharacters) + "\u{2026}",
                "only what is drawn is shortened")
        let inside = archive.tree.level(at: "folder")
        #expect(inside.files.isEmpty && inside.folders.map(\.path) == ["folder/\(long)"])
        let deepest = archive.tree.level(at: chain.path)
        #expect(deepest.files.map(\.label) == ["real.txt"] && deepest.files[0].entry.id == 0)
    }

    // MARK: C6 the parser reads a name only up to the bound

    @Test func theParserKeepsOfANameOnlyWhatTheBoundLetsBeRead() throws {
        let long = String(repeating: "n", count: 5_000) + "/"
        let archive = try SendFeedbackArchive.open(SendFeedbackMemoryBytes(SyntheticZip([.stored(long, Data())]).data()))
        let entry = archive.listing.entries[0]
        #expect(entry.path.utf8.count == SendFeedbackArchiveLimits.maxNameBytes, "the name was read to the bound and no further")
        #expect(entry.isFolder, "a name that is cut is still told by its last byte")
    }

    // MARK: C3 archives inside are not kept for ever

    @Test func sixtyFourAliasesOfOneArchiveNeverHoldMoreThanTheBoundOpen() async throws {
        let inner = SyntheticZip((0..<50).map { .stored("\($0)/a/b/x.txt", Data([0x41])) }).data()
        var entries = [SyntheticZip.stored("n0.zip", inner)]
        for index in 1..<64 {
            var alias = SyntheticZip.stored("n\(index).zip", Data())
            alias.headerOffset = 0
            alias.size = UInt32(inner.count)
            alias.compressedSize = UInt32(inner.count)
            entries.append(alias)
        }
        let archive = try reader(SendFeedbackMemoryBytes(SyntheticZip(entries).data()))
        for index in entries.indices {
            #expect(try await archive.kind(of: index) == .archive)
            #expect(await archive.nestedCount <= SendFeedbackArchiveReader.nestedKept)
        }
        for index in entries.indices {
            guard case .archive(let opened) = try await archive.content(of: index) else {
                Issue.record("entry \(index) is not an archive")
                return
            }
            #expect(opened.listing.entries.count == 50, "an archive that was let go is opened again when it is asked for")
            #expect(await archive.nestedCount <= SendFeedbackArchiveReader.nestedKept)
        }
        await archive.releaseNested()
        #expect(await archive.nestedCount == 0, "the pages are gone: nothing stays open")
    }

    // MARK: N1 a cancelled read of a kind is not damage

    @Test func aCancelledReadOfAKindIsNotDamageAndLeavesWhatTheRowShowed() async throws {
        let cancelled: () async throws -> SendFeedbackEntryKind = { throw CancellationError() }
        #expect(await SendFeedbackEntryKind.shown(after: cancelled, keeping: nil) == nil, "a row that showed nothing still shows nothing")
        #expect(await SendFeedbackEntryKind.shown(after: cancelled, keeping: .text) == .text, "a row keeps what it showed")
        #expect(
            await SendFeedbackEntryKind.shown(after: { throw SendFeedbackArchiveError.damaged }, keeping: .text) == .notShown(.problem(.damaged)),
            "a read that failed is a file that is damaged")
        #expect(await SendFeedbackEntryKind.shown(after: { .picture }, keeping: nil) == .picture)
    }

    @Test func theReadOfTheKindOfADeflatedEntryEndsWithACancelAndLeavesNoKindBehind() async throws {
        let archive = try reader(SendFeedbackMemoryBytes(SyntheticZip([.deflated("a.txt", Data(repeating: 0x61, count: 5_000))]).data()))
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await archive.kind(of: 0)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await archive.kind(of: 0) == .text, "asked again, the kind is read")
    }

    // MARK: C7 the tree has at most sixteen levels

    private func treeOf(_ names: [String]) throws -> SendFeedbackArchiveTree {
        try reader(SendFeedbackMemoryBytes(SyntheticZip(names.map { .stored($0, $0.hasSuffix("/") ? Data() : Data([0x41])) }).data())).tree
    }

    @Test func aPathOfFiveHundredComponentsMakesSixteenFoldersAndTheRestIsTheFilesName() throws {
        let deep = (0..<100).map { "u\($0)" + String(repeating: "/a", count: 500) + "/f.txt" }
        let tree = try treeOf(deep)
        #expect(SendFeedbackArchiveTree.maxLevels == 16)
        #expect(tree.nodeCount == 1 + 16 * deep.count, "the top, and sixteen folders for each path: \(tree.nodeCount)")
        let top = tree.level(at: "")
        #expect(top.folders.count == 100 && top.files.isEmpty)
        let folder = try #require(top.folders.first { $0.label.hasPrefix("u7/a/") })
        #expect(folder.path.split(separator: "/").count == 16 && folder.files == 1)
        let inside = tree.level(at: folder.path)
        #expect(inside.folders.isEmpty && inside.files.count == 1, "the seventeenth component is not a folder")
        let file = try #require(inside.files.first)
        #expect(file.entry.path == deep[7], "the whole name is kept")
        #expect(file.label.hasPrefix("a/a/a/") && file.label.hasSuffix("\u{2026}"), "the rest of the path is the name, cut for drawing")
        #expect(file.label.unicodeScalars.count == SendFeedbackArchiveLimits.maxNameCharacters + 1)
    }

    @Test func theSeventeenthComponentIsTheFilesNameAndNothingPastTheSixteenthIsAFolder() throws {
        let sixteen = (1...16).map { "d\($0)" }.joined(separator: "/")
        let deeper = (1...20).map { "e\($0)" }.joined(separator: "/")
        let tree = try treeOf([sixteen + "/f.txt", sixteen + "/x/y.txt", sixteen + "/x/y/z/w.txt", deeper + "/"])
        #expect(tree.nodeCount == 1 + 16 + 16, "one chain of sixteen for the files, one for the empty folder")
        let inside = tree.level(at: sixteen)
        #expect(inside.folders.isEmpty)
        #expect(inside.files.map(\.label) == ["f.txt", "x/y.txt", "x/y/z/w.txt"])
        let end = tree.level(at: "").folders.first { $0.label.hasPrefix("e1/") }
        #expect(end?.path.split(separator: "/").count == 16 && end.map { tree.level(at: $0.path) } == SendFeedbackArchiveTree.Level(folders: [], files: []))
    }

    @Test func theBookkeepingIsAtMostSixteenPrefixesOfTheBoundPerEntry() throws {
        // The worst shape: a first component that takes nearly the whole name, so that every one of the sixteen
        // prefixes is as long as a name may be, and a different one for each entry.
        let names = (0..<50).map { String(repeating: "x", count: 975) + String(format: "%05d", $0) + String(repeating: "/b", count: 15) + "/f.txt" }
        #expect(names.allSatisfy { $0.utf8.count <= SendFeedbackArchiveLimits.maxNameBytes })
        let tree = try treeOf(names)
        #expect(tree.nodeCount == 1 + 16 * names.count)
        #expect(tree.keyBytes <= names.count * 16 * SendFeedbackArchiveLimits.maxNameBytes, "\(tree.keyBytes) bytes of paths")
        // Linear: twice the entries, twice the nodes.
        let twice = try treeOf(names + names.map { $0.replacingOccurrences(of: "xxxxx", with: "yyyyy", options: .anchored) })
        #expect(twice.nodeCount == 1 + 16 * 2 * names.count)
    }

    // MARK: R2 the bound holds for names that sanitizing makes longer

    @Test func aNameIsClampedToTheBoundAfterWhatIsNotTextIsReplaced() {
        let bound = SendFeedbackArchiveLimits.maxNameBytes
        for byte in [UInt8(0x01), 0x7F, 0xFF, 0xC0] {
            let name = SendFeedbackArchiveNames.structural(Data(repeating: byte, count: bound))
            #expect(name.utf8.count <= bound, "\(byte): \(name.utf8.count) bytes")
            #expect(!name.isEmpty && name.unicodeScalars.allSatisfy { $0 == "\u{FFFD}" })
        }
        #expect(SendFeedbackArchiveNames.structural(Data(repeating: 0x01, count: bound)) == String(repeating: "\u{FFFD}", count: 341), "a cut at a character: 1,023 bytes")
        // A character is not cut in two: the last one that fits is the last one kept.
        let tail = Data(repeating: 0x61, count: 1_022) + Data([0xF0, 0x9F, 0x98, 0x80])
        #expect(SendFeedbackArchiveNames.structural(tail) == String(repeating: "a", count: 1_022))
        #expect(SendFeedbackArchiveNames.structural(Data("FS/data/anr/anr_1".utf8)) == "FS/data/anr/anr_1", "a name that fits is whole")
    }

    @Test func theTreeBoundHoldsForNamesWithControlAndInvalidBytes() throws {
        // 975 control bytes become 2,925 bytes of replacements; a name is clamped after that, so that the keys of
        // the tree are at most sixteen prefixes of at most 1,024 bytes for each entry.
        let ctl: String = String(repeating: "\u{01}", count: 975)
        let controls: [String] = (0..<50).map { (index: Int) -> String in ctl + String(format: "%05d", index) + String(repeating: "/b", count: 15) + "/f.txt" }
        #expect(controls.allSatisfy { $0.utf8.count <= SendFeedbackArchiveLimits.maxNameBytes })
        let tree = try treeOf(controls)
        #expect(tree.keyBytes <= controls.count * 16 * SendFeedbackArchiveLimits.maxNameBytes, "\(tree.keyBytes) bytes of paths")
        let archive = try reader(SendFeedbackMemoryBytes(SyntheticZip(controls.map { .stored($0, Data([0x41])) }).data()))
        #expect(archive.listing.entries.allSatisfy { $0.path.utf8.count <= SendFeedbackArchiveLimits.maxNameBytes })
        // Spread over components, so that the names stay different inside the bound and the sixteen levels fill.
        let component = "/" + String(repeating: "\u{02}", count: 20) + "q"
        var spread: [String] = []
        for index in 0..<50 {
            let number: String = String(format: "%05d", index)
            let middle: String = String(repeating: component, count: 15)
            spread.append(number + middle + "/f.txt")
        }
        let wide = try treeOf(spread)
        #expect(wide.nodeCount == 1 + 16 * spread.count, "sanitized, 15 components of 62 bytes: \(wide.nodeCount)")
        #expect(wide.keyBytes <= spread.count * 16 * SendFeedbackArchiveLimits.maxNameBytes, "\(wide.keyBytes) bytes of paths")
    }
}
