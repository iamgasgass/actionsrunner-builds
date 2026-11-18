// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import AndariumCore
import SwiftUI
import UIKit

extension AppModel {
    /// The receiver, when Send feedback has one: both entrances need it.
    var feedbackAddress: String? { feedbackServices.address() }

    /// A virtual machine runs.
    var virtualMachineRuns: Bool {
        if case .running = phase { return true }
        return false
    }

    /// The basic information that ends the mail.
    func feedbackInformation() -> SendFeedbackInformation {
        let bundle = Bundle.main
        // The display as the guest has it, in the plain words the receiver reads.
        let display = resolutionLayout.map { "\($0.width) x \($0.height) px, \($0.dotsPerInch) dpi" } ?? "not measured"
        let machine = guest.map { guest in
            SendFeedbackInformation.VirtualMachine(
                vcpus: guest.cores, memoryMiB: guest.memoryMiB, display: display,
                graphicsMiB: host.memory.graphicsMemoryMiB(
                    forMemory: guest.memoryMiB, vCPUs: guest.cores, cameraLive: cameraMode == .live))
        }
        return SendFeedbackInformation(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            configuration: Self.buildConfiguration,
            deviceModel: Self.machineIdentifier,
            runsOnMac: ProcessInfo.processInfo.isiOSAppOnMac,
            systemVersion: UIDevice.current.systemVersion,
            language: bundle.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en",
            virtualMachine: machine,
            androidRelease: system.release,
            runningSeconds: virtualMachineRuns ? feedbackServices.runningSeconds(self) : nil,
            boot: bootingInformation(),
            freeSpaceBytes: host.freeStorageBytes,
            thermalState: Self.thermalName(ProcessInfo.processInfo.thermalState), heatLimitOn: heatLimitOn)
    }

    /// The virtual machine is starting: the boot screen is up and Android has
    /// not been seen to boot.
    var virtualMachineStarts: Bool {
        if case .booting = phase { return true }
        return false
    }

    /// What the virtual machine printed in this boot, as the runtime's session
    /// record last quoted it: at most 4 KiB, from a checkpoint a few seconds
    /// old. Only the running record of the boot under way counts
    /// (`BootRecordBinding`): the record of a session that ended, of another
    /// process, of an earlier boot or left in the file as the run began says
    /// nothing of this one. nil where there is no such record or it has no
    /// output yet.
    func startOutput() -> String? {
        guard let diagnosticsDirectory, let bootRecord else { return nil }
        let record = SessionRecord.read(at: diagnosticsDirectory.appendingPathComponent(BugReportAttachments.sessionRecord))
        return bootRecord.output(of: record)
    }

    /// Where a start that is still under way has got, for the mail written
    /// from the boot screen's notice; nil in any other state.
    private func bootingInformation() -> SendFeedbackInformation.Boot? {
        guard case let .booting(kind) = phase else { return nil }
        // The boot screen's own step, so the mail names the one the notice shows.
        let step = liveBootStage()
        return SendFeedbackInformation.Boot(
            step: BootSteps.reportName(ofStep: min(step, BootSteps.count - 1), recovery: kind == .recovery),
            seconds: bootElapsedSeconds(), restarts: slowStart.restarts)
    }

    private static var buildConfiguration: String {
        #if TESTFLIGHT
        "TestFlight"
        #elseif APP_STORE
        "AppStore"
        #elseif DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    /// The hardware's machine identifier ("iPhone18,1"); in the Simulator, the
    /// model it plays; for an iPad app on a Mac, the Mac's model, as the
    /// identifier there names no model. nil when it cannot be read.
    private static var machineIdentifier: String? {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        return sysctlString(ProcessInfo.processInfo.isiOSAppOnMac ? "hw.model" : "hw.machine")
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// Makes a bug report for the Send feedback sheet: the same work as the
    /// Settings row, under the same overlay, which the sheet draws over
    /// itself instead of the screens. `failed` says why it did not come.
    /// Returns false when nothing started.
    @discardableResult
    func createBugReportForFeedback(
        finished: @escaping @MainActor (URL) -> Void, failed: @escaping @MainActor (String) -> Void
    ) -> Bool {
        guard canCreateBugReport, busy == nil else { return false }
        busyOverSheet = true
        runOperation(
            Self.bugReportState, failure: Self.bugReportFailure, failed: failed, bugReportWork(), finished: finished)
        return true
    }

    /// The overlay of a task the Send feedback sheet started.
    var feedbackBusy: BusyState? { busyOverSheet ? busy : nil }
}

#endif
