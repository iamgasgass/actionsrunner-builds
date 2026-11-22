import MapKit
import SwiftUI

/// Ricerca, calcolo del percorso e guida simulata lungo il percorso.
final class NavigationModel: NSObject, ObservableObject {
    enum Phase: Equatable {
        case browsing
        case preview
        case navigating
    }

    @Published var query = ""
    @Published private(set) var results: [MKMapItem] = []
    @Published private(set) var isSearching = false
    @Published private(set) var phase: Phase = .browsing
    @Published private(set) var destination: MKMapItem?
    @Published private(set) var routes: [MKRoute] = []
    @Published var selectedRouteIndex = 0
    @Published private(set) var errorMessage: String?

    // Guida
    @Published private(set) var isSimulating = false
    @Published private(set) var traveled: CLLocationDistance = 0
    @Published private(set) var currentStepIndex = 0
    @Published private(set) var simulatedSpeedKmh: Double = 0
    @Published var followUser = true

    var simulationMultiplier: Double = 4

    private(set) weak var mapView: MKMapView?
    private let carAnnotation = MKPointAnnotation()
    private var routeCoordinates: [CLLocationCoordinate2D] = []
    private var cumulative: [CLLocationDistance] = []
    private var stepEnds: [CLLocationDistance] = []
    private var simTimer: Timer?
    private var search: MKLocalSearch?

    var route: MKRoute? {
        routes.indices.contains(selectedRouteIndex) ? routes[selectedRouteIndex] : nil
    }

    var remainingDistance: CLLocationDistance {
        max(0, (route?.distance ?? 0) - traveled)
    }

    var remainingTime: TimeInterval {
        guard let route = route, route.distance > 0 else { return 0 }
        return route.expectedTravelTime * (remainingDistance / route.distance)
    }

    var currentStep: MKRoute.Step? {
        guard let steps = route?.steps, steps.indices.contains(currentStepIndex) else { return nil }
        return steps[currentStepIndex]
    }

    var nextStep: MKRoute.Step? {
        guard let steps = route?.steps, steps.indices.contains(currentStepIndex + 1) else { return nil }
        return steps[currentStepIndex + 1]
    }

    var distanceToNextManeuver: CLLocationDistance {
        guard stepEnds.indices.contains(currentStepIndex) else { return 0 }
        return max(0, stepEnds[currentStepIndex] - traveled)
    }

    // MARK: - Map view

    func attach(_ map: MKMapView) {
        mapView = map
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
        for (i, r) in routes.enumerated() where phase != .browsing {
            if phase == .navigating && i != selectedRouteIndex { continue }
            map.addOverlay(r.polyline, level: .aboveRoads)
        }
        if let dest = destination {
            let pin = MKPointAnnotation()
            pin.coordinate = dest.placemark.coordinate
            pin.title = dest.name
            map.addAnnotation(pin)
        }
        if isSimulating {
            map.addAnnotation(carAnnotation)
        }
        if phase == .preview { zoomToRoutes(animated: false) }
    }

    func isCar(_ annotation: MKAnnotation) -> Bool {
        (annotation as? MKPointAnnotation) === carAnnotation
    }

    func isSelectedRoute(_ polyline: MKPolyline) -> Bool {
        route?.polyline === polyline
    }

    var currentCoordinate: CLLocationCoordinate2D? {
        if isSimulating { return carAnnotation.coordinate }
        if let loc = mapView?.userLocation.location { return loc.coordinate }
        return mapView?.centerCoordinate
    }

    func centerOnUser() {
        guard let map = mapView else { return }
        followUser = true
        if let c = currentCoordinate {
            let region = MKCoordinateRegion(center: c, latitudinalMeters: 1500, longitudinalMeters: 1500)
            map.setRegion(region, animated: true)
        }
        if !isSimulating {
            map.setUserTrackingMode(.follow, animated: true)
        }
    }

    func zoom(_ factor: Double) {
        guard let map = mapView else { return }
        var region = map.region
        region.span.latitudeDelta = min(120, max(0.0005, region.span.latitudeDelta * factor))
        region.span.longitudeDelta = min(120, max(0.0005, region.span.longitudeDelta * factor))
        map.setRegion(region, animated: true)
    }

    // MARK: - Ricerca

    func performSearch(_ text: String? = nil) {
        let q = (text ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; return }
        query = q
        search?.cancel()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        if let map = mapView {
            request.region = map.region
        }
        isSearching = true
        errorMessage = nil
        let s = MKLocalSearch(request: request)
        search = s
        s.start { [weak self] response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isSearching = false
                if let items = response?.mapItems, !items.isEmpty {
                    self.results = items
                } else {
                    self.results = []
                    self.errorMessage = error == nil ? "Nessun risultato" : "Ricerca non disponibile"
                }
            }
        }
    }

    /// Cerca e avvia subito il percorso verso il primo risultato (usato dall'assistente vocale).
    func searchAndRoute(_ text: String, completion: @escaping (String?) -> Void) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let map = mapView { request.region = map.region }
        MKLocalSearch(request: request).start { [weak self] response, _ in
            DispatchQueue.main.async {
                guard let self = self, let item = response?.mapItems.first else {
                    completion(nil)
                    return
                }
                self.query = text
                self.results = response?.mapItems ?? []
                self.select(item)
                completion(item.name)
            }
        }
    }

    func clearSearch() {
        search?.cancel()
        query = ""
        results = []
        errorMessage = nil
    }

    // MARK: - Percorso

    func select(_ item: MKMapItem) {
        destination = item
        results = []
        let request = MKDirections.Request()
        if let c = currentCoordinate {
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: c))
        } else {
            request.source = MKMapItem.forCurrentLocation()
        }
        request.destination = item
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        errorMessage = nil
        MKDirections(request: request).calculate { [weak self] response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let routes = response?.routes, !routes.isEmpty else {
                    self.errorMessage = "Impossibile calcolare il percorso"
                    self.routes = []
                    self.phase = .browsing
                    if let map = self.mapView { self.attach(map) }
                    return
                }
                self.routes = routes
                self.selectedRouteIndex = 0
                self.phase = .preview
                if let map = self.mapView { self.attach(map) }
            }
        }
    }

    func chooseRoute(_ index: Int) {
        guard routes.indices.contains(index) else { return }
        selectedRouteIndex = index
        if let map = mapView { attach(map) }
    }

    func zoomToRoutes(animated: Bool) {
        guard let map = mapView, !routes.isEmpty else { return }
        var rect = routes[0].polyline.boundingMapRect
        for r in routes.dropFirst() { rect = rect.union(r.polyline.boundingMapRect) }
        map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 60, left: 60, bottom: 60, right: 340), animated: animated)
    }

    func startNavigation(simulate: Bool) {
        guard let route = route else { return }
        prepareGeometry(for: route)
        traveled = 0
        currentStepIndex = firstMeaningfulStep(from: 0)
        phase = .navigating
        followUser = true
        if simulate {
            isSimulating = true
            carAnnotation.coordinate = routeCoordinates.first ?? route.polyline.coordinate
            startSimTimer()
        }
        if let map = mapView {
            attach(map)
            if !simulate { map.setUserTrackingMode(.followWithHeading, animated: true) }
            updateCamera(animated: false)
        }
    }

    func endNavigation() {
        simTimer?.invalidate()
        simTimer = nil
        isSimulating = false
        simulatedSpeedKmh = 0
        phase = .browsing
        routes = []
        destination = nil
        traveled = 0
        currentStepIndex = 0
        if let map = mapView {
            attach(map)
            let cam = map.camera.copy() as? MKMapCamera ?? MKMapCamera()
            cam.pitch = 0
            cam.heading = 0
            map.setCamera(cam, animated: true)
        }
    }

    func cancelPreview() {
        endNavigation()
    }

    // MARK: - Simulazione

    func toggleSimulationPause() {
        if simTimer == nil { startSimTimer() } else {
            simTimer?.invalidate()
            simTimer = nil
            simulatedSpeedKmh = 0
        }
    }

    var simulationPaused: Bool { isSimulating && simTimer == nil }

    private func startSimTimer() {
        simTimer?.invalidate()
        simTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.simStep(dt: 0.1)
        }
    }

    private func simStep(dt: Double) {
        guard let route = route, !routeCoordinates.isEmpty else { return }
        // Velocità variabile in base al tipo di strada stimato dalla lunghezza del passo.
        let stepLen = currentStep?.distance ?? 500
        let base: Double = stepLen > 5000 ? 110 : (stepLen > 1200 ? 70 : 45)
        let wobble = sin(traveled / 180) * 6
        simulatedSpeedKmh = base + wobble
        let metersPerSecond = (simulatedSpeedKmh / 3.6) * simulationMultiplier
        traveled = min(route.distance, traveled + metersPerSecond * dt)

        carAnnotation.coordinate = coordinate(at: traveled)

        while stepEnds.indices.contains(currentStepIndex), traveled >= stepEnds[currentStepIndex],
              currentStepIndex < stepEnds.count - 1 {
            currentStepIndex += 1
        }

        updateCamera(animated: false)

        if traveled >= route.distance - 1 {
            simTimer?.invalidate()
            simTimer = nil
            simulatedSpeedKmh = 0
            NotificationCenter.default.post(name: .navigationArrived, object: destination?.name)
        }
    }

    /// Avanzamento con GPS reale (modalità "Vai"): proietta la posizione sul percorso.
    func updateWithRealLocation(_ location: CLLocation) {
        guard phase == .navigating, !isSimulating, !routeCoordinates.isEmpty, let route = route else { return }
        let here = MKMapPoint(location.coordinate)
        var bestIndex = 0
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude
        for (i, c) in routeCoordinates.enumerated() {
            let d = here.distance(to: MKMapPoint(c))
            if d < bestDistance {
                bestDistance = d
                bestIndex = i
            }
        }
        guard cumulative.indices.contains(bestIndex) else { return }
        traveled = min(route.distance, max(traveled, cumulative[bestIndex]))
        while stepEnds.indices.contains(currentStepIndex), traveled >= stepEnds[currentStepIndex],
              currentStepIndex < stepEnds.count - 1 {
            currentStepIndex += 1
        }
        if route.distance - traveled < 30 {
            NotificationCenter.default.post(name: .navigationArrived, object: destination?.name)
            endNavigation()
        }
    }

    private func updateCamera(animated: Bool) {
        guard let map = mapView, isSimulating, followUser else { return }
        let here = coordinate(at: traveled)
        let ahead = coordinate(at: min(traveled + 40, route?.distance ?? traveled))
        let heading = bearing(from: here, to: ahead)
        let camera = MKMapCamera(lookingAtCenter: here, fromDistance: 700, pitch: 50, heading: heading)
        map.setCamera(camera, animated: animated)
    }

    private func prepareGeometry(for route: MKRoute) {
        let poly = route.polyline
        let points = poly.points()
        routeCoordinates = (0..<poly.pointCount).map { points[$0].coordinate }
        cumulative = [0]
        for i in 1..<max(1, routeCoordinates.count) {
            let a = MKMapPoint(routeCoordinates[i - 1])
            let b = MKMapPoint(routeCoordinates[i])
            cumulative.append(cumulative[i - 1] + a.distance(to: b))
        }
        // Scala le distanze della geometria su quella dichiarata dal percorso.
        if let total = cumulative.last, total > 0 {
            let k = route.distance / total
            cumulative = cumulative.map { $0 * k }
        }
        var acc: CLLocationDistance = 0
        stepEnds = route.steps.map { step in
            acc += step.distance
            return acc
        }
    }

    private func firstMeaningfulStep(from index: Int) -> Int {
        guard let steps = route?.steps else { return 0 }
        var i = index
        while steps.indices.contains(i), steps[i].instructions.isEmpty, i < steps.count - 1 { i += 1 }
        return i
    }

    private func coordinate(at distance: CLLocationDistance) -> CLLocationCoordinate2D {
        guard routeCoordinates.count > 1 else { return routeCoordinates.first ?? CLLocationCoordinate2D() }
        // ricerca binaria del segmento
        var lo = 0
        var hi = cumulative.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= distance { lo = mid } else { hi = mid }
        }
        let segLen = cumulative[hi] - cumulative[lo]
        let t = segLen > 0 ? (distance - cumulative[lo]) / segLen : 0
        let a = routeCoordinates[lo]
        let b = routeCoordinates[hi]
        return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                      longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    private func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }
}

extension Notification.Name {
    static let navigationArrived = Notification.Name("CarPlaySim.navigationArrived")
}

enum Formatters {
    static func distance(_ meters: CLLocationDistance) -> String {
        if meters < 1000 {
            let rounded = meters < 100 ? (meters / 10).rounded() * 10 : (meters / 50).rounded() * 50
            return "\(Int(rounded)) m"
        }
        return String(format: "%.1f km", meters / 1000).replacingOccurrences(of: ".", with: ",")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let mins = Int((seconds / 60).rounded())
        if mins < 60 { return "\(max(1, mins)) min" }
        return "\(mins / 60) h \(mins % 60) min"
    }

    static func arrival(after seconds: TimeInterval) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date().addingTimeInterval(seconds))
    }

    static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func maneuverSymbol(for instruction: String) -> String {
        let s = instruction.lowercased()
        if s.contains("rotonda") || s.contains("roundabout") { return "arrow.triangle.turn.up.right.circle.fill" }
        if s.contains("inversione") || s.contains("u-turn") { return "arrow.uturn.left" }
        if s.contains("destinazione") || s.contains("arriv") || s.contains("destination") { return "mappin.circle.fill" }
        if s.contains("leggermente a destra") || s.contains("slight right") || s.contains("tieni la destra") || s.contains("keep right") { return "arrow.up.right" }
        if s.contains("leggermente a sinistra") || s.contains("slight left") || s.contains("tieni la sinistra") || s.contains("keep left") { return "arrow.up.left" }
        if s.contains("destra") || s.contains("right") { return "arrow.turn.up.right" }
        if s.contains("sinistra") || s.contains("left") { return "arrow.turn.up.left" }
        if s.contains("uscita") || s.contains("exit") { return "arrow.up.right" }
        return "arrow.up"
    }
}
