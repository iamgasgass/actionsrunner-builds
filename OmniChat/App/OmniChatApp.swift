import SwiftUI

@main
struct OmniChatApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(app.settings.theme.colorScheme)
                .tint(.primary)
        }
    }
}
