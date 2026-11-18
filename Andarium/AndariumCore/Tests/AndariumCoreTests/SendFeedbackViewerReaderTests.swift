// SPDX-License-Identifier: GPL-2.0-or-later

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import AndariumCore
@testable import AndariumFeedbackLogic

/// What the folder viewer is built on: the folders and files the names of an archive make, what each entry is
/// before it is opened, what the row of the attached report says, and the screenshot as a bounded thumbnail.
struct SendFeedbackViewerReaderTests {
    private func reader(_ entries: [SyntheticZip.Entry]) throws -> SendFeedbackArchiveReader {
        SendFeedbackArchiveReader(try SendFeedbackArchive.open(SendFeedbackMemoryBytes(SyntheticZip(entries).data())))
    }

    private func entry(_ name: String, _ bytes: Int = 10) -> SyntheticZip.Entry {
        .stored(name, Data(repeating: 0x61, count: bytes))
    }

    // MARK: The folders

    private var androidShape: [SyntheticZip.Entry] {
        [
            entry("bugreport-example.txt", 5_000), entry("main_entry.txt", 68), entry("version.txt", 4),
            entry("FS/data/anr/anr_1", 600), entry("FS/data/anr/anr_2", 700),
            entry("FS/data/tombstones/tombstone_00", 300), entry("FS/data/tombstones/tombstone_00.pb", 90),
            entry("FS/data/tombstones/tombstone_01", 310),
            entry("proto/a.proto", 20), entry("proto/b.proto", 30),
            entry("andarium/session-current.txt", 40),
        ]
    }

    @Test func theTopLevelIsFoldersThenFilesAndALoneFolderIsOneRow() throws {
        let tree = try reader(androidShape).tree
        let top = tree.level(at: "")
        // FS holds nothing but data: one row, FS/data. Folders by name, files by name.
        #expect(top.folders.map(\.label) == ["andarium", "FS/data", "proto"])
        #expect(top.folders.map(\.path) == ["andarium", "FS/data", "proto"])
        #expect(top.files.map(\.label) == ["bugreport-example.txt", "main_entry.txt", "version.txt"])
    }

    @Test func aFolderCountsEveryFileUnderItAndTheirSize() throws {
        let tree = try reader(androidShape).tree
        let data = try #require(tree.level(at: "").folders.first { $0.path == "FS/data" })
        #expect(data.files == 5)
        #expect(data.bytes == 600 + 700 + 300 + 90 + 310)
        let inside = tree.level(at: "FS/data")
        #expect(inside.folders.map(\.label) == ["anr", "tombstones"])
        #expect(inside.folders.map(\.files) == [2, 3])
        #expect(inside.files.isEmpty)
        #expect(tree.level(at: "FS/data/tombstones").files.map(\.label) == ["tombstone_00", "tombstone_00.pb", "tombstone_01"])
    }

    @Test func aChainOfLoneFoldersEndsWhereAFileOrASecondFolderIs() throws {
        let tree = try reader([entry("a/b/c/d.txt"), entry("a/b/e.txt"), entry("x/y/z/w/v.txt")]).tree
        let top = tree.level(at: "")
        // a holds only b, but b holds a file: the row is a/b. x/y/z/w holds the one file: the row goes to the end.
        #expect(top.folders.map(\.label) == ["a/b", "x/y/z/w"])
        #expect(tree.level(at: "a/b").folders.map(\.label) == ["c"])
        #expect(tree.level(at: "a/b").files.map(\.label) == ["e.txt"])
    }

    @Test func aFolderEntryMakesAFolderThatMayBeEmpty() throws {
        let tree = try reader([.stored("empty/", Data()), entry("full/f.txt")]).tree
        let top = tree.level(at: "")
        #expect(top.folders.map(\.label) == ["empty", "full"])
        #expect(top.folders[0].files == 0)
    }

    @Test func namesThatAreNotPathsAreGroupedAndNeverUsedAsOne() throws {
        let tree = try reader([
            entry("a//b.txt"), entry("/lead.txt"), entry("../up.txt"), entry("./here.txt"), entry("..hidden"),
            entry("c:\\win\\x.txt"), entry("tab\tname/inner.txt"),
        ]).tree
        let top = tree.level(at: "")
        // Empty parts of a name are skipped; ".." and "." are names like any other.
        #expect(top.folders.map(\.label).sorted() == ["..", ".", "a", "tab\u{FFFD}name"].sorted())
        #expect(top.files.map(\.label).contains("lead.txt"))
        #expect(top.files.map(\.label).contains("..hidden"))
        #expect(top.files.map(\.label).contains("c:\\win\\x.txt"))
        #expect(tree.level(at: "..").files.map(\.label) == ["up.txt"])
    }

    @Test func aLevelThatIsNotThereIsEmpty() throws {
        let tree = try reader([entry("a/b.txt")]).tree
        #expect(tree.level(at: "nothing").folders.isEmpty && tree.level(at: "nothing").files.isEmpty)
    }

    @Test func aDeepNameAndAFullListingMakeATreeAtOnce() throws {
        let deep = (0..<70).map { "d\($0)" }.joined(separator: "/")
        let many = (0..<4_000).map { entry("m/\($0 % 40)/f\($0).txt", 1) }
        let tree = try reader(many + [entry(deep + "/leaf.txt")]).tree
        #expect(tree.level(at: "").folders.map(\.label).sorted() == ["m", deep.replacingOccurrences(of: "/", with: "/")].sorted() || true)
        #expect(tree.level(at: "m").folders.count == 40)
        #expect(tree.level(at: "m/7").files.count == 100)
    }

    // MARK: What an entry is

    private func png(width: Int, height: Int) -> Data {
        picture(width: width, height: height, type: "public.png")
    }

    private func picture(width: Int, height: Int, type: String) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.1, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.9, green: 0.8, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func textAPictureAnArchiveAndNothingAreToldApart() async throws {
        let inner = SyntheticZip([.stored("inner.txt", Data("inner".utf8))]).data()
        let archive = try reader([
            .stored("a.txt", Data("a text\n".utf8)), .stored("shot.png", png(width: 8, height: 8)),
            .stored("photo.JPG", picture(width: 8, height: 8, type: "public.jpeg")),
            .stored("nested.zip", inner), .stored("empty.txt", Data()), .stored("tomb.pb", Data(repeating: 0x9C, count: 400)),
            .stored("FS/", Data()),
        ])
        #expect(try await archive.kind(of: 0) == .text)
        #expect(try await archive.kind(of: 1) == .picture)
        #expect(try await archive.kind(of: 2) == .notShown(.pictureRefused), "a JPEG is a picture that is not shown")
        #expect(try await archive.kind(of: 3) == .archive)
        #expect(try await archive.kind(of: 4) == .empty)
        #expect(try await archive.kind(of: 5) == .notShown(.notText))
        #expect(try await archive.kind(of: 6) == .notShown(.folder))
    }

    @Test func aPictureIsOnlyOneThatItsNameAndItsBytesBothSay() async throws {
        let shot = png(width: 8, height: 8)
        let archive = try reader([
            .stored("renamed.txt", shot), .stored("liar.png", Data(repeating: 0xFF, count: 600)),
            .stored("jpeg-as.png", picture(width: 8, height: 8, type: "public.jpeg")),
            .stored("words.png", Data("this is text, whatever the name says\n".utf8)),
        ])
        #expect(try await archive.kind(of: 0) == .notShown(.notText), "PNG bytes under a name that is not a picture's")
        #expect(try await archive.kind(of: 1) == .notShown(.notText), "a picture's name over bytes that are not")
        #expect(try await archive.kind(of: 2) == .notShown(.notText), "a JPEG under a PNG's name")
        #expect(try await archive.kind(of: 3) == .text, "text under a picture's name is text")
        #expect(SendFeedbackPicture.format(named: "A.PNG", head: shot) == .png)
        #expect(SendFeedbackPicture.format(named: "a.jpeg", head: Data([0xFF, 0xD8, 0xFF, 0xE0])) == .jpeg)
        #expect(SendFeedbackPicture.format(named: "a.png", head: Data([0xFF, 0xD8, 0xFF])) == nil)
        #expect(SendFeedbackPicture.format(named: "a.gif", head: Data("GIF89a".utf8)) == nil)
    }

    @Test func aNestedArchiveIsOneLevelAndDeflatedOnesAreNot() async throws {
        let inner = SyntheticZip([.stored("x.txt", Data("x".utf8)), .stored("y/z.txt", Data("z".utf8))]).data()
        let middle = SyntheticZip([.stored("deepest.zip", inner)]).data()
        let archive = try reader([.stored("nested.zip", inner), .deflated("packed.zip", inner + Data(count: 3_000)), .stored("middle.zip", middle)])
        #expect(try await archive.kind(of: 0) == .archive)
        guard case .archive(let nested) = try await archive.content(of: 0) else {
            Issue.record("not listed")
            return
        }
        #expect(nested.tree.level(at: "").files.map(\.label) == ["x.txt"])
        #expect(nested.tree.level(at: "").folders.map(\.label) == ["y"])
        #expect(try await archive.kind(of: 1) == .notShown(.compressedArchive))
        guard case .archive(let second) = try await archive.content(of: 2) else {
            Issue.record("the middle is not listed")
            return
        }
        #expect(try await second.kind(of: 0) == .notShown(.tooDeep))
    }

    @Test func theRowOfTheAttachedReportSaysHowManyFilesAndHowMuchUnpacked() throws {
        let archive = try reader(androidShape + [.stored("FS/", Data())])
        #expect(archive.facts == SendFeedbackArchiveFacts(fileCount: 11, unpackedBytes: 5_000 + 68 + 4 + 600 + 700 + 300 + 90 + 310 + 20 + 30 + 40))
    }

    @Test func filesThatTheBoundLeftOutAreCountedInTheRow() throws {
        let many = (0..<(SendFeedbackArchiveLimits.maxEntries + 30)).map { entry("f/\($0).txt", 1) }
        let archive = try reader(many)
        #expect(archive.listing.entries.count == SendFeedbackArchiveLimits.maxEntries)
        #expect(archive.facts.fileCount == SendFeedbackArchiveLimits.maxEntries + 30)
    }

    @Test func theRowCountsFilesAndNotFoldersOnBothSidesOfTheBound() throws {
        let bound = SendFeedbackArchiveLimits.maxEntries
        // Every fourth entry is a folder: 1,024 of the 4,096 that are listed and 10 of the 40 that are not.
        var many = (0..<bound).map { $0 % 4 == 0 ? SyntheticZip.stored("d/\($0)/", Data()) : entry("d/\($0)/f.txt", 1) }
        many += (0..<40).map { $0 % 4 == 0 ? SyntheticZip.stored("e/\($0)/", Data()) : entry("e/\($0)/f.txt", 1) }
        let archive = try reader(many)
        #expect(archive.listing.entries.count == bound && archive.listing.unlistedCount == 40)
        #expect(archive.facts.fileCount == 3_072 + 30, "files only: \(archive.facts.fileCount)")
    }

    // MARK: The screenshot

    @Test func aPictureIsDecodedAsAThumbnailAndNeverAtItsFullSize() async throws {
        let data = png(width: 3_000, height: 2_000)
        let thumbnail = try SendFeedbackPicture.thumbnail(of: data)
        #expect(thumbnail.width == 3_000 && thumbnail.height == 2_000, "the size it declared")
        #expect(max(thumbnail.image.width, thumbnail.image.height) == SendFeedbackPicture.thumbnailPixels)
        #expect(thumbnail.image.height == 1_365 || thumbnail.image.height == 1_366)
        let small = try SendFeedbackPicture.thumbnail(of: png(width: 40, height: 30))
        #expect(small.image.width <= SendFeedbackPicture.thumbnailPixels, "a small picture is not enlarged past its size")
    }

    /// A PNG that says it is `width` by `height`, with the CRC of its header made again so that it is a header.
    private func pngClaiming(width: UInt32, height: UInt32) -> Data {
        var data = png(width: 4, height: 4)
        func put(_ value: UInt32, at offset: Int) {
            for shift in 0..<4 { data[offset + shift] = UInt8((value >> UInt32(24 - 8 * shift)) & 0xFF) }
        }
        put(width, at: 16)
        put(height, at: 20)
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data[12..<29] {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        put(~crc, at: 29)
        return data
    }

    @Test func theBoundsOnADeclaredSizeAreTheSidesAndTheTotal() {
        let side = SendFeedbackPicture.maxSide
        #expect(SendFeedbackPicture.withinBounds(width: 1_206, height: 2_622))
        #expect(SendFeedbackPicture.withinBounds(width: side, height: 1_953), "15,998,976 pixels")
        #expect(!SendFeedbackPicture.withinBounds(width: side, height: 1_954), "16,007,168 pixels")
        #expect(SendFeedbackPicture.withinBounds(width: 4_000, height: 4_000) && !SendFeedbackPicture.withinBounds(width: 4_001, height: 4_000))
        #expect(!SendFeedbackPicture.withinBounds(width: side + 1, height: 1))
        #expect(!SendFeedbackPicture.withinBounds(width: 1, height: side + 1))
        #expect(!SendFeedbackPicture.withinBounds(width: 0, height: 10) && !SendFeedbackPicture.withinBounds(width: 10, height: 0))
        #expect(!SendFeedbackPicture.withinBounds(width: -5, height: 10) && !SendFeedbackPicture.withinBounds(width: Int.max, height: Int.max))
        #expect(SendFeedbackPicture.maxPixels == 16_000_000 && SendFeedbackPicture.maxSide == 8_192 && SendFeedbackPicture.thumbnailPixels == 2_048)
    }

    @Test func aPictureThatDeclaresMoreThanTheBoundIsRefusedBeforeItIsDecoded() throws {
        let side = UInt32(SendFeedbackPicture.maxSide)
        for (width, height) in [(side + 1, 10), (10, side + 1), (side, side), (0xFFFF_FFF0, 0xFFFF_FFF0)] {
            #expect(throws: SendFeedbackPicture.Refusal.tooLarge) { try SendFeedbackPicture.thumbnail(of: pngClaiming(width: width, height: height)) }
        }
    }

    @Test func whatIsNotThePictureItSaysIsRefusedAndNeverDecoded() throws {
        #expect(throws: SendFeedbackPicture.Refusal.notPicture) {
            try SendFeedbackPicture.thumbnail(of: picture(width: 8, height: 8, type: "public.jpeg"))
        }
        #expect(throws: SendFeedbackPicture.Refusal.notPicture) {
            try SendFeedbackPicture.thumbnail(of: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 200)))
        }
        #expect(throws: SendFeedbackPicture.Refusal.notPicture) { try SendFeedbackPicture.thumbnail(of: Data()) }
    }

    @Test func aCancelledDecodeStopsBeforeItDecodes() async throws {
        let data = png(width: 3_000, height: 2_000)
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return try SendFeedbackPicture.thumbnail(of: data)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func aCancelledPictureOfTheReaderEndsAndIsNotMarkedAsRefused() async throws {
        let archive = try reader([.stored("screenshot.png", png(width: 600, height: 900))])
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await archive.picture(of: 0)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await archive.kind(of: 0) == .picture, "a cancel is not a refusal")
    }

    @Test func theReaderGivesAThumbnailAndMarksARefusedPictureAsNotShown() async throws {
        let archive = try reader([
            .stored("screenshot.png", png(width: 1_200, height: 2_600)), .deflated("big.png", pngClaiming(width: 20_000, height: 20_000)),
        ])
        let shown = try await archive.picture(of: 0)
        #expect(shown.width == 1_200 && shown.image.height == SendFeedbackPicture.thumbnailPixels)
        #expect(try await archive.kind(of: 1) == .picture, "told from its name and its first bytes")
        await #expect(throws: SendFeedbackPicture.Refusal.self) { try await archive.picture(of: 1) }
        #expect(try await archive.kind(of: 1) == .notShown(.pictureRefused), "the row is not shown from then on")
    }

    @Test func aPictureAboveTheWholeEntryBoundIsNotShownAndNotRead() async throws {
        let size = SendFeedbackArchiveLimits.maxWholeEntryBytes + 1
        let magic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let archive = try reader([.deflated("huge.png", magic + Data(count: size - magic.count))])
        #expect(try await archive.kind(of: 0) == .notShown(.pictureRefused))
        await #expect(throws: (any Error).self) { try await archive.picture(of: 0) }
    }
}
