// SPDX-License-Identifier: GPL-2.0-or-later

#if FEEDBACK_MAIL

import AndariumCore
import Foundation

/// The basic information at the end of the mail: plain text, English keys
/// whatever the interface language, since the receiver reads it. It holds
/// nothing that singles out the device or the person: no device name, no
/// vendor identifier, no account and no path, which this type has no field for.
nonisolated struct SendFeedbackInformation: Equatable, Sendable {
    /// The virtual machine's settings.
    struct VirtualMachine: Equatable, Sendable {
        var vcpus: Int
        var memoryMiB: Int
        /// How the display is set, in plain words ("1206 x 2622 px, 480 dpi").
        var display: String
        /// The loader's estimate of graphics memory for these settings.
        var graphicsMiB: Int?
    }

    /// A start that has not reached Android: where it is and for how long,
    /// when the mail is written from the boot screen's notice.
    struct Boot: Equatable, Sendable {
        /// The step the boot screen names, in English.
        var step: String
        var seconds: Int
        /// How many times the virtual machine restarted itself in the start.
        var restarts: Int
    }

    var appVersion: String
    var build: String
    var configuration: String
    /// The hardware's machine identifier ("iPhone18,1"); the Mac's model for
    /// an iPad app on a Mac; nil or empty when it cannot be read.
    var deviceModel: String?
    /// The app is the iPad app running on a Mac ("Designed for iPad").
    var runsOnMac = false
    var systemVersion: String
    var language: String
    /// nil before a virtual machine is created.
    var virtualMachine: VirtualMachine?
    var androidRelease: String
    /// Seconds the virtual machine has run; nil while none runs.
    var runningSeconds: Int?
    /// nil unless a start is under way.
    var boot: Boot?
    /// The free space as the application shows it.
    var freeSpaceBytes: UInt64
    var thermalState: String
    /// Settings' "When hot": on limits the frame rate while the device is hot,
    /// off tells Android nothing of the heat.
    var heatLimitOn = true

    /// The device line's value: never empty, and never an iPhone's identifier
    /// for a Mac. What is known is said when the model is not.
    var deviceText: String {
        let model = deviceModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (model.isEmpty, runsOnMac) {
        case (false, false): return model
        case (false, true): return "\(model), iPad app on a Mac"
        case (true, true): return "a Mac, iPad app"
        case (true, false): return "unknown"
        }
    }

    var lines: [String] {
        var lines = [
            "App: Andarium \(appVersion) (\(build)), \(configuration)",
            "Device: \(deviceText)",
            "iOS: \(systemVersion)",
            "Language: \(language)",
        ]
        if let machine = virtualMachine {
            var line = "Virtual machine: \(Formats.vcpus(machine.vcpus)), \(Formats.size(mib: machine.memoryMiB)) memory"
            line += ", display \(machine.display)"
            if let graphics = machine.graphicsMiB { line += ", graphics memory about \(Formats.size(mib: graphics))" }
            lines.append(line)
        } else {
            lines.append("Virtual machine: not created")
        }
        lines.append("Android: \(androidRelease)")
        lines.append("Running: \(runningSeconds.map { "yes, for \(Self.duration($0))" } ?? "no")")
        if let boot {
            var line = "Boot: not finished, at \(boot.step) after \(Self.duration(boot.seconds))"
            if boot.restarts > 0 { line += ", restarted \(boot.restarts) time\(boot.restarts == 1 ? "" : "s")" }
            lines.append(line)
        }
        lines.append("Free space: \(Formats.size(bytes: freeSpaceBytes))")
        lines.append("Thermal state: \(thermalState)")
        lines.append("Frame rate limit when hot: \(HeatLimitWords.state(isOn: heatLimitOn))")
        return lines.map(Self.oneLine)
    }

    var text: String { lines.joined(separator: "\n") }

    /// "45 s", "42 min" or "1 h 12 min".
    static func duration(_ seconds: Int) -> String {
        let seconds = max(seconds, 0)
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
    }
}

#endif
