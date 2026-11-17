import SwiftUI
import UIKit

struct DeviceSelector: View {
    @EnvironmentObject private var viewModel: GestaltViewModel
    @ObservedObject var watch: WatchConnection
    @State private var showsInstallation = false
    @State private var pendingDevice: GestaltViewModel.Device?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            selectorHeader

            if viewModel.isDeviceSelectorExpanded {
                VStack(spacing: 10) {
                    Button { select(.iPhone) } label: {
                        deviceRow(localDeviceName,
                                  icon: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone",
                                  status: viewModel.selectedDevice == .iPhone
                                      ? (viewModel.plist == nil ? String(localized: "Not Connected") : String(localized: "Connected"))
                                      : nil,
                                  selected: viewModel.selectedDevice == .iPhone,
                                  connected: viewModel.selectedDevice == .iPhone && viewModel.plist != nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("device-selector-iphone")
                    .disabled(viewModel.isBusy)

                    Button {
                        if watch.isPaired && watch.isInstalled && watch.isReachable {
                            select(.appleWatch)
                        } else {
                            showsInstallation = true
                        }
                    } label: {
                        deviceRow(watch.name, icon: "applewatch", status: watchStatus,
                                  selected: viewModel.selectedDevice == .appleWatch,
                                  connected: watch.isPaired && watch.isInstalled && watch.isReachable)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("device-selector-watch")
                    .disabled(viewModel.isBusy)
                }
                .transition(.opacity)
            }
        }
        .glassSection()
    }

    // Keep presentation modifiers on one stable List row. A Group forwards
    // them to every child, creating competing sheet presentation hosts.
    private var selectorHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { viewModel.isDeviceSelectorExpanded.toggle() }
        } label: {
            HStack(alignment: .center, spacing: 0) {
                GlassSectionHeading(
                    title: String(localized: "Devices"),
                    subtitle: viewModel.selectedDevice == .appleWatch ? watch.name : localDeviceName,
                    symbol: "externaldrive.connected.to.line.below"
                )
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(viewModel.isDeviceSelectorExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("device-selector-toggle")
        .confirmationDialog("Discard Pending Changes?", isPresented: Binding(
            get: { pendingDevice != nil }, set: { if !$0 { pendingDevice = nil } }
        ), titleVisibility: .visible) {
            Button("Discard and Switch", role: .destructive) {
                if let pendingDevice { viewModel.selectDevice(pendingDevice) }
                pendingDevice = nil
            }
            Button("Cancel", role: .cancel) { pendingDevice = nil }
        }
        .onAppear { watch.refresh() }
        .onChange(of: viewModel.isDeviceSelectorExpanded) { _, expanded in
            if expanded { watch.refresh() }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { watch.refresh() } }
        .sheet(isPresented: $showsInstallation) {
            NavigationStack {
                GlassScreen(spacing: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        GlassSectionHeading(
                            title: watch.isPaired
                                ? (watch.isInstalled ? String(localized: "Connect Apple Watch") : String(localized: "Install Watch Helper"))
                                : String(localized: "Set Up Apple Watch"),
                            symbol: "applewatch"
                        )
                        Group {
                            if !watch.isPaired {
                                Text("Open the Watch app on this iPhone and pair your Apple Watch first.")
                            } else if !watch.isInstalled {
                                Text("Open the Watch app on this iPhone, find GestAltX in Available Apps, and tap Install. Then open GestAltX Helper on your Apple Watch.")
                            } else {
                                Text("Open GestAltX Helper on your Apple Watch and keep it nearby, then reload.")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        if watch.isPaired && watch.isInstalled {
                            Button {
                                showsInstallation = false
                                if viewModel.selectedDevice == .appleWatch { viewModel.load() }
                                else { select(.appleWatch) }
                            } label: {
                                Label("Connect", systemImage: "link")
                            }
                            .buttonStyle(LiquidGlassButtonStyle(prominent: true))
                            .disabled(!watch.isReachable || viewModel.isBusy)
                        } else {
                            Button {
                                UIApplication.shared.open(URL(string: "itms-watchs://")!) { opened in
                                    if opened { showsInstallation = false }
                                }
                            } label: {
                                Label("Open Watch App", systemImage: "applewatch")
                            }
                            .buttonStyle(LiquidGlassButtonStyle(prominent: true))
                        }
                    }
                    .glassSection()
                }
                .navigationTitle(watch.isPaired
                                 ? (watch.isInstalled ? String(localized: "Connect Apple Watch") : String(localized: "Install Watch Helper"))
                                 : String(localized: "Set Up Apple Watch"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showsInstallation = false } } }
            }
            .tint(Color.glassInk)
            .presentationDetents([.medium, .large])
        }
    }

    private var localDeviceName: String {
        AIRegionProfile.currentDeviceMarketingName ?? UIDevice.current.model
    }

    private func select(_ device: GestaltViewModel.Device) {
        guard device != viewModel.selectedDevice else { return }
        if viewModel.isDirty || viewModel.hasStagedTweaks { pendingDevice = device }
        else {
            viewModel.selectDevice(device)
        }
    }

    private var watchStatus: String {
        if !watch.isPaired { return String(localized: "Not Paired") }
        if !watch.isInstalled { return String(localized: "Not Installed") }
        return watch.isReachable ? String(localized: "Connected") : String(localized: "Offline")
    }

    private func deviceRow(_ title: String, icon: String, status: String?, selected: Bool, connected: Bool) -> some View {
        HStack(spacing: 14) {
            GlassIconBadge(symbol: icon, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(connected ? Color.green : Color.secondary)
                }
            }
            Spacer(minLength: 4)
            if selected && viewModel.isBusy {
                ProgressView().controlSize(.small).tint(Color.glassInk)
            } else {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(selected ? Color.glassInk.opacity(0.92) : Color.glassLine.opacity(0.35))
                    .accessibilityHidden(true)
            }
        }
        .glassRow()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
