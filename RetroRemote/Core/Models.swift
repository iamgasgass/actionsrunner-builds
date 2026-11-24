import Foundation

enum TVBrand: String, Codable, CaseIterable {
    case roku, samsung, lg

    var displayName: String {
        switch self {
        case .roku: return "Roku"
        case .samsung: return "Samsung Smart TV"
        case .lg: return "LG webOS"
        }
    }

    var shortName: String {
        switch self {
        case .roku: return "Roku"
        case .samsung: return "Samsung"
        case .lg: return "LG"
        }
    }
}

struct TVDevice: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var host: String
    var brand: TVBrand
    var model: String? = nil
    var token: String? = nil
    var mac: String? = nil
}

struct TVApp: Equatable {
    let id: String
    let name: String
    let iconURL: URL?
    var extra: String? = nil
}

enum RemoteKey: Hashable {
    case power, home, back, menu, input, info, guide, exit
    case up, down, left, right, ok
    case volumeUp, volumeDown, mute, channelUp, channelDown
    case play, pause, playPause, rewind, fastForward, stop
    case red, green, yellow, blue
    case digit(Int)
}

enum ConnectionState: Equatable {
    case idle, connecting, pairing, connected
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Non connesso"
        case .connecting: return "Connessione…"
        case .pairing: return "Accetta la richiesta sulla TV"
        case .connected: return "Connesso"
        case .failed(let message): return message
        }
    }
}
