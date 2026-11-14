import Foundation
import CoreLocation
import MapKit

struct Place: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    /// elenco salvato (Preferiti, Da visitare, Luoghi speciali) e nota personale, come Google Maps
    var list: String? = nil
    var note: String? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Chiave usata per ricordare i luoghi esplorati (arrotondata a ~10 m)
    var exploreKey: String {
        String(format: "%.4f,%.4f", latitude, longitude)
    }

    init(name: String, address: String, coordinate: CLLocationCoordinate2D) {
        self.name = name
        self.address = address
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }

    init(mapItem: MKMapItem) {
        let pm = mapItem.placemark
        self.init(name: mapItem.name ?? pm.name ?? "Posizione",
                  address: Place.formatShort(pm),
                  coordinate: pm.coordinate)
    }

    /// "84131 Salerno, Italia"
    static func formatShort(_ pm: CLPlacemark) -> String {
        var parts: [String] = []
        let city = [pm.postalCode, pm.locality].compactMap { $0 }.joined(separator: " ")
        if !city.isEmpty { parts.append(city) }
        if let country = pm.country { parts.append(country) }
        return parts.joined(separator: ", ")
    }

    /// "Via Trento 47, 84092 Bellizzi Salerno, Italy"
    static func formatFull(_ pm: CLPlacemark) -> String {
        var parts: [String] = []
        let street = [pm.thoroughfare, pm.subThoroughfare].compactMap { $0 }.joined(separator: " ")
        if !street.isEmpty { parts.append(street) }
        let city = [pm.postalCode, pm.locality, pm.subAdministrativeArea].compactMap { $0 }.joined(separator: " ")
        if !city.isEmpty { parts.append(city) }
        if let country = pm.country { parts.append(country) }
        return parts.isEmpty ? (pm.name ?? "") : parts.joined(separator: ", ")
    }
}

/// Mezzo di trasporto (come le schede di Google Maps)
enum TravelMode: String, CaseIterable, Identifiable, Codable {
    case car, walk, transit
    var id: String { rawValue }

    var title: String {
        switch self {
        case .car: return "Auto"
        case .walk: return "A piedi"
        case .transit: return "Mezzi"
        }
    }

    var icon: String {
        switch self {
        case .car: return "car.fill"
        case .walk: return "figure.walk"
        case .transit: return "tram.fill"
        }
    }

    var mkType: MKDirectionsTransportType {
        switch self {
        case .car: return .automobile
        case .walk: return .walking
        case .transit: return .transit
        }
    }
}

/// Singola manovra del percorso
struct RouteStep: Identifiable, Equatable {
    let id = UUID()
    var instruction: String
    var distance: CLLocationDistance
    /// punto in cui avviene la manovra (inizio del tratto)
    var coordinate: CLLocationCoordinate2D
    /// distanza dall'inizio del percorso al punto della manovra
    var startDistance: CLLocationDistance
    /// angolo di svolta misurato sul tracciato (+ destra, − sinistra, gradi); nil se non misurabile
    var turnAngle: Double? = nil
    /// passo di partenza ("Procedi in direzione nord su Via Roma verso Via Verdi"):
    /// direzione iniziale in gradi e strada verso cui si va, per completare il testo col nome della via
    var isDeparture = false
    var departureBearing: Double? = nil
    var toward: String? = nil

    static func == (lhs: RouteStep, rhs: RouteStep) -> Bool { lhs.id == rhs.id }
}

struct RouteInfo: Equatable, Identifiable {
    var id = UUID()
    var coordinates: [CLLocationCoordinate2D]
    var travelTime: TimeInterval
    var distance: CLLocationDistance
    var steps: [RouteStep] = []
    /// nome del percorso (es. "SS18")
    var name: String = ""
    var mode: TravelMode = .car
    var hasTolls = false
    var hasHighways = false
    /// solo tempo stimato (mezzi pubblici: MapKit non fornisce il tracciato)
    var etaOnly = false
    var advisories: [String] = []

    static func == (lhs: RouteInfo, rhs: RouteInfo) -> Bool { lhs.id == rhs.id }

    var arrival: Date { Date().addingTimeInterval(travelTime) }
    var minutes: Int { max(1, Int((travelTime / 60).rounded())) }

    /// "1 h 25 min" / "22 min"
    var durationText: String { RouteInfo.duration(travelTime) }

    static func duration(_ t: TimeInterval) -> String {
        let m = max(1, Int((t / 60).rounded()))
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }
}

/// Opzioni del percorso (come "Opzioni di percorso" di Google Maps)
struct RouteOptions: Codable, Equatable {
    var avoidTolls = false
    var avoidHighways = false
}

/// Informazioni aggiuntive del luogo selezionato
struct PlaceDetails: Equatable {
    var category: String = ""
    var phone: String?
    var website: URL?
    var carETA: TimeInterval?
    var walkETA: TimeInterval?
}

enum DistanceUnit: String, CaseIterable, Identifiable {
    case metric, imperial
    var id: String { rawValue }

    var title: String {
        switch self {
        case .metric: return "Metrico (KM)"
        case .imperial: return "Imperiale (MI)"
        }
    }

    var shortLabel: String { self == .metric ? "km" : "mi" }

    /// Distanza breve per la navigazione: "350 m" / "1,2 km"
    func short(_ meters: CLLocationDistance) -> String {
        if self == .metric {
            if meters < 1000 {
                let r = meters < 100 ? (meters / 10).rounded() * 10 : (meters / 50).rounded() * 50
                return "\(Int(max(r, 10))) m"
            }
            return String(format: "%.1f km", meters / 1000).replacingOccurrences(of: ".", with: ",")
        }
        let feet = meters * 3.28084
        if feet < 1000 { return "\(Int((feet / 50).rounded() * 50)) ft" }
        return String(format: "%.1f mi", meters / 1609.344)
    }

    /// Distanza da pronunciare: "350 metri" / "1,2 chilometri"
    func spoken(_ meters: CLLocationDistance) -> String {
        if self == .metric {
            // come la voce di Google Maps: cifre tonde ("Tra 300 metri", "Tra 1,5 chilometri", "Tra 12 chilometri")
            if meters < 950 {
                let r = meters < 100 ? (meters / 10).rounded() * 10
                    : meters < 300 ? (meters / 50).rounded() * 50 : (meters / 100).rounded() * 100
                return "\(Int(max(r, 10))) metri"
            }
            let km = meters >= 9_950 ? String(Int((meters / 1000).rounded()))
                : String(format: "%.1f", meters / 1000).replacingOccurrences(of: ".0", with: "")
                    .replacingOccurrences(of: ".", with: ",")
            return km == "1" ? "1 chilometro" : "\(km) chilometri"
        }
        let feet = meters * 3.28084
        if feet < 1000 { return "\(Int((feet / 50).rounded() * 50)) piedi" }
        return String(format: "%.1f miglia", meters / 1609.344)
    }

    func value(_ meters: CLLocationDistance) -> String {
        let v = self == .metric ? meters / 1000 : meters / 1609.344
        if v < 10 { return String(format: "%.1f", v).replacingOccurrences(of: ".0", with: "") }
        return String(Int(v.rounded()))
    }
}

enum Formatters {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "HH:mm"
        return f
    }()

    static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEEE, HH:mm"
        return f
    }()
}


/// Elenchi delle posizioni salvate (come Google Maps)
enum SavedList: String, CaseIterable, Identifiable {
    case favorites = "Preferiti", toVisit = "Da visitare", starred = "Luoghi speciali"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .favorites: return "heart.fill"
        case .toVisit: return "flag.fill"
        case .starred: return "star.fill"
        }
    }
}

/// Plus Code (Open Location Code), il codice di posizione mostrato da Google Maps
enum PlusCode {
    private static let alphabet = Array("23456789CFGHJMPQRVWX")

    static func encode(latitude: Double, longitude: Double) -> String {
        var lat = min(max(latitude, -90), 90)
        if lat >= 90 { lat = 89.9999999 }
        var lon = longitude
        while lon < -180 { lon += 360 }
        while lon >= 180 { lon -= 360 }
        var latV = lat + 90, lonV = lon + 180
        var code = ""
        var res = 20.0
        for i in 0..<5 {
            let la = min(19, max(0, Int(floor(latV / res + 1e-10))))
            let lo = min(19, max(0, Int(floor(lonV / res + 1e-10))))
            latV -= Double(la) * res
            lonV -= Double(lo) * res
            code.append(alphabet[la])
            code.append(alphabet[lo])
            if i == 3 { code.append("+") }
            res /= 20
        }
        return code
    }
}

/// Coordinate scritte nella ricerca ("40.85, 14.26" oppure "40,85 14,26")
enum CoordinateParser {
    static func parse(_ text: String) -> CLLocationCoordinate2D? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        let pattern = #"^\s*(-?\d{1,2}(?:[.,]\d+)?)\s*[,; ]\s*(-?\d{1,3}(?:[.,]\d+)?)\s*$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let r1 = Range(m.range(at: 1), in: cleaned), let r2 = Range(m.range(at: 2), in: cleaned) else { return nil }
        let a = Double(cleaned[r1].replacingOccurrences(of: ",", with: "."))
        let b = Double(cleaned[r2].replacingOccurrences(of: ",", with: "."))
        guard let lat = a, let lon = b, abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
