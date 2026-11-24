import Foundation

/// Converte la chiave pubblica RSA nel formato richiesto da ADB (struct RSAPublicKey di Android, base64).
enum ADBKey {
    static func encode(modulus: [UInt8], exponent: UInt32 = 65537, name: String) -> [UInt8]? {
        let words = 64
        guard modulus.count == words * 4 else { return nil }

        // Modulo in parole a 32 bit little-endian
        var n = [UInt32](repeating: 0, count: words)
        for i in 0..<words {
            let base = modulus.count - 4 * (i + 1)
            n[i] = UInt32(modulus[base]) << 24 | UInt32(modulus[base + 1]) << 16
                | UInt32(modulus[base + 2]) << 8 | UInt32(modulus[base + 3])
        }

        // n0inv = -1 / n[0] mod 2^32 (Newton)
        var inverse = n[0]
        for _ in 0..<5 { inverse = inverse &* (2 &- n[0] &* inverse) }
        let n0inv = 0 &- inverse

        // rr = 2^(2·2048) mod n, per raddoppi successivi
        var r = [UInt32](repeating: 0, count: words + 1)
        r[0] = 1
        let nExt = n + [0]
        for _ in 0..<(words * 32 * 2) {
            var carry: UInt32 = 0
            for i in 0..<r.count {
                let next = r[i] >> 31
                r[i] = (r[i] << 1) | carry
                carry = next
            }
            if compare(r, nExt) >= 0 { subtract(&r, nExt) }
        }

        var out: [UInt8] = []
        func put(_ v: UInt32) {
            out += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
        }
        put(UInt32(words))
        put(n0inv)
        n.forEach(put)
        r.prefix(words).forEach(put)
        put(exponent)
        return Array((Data(out).base64EncodedString() + " \(name)\u{0}").utf8)
    }

    private static func compare(_ a: [UInt32], _ b: [UInt32]) -> Int {
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] {
            return a[i] > b[i] ? 1 : -1
        }
        return 0
    }

    private static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for i in 0..<a.count {
            let lhs = UInt64(a[i])
            let rhs = UInt64(b[i]) + borrow
            if lhs >= rhs {
                a[i] = UInt32(lhs - rhs)
                borrow = 0
            } else {
                a[i] = UInt32(lhs + (1 << 32) - rhs)
                borrow = 1
            }
        }
    }
}
