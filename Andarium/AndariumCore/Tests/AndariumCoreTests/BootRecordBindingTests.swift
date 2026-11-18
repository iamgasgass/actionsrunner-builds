// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Testing

@testable import AndariumCore

/// Which session record is the boot under way's: the start log quotes the
/// record's kernel output only for it.
struct BootRecordBindingTests {
    /// The process the application runs as, and the second the run's record
    /// began in (2026-11-08 05:04:51 UTC).
    private static let pid = 4242
    private static let began = 1_794_114_291

    /// A record as the runtime writes it, with the lines the binding reads.
    private func record(
        state: String = "running", end: String = "running", pid: Int = pid, started: Int = began,
        restarts: Int? = 0, output: String = "init: starting service 'netd'\n"
    ) -> SessionRecord? {
        var text = "uml-session 7\nstate \(state)\nend \(end)\nstatus 0\npid \(pid)\nstarted \(started)\n"
        if state != "running" { text += "ended \(started + 5)\n" }
        text += "boot unfinished\n"
        if let restarts { text += "restarts \(restarts)\n" }
        text += "kernel-output\n" + output
        return SessionRecord(text: text)
    }

    private let binding = BootRecordBinding(processID: pid)

    @Test func theRunningRecordOfTheBootUnderWayIsAccepted() {
        #expect(binding.output(of: record()) == "init: starting service 'netd'\n")
    }

    /// The runtime stamps its record with the system clock as it reads it when the
    /// record begins, which may be earlier than the clock was when the run was
    /// asked for (the clock stepped back while the disk and the key were
    /// prepared): the boot's own record is accepted whatever second it says.
    @Test func aClockThatSteppedBackDoesNotMakeTheBootsOwnRecordStale() {
        for started in [Self.began - 1, Self.began - 600, Self.began - 86_400, 0, Self.began + 600] {
            #expect(binding.output(of: record(started: started)) != nil, "started \(started)")
        }
        // Also when the file held an earlier run's leftover at the start.
        let leftover = BootRecordBinding(
            processID: Self.pid, recordAtStart: record(started: Self.began + 7_200, output: "init: leftover\n"))
        #expect(leftover.output(of: record(started: Self.began - 3_600)) != nil)
    }

    @Test func aRecordThatEndedIsNotTheBootUnderWays() {
        for end in ["stopped", "restarted", "powered-off", "guest-panic", "failed"] {
            #expect(binding.output(of: record(state: "ended", end: end)) == nil, "\(end)")
        }
    }

    @Test func aRunningRecordOfAnotherProcessIsNot() {
        #expect(binding.output(of: record(pid: Self.pid + 1)) == nil)
        #expect(binding.output(of: record(pid: 1)) == nil)
    }

    /// A running record that the file held as the run began, of this process
    /// (an earlier run whose end was never written) or of one whose process id
    /// came round: it is that record, and no other, that is refused.
    @Test func aRunningLeftoverOfAnEarlierRunPresentAtTheStartIsNot() {
        for leftoverStarted in [Self.began - 3_600, Self.began, Self.began + 3_600] {
            let leftover = record(started: leftoverStarted, output: "init: from the run before\n")
            let bound = BootRecordBinding(processID: Self.pid, recordAtStart: leftover)
            #expect(bound.output(of: leftover) == nil, "leftover started \(leftoverStarted)")
            // The run's own record is another: it began after, and says so.
            #expect(bound.output(of: record(started: leftoverStarted + 1, output: "init: this run\n")) != nil)
            #expect(bound.output(of: record(started: leftoverStarted - 1, output: "init: this run\n")) != nil)
        }
        // A leftover of this boot's count only: a boot after a restart is not that record.
        var restarted = BootRecordBinding(processID: Self.pid, recordAtStart: record(restarts: 0))
        restarted.restarts = 1
        #expect(restarted.output(of: record(restarts: 1, output: "init: next boot\n")) != nil)
        // The leftover of another process is refused anyway, and not noted for another.
        #expect(BootRecordBinding(processID: Self.pid, recordAtStart: record(pid: Self.pid + 1))
            .output(of: record()) != nil)
    }

    /// An ended record was refused for it already; noting it would refuse the
    /// record of a run that began in the second the earlier one did.
    @Test func anEndedRecordAtTheStartIsNotNotedAsALeftover() {
        let ended = record(state: "ended", end: "stopped")
        let bound = BootRecordBinding(processID: Self.pid, recordAtStart: ended)
        #expect(bound.output(of: ended) == nil)
        #expect(bound.output(of: record()) != nil)
        // Neither is no record at all.
        #expect(BootRecordBinding(processID: Self.pid, recordAtStart: nil).output(of: record()) != nil)
    }

    @Test func aRunningRecordOfAnEarlierBootOfThisProcessIsNot() {
        var restarted = binding
        restarted.restarts = 2
        #expect(restarted.output(of: record(restarts: 1)) == nil)
        #expect(restarted.output(of: record(restarts: 0)) == nil)
        #expect(restarted.output(of: record(restarts: 2)) != nil)
        // A record of a later boot is not this one's either: the application has not yet been told of it.
        #expect(restarted.output(of: record(restarts: 3)) == nil)
    }

    @Test func betweenARestartAndTheNextRecordTheFileHoldsTheBootBeforeAndNothingIsQuoted() {
        var restarted = binding
        restarted.restarts = 1
        // The runtime ended the boot before (`restarted`), and has not begun the next one's record.
        #expect(restarted.output(of: record(state: "ended", end: "restarted", restarts: 0)) == nil)
        // Whatever the old record's end says, its count is the boot before's.
        #expect(restarted.output(of: record(restarts: 0)) == nil)
        // The next boot's record is its own.
        #expect(restarted.output(of: record(restarts: 1, output: "init: next boot\n")) == "init: next boot\n")
    }

    @Test func aRecordWithoutARestartCountOrOutputOrAtAllGivesNothing() {
        #expect(binding.output(of: record(restarts: nil)) == nil)
        #expect(binding.output(of: record(output: "")) == nil)
        #expect(binding.output(of: nil) == nil)
    }

    @Test func aRecordPaddedWithNewlinesGivesTheOutputWithoutThem() {
        #expect(binding.output(of: record(output: "init: a\ninit: b\n" + String(repeating: "\n", count: 4000)))
            == "init: a\ninit: b\n")
    }
}
