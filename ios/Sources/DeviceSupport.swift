// SPDX-License-Identifier: GPL-2.0-or-later
//
// WindowsiOS Universal: what this device is and what it can give Windows.
// The numbers come from the native profile (Sources/Native/winios_device.c);
// this file adds marketing names, the foldable check and the settings sheet.
import SwiftUI
import UIKit

@MainActor
enum DeviceSupport {
    static var modelIdentifier: String { WinIOSBridge.shared.deviceModelIdentifier }

    /// Marketing name for the model identifier, or the identifier itself when unknown.
    static var marketingName: String { names[modelIdentifier] ?? modelIdentifier }

    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// A foldable (iPhone Duo) has a hinge sensor. Every other iPhone and iPad does not,
    /// so the posture logic must not wait for hinge updates there.
    static var hasHingeSensor: Bool {
        modelIdentifier == "iPhone19,4"
    }

    static var physicalMemoryGB: Int { Int((Double(WinIOSBridge.shared.physicalMemoryMB) / 1024.0).rounded()) }

    /// Shown in the boot card: "iPhone 13 Pro · 6 GB · 2560 MB / 4 vCPU".
    static var summaryLine: String {
        let b = WinIOSBridge.shared
        return "\(marketingName) · \(physicalMemoryGB) GB · \(b.effectiveRamMB) MB / \(b.effectiveCPUs) vCPU"
    }

    /// A14 (iPhone 12) and later, as Henge. Older chips lack the Armv8.5 instructions the guest uses.
    static var isSupported: Bool { !WinIOSBridge.shared.isChipTooOld }

    static var isExperimental: Bool { WinIOSBridge.shared.physicalMemoryMB < 5000 }

    /// iPhone identifiers (adamawolf/3048717, AppleDB). Newer models fall back to the identifier.
    static let names: [String: String] = [
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd gen)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro",
        "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro",
        "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,6": "iPhone SE (3rd gen)",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,5": "iPhone 16e",
        "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air", "iPhone18,1": "iPhone 17 Pro",
        "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone19,4": "iPhone Duo",
    ]
}

/// Guest RAM and vCPU choices. Changes apply the next time the app is launched with JIT,
/// because guest RAM is reserved while the debugger is attached.
struct DeviceSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var ramMB: Double
    @State private var cpus: Double
    @State private var automatic: Bool

    private let bridge = WinIOSBridge.shared

    init() {
        let b = WinIOSBridge.shared
        let savedRam = UserDefaults.standard.integer(forKey: "winios.ramMB")
        let savedCpus = UserDefaults.standard.integer(forKey: "winios.cpus")
        _automatic = State(initialValue: savedRam == 0 && savedCpus == 0)
        _ramMB = State(initialValue: Double(b.effectiveRamMB))
        _cpus = State(initialValue: Double(b.effectiveCPUs))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    LabeledContent("Model", value: "\(DeviceSupport.marketingName) (\(DeviceSupport.modelIdentifier))")
                    LabeledContent("Memory", value: "\(DeviceSupport.physicalMemoryGB) GB")
                    LabeledContent("CPU cores", value: "\(bridge.hostCPUs)")
                    LabeledContent("JIT region", value: "\(bridge.jitRegionMB) MB")
                    if !DeviceSupport.isSupported {
                        Text(bridge.chipTooOldText).foregroundStyle(.orange)
                    } else if DeviceSupport.isExperimental {
                        Text("4 GB devices are experimental: use the Windows 11 lite image (scripts/optimize_windows_lite.py) and close other apps.")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Toggle("Automatic (recommended)", isOn: $automatic)
                    if !automatic {
                        VStack(alignment: .leading) {
                            Text("Guest RAM: \(Int(ramMB)) MB")
                            Slider(value: $ramMB, in: 1536...Double(max(bridge.maxRamMB, 1536)), step: 512)
                        }
                        Stepper("vCPUs: \(Int(cpus))", value: $cpus, in: 1...Double(max(1, min(8, bridge.hostCPUs))))
                    }
                } header: {
                    Text("Windows")
                } footer: {
                    Text("Recommended for this device: \(bridge.recommendedRamMB) MB, \(bridge.recommendedCPUs) vCPU. Changes apply the next time WindowsiOS starts with JIT enabled.")
                }
            }
            .navigationTitle("Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if automatic {
                            bridge.setRamOverrideMB(0, cpus: 0)
                        } else {
                            bridge.setRamOverrideMB(UInt64(ramMB), cpus: Int(cpus))
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}
