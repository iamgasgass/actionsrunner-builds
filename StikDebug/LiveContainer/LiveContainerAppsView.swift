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
    @ObservedObject private var controller = LiveContainerJITController.shared

    @State private var apps: [LiveContainerGuestApp] = []
    @State private var searchText = ""
    @State private var showHidden = false
    @State private var pendingApp: LiveContainerGuestApp?

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

                    Section {
                        Toggle("Show Hidden Apps", isOn: $showHidden)
                    }
                }

                howItWorksSection
            }
            .searchable(text: $searchText)
            .navigationTitle("LiveContainer")
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
                    controller.enableJIT(for: app)
                }
                Button("Cancel", role: .cancel) { pendingApp = nil }
            } message: { app in
                Text("\(app.displayName) will open in a LiveContainer Multitask window and StikDebug will enable JIT for it. If it is already open, it will be restarted.")
            }
            .sheet(item: $controller.scriptRunModel) { model in
                NavigationStack {
                    RunJSView(model: model)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { controller.scriptRunModel = nil }
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
            LabeledContent("JIT script required", value: ProcessInfo.processInfo.hasTXM ? "Yes (TXM)" : "No")
            if let message = controller.statusMessage {
                Label(message, systemImage: controller.lastResultIsError ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.footnote)
                    .foregroundStyle(controller.lastResultIsError ? .red : .secondary)
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

            StikDebug can't relaunch the LiveContainer it lives in (that would close StikDebug itself), so the app is started in a separate LiveContainer process and StikDebug attaches to it by PID. On devices that need a JIT script, the app's LiveContainer JIT script, your assigned script or universal.js is used.
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
                    let tags = tags(for: app)
                    if !tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(tags, id: \.self) { tag($0) }
                        }
                    }
                }
                Spacer()
                if controller.busyAppID == app.id {
                    ProgressView()
                } else {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.tint)
                }
            }
        }
        .disabled(controller.isBusy)
    }

    private func tags(for app: LiveContainerGuestApp) -> [String] {
        var tags: [String] = []
        if app.isShared { tags.append("Shared") }
        if app.isJITNeeded { tags.append("Run with JIT") }
        if app.jitLaunchScript != nil { tags.append("LC Script") }
        return tags
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }

    private func reload() {
        apps = LiveContainerBridge.installedGuestApps(includeHidden: showHidden)
    }
}

#Preview {
    LiveContainerAppsView()
}
