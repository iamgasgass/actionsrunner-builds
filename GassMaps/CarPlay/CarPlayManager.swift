import UIKit
import CarPlay
import MapKit
import Combine

/// CarPlay come app di navigazione:
/// - mappa con il tema scelto, pulsanti centra / zoom / sposta;
/// - "Destinazioni" (Casa, Lavoro, Parcheggio, Nei dintorni, Salvati, Recenti) e ricerca;
/// - anteprima del viaggio con i percorsi alternativi, "Avvia";
/// - guida svolta per svolta con le schede di CarPlay (stesse istruzioni di Apple Maps del telefono),
///   distanze aggiornate, ricalcolo, arrivo.
/// La guida è una sola: avviata o terminata dal telefono o dall'auto, l'altro schermo la segue.
final class CarPlayManager: NSObject {
    static let shared = CarPlayManager()

    private let state = AppState.shared
    private var interface: CPInterfaceController?
    private var mapVC: CarPlayMapViewController?
    private var mapTemplate: CPMapTemplate?
    private var session: CPNavigationSession?
    private var trip: CPTrip?
    /// viaggio avviato dall'auto, in attesa che la navigazione parta sul telefono
    private var pendingTrip: CPTrip?
    private var cancellables = Set<AnyCancellable>()

    // anteprima
    private var previewRoutes: [RouteInfo] = []
    private var previewPlace: Place?
    private var previewItem: MKMapItem?

    // guida
    private var shownStep = -1
    private var shownRouteID: UUID?
    private var panning = false

    // ricerca
    private let completer = MKLocalSearchCompleter()
    private var searchHandler: (([CPListItem]) -> Void)?
    private var lastQuery = ""

    private override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    // MARK: - Collegamento

    func connect(_ interfaceController: CPInterfaceController, window: CPWindow) {
        interface = interfaceController
        state.location.start()

        let vc = CarPlayMapViewController(state: state)
        window.rootViewController = vc
        mapVC = vc

        let t = CPMapTemplate()
        t.mapDelegate = self
        t.automaticallyHidesNavigationBar = false
        t.guidanceBackgroundColor = state.theme.accent
        t.tripEstimateStyle = .dark
        mapTemplate = t
        refreshButtons()
        interfaceController.setRootTemplate(t, animated: false, completion: nil)

        observe()
        if state.panel == .navigating { beginSession() }
    }

    func disconnect() {
        cancellables.removeAll()
        session = nil
        trip = nil
        pendingTrip = nil
        previewRoutes = []
        shownStep = -1
        shownRouteID = nil
        searchHandler = nil
        mapTemplate = nil
        mapVC = nil
        interface = nil
    }

    private func observe() {
        cancellables.removeAll()
        // receive(on:) → si legge lo stato dopo che è stato aggiornato (@Published avvisa prima)
        state.$panel.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.panelChanged() }.store(in: &cancellables)
        state.$routes.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.routesChanged() }.store(in: &cancellables)
        state.$progress.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.progressChanged() }.store(in: &cancellables)
        state.$isRerouting.receive(on: DispatchQueue.main)
            .sink { [weak self] rerouting in
                guard rerouting, let s = self?.session else { return }
                s.pauseTrip(for: .rerouting, description: "Ricalcolo del percorso…")
            }.store(in: &cancellables)
        state.$themeIndex.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.mapVC?.applyTheme()
                self.mapTemplate?.guidanceBackgroundColor = self.state.theme.accent
            }.store(in: &cancellables)
        state.$voiceMuted.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshButtons() }.store(in: &cancellables)
    }

    // MARK: - Pulsanti

    private func refreshButtons() {
        guard let t = mapTemplate else { return }
        if session != nil {
            let mute = CPBarButton(title: state.voiceMuted ? "Voce sì" : "Muto") { [weak self] _ in
                self?.state.voiceMuted.toggle()
            }
            let end = CPBarButton(title: "Termina") { [weak self] _ in
                self?.state.endNavigation()
            }
            t.leadingNavigationBarButtons = [mute]
            t.trailingNavigationBarButtons = [end]
        } else if !previewRoutes.isEmpty {
            t.leadingNavigationBarButtons = []
            t.trailingNavigationBarButtons = [CPBarButton(title: "Annulla") { [weak self] _ in self?.cancelPreview() }]
        } else {
            let dest = CPBarButton(title: "Destinazioni") { [weak self] _ in self?.showDestinations() }
            let search = CPBarButton(image: symbol("magnifyingglass")) { [weak self] _ in self?.showSearch() }
            t.leadingNavigationBarButtons = [dest]
            t.trailingNavigationBarButtons = [search]
        }

        let center = CPMapButton { [weak self] _ in self?.mapVC?.recenter() }
        center.image = symbol("location.fill")
        let zoomIn = CPMapButton { [weak self] _ in self?.mapVC?.zoom(by: 1) }
        zoomIn.image = symbol("plus")
        let zoomOut = CPMapButton { [weak self] _ in self?.mapVC?.zoom(by: -1) }
        zoomOut.image = symbol("minus")
        let pan = CPMapButton { [weak self] _ in self?.togglePanning() }
        pan.image = symbol(panning ? "xmark" : "arrow.up.and.down.and.arrow.left.and.right")
        t.mapButtons = [center, zoomIn, zoomOut, pan]
    }

    private func symbol(_ name: String, size: CGFloat = 22) -> UIImage {
        let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        return UIImage(systemName: name, withConfiguration: cfg) ?? UIImage()
    }

    private func togglePanning() {
        guard let t = mapTemplate else { return }
        if panning { t.dismissPanningInterface(animated: true) } else { t.showPanningInterface(animated: true) }
    }

    private func alert(_ text: String) {
        let ok = CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            self?.interface?.dismissTemplate(animated: true, completion: nil)
        }
        interface?.presentTemplate(CPAlertTemplate(titleVariants: [text], actions: [ok]), animated: true, completion: nil)
    }

    // MARK: - Destinazioni

    private var listLimit: Int { min(12, CPListTemplate.maximumItemCount) }

    private func showDestinations() {
        var top: [CPListItem] = []
        if let h = state.home { top.append(placeItem(h, title: "Casa", icon: "house.fill")) }
        if let w = state.work { top.append(placeItem(w, title: "Lavoro", icon: "briefcase.fill")) }
        if let p = state.parking { top.append(placeItem(p, title: "Auto parcheggiata", icon: "parkingsign.circle.fill")) }
        let nearby = CPListItem(text: "Nei dintorni", detailText: "Benzina, ricarica, parcheggi, ristoranti…",
                                image: symbol("mappin.and.ellipse"))
        nearby.handler = { [weak self] _, done in
            self?.showCategories()
            done()
        }
        top.append(nearby)

        var sections = [CPListSection(items: top)]
        let saved = state.saved.prefix(listLimit).map { placeItem($0, title: nil, icon: "star.fill") }
        if !saved.isEmpty { sections.append(CPListSection(items: saved, header: "Salvati", sectionIndexTitle: nil)) }
        let recent = state.history.prefix(listLimit).map { placeItem($0, title: nil, icon: "clock.arrow.circlepath") }
        if !recent.isEmpty { sections.append(CPListSection(items: recent, header: "Recenti", sectionIndexTitle: nil)) }

        interface?.pushTemplate(CPListTemplate(title: "Destinazioni", sections: sections), animated: true, completion: nil)
    }

    private func placeItem(_ place: Place, title: String?, icon: String) -> CPListItem {
        let name = place.name.isEmpty ? "Posizione" : place.name
        var detail = title == nil ? place.address : (place.name.isEmpty ? place.address : place.name)
        if let here = state.location.location {
            let d = here.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
            detail = detail.isEmpty ? state.units.short(d) : "\(state.units.short(d)) · \(detail)"
        }
        let item = CPListItem(text: title ?? name, detailText: detail, image: symbol(icon))
        item.handler = { [weak self] _, done in
            self?.preview(place, item: nil)
            done()
        }
        return item
    }

    private func showCategories() {
        let cats: [(String, String, String)] = [
            ("Benzina", "Stazione di servizio", "fuelpump.fill"),
            ("Ricarica", "Colonnina di ricarica", "ev.charger.fill"),
            ("Parcheggi", "Parcheggio", "parkingsign.circle.fill"),
            ("Ristoranti", "Ristorante", "fork.knife"),
            ("Caffè", "Bar caffè", "cup.and.saucer.fill"),
            ("Supermercati", "Supermercato", "cart.fill"),
            ("Farmacie", "Farmacia", "cross.case.fill"),
            ("Hotel", "Hotel", "bed.double.fill")
        ]
        let buttons = cats.map { title, query, icon in
            CPGridButton(titleVariants: [title], image: symbol(icon, size: 30)) { [weak self] _ in
                self?.runSearch(query, title: title)
            }
        }
        interface?.pushTemplate(CPGridTemplate(title: "Nei dintorni", gridButtons: buttons), animated: true, completion: nil)
    }

    // MARK: - Ricerca

    private func showSearch() {
        if let loc = state.location.location {
            completer.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        }
        let s = CPSearchTemplate()
        s.delegate = self
        interface?.pushTemplate(s, animated: true, completion: nil)
    }

    private func runSearch(_ query: String, title: String) {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        if let loc = state.location.location {
            req.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 15_000, longitudinalMeters: 15_000)
        }
        MKLocalSearch(request: req).start { [weak self] response, _ in
            DispatchQueue.main.async { self?.showResults(response?.mapItems ?? [], title: title) }
        }
    }

    private func showResults(_ items: [MKMapItem], title: String) {
        guard !items.isEmpty else { alert("Nessun risultato"); return }
        let here = state.location.location
        let sorted: [MKMapItem]
        if let h = here {
            sorted = items.sorted { ($0.placemark.location?.distance(from: h) ?? .infinity)
                                  < ($1.placemark.location?.distance(from: h) ?? .infinity) }
        } else {
            sorted = items
        }
        let list: [CPListItem] = sorted.prefix(listLimit).map { mi in
            var detail = Place.formatShort(mi.placemark)
            if let h = here, let l = mi.placemark.location {
                detail = "\(state.units.short(l.distance(from: h))) · \(detail)"
            }
            let it = CPListItem(text: mi.name ?? "Luogo", detailText: detail)
            it.handler = { [weak self] _, done in
                self?.preview(Place(mapItem: mi), item: mi)
                done()
            }
            return it
        }
        interface?.pushTemplate(CPListTemplate(title: title, sections: [CPListSection(items: list)]),
                                animated: true, completion: nil)
    }

    // MARK: - Anteprima del viaggio

    func preview(_ place: Place, item: MKMapItem?) {
        guard mapTemplate != nil else { return }
        if session != nil { alert("Termina prima la navigazione in corso"); return }
        DirectionsService.routes(from: state.location.location?.coordinate, to: place.coordinate,
                                 destinationItem: item, mode: .car, options: state.routeOptions,
                                 alternatives: true) { [weak self] infos in
            guard let self = self, let t = self.mapTemplate else { return }
            let routes = Array(infos.filter { !$0.etaOnly && $0.coordinates.count > 1 }.prefix(3))
            guard !routes.isEmpty else { self.alert("Impossibile calcolare il percorso"); return }
            self.previewRoutes = routes
            self.previewPlace = place
            self.previewItem = item
            let trip = self.makeTrip(place: place, item: item, routes: routes)
            self.interface?.popToRootTemplate(animated: true, completion: nil)
            let text = CPTripPreviewTextConfiguration(startButtonTitle: "Avvia",
                                                      additionalRoutesButtonTitle: "Altri percorsi",
                                                      overviewButtonTitle: "Panoramica")
            t.showTripPreviews([trip], textConfiguration: text)
            self.mapVC?.showPreview(routes[0].coordinates)
            self.refreshButtons()
        }
    }

    private func cancelPreview() {
        mapTemplate?.hideTripPreviews()
        previewRoutes = []
        previewPlace = nil
        previewItem = nil
        mapVC?.setRoute([])
        mapVC?.recenter()
        refreshButtons()
    }

    private func makeTrip(place: Place?, item: MKMapItem?, routes: [RouteInfo]) -> CPTrip {
        let coord = place?.coordinate ?? routes.first?.coordinates.last ?? CLLocationCoordinate2D()
        let dest = item ?? MKMapItem(placemark: MKPlacemark(coordinate: coord))
        if dest.name == nil || dest.name?.isEmpty == true {
            dest.name = (place?.name.isEmpty == false ? place?.name : nil) ?? "Destinazione"
        }
        let choices = routes.enumerated().map { i, r -> CPRouteChoice in
            let dist = state.units.short(r.distance)
            let via = r.name.isEmpty ? "" : "via \(r.name)"
            var info = via.isEmpty ? dist : "\(via) · \(dist)"
            if r.hasTolls { info += " · pedaggi" }
            let choice = CPRouteChoice(summaryVariants: [i == 0 ? "Più veloce · \(r.durationText)" : r.durationText, r.durationText],
                                       additionalInformationVariants: [info, dist],
                                       selectionSummaryVariants: [via.isEmpty ? r.durationText : via])
            choice.userInfo = i
            return choice
        }
        return CPTrip(origin: MKMapItem.forCurrentLocation(), destination: dest, routeChoices: choices)
    }

    // MARK: - Guida

    private func panelChanged() {
        if state.panel == .navigating {
            if session == nil { beginSession() }
        } else if let s = session {
            if state.arrived { s.finishTrip() } else { s.cancelTrip() }
            session = nil
            trip = nil
            shownStep = -1
            shownRouteID = nil
            mapVC?.endNavigation()
            refreshButtons()
        }
    }

    private func beginSession() {
        guard let t = mapTemplate, let r = state.route else { return }
        t.hideTripPreviews()
        let theTrip = pendingTrip ?? makeTrip(place: state.pinnedPlace, item: state.destinationItem, routes: [r])
        pendingTrip = nil
        previewRoutes = []
        trip = theTrip
        session = t.startNavigationSession(for: theTrip)
        shownStep = -1
        shownRouteID = nil
        interface?.popToRootTemplate(animated: false, completion: nil)
        mapVC?.beginNavigation()
        refreshButtons()
        routesChanged()
        progressChanged()
    }

    private func routesChanged() {
        guard session != nil else {
            if previewRoutes.isEmpty { mapVC?.setRoute([]) }
            return
        }
        guard let r = state.route else { return }
        mapVC?.setRoute(r.coordinates)
        if r.id != shownRouteID {
            // nuovo percorso (es. dopo un ricalcolo): schede rifatte da capo, il viaggio riprende
            shownRouteID = r.id
            shownStep = -1
            progressChanged()
        }
    }

    private func progressChanged() {
        guard let s = session, let r = state.route, !r.steps.isEmpty else { return }
        let p = state.progress
        let idx = min(max(p.nextStep, 0), r.steps.count - 1)
        if idx != shownStep || shownRouteID != r.id {
            shownStep = idx
            shownRouteID = r.id
            var list: [CPManeuver] = []
            for i in idx..<min(idx + 2, r.steps.count) {
                let dist = i == idx ? p.toManeuver : max(0, r.steps[i].startDistance - p.traveled)
                list.append(maneuver(r.steps[i], distance: dist, route: r))
            }
            s.upcomingManeuvers = list
        }
        if let current = s.upcomingManeuvers.first {
            s.updateEstimates(estimates(distance: p.toManeuver, route: r), for: current)
        }
        if let t = trip {
            mapTemplate?.updateEstimates(CPTravelEstimates(distanceRemaining: measure(p.remaining),
                                                           timeRemaining: p.remainingTime), for: t)
        }
    }

    /// Scheda della manovra: testo di Apple Maps (intero, poi solo la via, poi solo la manovra se lo spazio
    /// è poco) e la stessa freccia del telefono
    private func maneuver(_ step: RouteStep, distance: Double, route r: RouteInfo) -> CPManeuver {
        let m = CPManeuver()
        var variants = [step.instruction]
        if !step.isDeparture, let road = Departure.street(in: step.instruction), road != step.instruction {
            variants.append(road)
        }
        let short = Departure.maneuver(of: step.instruction).trimmingCharacters(in: .whitespacesAndNewlines)
        if !short.isEmpty, !variants.contains(short) { variants.append(short) }
        m.instructionVariants = variants
        let cfg = UIImage.SymbolConfiguration(pointSize: 44, weight: .bold)
        m.symbolImage = UIImage(systemName: ManeuverIcon.symbol(for: step), withConfiguration: cfg)?
            .withRenderingMode(.alwaysTemplate)
        m.initialTravelEstimates = estimates(distance: distance, route: r)
        return m
    }

    private func estimates(distance: Double, route r: RouteInfo) -> CPTravelEstimates {
        let speed = r.travelTime > 0 ? max(r.distance / r.travelTime, 1) : 10
        return CPTravelEstimates(distanceRemaining: measure(distance), timeRemaining: distance / speed)
    }

    /// Distanze arrotondate come sul telefono ("350 m", "1,2 km")
    private func measure(_ meters: Double) -> Measurement<UnitLength> {
        let m = max(0, meters)
        if state.units == .imperial {
            let feet = m * 3.28084
            if feet < 1000 { return Measurement(value: (feet / 50).rounded() * 50, unit: .feet) }
            return Measurement(value: (m / 1609.344 * 10).rounded() / 10, unit: .miles)
        }
        if m < 1000 {
            let r = m < 100 ? (m / 10).rounded() * 10 : (m / 50).rounded() * 50
            return Measurement(value: r, unit: .meters)
        }
        return Measurement(value: (m / 100).rounded() / 10, unit: .kilometers)
    }
}

// MARK: - CPMapTemplateDelegate

extension CarPlayManager: CPMapTemplateDelegate {
    func mapTemplate(_ mapTemplate: CPMapTemplate, selectedPreviewFor trip: CPTrip, using routeChoice: CPRouteChoice) {
        let i = routeChoice.userInfo as? Int ?? 0
        guard previewRoutes.indices.contains(i) else { return }
        let r = previewRoutes[i]
        mapVC?.showPreview(r.coordinates)
        mapTemplate.updateEstimates(CPTravelEstimates(distanceRemaining: measure(r.distance), timeRemaining: r.travelTime),
                                    for: trip)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        let i = routeChoice.userInfo as? Int ?? 0
        guard let place = previewPlace, previewRoutes.indices.contains(i) else { return }
        mapTemplate.hideTripPreviews()
        let routes = previewRoutes
        let item = previewItem
        pendingTrip = trip
        previewRoutes = []
        previewPlace = nil
        previewItem = nil
        // la guida parte sul telefono (stessa logica, stessa voce): la sessione CarPlay la segue
        state.pin(place, fly: false, item: item)
        state.travelMode = .car
        state.routes = routes
        state.selectedRoute = i
        state.addToHistory(place)
        state.startNavigation()
    }

    func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        // il sistema ha chiuso la guida (es. è partita un'altra app di navigazione)
        session = nil
        trip = nil
        shownStep = -1
        shownRouteID = nil
        mapVC?.endNavigation()
        if state.panel == .navigating { state.endNavigation() }
        refreshButtons()
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, panWith direction: CPMapTemplate.PanDirection) {
        var dx: CGFloat = 0, dy: CGFloat = 0
        if direction.contains(.left) { dx = -1 }
        if direction.contains(.right) { dx = 1 }
        if direction.contains(.up) { dy = -1 }
        if direction.contains(.down) { dy = 1 }
        mapVC?.pan(dx: dx, dy: dy)
    }

    func mapTemplateDidShowPanningInterface(_ mapTemplate: CPMapTemplate) {
        panning = true
        refreshButtons()
    }

    func mapTemplateDidDismissPanningInterface(_ mapTemplate: CPMapTemplate) {
        panning = false
        refreshButtons()
    }
}

// MARK: - Ricerca (CPSearchTemplate + suggerimenti di Apple Maps)

extension CarPlayManager: CPSearchTemplateDelegate {
    func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        lastQuery = q
        searchHandler?([])
        guard !q.isEmpty else {
            searchHandler = nil
            completionHandler([])
            return
        }
        searchHandler = completionHandler
        completer.queryFragment = q
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        guard let completion = item.userInfo as? MKLocalSearchCompletion else { completionHandler(); return }
        MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start { [weak self] response, _ in
            DispatchQueue.main.async {
                if let mi = response?.mapItems.first {
                    let place = Place(mapItem: mi)
                    self?.state.addToHistory(place)
                    self?.preview(place, item: mi)
                } else {
                    self?.alert("Luogo non trovato")
                }
                completionHandler()
            }
        }
    }

    func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
        guard !lastQuery.isEmpty else { return }
        runSearch(lastQuery, title: lastQuery)
    }
}

extension CarPlayManager: MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let items: [CPListItem] = completer.results.prefix(listLimit).map { c in
            let it = CPListItem(text: c.title, detailText: c.subtitle)
            it.userInfo = c
            return it
        }
        searchHandler?(items)
        searchHandler = nil
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        searchHandler?([])
        searchHandler = nil
    }
}
