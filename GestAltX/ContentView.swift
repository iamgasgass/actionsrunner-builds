import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var viewModel: GestaltViewModel
    @State private var selection = 0
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        ZStack {
            AppGlassBackground()

            if !GestaltAccess.supportsDeviceAccess {
                NavigationStack { UnsupportedSystemView() }
                    .tint(Color.glassInk)
            } else {
                TabView(selection: $selection) {
                    NavigationStack { TweakWorkbench() }
                        .tabItem { Label("Tools", systemImage: "switch.2") }
                        .tag(0)

                    NavigationStack { AdvancedGestaltEditor().id(viewModel.deviceContextID) }
                        .tabItem { Label("Fields", systemImage: "list.bullet.rectangle") }
                        .tag(1)

                    NavigationStack { BackupLibrary().id(viewModel.deviceContextID) }
                        .tabItem { Label("Restore", systemImage: "archivebox") }
                        .tag(2)

                    NavigationStack { SettingsView() }
                        .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                        .tag(3)
                }
                .tint(Color.glassInk)
                .disabled(viewModel.isBusy)
                .task { viewModel.load() }
            }
        }
        .overlay {
            if viewModel.isRespringing {
                NeoSpringView()
            }
        }
        .alert(item: $viewModel.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear { AppAppearance.apply(appearance) }
        .onChange(of: appearance) { _, newValue in AppAppearance.apply(newValue) }
    }
}

// MARK: - Sistema non supportato

private struct UnsupportedSystemView: View {
    var body: some View {
        GlassScreen {
            GlassHeroCard(eyebrow: "GESTALTX", title: "MobileGestalt,\non device.",
                          subtitle: "Presets, field editor and backups")
            GlassEmptyState(
                symbol: "iphone.slash",
                title: String(localized: "iOS 26 Is Not Supported"),
                message: String(localized: "On-device MobileGestalt editing requires iOS / iPadOS 27 or later. iOS / iPadOS 26 is not supported.")
            )
        }
        .navigationTitle("GestAltX")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Strumenti

private struct TweakWorkbench: View {
    @EnvironmentObject private var viewModel: GestaltViewModel

    var body: some View {
        GlassScreen(spacing: 16) {
            GlassHeroCard(eyebrow: "GESTALTX", title: "MobileGestalt,\non device.",
                          subtitle: "Presets, field editor and backups")

            DeviceSelector(watch: viewModel.watch)

            if viewModel.plist == nil { deviceStatus }

            if viewModel.selectedDevice == .appleWatch {
                WatchToolsSections()
                    .disabled(viewModel.plist == nil)
            } else if viewModel.plist != nil {
                tweakSection(.region)
                dynamicIslandSection
                tweakSection(.display)
                tweakSection(.ipad)
                tweakSection(.hardware)
                tweakSection(.audio)

                VStack(alignment: .leading, spacing: 14) {
                    GlassSectionHeading(title: String(localized: "Advanced"),
                                        subtitle: String(localized: "Settings shortcuts, internal flags and device name."),
                                        symbol: "wrench.and.screwdriver")
                    GlassRows {
                        GlassDisclosure(title: String(localized: "Settings Shortcuts"), symbol: "gearshape") {
                            tweakRows(.settings)
                        }
                        GlassDisclosure(title: String(localized: "Internal & Research"), symbol: "flask") {
                            tweakRows(.internalFeatures)
                        }
                        GlassDisclosure(title: String(localized: "Device Name"), symbol: "character.cursor.ibeam") {
                            modelNameControls
                        }
                    }
                }
                .glassSection()
            }
        }
        .navigationTitle("GestAltX")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { viewModel.load() }
        .safeAreaInset(edge: .bottom) {
            if viewModel.hasStagedTweaks {
                applyBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: viewModel.hasStagedTweaks)
    }

    private func symbol(for category: GestaltTweakCategory) -> String {
        switch category {
        case .region: "globe"
        case .display: "sparkles.rectangle.stack"
        case .ipad: "ipad.landscape"
        case .hardware: "cpu"
        case .audio: "speaker.wave.2.fill"
        case .settings: "gearshape"
        case .internalFeatures: "flask"
        }
    }

    private func tweakSection(_ category: GestaltTweakCategory) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassSectionHeading(title: category.label, symbol: symbol(for: category))
            GlassRows {
                if category == .ipad {
                    tweakRow(.iPadOS)
                    if isPhone {
                        stageManagerOnPhoneNote
                    }
                    GlassDisclosure(title: String(localized: "Individual iPad Options"), symbol: "square.split.2x1") {
                        // On iPhone the standalone key does nothing (Nugget hides it there):
                        // it is only listed when already written, so it can be removed.
                        if !isPhone || (viewModel.isApplied(.stageManager) && !viewModel.isIncludedInIPadOS(.stageManager)) {
                            tweakRow(.stageManager)
                        }
                        tweakRow(.iPadApps)
                    }
                } else {
                    tweakRows(category)
                }
                if category == .display {
                    GlassPickerRow(String(localized: "Liquid Glass"), selection: Binding<Int>(
                        get: {
                            if viewModel.isTweakOn(.enableLiquidGlassLowPerformance) { return 1 }
                            if viewModel.isTweakOn(.disableLiquidGlassLowPerformance) { return 0 }
                            return -1
                        },
                        set: { value in
                            viewModel.setTweak(.enableLiquidGlassLowPerformance, enabled: false)
                            viewModel.setTweak(.disableLiquidGlassLowPerformance, enabled: false)
                            if value >= 0 {
                                viewModel.setTweak(value == 1 ? .enableLiquidGlassLowPerformance : .disableLiquidGlassLowPerformance, enabled: true)
                            }
                        }
                    )) {
                        Text("Default").tag(-1)
                        Text("Reduced Effects").tag(1)
                        Text("Full Effects").tag(0)
                    }
                    GlassDisclosure(title: String(localized: "AOD Options"), symbol: "clock") {
                        tweakRow(.alwaysOnDisplayVibrancy)
                        tweakRow(.aodHighLuminance)
                        tweakRow(.aodFlipbook)
                    }
                }
                if category == .region {
                    Toggle(
                        isOn: Binding(
                            get: { viewModel.stagesAIRegion },
                            set: { viewModel.setAIRegion(enabled: $0) }
                        )
                    ) {
                        HStack(spacing: 6) {
                            Text("Enable Siri AI")
                            if viewModel.requiresForcedAIEnable { GlassRiskBadge() }
                        }
                    }
                    .glassToggle()

                    GlassPickerRow(String(localized: "Device Region"), selection: Binding<String?>(
                        get: { viewModel.stagedAIRegionPresetID },
                        set: { viewModel.setRegionPreset($0) }
                    )) {
                        Text("No Change").tag(String?.none)
                        ForEach(GestaltRegionPreset.all) { region in
                            Text(region.title).tag(String?.some(region.id))
                        }
                    }
                    .disabled(viewModel.stagesAIRegion)
                    .opacity(viewModel.stagesAIRegion ? 0.48 : 1)
                }
            }
        }
        .glassSection()
    }

    private func tweakRows(_ category: GestaltTweakCategory) -> some View {
        let customControls: Set<GestaltTweakID> = [
            .supportsDynamicIsland, .alwaysOnDisplayVibrancy, .aodHighLuminance, .aodFlipbook,
            .enableLiquidGlassLowPerformance, .disableLiquidGlassLowPerformance
        ]
        let definitions = GestaltTweakCatalog.definitions.filter {
            $0.category == category && !customControls.contains($0.id) && $0.isAvailable()
        }
        return ForEach(definitions) { definition in
            tweakRow(definition.id)
        }
    }

    @ViewBuilder
    private func tweakRow(_ id: GestaltTweakID) -> some View {
        if let definition = GestaltTweakCatalog.definition(for: id), definition.isAvailable() {
            let included = viewModel.isIncludedInIPadOS(id)
            TweakToggle(
                definition: definition,
                isOn: Binding(
                    get: { viewModel.isTweakOn(id) },
                    set: { viewModel.setTweak(id, enabled: $0) }
                ),
                included: included,
                state: tweakState(id, included: included),
                warning: definition.requiresIPad && isPhone
                    ? String(localized: "No effect on iPhone: use iPadOS Mode.")
                    : nil
            )
        }
    }

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    private func tweakState(_ id: GestaltTweakID, included: Bool) -> TweakState {
        if viewModel.revertedTweaks.contains(id) { return .willRemove }
        if included { return viewModel.isActive(.iPadOS) ? .active : .willApply }
        if viewModel.selectedTweaks.contains(id) { return .willApply }
        if viewModel.isApplied(id) { return viewModel.isOriginalValue(id) ? .original : .active }
        return .off
    }

    private var stageManagerOnPhoneNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "rectangle.3.group")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text("On iPhone, Stage Manager works only with iPadOS Mode. After applying, restart the iPhone and turn on Stage Manager in Control Center or Settings › Multitasking & Gestures.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var deviceStatus: some View {
        if viewModel.isBusy || !viewModel.hasAttemptedLoad {
            HStack(spacing: 13) {
                ProgressView().tint(Color.glassInk)
                Text("Reading MobileGestalt…")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
            }
            .glassSection(cornerRadius: 24)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeading(title: String(localized: "Unable to read MobileGestalt"),
                                    subtitle: String(localized: "Check that the device is supported, then try again."),
                                    symbol: "exclamationmark.triangle.fill")
                Button(action: viewModel.load) {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .buttonStyle(LiquidGlassButtonStyle(prominent: true))
            }
            .glassSection()
        }
    }

    private var dynamicIslandSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassSectionHeading(title: String(localized: "Dynamic Island"), symbol: "capsule.fill")
            GlassRows {
                tweakRow(.supportsDynamicIsland)
                if viewModel.isTweakOn(.supportsDynamicIsland) || viewModel.dynamicIslandSubtype != nil {
                    GlassPickerRow(String(localized: "Island Layout"), selection: $viewModel.dynamicIslandSubtype) {
                        Text("Keep Current Layout").tag(Int?.none)
                        ForEach(DynamicIslandOption.all) { option in
                            Text(option.title).tag(Int?.some(option.subtype))
                        }
                    }
                }
            }
        }
        .glassSection()
        .onChange(of: viewModel.isTweakOn(.supportsDynamicIsland)) { _, enabled in
            if !enabled { viewModel.dynamicIslandSubtype = nil }
        }
    }

    @ViewBuilder
    private var modelNameControls: some View {
        Toggle("Change model name in About", isOn: $viewModel.changesModelName)
            .glassToggle()
        if viewModel.changesModelName {
            VStack(alignment: .leading, spacing: 8) {
                GlassFieldLabel(String(localized: "Model Name"))
                GlassTextFieldSurface {
                    TextField("Model Name", text: $viewModel.modelName)
                        .textInputAutocapitalization(.words)
                }
            }
        }
    }

    private var applyBar: some View {
        HStack(spacing: 14) {
            GlassIconBadge(symbol: "square.and.pencil", size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: String(localized: "%d pending changes"), viewModel.stagedChangeCount))
                    .font(.system(.headline, design: .rounded, weight: .bold))
                Text("A backup is created before writing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Apply") { viewModel.applySelectedTweaks() }
                .buttonStyle(LiquidGlassButtonStyle(prominent: true))
                .frame(width: 112)
                .disabled(viewModel.isBusy)
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 30, borderOpacity: 0.18)
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }
}

enum TweakState {
    case off, active, original, willApply, willRemove

    var label: String? {
        switch self {
        case .off: nil
        case .active: String(localized: "Applied")
        case .original: String(localized: "Original value")
        case .willApply: String(localized: "Will be applied")
        case .willRemove: String(localized: "Will be removed")
        }
    }

    var color: Color {
        switch self {
        case .active: .green
        case .willApply: .blue
        case .willRemove: .orange
        case .off, .original: .secondary
        }
    }
}

private struct TweakToggle: View {
    let definition: GestaltTweakDefinition
    @Binding var isOn: Bool

    var included = false
    var state: TweakState = .off
    var warning: String? = nil
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(definition.title)
                        if definition.isRisky { GlassRiskBadge() }
                    }
                    if included {
                        Text("Included in iPadOS Mode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let label = state.label {
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(state.color)
                    }
                    if let warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .glassToggle()
            .disabled(included)
            if definition.isRisky || definition.showsDetails || [.supportsDynamicIsland, .chargeLimit, .alwaysOnDisplayVibrancy].contains(definition.id) {
                Button {
                    showsDetails = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 32, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("About \(definition.title)"))
            }
        }
        .onChange(of: isOn) { old, enabled in
            // Only a new selection asks for confirmation, not the state read from the device.
            if enabled && !old && state == .willApply && definition.isRisky && !included { showsDetails = true }
        }
        .alert(definition.title, isPresented: $showsDetails) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(definition.detail)
        }
    }
}

// MARK: - Impostazioni

private struct SettingsView: View {
    @EnvironmentObject private var viewModel: GestaltViewModel
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        GlassScreen(spacing: 16) {
            HStack(spacing: 15) {
                Image("AppMark")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 70, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.glassLine.opacity(0.20), lineWidth: 0.8)
                    }
                    .shadow(color: Color.glassShadow, radius: 11, x: 0, y: 5)

                VStack(alignment: .leading, spacing: 5) {
                    Text("GESTALTX")
                        .font(.system(.caption, design: .rounded, weight: .heavy))
                        .tracking(1.8)
                        .foregroundStyle(.secondary)
                    Text("Control center")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text("Appearance, device information and credits")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard(cornerRadius: 28, borderOpacity: 0.18)

            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeading(title: String(localized: "Appearance"),
                                    subtitle: String(localized: "Follow the iPhone or choose light or dark."),
                                    symbol: appearance.symbol)
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { a in
                        Text(a.label).tag(a)
                    }
                }
                .pickerStyle(.segmented)
            }
            .glassSection()

            VStack(alignment: .leading, spacing: 16) {
                GlassSectionHeading(title: String(localized: "Device"),
                                    subtitle: viewModel.plist == nil
                                        ? String(localized: "MobileGestalt not loaded")
                                        : String(localized: "MobileGestalt loaded"),
                                    symbol: UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")
                if viewModel.plist != nil {
                    GlassStatusPill(title: String(localized: "Connected"), symbol: "checkmark.seal.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GlassDetailRow(title: String(localized: "Model"),
                               value: AIRegionProfile.currentDeviceMarketingName ?? UIDevice.current.model,
                               symbol: "info.circle")
                GlassDivider()
                GlassDetailRow(title: String(localized: "System"),
                               value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
                               symbol: "gearshape")
                GlassDivider()
                GlassDetailRow(title: String(localized: "Backups"),
                               value: "\(viewModel.backups.count)",
                               symbol: "archivebox")
            }
            .glassSection()

            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeading(title: String(localized: "Credits"),
                                    subtitle: String(localized: "GestAltX is based on the original project by SUSS, released under GPL-3.0-or-later."),
                                    symbol: "heart.text.square")
                VStack(spacing: 10) {
                    DeveloperFooter()
                        .glassRow()

                    PlacardPromotionLink()
                        .glassRow()

                    NavigationLink {
                        RewardCodeView()
                    } label: {
                        HStack(spacing: 14) {
                            GlassIconBadge(symbol: "heart.fill", size: 44)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("打赏开发者")
                                    .font(.system(.headline, design: .rounded, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text("扫描赞赏码支持 SUSS")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            GlassChevron()
                        }
                        .glassRow()
                    }
                    .buttonStyle(.plain)
                }
            }
            .glassSection()

            VStack(alignment: .leading, spacing: 16) {
                GlassSectionHeading(title: String(localized: "About"), symbol: "info.circle")
                GlassDetailRow(title: String(localized: "Version"),
                               value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                               symbol: "number")
                GlassDivider()
                GlassDetailRow(title: String(localized: "Bundle Identifier"),
                               value: Bundle.main.bundleIdentifier ?? "com.iamgasgass.gestaltx",
                               symbol: "shippingbox")
            }
            .glassSection()
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct PlacardPromotionLink: View {
    private let placardURL = URL(string: "https://github.com/frs0n/placard")!

    var body: some View {
        Link(destination: placardURL) {
            HStack(spacing: 14) {
                placardIcon
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.glassLine.opacity(0.16), lineWidth: 0.8)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Placard")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("iPhone 动态壁纸")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Placard，iPhone 动态壁纸，点击打开 GitHub")
    }

    private var placardIcon: Image {
        guard let url = Bundle.main.url(forResource: "PlacardIcon", withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path) else {
            return Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled")
        }
        return Image(uiImage: image)
    }
}

private struct DeveloperFooter: View {
    private let douyinURL = URL(string: "https://v.douyin.com/hHHMAlF5bE0/")!
    private let xURL = URL(string: "https://x.com/Frs0n_")!
    private let githubURL = URL(string: "https://github.com/frs0n")!

    var body: some View {
        HStack(spacing: 14) {
            avatarImage
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(Color.glassLine.opacity(0.16), lineWidth: 0.8) }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("SUSS")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                Text("Original developer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                socialLink("Douyin", label: "抖音", destination: douyinURL)
                socialLink("X", label: "X", destination: xURL)
                socialLink("GitHub", label: "GitHub", destination: githubURL)
            }
        }
    }

    private func socialLink(_ image: String, label: String, destination: URL) -> some View {
        Link(destination: destination) {
            Image(image)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .frame(width: 38, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.glassInk.opacity(0.9))
        .accessibilityLabel("SUSS · \(label)")
    }

    private var avatarImage: Image {
        guard let url = Bundle.main.url(forResource: "SUSSAvatar", withExtension: "jpg"),
              let image = UIImage(contentsOfFile: url.path) else {
            return Image(systemName: "person.crop.circle")
        }
        return Image(uiImage: image)
    }
}

private struct RewardCodeView: View {
    private let rewardCodeImage: UIImage = {
        let imageURL = Bundle.main.url(forResource: "RewardCode", withExtension: "jpg")!
        return UIImage(contentsOfFile: imageURL.path)!
    }()

    var body: some View {
        GlassScreen {
            VStack(spacing: 18) {
                Image(uiImage: rewardCodeImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Color.glassLine.opacity(0.16), lineWidth: 0.8)
                    }
                    .accessibilityLabel("SUSS Reward Code")

                Text("感谢你对 SUSS 的支持")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)

                Text("打开微信扫描上方赞赏码")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 560)
            .glassSection(cornerRadius: 30)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("打赏 SUSS")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Ripristino

private struct BackupLibrary: View {
    @EnvironmentObject private var viewModel: GestaltViewModel
    @State private var showsBackupImporter = false

    var body: some View {
        GlassList {
            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeading(
                    title: viewModel.selectedDevice == .appleWatch
                        ? String(localized: "Apple Watch Backups")
                        : String(localized: "Backups"),
                    subtitle: String(localized: "Every write is backed up automatically."),
                    symbol: "archivebox.fill"
                )
                Button {
                    viewModel.createBackup()
                } label: {
                    Label("Back Up Current MobileGestalt", systemImage: "plus.circle.fill")
                }
                .buttonStyle(LiquidGlassButtonStyle(prominent: true))
                .disabled(viewModel.plist == nil || viewModel.isBusy)

                Button {
                    showsBackupImporter = true
                } label: {
                    Label("Import Backup", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(LiquidGlassButtonStyle())
                .disabled(viewModel.isBusy)
            }
            .glassSection()
            .glassListRow()

            if !identityBackups.isEmpty {
                GlassListHeader(title: String(localized: "Siri AI"), count: identityBackups.count, symbol: "sparkles")
                    .glassListRow(top: 12)

                Text("After the Siri AI model download finishes, use this backup to remove device spoofing. Face ID and dictation will work again after restarting, while Siri AI settings stay enabled.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    .glassListRow(top: 0, bottom: 4)

                backupRows(identityBackups)
            }

            GlassListHeader(title: String(localized: "Local Backups"), count: ordinaryBackups.count, symbol: "archivebox.fill")
                .glassListRow(top: 12)

            if ordinaryBackups.isEmpty {
                GlassEmptyState(symbol: "archivebox", title: String(localized: "No Backups"),
                                message: String(localized: "Back up the current MobileGestalt or import a .plist backup."))
                    .glassListRow()
            } else {
                backupRows(ordinaryBackups)
            }
        }
        .navigationTitle(viewModel.selectedDevice == .appleWatch ? String(localized: "Apple Watch Backups") : String(localized: "Restore"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsBackupImporter = true } label: {
                    Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                }
                .accessibilityLabel("Import Backup")
                .disabled(viewModel.isBusy)
            }
        }
        .refreshable { viewModel.refreshBackups() }
        .onAppear { viewModel.refreshBackups() }
        .fileImporter(
            isPresented: $showsBackupImporter,
            allowedContentTypes: [.propertyList],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { viewModel.importBackup(from: url) }
            case .failure(let error):
                viewModel.notice = GestaltNotice(kind: .error, message: error.localizedDescription)
            }
        }
    }

    private var identityBackups: [GestaltBackup] {
        viewModel.backups.filter { $0.purpose == .siriAIIdentityRestore }
    }

    private var ordinaryBackups: [GestaltBackup] {
        viewModel.backups.filter { $0.purpose == .standard }
    }

    private func backupRows(_ backups: [GestaltBackup]) -> some View {
        ForEach(backups) { backup in
            BackupRow(backup: backup)
                .background {
                    NavigationLink { BackupDetail(backup: backup) } label: { EmptyView() }
                        .opacity(0)
                }
                .glassListRow()
        }
        .onDelete { offsets in
            for index in offsets { viewModel.delete(backups[index]) }
        }
    }
}

private struct BackupRow: View {
    let backup: GestaltBackup

    var body: some View {
        HStack(spacing: 14) {
            GlassIconBadge(symbol: backup.purpose == .siriAIIdentityRestore ? "sparkles" : "doc.badge.clock",
                           size: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(backup.reason)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 10) {
                    Label {
                        Text(backup.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                    } icon: {
                        Image(systemName: "calendar")
                    }
                    Text(ByteCountFormatter.string(fromByteCount: backup.byteCount, countStyle: .file))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            GlassChevron()
        }
        .glassRow()
    }
}

private struct BackupDetail: View {
    @EnvironmentObject private var viewModel: GestaltViewModel
    @State private var showsRestoreConfirmation = false
    @State private var showsChanges = false
    let backup: GestaltBackup

    var body: some View {
        GlassScreen {
            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeading(title: backup.reason,
                                    subtitle: backup.name,
                                    symbol: backup.purpose == .siriAIIdentityRestore ? "sparkles" : "archivebox")
                GlassDetailRow(title: String(localized: "Created"),
                               value: backup.createdAt.formatted(.dateTime.year().month().day().hour().minute().second()),
                               symbol: "calendar")
                GlassDivider()
                GlassDetailRow(title: String(localized: "Size"),
                               value: ByteCountFormatter.string(fromByteCount: backup.byteCount, countStyle: .file),
                               symbol: "doc.on.doc")
            }
            .glassSection()

            if let record = backup.record,
               record.source == .modification || record.source == .restore || record.source == .identityRecovery {
                VStack(alignment: .leading, spacing: 14) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) { showsChanges.toggle() }
                    } label: {
                        HStack(alignment: .center, spacing: 0) {
                            GlassSectionHeading(
                                title: record.verified ? String(localized: "Changes") : String(localized: "Requested Changes"),
                                subtitle: "\(record.changes.count)",
                                symbol: "arrow.left.arrow.right"
                            )
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(showsChanges ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showsChanges {
                        if record.changes.isEmpty {
                            Text("No Field Changes")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .glassInset()
                        }
                        ForEach(record.changes) { change in
                            VStack(alignment: .leading, spacing: 8) {
                                if let title = fieldTitle(for: change) {
                                    Text(title)
                                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                    Text(change.path.joined(separator: " › "))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(change.path.joined(separator: " › "))
                                        .font(.subheadline.monospaced())
                                }
                                Text(change.before ?? String(localized: "Not Present"))
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.down").foregroundStyle(.tertiary)
                                    .accessibilityLabel("Changes to")
                                Text(change.after ?? String(localized: "Not Present"))
                                    .font(.system(.footnote, design: .monospaced))
                            }
                            .textSelection(.enabled)
                            .glassInset()
                        }
                    }
                }
                .glassSection()
            }

            VStack(alignment: .leading, spacing: 14) {
                GlassSectionHeading(title: String(localized: "Actions"),
                                    subtitle: String(localized: "Export the file or write it back to the device."),
                                    symbol: "square.and.arrow.up.on.square")
                ShareLink(item: backup.url) {
                    Label("Export Backup", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(LiquidGlassButtonStyle())

                Button {
                    showsRestoreConfirmation = true
                } label: {
                    Label("Restore Backup", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(LiquidGlassButtonStyle(prominent: true))
                .disabled(viewModel.isBusy)
                .confirmationDialog(
                    backup.purpose == .siriAIIdentityRestore
                        ? String(localized: "Remove Device Spoof?")
                        : String(localized: "Restore This MobileGestalt Backup?"),
                    isPresented: $showsRestoreConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(backup.purpose == .siriAIIdentityRestore
                           ? String(localized: "Remove Device Spoof")
                           : String(localized: "Restore and Write"), role: .destructive) {
                        viewModel.restore(backup)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    if backup.purpose == .siriAIIdentityRestore {
                        Text("Complete the Siri AI model download first. Your original device identity will be restored, and Face ID and dictation will work again after restarting. SiriMode and other AI settings stay enabled. The current file will be backed up before writing.")
                    } else {
                        Text(viewModel.selectedDevice == .appleWatch
                             ? String(localized: "The current Apple Watch file will be backed up first. The watch interface will restart automatically after restoring.")
                             : String(localized: "The current file will be backed up first. SpringBoard will refresh automatically after restoring."))
                    }
                }
            }
            .glassSection()
        }
        .navigationTitle("Backup Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func fieldTitle(for change: GestaltBackupChange) -> String? {
        guard change.path.count == 2, change.path.first == "CacheExtra", let key = change.path.dropFirst().first else {
            return nil
        }
        let matches = GestaltTweakCatalog.definitions.filter { $0.values[key] != nil }
        if matches.count == 1 { return matches[0].title }
        return WatchTweakCatalog.definitions.first { $0.keys.contains(key) }?.title
    }
}

// MARK: - Editor dei campi

private struct AdvancedGestaltEditor: View {
    @EnvironmentObject private var viewModel: GestaltViewModel

    @State private var searchText = ""
    @State private var activeEditor: FieldEditorRoute?

    private var cacheExtraKeys: [String] {
        filtered(viewModel.plist?.cacheExtraKeys ?? [], section: .cacheExtra)
    }

    private var topLevelKeys: [String] {
        filtered(
            viewModel.plist?.topLevelKeys.filter { $0 != "CacheExtra" } ?? [],
            section: .topLevel
        )
    }

    var body: some View {
        GlassList {
            if viewModel.plist != nil {
                KeySection(
                    title: "CacheExtra",
                    symbol: "tray.full.fill",
                    keys: cacheExtraKeys,
                    value: { value(for: PlistKey(section: .cacheExtra, key: $0)) },
                    select: {
                        activeEditor = .edit(
                            PlistKey(section: .cacheExtra, key: $0)
                        )
                    }
                )

                KeySection(
                    title: String(localized: "Top Level"),
                    symbol: "list.bullet.indent",
                    keys: topLevelKeys,
                    value: { value(for: PlistKey(section: .topLevel, key: $0)) },
                    select: {
                        activeEditor = .edit(
                            PlistKey(section: .topLevel, key: $0)
                        )
                    }
                )
            } else {
                GlassEmptyState(symbol: "list.bullet.rectangle",
                                title: String(localized: "MobileGestalt not loaded"),
                                message: String(localized: "Fields appear here once the selected device has been read."))
                    .glassListRow()
            }
        }
        .navigationTitle("Advanced Field Editor")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search key or value")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    activeEditor = .addCacheExtra
                } label: {
                    Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                }
                .accessibilityLabel("Add CacheExtra Field")
                .disabled(viewModel.plist == nil || viewModel.isBusy)

                Button("Save", action: viewModel.applyChanges)
                    .fontWeight(.semibold)
                    .disabled(!viewModel.isDirty || viewModel.isBusy)
            }
        }
        .sheet(item: $activeEditor) { editor in
            Group {
                switch editor {
                case .edit(let key):
                    ValueEditor(
                        key: key.key,
                        initialValue: value(for: key),
                        save: { update($0, for: key) },
                        delete: key.section == .cacheExtra
                            ? { deleteCacheExtraField(key.key) }
                            : nil
                    )
                case .addCacheExtra:
                    AddCacheExtraFieldEditor(save: addCacheExtraField)
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func filtered(_ keys: [String], section: PlistSection) -> [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return keys }

        return keys.filter { key in
            let reference = PlistKey(section: section, key: key)
            let info = PlistValueInfo.info(for: value(for: reference))
            return key.localizedCaseInsensitiveContains(query)
                || info.searchText.localizedCaseInsensitiveContains(query)
        }
    }

    private func value(for key: PlistKey) -> Any? {
        switch key.section {
        case .cacheExtra:
            viewModel.plist?.cacheExtra[key.key]
        case .topLevel:
            viewModel.plist?.value(forKey: key.key)
        }
    }

    private func update(_ value: Any, for key: PlistKey) {
        guard var plist = viewModel.plist else { return }
        switch key.section {
        case .cacheExtra:
            plist.setCacheExtra(value, forKey: key.key)
        case .topLevel:
            plist.setValue(value, forKey: key.key)
        }
        viewModel.plist = plist
        viewModel.isDirty = true
    }

    private func addCacheExtraField(key: String, value: Any) throws {
        guard var plist = viewModel.plist else { return }
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            throw AddFieldError.emptyKey
        }
        guard plist.cacheExtra[normalizedKey] == nil else {
            throw AddFieldError.duplicateKey(normalizedKey)
        }

        plist.setCacheExtra(value, forKey: normalizedKey)
        viewModel.plist = plist
        viewModel.isDirty = true
    }

    private func deleteCacheExtraField(_ key: String) {
        guard var plist = viewModel.plist else { return }
        plist.removeCacheExtraValue(forKey: key)
        viewModel.plist = plist
        viewModel.isDirty = true
    }
}

private enum PlistSection: String {
    case cacheExtra
    case topLevel
}

private struct PlistKey: Identifiable {
    let section: PlistSection
    let key: String
    var id: String { "\(section.rawValue)/\(key)" }
}

private enum FieldEditorRoute: Identifiable {
    case edit(PlistKey)
    case addCacheExtra

    var id: String {
        switch self {
        case .edit(let key): "edit/\(key.id)"
        case .addCacheExtra: "add/cacheExtra"
        }
    }
}

private enum AddFieldError: LocalizedError {
    case emptyKey
    case duplicateKey(String)

    var errorDescription: String? {
        switch self {
        case .emptyKey:
            String(localized: "Key cannot be empty.")
        case .duplicateKey(let key):
            String(format: String(localized: "CacheExtra already contains the field: %@"), key)
        }
    }
}

private struct KeySection: View {
    let title: String
    let symbol: String
    let keys: [String]
    let value: (String) -> Any?
    let select: (String) -> Void

    var body: some View {
        GlassListHeader(title: title, count: keys.count, symbol: symbol)
            .glassListRow(top: 12)

        if keys.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("No Results")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .glassInset()
            .glassListRow()
        } else {
            ForEach(keys, id: \.self) { key in
                Button { select(key) } label: {
                    KeyRow(key: key, value: value(key))
                }
                .buttonStyle(.plain)
                .glassListRow(top: 5, bottom: 5)
            }
        }
    }
}

private struct KeyRow: View {
    let key: String
    let value: Any?

    var body: some View {
        let info = PlistValueInfo.info(for: value)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(key)
                    .font(.system(.subheadline, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(info.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            GlassChevron()
        }
        .glassRow()
    }
}

private struct ValueEditor: View {
    @Environment(\.dismiss) private var dismiss

    let key: String
    let initialValue: Any?
    let save: (Any) -> Void
    let delete: (() -> Void)?

    @State private var kind: PlistValueKind
    @State private var text: String
    @State private var errorMessage: String?
    @State private var showsDeleteConfirmation = false

    init(
        key: String,
        initialValue: Any?,
        save: @escaping (Any) -> Void,
        delete: (() -> Void)? = nil
    ) {
        self.key = key
        self.initialValue = initialValue
        self.save = save
        self.delete = delete
        let kind = PlistValueKind.kind(of: initialValue)
        _kind = State(initialValue: kind)
        _text = State(initialValue: PlistValueInfo.encode(initialValue, as: kind))
    }

    var body: some View {
        NavigationStack {
            GlassScreen(spacing: 14) {
                GlassFieldLabel(String(localized: "Type"))
                GlassTextFieldSurface {
                    GlassPickerRow(String(localized: "Type"), selection: $kind) {
                        ForEach(PlistValueKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                }

                GlassFieldLabel(String(localized: "Value"))
                GlassTextFieldSurface {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 140)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if let errorMessage {
                    GlassErrorText(message: errorMessage)
                }

                if delete != nil {
                    Button(role: .destructive) {
                        showsDeleteConfirmation = true
                    } label: {
                        Label("Delete Field", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(LiquidGlassButtonStyle())
                    .padding(.top, 6)
                }
            }
            .navigationTitle(key)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: commit)
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                "Delete CacheExtra Field?",
                isPresented: $showsDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    delete?()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The field will be removed from the file after you return to the editor and tap Save.")
            }
        }
        .tint(Color.glassInk)
    }

    private func commit() {
        do {
            save(try PlistValueInfo.parse(text, as: kind))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AddCacheExtraFieldEditor: View {
    @Environment(\.dismiss) private var dismiss

    let save: (String, Any) throws -> Void

    @State private var key = ""
    @State private var kind: PlistValueKind = .string
    @State private var text = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            GlassScreen(spacing: 14) {
                GlassDetailRow(title: String(localized: "Location"), value: "CacheExtra", symbol: "tray.full")
                    .glassInset()

                GlassFieldLabel(String(localized: "Key"))
                GlassTextFieldSurface {
                    TextField("Key", text: $key)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                GlassFieldLabel(String(localized: "Type"))
                GlassTextFieldSurface {
                    GlassPickerRow(String(localized: "Type"), selection: $kind) {
                        ForEach(PlistValueKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                }

                GlassFieldLabel(String(localized: "Value"))
                GlassTextFieldSurface {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if let errorMessage {
                    GlassErrorText(message: errorMessage)
                }
            }
            .navigationTitle("Add Field")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add", action: commit)
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(Color.glassInk)
    }

    private func commit() {
        do {
            let value = try PlistValueInfo.parse(text, as: kind)
            try save(key, value)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(GestaltViewModel())
}
