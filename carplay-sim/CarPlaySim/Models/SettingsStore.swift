import SwiftUI

/// Risoluzioni tipiche delle unità di bordo. Le dimensioni sono in punti logici.
enum DisplayPreset: String, CaseIterable, Identifiable {
    case fit
    case standard
    case hd
    case wide
    case ultraWide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: return "Adatta allo schermo"
        case .standard: return "800 × 480 (standard)"
        case .hd: return "1280 × 720 (HD)"
        case .wide: return "1440 × 540 (wide)"
        case .ultraWide: return "1920 × 720 (ultra wide)"
        }
    }

    /// Dimensione logica dello schermo simulato; nil = usa tutto lo spazio.
    var logicalSize: CGSize? {
        switch self {
        case .fit: return nil
        case .standard: return CGSize(width: 800, height: 480)
        case .hd: return CGSize(width: 1280 / 1.5, height: 720 / 1.5)
        case .wide: return CGSize(width: 1440 / 1.5, height: 540 / 1.5)
        case .ultraWide: return CGSize(width: 1920 / 1.5, height: 720 / 1.5)
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "Scuro"
        case .light: return "Chiaro"
        case .system: return "Automatico"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

struct Wallpaper: Identifiable {
    let id: Int
    let name: String
    let colors: [Color]

    static let all: [Wallpaper] = [
        Wallpaper(id: 0, name: "Notte", colors: [Color(red: 0.05, green: 0.07, blue: 0.16), Color(red: 0.12, green: 0.10, blue: 0.30)]),
        Wallpaper(id: 1, name: "Aurora", colors: [Color(red: 0.02, green: 0.20, blue: 0.22), Color(red: 0.10, green: 0.45, blue: 0.40), Color(red: 0.15, green: 0.12, blue: 0.35)]),
        Wallpaper(id: 2, name: "Tramonto", colors: [Color(red: 0.35, green: 0.10, blue: 0.25), Color(red: 0.80, green: 0.35, blue: 0.20)]),
        Wallpaper(id: 3, name: "Oceano", colors: [Color(red: 0.02, green: 0.12, blue: 0.30), Color(red: 0.05, green: 0.40, blue: 0.65)]),
        Wallpaper(id: 4, name: "Grafite", colors: [Color(white: 0.08), Color(white: 0.20)]),
        Wallpaper(id: 5, name: "Lime", colors: [Color(red: 0.05, green: 0.18, blue: 0.08), Color(red: 0.30, green: 0.55, blue: 0.15)])
    ]
}

/// Preferenze persistenti (UserDefaults).
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var displayPreset: DisplayPreset {
        didSet { defaults.set(displayPreset.rawValue, forKey: "displayPreset") }
    }
    @Published var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }
    @Published var wallpaperIndex: Int {
        didSet { defaults.set(wallpaperIndex, forKey: "wallpaperIndex") }
    }
    @Published var rightHandDrive: Bool {
        didSet { defaults.set(rightHandDrive, forKey: "rightHandDrive") }
    }
    @Published var showBezel: Bool {
        didSet { defaults.set(showBezel, forKey: "showBezel") }
    }
    @Published var spokenFeedback: Bool {
        didSet { defaults.set(spokenFeedback, forKey: "spokenFeedback") }
    }
    @Published var simulationSpeed: Double {
        didSet { defaults.set(simulationSpeed, forKey: "simulationSpeed") }
    }
    @Published var use24h: Bool {
        didSet { defaults.set(use24h, forKey: "use24h") }
    }

    var wallpaper: Wallpaper {
        Wallpaper.all.indices.contains(wallpaperIndex) ? Wallpaper.all[wallpaperIndex] : Wallpaper.all[0]
    }

    init() {
        displayPreset = DisplayPreset(rawValue: defaults.string(forKey: "displayPreset") ?? "") ?? .fit
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .dark
        wallpaperIndex = defaults.object(forKey: "wallpaperIndex") as? Int ?? 0
        rightHandDrive = defaults.bool(forKey: "rightHandDrive")
        showBezel = defaults.object(forKey: "showBezel") as? Bool ?? true
        spokenFeedback = defaults.object(forKey: "spokenFeedback") as? Bool ?? true
        simulationSpeed = defaults.object(forKey: "simulationSpeed") as? Double ?? 4
        use24h = defaults.object(forKey: "use24h") as? Bool ?? true
    }
}
