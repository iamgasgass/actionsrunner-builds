// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// How the previous process's guest session ended, as the runtime recorded
/// it (darwin/runtime/session_record.hpp).
///
/// The runtime writes "running" when the guest boots and overwrites it with
/// the end on every way the session ends that runs any code: Android's own
/// power-off or restart, a stop, a guest kernel panic with its message, an
/// exit the kernel drives, a hibernated guest whose RAM could not be
/// restored, a crash of a host thread and an exit() of the process. A record
/// still running at the next launch says that the process ended without
/// running any of that code: the system ended it, as an end at the memory
/// limit does, or it crashed outside the guest's paths, which leaves only
/// the system's crash report.
public struct SessionRecord: Equatable, Sendable {
    /// The last of the runtime's memory checkpoints, a few seconds apart.
    public struct Memory: Equatable, Sendable {
        public var at: Date
        public var footprintBytes: UInt64
        public var peakBytes: UInt64
        /// What the process's memory limit still allowed; nil where the host
        /// sets no limit.
        public var availableBytes: UInt64?
    }

    public var running: Bool
    /// The runtime's word for the end: running, powered-off, restarted,
    /// stopped, failed, guest-panic, kernel-abort, kernel-exit,
    /// hibernation-restore-failed, process-exit or host-fault.
    public var end: String
    public var status: Int
    public var processID: Int
    public var started: Date?
    public var ended: Date?
    /// The panic's message, or what else the end said.
    public var message: String?
    /// The guest kernel's last output before a crash, oldest line first.
    public var kernelOutput: String?
    public var memory: Memory?
    /// Whether the guest's console had said that Android finished booting, for
    /// a guest whose console says so; nil in a record that does not say (an
    /// earlier runtime, or a guest that never reports it).
    public var bootFinished: Bool?
    /// How many times the guest had restarted in the process before this
    /// session, for a guest whose boot the record follows.
    public var restarts: Int?
    /// The footprint's large terms at the last checkpoint and at the
    /// session's highest one, in MiB, as the runtime words them ("guest G gpu
    /// H/B ..."); nil in a record that has none.
    public var terms: String?
    public var peakTerms: String?
    /// The stall record of the session, from layout 4 on: when the guest's
    /// vCPUs stopped running on the host and what the host was doing then; nil
    /// in an earlier layout or when the slot is of a version this reader does
    /// not know.
    public var stalls: StallRecord?
    /// What the guest's user network counted and whether Andarium's notice that
    /// iOS denies it the network was shown, from layout 5 on; nil in an earlier
    /// layout or when the slot is of a version this reader does not know.
    public var network: NetworkRecord?
    /// How often the guest's storage was settled and how often the guest did
    /// not confirm it, from layout 7 on; nil in an earlier layout, when the
    /// slot is blank (no settle yet) or when it is of a version this reader
    /// does not know.
    public var storage: StorageRecord?
    /// How the platform presented each of the guest's cameras and the stills of
    /// the guest's cameras that did not end in a picture and why, from layout 8
    /// on; nil in an earlier layout, when the slot is blank (no camera presented
    /// and no failure) or when it is of a version this reader does not know.
    public var camera: CameraRecord?

    /// The layouts this reader knows: 1 to 3 keep the session's state right
    /// after the memory slot, 4 puts the stall slot between them, 5 the
    /// network slot after the stall slot, 6 the figures of the run in each
    /// history row of an 8 KiB memory slot, 7 the storage slot after the
    /// network slot and 8 the camera slot after the storage slot. The rows are
    /// for the person reading the bug report; this reader takes none of them.
    static let layouts = [
        "uml-session 1", "uml-session 2", "uml-session 3", "uml-session 4", "uml-session 5", "uml-session 6",
        "uml-session 7", "uml-session 8",
    ]

    /// The read cap, 20 KiB: the runtime writes at most 19200 bytes
    /// (`session_record_max_bytes`), so a file longer than the cap is not one
    /// it wrote, and is neither read nor copied beyond it. The gap is slack for
    /// a later layout, not a limit the runtime reaches.
    public static let maximumBytes = 20 << 10

    /// The output's own text: the runtime pads the state's area with newlines to
    /// its full size, so the output ends with one newline, as the guest's
    /// last line did, and not with the padding.
    private static func withoutPadding(_ output: String) -> String {
        guard output.hasSuffix("\n") else { return output }
        var text = Substring(output)
        while text.hasSuffix("\n") { text.removeLast() }
        return text + "\n"
    }

    /// Reads a record's text; nil when it is not one.
    public init?(text: String) {
        let parts = text.components(separatedBy: "\nkernel-output\n")
        var fields: [String: String] = [:]
        let lines = parts[0].split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.allSatisfy { $0 == " " } }
        guard let format = lines.first, Self.layouts.contains(String(format))
        else { return nil }
        for line in lines.dropFirst() {
            guard let space = line.firstIndex(of: " ") else { continue }
            fields[String(line[..<space])] = String(line[line.index(after: space)...])
        }
        guard let state = fields["state"], let end = fields["end"] else { return nil }
        running = state == "running"
        self.end = end
        status = fields["status"].flatMap { Int($0) } ?? 0
        processID = fields["pid"].flatMap { Int($0) } ?? 0
        started = fields["started"].flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
        ended = fields["ended"].flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
        message = fields["message"]
        kernelOutput = parts.count > 1 ? Self.withoutPadding(parts[1]) : nil
        memory = fields["memory"].flatMap(Self.memory(from:))
        bootFinished = fields["boot"].flatMap { ["completed": true, "unfinished": false][$0] }
        restarts = fields["restarts"].flatMap { Int($0) }
        terms = fields["terms"]
        peakTerms = fields["peak-terms"]
        let hasStalls = ["uml-session 4", "uml-session 5", "uml-session 6", "uml-session 7", "uml-session 8"]
            .contains(String(format))
        stalls = hasStalls ? StallRecord(text: parts[0]) : nil
        let hasNetwork = ["uml-session 5", "uml-session 6", "uml-session 7", "uml-session 8"]
            .contains(String(format))
        network = hasNetwork ? NetworkRecord(text: parts[0]) : nil
        storage = ["uml-session 7", "uml-session 8"].contains(String(format))
            ? StorageRecord(text: parts[0]) : nil
        camera = format == "uml-session 8" ? CameraRecord(text: parts[0]) : nil
    }

    /// "at T footprint F peak P [available A]".
    private static func memory(from line: String) -> Memory? {
        let words = line.split(separator: " ")
        var values: [String: UInt64] = [:]
        var index = 0
        while index + 1 < words.count {
            if let value = UInt64(words[index + 1]) { values[String(words[index])] = value }
            index += 2
        }
        guard let at = values["at"], let footprint = values["footprint"] else { return nil }
        return Memory(
            at: Date(timeIntervalSince1970: TimeInterval(at)), footprintBytes: footprint,
            peakBytes: values["peak"] ?? footprint, availableBytes: values["available"]
        )
    }

    /// The record at `url`, or nil when there is none, it is longer than
    /// `maximumBytes` or it is not a record.
    public static func read(at url: URL) -> SessionRecord? {
        guard let data = BoundedFile.read(url, limit: maximumBytes), data.count <= maximumBytes,
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return SessionRecord(text: text)
    }

    /// Whether the session ended on its own terms: Android's power-off or
    /// restart, or a stop.
    public var orderly: Bool {
        !running && ["powered-off", "restarted", "stopped"].contains(end)
    }

    /// Below this, at the last checkpoint, a record still running most
    /// likely ended at the memory limit: the GPU and the guest can take that
    /// much between two checkpoints.
    public static let lowMemoryBytes: UInt64 = 256 << 20

    /// Whether the last checkpoint left the process close to its limit.
    public var nearMemoryLimit: Bool {
        guard let available = memory?.availableBytes else { return false }
        return available < Self.lowMemoryBytes
    }

    /// One line for a log or a report.
    public var summary: String {
        summaryOfEnd + bootSentence
    }

    /// What the record adds of the boot when it did not finish.
    private var bootSentence: String {
        guard bootFinished == false else { return "" }
        let times = restarts.map { $0 > 0 ? " and the guest had restarted \($0) time\($0 == 1 ? "" : "s") in this process" : "" } ?? ""
        return " Android had not finished booting\(times)."
    }

    private var summaryOfEnd: String {
        if running {
            var line = "The previous session was still running when the process ended (pid \(processID))"
            if let memory {
                line += "; at the last checkpoint it used \(memory.footprintBytes >> 20) MiB"
                if let available = memory.availableBytes { line += ", \(available >> 20) MiB left" }
            }
            return line + "."
        }
        let detail = message.map { ": \($0)" } ?? ""
        switch end {
        case "guest-panic":
            return "The previous session ended in a guest kernel panic\(detail)."
        case "kernel-abort":
            return "The previous session ended in a guest kernel crash\(detail)."
        case "kernel-exit":
            return "The guest kernel ended the previous process with status \(status)\(detail)."
        case "hibernation-restore-failed":
            return "The previous session ended because its guest RAM could not be restored\(detail)."
        case "process-exit":
            return "The previous process exited while its guest ran\(detail)."
        case "host-fault":
            return "The previous process crashed in Andarium's own code, with a crash report\(detail)."
        default:
            return "The previous session ended: \(end)\(detail)."
        }
    }

    /// What Home says at the next launch, or nil for an orderly end. A record
    /// still running whose process ended out of the foreground is iOS
    /// closing a paused guest, which the pause marker reports instead.
    public func notice(endedOutOfForeground: Bool) -> SessionEndNotice? {
        if orderly || (running && endedOutOfForeground) { return nil }
        switch end {
        case "guest-panic":
            return SessionEndNotice(
                title: String(
                    localized: "Android’s kernel panicked", bundle: .module,
                    comment: "Title of Home's card after Android's kernel panicked, the Linux kernel's own fatal error."),
                text: message.map {
                    String(
                        localized: "Android stopped with a kernel panic: \($0).", bundle: .module,
                        comment: "Home's card after a kernel panic. The argument is the kernel's own message, in English, which stays as it is.")
                } ?? String(
                    localized: "Android stopped with a kernel panic.", bundle: .module,
                    comment: "Home's card after a kernel panic that left no message.")
            )
        case "kernel-abort":
            return SessionEndNotice(
                title: String(
                    localized: "Android’s kernel crashed", bundle: .module,
                    comment: "Title of Home's card after Android's kernel stopped on an error of its own."),
                text: String(
                    localized: "Android stopped on a kernel error.", bundle: .module,
                    comment: "Home's card after Android's kernel stopped on an error of its own."))
        case "kernel-exit":
            return SessionEndNotice(
                title: String(
                    localized: "Android stopped", bundle: .module,
                    comment: "Title of Home's card after Android's kernel ended the session by itself, or after a stop with no known cause."),
                text: String(
                    localized: "Android’s kernel ended Andarium.", bundle: .module,
                    comment: "Home's card after Android's kernel ended the session by itself."))
        case "hibernation-restore-failed":
            return SessionEndNotice(
                title: String(
                    localized: "Android could not resume", bundle: .module,
                    comment: "Title of Home's card after a start that could not bring back the memory Android saved when it was paused."),
                text: String(
                    localized: "Android’s memory could not be restored, so it starts again from boot.", bundle: .module,
                    comment: "Home's card after a start that could not bring back the memory Android saved when it was paused."))
        case "host-fault", "process-exit":
            return SessionEndNotice(
                title: String(
                    localized: "Andarium crashed", bundle: .module,
                    comment: "Title of Home's card after Andarium itself crashed while Android was running."),
                text: String(
                    localized: "Andarium stopped on an error of its own while Android was running.", bundle: .module,
                    comment: "Home's card after Andarium itself crashed while Android was running."))
        case "running" where nearMemoryLimit:
            return SessionEndNotice(
                title: String(
                    localized: "iOS ended Andarium", bundle: .module,
                    comment: "Title of Home's card after iOS ended Andarium because the memory it used came near the limit."),
                text: String(
                    localized: "Android was using almost all the memory iOS allows Andarium. A smaller memory size is safer.",
                    bundle: .module,
                    comment: "Home's card after iOS ended Andarium because the memory it used came near the limit."))
        case "running":
            return SessionEndNotice(
                title: String(
                    localized: "Andarium stopped unexpectedly", bundle: .module,
                    comment: "Title of Home's card after Andarium ended while Android was running, with no known cause."),
                text: String(
                    localized: "Andarium ended while Android was running.", bundle: .module,
                    comment: "Home's card after Andarium ended while Android was running, with no known cause."))
        default:
            return SessionEndNotice(
                title: String(
                    localized: "Android stopped", bundle: .module,
                    comment: "Title of Home's card after Android's kernel ended the session by itself, or after a stop with no known cause."),
                text: String(
                    localized: "Android stopped unexpectedly.", bundle: .module,
                    comment: "Home's card after a stop with no known cause."))
        }
    }
}

/// Home's card after a session that ended badly.
public struct SessionEndNotice: Equatable, Sendable {
    public var title: String
    public var text: String

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}

/// Text that leaves the device in a bug report, with the application's own
/// container paths taken out: they identify this install of Andarium.
public enum DiagnosticRedaction {
    /// `text` with every path in `containers` replaced by `<container>`, and
    /// any other path that names an application container by its identifier
    /// replaced the same way.
    public static func redact(_ text: String, containers: [String]) -> String {
        var result = text
        for container in containers.filter({ $0.count > 1 }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: container, with: "<container>")
            // /private/var and /var name the same directory.
            if container.hasPrefix("/private/var/") {
                result = result.replacingOccurrences(
                    of: String(container.dropFirst("/private".count)), with: "<container>")
            }
        }
        let identified = #"(/private)?/var/[^\s"']*?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
        result = result.replacingOccurrences(of: identified, with: "<container>", options: .regularExpression)
        // An iPad app on a Mac lives under the person's home directory.
        return result.replacingOccurrences(
            of: #"/Users/[^/\s"']+"#, with: "/Users/<user>", options: .regularExpression)
    }
}

/// The previous session's record at launch: read once, then kept as
/// `previous-session.txt` for the bug report, so the next boot can write its
/// own and a second launch says nothing more.
public enum PreviousSession {
    /// The record and the notice Home shows for it. `endedOutOfForeground`
    /// is whether the pause marker said the previous process ended paused.
    public static func consume(in diagnostics: URL, endedOutOfForeground: Bool)
        -> (record: SessionRecord, notice: HomeNotice?)?
    {
        let current = diagnostics.appendingPathComponent(BugReportAttachments.sessionRecord)
        guard let record = SessionRecord.read(at: current) else { return nil }
        let kept = diagnostics.appendingPathComponent(BugReportAttachments.previousSessionRecord)
        try? FileManager.default.removeItem(at: kept)
        try? FileManager.default.moveItem(at: current, to: kept)
        return (record, record.notice(endedOutOfForeground: endedOutOfForeground).map { .sessionEnded($0) })
    }
}
