import SwiftUI

/// The app's two sections behind a native Liquid Glass bottom tab bar
/// (iOS 26+), in the style of the iOS Files app: "Respring" and "Impostazioni".
struct MainTabView: View {
    @StateObject private var settings = AppSettings()

    var body: some View {
        TabView {
            Tab("Respring", systemImage: "power") {
                RootPowerView()
            }

            Tab("Impostazioni", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .environmentObject(settings)
        .tint(.blue)
        .preferredColorScheme(settings.appearance.colorScheme)
    }
}

#Preview {
    MainTabView()
}
