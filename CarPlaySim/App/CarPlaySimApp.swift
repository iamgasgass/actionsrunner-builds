import SwiftUI

@main
struct CarPlaySimApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var state = AppState()
    @StateObject private var media = MediaController()
    @StateObject private var nav = NavigationModel()
    @StateObject private var assistant = VoiceAssistant()
    @StateObject private var location = LocationManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(state)
                .environmentObject(media)
                .environmentObject(nav)
                .environmentObject(assistant)
                .environmentObject(location)
                .preferredColorScheme(settings.appearance.colorScheme)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    location.requestAuthorization()
                }
        }
    }
}
