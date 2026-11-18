// SPDX-License-Identifier: GPL-2.0-or-later

import CoreGraphics
import Foundation
import ImageIO
import zlib

/// A PNG taken apart and put together again: its chunks, each with its CRC made again on the way out, so that a
/// test can add, remove or change a chunk and still have a file whose chunks are well formed.
struct PNGParts {
    struct Chunk {
        var type: String
        var data: Data

        init(_ type: String, _ data: Data = Data()) {
            self.type = type
            self.data = data
        }
    }

    static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    var chunks: [Chunk]

    init(chunks: [Chunk]) { self.chunks = chunks }

    /// The chunks of `png`, which is taken to be well formed.
    init(_ png: Data) {
        var chunks: [Chunk] = []
        var offset = 8
        while offset + 12 <= png.count {
            let length = png[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            let type = String(decoding: png[offset + 4..<offset + 8], as: UTF8.self)
            chunks.append(Chunk(type, Data(png[offset + 8..<offset + 8 + length])))
            offset += 12 + length
        }
        self.chunks = chunks
    }

    func data() -> Data {
        var out = Self.signature
        for chunk in chunks { out.append(Self.encode(chunk)) }
        return out
    }

    /// The width, height and interlace method of the header, written over what it said.
    mutating func setHeader(width: UInt32? = nil, height: UInt32? = nil, interlace: UInt8? = nil) {
        guard let index = chunks.firstIndex(where: { $0.type == "IHDR" }) else { return }
        if let width { chunks[index].data.replaceSubrange(0..<4, with: Self.bigEndian(width)) }
        if let height { chunks[index].data.replaceSubrange(4..<8, with: Self.bigEndian(height)) }
        if let interlace { chunks[index].data[12] = interlace }
    }

    static func bigEndian(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8((value >> UInt32(24 - 8 * $0)) & 0xFF) })
    }

    static func encode(_ chunk: Chunk) -> Data {
        var out = bigEndian(UInt32(chunk.data.count))
        let body = Data(chunk.type.utf8) + chunk.data
        out.append(body)
        var bytes = [UInt8](body)
        out.append(bigEndian(UInt32(truncatingIfNeeded: zlib.crc32(0, &bytes, UInt32(bytes.count)))))
        return out
    }

    /// `payload` as the zlib stream that the compressed chunks of a PNG hold (header, deflate, Adler-32).
    static func zlibStream(of payload: Data) -> Data {
        var bytes = [UInt8](payload)
        let adler = UInt32(truncatingIfNeeded: zlib.adler32(1, &bytes, UInt32(bytes.count)))
        return Data([0x78, 0x9C]) + ZipFixture.deflate(payload) + bigEndian(adler)
    }

    /// A zlib stream that holds `count` letters once it is inflated. Letters, because ImageIO takes the text of a
    /// chunk for a string and only a string that it can make is made at all.
    static func letters(_ count: Int) -> Data { zlibStream(of: Data(repeating: 0x41, count: count)) }

    /// `raw` as a zlib stream of stored blocks of `block` bytes (five bytes of header for each): the largest a valid
    /// stream of that much may be, and what an encoder that cannot make it smaller writes.
    static func stored(_ raw: Data, block: Int = 16_384) -> Data {
        var out = Data([0x78, 0x01])
        var offset = 0
        repeat {
            let count = min(block, raw.count - offset)
            let last = offset + count >= raw.count
            out.append(contentsOf: [last ? 1 : 0, UInt8(count & 0xFF), UInt8(count >> 8), UInt8(~count & 0xFF), UInt8((~count >> 8) & 0xFF)])
            out.append(raw[offset..<offset + count])
            offset += count
        } while offset < raw.count
        var bytes = [UInt8](raw)
        out.append(bigEndian(UInt32(truncatingIfNeeded: zlib.adler32(1, &bytes, UInt32(bytes.count)))))
        return out
    }

    /// The header of a picture: `width` by `height`, `depth` bits, `colour` type, not interlaced.
    static func header(width: UInt32, height: UInt32, depth: UInt8 = 8, colour: UInt8 = 2) -> Chunk {
        Chunk("IHDR", bigEndian(width) + bigEndian(height) + Data([depth, colour, 0, 0, 0]))
    }

    /// A compressed text chunk (`zTXt`, `iTXt`) or profile (`iCCP`) that holds `expanded` letters once
    /// it is inflated, in about two kilobytes per two megabytes.
    static func compressed(_ type: String, expanding expanded: Int, packed: Data? = nil) -> Chunk {
        let stream = packed ?? letters(expanded)
        switch type {
        case "iTXt": return Chunk(type, Data("Description".utf8) + Data([0, 1, 0, 0, 0]) + stream)
        default: return Chunk(type, Data("Description".utf8) + Data([0, 0]) + stream)
        }
    }

    /// A real picture, written by ImageIO: a teal ground with a yellow block.
    static func real(width: Int = 64, height: Int = 48) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.1, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.9, green: 0.8, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
