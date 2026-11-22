import SwiftUI

/// Stato di navigazione dell'interfaccia dell'auto.
final class AppState: ObservableObject {
    enum Screen: Equatable {
        case home
        case dashboard
        case app(CarApp)
    }

    @Published var screen: Screen = .dashboard
    @Published var recents: [CarApp] = [.maps, .nowPlaying, .phone]
    @Published var showAssistant = false
    @Published var banner: String?

    private var bannerWork: DispatchWorkItem?

    var currentApp: CarApp? {
        if case let .app(app) = screen { return app }
        return nil
    }

    func open(_ app: CarApp) {
        withAnimation(.easeInOut(duration: 0.25)) {
            screen = .app(app)
        }
        var list = recents.filter { $0 != app }
        list.insert(app, at: 0)
        recents = Array(list.prefix(3))
    }

    /// Il tasto Home alterna tra griglia app e Dashboard, come sulle vere unità.
    func homeButtonTapped() {
        withAnimation(.easeInOut(duration: 0.25)) {
            switch screen {
            case .home: screen = .dashboard
            case .dashboard: screen = .home
            case .app: screen = .home
            }
        }
    }

    func showBanner(_ text: String) {
        bannerWork?.cancel()
        withAnimation { banner = text }
        let work = DispatchWorkItem { [weak self] in
            withAnimation { self?.banner = nil }
        }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}
