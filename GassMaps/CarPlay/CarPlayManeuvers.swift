import UIKit
import CarPlay

/// Traduce le istruzioni di Apple Maps (le stesse del telefono) nei dati che CarPlay usa
/// per la scheda di guida, le notifiche, il quadro strumenti e l'head-up display (metadati di navigazione, iOS 17.4+).
/// I valori degli enum di CarPlay sono presi da CPManeuver.h dell'SDK di iOS 26.
@MainActor
enum CarPlayManeuvers {

    // CPManeuverType (CPManeuver.h)
    enum Kind: UInt {
        case noTurn = 0, leftTurn = 1, rightTurn = 2, straightAhead = 3, uTurn = 4, followRoad = 5
        case enterRoundabout = 6, exitRoundabout = 7, offRamp = 8, onRamp = 9
        case startRoute = 11, arriveAtDestination = 12, keepLeft = 13, keepRight = 14
        case enterFerry = 15, exitFerry = 16, uTurnAtRoundabout = 19
        case highwayOffRampLeft = 22, highwayOffRampRight = 23
        case arriveAtDestinationLeft = 24, arriveAtDestinationRight = 25
        case sharpLeftTurn = 47, sharpRightTurn = 48, slightLeftTurn = 49, slightRightTurn = 50
    }

    /// CPManeuverTypeRoundaboutExit1 = 28 … RoundaboutExit19 = 46
    static func roundaboutExitRaw(_ n: Int) -> UInt { UInt(27 + min(max(n, 1), 19)) }

    // CPManeuverState (NSInteger): continue, initial, prepare, execute
    enum Phase: Int { case `continue` = 0, initial = 1, prepare = 2, execute = 3 }

    /// Paesi con guida a sinistra (rotonde in senso orario)
    private static let leftHandTraffic: Set<String> = [
        "GB", "IE", "MT", "CY", "JP", "AU", "NZ", "ZA", "IN", "PK", "BD", "LK", "TH", "MY", "SG", "ID",
        "HK", "MO", "KE", "TZ", "UG", "ZM", "ZW", "BW", "NA", "MZ", "MW", "JM", "TT", "BS", "BB", "GY", "SR"
    ]

    static var drivesOnLeft: Bool {
        leftHandTraffic.contains(Locale.current.region?.identifier ?? "IT")
    }

    // MARK: Tipo di manovra

    /// Tipo di manovra CarPlay dal testo di Apple Maps; la geometria solo se il testo non dice nulla.
    static func typeRaw(for step: RouteStep) -> UInt {
        if step.isDeparture { return Kind.startRoute.rawValue }
        let m = Departure.maneuver(of: step.instruction).lowercased()
        func has(_ w: String...) -> Bool { w.contains { m.contains($0) } }
        let right = has("destra", "right")
        let left = has("sinistra", "left")

        if has("arriv", "destinazione", "destination") {
            if right { return Kind.arriveAtDestinationRight.rawValue }
            if left { return Kind.arriveAtDestinationLeft.rawValue }
            return Kind.arriveAtDestination.rawValue
        }
        let roundabout = has("rotonda", "rotatoria", "roundabout")
        if has("inversione", "u-turn", "make a u") {
            return roundabout ? Kind.uTurnAtRoundabout.rawValue : Kind.uTurn.rawValue
        }
        if roundabout {
            if let n = exitNumber(in: m) { return roundaboutExitRaw(n) }
            if has("esci dalla", "lascia la", "exit the") { return Kind.exitRoundabout.rawValue }
            return Kind.enterRoundabout.rawValue
        }
        if has("traghetto", "ferry") {
            return has("scendi", "sbarca", "esci", "exit", "leave") ? Kind.exitFerry.rawValue : Kind.enterFerry.rawValue
        }
        if has("rampa", "ramp", "immettiti", "merge"), !has("uscita", "esci", "exit", "svincolo") {
            return Kind.onRamp.rawValue
        }
        if has("uscita", "esci", "svincolo", "exit", "off-ramp") {
            if left { return Kind.highwayOffRampLeft.rawValue }
            if right { return Kind.highwayOffRampRight.rawValue }
            return Kind.offRamp.rawValue
        }
        if has("decisamente", "sharp", "stretta") {
            if right { return Kind.sharpRightTurn.rawValue }
            if left { return Kind.sharpLeftTurn.rawValue }
        }
        if has("leggermente", "slight", "bear") {
            if right { return Kind.slightRightTurn.rawValue }
            if left { return Kind.slightLeftTurn.rawValue }
        }
        if has("mantieni", "tieni", "rimani", "resta", "bivio", "keep", "stay") {
            if right { return Kind.keepRight.rawValue }
            if left { return Kind.keepLeft.rawValue }
        }
        if right { return Kind.rightTurn.rawValue }
        if left { return Kind.leftTurn.rawValue }
        if has("dritto", "diritto", "straight") { return Kind.straightAhead.rawValue }
        if has("continua", "prosegui", "procedi", "continue", "head", "proceed") { return Kind.followRoad.rawValue }

        // il testo non dice da che parte: angolo misurato sul tracciato
        guard let a = step.turnAngle else { return Kind.straightAhead.rawValue }
        let d = abs(a)
        if d < 15 { return Kind.straightAhead.rawValue }
        if d < 40 { return a > 0 ? Kind.slightRightTurn.rawValue : Kind.slightLeftTurn.rawValue }
        if d < 120 { return a > 0 ? Kind.rightTurn.rawValue : Kind.leftTurn.rawValue }
        if d < 160 { return a > 0 ? Kind.sharpRightTurn.rawValue : Kind.sharpLeftTurn.rawValue }
        return Kind.uTurn.rawValue
    }

    static func isRoundabout(_ step: RouteStep) -> Bool {
        let m = Departure.maneuver(of: step.instruction).lowercased()
        return ["rotonda", "rotatoria", "roundabout"].contains { m.contains($0) }
    }

    /// Numero dell'uscita alla rotonda: "prendi la terza uscita", "2ª uscita", "take the 1st exit"
    static func exitNumber(in s: String) -> Int? {
        let words = ["prima": 1, "seconda": 2, "terza": 3, "quarta": 4, "quinta": 5, "sesta": 6, "settima": 7,
                     "ottava": 8, "nona": 9, "decima": 10,
                     "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
                     "eighth": 8, "ninth": 9, "tenth": 10]
        for (w, n) in words where s.contains("\(w) uscita") || s.contains("\(w) exit") { return n }
        let pattern = "(\\d{1,2})\\s*(?:ª|°|º|a|st|nd|rd|th)?\\s*(?:uscita|exit)"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        if let match = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges > 1,
           let n = Int(ns.substring(with: match.range(at: 1))), n > 0 {
            return n
        }
        return nil
    }

    // MARK: Immagini

    /// Freccia della manovra in due varianti (chiara su sfondo scuro, scura su sfondo chiaro), come chiede CarPlay
    static func image(_ symbol: String, size: CGFloat) -> UIImage? {
        let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: .bold)
        guard let base = UIImage(systemName: symbol, withConfiguration: cfg) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        func tinted(_ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: base.size, format: format).image { _ in
                base.withTintColor(color, renderingMode: .alwaysOriginal).draw(in: CGRect(origin: .zero, size: base.size))
            }
        }
        let asset = UIImageAsset()
        asset.register(tinted(.black), with: UITraitCollection(userInterfaceStyle: .light))
        asset.register(tinted(.white), with: UITraitCollection(userInterfaceStyle: .dark))
        return asset.image(with: UITraitCollection(userInterfaceStyle: .dark))
    }
}
