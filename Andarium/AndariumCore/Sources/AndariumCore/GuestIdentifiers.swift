// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The values the application knows of this installation that tell it from
/// another, so that a text the guest printed (the start log) can have them
/// taken out wherever they stand, and not only where a rule knows the format
/// they come in. They are never stored or sent: they are read as the text is
/// made.
public struct GuestIdentifiers: Equatable, Sendable {
    /// The serial number the guest reads as `ro.serialno`.
    public var serial: String?
    /// The host's adb public key as the kernel's command line carries it,
    /// base64 without a comment.
    public var adbKey: String?
    /// The hardware addresses the guest has, as their six bytes.
    public var hardwareAddresses: [[UInt8]]
    /// The names of the time zone the guest was given: the one it booted with,
    /// and the one the host is in now.
    public var timeZones: [String]

    public static let none = GuestIdentifiers()

    public init(
        serial: String? = nil, adbKey: String? = nil, hardwareAddresses: [[UInt8]] = [], timeZones: [String] = []
    ) {
        self.serial = serial
        self.adbKey = adbKey
        self.hardwareAddresses = hardwareAddresses
        self.timeZones = timeZones
    }

    /// The most of the identity file that is read; the runtime's own limit
    /// (`darwin/device/block/README.md`).
    static let identityFileLimit = 4096

    /// The installation's serial number and eth0 address, from the file the
    /// runtime keeps beside the data disk (`InstanceFiles.identity`), with the
    /// key and the zones the application stated at the start. A file that is
    /// absent, too long, not an object or without a value adds nothing.
    public static func reading(identityFile: URL, adbKey: String?, timeZones: [String]) -> GuestIdentifiers {
        var identifiers = GuestIdentifiers(adbKey: adbKey, timeZones: timeZones)
        guard let data = BoundedFile.read(identityFile, limit: identityFileLimit), data.count <= identityFileLimit,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return identifiers }
        if let serial = object["serialno"] as? String, (4...32).contains(serial.utf8.count) {
            identifiers.serial = serial
        }
        if let address = (object["ethernet_mac"] as? String).flatMap(hardwareAddress(_:)) {
            identifiers.hardwareAddresses = [address]
        }
        return identifiers
    }

    /// The six bytes of `aa:bb:cc:dd:ee:ff` in either case; nil for any other text.
    public static func hardwareAddress(_ text: String) -> [UInt8]? {
        let octets = text.split(separator: ":", omittingEmptySubsequences: false)
        guard octets.count == 6 else { return nil }
        let bytes = octets.compactMap { $0.count == 2 ? UInt8($0, radix: 16) : nil }
        return bytes.count == 6 ? bytes : nil
    }
}
