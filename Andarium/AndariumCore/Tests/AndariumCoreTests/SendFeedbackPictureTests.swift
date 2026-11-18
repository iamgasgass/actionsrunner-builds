// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing

@testable import AndariumCore
@testable import AndariumFeedbackLogic

/// The picture of a bug report (C2): a PNG alone, decoded from a stream rebuilt out of its critical chunks, whose
/// header is read before ImageIO sees a byte. What the rebuilt stream leaves out (compressed text, profiles,
/// frames) is never expanded.
struct SendFeedbackPictureTests {
    private static let critical: Set<String> = ["IHDR", "PLTE", "tRNS", "IDAT", "IEND"]

    private func reader(_ entries: [SyntheticZip.Entry]) throws -> SendFeedbackArchiveReader {
        SendFeedbackArchiveReader(try SendFeedbackArchive.open(SendFeedbackMemoryBytes(SyntheticZip(entries).data())))
    }

    private func types(of png: Data) -> [String] { PNGParts(png).chunks.map(\.type) }

    private func isPicture(_ kind: SendFeedbackEntryKind) -> Bool {
        if case .picture = kind { return true }
        return false
    }

    /// `real` with `extra` chunks put after its header.
    private func adding(_ extra: [PNGParts.Chunk], to real: Data = PNGParts.real()) -> Data {
        var parts = PNGParts(real)
        parts.chunks.insert(contentsOf: extra, at: 1)
        return parts.data()
    }

    // MARK: What ImageIO is given

    @Test func theRebuiltStreamHoldsTheCriticalChunksAndNothingElse() throws {
        let real = PNGParts.real()
        var parts = PNGParts(real)
        let expected = parts.chunks.map(\.type).filter { Self.critical.contains($0) }
        let packed = PNGParts.letters(4_096)
        parts.chunks.insert(contentsOf: [
            PNGParts.Chunk("tEXt", Data("Comment\0hello".utf8)), PNGParts.compressed("zTXt", expanding: 0, packed: packed),
            PNGParts.compressed("iTXt", expanding: 0, packed: packed), PNGParts.compressed("iCCP", expanding: 0, packed: packed),
            PNGParts.Chunk("eXIf", Data(count: 40)), PNGParts.Chunk("tIME", Data(count: 7)), PNGParts.Chunk("pHYs", Data(count: 9)),
            PNGParts.Chunk("zzZz", Data(count: 3)),
        ], at: 1)
        let input = parts.data()
        let rebuilt = try SendFeedbackPicture.rebuilt(from: input)
        #expect(types(of: rebuilt.stream) == expected && expected.first == "IHDR" && expected.last == "IEND")
        #expect(rebuilt.stream.count <= real.count && rebuilt.stream.count < input.count, "no larger than the entry")
        #expect(rebuilt.width == 64 && rebuilt.height == 48)
        let thumbnail = try SendFeedbackPicture.thumbnail(of: input)
        #expect(thumbnail.width == 64 && thumbnail.height == 48)
    }

    @Test func aPaletteAndItsTransparencyAreKept() throws {
        var parts = PNGParts(PNGParts.real(width: 4, height: 4))
        let header = try #require(parts.chunks.firstIndex { $0.type == "IHDR" })
        let palette = PNGParts.Chunk("PLTE", Data((0..<12).map { UInt8($0 * 20) }))
        let transparency = PNGParts.Chunk("tRNS", Data([255, 128, 0, 255]))
        parts.chunks.insert(contentsOf: [PNGParts.Chunk("gAMA", Data(count: 4)), palette, transparency], at: header + 1)
        let rebuilt = try SendFeedbackPicture.rebuilt(from: parts.data())
        #expect(types(of: rebuilt.stream).prefix(3) == ["IHDR", "PLTE", "tRNS"])
    }

    @Test func aHundredAndTwentyEightCompressedChunksThatExpandToTwoMegabytesEachNeverReachImageIO() throws {
        let real = PNGParts.real(width: 1, height: 1)
        let packed = PNGParts.letters(2 << 20)
        var extra: [PNGParts.Chunk] = []
        for index in 0..<128 { extra.append(PNGParts.compressed(["zTXt", "iTXt", "iCCP"][index % 3], expanding: 0, packed: packed)) }
        let input = adding(extra, to: real)
        #expect(input.count > 100_000, "the file is a few hundred kilobytes, and claims 256 MiB of text")
        let rebuilt = try SendFeedbackPicture.rebuilt(from: input)
        #expect(rebuilt.stream.count <= real.count, "what is decoded holds none of it: \(rebuilt.stream.count) bytes")
        #expect(types(of: rebuilt.stream).allSatisfy { Self.critical.contains($0) })
        let thumbnail = try SendFeedbackPicture.thumbnail(of: input)
        #expect(thumbnail.width == 1 && thumbnail.height == 1)
    }

    @Test func theReaderShowsAPictureWithCompressedChunksFromItsCriticalChunksToo() async throws {
        let packed = PNGParts.letters(2 << 20)
        let extra = (0..<32).map { _ in PNGParts.compressed("zTXt", expanding: 0, packed: packed) }
        let archive = try reader([.stored("screenshot.png", adding(extra, to: PNGParts.real(width: 30, height: 20)))])
        #expect(isPicture(try await archive.kind(of: 0)))
        let shown = try await archive.picture(of: 0)
        #expect(shown.width == 30 && shown.height == 20)
    }

    // MARK: What is refused before ImageIO

    @Test func anAnimatedPictureIsRefused() {
        for chunk in [PNGParts.Chunk("acTL", Data(count: 8)), PNGParts.Chunk("fcTL", Data(count: 26)), PNGParts.Chunk("fdAT", Data(count: 8))] {
            #expect(throws: SendFeedbackPicture.Refusal.notPicture, "\(chunk.type)") {
                try SendFeedbackPicture.thumbnail(of: adding([chunk]))
            }
        }
        var parts = PNGParts(PNGParts.real())
        parts.chunks.insert(PNGParts.Chunk("fdAT", Data(count: 8)), at: parts.chunks.count - 1)
        #expect(throws: SendFeedbackPicture.Refusal.notPicture) { try SendFeedbackPicture.thumbnail(of: parts.data()) }
    }

    @Test func aSecondHeaderOrOneThatIsNotFirstIsRefused() {
        var twice = PNGParts(PNGParts.real())
        twice.chunks.insert(twice.chunks[0], at: 1)
        #expect(throws: SendFeedbackPicture.Refusal.notPicture) { try SendFeedbackPicture.thumbnail(of: twice.data()) }
        var late = PNGParts(PNGParts.real())
        late.chunks.insert(late.chunks[0], at: late.chunks.count - 1)
        #expect(throws: SendFeedbackPicture.Refusal.notPicture, "a second header after the data") {
            try SendFeedbackPicture.thumbnail(of: late.data())
        }
        var behind = PNGParts(PNGParts.real())
        behind.chunks.insert(PNGParts.Chunk("tEXt", Data("a\0b".utf8)), at: 0)
        #expect(throws: SendFeedbackPicture.Refusal.notPicture, "a header that is not the first chunk") {
            try SendFeedbackPicture.thumbnail(of: behind.data())
        }
        var other = PNGParts(PNGParts.real())
        other.chunks[0].data = Data(count: 12)
        #expect(throws: SendFeedbackPicture.Refusal.notPicture, "a header of the wrong length") {
            try SendFeedbackPicture.thumbnail(of: other.data())
        }
    }

    @Test func anInterlacedPictureIsRefused() {
        var parts = PNGParts(PNGParts.real())
        parts.setHeader(interlace: 1)
        #expect(throws: SendFeedbackPicture.Refusal.interlaced) { try SendFeedbackPicture.thumbnail(of: parts.data()) }
        parts.setHeader(interlace: 2)
        #expect(throws: SendFeedbackPicture.Refusal.notPicture, "no such method") { try SendFeedbackPicture.thumbnail(of: parts.data()) }
    }

    @Test func aHeaderThatDeclaresTooMuchIsRefusedBeforeImageIOIsGivenAnything() throws {
        func claim(_ width: UInt32, _ height: UInt32) -> Data {
            var parts = PNGParts(PNGParts.real())
            parts.setHeader(width: width, height: height)
            return parts.data()
        }
        #expect(SendFeedbackPicture.maxSide == 8_192 && SendFeedbackPicture.maxPixels == 16_000_000)
        for (width, height) in [(8_193, 10), (10, 8_193), (4_001, 4_000), (8_192, 1_954), (0xFFFF_FFF0, 0xFFFF_FFF0), (0x8000_0000, 1)] as [(UInt32, UInt32)] {
            #expect(throws: SendFeedbackPicture.Refusal.tooLarge, "\(width) by \(height)") {
                try SendFeedbackPicture.thumbnail(of: claim(width, height))
            }
        }
        for (width, height) in [(0, 10), (10, 0)] as [(UInt32, UInt32)] {
            #expect(throws: SendFeedbackPicture.Refusal.notPicture, "\(width) by \(height)") { try SendFeedbackPicture.rebuilt(from: claim(width, height)) }
        }
        let widest = try SendFeedbackPicture.rebuilt(from: claim(8_192, 1_953))
        #expect(widest.width == 8_192 && widest.height == 1_953, "15,998,976 pixels")
        let square = try SendFeedbackPicture.rebuilt(from: claim(4_000, 4_000))
        #expect(square.width * square.height == SendFeedbackPicture.maxPixels)
    }

    @Test func aMalformedListOfChunksIsRefused() {
        let real = PNGParts.real()
        let parts = PNGParts(real)
        let data = parts.chunks.first { $0.type == "IDAT" }!.data
        func refuses(_ input: Data, _ why: String) {
            #expect(throws: SendFeedbackPicture.Refusal.notPicture, "\(why)") { try SendFeedbackPicture.thumbnail(of: input) }
        }
        // Truncated: in the signature, in a chunk header, in the data of a chunk, before the end chunk.
        for cut in [0, 4, 8, 12, 20, 33, 40, real.count / 2, real.count - 13, real.count - 12, real.count - 1] {
            refuses(real.prefix(cut), "cut after \(cut) bytes")
        }
        // A chunk that says it is longer than what is left, or longer than a chunk may be.
        var longer = real
        let idat = PNGParts.signature.count + 25  // the first chunk after the header
        for (offset, value) in [(0, 0x7F), (1, 0xFF), (2, 0xFF), (3, 0xFF)] { longer[idat + offset] = UInt8(value) }
        refuses(longer, "a chunk of two gigabytes")
        for (offset, value) in [(0, 0xFF), (1, 0xFF), (2, 0xFF), (3, 0xFF)] { longer[idat + offset] = UInt8(value) }
        refuses(longer, "a chunk of four gigabytes")
        // Missing parts and the wrong order.
        var noData = parts
        noData.chunks.removeAll { $0.type == "IDAT" }
        refuses(noData.data(), "no image data")
        var noEnd = parts
        noEnd.chunks.removeAll { $0.type == "IEND" }
        refuses(noEnd.data(), "no end chunk")
        var split = parts
        split.chunks.insert(contentsOf: [PNGParts.Chunk("IDAT", data), PNGParts.Chunk("tEXt", Data("a\0b".utf8)), PNGParts.Chunk("IDAT", data)], at: 1)
        refuses(split.data(), "image data that something comes between")
        var palette = parts
        palette.chunks.insert(PNGParts.Chunk("PLTE", Data(count: 12)), at: palette.chunks.count - 1)
        refuses(palette.data(), "a palette after the data")
        var twice = parts
        twice.chunks.insert(contentsOf: [PNGParts.Chunk("PLTE", Data(count: 12)), PNGParts.Chunk("PLTE", Data(count: 12))], at: 1)
        refuses(twice.data(), "two palettes")
        var odd = parts
        odd.chunks.insert(PNGParts.Chunk("PLTE", Data(count: 10)), at: 1)
        refuses(odd.data(), "a palette that is not whole entries")
        var wide = parts
        wide.chunks.insert(PNGParts.Chunk("tRNS", Data(count: 257)), at: 1)
        refuses(wide.data(), "transparency beyond 256 entries")
        var end = parts
        end.chunks[end.chunks.count - 1].data = Data(count: 4)
        refuses(end.data(), "an end chunk that holds something")
        refuses(Data(), "nothing")
        refuses(Data(repeating: 0xFF, count: 600), "not a PNG")
        refuses(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + [UInt8](repeating: 0, count: 200)), "a signature and zeros")
    }

    @Test func aListOfMoreChunksThanTheBoundIsRefused() throws {
        var parts = PNGParts(PNGParts.real())
        let filler = PNGParts.Chunk("zzZz")
        parts.chunks.insert(contentsOf: [PNGParts.Chunk](repeating: filler, count: SendFeedbackPicture.maxChunks - 8), at: 1)
        let count = parts.chunks.count
        #expect(count < SendFeedbackPicture.maxChunks)
        _ = try SendFeedbackPicture.rebuilt(from: parts.data())
        parts.chunks.insert(contentsOf: [PNGParts.Chunk](repeating: filler, count: SendFeedbackPicture.maxChunks), at: 1)
        #expect(throws: SendFeedbackPicture.Refusal.notPicture) { try SendFeedbackPicture.rebuilt(from: parts.data()) }
    }

    @Test func dataAfterTheEndChunkIsNotDecoded() throws {
        let real = PNGParts.real()
        let input = real + Data(repeating: 0x41, count: 5_000)
        let rebuilt = try SendFeedbackPicture.rebuilt(from: input)
        let kept = PNGParts(real).chunks.filter { Self.critical.contains($0.type) }
        #expect(rebuilt.stream.count == 8 + kept.reduce(0) { $0 + $1.data.count + 12 }, "what follows the end chunk is left out")
    }

    @Test func theChecksAfterImageIOStayAndBoundWhatIsDecoded() throws {
        let thumbnail = try SendFeedbackPicture.thumbnail(of: PNGParts.real(width: 3_000, height: 2_000))
        #expect(thumbnail.width == 3_000 && thumbnail.height == 2_000, "the size the header declared")
        #expect(max(thumbnail.image.width, thumbnail.image.height) == SendFeedbackPicture.thumbnailPixels)
        let small = try SendFeedbackPicture.thumbnail(of: PNGParts.real(width: 40, height: 30))
        #expect(small.image.width <= SendFeedbackPicture.thumbnailPixels, "a small picture is not enlarged past its size")
    }

    @Test func anAncillaryChunkThatFollowsTheImageDataIsSkippedAndTheEndIsStillAccepted() throws {
        // IHDR, IDAT, tEXt, IEND (84 bytes): the text is left out and the picture opens.
        var parts = PNGParts(PNGParts.real(width: 1, height: 1))
        parts.chunks.removeAll { !Self.critical.contains($0.type) }
        let end = parts.chunks.count - 1
        parts.chunks.insert(contentsOf: [PNGParts.Chunk("tEXt", Data("Comment\0hi".utf8)), PNGParts.Chunk("tIME", Data(count: 7))], at: end)
        let input = parts.data()
        let rebuilt = try SendFeedbackPicture.rebuilt(from: input)
        #expect(types(of: rebuilt.stream) == ["IHDR", "IDAT", "IEND"] && rebuilt.stream.count < input.count)
        let thumbnail = try SendFeedbackPicture.thumbnail(of: input)
        #expect(thumbnail.width == 1 && thumbnail.height == 1)
    }

    @Test func aSecondRunOfImageDataAfterASkippedChunkIsStillRefused() {
        var parts = PNGParts(PNGParts.real(width: 1, height: 1))
        parts.chunks.removeAll { !Self.critical.contains($0.type) }
        let idat = parts.chunks[parts.chunks.firstIndex { $0.type == "IDAT" }!]
        parts.chunks.insert(contentsOf: [PNGParts.Chunk("tEXt", Data("a\0b".utf8)), idat], at: parts.chunks.count - 1)
        #expect(throws: SendFeedbackPicture.Refusal.notPicture) { try SendFeedbackPicture.rebuilt(from: parts.data()) }
    }

    // MARK: What the image data may cost

    @Test func imageDataThatInflatesToGigabytesBehindOnePixelIsRefusedBeforeImageIO() throws {
        // 1 by 1, and an IDAT of 64 KiB that inflates to 64 MiB of zeros (the reviewer's was 33 MB for 34 GB).
        var parts = PNGParts(PNGParts.real(width: 1, height: 1))
        let index = try #require(parts.chunks.firstIndex { $0.type == "IDAT" })
        parts.chunks[index].data = PNGParts.zlibStream(of: Data(count: 64 << 20))
        let input = parts.data()
        #expect(input.count > 10_000)
        #expect(throws: SendFeedbackPicture.Refusal.notPicture) { try SendFeedbackPicture.rebuilt(from: input) }
        #expect(throws: SendFeedbackPicture.Refusal.notPicture) { try SendFeedbackPicture.thumbnail(of: input) }
    }

    @Test func theMostImageDataAValidStreamNeedsIsTheRowsAndTheStoredBlocks() {
        // Rows of a filter byte and the pixels padded to a byte, as zlib stores them at worst (a two-byte header,
        // five bytes for each 16 KiB, a four-byte checksum), and 1 KiB of slack.
        #expect(SendFeedbackPicture.maxImageDataBytes(width: 1, height: 1, bitDepth: 8, colourType: 6) == 6 + 5 + 5 + 1_024)
        #expect(SendFeedbackPicture.maxImageDataBytes(width: 100, height: 100, bitDepth: 1, colourType: 0) == 6 + 1_400 + 5 + 1_024)
        #expect(SendFeedbackPicture.maxImageDataBytes(width: 10, height: 10, bitDepth: 16, colourType: 6) == 6 + 810 + 5 + 1_024)
        #expect(SendFeedbackPicture.maxImageDataBytes(width: 1_000, height: 1_000, bitDepth: 8, colourType: 2) == 6 + 3_001_000 + 5 * 184 + 1_024)
    }

    @Test func imageDataOfExactlyTheLimitIsKeptAndOneByteMoreIsRefused() throws {
        for (width, height, depth, colour) in [(1, 1, 8, 6), (100, 100, 1, 0), (10, 10, 16, 6), (7, 5, 4, 3), (33, 9, 8, 4)] as [(UInt32, UInt32, UInt8, UInt8)] {
            let limit = SendFeedbackPicture.maxImageDataBytes(width: Int(width), height: Int(height), bitDepth: Int(depth), colourType: Int(colour))
            func png(idat: Int) -> Data {
                PNGParts(chunks: [PNGParts.header(width: width, height: height, depth: depth, colour: colour), PNGParts.Chunk("IDAT", Data(count: idat)), PNGParts.Chunk("IEND")]).data()
            }
            #expect(try SendFeedbackPicture.rebuilt(from: png(idat: limit)).width == Int(width), "\(width) by \(height), \(depth) bits, colour \(colour)")
            #expect(throws: SendFeedbackPicture.Refusal.notPicture, "\(width) by \(height), \(depth) bits, colour \(colour)") {
                try SendFeedbackPicture.rebuilt(from: png(idat: limit + 1))
            }
        }
        // The total of several chunks is what counts.
        let limit = SendFeedbackPicture.maxImageDataBytes(width: 1, height: 1, bitDepth: 8, colourType: 6)
        let chunks = [PNGParts.header(width: 1, height: 1, depth: 8, colour: 6)] + (0..<4).map { _ in PNGParts.Chunk("IDAT", Data(count: limit / 4 + 1)) } + [PNGParts.Chunk("IEND")]
        #expect(throws: SendFeedbackPicture.Refusal.notPicture) { try SendFeedbackPicture.rebuilt(from: PNGParts(chunks: chunks).data()) }
    }

    @Test func aValidStreamOfStoredBlocksAtTheLimitStillOpens() throws {
        // The worst a valid encoder writes: every row stored, in blocks of 16 KiB. A 1,000 by 1,000 RGB picture.
        let rows = Data(count: 1_000 * (1 + 3_000))
        let idat = PNGParts.stored(rows)
        let limit = SendFeedbackPicture.maxImageDataBytes(width: 1_000, height: 1_000, bitDepth: 8, colourType: 2)
        #expect(idat.count <= limit && limit - idat.count < 1_100, "the stream is \(idat.count) bytes of at most \(limit)")
        let png = PNGParts(chunks: [PNGParts.header(width: 1_000, height: 1_000), PNGParts.Chunk("IDAT", idat), PNGParts.Chunk("IEND")]).data()
        let thumbnail = try SendFeedbackPicture.thumbnail(of: png)
        #expect(thumbnail.width == 1_000 && thumbnail.height == 1_000)
        // Blocks of 4 KiB, as a smaller buffer writes them, still fit.
        let small = PNGParts.stored(rows, block: 4_096)
        #expect(small.count > limit, "five bytes for each 4 KiB is more than the limit allows: that encoder is not valid here")
    }

    // MARK: What a row says

    @Test func onlyAPNGIsAPictureAndAJPEGIsOneThatIsNotShown() async throws {
        let png = PNGParts.real(width: 8, height: 8)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 0, count: 100))
        let archive = try reader([
            .stored("shot.png", png), .stored("photo.jpg", jpeg), .stored("photo.JPEG", jpeg), .stored("liar.jpg", Data("text, whatever the name says\n".utf8)),
            .stored("jpeg-as.png", jpeg),
        ])
        #expect(isPicture(try await archive.kind(of: 0)))
        #expect(try await archive.kind(of: 1) == .notShown(.pictureRefused), "Picture, not shown")
        #expect(try await archive.kind(of: 2) == .notShown(.pictureRefused))
        #expect(try await archive.kind(of: 3) == .text, "text under a picture's name is text")
        #expect(try await archive.kind(of: 4) == .notShown(.notText), "a JPEG under a PNG's name")
        await #expect(throws: SendFeedbackPicture.Refusal.notPicture) { try await archive.picture(of: 1) }
        guard case .unavailable(.pictureRefused) = try await archive.content(of: 1) else {
            Issue.record("a JPEG is not told as one that is not shown")
            return
        }
    }
}
