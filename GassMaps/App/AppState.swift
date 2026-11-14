import SwiftUI
import CoreLocation
import MapKit

enum AppPhase: Equatable {
    case splash, map
}

enum BottomPanelKind: Equatable {
    case none, pinned, directions, navigating, saved, results, myLocation
}

enum TrackingState: Equatable {
    case none, follow, heading
}

/// Cosa sta scegliendo l'utente nella ricerca
enum SearchPurpose: Equatable {
    case destination, origin, stop
}

final class AppState: ObservableObject {
    // MARK: Navigazione schermate
    @Published var phase: AppPhase = .splash
    @Published var showHeader = true
    @Published var showSearch = false
    @Published var showSettings = false
    @Published var showMapSelection = false
    @Published var showSteps = false

    // MARK: Tema
    @Published var themeIndex: Int {
        didSet { UserDefaults.standard.set(themeIndex, forKey: Keys.theme) }
    }
    var theme: MapTheme { Themes.all[themeIndex] }

    // MARK: Pannelli / mappa
    @Published var panel: BottomPanelKind = .none
    @Published var pinnedPlace: Place?
    @Published var placeDetails = PlaceDetails()
    /// luogo esatto restituito dalla ricerca (usato per un percorso preciso verso l'ingresso)
    var destinationItem: MKMapItem?
    @Published var isLoadingRoute = false
    @Published var tracking: TrackingState = .follow
    @Published var routeError: String?
    @Published var mapHeading: Double = 0

    // MARK: Indicazioni (come Google Maps)
    @Published var travelMode: TravelMode = TravelMode(rawValue: UserDefaults.standard.string(forKey: Prefs.defaultMode) ?? "") ?? .car
    @Published var routes: [RouteInfo] = []
    @Published var selectedRoute = 0
    @Published var modeETAs: [TravelMode: TimeInterval] = [:]
    @Published var routeOptions: RouteOptions {
        didSet {
            if let d = try? JSONEncoder().encode(routeOptions) { UserDefaults.standard.set(d, forKey: Keys.options) }
        }
    }
    var route: RouteInfo? { routes.indices.contains(selectedRoute) ? routes[selectedRoute] : nil }
    /// indici (in `routes`) dei percorsi alternativi disegnati in grigio
    var alternativeIndices: [Int] = []

    // MARK: Navigazione svolta per svolta
    @Published var progress = RouteProgress()
    @Published var speedKmh: Int = 0
    @Published var isRerouting = false
    @Published var voiceMuted = false {
        didSet {
            VoiceGuide.shared.muted = voiceMuted
            if voiceMuted { VoiceGuide.shared.stop() }
        }
    }
    @Published var arrived = false
    private var cumulative: [Double] = []
    private var lastProjectionIndex = 0
    private var announced: Set<String> = []
    /// all'avvio il banner mostra "Procedi in direzione … su …" finché non hai percorso i primi metri (come Google Maps)
    private var departing = false
    private var offRouteCount = 0
    private var lastReroute = Date.distantPast
    /// da quando si è fuori percorso / contromano (per decidere il ricalcolo come Google Maps)
    private var offRouteSince: Date?
    private var wrongWaySince: Date?

    // MARK: Partenza personalizzata, tappa, orario (come Google Maps)
    @Published var searchPurpose: SearchPurpose = .destination
    // misura distanza
    @Published var measuring = false
    @Published var measurePoints: [CLLocationCoordinate2D] = []
    @Published var measureDistance: Double = 0
    @Published var showLayers = false
    /// percorsi alternativi mostrati durante la navigazione (pulsante "percorsi" come Google Maps)
    @Published var navAlternatives: [RouteInfo] = []
    @Published var isLoadingAlternatives = false
    @Published var origin: Place? = nil
    @Published var stop: Place? = nil
    @Published var departure: Date? = nil

    // MARK: Risultati di ricerca sulla mappa
    @Published var searchResults: [MKMapItem] = []
    @Published var resultsTitle = ""
    @Published var showSearchArea = false
    private var resultsCenter: CLLocation?

    // MARK: Ricerca lungo il percorso
    @Published var alongRouteResults: [MKMapItem] = []
    @Published var alongRouteQuery = ""
    @Published var showAlongRoute = false
    @Published var isSearchingAlongRoute = false

    // MARK: Dati utente
    @Published var saved: [Place] = [] { didSet { persist(saved, Keys.saved) } }
    @Published var history: [Place] = [] { didSet { persist(history, Keys.history) } }
    @Published var home: Place? = nil { didSet { persistOne(home, Keys.home) } }
    @Published var work: Place? = nil { didSet { persistOne(work, Keys.work) } }
    /// dove ho parcheggiato
    @Published var parking: Place? = nil {
        didSet {
            persistOne(parking, Keys.parking)
            if parking == nil { Notifier.cancelParkingReminder() }
        }
    }
    @Published var explored: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(explored), forKey: Keys.explored) }
    }
    @Published var units: DistanceUnit {
        didSet { UserDefaults.standard.set(units.rawValue, forKey: Keys.units) }
    }

    let location = LocationManager()
    let map = MapController()

    enum Keys {
        static let theme = "gm.theme"
        static let saved = "gm.saved"
        static let history = "gm.history"
        static let explored = "gm.explored"
        static let units = "gm.units"
        static let home = "gm.home"
        static let work = "gm.work"
        static let options = "gm.routeOptions"
        static let parking = "gm.parking"
    }

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: Keys.theme) != nil {
            themeIndex = min(max(d.integer(forKey: Keys.theme), 0), Themes.all.count - 1)
        } else {
            themeIndex = Themes.defaultIndex
        }
        units = DistanceUnit(rawValue: d.string(forKey: Keys.units) ?? "") ?? .metric
        routeOptions = (d.data(forKey: Keys.options)).flatMap { try? JSONDecoder().decode(RouteOptions.self, from: $0) }
            ?? RouteOptions()
        saved = AppState.load(Keys.saved)
        history = AppState.load(Keys.history)
        home = AppState.loadOne(Keys.home)
        work = AppState.loadOne(Keys.work)
        parking = AppState.loadOne(Keys.parking)
        explored = Set(d.stringArray(forKey: Keys.explored) ?? [])
        map.state = self
        location.onUpdate = { [weak self] loc in self?.locationUpdated(loc) }
    }

    private func persist(_ places: [Place], _ key: String) {
        if let data = try? JSONEncoder().encode(places) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func persistOne(_ place: Place?, _ key: String) {
        if let p = place, let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func load(_ key: String) -> [Place] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([Place].self, from: data) else { return [] }
        return list
    }

    private static func loadOne(_ key: String) -> Place? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Place.self, from: data)
    }

    // MARK: - Avvio

    func finishSplash() {
        phase = .map
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            withAnimation(.easeInOut(duration: 0.45)) { self.showHeader = false }
        }
    }

    // MARK: - Luoghi

    /// Pulsante centrale: fissa la posizione al centro della mappa / posizione attuale
    func pinCurrentPosition() {
        let coord = map.centerCoordinate ?? location.location?.coordinate
        guard let c = coord else { return }
        pin(Place(name: "", address: "Ricerca indirizzo...", coordinate: c), fly: false)
        Geocoder.reverse(c) { [weak self] address in
            guard let self = self, var p = self.pinnedPlace, p.latitude == c.latitude else { return }
            p.address = address
            self.pinnedPlace = p
        }
    }

    func pin(_ place: Place, fly: Bool = true, item: MKMapItem? = nil) {
        clearRoute()
        origin = nil
        stop = nil
        departure = nil
        searchPurpose = .destination
        destinationItem = item
        pinnedPlace = place
        panel = .pinned
        map.showPin(place)
        if fly { map.fly(to: place.coordinate) }
        loadDetails(for: place, item: item)
    }

    /// Scheda del luogo: categoria, telefono, sito e tempi di percorrenza (come Google Maps)
    func loadDetails(for place: Place, item: MKMapItem?) {
        placeDetails = PlaceDetails()
        if let item = item {
            applyDetails(item)
        } else if !place.name.isEmpty {
            PlaceLookup.find(name: place.name, near: place.coordinate) { [weak self] found in
                guard let self = self, self.pinnedPlace?.id == place.id, let found = found else { return }
                self.destinationItem = found
                self.applyDetails(found)
                if var p = self.pinnedPlace, p.address.isEmpty || p.address.hasPrefix("Ricerca") {
                    p.address = Place.formatFull(found.placemark)
                    self.pinnedPlace = p
                }
            }
        }
        for mode in [TravelMode.car, .walk] {
            DirectionsService.eta(to: place.coordinate, destinationItem: item, mode: mode) { [weak self] t in
                guard let self = self, self.pinnedPlace?.id == place.id else { return }
                if mode == .car { self.placeDetails.carETA = t } else { self.placeDetails.walkETA = t }
            }
        }
    }

    private func applyDetails(_ item: MKMapItem) {
        placeDetails.category = PlaceLookup.categoryName(item.pointOfInterestCategory)
        placeDetails.phone = item.phoneNumber
        placeDetails.website = item.url
    }

    /// Tocco su un'icona della mappa
    func openPOI(name: String, coordinate: CLLocationCoordinate2D) {
        let place = Place(name: name, address: "", coordinate: coordinate)
        pin(place, fly: true)
        Geocoder.reverse(coordinate) { [weak self] address in
            guard let self = self, var p = self.pinnedPlace, p.id == place.id, p.address.isEmpty else { return }
            p.address = address
            self.pinnedPlace = p
        }
    }

    func select(mapItem: MKMapItem) {
        let place = Place(mapItem: mapItem)
        addToHistory(place)
        choose(place, item: mapItem)
    }

    /// Luogo scelto dalla ricerca: destinazione, punto di partenza o tappa
    func choose(_ place: Place, item: MKMapItem? = nil) {
        showSearch = false
        switch searchPurpose {
        case .origin:
            searchPurpose = .destination
            origin = place
            requestDirections()
        case .stop:
            searchPurpose = .destination
            stop = place
            if panel == .navigating, let loc = location.location { reroute(from: loc) } else { requestDirections() }
        case .destination:
            map.clearResults()
            searchResults = []
            pin(place, item: item)
        }
    }

    /// Inverte partenza e destinazione
    func swapEnds() {
        guard let dest = pinnedPlace else { return }
        let here = location.location.map { Place(name: "La tua posizione", address: "", coordinate: $0.coordinate) }
        guard let newDest = origin ?? here else { return }
        let keepStop = stop
        let newOrigin: Place? = dest
        pinnedPlace = newDest
        destinationItem = nil
        origin = newOrigin
        stop = keepStop
        if origin?.name == "La tua posizione" { origin = nil }
        map.showPin(newDest)
        requestDirections()
    }

    func saveParking() {
        guard let l = location.location else { routeError = "Posizione non disponibile"; return }
        let place = Place(name: "Auto parcheggiata", address: "Salvata alle \(Formatters.time.string(from: Date()))",
                          coordinate: l.coordinate)
        parking = place
        Notifier.scheduleParkingReminder()
        Geocoder.reverse(l.coordinate) { [weak self] address in
            guard let self = self, var p = self.parking, p.id == place.id else { return }
            p.address = address
            self.parking = p
        }
    }

    func addToHistory(_ place: Place) {
        guard Prefs.bool(Prefs.saveHistory, default: true) else { return }
        var h = history.filter { !($0.name == place.name && $0.address == place.address) }
        h.insert(place, at: 0)
        history = Array(h.prefix(15))
    }

    func toggleSave(_ place: Place) {
        if let idx = saved.firstIndex(where: { $0.exploreKey == place.exploreKey && $0.name == place.name }) {
            saved.remove(at: idx)
        } else {
            var p = place
            if p.name.isEmpty { p.name = p.address.components(separatedBy: ",").first ?? "Posizione" }
            saved.insert(p, at: 0)
        }
    }

    /// Salva in un elenco (o sposta il luogo nell'elenco scelto)
    func save(_ place: Place, in list: SavedList) {
        var p = place
        if p.name.isEmpty { p.name = p.address.components(separatedBy: ",").first ?? "Posizione" }
        if let idx = saved.firstIndex(where: { $0.exploreKey == place.exploreKey }) {
            saved[idx].list = list.rawValue
        } else {
            p.list = list.rawValue
            saved.insert(p, at: 0)
        }
    }

    func savedEntry(_ place: Place) -> Place? {
        saved.first { $0.exploreKey == place.exploreKey }
    }

    /// Nota personale sul luogo (lo salva se non lo era)
    func setNote(_ note: String, for place: Place) {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = saved.firstIndex(where: { $0.exploreKey == place.exploreKey }) {
            saved[idx].note = text.isEmpty ? nil : text
        } else if !text.isEmpty {
            var p = place
            if p.name.isEmpty { p.name = p.address.components(separatedBy: ",").first ?? "Posizione" }
            p.note = text
            saved.insert(p, at: 0)
        }
    }

    // MARK: Misura distanza (come Google Maps)

    func startMeasuring(from place: Place) {
        panel = .none
        pinnedPlace = nil
        map.removePin()
        map.setBottomInset(0)
        measurePoints = [place.coordinate]
        measuring = true
        map.mapView?.setUserTrackingMode(.none, animated: false, completionHandler: nil)
        tracking = .none
        map.mapView?.setCenter(place.coordinate, animated: true)
        updateMeasure()
    }

    func addMeasurePoint() {
        guard let c = map.centerCoordinate else { return }
        measurePoints.append(c)
        updateMeasure()
    }

    func undoMeasurePoint() {
        if measurePoints.count > 1 { measurePoints.removeLast() }
        updateMeasure()
    }

    func stopMeasuring() {
        measuring = false
        measurePoints = []
        map.drawMeasure([])
    }

    /// Ridisegna la linea fino al mirino al centro della mappa e aggiorna il totale
    func updateMeasure() {
        guard measuring else { return }
        var pts = measurePoints
        if let c = map.centerCoordinate { pts.append(c) }
        var total = 0.0
        for i in 1..<max(1, pts.count) {
            total += CLLocation(latitude: pts[i - 1].latitude, longitude: pts[i - 1].longitude)
                .distance(from: CLLocation(latitude: pts[i].latitude, longitude: pts[i].longitude))
        }
        measureDistance = total
        map.drawMeasure(pts)
    }

    func isSaved(_ place: Place) -> Bool {
        saved.contains { $0.exploreKey == place.exploreKey }
    }

    func setHome(_ place: Place) { var p = place; if p.name.isEmpty { p.name = "Casa" }; home = p }
    func setWork(_ place: Place) { var p = place; if p.name.isEmpty { p.name = "Lavoro" }; work = p }

    /// Percorso immediato verso Casa / Lavoro
    func go(to place: Place) {
        showSearch = false
        pin(place, fly: false)
        requestDirections()
    }

    // MARK: - Risultati di ricerca (categorie, "Ristoranti vicino a te"…)

    func showResults(_ items: [MKMapItem], title: String) {
        guard !items.isEmpty else {
            routeError = "Nessun risultato per \"\(title)\" in questa zona"
            return
        }
        showSearch = false
        clearRoute()
        pinnedPlace = nil
        map.removePin()
        searchResults = items
        resultsTitle = title
        panel = .results
        showSearchArea = false
        let coords = items.map { $0.placemark.coordinate }
        let lat = coords.map { $0.latitude }.reduce(0, +) / Double(coords.count)
        let lon = coords.map { $0.longitude }.reduce(0, +) / Double(coords.count)
        resultsCenter = CLLocation(latitude: lat, longitude: lon)
        map.showResults(items)
    }

    func searchCategory(_ query: String, inVisibleArea: Bool = false) {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.resultTypes = [.pointOfInterest, .address]
        if inVisibleArea, let r = map.visibleRegion {
            req.region = r
        } else if let c = location.location?.coordinate ?? map.centerCoordinate {
            req.region = MKCoordinateRegion(center: c, latitudinalMeters: 6000, longitudinalMeters: 6000)
        }
        let user = location.location
        MKLocalSearch(request: req).start { [weak self] response, _ in
            var items = response?.mapItems ?? []
            if let user = user {
                items.sort { ($0.placemark.location?.distance(from: user) ?? .infinity)
                    < ($1.placemark.location?.distance(from: user) ?? .infinity) }
            }
            DispatchQueue.main.async { self?.showResults(items, title: query) }
        }
    }

    /// La mappa è stata spostata lontano dai risultati → mostra "Cerca in questa zona"
    func mapMoved() {
        if measuring { updateMeasure() }
        guard panel == .results, let c = map.centerCoordinate, let rc = resultsCenter else { return }
        let moved = CLLocation(latitude: c.latitude, longitude: c.longitude).distance(from: rc) > 900
        if moved != showSearchArea { showSearchArea = moved }
    }

    func searchThisArea() {
        showSearchArea = false
        searchCategory(resultsTitle, inVisibleArea: true)
    }

    func closeResults() {
        searchResults = []
        map.clearResults()
        panel = .none
        map.setBottomInset(0)
    }

    // MARK: - Indicazioni

    func requestDirections(mode: TravelMode? = nil) {
        guard let dest = pinnedPlace else { return }
        if let mode = mode { travelMode = mode }
        let from = origin?.coordinate ?? location.location?.coordinate
        isLoadingRoute = true
        let requested = travelMode
        let handler: ([RouteInfo]) -> Void = { [weak self] infos in
            guard let self = self, self.travelMode == requested else { return }
            self.isLoadingRoute = false
            guard !infos.isEmpty else {
                self.routeError = requested == .transit
                    ? "Nessun collegamento con i mezzi pubblici disponibile per questa destinazione"
                    : "Impossibile calcolare il percorso"
                if self.panel != .directions { return }
                self.routes = []
                self.map.clearRoute()
                return
            }
            self.routes = infos
            self.selectedRoute = 0
            self.panel = .directions
            self.drawRoutes(overview: true)
        }
        if let stop = stop, requested != .transit {
            DirectionsService.routesVia(from: from, stop: stop, to: dest.coordinate, destinationItem: destinationItem,
                                        mode: requested, options: routeOptions, departure: departure, completion: handler)
        } else {
            DirectionsService.routes(from: from, to: dest.coordinate, destinationItem: destinationItem,
                                     mode: requested, options: routeOptions, departure: departure, completion: handler)
        }
        // tempi per tutte le modalità (come le schede in alto di Google Maps)
        for m in TravelMode.allCases {
            DirectionsService.eta(from: from, to: dest.coordinate, destinationItem: destinationItem, mode: m,
                                  departure: departure) { [weak self] t in
                self?.modeETAs[m] = t
            }
        }
    }

    func selectRoute(_ index: Int) {
        guard routes.indices.contains(index) else { return }
        selectedRoute = index
        drawRoutes(overview: false)
    }

    private func drawRoutes(overview: Bool) {
        guard let main = route, !main.etaOnly else {
            map.clearRoute()
            return
        }
        let altPairs = routes.enumerated().filter { $0.offset != selectedRoute && $0.element.coordinates.count > 1 }
        alternativeIndices = altPairs.map { $0.offset }
        map.showRoute(main.coordinates, alternatives: altPairs.map { $0.element.coordinates }, overview: overview)
    }

    /// Indicazioni per i mezzi pubblici nell'app Mappe di Apple (MapKit non fornisce il tracciato dei mezzi)
    func openTransitInMaps() {
        guard let dest = pinnedPlace else { return }
        let item = destinationItem ?? MKMapItem(placemark: MKPlacemark(coordinate: dest.coordinate))
        if item.name == nil { item.name = dest.name.isEmpty ? "Destinazione" : dest.name }
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeTransit])
    }

    /// "Avvia" direttamente dalla scheda del luogo
    func startDirectly() {
        guard let dest = pinnedPlace else { return }
        isLoadingRoute = true
        DirectionsService.routes(from: location.location?.coordinate, to: dest.coordinate,
                                 destinationItem: destinationItem, mode: travelMode == .transit ? .car : travelMode,
                                 options: routeOptions) { [weak self] infos in
            guard let self = self else { return }
            self.isLoadingRoute = false
            guard !infos.isEmpty else { self.routeError = "Impossibile calcolare il percorso"; return }
            self.routes = infos
            self.selectedRoute = 0
            self.drawRoutes(overview: false)
            self.startNavigation()
        }
    }

    // MARK: - Navigazione svolta per svolta

    func startNavigation(announce: Bool = true) {
        guard var r = route, !r.etaOnly else { return }
        // Come Google Maps le indicazioni partono dalla posizione reale:
        // - se il percorso era stato calcolato da un punto diverso (ti sei spostato, o la posizione si è
        //   aggiornata) si ricalcola subito da dove sei;
        // - se sei a pochi metri dall'inizio del tracciato (es. dentro un parcheggio), il tracciato viene
        //   allungato fino a te, così distanze e avvisi si contano dal punto esatto in cui ti trovi.
        var rerouteFrom: CLLocation? = nil
        if origin == nil, let loc = location.location, let start = r.coordinates.first,
           loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 100 {
            if RouteMath.meters(loc.coordinate, start) > max(25, loc.horizontalAccuracy) {
                rerouteFrom = loc
            } else {
                r = anchored(r, at: loc.coordinate)
                if routes.indices.contains(selectedRoute) { routes[selectedRoute] = r }
            }
        }
        // mostra solo il percorso scelto
        map.showRoute(r.coordinates, alternatives: [], overview: false)
        cumulative = RouteMath.cumulative(r.coordinates)
        lastProjectionIndex = 0
        announced = []
        offRouteCount = 0
        arrived = false
        departing = announce
        progress = RouteProgress(traveled: 0, remaining: cumulative.last ?? r.distance, offset: 0,
                                 nextStep: announce ? 0 : (r.steps.count > 1 ? 1 : 0),
                                 toManeuver: r.steps.count > 1 ? r.steps[1].startDistance : r.distance,
                                 remainingTime: r.travelTime)
        panel = .navigating
        location.setNavigating(true)
        UIApplication.shared.isIdleTimerDisabled = Prefs.bool(Prefs.keepAwake, default: true)
        map.startNavigation()
        // a percorso avviato si rifà l'inquadratura di "Riposiziona" quando le animazioni d'avvio
        // (pannello e margini della mappa) sono finite: vista inclinata e ravvicinata fin da subito
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self = self, self.panel == .navigating, self.navAlternatives.isEmpty else { return }
            self.map.startNavigation()
        }
        if let loc = rerouteFrom {
            reroute(from: loc, silent: false)
            return
        }
        announceStart(r, departure: announce)
        if let loc = location.location { updateNavigation(loc) }
    }

    /// Il tracciato parte esattamente dalla posizione indicata: si aggiunge il tratto fino alla strada
    /// e si spostano di conseguenza le manovre (la partenza resta all'inizio e il suo tratto si allunga).
    private func anchored(_ r: RouteInfo, at here: CLLocationCoordinate2D) -> RouteInfo {
        guard let first = r.coordinates.first else { return r }
        let gap = RouteMath.meters(here, first)
        guard gap > 3 else { return r }
        var fixed = r
        fixed.coordinates.insert(here, at: 0)
        fixed.steps = r.steps.enumerated().map { i, st in
            var c = st
            if i > 0 { c.startDistance += gap } else { c.distance += gap }
            if i == 0 { c.coordinate = here }
            return c
        }
        return fixed
    }

    private func thresholds(_ r: RouteInfo, speed v: Double) -> [Double] {
        // avvisi in base alla velocità (come Google Maps): l'ultimo ~5 secondi prima dell'incrocio
        r.mode == .walk ? [120, 25] : [v > 22 ? 1800 : 900, max(350, v * 18), max(50, v * 5)]
    }

    /// distanza entro cui due manovre si annunciano insieme ("…, poi svolta a sinistra")
    private func thenGap(_ r: RouteInfo) -> Double { r.mode == .walk ? 50 : 150 }

    private static func isArrivalText(_ s: String) -> Bool {
        let l = s.lowercased()
        return ["arriv", "destinazione", "destination"].contains { l.contains($0) }
    }

    /// Prima indicazione vocale, all'avvio o dopo un ricalcolo, come Google Maps:
    /// "Procedi in direzione nord su Via Roma verso Via Verdi, poi svolta a destra in Via Verdi".
    /// Gli avvisi già "detti" vengono segnati, così non si accavallano subito dopo.
    private func announceStart(_ r: RouteInfo, departure: Bool) {
        guard !r.steps.isEmpty else { return }
        var text = departure ? r.steps[0].instruction : ""
        if r.steps.count > 1 {
            let step = r.steps[1]
            let to = max(0, step.startDistance)
            let th = thresholds(r, speed: max(0, location.location?.speed ?? 0))
            let instr = lowerFirst(step.instruction)
            if to <= th[th.count - 1] {
                // la manovra è proprio qui: si dice soltanto quella (o "…, poi …")
                text = departure ? "\(text), poi \(instr)" : step.instruction
                for i in th.indices { announced.insert("1-\(i)") }
            } else if to <= thenGap(r) {
                text = departure ? "\(text), poi \(instr)" : "Tra \(units.spoken(to)), \(instr)"
                for i in 0..<(th.count - 1) { announced.insert("1-\(i)") }
            } else {
                if !departure {
                    text = to <= th[0] ? "Tra \(units.spoken(to)), \(instr)" : "Prosegui per \(units.spoken(to))"
                }
                for i in 0..<(th.count - 1) where to <= th[i] { announced.insert("1-\(i)") }
            }
        }
        VoiceGuide.shared.speak(text, interrupt: false)
    }

    /// Frase d'arrivo come Google Maps: "La destinazione è sulla destra".
    private func arrivalText(_ r: RouteInfo) -> String {
        if let last = r.steps.last, AppState.isArrivalText(last.instruction) {
            let l = last.instruction.lowercased()
            if l.contains("destra") || l.contains("sinistra") { return last.instruction }
        }
        if let p = pinnedPlace, let end = r.coordinates.last, cumulative.count == r.coordinates.count,
           let total = cumulative.last, total > 10, RouteMath.meters(end, p.coordinate) > 6 {
            let before = RouteMath.point(at: max(0, total - 30), on: r.coordinates, cumulative: cumulative).coordinate
            var a = MapController.bearing(from: end, to: p.coordinate) - MapController.bearing(from: before, to: end)
            while a > 180 { a -= 360 }
            while a < -180 { a += 360 }
            if abs(a) > 30 && abs(a) < 150 {
                return "La destinazione è sulla \(a > 0 ? "destra" : "sinistra")"
            }
        }
        return "Sei arrivato a destinazione"
    }

    func endNavigation() {
        clearNavAlternatives()
        location.setNavigating(false)
        UIApplication.shared.isIdleTimerDisabled = false
        departing = false
        VoiceGuide.shared.stop()
        showSteps = false
        clearRoute()
        panel = pinnedPlace == nil ? .none : .pinned
        map.recenter()
    }

    func clearRoute() {
        routes = []
        selectedRoute = 0
        map.clearRoute()
    }

    func dismissPanel() {
        if panel == .navigating { return }
        if panel == .directions {
            clearRoute()
            origin = nil
            stop = nil
            departure = nil
            panel = .pinned
            if let p = pinnedPlace { map.fly(to: p.coordinate) }
            return
        }
        if panel == .pinned && !searchResults.isEmpty {
            pinnedPlace = nil
            map.removePin()
            panel = .results
            map.showResults(searchResults)
            return
        }
        panel = .none
        pinnedPlace = nil
        map.removePin()
        map.setBottomInset(0)
    }

    /// Chiamato ad ogni aggiornamento GPS (anche in background durante la navigazione)
    func locationUpdated(_ loc: CLLocation) {
        if let p = pinnedPlace, loc.distance(from: CLLocation(latitude: p.latitude, longitude: p.longitude)) < 60 {
            if !explored.contains(p.exploreKey) { explored.insert(p.exploreKey) }
        }
        if panel == .navigating { updateNavigation(loc) }
    }

    private func updateNavigation(_ loc: CLLocation) {
        guard let r = route, r.coordinates.count > 1, cumulative.count == r.coordinates.count else { return }
        speedKmh = loc.speed >= 0 ? Int((loc.speed * 3.6).rounded()) : 0

        var proj = RouteMath.project(loc.coordinate, on: r.coordinates, cumulative: cumulative, from: lastProjectionIndex)
        if proj.offset > 40 {
            proj = RouteMath.project(loc.coordinate, on: r.coordinates, cumulative: cumulative, from: 0)
        }
        lastProjectionIndex = proj.index
        let total = cumulative.last ?? r.distance
        let traveled = proj.along
        // tratto percorso nascosto e zoom secondo la velocità
        if proj.offset < 35 {
            let p = RouteMath.point(at: traveled, on: r.coordinates, cumulative: cumulative, hint: proj.index)
            map.trimRoute(from: p.coordinate, index: p.index)
        }
        map.adjustNavigationZoom(speedKmh: speedKmh, walking: r.mode == .walk)
        let remaining = max(0, total - traveled)

        // prossima manovra
        var next = r.steps.count
        for (i, step) in r.steps.enumerated() where i > 0 && step.startDistance > traveled + 3 {
            next = i
            break
        }
        let toManeuver = next < r.steps.count ? r.steps[next].startDistance - traveled : remaining
        let ratio = total > 0 ? remaining / total : 0
        // banner di partenza finché non hai percorso i primi metri, poi la prima manovra
        if departing && (traveled > (r.mode == .walk ? 12 : 25) || next > 1) { departing = false }

        progress = RouteProgress(traveled: traveled, remaining: remaining, offset: proj.offset,
                                 nextStep: departing ? 0 : min(next, max(r.steps.count - 1, 0)),
                                 toManeuver: max(0, toManeuver),
                                 remainingTime: r.travelTime * ratio)

        // tappa raggiunta
        if let s = stop, loc.distance(from: CLLocation(latitude: s.latitude, longitude: s.longitude)) < 40 {
            stop = nil
            VoiceGuide.shared.speak("Hai raggiunto la tappa \(s.name)")
        }

        // arrivo
        if remaining < 25 && !arrived {
            arrived = true
            VoiceGuide.shared.speak(arrivalText(r), interrupt: false)
            if let p = pinnedPlace { explored.insert(p.exploreKey) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self = self, self.panel == .navigating else { return }
                self.endNavigation()
            }
            return
        }

        // guida vocale come Google Maps: "Tra 300 metri, svolta a destra in Via Roma" → "Svolta a destra in Via Roma"
        if next < r.steps.count {
            let step = r.steps[next]
            let instruction = step.instruction
            let th = thresholds(r, speed: max(0, loc.speed))
            let isArrival = next == r.steps.count - 1 && AppState.isArrivalText(instruction)

            // appena fatta una manovra, se la prossima è lontana: "Prosegui su Via Roma per 3 chilometri"
            if next >= 2, !announced.contains("\(next)-c"),
               traveled - r.steps[next - 1].startDistance < 150, toManeuver > th[0] + 300 {
                announced.insert("\(next)-c")
                let road = Departure.street(in: r.steps[next - 1].instruction)
                VoiceGuide.shared.speak(road.map { "Prosegui su \($0) per \(units.spoken(toManeuver))" }
                                        ?? "Prosegui per \(units.spoken(toManeuver))", interrupt: false)
            }

            for idx in th.indices.reversed() where toManeuver <= th[idx] {
                let key = "\(next)-\(idx)"
                if !announced.contains(key) {
                    // registra anche le soglie più lontane per non ripeterle
                    for i2 in 0...idx { announced.insert("\(next)-\(i2)") }
                    let atManeuver = idx == th.count - 1
                    // l'ultimo avviso dell'arrivo lo dà il controllo "arrivo" qui sopra
                    if atManeuver && isArrival { break }
                    var text = atManeuver ? instruction : "Tra \(units.spoken(toManeuver)), \(lowerFirst(instruction))"
                    // manovra subito dopo questa → "…, poi svolta a sinistra" (e non si ripete il suo preavviso)
                    if next + 1 < r.steps.count, r.steps[next + 1].startDistance - step.startDistance < thenGap(r) {
                        text += ", poi \(lowerFirst(r.steps[next + 1].instruction))"
                        for i2 in 0..<(th.count - 1) { announced.insert("\(next + 1)-\(i2)") }
                    }
                    VoiceGuide.shared.speak(text)
                }
                break
            }
        }

        // fuori percorso → ricalcolo automatico (come Google Maps)
        checkOffRoute(loc, route: r, proj: proj, toManeuver: toManeuver, next: next)
    }

    /// Decide se ricalcolare il percorso:
    /// - distanza dalla linea oltre una soglia che si adatta alla precisione del GPS (30–60 m in auto, 22–45 a piedi),
    ///   mantenuta per un paio di secondi (un singolo salto del GPS non basta);
    /// - svolta mancata: appena superato il punto della manovra e già lontano dalla linea → ricalcolo più rapido;
    /// - contromano: si va nella direzione opposta al percorso per qualche secondo → ricalcolo (inversione);
    /// - da fermi si ricalcola solo se si è davvero lontani; mai due ricalcoli troppo ravvicinati.
    private func checkOffRoute(_ loc: CLLocation, route r: RouteInfo,
                               proj: (along: Double, offset: Double, index: Int), toManeuver: Double, next: Int) {
        guard !isRerouting, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 80 else { return }
        let walking = r.mode == .walk
        let acc = loc.horizontalAccuracy
        let base: Double = walking ? 22 : 30
        let limit = min(max(base, acc * 1.3 + 10), walking ? 45 : 60)
        let speed = max(0, loc.speed)
        let now = Date()

        // direzione della strada nel punto in cui si è e confronto con la direzione di marcia
        let here = RouteMath.point(at: proj.along, on: r.coordinates, cumulative: cumulative, hint: proj.index)
        var headingDiff: Double = 0
        if loc.course >= 0 && speed > (walking ? 0.8 : 2.5) {
            var d = abs(loc.course - here.bearing).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            headingDiff = d
        }

        // svolta mancata: subito dopo la manovra si è già fuori strada
        let justPassedManeuver = next > 0 && next < r.steps.count + 1
            && proj.along - (r.steps.indices.contains(next - 1) ? r.steps[next - 1].startDistance : 0) < 80
        var threshold: TimeInterval = speed < 1 ? 6 : 2.5
        if justPassedManeuver && proj.offset > limit * 0.7 && headingDiff > 35 { threshold = 1.2 }
        if speed < 1 && proj.offset < limit * 2 { offRouteSince = nil }       // fermi e vicini: non è uscito

        if proj.offset > (justPassedManeuver && headingDiff > 35 ? limit * 0.7 : limit) {
            if offRouteSince == nil { offRouteSince = now }
        } else {
            offRouteSince = nil
        }

        // contromano sulla strada del percorso
        if proj.offset < limit && headingDiff > 135 {
            if wrongWaySince == nil { wrongWaySince = now }
        } else {
            wrongWaySince = nil
        }

        let cooldownOK = now.timeIntervalSince(lastReroute) > 5
        if cooldownOK, let since = offRouteSince, now.timeIntervalSince(since) >= threshold {
            reroute(from: loc)
        } else if cooldownOK, let since = wrongWaySince, now.timeIntervalSince(since) >= 6 {
            reroute(from: loc)
        }
    }

    private func lowerFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.lowercased() + s.dropFirst()
    }

    /// Ricalcolo come Google Maps:
    /// - parte da un punto qualche secondo più avanti nella direzione di marcia, così il nuovo percorso
    ///   non chiede un'inversione immediata;
    /// - tra le alternative sceglie quella che prosegue nella direzione in cui stai andando,
    ///   a meno che sia molto più lenta;
    /// - il nuovo tracciato parte dalla tua posizione (nessun buco sulla mappa);
    /// - se la rete non risponde riprova da solo dopo qualche secondo.
    private func reroute(from loc: CLLocation, silent: Bool = false) {
        guard let dest = pinnedPlace, let mode = route?.mode else { return }
        lastReroute = Date()
        offRouteCount = 0
        offRouteSince = nil
        wrongWaySince = nil
        isRerouting = true

        let speed = max(0, loc.speed)
        var origin = loc.coordinate
        if loc.course >= 0 && speed > 2 {
            // punto 3 secondi più avanti (max 60 m) nella direzione di marcia
            let ahead = min(60, speed * 3)
            let br = loc.course * .pi / 180
            origin = CLLocationCoordinate2D(latitude: origin.latitude + ahead * cos(br) / 111_320,
                                            longitude: origin.longitude + ahead * sin(br) / (111_320 * cos(origin.latitude * .pi / 180)))
        }
        let course = loc.course >= 0 && speed > 2 ? loc.course : nil
        let wasStart = departing && progress.traveled < 25

        let done: ([RouteInfo]) -> Void = { [weak self] infos in
            guard let self = self, self.panel == .navigating else { return }
            self.isRerouting = false
            guard !infos.isEmpty else {
                // nessuna risposta: nuovo tentativo tra 4 secondi se si è ancora fuori percorso
                self.lastReroute = Date().addingTimeInterval(-1)
                return
            }
            let chosen = AppState.bestReroute(infos, course: course)
            // il tracciato parte dalla posizione attuale (le manovre restano nel punto giusto)
            let fixed = self.location.location.map { self.anchored(chosen, at: $0.coordinate) } ?? chosen
            self.routes = [fixed]
            self.selectedRoute = 0
            self.cumulative = RouteMath.cumulative(fixed.coordinates)
            self.lastProjectionIndex = 0
            self.announced = []
            self.departing = wasStart
            self.map.showRoute(fixed.coordinates, alternatives: [], overview: false)
            // come Google Maps: subito l'indicazione dal punto in cui sei
            if !silent { self.announceStart(fixed, departure: wasStart) }
            if let l = self.location.location { self.updateNavigation(l) }
        }
        if let s = stop {
            DirectionsService.routesVia(from: origin, stop: s, to: dest.coordinate, destinationItem: destinationItem,
                                        mode: mode, options: routeOptions, departure: nil, completion: done)
        } else {
            DirectionsService.routes(from: origin, to: dest.coordinate, destinationItem: destinationItem,
                                     mode: mode, options: routeOptions, alternatives: true, completion: done)
        }
    }

    /// Tra i percorsi proposti preferisce quello che parte nella direzione di marcia (niente inversioni inutili),
    /// se non è più lento di oltre il 20% del più veloce.
    private static func bestReroute(_ infos: [RouteInfo], course: Double?) -> RouteInfo {
        guard let course = course, infos.count > 1, let fastest = infos.min(by: { $0.travelTime < $1.travelTime }) else {
            return infos[0]
        }
        func startBearingDiff(_ r: RouteInfo) -> Double {
            let cum = RouteMath.cumulative(r.coordinates)
            guard let total = cum.last, total > 1 else { return 180 }
            let p = RouteMath.point(at: min(40, total), on: r.coordinates, cumulative: cum)
            guard let a = r.coordinates.first else { return 180 }
            var d = abs(MapController.bearing(from: a, to: p.coordinate) - course).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            return d
        }
        let ok = infos.filter { $0.travelTime <= fastest.travelTime * 1.2 }
        return ok.min(by: { startBearingDiff($0) < startBearingDiff($1) }) ?? fastest
    }

    // MARK: - Cerca lungo il percorso (benzinai, ristoranti… senza allontanarsi)

    func searchAlongRoute(_ query: String) {
        guard let r = route, r.coordinates.count > 1, cumulative.count == r.coordinates.count else { return }
        alongRouteQuery = query
        isSearchingAlongRoute = true
        alongRouteResults = []
        let startIdx = max(0, lastProjectionIndex)
        let traveled = progress.traveled
        var ahead: [CLLocationCoordinate2D] = []
        for i in startIdx..<r.coordinates.count where cumulative[i] - traveled < 30_000 {
            ahead.append(r.coordinates[i])
        }
        guard let first = ahead.first else { isSearchingAlongRoute = false; return }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for c in ahead {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.resultTypes = .pointOfInterest
        req.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.02, (maxLat - minLat) * 1.2), longitudeDelta: max(0.02, (maxLon - minLon) * 1.2)))
        let coords = r.coordinates, cum = cumulative
        MKLocalSearch(request: req).start { [weak self] response, _ in
            let items = (response?.mapItems ?? []).compactMap { item -> (MKMapItem, Double)? in
                let p = RouteMath.project(item.placemark.coordinate, on: coords, cumulative: cum, from: 0)
                guard p.offset < 600, p.along > traveled else { return nil }
                return (item, p.along)
            }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }
            DispatchQueue.main.async {
                self?.isSearchingAlongRoute = false
                self?.alongRouteResults = Array(items.prefix(20))
            }
        }
    }

    /// Aggiunge una tappa durante la navigazione e ricalcola
    func addStop(_ item: MKMapItem) {
        stop = Place(mapItem: item)
        showAlongRoute = false
        if let loc = location.location { reroute(from: loc) }
    }

    /// Testo da condividere con l'orario di arrivo
    var shareETAText: String {
        let dest = pinnedPlace.map { $0.name.isEmpty ? $0.address : $0.name } ?? "destinazione"
        let eta = Formatters.time.string(from: Date().addingTimeInterval(progress.remainingTime))
        return "Sto arrivando a \(dest): arrivo previsto alle \(eta) (\(RouteInfo.duration(progress.remainingTime)))."
    }

    func showRouteOverview() {
        guard let r = route else { return }
        clearNavAlternatives()
        map.showRoute(r.coordinates, alternatives: [], overview: true)
    }

    /// "Riposiziona": torna alla vista di guida che segue la posizione
    func repositionNavigation() {
        clearNavAlternatives()
        if let r = route { map.showRoute(r.coordinates, alternatives: [], overview: false) }
        map.startNavigation()
    }

    /// Pulsante percorsi durante la navigazione (come Google Maps): calcola i percorsi da qui alla destinazione,
    /// li mostra dall'alto con il tempo in più/in meno rispetto a quello attuale; toccandone uno si passa a quello.
    func showNavAlternatives() {
        guard panel == .navigating, let loc = location.location, let dest = pinnedPlace, let current = route else { return }
        isLoadingAlternatives = true
        let remaining = progress.remainingTime
        DirectionsService.routes(from: loc.coordinate, to: dest.coordinate, destinationItem: destinationItem,
                                 mode: current.mode, options: routeOptions, alternatives: true, departure: nil) { [weak self] infos in
            guard let self = self, self.panel == .navigating else { return }
            self.isLoadingAlternatives = false
            // si scartano i percorsi uguali a quello che stai già seguendo
            let currentLeft = max(0, (self.cumulative.last ?? current.distance) - self.progress.traveled)
            let alts = infos.filter { abs($0.distance - currentLeft) > max(150, currentLeft * 0.03) && !$0.etaOnly }
            guard !alts.isEmpty else {
                self.routeError = "Nessun percorso alternativo disponibile al momento."
                return
            }
            self.navAlternatives = Array(alts.prefix(3))
            self.map.showRoute(current.coordinates, alternatives: self.navAlternatives.map { $0.coordinates }, overview: true)
            let labels: [(coordinate: CLLocationCoordinate2D, text: String, index: Int)] = self.navAlternatives.enumerated().map { i, alt in
                let cum = RouteMath.cumulative(alt.coordinates)
                let mid = RouteMath.point(at: (cum.last ?? 0) * 0.5, on: alt.coordinates, cumulative: cum)
                let diff = (alt.travelTime - remaining) / 60
                let text: String
                if abs(diff) < 1 { text = "Durata simile" }
                else if diff > 0 { text = "\(Int(diff.rounded())) min in più" }
                else { text = "\(Int((-diff).rounded())) min in meno" }
                return (mid.coordinate, text, i)
            }
            self.map.showAltLabels(labels)
        }
    }

    /// Passa al percorso alternativo scelto e riprende la guida
    func switchToNavAlternative(_ index: Int) {
        guard navAlternatives.indices.contains(index) else { return }
        let chosen = navAlternatives[index]
        clearNavAlternatives()
        routes = [chosen]
        selectedRoute = 0
        VoiceGuide.shared.speak("Percorso aggiornato")
        startNavigation(announce: false)
    }

    func clearNavAlternatives() {
        navAlternatives = []
        isLoadingAlternatives = false
        map.clearAltLabels()
    }

    /// Pulsante posizione come Google Maps:
    /// mappa spostata → torna sulla tua posizione e la segue;
    /// già centrata → modalità bussola (la mappa ruota con il telefono);
    /// in modalità bussola → torna col nord in alto.
    /// Senza permesso di localizzazione apre le Impostazioni di iOS.
    func cycleTracking() {
        switch location.authorization {
        case .denied, .restricted:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            return
        case .notDetermined:
            location.start()
            return
        default: break
        }
        if panel == .navigating {
            if tracking == .none { map.startNavigation() } else { map.setTracking(tracking == .heading ? .follow : .heading) }
            return
        }
        switch tracking {
        case .none: map.recenter()
        case .follow: map.setTracking(.heading)
        case .heading: map.resetNorthFollowing()
        }
    }

    /// Imposta un luogo come posizione dell'auto parcheggiata
    func setParking(_ place: Place) {
        parking = Place(name: "Auto parcheggiata", address: place.address.isEmpty ? place.name : place.address,
                        coordinate: place.coordinate)
        Notifier.scheduleParkingReminder()
    }

    /// Tocco sulla freccia della posizione → scheda "La tua posizione"
    func openMyLocation() {
        guard panel == .none || panel == .saved || panel == .myLocation else { return }
        panel = .myLocation
    }

    func deleteAllData() {
        saved = []
        history = []
        explored = []
        home = nil
        work = nil
        parking = nil
        themeIndex = Themes.defaultIndex
        units = .metric
        routeOptions = RouteOptions()
    }
}
