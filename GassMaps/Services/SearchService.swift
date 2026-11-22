import Foundation
import MapKit

final class SearchService: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query: String = "" {
        didSet { updateQuery() }
    }
    @Published var completions: [MKLocalSearchCompletion] = []
    @Published var categoryResults: [MKMapItem] = []
    @Published var activeCategory: String?
    @Published var isSearching = false

    private let completer = MKLocalSearchCompleter()
    var region: MKCoordinateRegion? {
        didSet { if let r = region { completer.region = r } }
    }

    static let nearbyCategories: [String] = [
        "Stazione di servizio", "Ristorante", "Caffè", "Hotel", "Parcheggio",
        "Farmacia", "Supermercato", "Ospedale", "Bancomat", "Palestra"
    ]

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest, .query]
    }

    private func updateQuery() {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            completions = []
            completer.cancel()
        } else {
            activeCategory = nil
            completer.queryFragment = q
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        DispatchQueue.main.async {
            self.completions = Array(completer.results.prefix(20))
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}

    /// posizione di riferimento per ordinare i risultati per vicinanza
    var userLocation: CLLocation?

    /// Risolve un suggerimento: se è una ricerca generica (es. "pizzerie") restituisce tutti i risultati
    func resolveAll(_ completion: MKLocalSearchCompletion, done: @escaping ([MKMapItem], Bool) -> Void) {
        let request = MKLocalSearch.Request(completion: completion)
        if let r = region { request.region = r }
        let title = completion.title, subtitle = completion.subtitle
        let user = userLocation
        MKLocalSearch(request: request).start { response, _ in
            var items = response?.mapItems ?? []
            let isQuery = items.count > 1 && !items.contains { ($0.name ?? "").caseInsensitiveCompare(title) == .orderedSame }
            if let user = user {
                items.sort { ($0.placemark.location?.distance(from: user) ?? .infinity)
                    < ($1.placemark.location?.distance(from: user) ?? .infinity) }
            }
            if !isQuery, let best = SearchService.bestMatch(items, title: title, subtitle: subtitle, near: user) {
                items = [best]
            }
            DispatchQueue.main.async { done(Array(items.prefix(25)), isQuery) }
        }
    }

    func resolve(_ completion: MKLocalSearchCompletion, done: @escaping (MKMapItem?) -> Void) {
        let request = MKLocalSearch.Request(completion: completion)
        if let r = region { request.region = r }
        let title = completion.title
        let subtitle = completion.subtitle
        let user = userLocation
        MKLocalSearch(request: request).start { response, _ in
            let items = response?.mapItems ?? []
            let best = SearchService.bestMatch(items, title: title, subtitle: subtitle, near: user)
            DispatchQueue.main.async { done(best) }
        }
    }

    /// Sceglie il risultato che corrisponde davvero al suggerimento toccato:
    /// stesso nome e indirizzo coerente con il sottotitolo; a parità, il più vicino.
    static func bestMatch(_ items: [MKMapItem], title: String, subtitle: String, near: CLLocation?) -> MKMapItem? {
        guard !items.isEmpty else { return nil }
        func norm(_ s: String) -> String {
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        let t = norm(title)
        let subTokens = Set(norm(subtitle).split(separator: " ").map(String.init).filter { $0.count > 1 })
        func score(_ item: MKMapItem) -> Double {
            var sc = 0.0
            let name = norm(item.name ?? "")
            if name == t { sc += 100 } else if name.contains(t) || t.contains(name) { sc += 40 }
            let pm = item.placemark
            let addr = norm([pm.thoroughfare, pm.subThoroughfare, pm.postalCode, pm.locality,
                             pm.subLocality, pm.administrativeArea, pm.subAdministrativeArea, pm.country,
                             pm.title].compactMap { $0 }.joined(separator: " "))
            let addrTokens = Set(addr.split(separator: " ").map(String.init))
            if !subTokens.isEmpty {
                let hit = Double(subTokens.intersection(addrTokens).count) / Double(subTokens.count)
                sc += hit * 80
            }
            if let near = near, let loc = pm.location {
                sc -= min(loc.distance(from: near) / 1000, 200) * 0.05
            }
            return sc
        }
        return items.max { score($0) < score($1) }
    }

    func searchCategory(_ name: String) {
        let user = userLocation
        activeCategory = name
        isSearching = true
        categoryResults = []
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = name
        request.resultTypes = .pointOfInterest
        if let r = region { request.region = r }
        MKLocalSearch(request: request).start { [weak self] response, _ in
            var items = response?.mapItems ?? []
            if let user = user {
                items.sort { ($0.placemark.location?.distance(from: user) ?? .infinity)
                    < ($1.placemark.location?.distance(from: user) ?? .infinity) }
            }
            DispatchQueue.main.async {
                self?.isSearching = false
                self?.categoryResults = items
            }
        }
    }

    /// Tutti i risultati per il testo cercato, i più pertinenti/vicini per primi
    func searchAll(done: @escaping ([MKMapItem]) -> Void) {
        // coordinate scritte a mano → punto esatto
        if let c = CoordinateParser.parse(query) {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: c))
            item.name = String(format: "%.6f, %.6f", c.latitude, c.longitude)
            done([item])
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let r = region { request.region = r }
        let q = query
        let user = userLocation
        MKLocalSearch(request: request).start { response, _ in
            var items = response?.mapItems ?? []
            if let best = SearchService.bestMatch(items, title: q, subtitle: "", near: user),
               let i = items.firstIndex(of: best) {
                items.remove(at: i)
                items.insert(best, at: 0)
            }
            DispatchQueue.main.async { done(Array(items.prefix(25))) }
        }
    }

    func searchText(done: @escaping (MKMapItem?) -> Void) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let r = region { request.region = r }
        let q = query
        let user = userLocation
        MKLocalSearch(request: request).start { response, _ in
            let best = SearchService.bestMatch(response?.mapItems ?? [], title: q, subtitle: "", near: user)
            DispatchQueue.main.async { done(best) }
        }
    }
}

enum DirectionsService {
    private static func request(from: CLLocationCoordinate2D?, to: CLLocationCoordinate2D,
                                destinationItem: MKMapItem?, mode: TravelMode,
                                options: RouteOptions, departure: Date? = nil) -> MKDirections.Request {
        let request = MKDirections.Request()
        if let d = departure { request.departureDate = d }
        if let from = from {
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        } else {
            request.source = MKMapItem.forCurrentLocation()
        }
        request.destination = destinationItem ?? MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = mode.mkType
        if mode == .car {
            request.tollPreference = options.avoidTolls ? .avoid : .any
            request.highwayPreference = options.avoidHighways ? .avoid : .any
        }
        return request
    }

    /// Percorsi verso la destinazione (con alternative, come Google Maps), ordinati dal più veloce.
    /// Per i mezzi pubblici MapKit restituisce solo il tempo stimato.
    static func routes(from: CLLocationCoordinate2D?, to: CLLocationCoordinate2D, destinationItem: MKMapItem? = nil,
                       mode: TravelMode = .car, options: RouteOptions = RouteOptions(), alternatives: Bool = true,
                       departure: Date? = nil, completion: @escaping ([RouteInfo]) -> Void) {
        let req = request(from: from, to: to, destinationItem: destinationItem, mode: mode, options: options,
                          departure: departure)
        if mode == .transit {
            MKDirections(request: req).calculateETA { response, _ in
                guard let r = response else {
                    DispatchQueue.main.async { completion([]) }
                    return
                }
                let info = RouteInfo(coordinates: [], travelTime: r.expectedTravelTime, distance: r.distance,
                                     name: "Mezzi pubblici", mode: .transit, etaOnly: true)
                DispatchQueue.main.async { completion([info]) }
            }
            return
        }
        req.requestsAlternateRoutes = alternatives
        MKDirections(request: req).calculate { response, _ in
            let infos = (response?.routes ?? []).map { route -> RouteInfo in
                let poly = route.polyline
                var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: poly.pointCount)
                poly.getCoordinates(&coords, range: NSRange(location: 0, length: poly.pointCount))
                var steps: [RouteStep] = []
                var along: CLLocationDistance = 0
                var startStreet: String? = nil
                for (k, step) in route.steps.enumerated() {
                    let sp = step.polyline
                    var sc = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: sp.pointCount)
                    sp.getCoordinates(&sc, range: NSRange(location: 0, length: sp.pointCount))
                    let text = step.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                    if k == 0 {
                        // il primo passo di MapKit è la partenza (spesso senza testo): prima veniva scartato e
                        // la prima svolta vera finiva a distanza 0, quindi veniva saltata durante la guida.
                        // Ora la partenza è un passo a sé, scritto come Google Maps.
                        startStreet = Departure.street(in: text)
                    } else if !text.isEmpty, let first = sc.first {
                        steps.append(RouteStep(instruction: text, distance: step.distance,
                                               coordinate: first, startDistance: along))
                    }
                    along += step.distance
                }
                if !coords.isEmpty {
                    steps.insert(Departure.step(coords: coords, street: startStreet,
                                                firstManeuver: steps.first?.instruction), at: 0)
                }
                // posizione esatta delle manovre sul tracciato e verifica destra/sinistra
                steps = ManeuverRefiner.refine(steps, on: coords)
                // lunghezza di ogni tratto misurata sul tracciato (come l'elenco "Passaggi" di Google Maps)
                let total = RouteMath.cumulative(coords).last ?? route.distance
                for i in steps.indices {
                    let end = i + 1 < steps.count ? steps[i + 1].startDistance : total
                    steps[i].distance = max(0, end - steps[i].startDistance)
                }
                return RouteInfo(coordinates: coords, travelTime: route.expectedTravelTime, distance: route.distance,
                                 steps: steps, name: route.name, mode: mode,
                                 hasTolls: route.hasTolls, hasHighways: route.hasHighways,
                                 advisories: route.advisoryNotices)
            }
            .sorted { $0.travelTime < $1.travelTime }
            // nome della via di partenza dalla posizione reale
            DispatchQueue.main.async { Departure.addStreetName(to: infos, completion: completion) }
        }
    }

    /// Compatibilità: un solo percorso in auto
    static func route(from: CLLocationCoordinate2D?, to: CLLocationCoordinate2D, destinationItem: MKMapItem? = nil,
                      completion: @escaping (RouteInfo?) -> Void) {
        routes(from: from, to: to, destinationItem: destinationItem, alternatives: false) { completion($0.first) }
    }

    /// Percorso con una tappa intermedia: due tratte unite in un unico percorso
    static func routesVia(from: CLLocationCoordinate2D?, stop: Place, to: CLLocationCoordinate2D,
                          destinationItem: MKMapItem?, mode: TravelMode, options: RouteOptions, departure: Date?,
                          completion: @escaping ([RouteInfo]) -> Void) {
        DirectionsService.routes(from: from, to: stop.coordinate, mode: mode, options: options, alternatives: false,
               departure: departure) { first in
            guard let a = first.first else { completion([]); return }
            DirectionsService.routes(from: stop.coordinate, to: to, destinationItem: destinationItem, mode: mode, options: options,
                   alternatives: false, departure: departure?.addingTimeInterval(a.travelTime)) { second in
                guard let b = second.first else { completion([]); return }
                // le distanze delle manovre sono misurate sul tracciato: si sfasa la seconda tratta
                // della lunghezza reale del tracciato della prima
                let legA = RouteMath.cumulative(a.coordinates).last ?? a.distance
                let steps = a.steps + b.steps.map { st -> RouteStep in
                    var c = st
                    c.startDistance += legA
                    return c
                }
                let merged = RouteInfo(coordinates: a.coordinates + b.coordinates.dropFirst(),
                                       travelTime: a.travelTime + b.travelTime, distance: a.distance + b.distance,
                                       steps: steps, name: "tappa: \(stop.name.isEmpty ? "posizione" : stop.name)",
                                       mode: mode, hasTolls: a.hasTolls || b.hasTolls,
                                       hasHighways: a.hasHighways || b.hasHighways,
                                       advisories: a.advisories + b.advisories)
                completion([merged])
            }
        }
    }

    /// Solo il tempo di percorrenza (per le schede delle modalità e la scheda del luogo)
    static func eta(from: CLLocationCoordinate2D? = nil, to: CLLocationCoordinate2D, destinationItem: MKMapItem?,
                    mode: TravelMode, departure: Date? = nil, completion: @escaping (TimeInterval?) -> Void) {
        let req = request(from: from, to: to, destinationItem: destinationItem, mode: mode, options: RouteOptions(),
                          departure: departure)
        MKDirections(request: req).calculateETA { response, _ in
            DispatchQueue.main.async { completion(response?.expectedTravelTime) }
        }
    }
}

enum PlaceLookup {
    /// Cerca il luogo reale vicino alle coordinate (per telefono, sito web, categoria e ingresso preciso).
    static func find(name: String, near coordinate: CLLocationCoordinate2D, completion: @escaping (MKMapItem?) -> Void) {
        guard !name.isEmpty else { completion(nil); return }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = name
        req.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500)
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        MKLocalSearch(request: req).start { response, _ in
            let items = (response?.mapItems ?? []).filter {
                ($0.placemark.location?.distance(from: target) ?? .infinity) < 300
            }
            let best = SearchService.bestMatch(items, title: name, subtitle: "", near: target)
            DispatchQueue.main.async { completion(best) }
        }
    }

    static func categoryName(_ c: MKPointOfInterestCategory?) -> String {
        guard let c = c else { return "" }
        let map: [MKPointOfInterestCategory: String] = [
            .restaurant: "Ristorante", .cafe: "Caffè", .bakery: "Panetteria", .brewery: "Birreria",
            .winery: "Enoteca", .nightlife: "Locale notturno", .foodMarket: "Supermercato", .store: "Negozio",
            .pharmacy: "Farmacia", .hospital: "Ospedale", .police: "Polizia", .fireStation: "Vigili del fuoco",
            .bank: "Banca", .atm: "Bancomat", .hotel: "Hotel", .campground: "Campeggio", .school: "Scuola",
            .university: "Università", .library: "Biblioteca", .museum: "Museo", .theater: "Teatro",
            .movieTheater: "Cinema", .park: "Parco", .nationalPark: "Parco nazionale", .beach: "Spiaggia",
            .fitnessCenter: "Palestra", .stadium: "Stadio", .gasStation: "Stazione di servizio",
            .evCharger: "Ricarica elettrica", .parking: "Parcheggio", .publicTransport: "Trasporti pubblici",
            .airport: "Aeroporto", .postOffice: "Ufficio postale", .laundry: "Lavanderia",
            .carRental: "Autonoleggio", .restroom: "Bagni pubblici", .amusementPark: "Parco divertimenti",
            .aquarium: "Acquario", .zoo: "Zoo", .marina: "Porto turistico"
        ]
        return map[c] ?? ""
    }
}
