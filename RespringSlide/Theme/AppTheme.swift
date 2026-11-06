import SwiftUI
import UIKit

/// The two skins the Respring screen can present.
enum AppTheme: String, CaseIterable, Identifiable {
    case liquidGlass
    case oldOS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        case .oldOS:       return "OldOS"
        }
    }

    var subtitle: String {
        switch self {
        case .liquidGlass: return "App attuale"
        case .oldOS:       return "UI iOS 6 (OldSafari)"
        }
    }

    var symbol: String {
        switch self {
        case .liquidGlass: return "circle.hexagongrid.fill"
        case .oldOS:       return "clock.arrow.circlepath"
        }
    }
}

/// App appearance (color scheme) override.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Sistema"
        case .light:  return "Chiaro"
        case .dark:   return "Scuro"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "gear"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    /// nil lets the system decide.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// Central, persisted app settings. Backed by `UserDefaults`, published so
/// every view updates live.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var skin: AppTheme { didSet { defaults.set(skin.rawValue, forKey: Keys.skin) } }
    @Published var appearance: AppAppearance { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }
    @Published var requireConfirmation: Bool { didSet { defaults.set(requireConfirmation, forKey: Keys.requireConfirmation) } }
    @Published var haptics: Bool { didSet { defaults.set(haptics, forKey: Keys.haptics) } }
    /// Fraction of the track (0…1) the thumb must reach to arm the respring.
    @Published var threshold: Double { didSet { defaults.set(threshold, forKey: Keys.threshold) } }

    private enum Keys {
        static let skin = "respringslide.skin"
        static let appearance = "respringslide.appearance"
        static let requireConfirmation = "respringslide.requireConfirmation"
        static let haptics = "respringslide.haptics"
        static let threshold = "respringslide.threshold"
    }

    init() {
        skin = AppTheme(rawValue: defaults.string(forKey: Keys.skin) ?? "") ?? .liquidGlass
        appearance = AppAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        requireConfirmation = defaults.object(forKey: Keys.requireConfirmation) as? Bool ?? true
        haptics = defaults.object(forKey: Keys.haptics) as? Bool ?? true
        threshold = defaults.object(forKey: Keys.threshold) as? Double ?? 0.84
    }

    /// Fire a light impact if haptics are enabled.
    func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard haptics else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
