import UIKit
import CoreLocation
import MapLibre

/// Mappa sullo schermo dell'auto: stesso tema del telefono, percorso disegnato col colore del tema,
/// vista che segue la marcia durante la guida e panoramica del percorso nell'anteprima.
final class CarPlayMapViewController: UIViewController, MLNMapViewDelegate {
    private let state: AppState
    private(set) var mapView: MLNMapView!
    private var routeCoords: [CLLocationCoordinate2D] = []
    private var styleID = ""
    private var navigating = false

    private static let sourceID = "cp-route"
    private static let lineID = "cp-route-line"
    private static let casingID = "cp-route-casing"

    init(state: AppState) {
        self.state = state
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
        map.attributionButton.alpha = 0.35
        map.showsUserLocation = true
        map.allowsRotating = true
        map.allowsTilting = true
        map.minimumZoomLevel = 3
        map.maximumZoomLevel = 19.5
        map.setZoomLevel(15.5, animated: false)
        map.userTrackingMode = .follow
        styleID = state.theme.id
        mapView = map
        view = map
    }

    // MARK: Stile e percorso

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        installRoute()
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

    private func installRoute() {
        guard let style = mapView?.style else { return }
        var coords = routeCoords
        let shape: MLNShape
        if coords.count > 1 {
            shape = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
        } else {
            shape = MLNShapeCollection(shapes: [])
        }
        if let source = style.source(withIdentifier: CarPlayMapViewController.sourceID) as? MLNShapeSource {
            source.shape = shape
            return
        }
        let source = MLNShapeSource(identifier: CarPlayMapViewController.sourceID, shape: shape, options: nil)
        style.addSource(source)

        let casing = MLNLineStyleLayer(identifier: CarPlayMapViewController.casingID, source: source)
        casing.lineColor = NSExpression(forConstantValue: UIColor.black.withAlphaComponent(0.55))
        casing.lineWidth = NSExpression(forConstantValue: 12)
        casing.lineCap = NSExpression(forConstantValue: "round")
        casing.lineJoin = NSExpression(forConstantValue: "round")

        let line = MLNLineStyleLayer(identifier: CarPlayMapViewController.lineID, source: source)
        line.lineColor = NSExpression(forConstantValue: state.theme.accent)
        line.lineWidth = NSExpression(forConstantValue: 7)
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

    // MARK: Camera

    /// Anteprima: percorso intero, a destra della scheda dell'anteprima di CarPlay
    func showPreview(_ coords: [CLLocationCoordinate2D]) {
        navigating = false
        setRoute(coords)
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
        let pad = UIEdgeInsets(top: 30, left: max(40, w * 0.42), bottom: 30, right: 40)
        mapView.setVisibleCoordinateBounds(bounds, edgePadding: pad, animated: true, completionHandler: nil)
    }

    /// Guida: vista inclinata che segue la direzione di marcia
    func beginNavigation() {
        navigating = true
        recenter()
        mapView.setZoomLevel(16.8, animated: true)
    }

    func endNavigation() {
        navigating = false
        setRoute([])
        recenter()
    }

    func recenter() {
        let cam = mapView.camera
        cam.pitch = navigating ? 50 : 0
        mapView.setCamera(cam, animated: true)
        mapView.setUserTrackingMode(navigating ? .followWithCourse : .follow, animated: true, completionHandler: nil)
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
}
