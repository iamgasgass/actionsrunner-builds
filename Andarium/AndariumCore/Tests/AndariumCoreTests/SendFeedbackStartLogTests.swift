// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing

@testable import AndariumCore
@testable import AndariumFeedbackLogic

/// The start log a Send feedback sheet attaches by itself when it is opened
/// during a start, and the sheet's rules for it: what the text says, what is
/// taken out of it, and the tip and the closing question while it is there.
struct SendFeedbackStartLogTests {
    /// A key as the Android adb keeps it: base64, with `+`, `/` and `=`.
    private let key = "QAAAAGJ4Z0n2Hq+Lx0aT/m8nR4sJ0d5bYwV9cE7uKf3PzQ1yM6hS2oXkUa8tNvB5rLq=="

    private func log(output: String?, restarts: Int = 0, containers: [String] = []) -> String {
        SendFeedbackStartLog.text(
            step: "Startup", seconds: 197, kind: .normal, restarts: restarts, output: output, containers: containers)
    }

    // MARK: The text

    @Test func theLogNamesTheStepTheTimeAndTheKindOfStart() {
        let text = log(output: "[   41.2] init: starting service 'netd'...\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.starts(with: ["Start log", "Step: Startup", "Time: 3:17", "Start: ordinary start", ""]))
        #expect(lines.contains("[   41.2] init: starting service 'netd'..."))
        #expect(text.hasSuffix("\n") && !text.hasSuffix("\n\n"))
        #expect(!lines.contains { $0.hasPrefix("Restarts") })
        // The clock is the elapsed time, in ASCII digits whatever the device's numbering system.
        #expect(lines[2].range(of: #"^Time: [0-9]+:[0-9]{2}$"#, options: .regularExpression) != nil)
    }

    @Test func everyKindOfStartHasItsOwnWords() {
        let names = [BootKind.normal, .firstStart, .upgrade, .recovery, .restart].map(SendFeedbackStartLog.kindName)
        #expect(names == ["ordinary start", "first start", "first start after an update", "Recovery start", "restart"])
    }

    @Test func aStartThatRestartedSaysSo() {
        #expect(log(output: nil, restarts: 2).contains("Restarts in this start: 2\n"))
    }

    @Test func withoutOutputTheLogSaysNothingWasPrintedYet() {
        #expect(log(output: nil).hasSuffix("\n(nothing yet)\n"))
        #expect(log(output: "").hasSuffix("\n(nothing yet)\n"))
        #expect(log(output: "\n\n").hasSuffix("\n(nothing yet)\n"))
    }

    @Test func theOutputIsAtMostTheLastFourKiBFromAWholeLine() {
        let lines = (0..<600).map { "[\(String(format: "%7.1f", Double($0)))] line number \($0)" }
        let output = lines.joined(separator: "\n") + "\n"
        #expect(output.utf8.count > SendFeedbackStartLog.outputLimit)
        let limited = SendFeedbackStartLog.limited(output)
        #expect(limited.utf8.count <= SendFeedbackStartLog.outputLimit)
        #expect(output.hasSuffix(limited), "the end is what is kept")
        #expect(limited.hasPrefix("["), "the cut falls at a line, never inside one")
        #expect(limited.hasSuffix("line number 599\n"))
        // What fits is not touched.
        #expect(SendFeedbackStartLog.limited("[0.1] a\n[0.2] b\n") == "[0.1] a\n[0.2] b\n")
    }

    // MARK: The name

    /// 2026-11-08 05:04:50 UTC.
    private let moment = Date(timeIntervalSince1970: 1_794_114_290)
    private let namePattern = #"^start-log-[0-9]{8}-[0-9]{6}\.txt$"#

    /// The mail names the log by the moment it was made, as every file the app
    /// makes (`SendFeedbackNames.stamp`), in the device's clock.
    @Test func theNameIsTheMomentTheLogWasMadeInTheDevicesClock() throws {
        func name(_ date: Date) -> String? { SendFeedbackAttachment.Kind.startLog.generatedFileName(at: date) }
        // The stamp's own zones, written out here independently of the code.
        for (identifier, expected) in [
            ("UTC", "20261108-050450"), ("Asia/Tokyo", "20261108-140450"), ("America/Los_Angeles", "20261107-210450"),
        ] {
            let zone = try #require(TimeZone(identifier: identifier))
            #expect(SendFeedbackNames.stamp(moment, in: zone) == expected, "\(identifier)")
        }
        // The year's end and a day of single digits: every field is padded to its width.
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(SendFeedbackNames.stamp(Date(timeIntervalSince1970: 1_798_761_599), in: utc) == "20261231-235959")
        #expect(SendFeedbackNames.stamp(Date(timeIntervalSince1970: 1_798_761_600), in: utc) == "20270101-000000")
        #expect(SendFeedbackNames.stamp(Date(timeIntervalSince1970: 1_804_136_767), in: utc) == "20270304-050607")
        // The log's name is that stamp in the device's clock, with no zone text.
        #expect(name(moment) == "start-log-\(SendFeedbackNames.stamp(moment)).txt")
        #expect(name(moment)?.range(of: namePattern, options: .regularExpression) != nil)
        // The mail's name is that, and not the name the file has where it is staged.
        let attachment = SendFeedbackAttachment(
            kind: .startLog, url: URL(fileURLWithPath: "/staged/start-log.txt"), bytes: 1, madeAt: moment)
        #expect(attachment.fileName == name(moment) && attachment.mimeType == "text/plain")
    }

    /// The stamp names its locale, calendar and digits, so the interface
    /// language and the numbering and calendar a person chose do not reach the
    /// name. The control is the same pattern from a formatter that follows such a
    /// setting: it writes another year and other digits, and the name does not.
    @Test func theNameDoesNotFollowTheLanguageTheCalendarOrTheDigits() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let name = "start-log-\(SendFeedbackNames.stamp(moment, in: utc)).txt"
        let settings: [(String, differs: Bool)] = [
            ("en", false), ("zh-Hans", false), ("zh-Hant", false), ("ja", false),
            ("th_TH@calendar=buddhist", true), ("ar@numbers=arab", true),
            ("ar_SA@calendar=islamic-umalqura;numbers=arab", true), ("fa_IR@calendar=persian;numbers=arabext", true),
            ("hi_IN@numbers=deva", true), ("ja_JP@calendar=japanese", true),
        ]
        for (identifier, differs) in settings {
            let following = DateFormatter()
            following.locale = Locale(identifier: identifier)
            following.timeZone = utc
            following.dateFormat = "yyyyMMdd-HHmmss"
            #expect((following.string(from: moment) != "20261108-050450") == differs, "\(identifier)")
            #expect(name == "start-log-20261108-050450.txt", "\(identifier)")
            #expect(name.range(of: namePattern, options: .regularExpression) != nil, "\(identifier)")
        }
    }

    // MARK: What is taken out

    @Test func theKeyOfEveryAssignmentIsMasked() {
        let line = "[    0.000000] Kernel command line: console=ttyS0 androidboot.kernarium.adb_key=\(key) androidboot.kernarium.adb_tcp=1"
        let masked = SendFeedbackStartLog.masked(line + "\n" + line)
        #expect(!masked.contains(key) && !masked.contains("QAAAAGJ4Z0n2Hq"))
        #expect(masked.components(separatedBy: "androidboot.kernarium.adb_key=<masked>").count == 3)
        #expect(masked.contains("androidboot.kernarium.adb_tcp=1"), "what is not identifying stays")
        // The same property, as init prints it.
        let property = SendFeedbackStartLog.masked("[ro.boot.kernarium.adb_key]: [\(key)]")
        #expect(property == "[ro.boot.kernarium.adb_key]: [<masked>]")
        // And in the finished text.
        #expect(!log(output: line).contains(key))
    }

    /// The kernel's early line is cut by the ring from its start: the text may
    /// begin anywhere in the argument that carries the key, even in its value.
    @Test func aLineCutAtTheStartOfTheTextIsMaskedWhereverItWasCut() {
        let argument = "androidboot.kernarium.adb_key=\(key)"
        let rest = " androidboot.kernarium.adb_tcp=1 quiet\n[    1.0] next line"
        for cut in 0...argument.count {
            let fragment = String(argument.dropFirst(cut)) + rest
            let masked = SendFeedbackStartLog.masked(fragment)
            // No eight characters of the key survive, wherever the text begins.
            for start in 0...(key.count - 8) {
                let piece = String(key.dropFirst(start).prefix(8))
                #expect(!masked.contains(piece), "cut at \(cut) kept \(piece): \(masked)")
            }
            #expect(masked.hasSuffix(rest), "the lines after the cut one are the log's own (cut at \(cut))")
        }
    }

    @Test func theTimeZoneOfEveryAssignmentIsMasked() {
        let line = "[    0.0] Kernel command line: androidboot.kernarium.timezone=Asia/Tokyo androidboot.kernarium.adb_tcp=1 androidboot.lcd_density=420"
        let masked = SendFeedbackStartLog.masked(line + "\n" + line)
        #expect(!masked.contains("Tokyo") && !masked.contains("Asia"))
        #expect(masked.components(separatedBy: "androidboot.kernarium.timezone=<time zone>").count == 3)
        #expect(masked.contains("androidboot.kernarium.adb_tcp=1") && masked.contains("androidboot.lcd_density=420"),
            "the port and the density stay")
        // The same property, as init prints it.
        #expect(SendFeedbackStartLog.masked("[persist.sys.timezone]: [America/Los_Angeles]")
            == "[persist.sys.timezone]: [<time zone>]")
        #expect(!log(output: line).contains("Tokyo"))
    }

    /// Like the key's: the text may begin anywhere in the argument, even in its
    /// value, where the line goes on with other arguments.
    @Test func aLineCutInsideTheTimeZoneArgumentIsMaskedWhereverItWasCut() {
        for zone in ["Asia/Tokyo", "America/Argentina/Buenos_Aires", "Etc/GMT+9"] {
            let argument = "androidboot.kernarium.timezone=\(zone)"
            let rest = " androidboot.kernarium.adb_tcp=1 quiet\n[    1.0] next line"
            for cut in 0...argument.count {
                let masked = SendFeedbackStartLog.masked(String(argument.dropFirst(cut)) + rest)
                // No four characters of the zone survive, wherever the text begins.
                for start in 0...(zone.count - 4) {
                    let piece = String(zone.dropFirst(start).prefix(4))
                    #expect(!masked.contains(piece), "\(zone) cut at \(cut) kept \(piece): \(masked)")
                }
                #expect(masked.hasSuffix(rest), "\(zone) cut at \(cut)")
            }
        }
    }

    @Test func aWholeLineIsNotMistakenForACutOne() {
        let ordinary = "starting service 'netd'...\n[  102.9] init: Service 'vold' (pid 312) exited with status 0"
        #expect(SendFeedbackStartLog.masked(ordinary) == ordinary)
        let timestamp = "[  102.9] init: starting service 'zygote'...\n"
        #expect(SendFeedbackStartLog.masked(timestamp) == timestamp)
        #expect(SendFeedbackStartLog.masked("pid=312 status=0") == "pid=312 status=0")
    }

    @Test func theSerialNumberTheAddressAndThePathsAreMasked() {
        let containers = ["/private/var/mobile/Containers/Data/Application/1B2C3D4E-0000-4A5B-8C9D-0123456789AB"]
        let output = """
            [    0.0] Kernel command line: androidboot.serialno=K7QX2M9T4R \
            --session-record=/var/mobile/Containers/Data/Application/1B2C3D4E-0000-4A5B-8C9D-0123456789AB/Library/x
            [    5.1] eth0: link up, address aa:bb:cc:dd:ee:ff and 0A:1B:2C:3D:4E:5F
            [    5.2] opened /Users/NAME/Library/Containers/x
            [    5.3] [ro.boot.serialno]: [K7QX2M9T4R]
            """
        let masked = SendFeedbackStartLog.masked(output, containers: containers)
        #expect(!masked.contains("K7QX2M9T4R"))
        #expect(masked.contains("androidboot.serialno=<masked>") && masked.contains("[ro.boot.serialno]: [<masked>]"))
        #expect(!masked.localizedCaseInsensitiveContains("aa:bb:cc") && !masked.contains("0A:1B:2C"))
        #expect(masked.contains("<address>"))
        #expect(!masked.contains("1B2C3D4E") && masked.contains("<container>"))
        #expect(!masked.contains("/Users/NAME") && masked.contains("/Users/<user>"))
    }

    // MARK: Identifiers of any format

    /// Synthetic values, as the reviewer's producers print them.
    private let serial = "a1b2c3d4e5f60718"
    private let mac = "02:1a:2b:3c:4d:5e"
    private let uuid = "12345678-1234-4abc-8def-123456789abc"
    private let zone = "America/Argentina/Buenos_Aires"

    private var identifiers: GuestIdentifiers {
        GuestIdentifiers(
            serial: serial, adbKey: key, hardwareAddresses: [GuestIdentifiers.hardwareAddress(mac)!],
            timeZones: [zone])
    }

    /// The lines the guest's own software prints: what the value stood in is
    /// gone, and the words around it remain.
    @Test func theProducersOfTheGuestsIdentifiersAreMasked() {
        let producers: [(line: String, value: String, kept: [String])] = [
            (
                "[1.0] init: Init cannot set 'ro.boot.kernarium.adb_key' to '\(key)': __system_property_add failed", key,
                ["init: Init cannot set 'ro.boot.kernarium.adb_key' to '", "': __system_property_add failed"]
            ),
            (
                "[1.0] init: Init cannot set 'ro.serialno' to '\(serial)': __system_property_add failed", serial,
                ["init: Init cannot set 'ro.serialno' to '", "': __system_property_add failed"]
            ),
            (
                "[1.0] eth0: IPv6 duplicate address fe80::1a:2bff:fe3c:4d5e used by \(mac) detected!",
                "fe80::1a:2bff:fe3c:4d5e", ["eth0: IPv6 duplicate address <ipv6> used by <address> detected!"]
            ),
            ("[1.0] mke2fs: Filesystem UUID: \(uuid)", uuid, ["mke2fs: Filesystem UUID: <uuid>"]),
            (
                "[ 2.0] EXT4-fs (ubdb1): mounted filesystem \(uuid) r/w with ordered data mode. Quota mode: none.", uuid,
                ["EXT4-fs (ubdb1): mounted filesystem <uuid> r/w with ordered data mode. Quota mode: none."]
            ),
        ]
        for producer in producers {
            // By the shape alone, and with the values known as well.
            for known in [GuestIdentifiers.none, identifiers] {
                let masked = SendFeedbackStartLog.masked(producer.line, identifiers: known)
                #expect(!masked.contains(producer.value), "\(producer.line) -> \(masked)")
                for part in producer.kept { #expect(masked.contains(part), "\(part) in \(masked)") }
                #expect(masked.hasPrefix(String(producer.line.prefix(6))))
            }
        }
        // And in the finished text.
        let text = log(output: producers.map(\.line).joined(separator: "\n") + "\n")
        for producer in producers { #expect(!text.contains(producer.value)) }
    }

    @Test func initsQuotedPropertyErrorLosesItsValueWhateverThePropertyIs() {
        let line = "[ 3.0] init: Init cannot set 'persist.sys.timezone' to 'Asia/Tokyo': permission denied"
        #expect(SendFeedbackStartLog.masked(line)
            == "[ 3.0] init: Init cannot set 'persist.sys.timezone' to '<masked>': permission denied")
        // A line that is not that message is its own.
        let other = "[ 3.0] init: cannot set 'x' to 'y'"
        #expect(SendFeedbackStartLog.masked(other) == other)
    }

    @Test func everySpellingOfAnIPv6AddressIsMasked() {
        let addresses = [
            "fe80::1a:2bff:fe3c:4d5e", "FE80::1A:2BFF:FE3C:4D5E", "fe80:0:0:0:1a:2bff:fe3c:4d5e",
            "FE80:0000:0000:0000:001A:2BFF:FE3C:4D5E", "fe80:0000:0000:0000:001a:2bff:fe3c:4d5e",
            "2001:db8::8a2e:370:7334", "2001:0DB8:0000:0000:0000:8A2E:0370:7334", "2001:db8::", "::ffff:10.0.2.15",
            "::ffff:0a00:020f", "2001:db8:1234:5678:9abc:def0:1234:5678", "1::2", "fe80::1%eth0",
        ]
        for address in addresses {
            let bare = address.components(separatedBy: "%")[0]
            for (template, expected) in [
                ("[ 2.0] eth0: address %@ done", "[ 2.0] eth0: address <ipv6> done"),
                ("[ 2.0] eth0: address %@.", "[ 2.0] eth0: address <ipv6>."),
                ("[ 2.0] eth0: address %@: bad", "[ 2.0] eth0: address <ipv6>: bad"),
                ("[ 2.0] inet6 %@/64 scope link", "[ 2.0] inet6 <ipv6>/64 scope link"),
                ("[ 2.0] listening on [%@]:5555", "[ 2.0] listening on [<ipv6>]:5555"),
                ("[ 2.0] %@", "[ 2.0] <ipv6>"),
            ] {
                let input = template.replacingOccurrences(of: "%@", with: bare)
                let masked = SendFeedbackStartLog.masked(input)
                #expect(masked == expected.replacingOccurrences(of: "%@", with: bare), "\(input) -> \(masked)")
            }
        }
        // A colon that opens a run of its own is the text's: `addr:fe80::1` is an address after a label.
        #expect(SendFeedbackStartLog.masked("[ 2.0] addr:fe80::1a:2bff:fe3c:4d5e/64") == "[ 2.0] addr:<ipv6>/64")
        // A zone stays: it names an interface, not an installation.
        #expect(SendFeedbackStartLog.masked("[ 2.0] fe80::1a:2bff:fe3c:4d5e%eth0 up") == "[ 2.0] <ipv6>%eth0 up")
    }

    @Test func whatIsNotAnIPv6AddressStays() {
        let ordinary = [
            "[    5.123456] eth0: link up", "[ 5.1] time 05:04:50 and 5:04:50.123", "2026-11-08T05:04:50Z",
            "[ 5.1] eth0: 10.0.2.15 gateway 10.0.2.2 dns 10.0.2.3", "adb connect 10.0.2.15:5555",
            "[ 5.1] loopback ::1 and unspecified ::", "[ 5.1] 0:0:0:0:0:0:0:1", "[ 5.1] mask 0xdeadbeef ffff0000 cafe",
            "[ 5.1] major:minor 8:16 and 259:3", "[ 5.1] std::string and android::hardware::Foo",
            "[ 5.1] android.hardware.foo@1.0::IFoo/default", "[ 5.1] ip=::::eth0:dhcp", "[ 5.1] 1:2:3:4:5:6:7:8:9",
            "[ 5.1] status=1 pid:312 uid:1000:2000", "[ 5.1] Filesystem 12345678-1234-1234 a1b2c3d4e5f60718",
        ]
        for line in ordinary {
            // `1:2:3:4:5:6:7:8:9` has nine groups: not an address.
            #expect(SendFeedbackStartLog.masked(line) == line, "\(line)")
        }
        // A hardware address is the existing rule's, not an IPv6 address.
        #expect(SendFeedbackStartLog.masked("[ 5.1] link/ether aa:bb:cc:dd:ee:ff brd ff:ff:ff:ff:ff:ff")
            == "[ 5.1] link/ether <address> brd <address>")
    }

    @Test func everyUUIDIsMaskedInEitherCase() {
        for value in [uuid, uuid.uppercased(), "00000000-0000-0000-0000-000000000000"] {
            for template in ["UUID=%@ rw", "(%@)", "Filesystem UUID: %@", "x_%@_y".replacingOccurrences(of: "_", with: "/")] {
                let masked = SendFeedbackStartLog.masked(template.replacingOccurrences(of: "%@", with: value))
                #expect(masked.contains("<uuid>") && !masked.contains(value.prefix(8)), "\(template) -> \(masked)")
            }
        }
        // A container's path goes whole, as before, and what is not a UUID stays.
        let container = "/private/var/mobile/Containers/Data/Application/\(uuid.uppercased())"
        let masked = SendFeedbackStartLog.masked("opened \(container)/Library/x", containers: [container])
        #expect(masked == "opened <container>/Library/x")
        #expect(SendFeedbackStartLog.masked("12345678-1234-4abc-8def-12345678 123456789-1234-4abc-8def-123456789abc")
            == "12345678-1234-4abc-8def-12345678 123456789-1234-4abc-8def-123456789abc")
    }

    @Test func theValuesTheApplicationKnowsAreMaskedWhereverTheyStand() {
        let output = """
            [ 1.0] init: using \(serial) as the serial and \(key) as the key
            [ 1.1] sntp: zone \(zone) selected, UTC kept
            [ 1.2] eth0: hwaddr \(mac), \(mac.uppercased()), \(mac.replacingOccurrences(of: ":", with: "-").uppercased()), \(mac.replacingOccurrences(of: ":", with: ""))
            [ 1.3] eth0: iid 1a:2bff:fe3c:4d5e, 001A:2BFF:FE3C:4D5E, 1A:2BFF:FE3C:4D5E and fe80::001a:2bff:fe3c:4d5e
            [ 1.4] other 1a2bff3c4d5e a1b2c3d4e5f607189 x\(serial)
            """
        let masked = SendFeedbackStartLog.masked(output, identifiers: identifiers)
        for value in [serial.uppercased() + "x", key, zone, "1a:2bff", "1A:2BFF", "2bff:fe3c", "021a2b", "02-1A-2B"]
        where !(value == serial.uppercased() + "x") {
            #expect(!masked.localizedCaseInsensitiveContains(value), "\(value) in \(masked)")
        }
        #expect(!masked.contains(serial + " ") && !masked.contains("as the serial and \(key)"))
        #expect(masked.contains("init: using <masked> as the serial and <masked> as the key"))
        #expect(masked.contains("sntp: zone <time zone> selected, UTC kept"))
        #expect(masked.contains("eth0: hwaddr <address>, <address>, <address>, <address>"))
        #expect(masked.contains("eth0: iid <address>, <address>, <address> and <ipv6>"))
        // A serial inside a longer word is not the serial.
        #expect(masked.contains("a1b2c3d4e5f607189 x\(serial)") && masked.contains("1a2bff3c4d5e"))
        // Without the values, the shapes that do not carry them stay.
        #expect(SendFeedbackStartLog.masked("[ 1.0] init: using \(serial) as the serial")
            == "[ 1.0] init: using \(serial) as the serial")
        // And through the finished text.
        let text = log(output: "[ 1.0] init: using \(serial) at \(zone)\n")
        #expect(text.contains(serial))
        let known = SendFeedbackStartLog.text(
            step: "Startup", seconds: 197, kind: .normal, restarts: 0, output: "[ 1.0] init: using \(serial) at \(zone)\n",
            identifiers: identifiers)
        #expect(known.contains("[ 1.0] init: using <masked> at <time zone>"))
    }

    @Test func theIdentityFileGivesTheSerialAndTheHardwareAddress() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("andarium-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(InstanceFiles.identityFile)
        try Data("{\n  \"ethernet_mac\": \"\(mac)\",\n  \"schema\": 1,\n  \"serialno\": \"\(serial)\"\n}\n".utf8).write(to: file)
        let read = GuestIdentifiers.reading(identityFile: file, adbKey: key, timeZones: [zone])
        #expect(read == identifiers)
        // A file that is absent, too long or not an object adds nothing.
        #expect(GuestIdentifiers.reading(identityFile: directory.appendingPathComponent("none"), adbKey: nil, timeZones: [])
            == .none)
        try Data(String(repeating: " ", count: 5000).utf8).write(to: file)
        #expect(GuestIdentifiers.reading(identityFile: file, adbKey: nil, timeZones: []) == .none)
        try Data("[1, 2]".utf8).write(to: file)
        #expect(GuestIdentifiers.reading(identityFile: file, adbKey: nil, timeZones: []) == .none)
        #expect(GuestIdentifiers.hardwareAddress("02:1a:2b:3c:4d") == nil
            && GuestIdentifiers.hardwareAddress("02:1a:2b:3c:4d:5g") == nil
            && GuestIdentifiers.hardwareAddress("02:1A:2B:3C:4D:5E") == [2, 0x1A, 0x2B, 0x3C, 0x4D, 0x5E])
    }

    @Test func theCutNeverSplitsACharacter() {
        // 1366 characters of three bytes: 4098 bytes, which a cut at 4096 would split.
        let expanded = String(repeating: "\u{6F22}", count: 1366)
        let limited = SendFeedbackStartLog.limited(expanded)
        #expect(limited.utf8.count <= SendFeedbackStartLog.outputLimit)
        #expect(!limited.contains("\u{FFFD}") && limited.allSatisfy { $0 == "\u{6F22}" })
        #expect(limited.utf8.count == 4095)
        // Lines of two-byte characters are cut at a line.
        let lines = (0..<600).map { "[\($0)] \(String(repeating: "\u{E9}", count: 8))" }.joined(separator: "\n") + "\n"
        let cut = SendFeedbackStartLog.limited(lines)
        #expect(cut.utf8.count <= SendFeedbackStartLog.outputLimit && cut.hasPrefix("[") && cut.hasSuffix("\n"))
        #expect(!cut.contains("\u{FFFD}"))
    }

    // MARK: The sheet's rules

    @Test func theTipFollowsTheStateTheSheetWasOpenedIn() {
        var form = SendFeedbackForm(mailAvailable: true, running: false)
        #expect(form.tip == .home, "from Home: nothing runs and nothing starts")
        form.starting = true
        #expect(form.tip == .starting)
        // A bug report and a screenshot stay unavailable during a start.
        #expect(!form.canMakeBugReport && !form.canTakeScreenshot && form.canAddMedia)
        // The start finishes while the sheet is open.
        form.starting = false
        form.running = true
        #expect(form.tip == .running && form.canMakeBugReport && form.canTakeScreenshot)
    }

    @Test func theLogAloneIsNotWhatClosingAsksAbout() {
        var form = SendFeedbackForm(mailAvailable: true, running: false)
        form.starting = true
        form.attachments.add(SendFeedbackAttachment(
            kind: .startLog, url: URL(fileURLWithPath: "/staged/start-log.txt"), bytes: 900))
        #expect(!form.hasContent, "a sheet that holds only what it attached itself closes without asking")
        #expect(form.attachments.count == 1 && form.attachments.totalBytes == 900, "but the mail counts it")
        form.details = "x"
        #expect(form.hasContent)
        form.details = ""
        form.attachments.add(SendFeedbackAttachment(
            kind: .photo, url: URL(fileURLWithPath: "/staged/photo.jpg"), bytes: 10))
        #expect(form.hasContent)
    }
}
