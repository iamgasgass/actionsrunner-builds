// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import Foundation

// Send feedback's logic: plain values and rules, no UIKit. The application
// compiles these files with the rest of Send feedback, and only where it is
// compiled in; the AndariumCore package compiles the same files for its tests
// (Andarium/README.md#send-feedback).

/// What the mail Send feedback hands to the system's composer says.
nonisolated enum SendFeedbackMail {
    /// What the subject starts with, so the receiver can filter on it.
    static let subjectPrefix = "Andarium feedback: "
    /// The line between what the person wrote and the information block.
    static let separator = "--"

    /// The subject: the prefix and the problem on one line.
    static func subject(problem: String) -> String {
        let words = problem.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return subjectPrefix + words.joined(separator: " ")
    }

    /// The details, a separator, then the information block. Without details
    /// the body starts with an empty line, where the person can still type.
    static func body(details: String, information: SendFeedbackInformation) -> String {
        let text = details.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = text.isEmpty ? "\n\n" : text + "\n\n"
        return head + separator + "\n" + information.text + "\n"
    }

    /// Whether `address` can be a receiver. One strict shape, the one the
    /// App Store bundle check holds the build's address to
    /// (`Andarium/scripts/check-app-store-bundle.py`): a local part of 1 to 64
    /// letters, digits and `. _ % + -` that starts and ends with a letter or
    /// digit and has no two dots in a row, then `@`, then at least two
    /// dot-separated labels of letters, digits and hyphens (none starts or
    /// ends with a hyphen) whose last is two or more letters. Quotes, angle
    /// brackets, a trailing semicolon, spaces and a second `@` make no address.
    static func isWellFormed(address: String) -> Bool {
        let bytes = Array(address.utf8)
        guard bytes.count <= 254 else { return false }
        let parts = bytes.split(separator: UInt8(ascii: "@"), omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = Array(parts[0])
        guard (1...64).contains(local.count),
              local.allSatisfy({ isAlphanumeric($0) || ".%_+-".utf8.contains($0) }),
              isAlphanumeric(local[0]), isAlphanumeric(local[local.count - 1]),
              !zip(local, local.dropFirst()).contains(where: { $0 == UInt8(ascii: ".") && $1 == UInt8(ascii: ".") })
        else { return false }
        let labels = parts[1].split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels.dropLast() {
            guard (1...63).contains(label.count),
                  label.allSatisfy({ isAlphanumeric($0) || $0 == UInt8(ascii: "-") }),
                  isAlphanumeric(label.first!), isAlphanumeric(label.last!) else { return false }
        }
        let top = labels[labels.count - 1]
        return (2...63).contains(top.count) && top.allSatisfy(isLetter)
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        isLetter(byte) || (byte >= 0x30 && byte <= 0x39)
    }
}

/// What the composer is given: where the mail goes, what it says and the files
/// that go with it, each already mapped (`mapped[i]` is the bytes of
/// `attachments[i]`), so the composer never has a file to leave out. Not
/// `Equatable`: comparing it would compare the bytes of every file.
nonisolated struct SendFeedbackMailRequest: Sendable {
    var address: String
    var subject: String
    var body: String
    var attachments: [SendFeedbackAttachment]
    var mapped: [Data]
}

#endif
