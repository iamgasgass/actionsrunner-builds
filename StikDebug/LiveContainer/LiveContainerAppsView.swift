//
//  LiveContainerAppsView.swift
//  StikDebug (LiveContainer fork)
//
//  Same layout as the JIT tab (InstalledAppsListView): large title, always-visible
//  search, Favorites / Recents / app sections with 54 pt icons, and a feedback capsule.
//  Tapping an app enables JIT immediately: it opens in a LiveContainer Multitask
//  window and StikDebug attaches to that process.
//

import SwiftUI

struct LiveContainerAppsView: View {
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var controller = LiveContainerJITController.shared

    @AppStorage("lcRecentApps") private var recentApps: [String] = []
    @AppStorage("lcFavoriteApps") private var favoriteApps: [String] = []
    @AppStorage("lcShowHiddenApps") private var showHidden = false

    @State private var apps: [LiveContainerGuestApp] = []
    @State private var searchText = ""
    @State private var showHelp = false
    @State private var scriptPickerApp: LiveContainerGuestApp?
    /// Bumped when a script choice changes so rows re-read it.
    @State private var scriptChoicesVersion = 0

    private static let maxFavorites = 4
    private static let maxRecents = 3

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
            list
                .navigationTitle("LiveContainer")
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search apps or bundle ID".localized
                )
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Menu {
                            Toggle("Show Hidden Apps", isOn: $showHidden)
                            Button("How It Works", systemImage: "questionmark.circle") { showHelp = true }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                        .accessibilityLabel("Options")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            reload()
                            if !tunnel.isConnected { startTunnelInBackground() }
                        } label: {
                            if tunnel.isStarting {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .accessibilityLabel("Refresh")
                    }
                }
        }
        .overlay { LiveContainerOverlayView() }
        .onAppear {
            reload()
            // Warm up the device connection so tapping an app is instant.
            if !tunnel.isConnected { startTunnelInBackground(showErrorUI: false) }
        }
        .onChange(of: showHidden) { _, _ in reload() }
        .sheet(isPresented: $showHelp) { helpSheet }
        .sheet(item: $scriptPickerApp) { app in
            ScriptListView { url in
                if let url {
                    LiveContainerJITScript.setChoice(url.lastPathComponent, for: app)
                    Haptics.light()
                }
                scriptPickerApp = nil
                scriptChoicesVersion += 1
            }
        }
    }

    // MARK: - List

    private var list: some View {
        List {
            if !tunnel.isConnected || tunnel.isStarting || tunnel.connectionNotice != nil {
                Section {
                    DeviceConnectionStatusView()
                }
            }

            if !LiveContainerBridge.isRunningInLiveContainer {
                emptyState(
                    systemImage: "shippingbox",
                    title: "Not Running in LiveContainer",
                    message: "Install StikDebug inside LiveContainer to enable JIT for the apps installed there."
                )
            } else if filteredApps.isEmpty {
                emptyState(
                    systemImage: searchText.isEmpty ? "magnifyingglass" : "text.magnifyingglass",
                    title: searchText.isEmpty ? "No Apps Found" : "No matching apps".localized,
                    message: searchText.isEmpty
                        ? "Install apps in LiveContainer and they will appear here."
                        : "Try a different name or bundle identifier.".localized
                )
            } else {
                appSections
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { reload() }
    }

    @ViewBuilder
    private var appSections: some View {
        let visible = filteredApps
        let byID = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let favorites = favoriteApps.compactMap { byID[$0] }
        let recents = recentApps.filter { !favoriteApps.contains($0) }.compactMap { byID[$0] }

        if !favorites.isEmpty {
            Section(String(format: "Favorites (%d/4)".localized, favorites.count)) {
                ForEach(favorites) { appRow($0) }
            }
        }
        if !recents.isEmpty {
            Section("Recents".localized) {
                ForEach(recents) { appRow($0) }
            }
        }
        Section("Apps in this LiveContainer") {
            ForEach(visible) { appRow($0) }
        }
    }

    private func appRow(_ app: LiveContainerGuestApp) -> some View {
        let isFavorite = favoriteApps.contains(app.id)
        let isBusy = controller.busyAppID == app.id

        return Button {
            select(app)
        } label: {
            HStack(spacing: 16) {
                LiveContainerAppIconView(app: app)

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.displayName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(app.bundleIdentifier)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isBusy {
                    ProgressView()
                } else if isFavorite {
                    Image(systemName: "star.fill")
                        .imageScale(.medium)
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.isBusy && !isBusy)
        .contextMenu {
            Button {
                toggleFavorite(app)
            } label: {
                Label(isFavorite ? "Remove Favorite" : "Add to Favorites",
                      systemImage: isFavorite ? "star.slash" : "star")
            }
            .disabled(!isFavorite && favoriteApps.count >= Self.maxFavorites)
            Button {
                copyBundleID(app)
            } label: {
                Label("Copy Bundle ID", systemImage: "doc.on.doc")
            }
            scriptMenu(for: app)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                toggleFavorite(app)
            } label: {
                Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: "star")
            }
            .tint(.yellow)

            Button {
                copyBundleID(app)
            } label: {
                Label("Copy ID", systemImage: "doc.on.doc")
            }

            Button {
                scriptPickerApp = app
            } label: {
                Label("Script", systemImage: "chevron.left.slash.chevron.right")
            }
            .tint(.indigo)
        }
        .accessibilityLabel(String(format: "Enable JIT for %@".localized, app.displayName))
    }

    /// Same idea as "Assign Script" in the JIT tab. Without a choice the default order applies:
    /// LiveContainer script → script assigned in the JIT tab → automatic → universal.js (TXM).
    @ViewBuilder
    private func scriptMenu(for app: LiveContainerGuestApp) -> some View {
        let _ = scriptChoicesVersion
        let choice = LiveContainerJITScript.choice(for: app)
        let fallback = LiveContainerJITScript.defaultScript(for: app)
        let defaultTitle = "Default Order (\(fallback.script?.name ?? "No Script"))"

        Menu {
            Button {
                LiveContainerJITScript.setChoice(nil, for: app)
                scriptChoicesVersion += 1
            } label: {
                Label(defaultTitle, systemImage: choice == nil ? "checkmark" : "arrow.uturn.left")
            }
            Button {
                scriptPickerApp = app
            } label: {
                let chosenName = choice.flatMap { $0 == LiveContainerJITScript.noScriptChoice ? nil : $0 }
                Label(chosenName.map { "Assigned: \($0)" } ?? "Assign Script…",
                      systemImage: chosenName == nil ? "chevron.left.slash.chevron.right" : "checkmark")
            }
            Button {
                LiveContainerJITScript.setChoice(LiveContainerJITScript.noScriptChoice, for: app)
                scriptChoicesVersion += 1
            } label: {
                Label("No Script", systemImage: choice == LiveContainerJITScript.noScriptChoice ? "checkmark" : "nosign")
            }
        } label: {
            Label("Script: \(scriptSummary(for: app))", systemImage: "chevron.left.slash.chevron.right")
        }
    }

    private func scriptSummary(for app: LiveContainerGuestApp) -> String {
        let resolved = LiveContainerJITScript.resolve(for: app)
        guard let script = resolved.script else { return "None" }
        return "\(script.name) (\(resolved.source.label))"
    }

    private func emptyState(systemImage: String, title: String, message: String) -> some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 36, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private var helpSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("""
                    1. Install StikDebug inside LiveContainer and import your pairing file.
                    2. Turn on LocalDevVPN.
                    3. In LiveContainer settings, enable Multitask and keep the LiveProcess extension installed.
                    4. Tap an app here: it opens in a Multitask window with JIT enabled.

                    StikDebug can't relaunch the LiveContainer it lives in (that would close StikDebug itself), so the app runs in a separate LiveContainer process and StikDebug attaches to it. On devices that need a JIT script, the app's LiveContainer script, your assigned script or universal.js runs in the background; tap the Liquid Glass status pill to see its log. Long-press an app to choose its script (default order: LiveContainer script → script assigned in the JIT tab → automatic → universal.js).
                    """)
                    .font(.callout)
                }
                Section("Environment") {
                    LabeledContent("Host", value: LiveContainerBridge.hostBundleIdentifier ?? "—")
                    LabeledContent("StikDebug process",
                                   value: LiveContainerBridge.isRunningInLiveProcess ? "Multitask (LiveProcess)" : "Main LiveContainer process")
                    LabeledContent("JIT script required", value: ProcessInfo.processInfo.hasTXM ? "Yes (TXM)" : "No")
                }
            }
            .navigationTitle("How It Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showHelp = false }
                }
            }
        }
    }

    // MARK: - Actions

    private func reload() {
        apps = LiveContainerBridge.installedGuestApps(includeHidden: showHidden)
    }

    private func select(_ app: LiveContainerGuestApp) {
        guard !controller.isBusy else { return }
        Haptics.selection()
        recentApps.removeAll { $0 == app.id }
        recentApps.insert(app.id, at: 0)
        if recentApps.count > Self.maxRecents {
            recentApps = Array(recentApps.prefix(Self.maxRecents))
        }
        controller.enableJIT(for: app)
    }

    private func toggleFavorite(_ app: LiveContainerGuestApp) {
        Haptics.light()
        if favoriteApps.contains(app.id) {
            favoriteApps.removeAll { $0 == app.id }
        } else if favoriteApps.count < Self.maxFavorites {
            favoriteApps.insert(app.id, at: 0)
            recentApps.removeAll { $0 == app.id }
        }
    }

    private func copyBundleID(_ app: LiveContainerGuestApp) {
        UIPasteboard.general.string = app.bundleIdentifier
        Haptics.light()
    }
}

#Preview {
    LiveContainerAppsView()
}
