// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import AndariumCore
import Foundation

/// The rules of `SendFeedbackStartLog.masked` that do not go by a name: the
/// values the application knows, and the shapes of identifiers (an IPv6
/// address, a UUID) that a line of the guest's output may carry whatever
/// names it.
nonisolated extension SendFeedbackStartLog {
    private static func escaped(_ text: String) -> String { NSRegularExpression.escapedPattern(for: text) }

    // MARK: By value

    /// `text` without `identifiers`: the adb key (at least eight characters)
    /// and the serial number where they stand as a whole word, a time zone's
    /// name (one with a `/`: `UTC` is too short a word to take out of a text),
    /// and the hardware addresses in their three spellings, in either case.
    static func maskedKnownValues(_ text: String, _ identifiers: GuestIdentifiers) -> String {
        var result = text
        if let key = identifiers.adbKey, key.utf8.count >= 8 {
            result = result.replacingOccurrences(of: key, with: "<masked>")
        }
        if let serial = identifiers.serial, serial.utf8.count >= 4 {
            result = result.replacingOccurrences(
                of: "(?<![A-Za-z0-9])\(escaped(serial))(?![A-Za-z0-9])", with: "<masked>", options: .regularExpression)
        }
        for zone in identifiers.timeZones where zone.contains("/") {
            result = result.replacingOccurrences(
                of: "(?<![A-Za-z0-9_/+-])\(escaped(zone))(?![A-Za-z0-9_/+-])", with: "<time zone>",
                options: .regularExpression)
        }
        for address in identifiers.hardwareAddresses where address.count == 6 {
            let octets = address.map { String(format: "%02x", $0) }
            for separator in [":", "-", ""] {
                result = result.replacingOccurrences(
                    of: "(?<![0-9A-Fa-f])\(octets.joined(separator: separator))(?![0-9A-Fa-f])", with: "<address>",
                    options: [.regularExpression, .caseInsensitive])
            }
        }
        return result
    }

    /// The interface identifier an IPv6 address takes from a hardware address
    /// (modified EUI-64: the universal/local bit flipped and `ff:fe` between
    /// the halves) in any spelling of its hextets (leading zeros or none, either
    /// case): `maskedIPv6` has taken the whole address, and this takes what
    /// stands without its prefix.
    static func maskedInterfaceIdentifiers(_ text: String, _ identifiers: GuestIdentifiers) -> String {
        var result = text
        for address in identifiers.hardwareAddresses where address.count == 6 {
            let identifier = [address[0] ^ 0x02, address[1], address[2], 0xFF, 0xFE, address[3], address[4], address[5]]
            let hextets = stride(from: 0, to: 8, by: 2).map { index -> String in
                let value = Int(identifier[index]) << 8 | Int(identifier[index + 1])
                return "0{0,3}" + String(value, radix: 16)
            }
            result = result.replacingOccurrences(
                of: "(?<![0-9A-Fa-f:])\(hextets.joined(separator: ":"))(?![0-9A-Fa-f])", with: "<address>",
                options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    // MARK: By shape

    /// Every UUID, in either case: a filesystem's (mke2fs and the kernel print
    /// it when a disk is made and mounted) and a container's.
    static func maskedUUIDs(_ text: String) -> String {
        text.replacingOccurrences(
            of: "(?<![0-9A-Za-z])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}(?![0-9A-Za-z])",
            with: "<uuid>", options: .regularExpression)
    }

    /// Every IPv6 address as `<ipv6>`, in any spelling of it: eight groups,
    /// compressed with `::`, with leading zeros or without, either case, with
    /// an IPv4 address as its last two groups, and with a `%zone` that the
    /// text keeps. A link-local address that the guest derives from its hardware
    /// address names the installation. The loopback address and the
    /// unspecified one name nothing and stay.
    ///
    /// A candidate is a run of hexadecimal digits, `:` and `.` that stands
    /// apart from the words around it (a letter, a digit or `_` on either side
    /// is not a boundary: `std::add` is not an address) and is a whole address
    /// by the grammar: eight groups, or at most seven with one `::`. Times of
    /// day (`05:04:50`), hardware addresses (six groups), kernel timestamps,
    /// IPv4 addresses with or without a port and ordinary hexadecimal numbers
    /// are none. Punctuation that ends a sentence after an address is not part
    /// of it.
    static func maskedIPv6(_ text: String) -> String {
        guard text.contains(":") else { return text }
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard isCandidateScalar(scalars[index]) else {
                output.append(scalars[index])
                index += 1
                continue
            }
            var end = index
            while end < scalars.count, isCandidateScalar(scalars[end]) { end += 1 }
            var start = index
            // A single colon that opens the run is the text's own (`address:fe80::1`).
            if scalars[start] == ":", start + 1 >= end || scalars[start + 1] != ":" {
                output.append(scalars[start])
                start += 1
            }
            let apart = start == 0 || !isWordScalar(scalars[start - 1])
            var stop = end
            while apart, stop > start {
                let after = stop == end ? (end < scalars.count ? scalars[end] : nil) : scalars[stop]
                if after.map({ !isWordScalar($0) }) ?? true,
                    let bytes = ipv6Bytes(scalars[start..<stop]) {
                    if isLoopbackOrUnspecified(bytes) {
                        stop = start
                    }
                    break
                }
                // The colon or dot of the text's own punctuation that follows an address.
                guard scalars[stop - 1] == ":" || scalars[stop - 1] == "." else {
                    stop = start
                    break
                }
                stop -= 1
            }
            if apart, stop > start {
                output.append(contentsOf: "<ipv6>".unicodeScalars)
                output.append(contentsOf: scalars[stop..<end])
            } else {
                output.append(contentsOf: scalars[start..<end])
            }
            index = end
        }
        return String(output)
    }

    private static func isCandidateScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == ":" || scalar == "." || isHexScalar(scalar)
    }

    private static func isHexScalar(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "0" && scalar <= "9") || (scalar >= "a" && scalar <= "f") || (scalar >= "A" && scalar <= "F")
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        isHexScalar(scalar) || (scalar >= "g" && scalar <= "z") || (scalar >= "G" && scalar <= "Z") || scalar == "_"
    }

    private static func isLoopbackOrUnspecified(_ bytes: [UInt8]) -> Bool {
        bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last.map { $0 <= 1 } == true
    }

    /// The 16 bytes of `text` when it is an IPv6 address (RFC 4291: eight
    /// groups of one to four hexadecimal digits, one run of zero groups
    /// written `::`, and an IPv4 address in decimal for the last two groups).
    private static func ipv6Bytes(_ scalars: ArraySlice<Unicode.Scalar>) -> [UInt8]? {
        let text = String(String.UnicodeScalarView(scalars))
        guard text.contains(":"), !text.contains(":::") else { return nil }
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ half: String, last: Bool) -> [UInt16]? {
            guard !half.isEmpty else { return [] }
            let words = half.split(separator: ":", omittingEmptySubsequences: false)
            var values: [UInt16] = []
            for (position, word) in words.enumerated() {
                if word.contains("."), last, position == words.count - 1 {
                    let octets = word.split(separator: ".", omittingEmptySubsequences: false)
                    guard octets.count == 4 else { return nil }
                    let numbers = octets.compactMap { $0.count <= 3 ? UInt16($0, radix: 10) : nil }
                    guard numbers.count == 4, numbers.allSatisfy({ $0 <= 255 }) else { return nil }
                    values += [numbers[0] << 8 | numbers[1], numbers[2] << 8 | numbers[3]]
                } else {
                    guard (1...4).contains(word.count), let value = UInt16(word, radix: 16) else { return nil }
                    values.append(value)
                }
            }
            return values
        }
        guard let head = groups(halves[0], last: halves.count == 1) else { return nil }
        var all = head
        if halves.count == 2 {
            guard let tail = groups(halves[1], last: true), head.count + tail.count <= 7 else { return nil }
            all += [UInt16](repeating: 0, count: 8 - head.count - tail.count) + tail
        }
        guard all.count == 8 else { return nil }
        return all.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }
}

#endif
