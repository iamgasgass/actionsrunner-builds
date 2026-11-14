import SwiftUI

@main
struct GassMapsApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(state.location)
                .preferredColorScheme(.dark)
                .statusBarHidden(false)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // la mappa viene creata subito (sotto lo splash) per precaricare i tile
            MainMapScreen()

            if state.showSearch {
                SearchScreen()
                    .transition(.move(edge: .trailing))
                    .zIndex(5)
            }

            if state.showSettings {
                SettingsScreen()
                    .transition(.move(edge: .trailing))
                    .zIndex(6)
            }

            if state.showMapSelection {
                MapSelectionScreen()
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
                    .zIndex(7)
            }

            if state.phase == .splash {
                SplashScreen()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: state.phase)
        .animation(.spring(response: 0.42, dampingFraction: 0.9), value: state.showSearch)
        .animation(.spring(response: 0.42, dampingFraction: 0.9), value: state.showSettings)
        .animation(.easeInOut(duration: 0.35), value: state.showMapSelection)
    }
}
