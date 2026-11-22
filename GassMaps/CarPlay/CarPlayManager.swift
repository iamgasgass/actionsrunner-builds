import UIKit
import SwiftUI
import CarPlay
import MapKit
import MapLibre
import Combine

/// CarPlay di GassMaps = la schermata principale dell'app in orizzontale, identica al telefono e sincronizzata con esso
/// (CarLandscapeScreen: mappa del tema, barra, chip, scheda del luogo, indicazioni, banner di guida, pannello di guida,
/// tachimetro, pulsanti laterali).
///
/// CarPlay non passa i tocchi alle viste dell'app, quindi i comandi sono:
/// - pulsanti di CarPlay in alto e sulla destra, diversi secondo la schermata e collegati alle stesse funzioni
///   dei pulsanti del telefono (Avvia, Indicazioni, Percorsi, Termina, voce, panoramica, percorsi alternativi, centra…);
/// - elenchi di CarPlay per scegliere: Destinazioni, Nei dintorni, ricerca, risultati, percorsi;
/// - gesti sulla mappa: trascina, pizzica, frecce del pannello "Sposta".
/// Le barre di CarPlay si nascondono da sole dopo qualche secondo, lasciando visibile solo l'interfaccia di GassMaps.
///
/// Inoltre: mappa nel widget della Dashboard di CarPlay (con scorciatoie Casa/Lavoro) e nel quadro strumenti.
@MainActor
final class CarPlayManager: NSObject {
    static let shared = CarPlayManager()

    private let state = AppState.shared
    private var interface: CPInterfaceController?
    private var mapTemplate: CPMapTemplate?
    private var carScreen: CarScreenContext?
    private var cancellables = Set<AnyCancellable>()
    private var panning = false
    /// "Percorsi alternativi" chiesti dall'auto: quando arrivano si mostra l'elenco
    private var wantsAlternativesList = false
    /// destinazione scelta dalla Dashboard prima che lo schermo principale fosse collegato
    private var pendingPlace: Place?
    // gesti sullo schermo touch dell'auto
    private var dragStart: CGPoint?
    private var zoomStart: Double?

    // mappe secondarie (Dashboard, quadro strumenti)
    private var dashboardVC: CarPlayMapViewController?
    private var dashboardController: CPDashboardController?
    private var clusterVC: CarPlayMapViewController?
    private var clusterController: CPInstrumentClusterController?
    private var secondaryRouteID: UUID?
    private var secondaryCumulative: [Double] = []

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

    func connect(_ interfaceController: CPInterfaceController, window: CPWindow) {
        interface = interfaceController
        state.location.setCarPlay(true)

        // mappa dell'auto: riceve le stesse azioni della mappa del telefono
        let ctx = CarScreenContext(state: state)
        carScreen = ctx
        state.map.mirror = ctx.map
        ctx.map.onAttach = { [weak self] in self?.replayState() }
        window.rootViewController = CarLandscapeHost.make(state: state, context: ctx)

        interfaceController.prefersDarkUserInterfaceStyle = true
        let t = CPMapTemplate()
        t.mapDelegate = self
        // barre e pulsanti di CarPlay compaiono al tocco e poi si nascondono: resta l'interfaccia di GassMaps
        t.automaticallyHidesNavigationBar = true
        t.hidesButtonsWithNavigationBar = true
        mapTemplate = t
        refreshButtons()
        interfaceController.setRootTemplate(t, animated: false, completion: nil)

        observe()
        // app avviata dall'auto senza passare dal telefono: si chiude l'intestazione d'avvio come farebbe lo splash
        if state.showHeader {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
                withAnimation(.easeInOut(duration: 0.45)) { self?.state.showHeader = false }
            }
        }
        checkLocationPermission()
        if let p = pendingPlace {
            pendingPlace = nil
            state.go(to: p)
        }
    }

    func disconnect() {
        if state.map.mirror === carScreen?.map { state.map.mirror = nil }
        carScreen = nil
        searchHandler = nil
        wantsAlternativesList = false
        dragStart = nil
        zoomStart = nil
        mapTemplate = nil
        interface = nil
        afterScreenChange()
    }

    /// La mappa dell'auto appena collegata mostra subito quello che mostra il telefono
    private func replayState() {
        guard let car = carScreen?.map else { return }
        let phone = state.map
        if !state.searchResults.isEmpty && state.panel == .results { car.showResults(state.searchResults) }
        if let p = state.pinnedPlace, state.panel != .none { car.showPin(p) }
        if phone.routeCoordinates.count > 1 {
            car.showRoute(phone.routeCoordinates, alternatives: phone.alternativeCoordinates,
                          overview: state.panel == .directions)
        }
        if state.panel == .navigating {
            car.startNavigation()
        } else if state.panel == .pinned || state.panel == .results || state.panel == .saved || state.panel == .myLocation {
            car.setBottomInset(330)
        }
        if state.measuring { car.drawMeasure(state.measurePoints) }
    }

    /// Manovra o avviso toccati in una notifica di CarPlay: si torna alla mappa
    func showGuidance() {
        interface?.popToRootTemplate(animated: true, completion: nil)
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

    // MARK: - Osservazione dello stato

    private func observe() {
        guard cancellables.isEmpty else { return }
        // receive(on:) → si legge lo stato dopo che è stato aggiornato (@Published avvisa prima)
        state.$panel.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.panelChanged() }.store(in: &cancellables)
        state.$voiceMuted.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshButtons() }.store(in: &cancellables)
        state.$tracking.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshButtons() }.store(in: &cancellables)
        state.$navAlternatives.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.alternativesChanged() }.store(in: &cancellables)
        state.$routes.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncSecondaryMaps() }.store(in: &cancellables)
        state.$progress.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateSecondaryProgress() }.store(in: &cancellables)
        state.$themeIndex.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                for vc in [self.dashboardVC, self.clusterVC].compactMap({ $0 }) { vc.applyTheme() }
            }.store(in: &cancellables)
        state.$home.combineLatest(state.$work, state.$parking).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshDashboardButtons() }.store(in: &cancellables)
    }

    private func panelChanged() {
        refreshButtons()
        syncSecondaryMaps()
        refreshDashboardButtons()
        // la guida è partita (dal telefono o dall'auto): via gli elenchi aperti, si vede la guida
        if state.panel == .navigating { interface?.popToRootTemplate(animated: true, completion: nil) }
    }

    // MARK: - Pulsanti di CarPlay (le stesse funzioni dei pulsanti del telefono)

    private func bar(_ title: String, _ action: @escaping (CarPlayManager) -> Void) -> CPBarButton {
        CPBarButton(title: title) { [weak self] _ in if let self = self { action(self) } }
    }

    private func bar(icon: String, _ action: @escaping (CarPlayManager) -> Void) -> CPBarButton {
        CPBarButton(image: symbol(icon)) { [weak self] _ in if let self = self { action(self) } }
    }

    private func mapButton(_ icon: String, _ action: @escaping (CarPlayManager) -> Void) -> CPMapButton {
        let b = CPMapButton { [weak self] _ in if let self = self { action(self) } }
        b.image = symbol(icon)
        return b
    }

    private func refreshButtons() {
        guard let t = mapTemplate else { return }
        var leading: [CPBarButton] = []
        var trailing: [CPBarButton] = []

        switch state.panel {
        case .navigating:
            // come i pulsanti laterali della guida: voce, panoramica, percorsi alternativi; "Termina percorso"
            leading = [bar(icon: state.voiceMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") { $0.state.voiceMuted.toggle() },
                       bar(icon: "map.fill") { $0.state.showRouteOverview() }]
            trailing = [bar(icon: "arrow.triangle.branch") { $0.requestAlternatives() },
                        bar("Termina") { $0.state.endNavigation() }]
        case .directions:
            // pannello "Indicazioni": annulla, scelta del percorso, Avvia
            leading = [bar("Annulla") { $0.state.dismissPanel() },
                       bar("Percorsi") { $0.showRouteChoices() }]
            trailing = [bar("Avvia") { $0.state.startNavigation() }]
        case .pinned:
            // scheda del luogo: chiudi, cerca; Indicazioni e Avvia
            leading = [bar("Chiudi") { $0.state.dismissPanel() },
                       bar(icon: "magnifyingglass") { $0.showSearch() }]
            trailing = [bar("Indicazioni") { $0.state.requestDirections() },
                        bar("Avvia") { $0.state.startDirectly() }]
        case .results:
            leading = [bar("Chiudi") { $0.state.closeResults() },
                       bar(icon: "magnifyingglass") { $0.showSearch() }]
            trailing = [bar("Risultati") { $0.showSearchResults() }]
        case .saved, .myLocation:
            leading = [bar("Chiudi") { $0.state.dismissPanel() },
                       bar("Destinazioni") { $0.showDestinations() }]
            trailing = [bar(icon: "magnifyingglass") { $0.showSearch() }]
        case .none:
            leading = [bar("Destinazioni") { $0.showDestinations() }]
            trailing = [bar(icon: "magnifyingglass") { $0.showSearch() }]
        }
        t.leadingNavigationBarButtons = leading
        t.trailingNavigationBarButtons = trailing

        // a destra: posizione/riposiziona (stesso pulsante del telefono), zoom, sposta
        let locate: CPMapButton
        if state.panel == .navigating {
            locate = mapButton(state.tracking == .none ? "location.north.fill" : "location.north.line.fill") {
                $0.state.repositionNavigation()
            }
        } else {
            let icon: String
            switch state.tracking {
            case .none: icon = "location"
            case .follow: icon = "location.fill"
            case .heading: icon = "location.north.line.fill"
            }
            locate = mapButton(icon) { $0.state.cycleTracking() }
        }
        t.mapButtons = [locate,
                        mapButton("plus") { $0.carMap?.zoom(by: 1) },
                        mapButton("minus") { $0.carMap?.zoom(by: -1) },
                        mapButton(panning ? "xmark" : "arrow.up.and.down.and.arrow.left.and.right") { $0.togglePanning() }]
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

    private var listLimit: Int { min(12, CPListTemplate.maximumItemCount) }

    private func push(_ template: CPTemplate) {
        interface?.pushTemplate(template, animated: true, completion: nil)
    }

    /// dopo una scelta si torna alla schermata di GassMaps
    private func backToMap() {
        interface?.popToRootTemplate(animated: true, completion: nil)
    }

    /// mappa dello schermo dell'auto
    private var carMap: CarMapGestures? {
        guard let m = carScreen?.map.mapView else { return nil }
        return CarMapGestures(map: m)
    }

    // MARK: - Destinazioni (come "Salvati" e la ricerca del telefono)

    private func showDestinations() {
        var top: [CPListItem] = []
        // Casa, Lavoro e parcheggio aprono subito le indicazioni (come le scorciatoie del telefono)
        if let h = state.home { top.append(placeItem(h, title: "Casa", icon: "house.fill", directions: true)) }
        if let w = state.work { top.append(placeItem(w, title: "Lavoro", icon: "briefcase.fill", directions: true)) }
        if let p = state.parking {
            top.append(placeItem(p, title: "Auto parcheggiata", icon: "parkingsign.circle.fill", directions: true))
        }
        let nearby = CPListItem(text: "Nei dintorni", detailText: "Le stesse categorie dei chip della mappa",
                                image: symbol("mappin.and.ellipse"))
        nearby.accessoryType = .disclosureIndicator
        nearby.handler = { [weak self] _, done in
            self?.showCategories()
            done()
        }
        top.append(nearby)

        var sections = [CPListSection(items: top)]
        let saved = state.saved.prefix(listLimit).map { placeItem($0, title: nil, icon: "star.fill", directions: false) }
        if !saved.isEmpty { sections.append(CPListSection(items: saved, header: "Salvati", sectionIndexTitle: nil)) }
        let recent = state.history.prefix(listLimit).map { placeItem($0, title: nil, icon: "clock.arrow.circlepath", directions: false) }
        if !recent.isEmpty { sections.append(CPListSection(items: recent, header: "Recenti", sectionIndexTitle: nil)) }

        push(CPListTemplate(title: "Destinazioni", sections: sections))
    }

    private func placeItem(_ place: Place, title: String?, icon: String, directions: Bool) -> CPListItem {
        let name = place.name.isEmpty ? "Posizione" : place.name
        var detail = title == nil ? place.address : (place.name.isEmpty ? place.address : place.name)
        if let here = state.location.location {
            let d = here.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
            detail = detail.isEmpty ? state.units.short(d) : "\(state.units.short(d)) · \(detail)"
        }
        let item = CPListItem(text: title ?? name, detailText: detail, image: symbol(icon))
        item.handler = { [weak self] _, done in
            done()
            guard let self = self else { return }
            if self.state.panel == .navigating {
                self.alert("Termina prima la navigazione in corso")
                return
            }
            if directions {
                self.state.go(to: place)        // pannello "Indicazioni" con i percorsi
            } else {
                self.state.pin(place)           // scheda del luogo
            }
            self.backToMap()
        }
        return item
    }

    /// Le stesse categorie dei chip sotto la barra di ricerca del telefono
    private func showCategories() {
        let electric = ["electric", "plugin"].contains(UserDefaults.standard.string(forKey: Prefs.engine) ?? "gas")
        let cats: [(String, String)] = [
            ("Ristoranti", "fork.knife"),
            electric ? ("Ricarica elettrica", "bolt.car.fill") : ("Benzina", "fuelpump.fill"),
            ("Caffè", "cup.and.saucer.fill"), ("Supermercati", "cart.fill"),
            ("Hotel", "bed.double.fill"), ("Farmacie", "pills.fill"),
            ("Parcheggi", "parkingsign"), ("Bancomat", "creditcard.fill")
        ]
        let buttons = cats.map { cat -> CPGridButton in
            CPGridButton(titleVariants: [cat.0], image: symbol(cat.1, size: 30)) { [weak self] _ in
                guard let self = self else { return }
                if self.state.panel == .navigating {
                    self.alert("Termina prima la navigazione in corso")
                    return
                }
                self.state.searchCategory(cat.0)      // pannello "Risultati" come col chip del telefono
                self.backToMap()
            }
        }
        push(CPGridTemplate(title: "Nei dintorni", gridButtons: buttons))
    }

    // MARK: - Ricerca

    private func showSearch() {
        if let loc = state.location.location {
            completer.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        }
        let s = CPSearchTemplate()
        s.delegate = self
        push(s)
    }

    /// Elenco dei risultati mostrati nel pannello "Risultati"
    private func showSearchResults() {
        let items = state.searchResults
        guard !items.isEmpty else { return }
        let here = state.location.location
        let list: [CPListItem] = items.prefix(listLimit).map { mi in
            var detail = Place.formatShort(mi.placemark)
            if let h = here, let l = mi.placemark.location {
                detail = "\(state.units.short(l.distance(from: h))) · \(detail)"
            }
            let it = CPListItem(text: mi.name ?? "Luogo", detailText: detail)
            it.handler = { [weak self] _, done in
                done()
                self?.state.pin(Place(mapItem: mi), item: mi)
                self?.backToMap()
            }
            return it
        }
        push(CPListTemplate(title: state.resultsTitle.isEmpty ? "Risultati" : state.resultsTitle,
                            sections: [CPListSection(items: list)]))
    }

    // MARK: - Percorsi

    /// Pannello "Indicazioni": scelta tra i percorsi proposti (come toccarli nel pannello del telefono)
    private func showRouteChoices() {
        let routes = state.routes
        guard !routes.isEmpty else { return }
        let items: [CPListItem] = routes.enumerated().map { pair in
            let i = pair.offset, r = pair.element
            var detail = state.units.short(r.distance)
            if !r.name.isEmpty { detail = "via \(r.name) · \(detail)" }
            if r.hasTolls { detail += " · pedaggi" }
            let title = (i == 0 ? "Più veloce · " : "") + r.durationText
            let it = CPListItem(text: title, detailText: detail,
                                image: symbol(i == state.selectedRoute ? "checkmark.circle.fill" : "circle"))
            it.handler = { [weak self] _, done in
                done()
                self?.state.selectRoute(i)
                self?.backToMap()
            }
            return it
        }
        push(CPListTemplate(title: "Percorsi", sections: [CPListSection(items: items)]))
    }

    /// Durante la guida: percorsi alternativi da qui (stesso pulsante del telefono), poi l'elenco per sceglierne uno
    private func requestAlternatives() {
        wantsAlternativesList = true
        if state.navAlternatives.isEmpty { state.showNavAlternatives() } else { alternativesChanged() }
    }

    private func alternativesChanged() {
        guard wantsAlternativesList, state.panel == .navigating, !state.navAlternatives.isEmpty else { return }
        wantsAlternativesList = false
        let remaining = state.progress.remainingTime
        let items: [CPListItem] = state.navAlternatives.enumerated().map { pair in
            let i = pair.offset, alt = pair.element
            let diff = (alt.travelTime - remaining) / 60
            let text: String
            if abs(diff) < 1 { text = "Durata simile" }
            else if diff > 0 { text = "\(Int(diff.rounded())) min in più" }
            else { text = "\(Int((-diff).rounded())) min in meno" }
            let detail = alt.name.isEmpty ? alt.durationText : "via \(alt.name) · \(alt.durationText)"
            let it = CPListItem(text: text, detailText: detail, image: symbol("arrow.triangle.branch"))
            it.handler = { [weak self] _, done in
                done()
                self?.state.switchToNavAlternative(i)
                self?.backToMap()
            }
            return it
        }
        let keep = CPListItem(text: "Mantieni il percorso attuale", detailText: nil, image: symbol("xmark"))
        keep.handler = { [weak self] _, done in
            done()
            self?.state.repositionNavigation()
            self?.backToMap()
        }
        push(CPListTemplate(title: "Percorsi alternativi", sections: [CPListSection(items: items + [keep])]))
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
        secondaryRouteID = nil
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
        secondaryRouteID = nil
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
                subtitle = [state.units.short(here.distance(from: CLLocation(latitude: p.latitude, longitude: p.longitude)))]
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

    /// Scorciatoia della Dashboard: CarPlay apre l'app sullo schermo principale con le indicazioni
    private func startFromShortcut(_ place: Place) {
        guard state.panel != .navigating else { return }
        if interface != nil { state.go(to: place) } else { pendingPlace = place }
    }

    private func syncSecondaryMaps() {
        let maps = [dashboardVC, clusterVC].compactMap { $0 }
        guard !maps.isEmpty else { return }
        if state.panel == .navigating, let r = state.route {
            if secondaryRouteID != r.id {
                secondaryRouteID = r.id
                secondaryCumulative = RouteMath.cumulative(r.coordinates)
            }
            for vc in maps {
                if vc.navigating { vc.setRoute(r.coordinates) } else { vc.beginNavigation(route: r.coordinates) }
            }
        } else {
            secondaryRouteID = nil
            for vc in maps where vc.navigating { vc.endNavigation() }
        }
    }

    private func updateSecondaryProgress() {
        guard state.panel == .navigating, let r = state.route else { return }
        if secondaryRouteID != r.id { syncSecondaryMaps() }
        for vc in [dashboardVC, clusterVC].compactMap({ $0 }) {
            vc.trimRoute(traveled: state.progress.traveled, cumulative: secondaryCumulative)
            vc.adjustZoom(speedKmh: state.speedKmh)
        }
    }
}

/// Zoom e spostamenti della mappa dell'auto (pulsanti e frecce di CarPlay)
@MainActor
struct CarMapGestures {
    let map: MLNMapView

    func zoom(by delta: Double) {
        map.setZoomLevel(min(max(map.zoomLevel + delta, 3), 19.5), animated: true)
    }

    /// la mappa smette di seguire la posizione: compare "Riposiziona", come spostandola col dito sul telefono
    func stopFollowing() {
        if map.userTrackingMode != .none { map.setUserTrackingMode(.none, animated: false, completionHandler: nil) }
    }

    func pan(dx: CGFloat, dy: CGFloat) {
        stopFollowing()
        let step = min(map.bounds.width, map.bounds.height) * 0.3
        let p = CGPoint(x: map.bounds.midX + dx * step, y: map.bounds.midY + dy * step)
        map.setCenter(map.convert(p, toCoordinateFrom: map), animated: true)
    }
}

// MARK: - CPMapTemplateDelegate (frecce "Sposta" e gesti sullo schermo touch dell'auto)

extension CarPlayManager: CPMapTemplateDelegate {
    func mapTemplate(_ mapTemplate: CPMapTemplate, panWith direction: CPMapTemplate.PanDirection) {
        var dx: CGFloat = 0, dy: CGFloat = 0
        if direction.contains(.left) { dx = -1 }
        if direction.contains(.right) { dx = 1 }
        if direction.contains(.up) { dy = -1 }
        if direction.contains(.down) { dy = 1 }
        carMap?.pan(dx: dx, dy: dy)
    }

    func mapTemplateDidShowPanningInterface(_ mapTemplate: CPMapTemplate) {
        panning = true
        refreshButtons()
    }

    func mapTemplateDidDismissPanningInterface(_ mapTemplate: CPMapTemplate) {
        panning = false
        refreshButtons()
    }

    // trascinamento
    func mapTemplateDidBeginPanGesture(_ mapTemplate: CPMapTemplate) {
        guard let g = carMap else { return }
        g.stopFollowing()
        dragStart = g.map.convert(g.map.centerCoordinate, toPointTo: g.map)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didUpdatePanGestureWithTranslation translation: CGPoint, velocity: CGPoint) {
        guard let m = carMap?.map, let start = dragStart else { return }
        let p = CGPoint(x: start.x - translation.x, y: start.y - translation.y)
        m.setCenter(m.convert(p, toCoordinateFrom: m), animated: false)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didEndPanGestureWithVelocity velocity: CGPoint) {
        dragStart = nil
    }

    // pizzico (iOS 26)
    func mapTemplateDidBeginZoomGesture(_ mapTemplate: CPMapTemplate) {
        guard let g = carMap else { return }
        g.stopFollowing()
        zoomStart = g.map.zoomLevel
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didUpdateZoomGestureWithCenter center: CGPoint, scale: CGFloat, velocity: CGFloat) {
        guard let m = carMap?.map, let z0 = zoomStart, scale > 0 else { return }
        m.setZoomLevel(min(max(z0 + log2(Double(scale)), 3), 19.5), animated: false)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didEndZoomGestureWithVelocity velocity: CGFloat) {
        zoomStart = nil
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

    /// Suggerimento scelto: come sceglierlo nella ricerca del telefono (scheda del luogo, cronologia)
    func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        guard let completion = item.userInfo as? MKLocalSearchCompletion else { completionHandler(); return }
        MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start { [weak self] response, _ in
            let mi = response?.mapItems.first
            DispatchQueue.main.async {
                completionHandler()
                guard let self = self else { return }
                guard let mi = mi else { self.alert("Luogo non trovato"); return }
                if self.state.panel == .navigating {
                    self.alert("Termina prima la navigazione in corso")
                    return
                }
                self.state.searchPurpose = .destination
                self.state.select(mapItem: mi)
                self.backToMap()
            }
        }
    }

    /// Tasto "Cerca": risultati sulla mappa nel pannello "Risultati", come la ricerca del telefono
    func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
        guard !lastQuery.isEmpty, state.panel != .navigating else { return }
        state.searchCategory(lastQuery)
        backToMap()
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
