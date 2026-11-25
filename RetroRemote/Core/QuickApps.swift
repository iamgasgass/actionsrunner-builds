import UIKit

/// Catalogo delle app avviabili con un tocco e relativi identificativi per piattaforma.
enum QuickApps {
    struct Entry {
        let name: String
        let ids: [TVBrand: String]
    }

    static let catalog: [Entry] = [
        Entry(name: "Netflix", ids: [
            .roku: "12", .samsung: "3201907018807", .lg: "netflix",
            .androidTV: "https://www.netflix.com/title", .fireTV: "com.netflix.ninja",
            .panasonic: "0010000200000001"]),
        Entry(name: "YouTube", ids: [
            .roku: "837", .samsung: "111299001912", .lg: "youtube.leanback.v4",
            .androidTV: "https://www.youtube.com", .fireTV: "com.amazon.firetv.youtube",
            .panasonic: "0070000200180001"]),
        Entry(name: "Prime Video", ids: [
            .roku: "13", .samsung: "3201910019365", .lg: "amazon",
            .androidTV: "https://app.primevideo.com", .fireTV: "com.amazon.avod",
            .panasonic: "0010000100180001"]),
        Entry(name: "Disney+", ids: [
            .roku: "291097", .samsung: "3201901017640", .lg: "com.disney.disneyplus-prod",
            .androidTV: "https://www.disneyplus.com", .fireTV: "com.disney.disneyplus"]),
        Entry(name: "Spotify", ids: [
            .roku: "22297", .samsung: "3201606009684", .lg: "spotify-beehive",
            .androidTV: "https://open.spotify.com", .fireTV: "com.spotify.tv.android"]),
        Entry(name: "Apple TV", ids: [
            .roku: "551012", .samsung: "3201807016597", .lg: "com.apple.appletv",
            .androidTV: "https://tv.apple.com", .fireTV: "com.apple.atve.amazon.appletv"])
    ]

    static var names: [String] { catalog.map { $0.name } }

    /// Tutte le app del catalogo disponibili per la piattaforma.
    static func apps(for brand: TVBrand) -> [TVApp] {
        catalog.compactMap { entry in
            guard let id = entry.ids[brand] else { return nil }
            return TVApp(id: id, name: entry.name, iconURL: nil, extra: brand == .samsung ? "2" : nil)
        }
    }

    /// Le app scelte dall'utente per la riga di accesso rapido.
    static func favorites(for brand: TVBrand) -> [TVApp] {
        let all = apps(for: brand)
        return Preferences.shared.quickAppNames.compactMap { name in all.first { $0.name == name } }
    }

    /// Colori stabili per la piastrella di un'app (derivati dal nome, senza loghi).
    static func tileColors(for name: String) -> [UIColor] {
        let seed = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let hue = CGFloat(seed % 360) / 360
        return [UIColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1),
                UIColor(hue: hue, saturation: 0.85, brightness: 0.62, alpha: 1)]
    }
}
