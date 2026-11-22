import UIKit
import CoreLocation
import MapLibre

/// Mappa di CarPlay. La stessa classe serve tre schermi:
/// - `.main`: schermo principale (anteprima del viaggio, guida, panoramica, spostamento e zoom);
/// - `.dashboard`: riquadro della mappa nella schermata Dashboard di CarPlay;
/// - `.cluster`: quadro strumenti dell'auto (solo le auto che lo supportano).
/// La posizione arriva dalla stessa sorgente filtrata del telefono, anche a telefono bloccato.
/// MapLibre continua a disegnare in background quando la vista è su uno schermo esterno (CarPlay).
@MainActor
final class CarPlayMapViewController: UIViewController, MLNMapViewDelegate {
    enum Role { case main, dashboard, cluster }

    let role: Role
    private let state: AppState
    private let feed: MapLocationFeed
    private(set) var mapView: MLNMapView!
    private var routeCoords: [CLLocationCoordinate2D] = []
    private var styleID = ""
    private(set) var navigating = false
    private var previewing = false
    /// gesti sullo schermo touch dell'auto
    private var dragStartCenter: CGPoint?
    private var zoomStart: Double?

    private static let sourceID = "cp-route"
    private static let lineID = "cp-route-line"
    private static let casingID = "cp-route-casing"

    init(state: AppState, role: Role) {
        self.state = state
        self.role = role
        self.feed = state.location.makeMapFeed()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func loadView() {
        let map = MLNMapView(frame: .zero, styleURL: state.theme.styleURL)
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.delegate = self
        map.backgroundColor = .black
        map.logoView.isHidden = true
        map.compassView.isHidden = true
        map.attributionButton.alpha = role == .main ? 0.35 : 0
        map.attributionButton.isUserInteractionEnabled = false
        map.locationManager = feed
        map.showsUserLocation = true
        map.showsUserHeadingIndicator = true
        map.allowsRotating = true
        map.allowsTilting = true
        map.allowsZooming = role == .main
        map.allowsScrolling = role == .main
        map.minimumZoomLevel = 3
        map.maximumZoomLevel = 19.5
        map.setZoomLevel(role == .main ? 15.5 : 16, animated: false)
        map.userTrackingMode = .follow
        styleID = state.theme.id
        mapView = map
        view = map
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyInsets(animated: false)
    }

    // MARK: Stile e percorso

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        installRoute()
    }

    /// Stessa freccia di posizione del telefono (colore del tema e avatar scelto)
    func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
        annotation is MLNUserLocation ? UserArrowView() : nil
    }

    func applyTheme() {
        guard state.theme.id != styleID else { return }
        styleID = state.theme.id
        mapView.styleURL = state.theme.styleURL   // il percorso si reinstalla a stile caricato
    }

    func setRoute(_ coords: [CLLocationCoordinate2D]) {
        routeCoords = coords
        installRoute()
    }

    /// Il tratto già percorso sparisce dietro la freccia (come sul telefono)
    func trimRoute(traveled: Double, cumulative: [Double]) {
        guard routeCoords.count > 1, cumulative.count == routeCoords.count, traveled > 0 else { return }
        let p = RouteMath.point(at: traveled, on: routeCoords, cumulative: cumulative)
        let rest = p.index + 1 < routeCoords.count ? Array(routeCoords[(p.index + 1)...]) : []
        updateShape([p.coordinate] + rest)
    }

    private func installRoute() {
        guard let style = mapView?.style else { return }
        if style.source(withIdentifier: CarPlayMapViewController.sourceID) != nil {
            updateShape(routeCoords)
            return
        }
        let source = MLNShapeSource(identifier: CarPlayMapViewController.sourceID, shape: shape(routeCoords), options: nil)
        style.addSource(source)

        let casing = MLNLineStyleLayer(identifier: CarPlayMapViewController.casingID, source: source)
        casing.lineColor = NSExpression(forConstantValue: UIColor.black.withAlphaComponent(0.55))
        casing.lineWidth = NSExpression(forConstantValue: role == .main ? 12 : 9)
        casing.lineCap = NSExpression(forConstantValue: "round")
        casing.lineJoin = NSExpression(forConstantValue: "round")

        let line = MLNLineStyleLayer(identifier: CarPlayMapViewController.lineID, source: source)
        line.lineColor = NSExpression(forConstantValue: state.theme.accent)
        line.lineWidth = NSExpression(forConstantValue: role == .main ? 7 : 5.5)
        line.lineCap = NSExpression(forConstantValue: "round")
        line.lineJoin = NSExpression(forConstantValue: "round")

        if let below = style.layer(withIdentifier: "road-oneway") {
            style.insertLayer(casing, below: below)
            style.insertLayer(line, below: below)
        } else {
            style.addLayer(casing)
            style.addLayer(line)
        }
    }

    private func updateShape(_ coords: [CLLocationCoordinate2D]) {
        guard let source = mapView?.style?.source(withIdentifier: CarPlayMapViewController.sourceID) as? MLNShapeSource else { return }
        source.shape = shape(coords)
    }

    private func shape(_ coords: [CLLocationCoordinate2D]) -> MLNShape {
        var c = coords
        if c.count > 1 { return MLNPolylineFeature(coordinates: &c, count: UInt(c.count)) }
        return MLNShapeCollection(shapes: [])
    }

    // MARK: Camera

    /// Durante la guida la freccia sta in basso a destra, lontano dalla scheda della manovra (come Apple Maps)
    private func applyInsets(animated: Bool) {
        guard let m = mapView, m.bounds.width > 0 else { return }
        let inset: UIEdgeInsets
        if navigating && !previewing && role == .main {
            inset = UIEdgeInsets(top: m.bounds.height * 0.38, left: m.bounds.width * 0.36, bottom: 8, right: 8)
        } else if navigating && role != .main {
            inset = UIEdgeInsets(top: m.bounds.height * 0.35, left: 0, bottom: 0, right: 0)
        } else {
            inset = .zero
        }
        if m.contentInset != inset { m.setContentInset(inset, animated: animated) }
    }

    /// Anteprima: percorso intero, a destra della scheda dell'anteprima di CarPlay
    func showPreview(_ coords: [CLLocationCoordinate2D]) {
        previewing = true
        setRoute(coords)
        applyInsets(animated: false)
        fit(coords)
    }

    /// Panoramica del percorso durante la guida
    func showOverview() {
        guard routeCoords.count > 1 else { return }
        previewing = true
        applyInsets(animated: false)
        fit(routeCoords)
    }

    private func fit(_ coords: [CLLocationCoordinate2D]) {
        guard coords.count > 1 else { return }
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
                                         ne: CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon))
        mapView.setUserTrackingMode(.none, animated: false, completionHandler: nil)
        let cam = mapView.camera
        cam.pitch = 0
        cam.heading = 0
        mapView.setCamera(cam, animated: false)
        let w = mapView.bounds.width
        let pad = role == .main
            ? UIEdgeInsets(top: 30, left: max(40, w * 0.42), bottom: 30, right: 60)
            : UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        mapView.setVisibleCoordinateBounds(bounds, edgePadding: pad, animated: true, completionHandler: nil)
    }

    func endPreview() {
        previewing = false
        if !navigating { setRoute([]) }
        recenter()
    }

    /// Guida: vista inclinata che segue la direzione di marcia
    func beginNavigation(route coords: [CLLocationCoordinate2D]) {
        navigating = true
        previewing = false
        setRoute(coords)
        recenter()
    }

    func endNavigation() {
        navigating = false
        previewing = false
        setRoute([])
        recenter()
    }

    func recenter() {
        previewing = false
        applyInsets(animated: true)
        let cam = mapView.camera
        cam.pitch = navigating ? 50 : 0
        mapView.setCamera(cam, animated: true)
        mapView.setUserTrackingMode(navigating ? .followWithCourse : .follow, animated: true, completionHandler: nil)
        if navigating { mapView.setZoomLevel(role == .main ? 16.8 : 16.4, animated: true) }
    }

    /// Zoom secondo la velocità durante la guida (come sul telefono)
    func adjustZoom(speedKmh: Int) {
        guard navigating, !previewing, mapView.userTrackingMode == .followWithCourse else { return }
        let z: Double
        if speedKmh < 25 { z = 17.4 } else if speedKmh < 55 { z = 16.9 } else if speedKmh < 90 { z = 16.2 } else { z = 15.5 }
        if abs(mapView.zoomLevel - z) > 0.35 { mapView.setZoomLevel(z, animated: true) }
    }

    func zoom(by delta: Double) {
        mapView.setZoomLevel(min(max(mapView.zoomLevel + delta, 3), 19.5), animated: true)
    }

    /// Spostamento con le frecce del pannello "Sposta" di CarPlay
    func pan(dx: CGFloat, dy: CGFloat) {
        mapView.setUserTrackingMode(.none, animated: false, completionHandler: nil)
        let step = min(mapView.bounds.width, mapView.bounds.height) * 0.3
        let p = CGPoint(x: mapView.bounds.midX + dx * step, y: mapView.bounds.midY + dy * step)
        mapView.setCenter(mapView.convert(p, toCoordinateFrom: mapView), animated: true)
    }

    // MARK: Gesti sullo schermo touch dell'auto

    func beginDrag() {
        mapView.setUserTrackingMode(.none, animated: false, completionHandler: nil)
        dragStartCenter = mapView.convert(mapView.centerCoordinate, toPointTo: mapView)
    }

    func drag(translation: CGPoint) {
        guard let start = dragStartCenter else { return }
        let p = CGPoint(x: start.x - translation.x, y: start.y - translation.y)
        mapView.setCenter(mapView.convert(p, toCoordinateFrom: mapView), animated: false)
    }

    func endDrag() { dragStartCenter = nil }

    func beginZoomGesture() {
        mapView.setUserTrackingMode(.none, animated: false, completionHandler: nil)
        zoomStart = mapView.zoomLevel
    }

    func zoomGesture(scale: CGFloat) {
        guard let z0 = zoomStart, scale > 0 else { return }
        mapView.setZoomLevel(min(max(z0 + log2(Double(scale)), 3), 19.5), animated: false)
    }

    func endZoomGesture() { zoomStart = nil }
}
