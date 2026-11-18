// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What the application knows of the boot under way, to tell the runtime's
/// session record of it from any other that may be on disk: the record of a
/// session that ended, of another process (a launch before this one), of an
/// earlier boot of this one, or one that was already in the file when the run
/// began. A record is the boot's when it is running, is of this process, says
/// the restart count the application counted for this boot and is not that
/// leftover.
///
/// No comparison of the wall clock is part of it: the system clock may step
/// while the run prepares its disk, and the runtime stamps its record with
/// whatever the clock says then, so a record that is the boot's must never be
/// refused for an earlier time.
public struct BootRecordBinding: Equatable, Sendable {
    /// The running record that the file held when the run began, which no later
    /// record of this run can be: the file is rewritten for the run, and a
    /// record of the same process, beginning and boot that is still there was not.
    struct Leftover: Equatable, Sendable {
        var processID: Int
        var started: Date?
        var restarts: Int?
    }

    /// This process: the record's `pid`. A record of an earlier launch is of
    /// another process; one whose process id came round again is the leftover.
    public var processID: Int
    /// How many times the runtime restarted the guest in place in this run
    /// (`GuestRestartEvent.began`'s count), which is the `restarts` its record
    /// says of the boot that follows. A restart makes it one more at once; the
    /// record of the boot before says the number before, or has ended, until
    /// the runtime begins the next.
    public var restarts: Int
    private var leftover: Leftover?

    /// `recordAtStart` is the record the file holds as the run begins (nil
    /// where there is none). Only a running one is noted: an ended record is
    /// refused for that, and noting it would refuse a run's own record that
    /// began in the same second.
    public init(processID: Int, restarts: Int = 0, recordAtStart: SessionRecord? = nil) {
        self.processID = processID
        self.restarts = restarts
        if let record = recordAtStart, record.running {
            leftover = Leftover(processID: record.processID, started: record.started, restarts: record.restarts)
        }
    }

    /// Whether `record` is the running record of the boot under way. A record
    /// that does not say its restart count (a guest whose console reports no
    /// boot) is not: nothing then binds it to this boot.
    public func accepts(_ record: SessionRecord) -> Bool {
        guard record.running, record.end == "running", record.processID == processID,
            record.restarts == restarts
        else { return false }
        return leftover != Leftover(processID: record.processID, started: record.started, restarts: record.restarts)
    }

    /// What the guest printed in the boot under way, as `record` last quoted it:
    /// nil where the record is not that boot's or holds no output yet.
    public func output(of record: SessionRecord?) -> String? {
        guard let record, accepts(record), let output = record.kernelOutput, !output.isEmpty else { return nil }
        return output
    }
}
