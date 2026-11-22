import UIKit
import CarPlay
import MapKit
import Combine

/// CarPlay come app di navigazione completa:
/// - schermo principale: mappa col tema scelto, centra / zoom / sposta (pulsanti, frecce e gesti touch),
///   "Destinazioni" (Casa, Lavoro, Parcheggio, Nei dintorni, Salvati, Recenti) e ricerca;
/// - anteprima del viaggio con i percorsi alternativi (anche quella scelta sul telefono), "Avvia";
/// - guida svolta per svolta nelle schede di CarPlay con le istruzioni di Apple Maps del telefono,
///   distanze e orario aggiornati, ricalcolo, panoramica, arrivo;
/// - notifiche della prossima manovra quando sullo schermo dell'auto c'è un'altra app;
/// - metadati di navigazione (iOS 17.4+) per quadro strumenti e head-up display;
/// - widget nella Dashboard di CarPlay (mappa + scorciatoie Casa/Lavoro) e mappa nel quadro strumenti.
/// La guida è una sola: avviata o terminata dal telefono o dall'auto, gli altri schermi la seguono.
@MainActor
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
    /// destinazione scelta dalla Dashboard prima che lo schermo principale fosse collegato
    private var pendingPlace: Place?
    private var cancellables = Set<AnyCancellable>()
    private var contentStyle: UIUserInterfaceStyle = .dark

    // mappe secondarie (Dashboard, quadro strumenti)
    private var dashboardVC: CarPlayMapViewController?
    private var dashboardController: CPDashboardController?
    private var clusterVC: CarPlayMapViewController?
    private var clusterController: CPInstrumentClusterController?

    // anteprima
    private var previewRoutes: [RouteInfo] = []
    private var previewPlace: Place?
    private var previewItem: MKMapItem?
    /// anteprima mostrata perché sul telefono c'è il pannello "Indicazioni"
    private var previewFromPhone = false
    private var previewTrip: CPTrip?

    // guida
    private var routeManeuvers: [CPManeuver] = []
    private var maneuversRouteID: UUID?
    private var shownStep = -1
    private var shownStepRouteID: UUID?
    private var routeCumulative: [Double] = []
    private var arrivalShown = false
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

    private var anyScreenConnected: Bool { interface != nil || dashboardVC != nil || clusterVC != nil }

    // MARK: - Schermo principale

    func connect(_ interfaceController: CPInterfaceController, window: CPWindow, contentStyle: UIUserInterfaceStyle) {
        interface = interfaceController
        self.contentStyle = contentStyle
        state.location.setCarPlay(true)

        let vc = CarPlayMapViewController(state: state, role: .main)
        window.rootViewController = vc
        mapVC = vc

        // le mappe dei temi sono scure: interfaccia di CarPlay scura per coerenza
        interfaceController.prefersDarkUserInterfaceStyle = true

        let t = CPMapTemplate()
        t.mapDelegate = self
        t.automaticallyHidesNavigationBar = false
        t.hidesButtonsWithNavigationBar = false
        t.guidanceBackgroundColor = state.theme.accent
        t.tripEstimateStyle = contentStyle == .light ? .light : .dark
        mapTemplate = t
        refreshButtons()
        interfaceController.setRootTemplate(t, animated: false, completion: nil)

        observe()
        if state.panel == .navigating {
            beginSession()
        } else {
            syncPhonePreview()
        }
        checkLocationPermission()
        if let p = pendingPlace {
            pendingPlace = nil
            preview(p, item: nil)
        }
    }

    func disconnect() {
        session = nil
        trip = nil
        pendingTrip = nil
        previewRoutes = []
        previewTrip = nil
        previewFromPhone = false
        routeManeuvers = []
        maneuversRouteID = nil
        shownStep = -1
        shownStepRouteID = nil
        searchHandler = nil
        mapTemplate = nil
        mapVC = nil
        interface = nil
        afterScreenChange()
    }

    func contentStyleChanged(_ style: UIUserInterfaceStyle) {
        contentStyle = style
        mapTemplate?.tripEstimateStyle = style == .light ? .light : .dark
    }

    /// La guida è iniziata o la manovra è stata toccata in una notifica: si torna alla mappa
    func showGuidance() {
        interface?.popToRootTemplate(animated: true, completion: nil)
        mapVC?.recenter()
    }

    private func checkLocationPermission() {
        switch state.location.authorization {
        case .denied, .restricted:
            alert("Consenti a GassMaps di usare la posizione: Impostazioni › Privacy › Localizzazione sull'iPhone.")
        case .notDetermined:
            alert("Apri GassMaps sull'iPhone una volta per consentire l'uso della posizione.")
        default:
            break
        }
    }

    // MARK: - Dashboard e quadro strumenti

    func connectDashboard(_ controller: CPDashboardController, window: UIWindow) {
        dashboardController = controller
        state.location.setCarPlay(true)
        let vc = CarPlayMapViewController(state: state, role: .dashboard)
        window.rootViewController = vc
        dashboardVC = vc
        observe()
        refreshDashboardButtons()
        syncSecondaryMaps()
    }

    func disconnectDashboard() {
        dashboardVC = nil
        dashboardController = nil
        afterScreenChange()
    }

    func connectCluster(_ controller: CPInstrumentClusterController) {
        clusterController = controller
        controller.inactiveDescriptionVariants = ["GassMaps · imposta una destinazione", "GassMaps"]
        state.location.setCarPlay(true)
        observe()
    }

    func clusterWindowConnected(_ window: UIWindow) {
        let vc = CarPlayMapViewController(state: state, role: .cluster)
        window.rootViewController = vc
        clusterVC = vc
        syncSecondaryMaps()
    }

    func clusterWindowDisconnected() {
        clusterVC = nil
        afterScreenChange()
    }

    func disconnectCluster() {
        clusterVC = nil
        clusterController = nil
        afterScreenChange()
    }

    func zoomCluster(by delta: Double) { clusterVC?.zoom(by: delta) }

    private func afterScreenChange() {
        if !anyScreenConnected {
            cancellables.removeAll()
            state.location.setCarPlay(false)
        }
    }

    private func refreshDashboardButtons() {
        guard let dc = dashboardController else { return }
        var buttons: [CPDashboardButton] = []
        func add(_ place: Place?, title: String, icon: String) {
            guard let p = place else { return }
            var subtitle: [String] = []
            if let here = state.location.location {
                let d = here.distance(from: CLLocation(latitude: p.latitude, longitude: p.longitude))
                subtitle = [state.units.short(d)]
            }
            buttons.append(CPDashboardButton(titleVariants: [title], subtitleVariants: subtitle,
                                             image: symbol(icon, size: 24)) { [weak self] _ in
                self?.startFromShortcut(p)
            })
        }
        add(state.home, title: "Casa", icon: "house.fill")
        add(state.work, title: "Lavoro", icon: "briefcase.fill")
        if buttons.count < 2 { add(state.parking, title: "Auto parcheggiata", icon: "parkingsign.circle.fill") }
        if buttons.count < 2, let last = state.history.first {
            add(last, title: last.name.isEmpty ? "Recente" : last.name, icon: "clock.arrow.circlepath")
        }
        dc.shortcutButtons = Array(buttons.prefix(2))
    }

    /// Scorciatoia della Dashboard: CarPlay apre l'app sullo schermo principale, lì si mostra l'anteprima
    private func startFromShortcut(_ place: Place) {
        if mapTemplate != nil { preview(place, item: nil) } else { pendingPlace = place }
    }

    private func syncSecondaryMaps() {
        for vc in [dashboardVC, clusterVC].compactMap({ $0 }) {
            if session != nil || state.panel == .navigating, let r = state.route {
                if !vc.navigating { vc.beginNavigation(route: r.coordinates) } else { vc.setRoute(r.coordinates) }
            } else if vc.navigating {
                vc.endNavigation()
            }
        }
    }

    // MARK: - Osservazione dello stato

    private func observe() {
        guard cancellables.isEmpty else { return }
        // receive(on:) → si legge lo stato dopo che è stato aggiornato (@Published avvisa prima)
        state.$panel.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.panelChanged() }.store(in: &cancellables)
        state.$routes.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.routesChanged() }.store(in: &cancellables)
        state.$selectedRoute.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.routesChanged() }.store(in: &cancellables)
        state.$progress.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.progressChanged() }.store(in: &cancellables)
        state.$isRerouting.receive(on: DispatchQueue.main)
            .sink { [weak self] rerouting in
                guard rerouting, let self = self, let s = self.session else { return }
                s.pauseTrip(for: .rerouting, description: "Ricalcolo del percorso…")
            }.store(in: &cancellables)
        state.$arrived.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.arrivalChanged() }.store(in: &cancellables)
        state.$themeIndex.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                for vc in [self.mapVC, self.dashboardVC, self.clusterVC].compactMap({ $0 }) { vc.applyTheme() }
                self.mapTemplate?.guidanceBackgroundColor = self.state.theme.accent
                self.maneuversRouteID = nil      // schede rifatte col nuovo colore
                self.progressChanged()
            }.store(in: &cancellables)
        state.$voiceMuted.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshButtons() }.store(in: &cancellables)
        state.$home.combineLatest(state.$work, state.$parking).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshDashboardButtons() }.store(in: &cancellables)
    }

    // MARK: - Pulsanti

    private func refreshButtons() {
        guard let t = mapTemplate else { return }
        if session != nil {
            let mute = CPBarButton(image: symbol(state.voiceMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")) { [weak self] _ in
                self?.state.voiceMuted.toggle()
            }
            let overview = CPBarButton(image: symbol("point.topleft.down.to.point.bottomright.curvepath")) { [weak self] _ in
                self?.mapVC?.showOverview()
            }
            let end = CPBarButton(title: "Termina") { [weak self] _ in
                self?.state.endNavigation()
            }
            t.leadingNavigationBarButtons = [mute, overview]
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
        center.image = symbol(session != nil ? "location.north.line.fill" : "location.fill")
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
        guard let ic = interface else { return }
        let ok = CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            self?.interface?.dismissTemplate(animated: true, completion: nil)
        }
        let a = CPAlertTemplate(titleVariants: [text], actions: [ok])
        if ic.presentedTemplate != nil {
            ic.dismissTemplate(animated: false) { _, _ in
                ic.presentTemplate(a, animated: true, completion: nil)
            }
        } else {
            ic.presentTemplate(a, animated: true, completion: nil)
        }
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
        nearby.accessoryType = .disclosureIndicator
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
            self?.preview(place, item: nil, completion: done)
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
        let buttons = cats.map { (cat: (String, String, String)) -> CPGridButton in
            CPGridButton(titleVariants: [cat.0], image: symbol(cat.2, size: 30)) { [weak self] _ in
                self?.runSearch(cat.1, title: cat.0)
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
            let items = response?.mapItems ?? []
            DispatchQueue.main.async { self?.showResults(items, title: title) }
        }
    }

    private func showResults(_ items: [MKMapItem], title: String) {
        guard !items.isEmpty else { alert("Nessun risultato per \"\(title)\""); return }
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
                let place = Place(mapItem: mi)
                self?.state.addToHistory(place)
                self?.preview(place, item: mi, completion: done)
            }
            return it
        }
        interface?.pushTemplate(CPListTemplate(title: title, sections: [CPListSection(items: list)]),
                                animated: true, completion: nil)
    }

    // MARK: - Anteprima del viaggio

    /// Calcola i percorsi dalla posizione reale e mostra l'anteprima (fino a 3 percorsi).
    /// `completion` chiude lo spinner della riga toccata quando i percorsi sono pronti.
    func preview(_ place: Place, item: MKMapItem?, completion: (() -> Void)? = nil) {
        guard mapTemplate != nil else { completion?(); return }
        if session != nil {
            completion?()
            alert("Termina prima la navigazione in corso")
            return
        }
        DirectionsService.routes(from: state.location.location?.coordinate, to: place.coordinate,
                                 destinationItem: item, mode: .car, options: state.routeOptions,
                                 alternatives: true) { [weak self] infos in
            completion?()
            guard let self = self, self.mapTemplate != nil else { return }
            let routes = Array(infos.filter { !$0.etaOnly && $0.coordinates.count > 1 }.prefix(3))
            guard !routes.isEmpty else { self.alert("Impossibile calcolare il percorso"); return }
            self.presentPreview(place: place, item: item, routes: routes, selected: 0, fromPhone: false)
        }
    }

    private func presentPreview(place: Place?, item: MKMapItem?, routes: [RouteInfo], selected: Int, fromPhone: Bool) {
        guard let t = mapTemplate else { return }
        previewRoutes = routes
        previewPlace = place
        previewItem = item
        previewFromPhone = fromPhone
        let trip = makeTrip(place: place, item: item, routes: routes)
        previewTrip = trip
        interface?.popToRootTemplate(animated: true, completion: nil)
        let text = CPTripPreviewTextConfiguration(startButtonTitle: "Avvia",
                                                  additionalRoutesButtonTitle: "Altri percorsi",
                                                  overviewButtonTitle: "Panoramica")
        t.showTripPreviews([trip], textConfiguration: text)
        let sel = routes.indices.contains(selected) ? selected : 0
        mapVC?.showPreview(routes[sel].coordinates)
        t.updateEstimates(travel(routes[sel].distance, time: routes[sel].travelTime), for: trip)
        refreshButtons()
    }

    private func cancelPreview() {
        mapTemplate?.hideTripPreviews()
        let fromPhone = previewFromPhone
        clearPreview()
        mapVC?.endPreview()
        refreshButtons()
        // annullata in auto: si chiude anche il pannello "Indicazioni" del telefono
        if fromPhone && state.panel == .directions { state.dismissPanel() }
    }

    private func clearPreview() {
        previewRoutes = []
        previewPlace = nil
        previewItem = nil
        previewTrip = nil
        previewFromPhone = false
    }

    /// Percorsi scelti sul telefono (pannello "Indicazioni"): li mostra anche in auto, come Apple Maps
    private func syncPhonePreview() {
        guard session == nil, mapTemplate != nil else { return }
        let phoneRoutes = state.routes.filter { !$0.etaOnly && $0.coordinates.count > 1 }
        if state.panel == .directions, !phoneRoutes.isEmpty, state.routes.count == phoneRoutes.count {
            if previewFromPhone, previewRoutes.map(\.id) == phoneRoutes.map(\.id) {
                // stessi percorsi: si aggiorna solo il percorso evidenziato
                if phoneRoutes.indices.contains(state.selectedRoute) {
                    mapVC?.showPreview(phoneRoutes[state.selectedRoute].coordinates)
                }
                return
            }
            presentPreview(place: state.pinnedPlace, item: state.destinationItem, routes: phoneRoutes,
                           selected: state.selectedRoute, fromPhone: true)
        } else if previewFromPhone {
            mapTemplate?.hideTripPreviews()
            clearPreview()
            mapVC?.endPreview()
            refreshButtons()
        }
    }

    private func makeTrip(place: Place?, item: MKMapItem?, routes: [RouteInfo]) -> CPTrip {
        let coord = place?.coordinate ?? routes.first?.coordinates.last ?? CLLocationCoordinate2D()
        let dest = item ?? MKMapItem(placemark: MKPlacemark(coordinate: coord))
        let name = (place?.name.isEmpty == false ? place?.name : nil) ?? dest.name ?? "Destinazione"
        if dest.name == nil || dest.name?.isEmpty == true { dest.name = name }
        let choices = routes.enumerated().map { pair -> CPRouteChoice in
            let i = pair.offset, r = pair.element
            let dist = state.units.short(r.distance)
            let via = r.name.isEmpty ? "" : "via \(r.name)"
            var info = via.isEmpty ? dist : "\(via) · \(dist)"
            if r.hasTolls { info += " · pedaggi" }
            let arrival = "arrivo \(Formatters.time.string(from: Date().addingTimeInterval(r.travelTime)))"
            let choice = CPRouteChoice(summaryVariants: [i == 0 ? "Più veloce · \(r.durationText)" : r.durationText, r.durationText],
                                       additionalInformationVariants: ["\(info) · \(arrival)", info, dist],
                                       selectionSummaryVariants: [via.isEmpty ? r.durationText : via])
            choice.userInfo = i
            return choice
        }
        let t = CPTrip(origin: MKMapItem.forCurrentLocation(), destination: dest, routeChoices: choices)
        t.destinationNameVariants = [name]
        return t
    }

    // MARK: - Guida

    private func panelChanged() {
        if state.panel == .navigating {
            if session == nil { beginSession() }
        } else if let s = session {
            if state.arrived { s.finishTrip() } else { s.cancelTrip() }
            endSessionState()
        } else {
            syncPhonePreview()
        }
        syncSecondaryMaps()
        refreshDashboardButtons()
    }

    private func endSessionState() {
        session = nil
        trip = nil
        routeManeuvers = []
        maneuversRouteID = nil
        shownStep = -1
        shownStepRouteID = nil
        arrivalShown = false
        mapVC?.endNavigation()
        refreshButtons()
    }

    private func beginSession() {
        guard let t = mapTemplate, let r = state.route else { return }
        t.hideTripPreviews()
        let theTrip = pendingTrip ?? previewTrip ?? makeTrip(place: state.pinnedPlace, item: state.destinationItem, routes: [r])
        pendingTrip = nil
        clearPreview()
        trip = theTrip
        session = t.startNavigationSession(for: theTrip)
        routeManeuvers = []
        maneuversRouteID = nil
        shownStep = -1
        shownStepRouteID = nil
        arrivalShown = false
        interface?.popToRootTemplate(animated: false, completion: nil)
        mapVC?.beginNavigation(route: r.coordinates)
        refreshButtons()
        progressChanged()
    }

    private func routesChanged() {
        guard session != nil else {
            if state.panel == .directions || previewFromPhone { syncPhonePreview() }
            return
        }
        guard let r = state.route else { return }
        for vc in [mapVC, dashboardVC, clusterVC].compactMap({ $0 }) { vc.setRoute(r.coordinates) }
        progressChanged()
    }

    /// Tutte le manovre del percorso, create una volta per percorso: CarPlay (metadati iOS 17.4+) vuole
    /// riceverle tutte in ordine, e le schede mostrate devono essere gli stessi oggetti.
    private func ensureManeuvers(for r: RouteInfo) {
        guard maneuversRouteID != r.id || routeManeuvers.count != r.steps.count else { return }
        maneuversRouteID = r.id
        routeCumulative = RouteMath.cumulative(r.coordinates)
        let leftTraffic = CarPlayManeuvers.drivesOnLeft
        routeManeuvers = r.steps.enumerated().map { i, step in
            maneuver(step, index: i, route: r, leftTraffic: leftTraffic)
        }
        shownStep = -1
        if let s = session, s.responds(to: NSSelectorFromString("addManeuvers:")) {
            _ = s.perform(NSSelectorFromString("addManeuvers:"), with: routeManeuvers)
        }
    }

    private func progressChanged() {
        guard let s = session, let r = state.route, !r.steps.isEmpty else { return }
        ensureManeuvers(for: r)
        guard routeManeuvers.count == r.steps.count else { return }
        let p = state.progress
        let idx = min(max(p.nextStep, 0), r.steps.count - 1)

        if idx != shownStep || shownStepRouteID != r.id {
            shownStep = idx
            shownStepRouteID = r.id
            // scheda attuale + la successiva (CarPlay mostra la seconda quando c'è spazio)
            s.upcomingManeuvers = Array(routeManeuvers[idx..<min(idx + 2, routeManeuvers.count)])
            // strada su cui ti trovi (quadro strumenti / head-up display)
            s.currentRoadNameVariants = currentRoad(r, index: idx)
        }
        s.updateEstimates(estimates(distance: p.toManeuver, route: r), for: routeManeuvers[idx])
        if let t = trip {
            mapTemplate?.updateEstimates(travel(p.remaining, time: p.remainingTime), for: t)
        }
        if let st = CPManeuverState(rawValue: phase(progress: p, route: r, index: idx).rawValue) { s.maneuverState = st }

        // tratto percorso nascosto e zoom secondo la velocità, su tutti gli schermi dell'auto
        for vc in [mapVC, dashboardVC, clusterVC].compactMap({ $0 }) {
            vc.trimRoute(traveled: p.traveled, cumulative: routeCumulative)
            vc.adjustZoom(speedKmh: state.speedKmh)
        }
    }

    /// Fase della manovra (come Apple Maps): appena iniziata, in preparazione, da eseguire ora, prosegui
    private func phase(progress p: RouteProgress, route r: RouteInfo, index: Int) -> CarPlayManeuvers.Phase {
        let speed = max(state.location.location?.speed ?? 0, 0)
        let executeAt = r.mode == .walk ? 25 : max(60, speed * 6)
        let prepareAt = r.mode == .walk ? 120 : max(400, speed * 20)
        if p.toManeuver <= executeAt { return .execute }
        if p.toManeuver <= prepareAt { return .prepare }
        let sinceLast = index > 0 ? p.traveled - r.steps[index - 1].startDistance : p.traveled
        if sinceLast < (r.mode == .walk ? 20 : 80) { return .initial }
        return .continue
    }

    private func currentRoad(_ r: RouteInfo, index: Int) -> [String] {
        // la via in cui ti trovi è quella imboccata con la manovra precedente
        let source = index > 0 ? r.steps[index - 1].instruction : r.steps[0].instruction
        if index > 0, let road = Departure.street(in: source) { return [road] }
        if let road = r.steps.first?.instruction, let st = departureStreet(road) { return [st] }
        return []
    }

    /// "Procedi verso nord su Via Roma in direzione di …" → "Via Roma"
    private func departureStreet(_ text: String) -> String? {
        guard let r = text.range(of: " su ") else { return nil }
        var rest = String(text[r.upperBound...])
        if let cut = rest.range(of: " in direzione di ") { rest = String(rest[..<cut.lowerBound]) }
        return rest.isEmpty ? nil : rest
    }

    private func arrivalChanged() {
        guard state.arrived, !arrivalShown, let s = session else { return }
        arrivalShown = true
        let dest = state.pinnedPlace.map { $0.name.isEmpty ? "a destinazione" : "a \($0.name)" } ?? "a destinazione"
        s.pauseTrip(for: .arrived, description: "Sei arrivato \(dest)")
    }

    /// Scheda della manovra: testo di Apple Maps (intero → solo la via → solo la manovra se lo spazio
    /// è poco), freccia uguale al telefono in variante chiara/scura, tipo di manovra per i metadati.
    private func maneuver(_ step: RouteStep, index: Int, route r: RouteInfo, leftTraffic: Bool) -> CPManeuver {
        let m = CPManeuver()
        var variants = [step.instruction]
        let road = step.isDeparture ? departureStreet(step.instruction) : Departure.street(in: step.instruction)
        let short = Departure.maneuver(of: step.instruction).trimmingCharacters(in: .whitespacesAndNewlines)
        if !step.isDeparture, !short.isEmpty, short != step.instruction, let road = road {
            variants.append("\(short) · \(road)")
        }
        if let road = road, !variants.contains(road) { variants.append(road) }
        if !short.isEmpty, !variants.contains(short) { variants.append(short) }
        m.instructionVariants = variants
        m.dashboardInstructionVariants = variants
        m.notificationInstructionVariants = variants

        let icon = ManeuverIcon.symbol(for: step)
        m.symbolImage = CarPlayManeuvers.image(icon, size: 44)
        m.dashboardSymbolImage = CarPlayManeuvers.image(icon, size: 30)
        m.notificationSymbolImage = CarPlayManeuvers.image(icon, size: 30)
        m.cardBackgroundColor = state.theme.accent

        // stima del tratto che porta a questa manovra (dalla manovra precedente)
        let leg = index > 0 ? max(0, step.startDistance - r.steps[index - 1].startDistance) : step.distance
        m.initialTravelEstimates = estimates(distance: leg, route: r)

        // metadati per quadro strumenti / head-up display
        if let type = CPManeuverType(rawValue: CarPlayManeuvers.typeRaw(for: step)) { m.maneuverType = type }
        if let side = CPTrafficSide(rawValue: leftTraffic ? 1 : 0) { m.trafficSide = side }
        if let junction = CPJunctionType(rawValue: CarPlayManeuvers.isRoundabout(step) ? 1 : 0) { m.junctionType = junction }
        if let road = road { m.roadFollowingManeuverVariants = [road] }
        m.userInfo = index
        return m
    }

    private func estimates(distance: Double, route r: RouteInfo) -> CPTravelEstimates {
        let speed = r.travelTime > 0 ? max(r.distance / r.travelTime, 1) : 10
        return travel(distance, time: max(0, distance) / speed)
    }

    /// Distanza esatta (metadati per quadro strumenti) + distanza arrotondata da mostrare, come sul telefono
    private func travel(_ meters: Double, time: TimeInterval) -> CPTravelEstimates {
        CPTravelEstimates(distanceRemaining: Measurement(value: max(0, meters), unit: UnitLength.meters),
                          distanceRemainingToDisplay: measure(meters),
                          timeRemaining: max(0, time))
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
        if m < 10_000 { return Measurement(value: (m / 100).rounded() / 10, unit: .kilometers) }
        return Measurement(value: (m / 1000).rounded(), unit: .kilometers)
    }
}

// MARK: - CPMapTemplateDelegate

extension CarPlayManager: CPMapTemplateDelegate {
    func mapTemplate(_ mapTemplate: CPMapTemplate, selectedPreviewFor trip: CPTrip, using routeChoice: CPRouteChoice) {
        let i = routeChoice.userInfo as? Int ?? 0
        guard previewRoutes.indices.contains(i) else { return }
        let r = previewRoutes[i]
        mapVC?.showPreview(r.coordinates)
        mapTemplate.updateEstimates(travel(r.distance, time: r.travelTime),
                                    for: trip)
        // percorso arrivato dal telefono: la scelta si vede anche lì
        if previewFromPhone, state.panel == .directions, state.routes.indices.contains(i), state.selectedRoute != i {
            state.selectRoute(i)
        }
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        let i = routeChoice.userInfo as? Int ?? 0
        guard previewRoutes.indices.contains(i) else { return }
        mapTemplate.hideTripPreviews()
        let routes = previewRoutes
        let fromPhone = previewFromPhone
        let place = previewPlace
        let item = previewItem
        pendingTrip = trip
        clearPreview()
        if fromPhone && state.panel == .directions {
            // stessi percorsi del telefono: si avvia quello scelto
            state.selectedRoute = i
            state.startNavigation()
        } else if let place = place {
            // la guida parte sul telefono (stessa logica, stessa voce): CarPlay la segue
            state.pin(place, fly: false, item: item)
            state.travelMode = .car
            state.routes = routes
            state.selectedRoute = i
            state.startNavigation()
        }
    }

    func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        // il sistema ha chiuso la guida (es. è partita un'altra app di navigazione)
        endSessionState()
        if state.panel == .navigating { state.endNavigation() }
    }

    // metadati di navigazione per quadro strumenti e head-up display (iOS 17.4+)
    func mapTemplateShouldProvideNavigationMetadata(_ mapTemplate: CPMapTemplate) -> Bool { true }

    // notifiche quando sullo schermo dell'auto c'è un'altra app
    func mapTemplate(_ mapTemplate: CPMapTemplate, shouldShowNotificationFor maneuver: CPManeuver) -> Bool { true }

    func mapTemplate(_ mapTemplate: CPMapTemplate, shouldUpdateNotificationFor maneuver: CPManeuver,
                     with travelEstimates: CPTravelEstimates) -> Bool { true }

    func mapTemplate(_ mapTemplate: CPMapTemplate, shouldShowNotificationFor navigationAlert: CPNavigationAlert) -> Bool { true }

    // pannello "Sposta" (frecce)
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

    // trascinamento sullo schermo touch dell'auto
    func mapTemplateDidBeginPanGesture(_ mapTemplate: CPMapTemplate) { mapVC?.beginDrag() }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didUpdatePanGestureWithTranslation translation: CGPoint, velocity: CGPoint) {
        mapVC?.drag(translation: translation)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didEndPanGestureWithVelocity velocity: CGPoint) { mapVC?.endDrag() }

    // pizzico per lo zoom (iOS 26)
    func mapTemplateDidBeginZoomGesture(_ mapTemplate: CPMapTemplate) { mapVC?.beginZoomGesture() }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didUpdateZoomGestureWithCenter center: CGPoint, scale: CGFloat, velocity: CGFloat) {
        mapVC?.zoomGesture(scale: scale)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didEndZoomGestureWithVelocity velocity: CGFloat) { mapVC?.endZoomGesture() }
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
            let mi = response?.mapItems.first
            DispatchQueue.main.async {
                guard let self = self else { completionHandler(); return }
                if let mi = mi {
                    let place = Place(mapItem: mi)
                    self.state.addToHistory(place)
                    self.preview(place, item: mi, completion: completionHandler)
                } else {
                    completionHandler()
                    self.alert("Luogo non trovato")
                }
            }
        }
    }

    func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
        guard !lastQuery.isEmpty else { return }
        runSearch(lastQuery, title: lastQuery)
    }
}

extension CarPlayManager: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            let items: [CPListItem] = completer.results.prefix(listLimit).map { c in
                let it = CPListItem(text: c.title, detailText: c.subtitle)
                it.userInfo = c
                return it
            }
            searchHandler?(items)
            searchHandler = nil
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            searchHandler?([])
            searchHandler = nil
        }
    }
}
