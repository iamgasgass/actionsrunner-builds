import Foundation

/// Scrittura Protocol Buffers minimale (solo varint e campi length-delimited).
struct ProtoWriter {
    private(set) var bytes: [UInt8] = []

    mutating func varint(_ field: Int, _ value: UInt64) {
        key(field, 0)
        Self.appendVarint(value, to: &bytes)
    }

    mutating func data(_ field: Int, _ value: [UInt8]) {
        key(field, 2)
        Self.appendVarint(UInt64(value.count), to: &bytes)
        bytes += value
    }

    mutating func string(_ field: Int, _ value: String) {
        data(field, Array(value.utf8))
    }

    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        build(&inner)
        data(field, inner.bytes)
    }

    private mutating func key(_ field: Int, _ wireType: UInt64) {
        Self.appendVarint(UInt64(field) << 3 | wireType, to: &bytes)
    }

    static func appendVarint(_ value: UInt64, to out: inout [UInt8]) {
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    /// Messaggio preceduto dalla sua lunghezza (varint), come sul socket delle Android TV.
    static func framed(_ message: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        appendVarint(UInt64(message.count), to: &out)
        return out + message
    }
}

/// Lettura Protocol Buffers minimale.
struct ProtoMessage {
    enum Value {
        case varint(UInt64)
        case bytes([UInt8])
    }

    private(set) var fields: [Int: [Value]] = [:]

    init?(_ bytes: [UInt8]) {
        var i = 0
        while i < bytes.count {
            guard let key = Self.readVarint(bytes, &i) else { return nil }
            let field = Int(key >> 3)
            switch key & 0x7 {
            case 0:
                guard let v = Self.readVarint(bytes, &i) else { return nil }
                fields[field, default: []].append(.varint(v))
            case 1:
                guard i + 8 <= bytes.count else { return nil }
                i += 8
            case 2:
                guard let len = Self.readVarint(bytes, &i), i + Int(len) <= bytes.count else { return nil }
                fields[field, default: []].append(.bytes(Array(bytes[i..<(i + Int(len))])))
                i += Int(len)
            case 5:
                guard i + 4 <= bytes.count else { return nil }
                i += 4
            default:
                return nil
            }
        }
    }

    func has(_ field: Int) -> Bool { fields[field] != nil }

    func varint(_ field: Int) -> UInt64? {
        for value in fields[field] ?? [] {
            if case .varint(let v) = value { return v }
        }
        return nil
    }

    func bytes(_ field: Int) -> [UInt8]? {
        for value in fields[field] ?? [] {
            if case .bytes(let b) = value { return b }
        }
        return nil
    }

    func message(_ field: Int) -> ProtoMessage? {
        bytes(field).flatMap { ProtoMessage($0) }
    }

    static func readVarint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count && shift < 64 {
            let b = bytes[index]
            index += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    /// Estrae dal buffer tutti i messaggi completi preceduti da lunghezza varint.
    static func drainFrames(_ buffer: inout [UInt8]) -> [[UInt8]] {
        var frames: [[UInt8]] = []
        while true {
            var i = 0
            guard let len = readVarint(buffer, &i), i + Int(len) <= buffer.count else { break }
            frames.append(Array(buffer[i..<(i + Int(len))]))
            buffer.removeFirst(i + Int(len))
        }
        return frames
    }
}
