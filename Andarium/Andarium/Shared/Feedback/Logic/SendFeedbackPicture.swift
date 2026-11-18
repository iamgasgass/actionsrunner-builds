// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import CoreGraphics
import Foundation
import ImageIO

// The screenshot of a bug report, shown as a picture. The bytes were written by the virtual machine, so nothing
// about them is trusted. Only a PNG is shown (a JPEG is told apart only to be refused). ImageIO expands the
// compressed text and profile chunks of a PNG before any check of ours, so the file is never given to it as it
// is: its chunks are walked here, within bounds, its header is read and checked, and ImageIO is given a stream
// rebuilt from the critical chunks alone (IHDR, PLTE, tRNS, IDAT and IEND), which is no larger than the file. What
// it makes of that is a thumbnail of a bounded size, never an image of the full size.

nonisolated enum SendFeedbackPictureFormat: Equatable, Sendable {
    case png
    /// A JPEG is told from its name and its first bytes so that its row can say it is not shown.
    case jpeg
}

nonisolated enum SendFeedbackPicture {
    /// The most a side may declare.
    static let maxSide = 8_192
    /// The most pixels a picture may declare in all.
    static let maxPixels = 16_000_000
    /// The longest side of what is decoded.
    static let thumbnailPixels = 2_048
    /// The most chunks a file may list before its end chunk: far above the thousands that a file of the entry
    /// bound holds in image data of 8 KiB each.
    static let maxChunks = 65_536
    /// The most that a palette (256 entries of three bytes) or a transparency chunk may hold.
    static let maxPaletteBytes = 768
    static let maxTransparencyBytes = 256

    enum Refusal: Error, Equatable, Sendable {
        /// Not one plain PNG: a malformed list of chunks, a second header, an animation, or what the decoder
        /// will not call one.
        case notPicture
        /// A side or a total of pixels above the bounds.
        case tooLarge
        /// An interlaced image: decoded by passes, which the bounded decode does not take.
        case interlaced
        /// The decoder would not make it.
        case undecodable
    }

    /// A decoded picture, and the size it declared.
    struct Thumbnail: @unchecked Sendable {
        let image: CGImage
        let width: Int
        let height: Int
    }

    /// The critical chunks of a PNG in the order of the file, and the size its header declared.
    struct Rebuilt: Sendable {
        let stream: Data
        let width: Int
        let height: Int
    }

    /// The format an entry may be told as: its name ends in the format's extension and its first bytes are the
    /// format's signature. Anything else is not a picture to show.
    static func format(named name: String, head: Data) -> SendFeedbackPictureFormat? {
        let lower = name.lowercased()
        let bytes = [UInt8](head.prefix(8))
        if lower.hasSuffix(".png"), bytes == signature { return .png }
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg"), bytes.count >= 3, Array(bytes[0..<3]) == [0xFF, 0xD8, 0xFF] {
            return .jpeg
        }
        return nil
    }

    /// Whether a picture of this declared size may be decoded: both sides positive and within `maxSide`, and no more
    /// than `maxPixels` in all.
    static func withinBounds(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maxSide && height <= maxSide && width <= maxPixels / height
    }

    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private enum Chunk {
        static let header: UInt32 = 0x4948_4452  // IHDR
        static let palette: UInt32 = 0x504C_5445  // PLTE
        static let transparency: UInt32 = 0x7452_4E53  // tRNS
        static let data: UInt32 = 0x4944_4154  // IDAT
        static let end: UInt32 = 0x4945_4E44  // IEND
        /// The chunks of an animation (APNG): a picture of frames is not one picture.
        static let animation: Set<UInt32> = [0x6163_544C, 0x6663_544C, 0x6664_4154]  // acTL, fcTL, fdAT
    }

    /// Walks the chunks of the PNG in `data`, within `maxChunks`, reads and checks its header, and gives back the
    /// stream of its critical chunks alone, with the size its header declared. Every chunk's length must fit what
    /// is left of the file; the header comes first and once, the palette and the transparency come once and
    /// before the image data, the image data is one run of chunks (skipped chunks may follow it, and then only the end chunk), and the end chunk is present. The image data together is no more than `maxImageDataBytes` for the header. What follows the
    /// end chunk, and every chunk that is not critical, is left out.
    static func rebuilt(from data: Data) throws -> Rebuilt {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Rebuilt in
            guard bytes.count >= signature.count, bytes.prefix(signature.count).elementsEqual(signature) else {
                throw Refusal.notPicture
            }
            func u32(_ at: Int) -> Int {
                Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            }
            enum Stage { case start, beforeData, inData, afterData }
            var stage = Stage.start
            var sawPalette = false
            var sawTransparency = false
            var size: (width: Int, height: Int, imageData: Int) = (0, 0, 0)
            var imageData = 0
            var out = Data(signature)
            out.reserveCapacity(min(bytes.count, 1 << 20))
            var offset = signature.count
            var count = 0
            var ended = false
            while !ended {
                if count % 256 == 0 { try Task.checkCancellation() }
                count += 1
                guard count <= maxChunks, bytes.count - offset >= 12 else { throw Refusal.notPicture }
                let length = u32(offset)
                guard length <= 0x7FFF_FFFF, length <= bytes.count - offset - 12 else { throw Refusal.notPicture }
                let type = UInt32(truncatingIfNeeded: u32(offset + 4))
                var keep = false
                switch type {
                case Chunk.header:
                    guard stage == .start, length == 13 else { throw Refusal.notPicture }
                    size = try header(width: u32(offset + 8), height: u32(offset + 12), fields: bytes[(offset + 16)..<(offset + 21)])
                    stage = .beforeData
                    keep = true
                case Chunk.palette:
                    guard stage == .beforeData, !sawPalette, !sawTransparency, length > 0, length % 3 == 0, length <= maxPaletteBytes
                    else { throw Refusal.notPicture }
                    sawPalette = true
                    keep = true
                case Chunk.transparency:
                    guard stage == .beforeData, !sawTransparency, length > 0, length <= maxTransparencyBytes else { throw Refusal.notPicture }
                    sawTransparency = true
                    keep = true
                case Chunk.data:
                    guard stage == .beforeData || stage == .inData else { throw Refusal.notPicture }
                    imageData += length
                    guard imageData <= size.imageData else { throw Refusal.notPicture }
                    stage = .inData
                    keep = true
                case Chunk.end:
                    // Chunks that are left out may stand between the image data and the end; image data may not.
                    guard stage == .inData || stage == .afterData, length == 0 else { throw Refusal.notPicture }
                    ended = true
                    keep = true
                default:
                    guard stage != .start, !Chunk.animation.contains(type) else { throw Refusal.notPicture }
                    if stage == .inData { stage = .afterData }
                }
                if keep { out.append(bytes.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: 12 + length) }
                offset += 12 + length
            }
            return Rebuilt(stream: out, width: size.width, height: size.height)
        }
    }

    /// The size of a header that may be decoded: sides and pixels within bounds, a bit depth that goes with its
    /// colour type, the one compression and filter method, and no interlace.
    private static func header(width: Int, height: Int, fields: Slice<UnsafeRawBufferPointer>) throws -> (width: Int, height: Int, imageData: Int) {
        let fields = Array(fields)  // bit depth, colour type, compression, filter, interlace
        guard width > 0, height > 0 else { throw Refusal.notPicture }
        guard withinBounds(width: width, height: height) else { throw Refusal.tooLarge }
        let depths: [UInt8: [UInt8]] = [0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]]
        guard depths[fields[1]]?.contains(fields[0]) == true, fields[2] == 0, fields[3] == 0 else { throw Refusal.notPicture }
        guard fields[4] != 1 else { throw Refusal.interlaced }
        guard fields[4] == 0 else { throw Refusal.notPicture }
        return (width, height, maxImageDataBytes(width: width, height: height, bitDepth: Int(fields[0]), colourType: Int(fields[1])))
    }

    /// The most image data (the IDAT chunks together) that a valid stream for a header needs: the rows, each of a
    /// filter byte and its pixels padded to a byte, as zlib stores them at worst (a two-byte header, five bytes for
    /// each 16 KiB block and a four-byte checksum), and 1 KiB of slack. A stream is read at up to 1,032 times its
    /// size, so what a 1 by 1 picture may carry is a kilobyte and not what the entry holds.
    static func maxImageDataBytes(width: Int, height: Int, bitDepth: Int, colourType: Int) -> Int {
        let channels = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][colourType] ?? 4
        let rows = height * (1 + (width * channels * bitDepth + 7) / 8)
        return 2 + 4 + rows + 5 * (rows / 16_384 + 1) + 1_024
    }

    /// The picture in `data` at no more than `thumbnailPixels` on a side. Walks the chunks and reads the header
    /// first (`rebuilt(from:)`), gives ImageIO only the rebuilt stream, checks that what it reports is the one
    /// PNG of the header's size, and decodes only a thumbnail.
    static func thumbnail(of data: Data) throws -> Thumbnail {
        try Task.checkCancellation()
        let plain = try rebuilt(from: data)
        try Task.checkCancellation()
        let options = [kCGImageSourceShouldCache: false, kCGImageSourceTypeIdentifierHint: "public.png"] as CFDictionary
        guard let source = CGImageSourceCreateWithData(plain.stream as CFData, options),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == plain.width, height == plain.height
        else { throw Refusal.notPicture }
        guard withinBounds(width: width, height: height) else { throw Refusal.tooLarge }
        try Task.checkCancellation()
        let make = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, make) else { throw Refusal.undecodable }
        try Task.checkCancellation()
        return Thumbnail(image: image, width: width, height: height)
    }
}

#endif
