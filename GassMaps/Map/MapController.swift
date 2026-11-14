import UIKit
import CoreLocation
import MapLibre
import MapKit

/// Segnaposto di un risultato di ricerca
final class ResultAnnotation: MLNPointAnnotation {
    var index = 0
}

/// Etichetta sopra un percorso alternativo durante la navigazione ("4 min in più", "Durata simile")
final class AltLabelAnnotation: MLNPointAnnotation {
    var index = 0
}

/// Ponte tra SwiftUI e MLNMapView.
final class MapController {
    weak var mapView: MLNMapView?
    weak var state: AppState?

    private(set) var routeCoordinates: [CLLocationCoordinate2D] = []
    private(set) var alternativeCoordinates: [[CLLocationCoordinate2D]] = []
    private var resultAnnotations: [ResultAnnotation] = []
    private var pinAnnotation: MLNPointAnnotation?
    private var didInitialPosition = false

    static let defaultPitch: CGFloat = 52
    /// inclinazione della camera per il tema attivo
    var pitch: CGFloat {
        guard Prefs.bool(Prefs.tilt3D, default: true) else { return 0 }
        return state?.theme.mapPitch ?? MapController.defaultPitch
    }
    static let defaultZoom: Double = 16.4

    static let routeSourceID = "gm-route"
    static let routeLayerID = "gm-route-line"
    static let routeCasingID = "gm-route-casing"
    static let altSourceID = "gm-route-alt"
    static let altLayerID = "gm-route-alt-line"
    static let altCasingID = "gm-route-alt-casing"

    var centerCoordinate: CLLocationCoordinate2D? { mapView?.centerCoordinate }

    func attach(_ map: MLNMapView) {
        mapView = map
    }

    // MARK: - Camera

    func initialPosition(_ coordinate: CLLocationCoordinate2D) {
        guard !didInitialPosition, let m = mapView else { return }
        didInitialPosition = true
        let cam = MLNMapCamera(lookingAtCenter: coordinate, altitude: 650, pitch: pitch, heading: 0)
        m.setCamera(cam, animated: false)
        m.setZoomLevel(MapController.defaultZoom, animated: false)
        m.setUserTrackingMode(.follow, animated: false, completionHandler: nil)
    }

    func recenter() {
        guard let m = mapView else { return }
        setBottomInset(0)
        if let loc = m.userLocation?.location ?? state?.location.location {
            let cam = MLNMapCamera(lookingAtCenter: loc.coordinate, altitude: 650,
                                   pitch: pitch, heading: m.direction)
            m.fly(to: cam, withDuration: 0.8) { [weak self] in
                self?.mapView?.setZoomLevel(MapController.defaultZoom, animated: true)
                self?.setTracking(.follow)
            }
        } else {
            setTracking(.follow)
        }
    }

    // MARK: - Livelli (come il pulsante "Livelli" di Google Maps)

    static let satSourceID = "gm-layer-sat"
    static let satLayerID = "gm-layer-sat-raster"
    static let transitLayerID = "gm-layer-transit"
    static let bikeLayerID = "gm-layer-bike"

    /// Applica i livelli scelti: satellite (con strade ed etichette sopra), trasporti pubblici, piste ciclabili
    func applyLayers() {
        guard let style = mapView?.style else { return }
        let sat = Prefs.bool(Prefs.layerSatellite, default: false)
        let transit = Prefs.bool(Prefs.layerTransit, default: false)
        let bike = Prefs.bool(Prefs.layerBike, default: false)

        // satellite
        if sat {
            if style.layer(withIdentifier: MapController.satLayerID) == nil {
                let source: MLNSource
                if let existing = style.source(withIdentifier: MapController.satSourceID) {
                    source = existing
                } else {
                    let s = MLNRasterTileSource(identifier: MapController.satSourceID,
                        tileURLTemplates: ["https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"],
                        options: [.tileSize: 256, .maximumZoomLevel: 19])
                    style.addSource(s)
                    source = s
                }
                let layer = MLNRasterStyleLayer(identifier: MapController.satLayerID, source: source)
                if let below = style.layer(withIdentifier: "road-path") ?? style.layer(withIdentifier: "road-rail") {
                    style.insertLayer(layer, below: below)
                } else {
                    style.addLayer(layer)
                }
            }
        } else if let l = style.layer(withIdentifier: MapController.satLayerID) {
            style.removeLayer(l)
        }

        guard let vector = style.source(withIdentifier: "openmaptiles") else { return }
        let below = style.layer(withIdentifier: MapController.routeCasingID) ?? style.layer(withIdentifier: "road-oneway")

        // trasporti pubblici: linee ferroviarie, metro e tram evidenziate
        if transit {
            if style.layer(withIdentifier: MapController.transitLayerID) == nil {
                let l = MLNLineStyleLayer(identifier: MapController.transitLayerID, source: vector)
                l.sourceLayerIdentifier = "transportation"
                l.predicate = NSPredicate(format: "class IN %@", ["rail", "transit"])
                l.lineColor = NSExpression(forConstantValue: UIColor(hex: 0x2F8CFF))
                l.lineWidth = NSExpression(forConstantValue: 3.5)
                l.lineCap = NSExpression(forConstantValue: "round")
                l.lineJoin = NSExpression(forConstantValue: "round")
                if let b = below { style.insertLayer(l, below: b) } else { style.addLayer(l) }
            }
        } else if let l = style.layer(withIdentifier: MapController.transitLayerID) {
            style.removeLayer(l)
        }

        // piste ciclabili
        if bike {
            if style.layer(withIdentifier: MapController.bikeLayerID) == nil {
                let l = MLNLineStyleLayer(identifier: MapController.bikeLayerID, source: vector)
                l.sourceLayerIdentifier = "transportation"
                l.predicate = NSPredicate(format: "subclass == 'cycleway'")
                l.lineColor = NSExpression(forConstantValue: UIColor(hex: 0x1E8E3E))
                l.lineWidth = NSExpression(forConstantValue: 3)
                l.lineCap = NSExpression(forConstantValue: "round")
                l.lineJoin = NSExpression(forConstantValue: "round")
                if let b = below { style.insertLayer(l, below: b) } else { style.addLayer(l) }
            }
        } else if let l = style.layer(withIdentifier: MapController.bikeLayerID) {
            style.removeLayer(l)
        }
    }

    // MARK: - Alternative durante la navigazione

    private var altLabels: [AltLabelAnnotation] = []

    func showAltLabels(_ items: [(coordinate: CLLocationCoordinate2D, text: String, index: Int)]) {
        clearAltLabels()
        guard let m = mapView else { return }
        altLabels = items.map { item in
            let a = AltLabelAnnotation()
            a.coordinate = item.coordinate
            a.title = item.text
            a.index = item.index
            return a
        }
        m.addAnnotations(altLabels)
    }

    func clearAltLabels() {
        guard !altLabels.isEmpty else { return }
        mapView?.removeAnnotations(altLabels)
        altLabels = []
    }

    // MARK: - Misura distanza

    static let measureSourceID = "gm-measure"

    func drawMeasure(_ points: [CLLocationCoordinate2D]) {
        guard let style = mapView?.style else { return }
        var coords = points
        let shape: MLNShape? = coords.count > 1 ? MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count)) : nil
        let dots = MLNShapeCollectionFeature(shapes: points.map { c -> MLNPointFeature in
            let f = MLNPointFeature(); f.coordinate = c; return f
        })
        if let source = style.source(withIdentifier: MapController.measureSourceID) as? MLNShapeSource,
           let dotSource = style.source(withIdentifier: MapController.measureSourceID + "-dots") as? MLNShapeSource {
            source.shape = shape
            dotSource.shape = points.isEmpty ? nil : dots
            return
        }
        guard !points.isEmpty else { return }
        let source = MLNShapeSource(identifier: MapController.measureSourceID, shape: shape, options: nil)
        let dotSource = MLNShapeSource(identifier: MapController.measureSourceID + "-dots", shape: dots, options: nil)
        style.addSource(source)
        style.addSource(dotSource)
        let line = MLNLineStyleLayer(identifier: MapController.measureSourceID + "-line", source: source)
        line.lineColor = NSExpression(forConstantValue: UIColor.white)
        line.lineWidth = NSExpression(forConstantValue: 3)
        line.lineDashPattern = NSExpression(forConstantValue: [2, 1.5])
        let casing = MLNLineStyleLayer(identifier: MapController.measureSourceID + "-casing", source: source)
        casing.lineColor = NSExpression(forConstantValue: UIColor.black.withAlphaComponent(0.6))
        casing.lineWidth = NSExpression(forConstantValue: 6)
        let circles = MLNCircleStyleLayer(identifier: MapController.measureSourceID + "-points", source: dotSource)
        circles.circleColor = NSExpression(forConstantValue: UIColor.white)
        circles.circleRadius = NSExpression(forConstantValue: 5)
        circles.circleStrokeColor = NSExpression(forConstantValue: UIColor.black)
        circles.circleStrokeWidth = NSExpression(forConstantValue: 2)
        style.addLayer(casing)
        style.addLayer(line)
        style.addLayer(circles)
    }

    /// Dalla modalità bussola: nord in alto continuando a seguire la posizione
    func resetNorthFollowing() {
        guard let m = mapView else { return }
        m.setUserTrackingMode(.follow, animated: true, completionHandler: nil)
        m.setDirection(0, animated: true)
        state?.tracking = .follow
    }

    func setTracking(_ t: TrackingState) {
        guard let m = mapView else { return }
        switch t {
        case .none: m.setUserTrackingMode(.none, animated: true, completionHandler: nil)
        case .follow: m.setUserTrackingMode(.follow, animated: true, completionHandler: nil)
        case .heading: m.setUserTrackingMode(.followWithHeading, animated: true, completionHandler: nil)
        }
        state?.tracking = t
    }

    func fly(to coordinate: CLLocationCoordinate2D) {
        guard let m = mapView else { return }
        m.setUserTrackingMode(.none, animated: false, completionHandler: nil)
        state?.tracking = .none
        setBottomInset(330)
        let cam = MLNMapCamera(lookingAtCenter: coordinate, altitude: 700,
                               pitch: pitch, heading: m.direction)
        m.fly(to: cam, withDuration: 1.1, completionHandler: nil)
    }

    /// Orizzontale: come Google Maps i pannelli stanno in una colonna a sinistra invece che in basso
    var isLandscape: Bool {
        guard let m = mapView else { return false }
        return m.bounds.width > m.bounds.height
    }

    static func sidePanelWidth(for width: CGFloat) -> CGFloat { min(420, width * 0.42) }

    private var lastBottomInset: CGFloat = 0

    func setBottomInset(_ bottom: CGFloat) {
        guard let m = mapView else { return }
        lastBottomInset = bottom
        if isLandscape {
            // il pannello occupa la colonna di sinistra: la mappa si centra nello spazio libero a destra
            let left = bottom > 0 ? MapController.sidePanelWidth(for: m.bounds.width) + 8 : 0
            m.setContentInset(UIEdgeInsets(top: 0, left: left, bottom: 0, right: 0), animated: true)
        } else {
            m.setContentInset(UIEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0), animated: true)
        }
    }

    /// Rotazione del telefono: si riapplicano i margini adatti al nuovo orientamento
    func orientationChanged(navigating: Bool) {
        if navigating {
            if state?.tracking != TrackingState.none { applyNavigationInsets(animated: false) }
        } else {
            setBottomInset(lastBottomInset)
        }
    }

    /// Margini per inquadrare un percorso intero sopra/accanto al pannello
    private var overviewPadding: UIEdgeInsets {
        guard let m = mapView, isLandscape else { return UIEdgeInsets(top: 150, left: 34, bottom: 380, right: 34) }
        return UIEdgeInsets(top: 40, left: MapController.sidePanelWidth(for: m.bounds.width) + 40, bottom: 30, right: 80)
    }

    // MARK: - Pin

    func showPin(_ place: Place) {
        guard let m = mapView else { return }
        removePin()
        let a = MLNPointAnnotation()
        a.coordinate = place.coordinate
        a.title = place.name
        m.addAnnotation(a)
        pinAnnotation = a
        if place.name.isEmpty {
            setBottomInset(330)
            m.setUserTrackingMode(.none, animated: false, completionHandler: nil)
            state?.tracking = .none
            let cam = MLNMapCamera(lookingAtCenter: place.coordinate, altitude: 700,
                                   pitch: pitch, heading: m.direction)
            m.setCamera(cam, withDuration: 0.6, animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
        }
    }

    func removePin() {
        if let a = pinAnnotation { mapView?.removeAnnotation(a) }
        pinAnnotation = nil
    }

    // MARK: - Percorso

    func showRoute(_ coordinates: [CLLocationCoordinate2D], overview: Bool) {
        showRoute(coordinates, alternatives: [], overview: overview)
    }

    /// Percorso scelto (colore del tema) + alternative (grigie, toccabili) come in Google Maps
    func showRoute(_ coordinates: [CLLocationCoordinate2D], alternatives: [[CLLocationCoordinate2D]], overview: Bool) {
        routeCoordinates = coordinates
        alternativeCoordinates = alternatives.filter { $0.count > 1 }
        guard let m = mapView else { return }
        if let style = m.style { installRoute(in: style) }
        guard overview, coordinates.count > 1 else { return }

        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for c in coordinates + alternativeCoordinates.flatMap({ $0 }) {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
                                         ne: CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon))
        m.setUserTrackingMode(.none, animated: false, completionHandler: nil)
        state?.tracking = .none
        m.setContentInset(.zero, animated: false)
        // Come nel video: vista dall'alto, nord in su, percorso intero nella parte alta sopra il pannello,
        // movimento rapido (~0,5 s) senza "volo".
        // L'inquadratura si calcola già con vista dall'alto e nord in su: così basta un tocco anche
        // partendo dalla vista inclinata della navigazione (prima serviva un secondo tocco).
        let flat = MLNMapCamera(lookingAtCenter: m.centerCoordinate, altitude: m.camera.altitude, pitch: 0, heading: 0)
        let cam = m.camera(flat, fitting: bounds, edgePadding: overviewPadding)
        cam.pitch = 0
        cam.heading = 0
        m.setCamera(cam, withDuration: 0.5, animationTimingFunction: CAMediaTimingFunction(name: .easeOut))
    }

    func installRoute(in style: MLNStyle) {
        installAlternatives(in: style)
        guard routeCoordinates.count > 1 else { return }
        var coords = routeCoordinates
        let line = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))

        if let source = style.source(withIdentifier: MapController.routeSourceID) as? MLNShapeSource {
            source.shape = line
            return
        }
        let source = MLNShapeSource(identifier: MapController.routeSourceID, shape: line, options: nil)
        style.addSource(source)

        let accent = state?.theme.accent ?? UIColor(hex: 0x7B2CF0)

        if state?.theme.id == "crimson" {
            installLoadingBarRoute(in: style, source: source)
            return
        }

        let casing = MLNLineStyleLayer(identifier: MapController.routeCasingID, source: source)
        casing.lineColor = NSExpression(forConstantValue: UIColor.black.withAlphaComponent(0.55))
        casing.lineWidth = NSExpression(forConstantValue: 11)
        casing.lineCap = NSExpression(forConstantValue: "round")
        casing.lineJoin = NSExpression(forConstantValue: "round")

        let layer = MLNLineStyleLayer(identifier: MapController.routeLayerID, source: source)
        layer.lineColor = NSExpression(forConstantValue: accent)
        layer.lineWidth = NSExpression(forConstantValue: 6.5)
        layer.lineCap = NSExpression(forConstantValue: "round")
        layer.lineJoin = NSExpression(forConstantValue: "round")

        if let below = style.layer(withIdentifier: "road-oneway") {
            style.insertLayer(casing, below: below)
            style.insertLayer(layer, below: below)
        } else {
            style.addLayer(casing)
            style.addLayer(layer)
        }
    }

    /// Percorso disegnato come la barra di caricamento della splash: binario scuro, riempimento blu
    /// con sfumatura dall'azzurro chiaro (sopra) al blu-viola (sotto) e alone blu
    private func installLoadingBarRoute(in style: MLNStyle, source: MLNShapeSource) {
        func line(_ id: String, _ color: UInt32, width: Double, offset: Double = 0, blur: Double = 0, opacity: Double = 1) -> MLNLineStyleLayer {
            let l = MLNLineStyleLayer(identifier: id, source: source)
            l.lineColor = NSExpression(forConstantValue: UIColor(hex: color))
            l.lineWidth = NSExpression(forConstantValue: width)
            l.lineCap = NSExpression(forConstantValue: "round")
            l.lineJoin = NSExpression(forConstantValue: "round")
            if offset != 0 { l.lineOffset = NSExpression(forConstantValue: offset) }
            if blur > 0 { l.lineBlur = NSExpression(forConstantValue: blur) }
            if opacity < 1 { l.lineOpacity = NSExpression(forConstantValue: opacity) }
            return l
        }
        let layers = [
            line(MapController.routeCasingID + "-glow", 0x0970FF, width: 20, blur: 7, opacity: 0.55),   // alone
            line(MapController.routeCasingID, 0x181818, width: 14),                                       // binario scuro
            line(MapController.routeLayerID, 0x1784FF, width: 9),                                         // riempimento
            line(MapController.routeLayerID + "-mid", 0x0970FF, width: 3.5),                              // centro più intenso
            line(MapController.routeLayerID + "-top", 0x68BBFE, width: 2.2, offset: -3),                  // bordo alto chiaro
            line(MapController.routeLayerID + "-bottom", 0x3564FE, width: 2.2, offset: 3)                 // bordo basso blu-viola
        ]
        let below = style.layer(withIdentifier: "road-oneway")
        for l in layers {
            if let b = below { style.insertLayer(l, below: b) } else { style.addLayer(l) }
        }
    }

    private func installAlternatives(in style: MLNStyle) {
        let shapes: [MLNShape] = alternativeCoordinates.map { coords in
            var c = coords
            return MLNPolylineFeature(coordinates: &c, count: UInt(c.count))
        }
        let collection = MLNShapeCollectionFeature(shapes: shapes)
        if let source = style.source(withIdentifier: MapController.altSourceID) as? MLNShapeSource {
            source.shape = collection
            return
        }
        guard !shapes.isEmpty else { return }
        let source = MLNShapeSource(identifier: MapController.altSourceID, shape: collection, options: nil)
        style.addSource(source)
        let casing = MLNLineStyleLayer(identifier: MapController.altCasingID, source: source)
        casing.lineColor = NSExpression(forConstantValue: UIColor.black.withAlphaComponent(0.45))
        casing.lineWidth = NSExpression(forConstantValue: 10)
        casing.lineCap = NSExpression(forConstantValue: "round")
        casing.lineJoin = NSExpression(forConstantValue: "round")
        let layer = MLNLineStyleLayer(identifier: MapController.altLayerID, source: source)
        layer.lineColor = NSExpression(forConstantValue: UIColor(white: 0.62, alpha: 0.95))
        layer.lineWidth = NSExpression(forConstantValue: 5.5)
        layer.lineCap = NSExpression(forConstantValue: "round")
        layer.lineJoin = NSExpression(forConstantValue: "round")
        // le alternative stanno sotto al percorso scelto
        if let below = style.layer(withIdentifier: MapController.routeCasingID) ?? style.layer(withIdentifier: "road-oneway") {
            style.insertLayer(casing, below: below)
            style.insertLayer(layer, below: below)
        } else {
            style.addLayer(casing)
            style.addLayer(layer)
        }
    }

    func clearRoute() {
        routeCoordinates = []
        alternativeCoordinates = []
        guard let style = mapView?.style else { return }
        if let source = style.source(withIdentifier: MapController.routeSourceID) as? MLNShapeSource {
            source.shape = nil
        }
        if let source = style.source(withIdentifier: MapController.altSourceID) as? MLNShapeSource {
            source.shape = nil
        }
    }

    /// Indice dell'alternativa più vicina al punto toccato (entro 26 pt), se c'è
    func alternativeIndex(near point: CGPoint) -> Int? {
        guard let m = mapView else { return nil }
        var best: (Int, CGFloat)?
        for (i, coords) in alternativeCoordinates.enumerated() {
            let pts = coords.map { m.convert($0, toPointTo: m) }
            for j in 0..<(pts.count - 1) {
                let d = MapController.distance(point, pts[j], pts[j + 1])
                if d < 26 && (best == nil || d < best!.1) { best = (i, d) }
            }
        }
        return best?.0
    }

    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let vx = b.x - a.x, vy = b.y - a.y
        let len2 = vx * vx + vy * vy
        var t = len2 > 0 ? ((p.x - a.x) * vx + (p.y - a.y) * vy) / len2 : 0
        t = min(max(t, 0), 1)
        let cx = a.x + t * vx - p.x, cy = a.y + t * vy - p.y
        return sqrt(cx * cx + cy * cy)
    }

    // MARK: - Risultati di ricerca

    func showResults(_ items: [MKMapItem]) {
        guard let m = mapView else { return }
        clearResults()
        removePin()
        let anns = items.enumerated().map { i, item -> ResultAnnotation in
            let a = ResultAnnotation()
            a.coordinate = item.placemark.coordinate
            a.title = item.name
            a.index = i
            return a
        }
        resultAnnotations = anns
        m.addAnnotations(anns)
        m.setUserTrackingMode(.none, animated: false, completionHandler: nil)
        state?.tracking = .none
        m.contentInset = .zero
        let coords = anns.map { $0.coordinate }
        guard let first = coords.first else { return }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let pad = 0.002
        let bounds = MLNCoordinateBounds(sw: CLLocationCoordinate2D(latitude: minLat - pad, longitude: minLon - pad),
                                         ne: CLLocationCoordinate2D(latitude: maxLat + pad, longitude: maxLon + pad))
        let cam = m.cameraThatFitsCoordinateBounds(bounds, edgePadding: isLandscape
            ? UIEdgeInsets(top: 60, left: MapController.sidePanelWidth(for: m.bounds.width) + 40, bottom: 40, right: 80)
            : UIEdgeInsets(top: 170, left: 40, bottom: 400, right: 40))
        cam.pitch = min(pitch, 30)
        m.setCamera(cam, withDuration: 0.6, animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
    }

    func clearResults() {
        if !resultAnnotations.isEmpty { mapView?.removeAnnotations(resultAnnotations) }
        resultAnnotations = []
    }

    /// Area visibile della mappa (per "Cerca in questa zona" e per i suggerimenti di ricerca)
    var visibleRegion: MKCoordinateRegion? {
        guard let m = mapView else { return nil }
        let b = m.visibleCoordinateBounds
        let center = CLLocationCoordinate2D(latitude: (b.sw.latitude + b.ne.latitude) / 2,
                                            longitude: (b.sw.longitude + b.ne.longitude) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.01, abs(b.ne.latitude - b.sw.latitude)),
                                    longitudeDelta: max(0.01, abs(b.ne.longitude - b.sw.longitude)))
        return MKCoordinateRegion(center: center, span: span)
    }

    func resetNorth() {
        mapView?.resetNorth()
    }

    // MARK: - Navigazione

    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDirection {
        let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dl) * cos(la2)
        let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dl)
        let deg = atan2(y, x) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    /// Inquadratura di guida come Google Maps: la freccia sta in basso (circa a tre quarti dello schermo),
    /// così si vede molta più strada davanti che dietro.
    func applyNavigationInsets(animated: Bool = true) {
        guard let m = mapView else { return }
        let h = m.bounds.height
        if isLandscape {
            // freccia in basso a destra della colonna dei pannelli, molta strada davanti
            m.setContentInset(UIEdgeInsets(top: h * 0.4, left: MapController.sidePanelWidth(for: m.bounds.width), bottom: 20, right: 0),
                              animated: animated)
        } else {
            m.setContentInset(UIEdgeInsets(top: h * 0.46, left: 0, bottom: 150, right: 0), animated: animated)
        }
    }

    /// Zoom in base alla velocità (più lontano in autostrada, più vicino in città), come Google Maps
    func adjustNavigationZoom(speedKmh: Int, walking: Bool) {
        guard let m = mapView, state?.tracking == .heading else { return }
        let z: Double
        if walking { z = 18 }
        else if speedKmh < 25 { z = 17.6 }
        else if speedKmh < 55 { z = 17.1 }
        else if speedKmh < 90 { z = 16.4 }
        else { z = 15.7 }
        if abs(m.zoomLevel - z) > 0.35 { m.setZoomLevel(z, animated: true) }
    }

    /// Il tratto già percorso sparisce dietro la freccia (come Google Maps)
    func trimRoute(from point: CLLocationCoordinate2D, index: Int) {
        guard routeCoordinates.count > 1, let style = mapView?.style,
              let source = style.source(withIdentifier: MapController.routeSourceID) as? MLNShapeSource else { return }
        let rest = index + 1 < routeCoordinates.count ? Array(routeCoordinates[(index + 1)...]) : []
        var coords = [point] + rest
        guard coords.count > 1 else { source.shape = nil; return }
        source.shape = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
    }

    func startNavigation() {
        guard let m = mapView else { return }
        applyNavigationInsets()
        if let loc = m.userLocation?.location ?? state?.location.location {
            // Come nel video: passaggio quasi immediato a una vista molto ravvicinata che segue la marcia
            var course = loc.course >= 0 ? loc.course : m.direction
            if loc.course < 0, routeCoordinates.count > 1 {
                course = MapController.bearing(from: routeCoordinates[0], to: routeCoordinates[min(5, routeCoordinates.count - 1)])
            }
            let cam = MLNMapCamera(lookingAtCenter: loc.coordinate, altitude: 230, pitch: 52, heading: course)
            m.setCamera(cam, withDuration: 0.35, animationTimingFunction: CAMediaTimingFunction(name: .easeOut))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.mapView?.setUserTrackingMode(.followWithCourse, animated: true, completionHandler: nil)
            }
        } else {
            m.setUserTrackingMode(.followWithCourse, animated: true, completionHandler: nil)
        }
        state?.tracking = .heading
    }
}
