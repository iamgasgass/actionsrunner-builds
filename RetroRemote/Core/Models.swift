import Foundation

enum TVBrand: String, Codable, CaseIterable {
    case samsung, lg, roku, androidTV, fireTV, vizio, panasonic

    var displayName: String {
        switch self {
        case .samsung: return "Samsung Smart TV"
        case .lg: return "LG webOS"
        case .roku: return "Roku / Roku TV"
        case .androidTV: return "Android TV / Google TV"
        case .fireTV: return "Amazon Fire TV"
        case .vizio: return "VIZIO SmartCast"
        case .panasonic: return "Panasonic Viera"
        }
    }

    var shortName: String {
        switch self {
        case .samsung: return "Samsung"
        case .lg: return "LG"
        case .roku: return "Roku"
        case .androidTV: return "Android TV"
        case .fireTV: return "Fire TV"
        case .vizio: return "VIZIO"
        case .panasonic: return "Panasonic"
        }
    }

    /// Note di configurazione mostrate in "TV compatibili".
    var setupNotes: String {
        switch self {
        case .samsung:
            return "Modelli Tizen dal 2016. Alla prima connessione accetta la richiesta sulla TV."
        case .lg:
            return "webOS (2014 e successivi). Alla prima connessione accetta la richiesta sulla TV. Il touchpad può funzionare da mouse."
        case .roku:
            return "Roku Stick, Express, Ultra e Roku TV (TCL, Hisense, Sharp…). Attiva «Controllo da app mobili» nelle impostazioni di sistema avanzate."
        case .androidTV:
            return "Sony, Philips, TCL, Hisense, Xiaomi, Sharp, Nvidia Shield, Chromecast con Google TV. Alla prima connessione inserisci il codice mostrato sulla TV."
        case .fireTV:
            return "Fire TV Stick, Cube e Fire TV Edition. Attiva Impostazioni › La mia Fire TV › Opzioni sviluppatore › Debug ADB, poi consenti la connessione sulla TV."
        case .vizio:
            return "TV SmartCast. Alla prima connessione inserisci il PIN di 4 cifre mostrato sulla TV."
        case .panasonic:
            return "Viera 2012–2018 con «Controllo remoto TV» attivo (Rete › Impostazioni app TV remote). Alcuni modelli più recenti usano un protocollo cifrato non supportato."
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
    case red, green, yellow, blue, settings
    case backspace, enter, previousChannel, dash
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
