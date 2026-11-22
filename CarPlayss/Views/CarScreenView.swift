import SwiftUI

/// Lo schermo dell'unità di bordo: barra laterale + contenuto.
struct CarScreenView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var state: AppState
    @EnvironmentObject var nav: NavigationModel

    var body: some View {
        HStack(spacing: 0) {
            if !settings.rightHandDrive { DockView() }
            ZStack {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)

                if let banner = state.banner {
                    VStack {
                        Text(banner)
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 10)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if settings.rightHandDrive { DockView() }
        }
        .background(WallpaperView(wallpaper: settings.wallpaper))
        .overlay {
            if state.showAssistant {
                AssistantOverlay()
                    .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigationArrived)) { note in
            let name = note.object as? String ?? "destinazione"
            state.showBanner("Sei arrivato: \(name)")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.screen {
        case .home:
            HomeView()
        case .dashboard:
            DashboardView()
        case .app(let app):
            AppContainer(app: app)
        case .guest(let id):
            GuestAppView(appID: id)
        }
    }
}

struct AppContainer: View {
    let app: CarApp

    var body: some View {
        switch app {
        case .maps: MapsView()
        case .nowPlaying: NowPlayingView()
        case .music: MusicLibraryView()
        case .radio: RadioView()
        case .phone: PhoneView()
        case .messages: MessagesView()
        case .calendar: CalendarAppView()
        case .weather: WeatherView()
        case .settings: SettingsView()
        }
    }
}

struct WallpaperView: View {
    let wallpaper: Wallpaper

    var body: some View {
        ZStack {
            LinearGradient(colors: wallpaper.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.white.opacity(0.10), .clear], center: .topTrailing, startRadius: 10, endRadius: 500)
        }
        .ignoresSafeArea()
    }
}
