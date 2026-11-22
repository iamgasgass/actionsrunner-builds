import SwiftUI

/// Elemento della Home: app integrata o app CarPlay installata.
enum HomeItem: Hashable, Identifiable {
    case builtin(CarApp)
    case guest(String)

    var id: String {
        switch self {
        case .builtin(let app): return "b." + app.rawValue
        case .guest(let id): return "g." + id
        }
    }
}

/// Stato di navigazione dell'interfaccia dell'auto.
final class AppState: ObservableObject {
    enum Screen: Equatable {
        case home
        case dashboard
        case app(CarApp)
        case guest(String)
    }

    @Published var screen: Screen = .dashboard
    @Published var recents: [HomeItem] = [.builtin(.maps), .builtin(.nowPlaying), .builtin(.phone)]
    @Published var showAssistant = false
    @Published var banner: String?
    @Published var homePage = 0

    private var bannerWork: DispatchWorkItem?

    var currentApp: CarApp? {
        if case let .app(app) = screen { return app }
        return nil
    }

    var currentItem: HomeItem? {
        switch screen {
        case .app(let a): return .builtin(a)
        case .guest(let id): return .guest(id)
        default: return nil
        }
    }

    func open(_ app: CarApp) {
        open(.builtin(app))
    }

    func open(_ item: HomeItem) {
        withAnimation(.easeInOut(duration: 0.2)) {
            switch item {
            case .builtin(let app): screen = .app(app)
            case .guest(let id): screen = .guest(id)
            }
        }
        var list = recents.filter { $0 != item }
        list.insert(item, at: 0)
        recents = Array(list.prefix(3))
    }

    /// Il tasto Home alterna tra griglia app e Dashboard, come sulle vere unità.
    func homeButtonTapped() {
        withAnimation(.easeInOut(duration: 0.2)) {
            switch screen {
            case .home: screen = .dashboard
            case .dashboard: screen = .home
            case .app, .guest: screen = .home
            }
        }
    }

    func removeGuest(_ id: String) {
        recents.removeAll { $0 == .guest(id) }
        if screen == .guest(id) { screen = .home }
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
