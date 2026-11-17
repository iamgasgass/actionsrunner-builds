import SwiftUI

struct WatchToolsSections: View {
    @EnvironmentObject private var viewModel: GestaltViewModel

    var body: some View {
        GlassCardSection(title: String(localized: "Apple Intelligence"), symbol: "sparkles") {
            Toggle("Enable Siri AI", isOn: Binding(
                get: { viewModel.selectedWatchTweaks.contains("intelligence") },
                set: { enabled in
                    if enabled { viewModel.selectedWatchTweaks.insert("intelligence") }
                    else { viewModel.selectedWatchTweaks.remove("intelligence") }
                }
            ))
            .glassToggle()
        } footer: {
            Text("Automatically adjusts unsupported regions to the United States.")
        }

        ForEach(WatchTweakGroup.allCases.filter { $0 != .intelligence }) { group in
            GlassCardSection(title: group.title, symbol: symbol(for: group)) {
                ForEach(WatchTweakCatalog.definitions.filter { $0.group == group }) { definition in
                    Toggle(definition.title, isOn: Binding(
                        get: { viewModel.selectedWatchTweaks.contains(definition.id) },
                        set: { enabled in
                            if enabled { viewModel.selectedWatchTweaks.insert(definition.id) }
                            else {
                                viewModel.selectedWatchTweaks.remove(definition.id)
                                if definition.id == "ultra" {
                                    viewModel.watchUltraFaceClass = viewModel.currentWatchUltraFaceClass
                                        ?? viewModel.watchUltraFaceClassOptions.first ?? 29
                                }
                            }
                        }
                    ))
                    .glassToggle()
                    .disabled(definition.isFace && !viewModel.supportsWatchFaces)
                }
                if group == .faces && viewModel.watchUltraFaceClassOptions.count > 1 &&
                    (viewModel.selectedWatchTweaks.contains("ultra") || viewModel.currentWatchUltraFaceClass != nil) {
                    GlassPickerRow(String(localized: "Ultra Face Layout"), selection: Binding(
                        get: { viewModel.watchUltraFaceClass },
                        set: { layout in
                            viewModel.watchUltraFaceClass = layout
                            viewModel.selectedWatchTweaks.insert("ultra")
                        }
                    )) {
                        ForEach(viewModel.watchUltraFaceClassOptions, id: \.self) { layout in
                            Text("Class \(layout)").tag(layout)
                        }
                    }
                }
            } footer: {
                if group == .faces {
                    if !viewModel.supportsWatchFaces {
                        Text("Watch face changes are unavailable on this watchOS build.")
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Ultra faces can prevent the Hermès Faubourg Party face from working.")
                            if viewModel.watchUltraFaceClassOptions.count > 1 {
                                Text("A larger Ultra layout may affect other watch faces and complications.")
                            }
                        }
                    }
                } else if group == .sensors {
                    Text("Capability flags do not add missing sensors or override Health permissions.")
                }
            }
        }

        GlassCardSection(title: String(localized: "Watch Region"), symbol: "globe") {
            GlassPickerRow(String(localized: "Region Code"), selection: $viewModel.watchRegionCode) {
                Text("No Change").tag("")
                ForEach(WatchTweakCatalog.regions, id: \.1) { region in
                    Text(region.0).tag(region.1)
                }
            }
            GlassPickerRow(String(localized: "Sales Region"), selection: $viewModel.watchSalesRegion) {
                Text("No Change").tag("")
                ForEach(WatchTweakCatalog.regions, id: \.2) { region in
                    Text(region.0).tag(region.2)
                }
            }
        }

        GlassCardSection(title: String(localized: "Watch Resolution"), symbol: "applewatch.watchface") {
            GlassPickerRow(String(localized: "Screen Resolution"), selection: $viewModel.watchResolution) {
                Text("No Change").tag(-1)
                ForEach(WatchTweakCatalog.resolutions.indices, id: \.self) { index in
                    let resolution = WatchTweakCatalog.resolutions[index]
                    Text("\(resolution.0) · \(resolution.1) × \(resolution.2)").tag(index)
                }
            }
        }
    }

    private func symbol(for group: WatchTweakGroup) -> String {
        switch group {
        case .faces: "applewatch.watchface"
        case .display: "sun.max.fill"
        case .controls: "digitalcrown.horizontal.press.fill"
        case .sensors: "heart.text.square.fill"
        case .voice: "waveform"
        case .intelligence: "sparkles"
        }
    }
}
