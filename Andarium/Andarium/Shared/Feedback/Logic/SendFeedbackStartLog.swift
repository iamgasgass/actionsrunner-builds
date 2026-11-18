// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import AndariumCore
import Foundation

/// The log a sheet opened during a start attaches by itself: a small text file
/// with the step the start has reached, the time on the notice's clock, the
/// kind of start and what the virtual machine printed while starting, for this
/// boot only. It is in English, for whoever reads the mail, as the information
/// block is, and the person sees it as a row they can remove.
nonisolated enum SendFeedbackStartLog {
    /// The most of the printed output the file holds. The runtime's session
    /// record keeps 4 KiB of a boot's output (`session_kernel_output_bytes`); a
    /// longer text is cut from its start, to the last whole line.
    static let outputLimit = 4096

    static func kindName(_ kind: BootKind) -> String {
        switch kind {
        case .normal: "ordinary start"
        case .firstStart: "first start"
        case .upgrade: "first start after an update"
        case .recovery: "Recovery start"
        case .restart: "restart"
        }
    }

    /// The file's text. `output` is what the virtual machine printed in this
    /// boot, as the runtime's record last quoted it (nil where it has none yet);
    /// `containers` are the application's own folders, which the output may
    /// name, and `identifiers` the values of this installation that are taken
    /// out wherever they stand.
    static func text(
        step: String, seconds: Int, kind: BootKind, restarts: Int, output: String?, containers: [String] = [],
        identifiers: GuestIdentifiers = .none
    ) -> String {
        var lines = [
            "Start log",
            "Step: \(step)",
            "Time: \(Formats.elapsed(seconds))",
            "Start: \(kindName(kind))",
        ]
        if restarts > 0 { lines.append("Restarts in this start: \(restarts)") }
        lines.append("")
        lines.append("Printed while starting, this boot only (the last \(outputLimit) bytes at most):")
        let printed = (output.map { masked(limited($0), containers: containers, identifiers: identifiers) } ?? "")
            .trimmingCharacters(in: .newlines)
        lines.append(printed.isEmpty ? "(nothing yet)" : printed)
        return lines.joined(separator: "\n") + "\n"
    }

    /// `output` cut from its start to at most `outputLimit` bytes, at a line.
    /// The cut falls between two characters: a character it would split is
    /// left out whole, not replaced by U+FFFD, which is longer than the bytes
    /// it stands for.
    static func limited(_ output: String) -> String {
        guard output.utf8.count > outputLimit else { return output }
        var bytes = Array(output.utf8.suffix(outputLimit))
        while let first = bytes.first, first & 0xC0 == 0x80 { bytes.removeFirst() }
        var tail = String(decoding: bytes, as: UTF8.self)
        if let newline = tail.firstIndex(of: "\n") { tail = String(tail[tail.index(after: newline)...]) }
        return tail
    }

    /// The kernel arguments whose value is taken out, and what stands in its
    /// place: the first line may be the end of one of them.
    private static let sensitiveArguments: [(name: String, short: String, placeholder: String)] = [
        ("androidboot.kernarium.adb_key", "adb_key", "<masked>"),
        ("androidboot.kernarium.timezone", "timezone", "<time zone>"),
    ]

    /// `text` with what could tell an installation apart taken out, as well as
    /// what the bug report takes out (`DiagnosticRedaction`). By the name that
    /// carries a value:
    /// - the value of every `adb_key=` assignment (the kernel echoes its command
    ///   line, and the host's adb public key is on it), and of the same property
    ///   printed as `[...adb_key]: [value]`;
    /// - the value of `serialno=` and of the property `[...serialno]: [value]`
    ///   (the runtime masks the first in the record; this is the same rule again,
    ///   for a text that did not come from it);
    /// - the value of `timezone=` and of the property `[...timezone]: [value]`,
    ///   which tells the region the person is in, as `<time zone>`;
    /// - the value in init's `Init cannot set 'NAME' to 'VALUE'`, whichever
    ///   property it names (the properties come from the kernel's command line,
    ///   and the reason after it stays);
    /// - and, where the text begins in the middle of a line, the rest of an
    ///   assignment that was cut, or of a key cut inside its value.
    ///
    /// By value, wherever the text has it (`identifiers`): the serial number,
    /// the adb key, the hardware address in its colon, dash and plain spellings
    /// and the interface identifier an IPv6 address derives from it, and the
    /// time zone's name. By shape, whatever the value: any hardware address in
    /// its colon spelling, any IPv6 address (`maskedIPv6`), any UUID (a
    /// filesystem's, a container's), the application's own folders and the
    /// person's home folder.
    static func masked(_ text: String, containers: [String] = [], identifiers: GuestIdentifiers = .none) -> String {
        let masked = "<masked>"
        var result = maskedFirstLineFragment(text)
        for (pattern, template) in [
            (#"(adb_key=)\S*"#, "$1\(masked)"),
            (#"(adb_key\]: \[)[^\]]*"#, "$1\(masked)"),
            (#"(serialno=)\S*"#, "$1\(masked)"),
            (#"(serialno\]: \[)[^\]]*"#, "$1\(masked)"),
            (#"(timezone=)\S*"#, "$1<time zone>"),
            (#"(timezone\]: \[)[^\]]*"#, "$1<time zone>"),
            (#"(Init cannot set '[^']*' to ')[^']*(')"#, "$1\(masked)$2"),
        ] {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        result = maskedKnownValues(result, identifiers)
        result = result.replacingOccurrences(
            of: #"\b[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}\b"#, with: "<address>", options: .regularExpression)
        // The folders go first: a container's path ends in a UUID, which the
        // rule for UUIDs would leave the rest of the path of.
        result = DiagnosticRedaction.redact(result, containers: containers)
        result = maskedIPv6(result)
        result = maskedInterfaceIdentifiers(result, identifiers)
        return maskedUUIDs(result)
    }

    /// A text cut at its start begins in the middle of a line. If the cut fell
    /// inside the argument that carries a key or a time zone, what is left is
    /// the name's tail and the value (`_key=AAAA...`), or the value's tail alone
    /// (`AAAA...==`, `Tokyo`): the first word is masked in either case. A value's
    /// tail is told from an ordinary word by what surrounds it: a key's tail
    /// looks like base64 (eight characters or more with its padding) and is not
    /// a plain word, and any other tail is one where the line goes on with
    /// arguments of the kernel's command line. The log's own text always begins
    /// at a whole line, so this is for a text that does not.
    private static func maskedFirstLineFragment(_ text: String) -> String {
        let end = text.firstIndex(where: { $0 == "\n" }) ?? text.endIndex
        let line = text[..<end]
        let wordEnd = line.firstIndex(where: { $0 == " " || $0 == "\t" }) ?? line.endIndex
        let word = String(line[..<wordEnd])
        let rest = text[wordEnd...]
        // A key's tail looks like base64 and is not a plain word: it has a
        // digit, a sign, or a capital after its first letter.
        if word.count >= 8, word.range(of: #"^[A-Za-z0-9+/]+={0,2}$"#, options: .regularExpression) != nil,
           word.contains(where: \.isNumber) || word.contains(where: { "+/=".contains($0) })
            || word.dropFirst().contains(where: \.isUppercase) {
            return "<masked>" + rest
        }
        if let equals = word.firstIndex(of: "=") {
            let name = word[..<equals]
            // A whole name is the ordinary rule's; a name's tail is a cut one.
            for argument in sensitiveArguments where argument.name.hasSuffix(name) && !name.hasSuffix(argument.short) {
                return String(word[...equals]) + argument.placeholder + rest
            }
            return text
        }
        // The tail of a value (`Tokyo`, `Aires`) in a line of the command line.
        if word.range(of: #"^[A-Za-z0-9_/+.-]+$"#, options: .regularExpression) != nil,
           rest.contains("androidboot.") {
            return "<masked>" + rest
        }
        return text
    }
}

#endif
