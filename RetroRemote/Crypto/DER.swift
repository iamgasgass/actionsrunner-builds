import Foundation

/// Codifica/decodifica ASN.1 DER minimale (certificato client X.509 e chiavi RSA).
enum DER {
    static let oidSHA256WithRSA: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
    static let oidRSAEncryption: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    static let oidCommonName: [UInt8] = [0x06, 0x03, 0x55, 0x04, 0x03]
    static let null: [UInt8] = [0x05, 0x00]

    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var value = n
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + length(content.count) + content
    }

    static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    static func set(_ items: [[UInt8]]) -> [UInt8] { tlv(0x31, items.flatMap { $0 }) }
    static func explicit(_ number: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0xA0 | number, content) }
    static func utf8(_ string: String) -> [UInt8] { tlv(0x0C, Array(string.utf8)) }
    static func bitString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x03, [0x00] + bytes) }

    static func integer(_ bytes: [UInt8]) -> [UInt8] {
        var b = stripLeadingZeros(bytes)
        if b.isEmpty { b = [0] }
        if b[0] & 0x80 != 0 { b.insert(0, at: 0) }
        return tlv(0x02, b)
    }

    static func utcTime(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Array(formatter.string(from: date).utf8))
    }

    static func stripLeadingZeros(_ bytes: [UInt8]) -> [UInt8] {
        var b = bytes
        while b.count > 1 && b[0] == 0 { b.removeFirst() }
        return b
    }

    /// Legge un elemento TLV a partire da `index`, che viene fatto avanzare.
    static func read(_ bytes: [UInt8], _ index: inout Int) -> (tag: UInt8, content: [UInt8])? {
        guard index + 2 <= bytes.count else { return nil }
        let tag = bytes[index]
        index += 1
        var len = Int(bytes[index])
        index += 1
        if len & 0x80 != 0 {
            let count = len & 0x7F
            guard count > 0, count <= 4, index + count <= bytes.count else { return nil }
            len = 0
            for _ in 0..<count {
                len = (len << 8) | Int(bytes[index])
                index += 1
            }
        }
        guard len >= 0, index + len <= bytes.count else { return nil }
        let content = Array(bytes[index..<(index + len)])
        index += len
        return (tag, content)
    }

    /// Modulo ed esponente (big-endian, senza zeri iniziali) da una chiave pubblica RSA PKCS#1.
    static func rsaComponents(_ pkcs1: Data) -> (modulus: [UInt8], exponent: [UInt8])? {
        let bytes = [UInt8](pkcs1)
        var i = 0
        guard let outer = read(bytes, &i), outer.tag == 0x30 else { return nil }
        var j = 0
        guard let n = read(outer.content, &j), n.tag == 0x02,
              let e = read(outer.content, &j), e.tag == 0x02 else { return nil }
        return (stripLeadingZeros(n.content), stripLeadingZeros(e.content))
    }
}
