import Foundation
import CoreLocation
import AVFoundation

/// Avanzamento lungo il percorso (calcolato ad ogni posizione GPS).
struct RouteProgress: Equatable {
    /// distanza percorsa dall'inizio del percorso
    var traveled: CLLocationDistance = 0
    /// distanza mancante all'arrivo
    var remaining: CLLocationDistance = 0
    /// distanza minima dalla linea del percorso (per capire se si è fuori percorso)
    var offset: CLLocationDistance = 0
    /// indice della prossima manovra in `RouteInfo.steps`
    var nextStep: Int = 0
    /// distanza alla prossima manovra
    var toManeuver: CLLocationDistance = 0
    /// tempo mancante stimato
    var remainingTime: TimeInterval = 0
}

enum RouteMath {
    /// metri tra due coordinate (approssimazione locale, precisa a scala urbana)
    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let k = 111_320.0
        let dx = (b.longitude - a.longitude) * k * cos((a.latitude + b.latitude) / 2 * .pi / 180)
        let dy = (b.latitude - a.latitude) * k
        return sqrt(dx * dx + dy * dy)
    }

    /// distanze cumulative lungo la polilinea
    static func cumulative(_ coords: [CLLocationCoordinate2D]) -> [Double] {
        var out = [Double](repeating: 0, count: coords.count)
        for i in 1..<max(coords.count, 1) where i < coords.count {
            out[i] = out[i - 1] + meters(coords[i - 1], coords[i])
        }
        return out
    }

    /// proiezione del punto sulla polilinea: (distanza lungo il percorso, distanza dalla linea)
    /// Punto sul percorso a una certa distanza dall'inizio, con la direzione del tratto
    static func point(at along: Double, on coords: [CLLocationCoordinate2D], cumulative cum: [Double],
                      hint: Int = 0) -> (coordinate: CLLocationCoordinate2D, bearing: Double, index: Int) {
        guard coords.count > 1, cum.count == coords.count else {
            return (coords.first ?? CLLocationCoordinate2D(), 0, 0)
        }
        var i = max(0, min(hint, coords.count - 2))
        while i > 0 && cum[i] > along { i -= 1 }
        while i < coords.count - 2 && cum[i + 1] < along { i += 1 }
        let a = coords[i], b = coords[i + 1]
        let seg = max(cum[i + 1] - cum[i], 0.0001)
        let t = min(max((along - cum[i]) / seg, 0), 1)
        let c = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                       longitude: a.longitude + (b.longitude - a.longitude) * t)
        return (c, MapController.bearing(from: a, to: b), i)
    }

    static func project(_ p: CLLocationCoordinate2D, on coords: [CLLocationCoordinate2D],
                        cumulative cum: [Double], from startIndex: Int = 0) -> (along: Double, offset: Double, index: Int) {
        guard coords.count > 1 else { return (0, coords.first.map { meters($0, p) } ?? 0, 0) }
        let k = 111_320.0
        let cosLat = cos(p.latitude * .pi / 180)
        var best = (along: 0.0, offset: Double.greatestFiniteMagnitude, index: 0)
        let lower = max(0, startIndex - 5)
        for i in lower..<(coords.count - 1) {
            let a = coords[i], b = coords[i + 1]
            let ax = (a.longitude - p.longitude) * k * cosLat, ay = (a.latitude - p.latitude) * k
            let bx = (b.longitude - p.longitude) * k * cosLat, by = (b.latitude - p.latitude) * k
            let vx = bx - ax, vy = by - ay
            let len2 = vx * vx + vy * vy
            var t = len2 > 0 ? -(ax * vx + ay * vy) / len2 : 0
            t = min(max(t, 0), 1)
            let cx = ax + t * vx, cy = ay + t * vy
            let d = sqrt(cx * cx + cy * cy)
            if d < best.offset {
                best = (cum[i] + t * sqrt(len2), d, i)
            }
        }
        return best
    }
}

/// Rende le indicazioni più precise:
/// 1) la distanza di ogni manovra è misurata proiettando il punto della manovra sul tracciato
///    (la stessa misura usata per la posizione durante la guida, quindi avvisi al momento giusto);
/// 2) la direzione reale della svolta è calcolata dalla geometria della strada (30 m prima e dopo l'incrocio):
///    se il testo dice il contrario viene corretto, se non indica una direzione la aggiunge.
enum ManeuverRefiner {
    static func refine(_ steps: [RouteStep], on coords: [CLLocationCoordinate2D]) -> [RouteStep] {
        guard coords.count > 1 else { return steps }
        let cum = RouteMath.cumulative(coords)
        let total = cum.last ?? 0
        var out: [RouteStep] = []
        var lastIndex = 0
        var lastAlong = 0.0
        for (i, step) in steps.enumerated() {
            var s = step
            if i == 0 {
                s.startDistance = 0
                out.append(s)
                continue
            }
            let proj = RouteMath.project(step.coordinate, on: coords, cumulative: cum, from: lastIndex)
            let along = max(lastAlong, proj.offset < 60 ? proj.along : step.startDistance)
            lastIndex = proj.index
            lastAlong = along
            s.startDistance = along
            if along > 15 && along < total - 5 {
                // rotonde: si confronta la direzione d'ingresso con quella d'uscita dalla rotonda
                // (il giro intorno all'isola centrale non conta), altrimenti 30 m prima/dopo l'incrocio
                let round = isRoundabout(step.instruction.lowercased())
                let nextStart = i + 1 < steps.count ? steps[i + 1].startDistance : total
                let outFrom = round ? min(along + 35, max(along + 10, nextStart - 25)) : along
                let outTo = round ? min(total, outFrom + 45) : min(total, along + 30)
                let before = RouteMath.point(at: max(0, along - (round ? 45 : 30)), on: coords, cumulative: cum, hint: proj.index)
                let at = RouteMath.point(at: along, on: coords, cumulative: cum, hint: proj.index)
                let outA = RouteMath.point(at: outFrom, on: coords, cumulative: cum, hint: proj.index)
                let after = RouteMath.point(at: outTo, on: coords, cumulative: cum, hint: proj.index)
                if RouteMath.meters(before.coordinate, at.coordinate) > 5 && RouteMath.meters(outA.coordinate, after.coordinate) > 5 {
                    let bIn = MapController.bearing(from: before.coordinate, to: at.coordinate)
                    let bOut = MapController.bearing(from: outA.coordinate, to: after.coordinate)
                    var a = bOut - bIn
                    while a > 180 { a -= 360 }
                    while a < -180 { a += 360 }
                    s.turnAngle = a
                    s.instruction = corrected(s.instruction, angle: a)
                }
            }
            out.append(s)
        }
        return out
    }

    static func isRoundabout(_ s: String) -> Bool {
        ["rotonda", "rotatoria", "roundabout"].contains { s.contains($0) }
    }

    /// istruzioni che non si correggono (uscite numerate, arrivo, traghetti, inversioni)
    private static func isSpecial(_ s: String) -> Bool {
        if isRoundabout(s) {
            // "Alla rotonda, gira a sinistra/destra" si verifica; "prendi la 2ª uscita" no
            return !(s.contains("sinistra") || s.contains("destra") || s.contains("left") || s.contains("right"))
        }
        return ["uscita", "exit", "svincolo", "arriv", "destinazione",
                "destination", "traghetto", "ferry", "inversione", "u-turn"].contains { s.contains($0) }
    }

    static func corrected(_ text: String, angle a: Double) -> String {
        let s = text.lowercased()
        guard !isSpecial(s) else { return text }
        let saysLeft = s.contains("sinistra") || s.contains("left")
        let saysRight = s.contains("destra") || s.contains("right")
        // il testo contraddice chiaramente la geometria → si corregge la direzione
        // (alle rotonde basta una differenza più piccola: l'uscita è già misurata dopo il giro)
        let limit = isRoundabout(s) ? 30.0 : 50.0
        if saysLeft && !saysRight && a > limit {
            return text.replacingOccurrences(of: "sinistra", with: "destra")
                .replacingOccurrences(of: "Sinistra", with: "Destra")
                .replacingOccurrences(of: "left", with: "right").replacingOccurrences(of: "Left", with: "Right")
        }
        if saysRight && !saysLeft && a < -limit {
            return text.replacingOccurrences(of: "destra", with: "sinistra")
                .replacingOccurrences(of: "Destra", with: "Sinistra")
                .replacingOccurrences(of: "right", with: "left").replacingOccurrences(of: "Right", with: "Left")
        }
        // nessuna direzione nel testo ma la strada gira davvero → si aggiunge
        if !saysLeft && !saysRight && abs(a) >= 35 && !isRoundabout(s) {
            let side = a > 0 ? "destra" : "sinistra"
            if s.hasPrefix("svolta ") {
                return "Svolta a \(side) " + text.dropFirst("svolta ".count)
            }
            let prefix = abs(a) < 60 ? "Tieni la \(side)" : "Svolta a \(side)"
            return "\(prefix) e \(text.prefix(1).lowercased() + text.dropFirst())"
        }
        return text
    }
}

/// Primo passo del percorso come Google Maps: "Procedi in direzione nord su Via Roma verso Via Verdi".
/// La direzione è misurata sui primi metri del tracciato (che parte dalla tua posizione),
/// la via di partenza viene dalla posizione reale (geocodifica inversa), quella verso cui vai dalla prima manovra.
enum Departure {
    static let cardinals = ["nord", "nord-est", "est", "sud-est", "sud", "sud-ovest", "ovest", "nord-ovest"]

    static func cardinal(_ bearing: Double) -> String {
        var b = bearing.truncatingRemainder(dividingBy: 360)
        if b < 0 { b += 360 }
        return cardinals[Int((b + 22.5) / 45) % 8]
    }

    /// direzione dei primi ~40 m del tracciato
    static func initialBearing(_ coords: [CLLocationCoordinate2D]) -> Double? {
        guard coords.count > 1 else { return nil }
        let cum = RouteMath.cumulative(coords)
        guard let total = cum.last, total > 3 else { return nil }
        let p = RouteMath.point(at: min(40, total), on: coords, cumulative: cum)
        return MapController.bearing(from: coords[0], to: p.coordinate)
    }

    /// Nome della strada in un'istruzione ("Svolta a destra in Via Roma" → "Via Roma",
    /// "Mantieni la sinistra verso A1" → "A1"). I nomi di strada iniziano con maiuscola o cifra.
    static func street(in instruction: String) -> String? {
        let markers = [" in ", " su ", " sulla ", " sul ", " verso ", " imbocca ", " per ", " onto ", " on ", " toward "]
        var best: (pos: String.Index, rest: Substring)? = nil
        for m in markers {
            var searchFrom = instruction.startIndex
            while let r = instruction.range(of: m, range: searchFrom..<instruction.endIndex) {
                let rest = instruction[r.upperBound...]
                if let c = rest.first, c.isUppercase || c.isNumber {
                    if best == nil || r.lowerBound < best!.pos { best = (r.lowerBound, rest) }
                    break
                }
                searchFrom = r.upperBound
            }
        }
        guard let rest = best?.rest else { return nil }
        let name = rest.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:"))
        return name.isEmpty ? nil : name
    }

    static func text(bearing: Double?, street: String?, toward: String?) -> String {
        var s = "Procedi"
        if let b = bearing { s += " in direzione \(cardinal(b))" }
        if let st = street, !st.isEmpty { s += " su \(st)" }
        if let t = toward, !t.isEmpty, t.lowercased() != street?.lowercased() { s += " verso \(t)" }
        return s == "Procedi" ? "Procedi lungo il percorso" : s
    }

    static func step(coords: [CLLocationCoordinate2D], street: String?, firstManeuver: String?) -> RouteStep {
        let bearing = initialBearing(coords)
        let toward = firstManeuver.flatMap { Departure.street(in: $0) }
        var st = RouteStep(instruction: text(bearing: bearing, street: street, toward: toward), distance: 0,
                           coordinate: coords.first ?? CLLocationCoordinate2D(), startDistance: 0)
        st.isDeparture = true
        st.departureBearing = bearing
        st.toward = toward
        return st
    }

    /// Aggiunge al passo di partenza il nome della via in cui ti trovi (come Google Maps).
    /// Se la geocodifica non risponde entro 1,5 s si prosegue senza.
    static func addStreetName(to infos: [RouteInfo], completion: @escaping ([RouteInfo]) -> Void) {
        guard let start = infos.first?.coordinates.first, CLLocationCoordinate2DIsValid(start),
              infos.contains(where: { $0.steps.first?.isDeparture == true }) else {
            completion(infos)
            return
        }
        var finished = false
        let geocoder = CLGeocoder()
        let finish: (String?) -> Void = { street in
            guard !finished else { return }
            finished = true
            geocoder.cancelGeocode()
            guard let street = street, !street.isEmpty else { completion(infos); return }
            completion(infos.map { info in
                var r = info
                if var first = r.steps.first, first.isDeparture {
                    first.instruction = text(bearing: first.departureBearing, street: street, toward: first.toward)
                    r.steps[0] = first
                }
                return r
            })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { finish(nil) }
        geocoder.reverseGeocodeLocation(CLLocation(latitude: start.latitude, longitude: start.longitude),
                                        preferredLocale: Locale(identifier: "it_IT")) { placemarks, _ in
            let name = placemarks?.first?.thoroughfare
            DispatchQueue.main.async { finish(name) }
        }
    }
}

/// Icona della manovra a partire dal testo dell'istruzione (italiano o inglese).
enum ManeuverIcon {
    /// Icona dal tracciato reale della svolta (più affidabile del testo), tranne rotonde, uscite e arrivo
    static func symbol(for step: RouteStep) -> String {
        // partenza: freccia dritta (il testo può contenere nomi di vie come "Via Destra")
        if step.isDeparture { return "arrow.up" }
        let s = step.instruction.lowercased()
        let special = ["uscita", "exit", "svincolo", "arriv",
                       "destinazione", "destination", "traghetto", "ferry", "inversione", "u-turn"].contains { s.contains($0) }
        guard !special || ManeuverRefiner.isRoundabout(s), let a = step.turnAngle else { return symbol(for: step.instruction) }
        let m = abs(a)
        if m < 20 { return "arrow.up" }
        if m < 55 { return a > 0 ? "arrow.up.right" : "arrow.up.left" }
        if m < 150 { return a > 0 ? "arrow.turn.up.right" : "arrow.turn.up.left" }
        return a > 0 ? "arrow.uturn.right" : "arrow.uturn.left"
    }

    static func symbol(for instruction: String) -> String {
        let s = instruction.lowercased()
        func has(_ words: String...) -> Bool { words.contains { s.contains($0) } }
        if has("arriv", "destinazione", "destination") { return "mappin.circle.fill" }
        if has("inversione", "u-turn", "make a u") { return "arrow.uturn.left" }
        if has("rotonda", "roundabout", "rotatoria") { return "arrow.triangle.turn.up.right.circle.fill" }
        if has("uscita", "exit", "svincolo") {
            return has("sinistra", "left") ? "arrow.up.left" : "arrow.up.right"
        }
        if has("leggermente a destra", "slight right", "mantieni la destra", "keep right", "tieni la destra") {
            return "arrow.up.right"
        }
        if has("leggermente a sinistra", "slight left", "mantieni la sinistra", "keep left", "tieni la sinistra") {
            return "arrow.up.left"
        }
        if has("a destra", "turn right", "right onto") { return "arrow.turn.up.right" }
        if has("a sinistra", "turn left", "left onto") { return "arrow.turn.up.left" }
        if has("destra") { return "arrow.turn.up.right" }
        if has("sinistra") { return "arrow.turn.up.left" }
        if has("traghetto", "ferry") { return "ferry.fill" }
        return "arrow.up"
    }
}

/// Guida vocale in italiano (come le indicazioni vocali di Google Maps).
final class VoiceGuide {
    static let shared = VoiceGuide()
    private let synth = AVSpeechSynthesizer()
    var muted = false

    /// `interrupt: false` mette la frase in coda invece di troncare quella in corso
    func speak(_ text: String, interrupt: Bool = true) {
        guard !muted, !text.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        if interrupt, synth.isSpeaking { synth.stopSpeaking(at: .word) }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "it-IT")
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                     AVSpeechUtteranceDefaultSpeechRate * 1.02 * Float(Prefs.double(Prefs.voiceRate, default: 1)))
        u.volume = Float(Prefs.double(Prefs.voiceVolume, default: 0.8))
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
