//
//  LiveContainerAppsView.swift
//  StikDebug (LiveContainer fork)
//
//  Lists the apps installed in the LiveContainer that is hosting StikDebug and
//  launches one of them with JIT in a LiveContainer Multitask (LiveProcess)
//  window, attaching StikDebug's debugger to that process.
//

import SwiftUI

struct LiveContainerAppsView: View {
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mounting = MountingProgress.shared

    @State private var apps: [LiveContainerGuestApp] = []
    @State private var searchText = ""
    @State private var showHidden = false
    @State private var pendingApp: LiveContainerGuestApp?
    @State private var busyAppID: String?
    @State private var statusMessage: String?
    @State private var scriptRunModel: RunJSViewModel?

    private var filteredApps: [LiveContainerGuestApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.displayName.localizedCaseInsensitiveContains(query) ||
            $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                statusSection

                if LiveContainerBridge.isRunningInLiveContainer {
                    Section {
                        if filteredApps.isEmpty {
                            Text(apps.isEmpty ? "No apps found in this LiveContainer." : "No matching apps.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(filteredApps) { app in
                            appRow(app)
                        }
                    } header: {
                        Text("Apps in this LiveContainer")
                    } footer: {
                        Text("The app opens in a LiveContainer Multitask window and StikDebug attaches to it. Keep StikDebug open until the JIT request completes.")
                    }
                }

                howItWorksSection
            }
            .searchable(text: $searchText)
            .navigationTitle("LiveContainer")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Show Hidden Apps", isOn: $showHidden)
                        Button("Reload", systemImage: "arrow.clockwise", action: reload)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear {
                reload()
                startTunnelInBackground(showErrorUI: false)
            }
            .onChange(of: showHidden) { _, _ in reload() }
            .refreshable { reload() }
            .confirmationDialog(
                "Launch with JIT?",
                isPresented: Binding(
                    get: { pendingApp != nil },
                    set: { if !$0 { pendingApp = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingApp
            ) { app in
                Button("Launch \(app.displayName) with JIT") {
                    pendingApp = nil
                    launch(app)
                }
                Button("Cancel", role: .cancel) { pendingApp = nil }
            } message: { app in
                Text("\(app.displayName) will open in a LiveContainer Multitask window and StikDebug will enable JIT for it.")
            }
            .sheet(item: $scriptRunModel) { model in
                NavigationStack {
                    RunJSView(model: model)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { scriptRunModel = nil }
                            }
                        }
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var statusSection: some View {
        Section("Environment") {
            LabeledContent("Running in LiveContainer",
                           value: LiveContainerBridge.isRunningInLiveContainer ? "Yes" : "No")
            if LiveContainerBridge.isRunningInLiveContainer {
                LabeledContent("Host", value: LiveContainerBridge.hostBundleIdentifier ?? "Unknown")
                LabeledContent("StikDebug process",
                               value: LiveContainerBridge.isRunningInLiveProcess ? "Multitask (LiveProcess)" : "Main LiveContainer process")
            }
            LabeledContent("Device connection", value: tunnel.isConnected ? "Connected" : "Not connected")
            LabeledContent("Developer Disk Image", value: mounting.coolisMounted ? "Mounted" : "Not mounted")
            if !LiveContainerBridge.multitaskJITSupported {
                Text("JIT in a Multitask window needs iOS 17.4 or newer.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var howItWorksSection: some View {
        Section("How it works") {
            Text("""
            1. Install StikDebug inside LiveContainer (shared or private app) and import your pairing file in StikDebug.
            2. Turn on LocalDevVPN.
            3. In LiveContainer settings, enable Multitask and keep the LiveProcess extension installed.
            4. Open StikDebug from LiveContainer, choose an app here and tap it.

            StikDebug can't relaunch the LiveContainer it lives in (that would close StikDebug itself), so the app is started in a separate LiveContainer process and StikDebug attaches to it by PID.
            """)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func appRow(_ app: LiveContainerGuestApp) -> some View {
        Button {
            pendingApp = app
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.displayName)
                        .foregroundStyle(.primary)
                    Text(app.bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if app.isShared { tag("Shared") }
                        if app.isJITNeeded { tag("Run with JIT") }
                        if app.jitLaunchScript != nil { tag("Script") }
                    }
                }
                Spacer()
                if busyAppID == app.id {
                    ProgressView()
                } else {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(busyAppID != nil)
    }

    private func tag(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }

    // MARK: - Actions

    private func reload() {
        apps = LiveContainerBridge.installedGuestApps(includeHidden: showHidden)
    }

    private func launch(_ app: LiveContainerGuestApp) {
        busyAppID = app.id
        statusMessage = "Waiting for device connection…"
        Haptics.medium()
        LogManager.shared.addInfoLog("[LiveContainer] Launching \(app.displayName) (\(app.relativeBundlePath)) with JIT in the same LiveContainer")

        Task { @MainActor in
            let ready = await Task.detached(priority: .userInitiated) {
                Self.waitForJITPrerequisites()
            }.value
            guard ready else {
                finish(error: "The device connection or Developer Disk Image wasn't ready in time. Make sure LocalDevVPN is on and the pairing file is imported, then try again.")
                return
            }

            statusMessage = "Starting \(app.displayName) in Multitask…"
            let pid: Int32
            do {
                pid = try await LiveContainerBridge.launchInMultitask(app)
            } catch {
                finish(error: error.localizedDescription)
                return
            }

            guard !LiveContainerBridge.isOwnProcess(pid: pid) else {
                finish(error: "LiveContainer returned StikDebug's own process. Enable Multitask in LiveContainer settings and try again.")
                return
            }

            statusMessage = "Attaching to \(app.displayName) (PID \(pid))…"
            LogManager.shared.addInfoLog("[LiveContainer] \(app.displayName) is running as PID \(pid)")
            attach(pid: pid, app: app)
        }
    }

    private func attach(pid: Int32, app: LiveContainerGuestApp) {
        var script: (data: Data, name: String)?
        if let data = app.jitLaunchScript {
            script = (data, "\(app.displayName) (LiveContainer)")
        } else if let preferred = ScriptStore.preferredScript(for: app.bundleIdentifier) {
            script = preferred
        }

        var callback: DebugAppCallback?
        if ProcessInfo.processInfo.hasTXM, let script {
            callback = { pid, debugProxy, remoteServer, semaphore in
                // No resumeBundleID: the target lives in this LiveContainer, relaunching
                // the host bundle would terminate StikDebug.
                let model = RunJSViewModel(pid: Int(pid), debugProxy: debugProxy,
                                           remoteServer: remoteServer, semaphore: semaphore,
                                           resumeBundleID: nil)
                DispatchQueue.main.async { scriptRunModel = model }
                do {
                    try model.runScript(data: script.data, name: script.name)
                } catch {
                    semaphore.signal()
                    DispatchQueue.main.async {
                        showAlert(title: "Error Occurred While Executing Script.".localized,
                                  message: error.localizedDescription, showOk: true)
                    }
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let keepAlive = DebugKeepAliveLease()
            defer { keepAlive.invalidate() }

            var lastMessage: String?
            let logger: LogFunc = { message in
                if let message {
                    lastMessage = message
                    LogManager.shared.addInfoLog(message)
                }
            }
            let success = JITEnableContext.shared.debugApp(withPID: pid, logger: logger, jsCallback: callback)
            DispatchQueue.main.async {
                if success {
                    finish(message: "JIT enabled for \(app.displayName). Switch to its Multitask window.")
                } else {
                    finish(error: lastMessage ?? "StikDebug could not attach to \(app.displayName).")
                }
            }
        }
    }

    private func finish(message: String) {
        busyAppID = nil
        statusMessage = message
        Haptics.light()
        AccessibilityAnnouncer.announce(message)
    }

    private func finish(error: String) {
        busyAppID = nil
        statusMessage = error
        LogManager.shared.addErrorLog("[LiveContainer] \(error)")
        showAlert(title: "Failed to Enable JIT".localized, message: error, showOk: true)
    }

    nonisolated private static func waitForJITPrerequisites(timeout: TimeInterval = 25) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if TunnelManager.shared.isConnected && MountingProgress.shared.coolisMounted {
                return true
            }
            usleep(250_000)
        }
        return TunnelManager.shared.isConnected && MountingProgress.shared.coolisMounted
    }
}

#Preview {
    LiveContainerAppsView()
}
