import SwiftUI

/// Le "app" disponibili sullo schermo dell'auto simulato.
enum CarApp: String, CaseIterable, Identifiable, Codable {
    case maps
    case nowPlaying
    case music
    case radio
    case phone
    case messages
    case calendar
    case weather
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .maps: return "Mappe"
        case .nowPlaying: return "In riproduzione"
        case .music: return "Musica"
        case .radio: return "Radio"
        case .phone: return "Telefono"
        case .messages: return "Messaggi"
        case .calendar: return "Calendario"
        case .weather: return "Meteo"
        case .settings: return "Impostazioni"
        }
    }

    var symbol: String {
        switch self {
        case .maps: return "map.fill"
        case .nowPlaying: return "waveform"
        case .music: return "music.note"
        case .radio: return "dot.radiowaves.left.and.right"
        case .phone: return "phone.fill"
        case .messages: return "message.fill"
        case .calendar: return "calendar"
        case .weather: return "cloud.sun.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var colors: [Color] {
        switch self {
        case .maps: return [Color(red: 0.36, green: 0.80, blue: 0.45), Color(red: 0.13, green: 0.55, blue: 0.85)]
        case .nowPlaying: return [Color(red: 0.98, green: 0.36, blue: 0.42), Color(red: 0.86, green: 0.15, blue: 0.35)]
        case .music: return [Color(red: 1.0, green: 0.42, blue: 0.48), Color(red: 0.95, green: 0.18, blue: 0.30)]
        case .radio: return [Color(red: 0.98, green: 0.55, blue: 0.20), Color(red: 0.90, green: 0.28, blue: 0.10)]
        case .phone: return [Color(red: 0.40, green: 0.90, blue: 0.40), Color(red: 0.15, green: 0.70, blue: 0.25)]
        case .messages: return [Color(red: 0.42, green: 0.92, blue: 0.42), Color(red: 0.13, green: 0.72, blue: 0.30)]
        case .calendar: return [Color(white: 1.0), Color(white: 0.88)]
        case .weather: return [Color(red: 0.35, green: 0.70, blue: 1.0), Color(red: 0.12, green: 0.38, blue: 0.85)]
        case .settings: return [Color(white: 0.62), Color(white: 0.38)]
        }
    }

    var symbolColor: Color {
        self == .calendar ? .red : .white
    }

    /// App mostrate nella griglia Home, nell'ordine.
    static var homeOrder: [CarApp] {
        [.maps, .nowPlaying, .music, .radio, .phone, .messages, .calendar, .weather, .settings]
    }
}
