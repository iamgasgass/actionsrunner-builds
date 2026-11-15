// SPDX-License-Identifier: GPL-2.0-or-later
//
// WindowsiOS Universal: "Install Windows 11", laid out like Henge's Install tab:
// pick the version (language), name the account, choose memory, keep the app open.
import SwiftUI
import UniformTypeIdentifiers

struct InstallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var installer = WindowsInstaller.shared
    @State private var release: WindowsRelease? = WindowsCatalog.recommended
    @State private var user = "User"
    @State private var lite = WinIOSBridge.shared.physicalMemoryMB < 7000
    @State private var deleteAfter = true
    @State private var importing = false
    @State private var importError: String?
    @State private var useImported = FileManager.default.fileExists(atPath: WindowsInstaller.importedESD.path)
    @State private var confirmDelete: WindowsRelease?
    @State private var refresh = 0
    var onStartVM: () -> Void = {}

    private let bridge = WinIOSBridge.shared

    var body: some View {
        NavigationStack {
            Form {
                switch installer.phase {
                case .idle: chooser
                case .downloading, .verifying, .preparing, .installing, .waitingForJIT: progress
                case .done(let text): finished(text)
                case .failed(let text): failed(text)
                }
            }
            .navigationTitle(installer.busy ? "Installing" : "Install Windows 11")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(installer.busy ? "Hide" : "Close") { dismiss() }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                importESD(result)
            }
        }
    }

    // MARK: Choosing

    @ViewBuilder private var chooser: some View {
        Section {
            if WindowsCatalog.all.isEmpty {
                Text("This build has no download list. Import a Windows 11 ARM64 ESD instead (below).")
                    .foregroundStyle(.secondary)
            }
            ForEach(WindowsCatalog.all) { r in
                Button {
                    release = r
                    useImported = false
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(r.title) · \(r.language)").foregroundStyle(.primary)
                            Text(downloadNote(r)).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !useImported && release?.id == r.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                .swipeActions {
                    if WindowsInstaller.haveImage(r) || WindowsInstaller.partSize(r) > 0 {
                        Button("Delete", role: .destructive) { confirmDelete = r }
                    }
                }
            }
            .id(refresh)
            Button {
                importing = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Use a Windows image on this \(DeviceSupport.isPad ? "iPad" : "iPhone")…")
                        Text(useImported ? "Imported: \(WindowsInstaller.importedESD.lastPathComponent)" : "An ARM64 .esd from Microsoft (Files, iCloud)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if useImported { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
            }
            if let importError { Text(importError).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Version")
        } footer: {
            Text("Downloaded from Microsoft's servers. Windows 11 Pro, ARM64.")
        }
        .confirmationDialog("Delete this download?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete Download", role: .destructive) {
                if let r = confirmDelete { WindowsInstaller.deleteDownload(r) }
                confirmDelete = nil
                refresh += 1
            }
        }

        Section {
            TextField("Account name", text: $user)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            LabeledContent("Memory", value: "\(bridge.effectiveRamMB) MB · \(bridge.effectiveCPUs) vCPU")
            Toggle("Lite (faster on a phone)", isOn: $lite)
            Toggle("Delete the download after installing", isOn: $deleteAfter)
        } header: {
            Text("New PC")
        } footer: {
            Text("A local account with no password signs in by itself. Lite turns off Defender, indexing, updates in the background and preinstalled apps, as scripts/optimize_windows_lite.py does. Memory is set in the device settings.")
        }

        Section {
            Button {
                installer.start(useImported ? nil : release, user: user, lite: lite, deleteAfter: deleteAfter && !useImported)
            } label: {
                Text("Install Windows 11").frame(maxWidth: .infinity).fontWeight(.semibold)
            }
            .disabled(!canStart)
        } footer: {
            Text(startNote)
        }
    }

    private var canStart: Bool {
        !bridge.isChipTooOld && (useImported || release != nil) && WindowsInstaller.hasBundledFirmware
    }

    private var startNote: String {
        if bridge.isChipTooOld { return bridge.chipTooOldText }
        if !WindowsInstaller.hasBundledFirmware { return "This build has no UEFI firmware: build the app with the GitHub workflow." }
        let need = ByteCountFormatter.string(fromByteCount: WindowsInstaller.spaceNeeded(useImported ? nil : release), countStyle: .file)
        let free = ByteCountFormatter.string(fromByteCount: WindowsInstaller.freeSpace, countStyle: .file)
        let jit = bridge.isJITLive ? "" : " JIT is needed for the last step (the app asks then)."
        return "Keep WindowsiOS open and the \(DeviceSupport.isPad ? "iPad" : "iPhone") plugged in. Needs about \(need) free (\(free) free now).\(jit) The install takes 1–2 hours."
    }

    private func downloadNote(_ r: WindowsRelease) -> String {
        let size = ByteCountFormatter.string(fromByteCount: r.size, countStyle: .file)
        if WindowsInstaller.haveImage(r) { return "Downloaded, \(size)" }
        let part = WindowsInstaller.partSize(r)
        if part > 0 { return "\(ByteCountFormatter.string(fromByteCount: part, countStyle: .file)) of \(size) downloaded: goes on from there" }
        return "\(size) download"
    }

    private func importESD(_ result: Result<[URL], Error>) {
        importError = nil
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(at: WindowsInstaller.downloads, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: WindowsInstaller.importedESD)
            try FileManager.default.copyItem(at: url, to: WindowsInstaller.importedESD)
            var err: NSString?
            if bridge.inspectWindowsImage(WindowsInstaller.importedESD.path, error: &err) == nil {
                try? FileManager.default.removeItem(at: WindowsInstaller.importedESD)
                importError = (err as String?) ?? "Not a Windows 11 ARM64 image"
                useImported = false
                return
            }
            useImported = true
        } catch {
            importError = error.localizedDescription
        }
    }

    // MARK: Progress

    @ViewBuilder private var progress: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(installer.stage).font(.headline)
                if installer.phase == .downloading || installer.phase == .verifying || installer.phase == .preparing {
                    ProgressView(value: installer.fraction)
                    HStack {
                        Text("\(Int(installer.fraction * 100))%")
                        Spacer()
                        if installer.phase == .downloading {
                            Text("\(ByteCountFormatter.string(fromByteCount: installer.received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: installer.expected, countStyle: .file))")
                        }
                    }
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                if installer.phase == .installing {
                    Text("Windows is installing in the VM. You can watch it: close this sheet. It turns off by itself when it is done (1–2 hours).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Keep WindowsiOS open and the device plugged in.")
        }

        Section("Steps") {
            step("Download", done: installer.phase != .downloading, active: installer.phase == .downloading)
            step("Check", done: [.preparing, .waitingForJIT, .installing].contains(installer.phase), active: installer.phase == .verifying)
            step("Prepare the installer", done: [.waitingForJIT, .installing].contains(installer.phase), active: installer.phase == .preparing)
            step("Install Windows (Windows PE)", done: false, active: installer.phase == .installing)
            step("First setup (automatic)", done: false, active: false)
        }

        if installer.phase == .waitingForJIT {
            Section {
                Button("Enable JIT (StikDebug)") { VMViewModel.openStikDebug() }
                Button("JIT is on: install") {
                    installer.launchInstall()
                    if installer.phase == .installing { onStartVM(); dismiss() }
                }
            } footer: {
                Text("The installer is ready. Windows runs in the VM, which needs JIT.")
            }
        }
        if installer.phase == .downloading || installer.phase == .verifying {
            Section { Button("Stop", role: .destructive) { installer.cancel() } }
        }
        logSection
    }

    private func step(_ title: String, done: Bool, active: Bool) -> some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : active ? "circle.dotted" : "circle")
                .foregroundStyle(done ? Color.green : active ? Color.accentColor : Color.secondary)
            Text(title).foregroundStyle(active ? .primary : .secondary)
        }
    }

    @ViewBuilder private var logSection: some View {
        if !installer.log.isEmpty {
            Section("Log") {
                ForEach(Array(installer.log.suffix(30).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Results

    @ViewBuilder private func finished(_ text: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Installed", systemImage: "checkmark.seal.fill").font(.title2.bold()).foregroundStyle(.green)
                Text(text)
            }
            .padding(.vertical, 6)
        }
        logSection
    }

    @ViewBuilder private func failed(_ text: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("It did not work").font(.title2.bold())
                Text(text)
            }
            .padding(.vertical, 6)
            Button("Try Again") { installer.reset() }
        }
        logSection
    }
}
